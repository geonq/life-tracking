#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${LIFEOS_ARTIFACT_DIR:-$ROOT/artifacts/apple-validation}"

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
  if command -v brew >/dev/null; then
    brew install xcodegen
  else
    echo "Install XcodeGen first: https://github.com/yonaskolb/XcodeGen" >&2
    exit 2
  fi
fi

cd "$ROOT"
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR/screenshots"

python3 scripts/validate_native_calendar.py
xcodegen generate --spec ios/project.yml

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
devices = [
    device
    for runtime, entries in data["devices"].items()
    if "iOS" in runtime
    for device in entries
    if device.get("isAvailable") and "iPhone" in device["name"]
]
preferred = [device for device in devices if "Pro" not in device["name"] and "SE" not in device["name"]]
selected = (preferred or devices)[-1] if devices else None
print(selected["udid"] if selected else "")
')"

if [[ -z "$UDID" ]]; then
  echo "No available iPhone simulator was found." >&2
  exit 2
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

xcodebuild \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOS \
  -destination "id=$UDID" \
  -resultBundlePath "$ARTIFACT_DIR/LifeOS.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test | tee "$ARTIFACT_DIR/ios-xcodebuild.log"

xcrun xcresulttool export attachments \
  --path "$ARTIFACT_DIR/LifeOS.xcresult" \
  --output-path "$ARTIFACT_DIR/screenshots" || {
    echo "Warning: screenshot attachment export was unavailable; the xcresult bundle is preserved." >&2
  }

xcodebuild \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOSMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$ARTIFACT_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build | tee "$ARTIFACT_DIR/macos-xcodebuild.log"

echo "Apple validation complete. Artifacts: $ARTIFACT_DIR"
