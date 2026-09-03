#!/usr/bin/env bash
set -euo pipefail

# Build the source-bound Windows handoff. This is deterministic packaging of
# the selected source checkout and supplied runtime inputs; it does not claim
# bit-for-bit identity across compiler/runtime toolchains. The script intentionally
# stages explicit production files instead of copying a workspace, runtime
# tree, or any machine-local data. The resulting archive contains no secrets.

usage() {
    cat >&2 <<'EOF'
Usage: scripts/build_windows_release.sh --node-source PATH [--output-dir PATH]

  --node-source PATH  standalone Windows node.exe, or a directory containing it
  --output-dir PATH   destination for lifeos-release-SHA and its zip (default: /private/tmp)
EOF
}

die() {
    echo "build_windows_release: $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
output_dir="/private/tmp"
node_source=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-source)
            [[ $# -ge 2 ]] || { usage; die '--node-source requires a path'; }
            node_source="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { usage; die '--output-dir requires a path'; }
            output_dir="$2"
            shift 2
            ;;
        --help|-h)
            usage >&2
            exit 0
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

for tool in git npm node dotnet python3; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool is not installed or not on PATH: $tool"
done

sdk_list="$(dotnet --list-sdks 2>/dev/null || true)"
[[ "$sdk_list" == *"9."* ]] || die 'a .NET 9 SDK is required for the self-contained service-host publish'

repo_status="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$repo_status" ]] || die 'the repository worktree must be clean before a release build'

branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[[ -n "$branch" ]] || die 'the release build requires a named branch, not a detached HEAD'
upstream="$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
[[ "$upstream" == origin/* ]] || die 'the release build requires an origin/* upstream branch'
source_sha="$(git -C "$repo_root" rev-parse HEAD)"
origin_sha="$(git -C "$repo_root" rev-parse "$upstream")"
[[ "$source_sha" == "$origin_sha" ]] || die "HEAD does not match $upstream"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || die 'git did not return a full lowercase source SHA'

if [[ -z "$node_source" ]]; then
    for candidate in \
        "$repo_root/services/api/node-runtime/node.exe" \
        "$repo_root/services/api/node/node.exe"; do
        if [[ -f "$candidate" ]]; then
            node_source="$candidate"
            break
        fi
    done
fi
[[ -n "$node_source" ]] || die 'pass --node-source with a standalone Windows node.exe; the builder never copies a user Hermes node tree'
if [[ -d "$node_source" ]]; then
    node_source="$node_source/node.exe"
fi
[[ -f "$node_source" ]] || die "Node source is not a file: $node_source"
[[ ! -L "$node_source" ]] || die 'Node source must not be a symbolic link'
node_source="$(cd "$(dirname "$node_source")" && pwd -P)/$(basename "$node_source")"
node_size="$(wc -c < "$node_source" | tr -d '[:space:]')"
[[ "$node_size" =~ ^[0-9]+$ ]] || die 'could not determine the standalone node.exe size'
(( node_size <= 256 * 1024 * 1024 )) || die 'Node source is unexpectedly large; pass only the standalone node.exe, never the Hermes runtime tree'
python3 - "$node_source" <<'PY'
import sys
from pathlib import Path

node_path = Path(sys.argv[1])
with node_path.open("rb") as handle:
    if handle.read(2) != b"MZ":
        raise SystemExit("Node source is not a Windows PE executable")
PY

if [[ "$output_dir" != /* ]]; then
    output_dir="$PWD/$output_dir"
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
if [[ "$output_dir" == "$repo_root" || "$output_dir" == "$repo_root/"* ]]; then
    die 'output directory must be outside the repository worktree'
fi

final_release="$output_dir/lifeos-release-$source_sha"
final_archive="$output_dir/lifeos-release-$source_sha.zip"
final_archive_hash="$final_archive.sha256"
[[ ! -e "$final_release" ]] || die "candidate directory already exists; remove or archive it explicitly before rebuilding: $final_release"
[[ ! -e "$final_archive" ]] || die "candidate archive already exists; refusing to overwrite: $final_archive"
[[ ! -e "$final_archive_hash" ]] || die "candidate archive hash already exists; refusing to overwrite: $final_archive_hash"

[[ -x "$repo_root/node_modules/.bin/tsc" ]] || die 'root npm dependencies are missing; install the locked workspace dependencies before building'
[[ -f "$repo_root/node_modules/zod/package.json" ]] || die 'the production zod dependency is missing from root node_modules'

work_root="$(mktemp -d "${TMPDIR:-/private/tmp}/lifeos-release-build.XXXXXX")"
cleanup() {
    rm -rf "$work_root"
}
trap cleanup EXIT

release_tmp="$work_root/lifeos-release-$source_sha"
publish_tmp="$work_root/service-host-publish"
mkdir -p "$release_tmp" "$publish_tmp"

copy_file() {
    local source="$1"
    local relative_destination="$2"
    [[ -f "$source" ]] || die "required release input is missing: $source"
    [[ ! -L "$source" ]] || die "release input must not be a symbolic link: $source"
    local destination="$release_tmp/$relative_destination"
    mkdir -p "$(dirname "$destination")"
    cp -p "$source" "$destination"
    [[ -f "$destination" && ! -L "$destination" ]] || die "failed to create a regular candidate file: $relative_destination"
}

echo "Building contracts from source SHA $source_sha..."
npm --workspace packages/contracts run build
echo 'Building API from the same source tree...'
npm --workspace services/api run build

echo 'Publishing the self-contained win-x64 service host...'
dotnet publish "$repo_root/services/windows-service-host/src/LifeOS.ServiceHost.csproj" \
    -c Release \
    -r win-x64 \
    --self-contained true \
    --no-restore \
    -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:PublishTrimmed=false \
    -o "$publish_tmp"
[[ -f "$publish_tmp/LifeOS.ServiceHost.exe" ]] || die 'dotnet publish did not produce LifeOS.ServiceHost.exe'

api_dist_files=(
    atomic-file.js
    calendar-store.js
    claude-ingest.js
    clipper-store.js
    codex-adapter.js
    codex-collector.js
    finance-connectors.js
    history.js
    ingest-secret.js
    json-boundary.js
    nutrition-photo.js
    open-food-facts.js
    projection.js
    server.js
)
for file in "${api_dist_files[@]}"; do
    copy_file "$repo_root/services/api/dist/$file" "api/dist/$file"
done

contract_dist_files=(
    clipper.js
    fitness-retention.js
    index.js
    nutrition-barcode.js
    nutrition-benchmark.js
    nutrition.js
    supplements.js
    sync.js
    usage.js
)
for file in "${contract_dist_files[@]}"; do
    copy_file "$repo_root/packages/contracts/dist/$file" "api/node_modules/@iphone-life-os/contracts/dist/$file"
done
copy_file "$repo_root/packages/contracts/package.json" 'api/node_modules/@iphone-life-os/contracts/package.json'

zod_root_files=(package.json index.cjs index.js)
for file in "${zod_root_files[@]}"; do
    copy_file "$repo_root/node_modules/zod/$file" "api/node_modules/zod/$file"
done
zod_files=(
    v3/ZodError.cjs
    v3/ZodError.js
    v3/errors.cjs
    v3/errors.js
    v3/external.cjs
    v3/external.js
    v3/helpers/enumUtil.cjs
    v3/helpers/enumUtil.js
    v3/helpers/errorUtil.cjs
    v3/helpers/errorUtil.js
    v3/helpers/parseUtil.cjs
    v3/helpers/parseUtil.js
    v3/helpers/partialUtil.cjs
    v3/helpers/partialUtil.js
    v3/helpers/typeAliases.cjs
    v3/helpers/typeAliases.js
    v3/helpers/util.cjs
    v3/helpers/util.js
    v3/index.cjs
    v3/index.js
    v3/locales/en.cjs
    v3/locales/en.js
    v3/standard-schema.cjs
    v3/standard-schema.js
    v3/types.cjs
    v3/types.js
)
for file in "${zod_files[@]}"; do
    copy_file "$repo_root/node_modules/zod/$file" "api/node_modules/zod/$file"
done

# The staged API package must not retain the source workspace's file:../../
# dependency. It is already wired to the copied production contracts package.
python3 - "$repo_root/services/api/package.json" "$release_tmp/api/package.json" <<'PY'
import json
import sys
from pathlib import Path

source_path, destination_path = map(Path, sys.argv[1:])
source = json.loads(source_path.read_text(encoding="utf-8"))
if source.get("name") != "@iphone-life-os/api" or source.get("version") != "0.1.0":
    raise SystemExit("source API package metadata is not the reviewed release")
dependencies = source.get("dependencies") or {}
zod = dependencies.get("zod")
if not isinstance(zod, str) or zod.startswith("file:"):
    raise SystemExit("source API package has an invalid zod dependency")
release = {
    "name": source["name"],
    "version": source["version"],
    "private": True,
    "type": "module",
    "dependencies": {
        "@iphone-life-os/contracts": "0.1.0",
        "zod": zod,
    },
}
destination_path.write_text(json.dumps(release, separators=(",", ":")) + "\n", encoding="utf-8")
PY

gateway_files=(
    main.py
    enablebanking.py
    supplement_catalog.py
    supplement_catalog_schema.sql
    supplement_catalog_seed.sql
    requirements.txt
    test_enablebanking.py
    test_gateway.py
    test_gateway_launcher.py
    test_supplement_catalog.py
)
for file in "${gateway_files[@]}"; do
    copy_file "$repo_root/services/gateway/$file" "gateway/$file"
done
# test_gateway_launcher.py is currently repository-relative. Keep this exact
# reviewed launcher copy only as a test fixture compatibility path; install.ps1
# deploys the production launcher from deploy/, not this staging-only copy.
copy_file "$repo_root/services/windows-service-host/deploy/gateway_launcher.py" \
    'windows-service-host/deploy/gateway_launcher.py'

deploy_files=(
    Deployment.Common.ps1
    README.md
    gateway_launcher.py
    install.ps1
    preflight.ps1
    rollback.ps1
    verify-candidate.ps1
    verify.ps1
)
for file in "${deploy_files[@]}"; do
    copy_file "$repo_root/services/windows-service-host/deploy/$file" "deploy/$file"
done
deploy_test_files=(
    Deployment.Behavior.Tests.ps1
    Deployment.LegacyServe.Tests.ps1
    Deployment.Static.Tests.ps1
)
for file in "${deploy_test_files[@]}"; do
    copy_file "$repo_root/services/windows-service-host/deploy/tests/$file" "deploy/tests/$file"
done

copy_file "$node_source" 'node-runtime/node.exe'
copy_file "$publish_tmp/LifeOS.ServiceHost.exe" 'service-host/LifeOS.ServiceHost.exe'

printf '%s\n' "$source_sha" > "$release_tmp/SOURCE_SHA.txt"

python3 - "$release_tmp" "$release_tmp/CANDIDATE-MANIFEST.sha256" <<'PY'
import hashlib
import os
import sys
from pathlib import Path

root, manifest_path = map(Path, sys.argv[1:])
entries = []
for path in root.rglob("*"):
    if path.is_symlink():
        raise SystemExit(f"candidate contains a symbolic link: {path}")
    if path.is_file() and path.name != "CANDIDATE-MANIFEST.sha256":
        relative = path.relative_to(root).as_posix()
        if (
            "\n" in relative
            or "\r" in relative
            or relative.startswith("/")
            or any(part in {"", ".", ".."} for part in relative.split("/"))
        ):
            raise SystemExit(f"candidate path is unsafe: {relative}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        entries.append((relative, digest))
entries.sort(key=lambda item: item[0])
manifest_path.write_text(
    "".join(f"{digest}  ./{relative}\n" for relative, digest in entries),
    encoding="utf-8",
)
if not entries:
    raise SystemExit("candidate manifest is unexpectedly empty")
PY

python3 - "$release_tmp" "$source_sha" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected_sha = sys.argv[2]
source_file = root / "SOURCE_SHA.txt"
if source_file.read_text(encoding="utf-8") != expected_sha + "\n":
    raise SystemExit("SOURCE_SHA.txt failed the builder self-check")
manifest = root / "CANDIDATE-MANIFEST.sha256"
lines = manifest.read_text(encoding="utf-8").splitlines()
listed = []
for line in lines:
    digest, separator, relative = line.partition("  ./")
    if separator != "  ./" or len(digest) != 64:
        raise SystemExit("candidate manifest failed the builder self-check")
    candidate_path = root / relative
    if not candidate_path.is_file() or candidate_path.is_symlink():
        raise SystemExit(f"candidate manifest names an invalid file: {relative}")
    if hashlib.sha256(candidate_path.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"candidate manifest hash mismatch: {relative}")
    listed.append(relative)
actual = sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() and path.name != manifest.name)
if listed != sorted(listed) or listed != actual:
    raise SystemExit("candidate manifest file set is not deterministic")
PY

if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$release_tmp/deploy/verify-candidate.ps1" \
        -Root "$release_tmp" \
        -ExpectedSourceSha "$source_sha"
else
    echo 'PowerShell is unavailable on this build host; run deploy/verify-candidate.ps1 on Windows before staging.' >&2
fi

archive_tmp="$work_root/lifeos-release-$source_sha.zip"
python3 - "$release_tmp" "$archive_tmp" <<'PY'
import stat
import sys
import zipfile
from pathlib import Path

root, archive_path = map(Path, sys.argv[1:])
files = sorted(path for path in root.rglob("*") if path.is_file())
with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in files:
        relative = path.relative_to(root).as_posix()
        info = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        mode = stat.S_IFREG | (0o755 if path.suffix.lower() == ".exe" else 0o644)
        info.external_attr = mode << 16
        archive.writestr(info, path.read_bytes())
PY

mv "$release_tmp" "$final_release"
mv "$archive_tmp" "$final_archive"
python3 - "$final_archive" "$final_archive_hash" <<'PY'
import hashlib
import sys
from pathlib import Path

archive, sidecar = map(Path, sys.argv[1:])
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
sidecar.write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
PY

echo "Candidate directory: $final_release"
echo "Candidate archive:  $final_archive"
echo "Archive SHA-256:    $(python3 - "$final_archive" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
