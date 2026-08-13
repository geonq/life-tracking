#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${LIFEOS_ARTIFACT_DIR:-$ROOT/artifacts/apple-validation}"
XCODEGEN_VERSION="2.46.0"
LANE_SELECTION="${1:-logic}"

case "$LANE_SELECTION" in
  logic|ui|all) ;;
  *)
    echo "Usage: $0 [logic|ui|all] (default: logic)" >&2
    exit 2
    ;;
esac

# Non-interactive SSH shells do not load Homebrew's shellenv. Include the
# standard Apple Silicon and Intel prefixes so XcodeGen is still discoverable.
for brew_prefix in /opt/homebrew/bin /usr/local/bin; do
  if [[ -d "$brew_prefix" ]]; then
    PATH="$brew_prefix:$PATH"
  fi
done
export PATH

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This validation requires macOS with Xcode." >&2
  exit 2
fi

for command_name in xcodebuild xcrun python3; do
  command -v "$command_name" >/dev/null || {
    echo "Missing required command: $command_name" >&2
    exit 2
  }
done

if ! command -v xcodegen >/dev/null; then
  echo "Missing XcodeGen ${XCODEGEN_VERSION}; install that exact upstream release before running this script." >&2
  echo "https://github.com/yonaskolb/XcodeGen/releases/tag/${XCODEGEN_VERSION}" >&2
  exit 2
fi

actual_xcodegen_version="$(xcodegen version | sed -n 's/.*Version: //p')"
if [[ "$actual_xcodegen_version" != "$XCODEGEN_VERSION" ]]; then
  echo "XcodeGen version drift: expected ${XCODEGEN_VERSION}, found ${actual_xcodegen_version:-unknown}." >&2
  exit 2
fi

manifest_value() {
  local lane_id="$1"
  local field="$2"
  python3 -B "$ROOT/scripts/lane_manifest.py" --lane "$lane_id" --field "$field"
}

cd "$ROOT"
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR/DerivedData"

expected_commit="${LIFEOS_EXPECTED_COMMIT:-$(git rev-parse HEAD)}"
git cat-file -e "${expected_commit}^{commit}"
python3 -B scripts/validate_acceptance_registry.py --expected-commit "$expected_commit"
python3 -B scripts/validate_native_calendar.py
xcodegen_project="$ROOT/ios/LifeOS.xcodeproj"
rm -rf "$xcodegen_project"
xcodegen generate --spec ios/project.yml --project ios --project-root ios
python3 -B scripts/validate_xcodegen.py \
  --project ios/LifeOS.xcodeproj \
  --spec ios/project.yml \
  --expected-version "$XCODEGEN_VERSION"

DEVICE_INFO="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
devices = [
    device
    for runtime, entries in data["devices"].items()
    if "iOS" in runtime
    for device in entries
    if device.get("isAvailable") and "iPhone" in device["name"]
]
preferred = [device for device in devices if device["name"] == "iPhone 17"]
if not preferred:
    preferred = [device for device in devices if "Pro" not in device["name"] and "SE" not in device["name"]]
selected = preferred[0] if preferred else (devices[-1] if devices else None)
if selected:
    print(selected["udid"] + "|" + selected.get("state", "Shutdown"))
')"

if [[ -z "$DEVICE_INFO" ]]; then
  echo "No available iPhone simulator was found." >&2
  exit 2
fi

UDID="${DEVICE_INFO%%|*}"
DEVICE_STATE="${DEVICE_INFO#*|}"
BOOTED_BY_SCRIPT="$UDID"
cleanup_simulator() {
  xcrun simctl terminate "$BOOTED_BY_SCRIPT" com.hermes.lifeos.app >/dev/null 2>&1 || true
  xcrun simctl terminate "$BOOTED_BY_SCRIPT" com.hermes.lifeos.app.widget >/dev/null 2>&1 || true
  xcrun simctl shutdown "$BOOTED_BY_SCRIPT" >/dev/null 2>&1 || true
}
trap cleanup_simulator EXIT

if [[ "$DEVICE_STATE" != "Booted" ]]; then
  xcrun simctl boot "$UDID"
  BOOTED_BY_SCRIPT="$UDID"
fi
xcrun simctl bootstatus "$UDID" -b

run_ios_lane() {
  local lane_id="$1"
  local scheme test_plan configuration test_target minimum_tests artifact_name
  scheme="$(manifest_value "$lane_id" scheme)"
  test_plan="$(manifest_value "$lane_id" test_plan)"
  configuration="$(manifest_value "$lane_id" configuration)"
  test_target="$(manifest_value "$lane_id" only_testing)"
  minimum_tests="$(manifest_value "$lane_id" minimum_tests)"
  artifact_name="$lane_id"
  local result_path="$ARTIFACT_DIR/$(manifest_value "$lane_id" result_path)"
  local derived_data_path="$ARTIFACT_DIR/DerivedData/$(manifest_value "$lane_id" derived_data_path)"
  local log_path="$ARTIFACT_DIR/$(manifest_value "$lane_id" log_path)"
  rm -rf "$result_path" "$derived_data_path"
  mkdir -p "$derived_data_path"
  set +e
  xcodebuild \
    -project ios/LifeOS.xcodeproj \
    -scheme "$scheme" \
    -testPlan "$test_plan" \
    -configuration "$configuration" \
    -destination "id=$UDID" \
    -derivedDataPath "$derived_data_path" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$result_path" \
    "-only-testing:$test_target" \
    CODE_SIGNING_ALLOWED=NO \
    test | tee "$log_path"
  local xcodebuild_status="${PIPESTATUS[0]}"
  set -e
  set +e
  python3 -B scripts/validate_xcresult.py \
    --result "$result_path" \
    --minimum-tests "$minimum_tests"
  local validator_status="$?"
  set -e
  if [[ "$xcodebuild_status" -ne 0 ]]; then
    echo "${artifact_name}: xcodebuild failed with status ${xcodebuild_status}" >&2
    return "$xcodebuild_status"
  fi
  return "$validator_status"
}

run_mac_lane() {
  local lane_id="$1"
  local scheme test_plan configuration test_target minimum_tests artifact_name
  scheme="$(manifest_value "$lane_id" scheme)"
  test_plan="$(manifest_value "$lane_id" test_plan)"
  configuration="$(manifest_value "$lane_id" configuration)"
  test_target="$(manifest_value "$lane_id" only_testing)"
  minimum_tests="$(manifest_value "$lane_id" minimum_tests)"
  artifact_name="$lane_id"
  local result_path="$ARTIFACT_DIR/$(manifest_value "$lane_id" result_path)"
  local derived_data_path="$ARTIFACT_DIR/DerivedData/$(manifest_value "$lane_id" derived_data_path)"
  local log_path="$ARTIFACT_DIR/$(manifest_value "$lane_id" log_path)"
  rm -rf "$result_path" "$derived_data_path"
  mkdir -p "$derived_data_path"
  set +e
  xcodebuild \
    -project ios/LifeOS.xcodeproj \
    -scheme "$scheme" \
    -testPlan "$test_plan" \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$result_path" \
    "-only-testing:$test_target" \
    CODE_SIGNING_ALLOWED=NO \
    test | tee "$log_path"
  local xcodebuild_status="${PIPESTATUS[0]}"
  set -e
  set +e
  python3 -B scripts/validate_xcresult.py \
    --result "$result_path" \
    --minimum-tests "$minimum_tests"
  local validator_status="$?"
  set -e
  if [[ "$xcodebuild_status" -ne 0 ]]; then
    echo "${artifact_name}: xcodebuild failed with status ${xcodebuild_status}" >&2
    return "$xcodebuild_status"
  fi
  return "$validator_status"
}

export_ios_ui_attachments() {
  local result_path="$ARTIFACT_DIR/$(manifest_value ios-ui result_path)"
  local output_path="$ARTIFACT_DIR/ios-ui-attachments"
  mkdir -p "$output_path"
  xcrun xcresulttool export attachments \
    --path "$result_path" \
    --output-path "$output_path" || {
      echo "Warning: iOS UI attachment export was unavailable; the xcresult bundle is preserved." >&2
    }
}

# Default validation is deliberately logic-only. UI/visual lanes are explicit
# opt-ins because they are slower and produce much larger attachment trees.
if [[ "$LANE_SELECTION" == "logic" || "$LANE_SELECTION" == "all" ]]; then
  run_ios_lane "ios-logic"
fi

if [[ "$LANE_SELECTION" == "ui" || "$LANE_SELECTION" == "all" ]]; then
  run_ios_lane "ios-ui"
  export_ios_ui_attachments
  run_mac_lane "mac-ui"
fi

if [[ "$LANE_SELECTION" == "all" ]]; then
  run_mac_lane "mac-logic"
  run_mac_lane "widgets"
fi

echo "Apple validation complete ($LANE_SELECTION lanes). Artifacts: $ARTIFACT_DIR"
