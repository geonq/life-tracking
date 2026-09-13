#!/bin/bash -p
set -euo pipefail
IFS=$'\n\t'

# Install the signed personal-team iOS build onto one connected physical
# iPhone. This is intentionally non-interactive so a macOS Shortcut can call
# it and use the exit status as its result.

readonly SCHEME="LifeOS"
readonly CONFIGURATION="Debug"
readonly BUNDLE_IDENTIFIER="com.hermes.lifeos.app"
readonly WIDGET_BUNDLE_IDENTIFIER="com.hermes.lifeos.app.widget"
readonly MAX_DEVICE_JSON_BYTES=$((4 * 1024 * 1024))
readonly DEVICE_LIST_TIMEOUT_SECONDS=20
readonly INSTALL_TIMEOUT_SECONDS=120
readonly BUILD_TIMEOUT_SECONDS=300
readonly COMMAND_TIMEOUT_SECONDS=30
readonly MAX_BUNDLE_PLIST_BYTES=$((256 * 1024))
readonly TRUSTED_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
readonly TRUSTED_PYTHON="/usr/bin/python3"

PATH="$TRUSTED_SYSTEM_PATH"
export PATH

script_dir="$(builtin cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
repo_root="$(builtin cd "$script_dir/.." && /bin/pwd -P)"
project_path="$repo_root/ios/LifeOS.xcodeproj"
checks_path="$repo_root/scripts/install_personal_device_checks.py"
active_runner_pid=""
xcrun_bin=""
xcodebuild_bin=""
codesign_bin=""
security_bin=""
python_bin=""

usage() {
    /bin/cat <<'EOF'
Usage: scripts/install_personal_device.sh [options]

Required signing input:
  DEVELOPMENT_TEAM=TEAMID or --development-team TEAMID
  APP_GROUP_IDENTIFIER=group.* or --app-group group.*

Optional device input:
  LIFEOS_DEVICE_UDID=UDID or --device-udid UDID

The team and App Group values are configuration identifiers, not credentials.
The command asks Xcode to perform its normal signing checks and never bypasses
signing. Xcode may still require an interactive trust or keychain step before
a Shortcut can complete the install.
The App Group must already be registered for the supplied Team; signing may
reject a group that the Team cannot provision.
Personal Team builds require a rebuild and reinstall within Apple's seven-day
development provisioning cycle. An expired profile requires Xcode to provision
the device again; this command does not renew signing itself.
EOF
}

die() {
    builtin printf 'LifeOS device: failed (%s)\n' "$1" >&2
    exit 1
}

status() {
    builtin printf 'LifeOS device: %s\n' "$1"
}

# The Python helper creates a new process group, applies the deadline, and
# performs best-effort cleanup for trusted command descendants, including
# common cases where the direct child exits early. Arbitrary executables are
# rejected by the production command allowlist.
run_bounded() {
    local timeout_seconds="$1"
    shift
    local runner_status

    /usr/bin/env -i \
        PATH="$TRUSTED_SYSTEM_PATH" \
        HOME="${HOME:-}" \
        USER="${USER:-}" \
        LOGNAME="${LOGNAME:-}" \
        LANG="${LANG:-C}" \
        LC_ALL="${LC_ALL:-}" \
        LC_CTYPE="${LC_CTYPE:-}" \
        LC_MESSAGES="${LC_MESSAGES:-}" \
        TERM="${TERM:-}" \
        TMPDIR="$work_dir" \
        LIFEOS_STUB_DEVICE_JSON="${LIFEOS_STUB_DEVICE_JSON:-}" \
        LIFEOS_STUB_STATE_DIR="${LIFEOS_STUB_STATE_DIR:-}" \
        LIFEOS_STUB_APP_PROFILE="${LIFEOS_STUB_APP_PROFILE:-}" \
        LIFEOS_STUB_WIDGET_PROFILE="${LIFEOS_STUB_WIDGET_PROFILE:-}" \
        LIFEOS_STUB_APP_ENTITLEMENTS="${LIFEOS_STUB_APP_ENTITLEMENTS:-}" \
        LIFEOS_STUB_WIDGET_ENTITLEMENTS="${LIFEOS_STUB_WIDGET_ENTITLEMENTS:-}" \
        LIFEOS_STUB_BUILD_FAIL="${LIFEOS_STUB_BUILD_FAIL:-}" \
        LIFEOS_STUB_CODESIGN_FAIL="${LIFEOS_STUB_CODESIGN_FAIL:-}" \
        LIFEOS_STUB_INSTALL_FAIL="${LIFEOS_STUB_INSTALL_FAIL:-}" \
        LIFEOS_STUB_DIAGNOSTIC="${LIFEOS_STUB_DIAGNOSTIC:-}" \
        LIFEOS_STUB_SECURITY_FAIL="${LIFEOS_STUB_SECURITY_FAIL:-}" \
        LIFEOS_STUB_DUPLICATE_INFO="${LIFEOS_STUB_DUPLICATE_INFO:-}" \
        PYTHONNOUSERSITE=1 \
        PYTHONSAFEPATH=1 \
        "$python_bin" -S -B "$checks_path" --run-bounded "$timeout_seconds" -- "$@" &
    active_runner_pid="$!"
    if builtin wait "$active_runner_pid"; then
        runner_status=0
    else
        runner_status="$?"
    fi
    active_runner_pid=""
    return "$runner_status"
}

# Resolve every executable from the sealed system locations before invoking
# any external command. The inherited PATH is never used for tool selection.
resolve_tool() {
    local tool_name="$1"
    local tool_path
    case "$tool_name" in
        python3)
            tool_path="$TRUSTED_PYTHON"
            ;;
        xcrun|xcodebuild|codesign|security)
            tool_path="/usr/bin/$tool_name"
            ;;
        *)
            die "missing-required-tool"
            ;;
    esac
    [[ -f "$tool_path" && ! -L "$tool_path" && -x "$tool_path" ]] || die "missing-required-tool"
    builtin printf '%s\n' "$tool_path"
}

team_argument=""
app_group_argument=""
device_argument=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --development-team)
            [[ $# -ge 2 && -n "${2:-}" ]] || die "invalid-argument"
            team_argument="$2"
            shift 2
            ;;
        --app-group)
            [[ $# -ge 2 && -n "${2:-}" ]] || die "invalid-argument"
            app_group_argument="$2"
            shift 2
            ;;
        --device-udid)
            [[ $# -ge 2 && -n "${2:-}" ]] || die "invalid-argument"
            device_argument="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "invalid-argument"
            ;;
    esac
done

development_team="${DEVELOPMENT_TEAM:-}"
if [[ -n "${LIFEOS_DEVELOPMENT_TEAM:-}" ]]; then
    if [[ -n "$development_team" && "$development_team" != "$LIFEOS_DEVELOPMENT_TEAM" ]]; then
        die "conflicting-development-team"
    fi
    development_team="$LIFEOS_DEVELOPMENT_TEAM"
fi
if [[ -n "$team_argument" ]]; then
    if [[ -n "$development_team" && "$development_team" != "$team_argument" ]]; then
        die "conflicting-development-team"
    fi
    development_team="$team_argument"
fi

app_group_identifier="${APP_GROUP_IDENTIFIER:-}"
if [[ -n "${LIFEOS_APP_GROUP_IDENTIFIER:-}" ]]; then
    if [[ -n "$app_group_identifier" && "$app_group_identifier" != "$LIFEOS_APP_GROUP_IDENTIFIER" ]]; then
        die "conflicting-app-group"
    fi
    app_group_identifier="$LIFEOS_APP_GROUP_IDENTIFIER"
fi
if [[ -n "$app_group_argument" ]]; then
    if [[ -n "$app_group_identifier" && "$app_group_identifier" != "$app_group_argument" ]]; then
        die "conflicting-app-group"
    fi
    app_group_identifier="$app_group_argument"
fi

device_udid="${LIFEOS_DEVICE_UDID:-}"
if [[ -n "$device_argument" ]]; then
    if [[ -n "$device_udid" && "$device_udid" != "$device_argument" ]]; then
        die "conflicting-device-udid"
    fi
    device_udid="$device_argument"
fi

[[ "$development_team" =~ ^[A-Z0-9]{10}$ ]] || die "missing-or-invalid-development-team"
development_team_lower="$(builtin printf '%s' "$development_team" | /usr/bin/tr '[:upper:]' '[:lower:]')"
case "$development_team_lower" in
    *placeholder*|*replace*|*example*|*your*|*teamid*)
        die "missing-or-invalid-development-team"
        ;;
esac

[[ "${#app_group_identifier}" -le 128 ]] || die "missing-or-invalid-app-group"
[[ "$app_group_identifier" =~ ^group\.[A-Za-z0-9]+([.-][A-Za-z0-9]+)*$ ]] || die "missing-or-invalid-app-group"
app_group_lower="$(builtin printf '%s' "$app_group_identifier" | /usr/bin/tr '[:upper:]' '[:lower:]')"
case "$app_group_lower" in
    *placeholder*|*replace*|*example*|*your*|*teamid*|*change-me*|*changeme*|*todo*)
        die "missing-or-invalid-app-group"
        ;;
esac

if [[ -n "$device_udid" ]]; then
    [[ "$device_udid" =~ ^[0-9A-Fa-f-]{8,64}$ ]] || die "invalid-device-udid"
fi

[[ -f "$checks_path" && ! -L "$checks_path" ]] || die "checks-missing"
xcrun_bin="$(resolve_tool xcrun)"
xcodebuild_bin="$(resolve_tool xcodebuild)"
codesign_bin="$(resolve_tool codesign)"
security_bin="$(resolve_tool security)"
python_bin="$(resolve_tool python3)"

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/lifeos-device.XXXXXX" 2>/dev/null)" || die "temporary-workspace"
cleanup() {
    local runner_pid="$active_runner_pid"
    local waited=0
    active_runner_pid=""
    if [[ -n "$runner_pid" ]]; then
        builtin kill -TERM "$runner_pid" 2>/dev/null || builtin true
        # Give the Python supervisor time to forward the signal to its own
        # isolated command group and restore its signal handlers. KILLing the
        # supervisor immediately can strand a TERM-ignoring Xcode descendant.
        while builtin kill -0 "$runner_pid" 2>/dev/null && (( waited < 20 )); do
            /bin/sleep 0.1
            waited=$((waited + 1))
        done
        if builtin kill -0 "$runner_pid" 2>/dev/null; then
            builtin kill -KILL "$runner_pid" 2>/dev/null || builtin true
        fi
        builtin wait "$runner_pid" 2>/dev/null || builtin true
    fi
    /bin/rm -rf "$work_dir" >/dev/null 2>&1 || builtin true
}
trap cleanup EXIT
on_signal() {
    local status_code="$1"
    cleanup
    exit "$status_code"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$xcrun_bin" --find devicectl \
    >"$work_dir/devicectl-path" 2>"$work_dir/devicectl-path.log"; then
    die "missing-devicectl"
fi

status "checking-device"
device_json="$work_dir/devices.json"
if ! run_bounded "$DEVICE_LIST_TIMEOUT_SECONDS" "$xcrun_bin" devicectl --quiet --timeout "$DEVICE_LIST_TIMEOUT_SECONDS" \
    --json-output "$device_json" \
    --log-output "$work_dir/devicectl-list.log" \
    list devices >"$work_dir/devicectl-list.stdout" 2>"$work_dir/devicectl-list.stderr"; then
    die "device-discovery"
fi

[[ -f "$device_json" ]] || die "device-discovery"
device_json_bytes="$(/usr/bin/wc -c <"$device_json" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
[[ "$device_json_bytes" =~ ^[0-9]+$ ]] || die "device-discovery"
(( device_json_bytes <= MAX_DEVICE_JSON_BYTES )) || die "device-discovery"

device_candidates="$work_dir/device-candidates"
if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$python_bin" -S -B "$checks_path" --devices "$device_json" \
    >"$device_candidates" 2>"$work_dir/device-parser.log"
then
    die "device-discovery"
fi

candidate_count=0
selected_device=""
while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ "$candidate" =~ ^[0-9A-Fa-f-]{8,64}$ ]] || die "device-discovery"
    candidate_count=$((candidate_count + 1))
    selected_device="$candidate"
done < "$device_candidates"

if [[ -n "$device_udid" ]]; then
    requested_device="$(builtin printf '%s' "$device_udid" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    requested_found=0
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        candidate_lower="$(builtin printf '%s' "$candidate" | /usr/bin/tr '[:upper:]' '[:lower:]')"
        if [[ "$candidate_lower" == "$requested_device" ]]; then
            selected_device="$candidate"
            requested_found=1
            break
        fi
    done < "$device_candidates"
    (( requested_found == 1 )) || die "device-not-connected"
elif (( candidate_count == 0 )); then
    die "no-connected-iphone"
elif (( candidate_count != 1 )); then
    die "ambiguous-connected-iphone"
fi

status "device-ready"

if ! builtin cd "$repo_root" 2>/dev/null; then
    die "repository-missing"
fi

[[ ! -L "$project_path" ]] || die "project-missing"
# The checked-in project is a reviewed repository artifact. A daily Shortcut
# must not rewrite source or depend on a package generator being available.
[[ -f "$project_path/project.pbxproj" && ! -L "$project_path/project.pbxproj" ]] || die "project-missing"

derived_data_path="$work_dir/derived-data"
app_path="$derived_data_path/Build/Products/${CONFIGURATION}-iphoneos/LifeOS.app"
widget_path="$app_path/PlugIns/LifeOSWidget.appex"

status "building"
build_log="$work_dir/xcodebuild.log"
if run_bounded "$BUILD_TIMEOUT_SECONDS" "$xcodebuild_bin" \
    -project "$project_path" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "id=$selected_device" \
    -derivedDataPath "$derived_data_path" \
    -parallel-testing-enabled NO \
    -jobs 1 \
    -quiet \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_REQUIRED=YES \
    DEVELOPMENT_TEAM="$development_team" \
    APP_GROUP_IDENTIFIER="$app_group_identifier" \
    build >"$build_log" 2>&1; then
    :
else
    build_status="$?"
    if [[ "$build_status" == "124" ]]; then
        die "build-timeout"
    fi
    if /usr/bin/grep -Eqi 'code[[:space:]-]*sign|provision|entitlement|signing|profile' "$build_log"; then
        die "signing-failure"
    fi
    die "build-failure"
fi

[[ -d "$app_path" && ! -L "$app_path" ]] || die "app-missing"
[[ -f "$app_path/Info.plist" ]] || die "app-missing"

bundle_info_bytes="$(/usr/bin/wc -c <"$app_path/Info.plist" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
[[ "$bundle_info_bytes" =~ ^[0-9]+$ && bundle_info_bytes -le MAX_BUNDLE_PLIST_BYTES ]] || die "app-missing"
if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$python_bin" -S -B "$checks_path" --validate-info-plist \
    "$app_path/Info.plist" "$BUNDLE_IDENTIFIER" >"$work_dir/bundle-id.log" 2>&1; then
    die "app-missing"
fi

if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$codesign_bin" --verify --deep --strict "$app_path" \
    >"$work_dir/codesign-verify.log" 2>&1; then
    die "signing-failure"
fi

[[ -d "$widget_path" && ! -L "$widget_path" ]] || die "widget-missing"

verify_signed_bundle() {
    local label="$1"
    local bundle_path="$2"
    local expected_bundle_id="$3"
    local metadata_path="$work_dir/${label}-codesign.txt"
    local entitlements_path="$work_dir/${label}-entitlements.plist"
    local profile_source="$bundle_path/embedded.mobileprovision"
    local profile_path="$work_dir/${label}-profile.plist"
    local info_bytes
    local profile_bytes
    local validation_status

    [[ -d "$bundle_path" && ! -L "$bundle_path" ]] || return 10
    [[ -f "$bundle_path/Info.plist" && ! -L "$bundle_path/Info.plist" ]] || return 10
    [[ -f "$profile_source" && ! -L "$profile_source" ]] || return 11

    info_bytes="$(/usr/bin/wc -c <"$bundle_path/Info.plist" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
    [[ "$info_bytes" =~ ^[0-9]+$ && info_bytes -le MAX_BUNDLE_PLIST_BYTES ]] || return 10
    profile_bytes="$(/usr/bin/wc -c <"$profile_source" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
    [[ "$profile_bytes" =~ ^[0-9]+$ && profile_bytes -le MAX_BUNDLE_PLIST_BYTES ]] || return 11

    if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$python_bin" -S -B "$checks_path" --validate-info-plist \
        "$bundle_path/Info.plist" "$expected_bundle_id" >"$work_dir/${label}-bundle-id.log" 2>&1; then
        return 10
    fi

    if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$codesign_bin" --verify --strict "$bundle_path" \
        >"$work_dir/${label}-verify.log" 2>&1; then
        return 10
    fi
    if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$codesign_bin" --display --verbose=4 "$bundle_path" \
        >"$metadata_path" 2>&1; then
        return 10
    fi
    if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$codesign_bin" -d --entitlements :- "$bundle_path" \
        >"$entitlements_path" 2>"$work_dir/${label}-entitlements.log"; then
        return 10
    fi
    if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" "$security_bin" cms -D -i "$profile_source" -o "$profile_path" \
        >"$work_dir/${label}-profile.log" 2>&1; then
        return 11
    fi

    if run_bounded "$COMMAND_TIMEOUT_SECONDS" "$python_bin" -S -B "$checks_path" --validate-bundle \
        "$metadata_path" \
        "$entitlements_path" \
        "$profile_path" \
        "$development_team" \
        "$expected_bundle_id" \
        "$selected_device" \
        "$app_group_identifier" >"$work_dir/${label}-validator.log" 2>&1; then
        return 0
    else
        validation_status="$?"
        return "$validation_status"
    fi
}

verify_bundle_or_die() {
    local label="$1"
    local bundle_path="$2"
    local expected_bundle_id="$3"
    local result=0

    set +e
    verify_signed_bundle "$label" "$bundle_path" "$expected_bundle_id"
    result="$?"
    set -e
    case "$result" in
        0) ;;
        10) die "signing-failure" ;;
        11) die "profile-failure" ;;
        12) die "app-group-failure" ;;
        *) die "preinstall-verification" ;;
    esac
}

verify_bundle_or_die "app" "$app_path" "$BUNDLE_IDENTIFIER"
verify_bundle_or_die "widget" "$widget_path" "$WIDGET_BUNDLE_IDENTIFIER"

status "installing"
if ! run_bounded "$INSTALL_TIMEOUT_SECONDS" "$xcrun_bin" devicectl --quiet --timeout "$INSTALL_TIMEOUT_SECONDS" \
    --json-output "$work_dir/devicectl-install.json" \
    --log-output "$work_dir/devicectl-install.log" \
    device install app \
    --device "$selected_device" \
    "$app_path" >"$work_dir/devicectl-install.stdout" 2>"$work_dir/devicectl-install.stderr"; then
    die "install-failure"
fi

status "installed"
