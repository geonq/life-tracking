#!/bin/bash -p
set -euo pipefail
IFS=$'\n\t'

# LifeOS native builds are deliberately serialized. This command is a bounded,
# manual maintenance pass for generated Apple artifacts; it never touches
# source, personal data, or an active simulator by default.

readonly ROOT="$(builtin cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
readonly DEVELOPER_ROOT="${LIFEOS_DEVELOPER_ROOT:-$HOME/Library/Developer}"
readonly DERIVED_DATA_ROOT="${LIFEOS_DERIVED_DATA_ROOT:-$DEVELOPER_ROOT/Xcode/DerivedData}"
readonly DEVICE_SUPPORT_ROOT="${LIFEOS_DEVICE_SUPPORT_ROOT:-$DEVELOPER_ROOT/Xcode/iOS DeviceSupport}"
readonly ARCHIVES_ROOT="${LIFEOS_ARCHIVES_ROOT:-$DEVELOPER_ROOT/Xcode/Archives}"
readonly KEEP_SIMULATOR_UDID="${LIFEOS_KEEP_SIMULATOR_UDID:-FE7DBF30-8478-48A3-AB6C-3E472F9E0FEA}"
readonly KEEP_SIMULATOR_NAME="${LIFEOS_KEEP_SIMULATOR_NAME:-iPhone 17}"
readonly KEEP_DEVICE_SUPPORT_PREFIX="${LIFEOS_KEEP_DEVICE_SUPPORT_PREFIX:-iPhone18,3}"
readonly MIN_FREE_GIB="${LIFEOS_MIN_FREE_GIB:-15}"
# Tests may point this at a deterministic probe. Production defaults to the
# system binary and treats every status other than "no matching process" as
# an inability to prove that destructive cleanup is safe.
readonly PGREP_PATH="${LIFEOS_PGREP_PATH:-/usr/bin/pgrep}"

apply_changes=0
check_free_space=0
clear_derived_data=0
clear_all_derived_data=0
clear_repo_artifacts=0
prune_simulators=0
prune_device_support=0

usage() {
    /bin/cat <<'EOF'
Usage: scripts/maintain_macos_storage.sh [options]

Default mode reports sizes and planned candidates without deleting anything.

Options:
  --apply                    perform the explicitly selected cleanup actions
  --check                   fail if the home volume has less than 15 GiB free
  --clear-derived-data      remove LifeOS-* global Xcode DerivedData
  --clear-all-derived-data  remove every global Xcode DerivedData directory
  --clear-repo-artifacts    remove generated LifeOS validation artifacts
  --prune-simulators        delete shutdown/unavailable simulators except the kept iPhone
  --prune-device-support    remove iOS DeviceSupport outside the kept device prefix
  --help                    show this help

The destructive actions require --apply. A booted simulator is always skipped.
Override the kept iPhone with LIFEOS_KEEP_SIMULATOR_UDID and the physical-device
support prefix with LIFEOS_KEEP_DEVICE_SUPPORT_PREFIX when hardware changes.
EOF
}

die() {
    builtin printf 'LifeOS storage: %s\n' "$1" >&2
    exit 2
}

show_size() {
    local label="$1"
    local path="$2"
    if [[ -e "$path" ]]; then
        local size
        size="$(/usr/bin/du -sh "$path" 2>/dev/null | /usr/bin/awk '{print $1}')"
        builtin printf '%s: %s\n' "$label" "${size:-unknown}"
    else
        builtin printf '%s: absent\n' "$label"
    fi
}

free_bytes() {
    local free_kib
    free_kib="$(/bin/df -k "$HOME" | /usr/bin/awk 'NR == 2 { print $4 }')"
    [[ "$free_kib" =~ ^[0-9]+$ ]] || die 'could not read free home-volume space'
    builtin printf '%s\n' "$((free_kib * 1024))"
}

safe_remove_directory() {
    local path="$1"
    [[ -n "$path" && -d "$path" && ! -L "$path" ]] || return 0
    case "$path" in
        "$DERIVED_DATA_ROOT"/*|"$DEVICE_SUPPORT_ROOT"/*|\
        "$ROOT/artifacts/apple-validation"|"$ROOT/artifacts/apple-validation"/*|\
        "$ROOT/artifacts/apple-prerelease"|"$ROOT/artifacts/apple-prerelease"/*|\
        "$ROOT/ios/DerivedData"|"$ROOT/ios/DerivedData"/*)
            ;;
        *)
            die "refusing an unscoped deletion: $path"
            ;;
    esac
    if [[ "$apply_changes" -eq 1 ]]; then
        /bin/rm -rf -- "$path"
        builtin printf 'REMOVED: %s\n' "$path"
    else
        builtin printf 'PLAN: remove %s\n' "$path"
    fi
}

print_simulators() {
    if [[ ! -x /usr/bin/xcrun ]]; then
        builtin printf 'Simulators: xcrun unavailable\n'
        return 0
    fi
    local simulator_json
    if ! simulator_json="$(/usr/bin/xcrun simctl list devices -j 2>/dev/null)"; then
        builtin printf 'Simulators: unavailable (CoreSimulatorService is not responding)\n'
        return 0
    fi
    local rows
    if ! rows="$(builtin printf '%s' "$simulator_json" | /usr/bin/python3 -c '
import json
import sys

payload = json.load(sys.stdin)
keep_uuid, keep_name = sys.argv[1:]
devices = [device for entries in payload.get("devices", {}).values() for device in entries]
uuid_exists = any(device.get("udid") == keep_uuid for device in devices)
for device in devices:
    udid = device.get("udid", "")
    name = device.get("name", "")
    state = device.get("state", "Unknown")
    available = device.get("isAvailable", True)
    keep = udid == keep_uuid or (not uuid_exists and name == keep_name)
    print("\t".join((udid, name, state, str(available).lower(), str(keep).lower())))
' "$KEEP_SIMULATOR_UDID" "$KEEP_SIMULATOR_NAME")"; then
        builtin printf 'Simulators: unavailable (simctl returned malformed JSON)\n'
        return 0
    fi
    if [[ -z "$rows" ]]; then
        builtin printf 'Simulators: none\n'
        return 0
    fi
    builtin printf '%s\n' "$rows" | while IFS=$'\t' read -r udid name state available keep; do
        local marker="keep"
        [[ "$keep" == "true" ]] || marker="candidate"
        builtin printf 'Simulator: %s | %s | %s | available=%s | %s\n' "$name" "$udid" "$state" "$available" "$marker"
        if [[ "$prune_simulators" -eq 1 && "$keep" != "true" ]]; then
            if [[ "$state" == "Booted" ]]; then
                builtin printf 'SKIP: booted simulator %s (%s)\n' "$name" "$udid"
            elif [[ "$apply_changes" -eq 1 ]]; then
                /usr/bin/xcrun simctl delete "$udid"
                builtin printf 'REMOVED: simulator %s (%s)\n' "$name" "$udid"
            else
                builtin printf 'PLAN: remove simulator %s (%s)\n' "$name" "$udid"
            fi
        fi
    done
}

plan_derived_data() {
    if [[ ! -d "$DERIVED_DATA_ROOT" || "$clear_derived_data" -eq 0 ]]; then
        return 0
    fi
    local pattern='LifeOS-*'
    [[ "$clear_all_derived_data" -eq 1 ]] && pattern='*'
    while IFS= read -r path; do
        safe_remove_directory "$path"
    done < <(/usr/bin/find "$DERIVED_DATA_ROOT" -mindepth 1 -maxdepth 1 -type d -name "$pattern" -print)
}

plan_device_support() {
    if [[ ! -d "$DEVICE_SUPPORT_ROOT" || "$prune_device_support" -eq 0 ]]; then
        return 0
    fi
    while IFS= read -r path; do
        local name="$(/usr/bin/basename "$path")"
        if [[ "$name" != "$KEEP_DEVICE_SUPPORT_PREFIX"* ]]; then
            safe_remove_directory "$path"
        fi
    done < <(/usr/bin/find "$DEVICE_SUPPORT_ROOT" -mindepth 1 -maxdepth 1 -type d -print)
}

assert_builds_are_idle() {
    if [[ "$apply_changes" -eq 0 ]]; then
        return 0
    fi
    if [[ "$clear_derived_data" -eq 1 || "$clear_repo_artifacts" -eq 1 || "$prune_device_support" -eq 1 ]]; then
        if [[ ! -x "$PGREP_PATH" ]]; then
            die "cannot verify whether xcodebuild is active; process probe is unavailable: $PGREP_PATH"
        fi
        if "$PGREP_PATH" -x xcodebuild >/dev/null 2>&1; then
            die 'xcodebuild is active; finish or stop the build before removing generated artifacts'
        else
            local probe_status=$?
            if [[ "$probe_status" -ne 1 ]]; then
                die "cannot verify whether xcodebuild is active; process probe exited with status $probe_status"
            fi
        fi
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) apply_changes=1; shift ;;
        --check) check_free_space=1; shift ;;
        --clear-derived-data) clear_derived_data=1; shift ;;
        --clear-all-derived-data) clear_derived_data=1; clear_all_derived_data=1; shift ;;
        --clear-repo-artifacts) clear_repo_artifacts=1; shift ;;
        --prune-simulators) prune_simulators=1; shift ;;
        --prune-device-support) prune_device_support=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ "$MIN_FREE_GIB" =~ ^[0-9]+$ ]] || die 'LIFEOS_MIN_FREE_GIB must be a whole number'

builtin printf 'LifeOS macOS storage report\n'
show_size 'Developer root' "$DEVELOPER_ROOT"
show_size 'Global DerivedData' "$DERIVED_DATA_ROOT"
show_size 'iOS DeviceSupport' "$DEVICE_SUPPORT_ROOT"
show_size 'Xcode Archives' "$ARCHIVES_ROOT"
show_size 'Repo generated artifacts' "$ROOT/artifacts"
show_size 'Repo local DerivedData' "$ROOT/ios/DerivedData"
free_bytes_value="$(free_bytes)"
free_gib="$(/usr/bin/awk -v bytes="$free_bytes_value" 'BEGIN { printf "%.1f", bytes / (1024 * 1024 * 1024) }')"
builtin printf 'Free home-volume space: %s GiB\n' "$free_gib"

assert_builds_are_idle
print_simulators
plan_derived_data
plan_device_support
if [[ "$clear_repo_artifacts" -eq 1 ]]; then
    safe_remove_directory "$ROOT/artifacts/apple-validation"
    safe_remove_directory "$ROOT/artifacts/apple-prerelease"
    safe_remove_directory "$ROOT/ios/DerivedData"
fi

if [[ "$check_free_space" -eq 1 ]]; then
    minimum_bytes="$((MIN_FREE_GIB * 1024 * 1024 * 1024))"
    if [[ "$free_bytes_value" -lt "$minimum_bytes" ]]; then
        builtin printf 'FAIL: only %s GiB free; minimum is %s GiB\n' "$free_gib" "$MIN_FREE_GIB" >&2
        exit 1
    fi
    builtin printf 'PASS: free space is above the %s GiB floor\n' "$MIN_FREE_GIB"
fi

if [[ "$apply_changes" -eq 0 && ( "$clear_derived_data" -eq 1 || "$clear_repo_artifacts" -eq 1 || "$prune_simulators" -eq 1 || "$prune_device_support" -eq 1 ) ]]; then
    builtin printf 'Dry run only. Add --apply to perform the planned cleanup.\n'
fi
