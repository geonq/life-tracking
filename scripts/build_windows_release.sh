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
  --wheelhouse PATH   reviewed Windows CPython 3.12 wheelhouse; no downloads
  --output-dir PATH   destination for lifeos-release-SHA and its zip (default: /private/tmp)
EOF
}

die() {
    echo "build_windows_release: $*" >&2
    exit 1
}

# Keep the packaging policy byte-for-byte aligned with the Windows candidate
# verifier. Only the exact standalone runtime destination gets the larger
# allowance; every other candidate file is capped at 64 MiB.
candidate_max_file_bytes=$((64 * 1024 * 1024))
candidate_node_max_file_bytes=$((256 * 1024 * 1024))
candidate_service_host_max_file_bytes=$((256 * 1024 * 1024))

candidate_file_max_bytes() {
    case "$1" in
        node-runtime/node.exe)
            printf '%s\n' "$candidate_node_max_file_bytes"
            ;;
        service-host/LifeOS.ServiceHost.exe)
            printf '%s\n' "$candidate_service_host_max_file_bytes"
            ;;
        *)
            printf '%s\n' "$candidate_max_file_bytes"
            ;;
    esac
}

file_size_bytes() {
    local path="$1"
    local size
    size="$(wc -c < "$path")"
    size="${size//[[:space:]]/}"
    [[ "$size" =~ ^[0-9]+$ ]] || die "could not determine candidate input size: $path"
    printf '%s\n' "$size"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
output_dir="/private/tmp"
node_source=""
wheelhouse_source=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-source)
            [[ $# -ge 2 ]] || { usage; die '--node-source requires a path'; }
            node_source="$2"
            shift 2
            ;;
        --wheelhouse)
            [[ $# -ge 2 ]] || { usage; die '--wheelhouse requires a path'; }
            wheelhouse_source="$2"
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

# The Windows installer receives only a trusted base Python runtime separately.
# The builder never downloads packages or copies a venv. It authenticates the
# supplied, immutable wheelhouse and stages the exact artifacts named by the
# lock so the installer can recreate a fresh venv with --require-hashes.
gateway_lock_source="$repo_root/services/gateway/requirements.lock"
[[ -f "$gateway_lock_source" ]] || die 'gateway dependency lock is missing'
[[ ! -L "$gateway_lock_source" ]] || die 'gateway dependency lock must not be a symbolic link'
gateway_lock_sha="$(python3 - "$gateway_lock_source" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

lock_path = Path(sys.argv[1])
lock_bytes = lock_path.read_bytes()
if len(lock_bytes) > 1024 * 1024:
    raise SystemExit("gateway dependency lock exceeds its bounded size")
lock_text = lock_bytes.decode("utf-8")
if lock_text.startswith("\ufeff") or not lock_text.endswith("\n"):
    raise SystemExit("gateway dependency lock encoding is not canonical")
entry_pattern = re.compile(
    r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}=="
    r"[A-Za-z0-9][A-Za-z0-9.!+_-]{0,127}\s+"
    r"--hash=sha256:[0-9a-f]{64}"
    r"\s+#\s+[A-Za-z0-9][A-Za-z0-9._+!-]{0,255}\.whl\Z"
)
seen = set()
last_name = None
for line_number, line in enumerate(lock_text.splitlines(), 1):
    if len(line) > 1024:
        raise SystemExit(f"gateway dependency lock line {line_number} is oversized")
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    if entry_pattern.fullmatch(line) is None:
        raise SystemExit(f"gateway dependency lock line {line_number} is not canonical")
    raw_name = line.split("==", 1)[0]
    normalized = re.sub(r"[-_.]+", "-", raw_name).lower()
    if normalized in seen:
        raise SystemExit("gateway dependency lock contains duplicate normalized names")
    if last_name is not None and normalized <= last_name:
        raise SystemExit("gateway dependency lock is not sorted by normalized name")
    seen.add(normalized)
    last_name = normalized
if not seen:
    raise SystemExit("gateway dependency lock is empty")
print(hashlib.sha256(lock_bytes).hexdigest())
PY
)"
[[ "$gateway_lock_sha" =~ ^[0-9a-f]{64}$ ]] || die 'gateway dependency lock digest was not produced'

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

[[ -n "$wheelhouse_source" ]] || die 'pass --wheelhouse with a reviewed Windows CPython 3.12 wheelhouse; the builder never downloads packages'
[[ -d "$wheelhouse_source" ]] || die "wheelhouse is not a directory: $wheelhouse_source"
[[ ! -L "$wheelhouse_source" ]] || die 'wheelhouse must not be a symbolic link'
wheelhouse_source="$(cd "$wheelhouse_source" && pwd -P)"
[[ "$wheelhouse_source" != "$repo_root" && "$wheelhouse_source" != "$repo_root/"* ]] || die 'wheelhouse must be outside the repository worktree'

[[ -n "$node_source" ]] || die 'pass --node-source with a standalone Windows node.exe; the builder never copies a user Hermes node tree'
if [[ -d "$node_source" ]]; then
    node_source="$node_source/node.exe"
fi
[[ -f "$node_source" ]] || die "Node source is not a file: $node_source"
[[ ! -L "$node_source" ]] || die 'Node source must not be a symbolic link'
node_source="$(cd "$(dirname "$node_source")" && pwd -P)/$(basename "$node_source")"
node_size="$(file_size_bytes "$node_source")"
# Keep this equal to LifeOSCandidateNodeMaxFileBytes in Deployment.Common.ps1;
# the candidate verifier grants this larger bound only to node-runtime/node.exe.
(( node_size <= candidate_node_max_file_bytes )) || die 'Node source is unexpectedly large; pass only the standalone node.exe, never the Hermes runtime tree'
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

# Validate the wheelhouse before any build output is staged. The Python helper
# uses lstat for every path component and rejects symlinks, nested entries,
# non-wheel files, malformed wheels, incompatible tags, hash mismatches, and
# extras. Its bounded tab-separated index contains only safe wheel basenames.
wheelhouse_contract="$work_root/wheelhouse.contract"
python3 - "$gateway_lock_source" "$wheelhouse_source" "$repo_root" "$wheelhouse_contract" <<'PY'
import hashlib
import os
import re
import stat
import sys
import zipfile
from pathlib import Path

lock_path, wheelhouse_path, repo_path, contract_path = map(Path, sys.argv[1:])
MAX_LOCK_BYTES = 1024 * 1024
MAX_LINE_BYTES = 1024
MAX_PACKAGES = 1024
MAX_WHEEL_BYTES = 64 * 1024 * 1024
MAX_WHEEL_MEMBERS = 4096
MAX_WHEEL_UNCOMPRESSED_BYTES = 256 * 1024 * 1024
LOCK_ENTRY = re.compile(
    r"\A(?P<name>[A-Za-z0-9][A-Za-z0-9._-]{0,127})=="
    r"(?P<version>[A-Za-z0-9][A-Za-z0-9.!+_-]{0,127})\s+"
    r"--hash=sha256:(?P<hash>[0-9a-f]{64})\s+#\s+"
    r"(?P<wheel>[A-Za-z0-9][A-Za-z0-9._+!-]{0,255}\.whl)\Z"
)
WHEEL_NAME = re.compile(
    r"\A(?P<distribution>[A-Za-z0-9][A-Za-z0-9._-]{0,127})-"
    r"(?P<version>[A-Za-z0-9][A-Za-z0-9.!+_-]{0,127})-"
    r"(?P<python>[A-Za-z0-9.]+)-(?P<abi>[A-Za-z0-9]+)-"
    r"(?P<platform>[A-Za-z0-9_]+)\.whl\Z"
)


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def reject_path_redirection(path: Path, label: str) -> None:
    absolute = path.absolute()
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        info = os.lstat(current)
        if stat.S_ISLNK(info.st_mode):
            raise SystemExit(f"{label} contains a symbolic link: {current}")


def read_lock() -> list[dict[str, str]]:
    reject_path_redirection(lock_path, "gateway dependency lock")
    lock_bytes = lock_path.read_bytes()
    if len(lock_bytes) > MAX_LOCK_BYTES:
        raise SystemExit("gateway dependency lock exceeds its bounded size")
    text = lock_bytes.decode("utf-8")
    if text.startswith("\ufeff") or not text.endswith("\n"):
        raise SystemExit("gateway dependency lock encoding is not canonical")
    result: list[dict[str, str]] = []
    seen: set[str] = set()
    last_name = ""
    for line_number, line in enumerate(text.splitlines(), 1):
        if len(line.encode("utf-8")) > MAX_LINE_BYTES:
            raise SystemExit(f"gateway dependency lock line {line_number} is oversized")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = LOCK_ENTRY.fullmatch(line)
        if match is None:
            raise SystemExit(
                f"gateway dependency lock line {line_number} must name its reviewed wheel"
            )
        values = match.groupdict()
        normalized = normalize(values["name"])
        if normalized in seen or (last_name and normalized <= last_name):
            raise SystemExit("gateway dependency lock is not unique and sorted")
        wheel_match = WHEEL_NAME.fullmatch(values["wheel"])
        if wheel_match is None:
            raise SystemExit(f"invalid reviewed wheel filename: {values['wheel']}")
        wheel_values = wheel_match.groupdict()
        if normalize(wheel_values["distribution"]) != normalized:
            raise SystemExit(f"wheel distribution does not match lock: {values['wheel']}")
        if wheel_values["version"] != values["version"]:
            raise SystemExit(f"wheel version does not match lock: {values['wheel']}")
        tag = (wheel_values["python"], wheel_values["abi"], wheel_values["platform"])
        pure = tag in {("py3", "none", "any"), ("py2.py3", "none", "any")}
        abi3_windows = (
            wheel_values["platform"] == "win_amd64"
            and wheel_values["python"].startswith("cp")
            and wheel_values["python"][2:].isdigit()
            and wheel_values["abi"] == "abi3"
        )
        cp312_windows = tag == ("cp312", "cp312", "win_amd64")
        if not (pure or abi3_windows or cp312_windows):
            raise SystemExit(f"wheel is not compatible with Windows CPython 3.12: {values['wheel']}")
        values.update(
            normalized=normalized,
            python_tag=wheel_values["python"],
            abi_tag=wheel_values["abi"],
            platform_tag=wheel_values["platform"],
        )
        result.append(values)
        seen.add(normalized)
        last_name = normalized
        if len(result) > MAX_PACKAGES:
            raise SystemExit("gateway dependency lock contains too many packages")
    if not result:
        raise SystemExit("gateway dependency lock is empty")
    return result


def validate_wheel(path: Path, expected: dict[str, str]) -> int:
    size = path.stat().st_size
    if size <= 0 or size > MAX_WHEEL_BYTES:
        raise SystemExit(f"wheel exceeds its bounded size: {path.name}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected["hash"]:
        raise SystemExit(f"wheel hash does not match the lock: {path.name}")
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            if not members or len(members) > MAX_WHEEL_MEMBERS:
                raise SystemExit(f"wheel member count is outside its bound: {path.name}")
            expanded = 0
            member_names = set()
            metadata_names = []
            wheel_metadata_names = []
            for member in members:
                name = member.filename
                pieces = name.split("/")
                if name in member_names:
                    raise SystemExit(f"wheel contains duplicate members: {path.name}")
                member_names.add(name)
                if (
                    not name
                    or "\\" in name
                    or name.startswith("/")
                    or re.match(r"[A-Za-z]:", name)
                    or any(piece in {"", ".", ".."} for piece in pieces)
                    or (stat.S_IFMT(member.external_attr >> 16) == stat.S_IFLNK)
                ):
                    raise SystemExit(f"wheel contains an unsafe member: {path.name}")
                expanded += max(0, member.file_size)
                if member.file_size > MAX_WHEEL_BYTES or expanded > MAX_WHEEL_UNCOMPRESSED_BYTES:
                    raise SystemExit(f"wheel expands beyond its bounded size: {path.name}")
                if name.endswith(".dist-info/METADATA"):
                    metadata_names.append(name)
                if name.endswith(".dist-info/WHEEL"):
                    wheel_metadata_names.append(name)
            if len(metadata_names) != 1 or len(wheel_metadata_names) != 1:
                raise SystemExit(f"wheel metadata is incomplete: {path.name}")
            metadata = archive.read(metadata_names[0])
            wheel_metadata = archive.read(wheel_metadata_names[0])
    except zipfile.BadZipFile as exc:
        raise SystemExit(f"wheel is not a valid ZIP archive: {path.name}") from exc
    if len(metadata) > 1024 * 1024 or len(wheel_metadata) > 1024 * 1024:
        raise SystemExit(f"wheel metadata exceeds its bound: {path.name}")
    fields: dict[str, str] = {}
    for line in metadata.decode("utf-8").splitlines():
        key, separator, value = line.partition(":")
        if separator and key in {"Name", "Version"} and key not in fields:
            fields[key] = value.strip()
    if normalize(fields.get("Name", "")) != expected["normalized"] or fields.get("Version") != expected["version"]:
        raise SystemExit(f"wheel METADATA does not match the lock: {path.name}")
    tags = {
        line[4:].strip()
        for line in wheel_metadata.decode("utf-8").splitlines()
        if line.startswith("Tag:")
    }
    expected_tag = "-".join((expected["python_tag"], expected["abi_tag"], expected["platform_tag"]))
    if expected_tag not in tags:
        raise SystemExit(f"wheel WHEEL tags do not match the lock: {path.name}")
    return size


reject_path_redirection(wheelhouse_path, "wheelhouse")
if not wheelhouse_path.is_dir():
    raise SystemExit("wheelhouse is not a directory")
if wheelhouse_path.resolve().is_relative_to(repo_path.resolve()):
    raise SystemExit("wheelhouse must be outside the repository worktree")
expected = read_lock()
expected_by_name = {item["wheel"]: item for item in expected}
actual: list[str] = []
for entry in os.scandir(wheelhouse_path):
    entry_path = Path(entry.path)
    info = os.lstat(entry_path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise SystemExit(f"wheelhouse contains a non-regular entry: {entry.name}")
    if entry.name not in expected_by_name:
        raise SystemExit(f"wheelhouse contains an unreviewed artifact: {entry.name}")
    actual.append(entry.name)
if sorted(actual) != sorted(expected_by_name):
    raise SystemExit("wheelhouse does not contain exactly one artifact per locked package")
contract_lines: list[str] = []
for item in expected:
    wheel_path = wheelhouse_path / item["wheel"]
    wheel_size = validate_wheel(wheel_path, item)
    contract_lines.append(f"{item['wheel']}\t{item['hash']}\t{wheel_size}\n")
contract_path.write_text("".join(contract_lines), encoding="utf-8")
PY

copy_file() {
    local source="$1"
    local relative_destination="$2"
    [[ -f "$source" ]] || die "required release input is missing: $source"
    [[ ! -L "$source" ]] || die "release input must not be a symbolic link: $source"
    local max_bytes
    max_bytes="$(candidate_file_max_bytes "$relative_destination")"
    local source_size
    source_size="$(file_size_bytes "$source")"
    (( source_size <= max_bytes )) || die "candidate input exceeds its bounded size: $relative_destination"
    local destination="$release_tmp/$relative_destination"
    mkdir -p "$(dirname "$destination")"
    cp -p "$source" "$destination"
    [[ -f "$destination" && ! -L "$destination" ]] || die "failed to create a regular candidate file: $relative_destination"
    local destination_size
    destination_size="$(file_size_bytes "$destination")"
    (( destination_size <= max_bytes )) || die "staged candidate file exceeds its bounded size: $relative_destination"
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
    local-auth.js
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
if source_path.stat().st_size > 64 * 1024 * 1024:
    raise SystemExit("source API package metadata exceeds the candidate file bound")
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
if destination_path.stat().st_size > 64 * 1024 * 1024:
    raise SystemExit("staged API package metadata exceeds the candidate file bound")
PY

# Validate the staged package, never workspace module resolution or operator
# credentials. NODE_ENV=test prevents executable module imports starting writers.
node_binary="$(command -v node)"
env -i NODE_ENV=test "$node_binary" --input-type=module - "$release_tmp" <<'JS'
import { readdir } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
async function modules(directory) {
    for (const entry of (await readdir(directory, {withFileTypes: true})).sort((a, b) => a.name.localeCompare(b.name))) {
        const file = path.join(directory, entry.name);
        if (entry.isDirectory()) await modules(file);
        else if (/\.(?:js|cjs)$/.test(entry.name)) await import(pathToFileURL(file).href);
    }
}
try {
    for (const relative of ['api/dist', 'api/node_modules/@iphone-life-os/contracts/dist', 'api/node_modules/zod']) {
        await modules(path.join(root, relative));
    }
} catch {
    // Module exceptions can contain source or environment values. Never echo them.
    console.error('Staged JavaScript import closure failed.');
    process.exitCode = 1;
}
JS

gateway_files=(
    main.py
    enablebanking.py
    supplement_catalog.py
    supplement_catalog_schema.sql
    supplement_catalog_seed.sql
    requirements.txt
    requirements.lock
    test_enablebanking.py
    test_gateway.py
    test_gateway_launcher.py
    test_supplement_catalog.py
)
for file in "${gateway_files[@]}"; do
    copy_file "$repo_root/services/gateway/$file" "gateway/$file"
done
python3 - "$release_tmp/gateway/requirements.lock" "$gateway_lock_sha" <<'PY'
import hashlib
import sys
from pathlib import Path

lock_path = Path(sys.argv[1])
expected_sha = sys.argv[2]
actual_sha = hashlib.sha256(lock_path.read_bytes()).hexdigest()
if actual_sha != expected_sha:
    raise SystemExit("staged gateway dependency lock digest mismatch")
PY

# Stage only the wheel basenames returned by the authenticated contract. The
# explicit allowlist is kept beside the wheelhouse so the Windows verifier and
# installer can bind the same set without trusting directory enumeration order.
wheelhouse_target="$release_tmp/gateway/wheelhouse"
mkdir -p "$wheelhouse_target"
while IFS=$'\t' read -r wheel_name wheel_sha wheel_size; do
    [[ -n "$wheel_name" && "$wheel_name" != */* && "$wheel_name" != *$'\n'* ]] || die 'wheelhouse contract contains an unsafe artifact name'
    [[ "$wheel_sha" =~ ^[0-9a-f]{64}$ && "$wheel_size" =~ ^[1-9][0-9]*$ ]] || die 'wheelhouse contract contains invalid artifact metadata'
    copy_file "$wheelhouse_source/$wheel_name" "gateway/wheelhouse/$wheel_name"
done < "$wheelhouse_contract"
python3 - "$wheelhouse_contract" "$wheelhouse_target" "$wheelhouse_target/ALLOWLIST.sha256" <<'PY'
import hashlib
import os
import sys
from pathlib import Path

contract_path, target, allowlist_path = map(Path, sys.argv[1:])
expected: list[tuple[str, str, int]] = []
for line in contract_path.read_text(encoding="utf-8").splitlines():
    name, digest, size_text = line.split("\t")
    expected.append((name, digest, int(size_text)))
expected_names = {name for name, _, _ in expected}
actual_names = set()
for entry in os.scandir(target):
    if entry.name == "ALLOWLIST.sha256":
        continue
    if not entry.is_file(follow_symlinks=False) or entry.name not in expected_names:
        raise SystemExit("staged wheelhouse contains an unexpected entry")
    actual_names.add(entry.name)
if actual_names != expected_names:
    raise SystemExit("staged wheelhouse file set does not match its contract")
for name, expected_digest, expected_size in expected:
    path = target / name
    if path.stat().st_size != expected_size:
        raise SystemExit(f"staged wheel size changed: {name}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected_digest:
        raise SystemExit(f"staged wheel hash changed: {name}")
allowlist_path.write_text(
    "".join(
        f"{digest}  ./{name}\n"
        for name, digest, _ in sorted(expected, key=lambda item: item[0])
    ),
    encoding="utf-8",
)
PY
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
    tailscale_snapshot.ps1
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
        if relative == "node-runtime/node.exe":
            max_bytes = 256 * 1024 * 1024
        elif relative == "service-host/LifeOS.ServiceHost.exe":
            max_bytes = 256 * 1024 * 1024
        else:
            max_bytes = 64 * 1024 * 1024
        if path.stat().st_size > max_bytes:
            raise SystemExit(f"candidate file exceeds its bounded size: {relative}")
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
