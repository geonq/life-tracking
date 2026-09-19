#!/bin/bash
set -euo pipefail
umask 077

REPO_ROOT="$(git rev-parse --show-toplevel)"
COMMAND="${1:-}"
RUN="${2:-}"

die() {
  printf 'PACKET_C_PROBE_BLOCKED code=%s\n' "$1" >&2
  exit 2
}

if [[ "$COMMAND" != "prepare" && "$COMMAND" != "crash" ]]; then
  die usage
fi
if [[ -z "$RUN" || "$RUN" == / || "$RUN" == "$REPO_ROOT" || "$RUN" == "$REPO_ROOT"/* ]]; then
  die unsafeRunPath
fi

ALLOWED=(
  ios/Planning/PlanningMutationJournal.swift
  ios/Planning/PlanningPublicationDomain.swift
  ios/Planning/PlanningFilesystemDomain.swift
  ios/Planning/PlanningVaultAccess.swift
  ios/Planning/PlanningSafeFileIO.swift
  ios/Planning/PlanningCoordinatedAccess.swift
  ios/Planning/PlanningFilesystemPublication.swift
  ios/Planning/PlanningVaultCache.swift
  ios/Planning/PlanningVaultStore.swift
  ios/Planning/PlanningNativeDocumentPicker.swift
  ios/LifeOSTests/PlanningFilesystemTests.swift
  ios/LifeOSMacSnapshotTests/PlanningFilesystemTests.swift
  scripts/planning_packet_c_probe.swift
  scripts/run_planning_packet_c_probes.sh
  artifacts/final/planning-core/packet-c-publication-20260919.md
)

is_allowed() {
  local candidate="$1"
  local allowed
  for allowed in "${ALLOWED[@]}"; do
    [[ "$candidate" == "$allowed" ]] && return 0
  done
  return 1
}

verify_workspace() {
  local line path
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    path="${line:3}"
    is_allowed "$path" || die "unauthorizedDiff.$path"
  done < <(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

prepare() {
  [[ ! -e "$RUN" ]] || die runAlreadyExists
  verify_workspace
  mkdir -p "$RUN/src" "$RUN/logs"
  git -C "$REPO_ROOT" archive --format=tar HEAD | tar -x -C "$RUN/src"

  local relative destination
  : > "$RUN/prepare-manifest.txt"
  for relative in "${ALLOWED[@]}"; do
    [[ -f "$REPO_ROOT/$relative" ]] || die "missingAllowed.$relative"
    destination="$RUN/src/$relative"
    mkdir -p "$(dirname "$destination")"
    cp -p "$REPO_ROOT/$relative" "$destination"
    printf '%s %s\n' "$(sha256 "$REPO_ROOT/$relative")" "$relative" >> "$RUN/prepare-manifest.txt"
  done

  (cd "$RUN/src/ios" && xcodegen generate) > "$RUN/logs/prepare-xcodegen.log" 2>&1 || {
    printf 'PACKET_C_PROBE_BLOCKED code=xcodegenFailed\n' >&2
    exit 2
  }
  [[ -f "$RUN/src/ios/LifeOS.xcodeproj/project.pbxproj" ]] || die generatedProjectMissing
  printf 'PACKET_C_PROBE_PREPARED run=%s\n' "$RUN"
  printf 'PACKET_C_PROBE_SOURCE=%s\n' "$RUN/src"
  printf 'PACKET_C_PROBE_PROJECT=%s\n' "$RUN/src/ios/LifeOS.xcodeproj"
  printf 'PACKET_C_PROBE_MANIFEST=%s\n' "$RUN/prepare-manifest.txt"
}

crash() {
  [[ -d "$RUN/src/ios" && -f "$RUN/src/ios/LifeOS.xcodeproj/project.pbxproj" ]] || die preparedRunMissing
  mkdir -p "$RUN/logs"
  local binary="$RUN/planning_packet_c_probe"
  local planning_files=("$RUN/src/ios/Planning/"*.swift)
  [[ -f "${planning_files[0]}" ]] || die planningSourcesMissing
  xcrun swiftc \
    -module-name PlanningPacketCProbe \
    -parse-as-library \
    -o "$binary" \
    "${planning_files[@]}" \
    "$RUN/src/scripts/planning_packet_c_probe.swift" \
    -framework Foundation \
    -framework AppKit \
    -lsqlite3 \
    > "$RUN/logs/probe-compile.log" 2>&1 || {
      printf 'PACKET_C_PROBE_BLOCKED code=swiftcFailed log=%s\n' "$RUN/logs/probe-compile.log" >&2
      exit 2
    }
  "$binary" --parent "$RUN/probe-runtime" > "$RUN/logs/probe-run.log" 2>&1 || {
    printf 'PACKET_C_PROBE_FAILED code=childOrAdversaryFailure log=%s\n' "$RUN/logs/probe-run.log" >&2
    exit 1
  }
  printf 'PACKET_C_PROBE_PASS compileLog=%s runLog=%s\n' "$RUN/logs/probe-compile.log" "$RUN/logs/probe-run.log"
}

case "$COMMAND" in
  prepare) prepare ;;
  crash) crash ;;
esac
