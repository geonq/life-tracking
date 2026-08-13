#!/usr/bin/env bash
set -euo pipefail

# The prerelease contract is platform-separated. Do not combine the iOS and
# macOS destinations in one xcodebuild invocation: each platform gets its own
# scheme, test plan, result bundle, and DerivedData materialization.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/ios/LifeOS.xcodeproj"
ACTION="${1:-}"

if [[ -z "$ACTION" || ( "$ACTION" != "build-for-testing" && "$ACTION" != "test-without-building" && "$ACTION" != "test" ) ]]; then
  echo "Usage: $0 {build-for-testing|test-without-building|test}" >&2
  exit 2
fi

if [[ ! -d "$PROJECT" ]]; then
  echo "Missing generated project: $PROJECT (run xcodegen generate --spec ios/project.yml --project ios --project-root ios first)" >&2
  exit 2
fi

ARTIFACT_DIR="${LIFEOS_PRERELEASE_ARTIFACT_DIR:-$ROOT/artifacts/apple-prerelease}"
DERIVED_DATA_ROOT="${LIFEOS_PRERELEASE_DERIVED_DATA_PATH:-$ARTIFACT_DIR/DerivedData}"
mkdir -p "$ARTIFACT_DIR" "$DERIVED_DATA_ROOT"

manifest_value() {
  local lane_id="$1"
  local field="$2"
  python3 -B "$ROOT/scripts/lane_manifest.py" --lane "$lane_id" --field "$field"
}

IOS_UDID=""
select_ios_simulator() {
  local preferred
  preferred="$(manifest_value prerelease-ios simulator_name)"
  IOS_UDID="$(PREFERRED_SIMULATOR="$preferred" xcrun simctl list devices available -j | python3 -c '
import json, os, sys
data = json.load(sys.stdin)
devices = [
    device
    for runtime, entries in data.get("devices", {}).items()
    if "iOS" in runtime
    for device in entries
    if device.get("isAvailable") and "iPhone" in device.get("name", "")
]
preferred = [device for device in devices if device["name"] == os.environ["PREFERRED_SIMULATOR"]]
selected = preferred[0] if preferred else (devices[0] if devices else None)
print(selected["udid"] if selected else "")
')"
  if [[ -z "$IOS_UDID" ]]; then
    echo "No available iPhone simulator was found for prerelease iOS." >&2
    exit 2
  fi
}

run_lane() {
  local lane_id="$1"
  local scheme configuration test_plan platform destination only_testing_csv
  local result_name log_name derived_name result_path log_path derived_data_path
  scheme="$(manifest_value "$lane_id" scheme)"
  configuration="$(manifest_value "$lane_id" configuration)"
  test_plan="$(manifest_value "$lane_id" test_plan)"
  platform="$(manifest_value "$lane_id" platform)"
  destination="$(manifest_value "$lane_id" destination)"
  only_testing_csv="$(manifest_value "$lane_id" only_testing)"
  result_name="$(manifest_value "$lane_id" result_path)"
  log_name="$(manifest_value "$lane_id" log_path)"
  derived_name="$(manifest_value "$lane_id" derived_data_path)"
  result_path="$ARTIFACT_DIR/$result_name"
  log_path="$ARTIFACT_DIR/$log_name"
  derived_data_path="$DERIVED_DATA_ROOT/$derived_name"

  if [[ "$platform" == "ios" ]]; then
    destination="id=$IOS_UDID"
  fi
  rm -rf "$result_path" "$derived_data_path"
  mkdir -p "$derived_data_path"
  IFS=',' read -r -a only_testing <<< "$only_testing_csv"
  local command=(
    xcodebuild
    -project "$PROJECT"
    -scheme "$scheme"
    -testPlan "$test_plan"
    -configuration "$configuration"
    -destination "$destination"
    -derivedDataPath "$derived_data_path"
    -parallel-testing-enabled NO
    CODE_SIGNING_ALLOWED=NO
  )
  for target in "${only_testing[@]}"; do
    command+=("-only-testing:$target")
  done
  if [[ "$ACTION" == "test" || "$ACTION" == "test-without-building" ]]; then
    command+=( -resultBundlePath "$result_path" )
  fi
  command+=( "$ACTION" )

  echo "==> $lane_id / $scheme ($destination): $ACTION"
  set +e
  "${command[@]}" | tee "$log_path"
  local xcodebuild_status="${PIPESTATUS[0]}"
  set -e
  local validator_status=0
  if [[ "$ACTION" == "test" || "$ACTION" == "test-without-building" ]]; then
    set +e
    python3 -B "$ROOT/scripts/validate_xcresult.py" \
      --result "$result_path" \
      --minimum-tests "$(manifest_value "$lane_id" minimum_tests)"
    validator_status="$?"
    set -e
  fi
  if [[ "$xcodebuild_status" -ne 0 ]]; then
    echo "$lane_id: xcodebuild failed with status $xcodebuild_status" >&2
    return "$xcodebuild_status"
  fi
  return "$validator_status"
}

select_ios_simulator
cleanup_simulator() {
  if [[ -n "$IOS_UDID" ]]; then
    xcrun simctl terminate "$IOS_UDID" com.hermes.lifeos.app >/dev/null 2>&1 || true
    xcrun simctl terminate "$IOS_UDID" com.hermes.lifeos.app.widget >/dev/null 2>&1 || true
    xcrun simctl shutdown "$IOS_UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_simulator EXIT
run_lane "prerelease-ios"
run_lane "prerelease-mac"

echo "Prerelease lanes completed: $ACTION"
