#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/launch_macos_visual_fixture.sh APP_PATH [--live]

Stages a built LifeOSMac.app under a test-only bundle identifier and opens it
through LaunchServices. The default launch uses visual fixtures; pass --live
only when a live-data visual check is deliberate.
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 64
fi

source_app=$1
live_mode=0
if [[ ${2:-} == "--live" ]]; then
  live_mode=1
elif [[ $# -eq 2 ]]; then
  usage >&2
  exit 64
fi

if [[ "$source_app" != /* || ! -d "$source_app" || ! -f "$source_app/Contents/Info.plist" ]]; then
  echo "LifeOSMac.app path must be an absolute built app bundle: $source_app" >&2
  exit 66
fi

fixture_bundle_id="com.hermes.lifeos.mac.visual-fixture"
fixture_root="/private/tmp/lifeos-mac-visual-fixture"
fixture_app="$fixture_root/LifeOSMac.app"

# This identifier belongs only to this disposable visual-check process. Never
# quit the production bundle: XCTest may be running against that bundle.
/usr/bin/osascript -e "tell application id \"$fixture_bundle_id\" to quit" >/dev/null 2>&1 || true
sleep 1
rm -rf "$fixture_root"
mkdir -p "$fixture_root"
/usr/bin/ditto "$source_app" "$fixture_app"

# The copy is unsigned by design. Changing only the staged plist keeps the
# production build untouched and prevents XCTest's terminate/relaunch calls
# from selecting the visual-check instance.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $fixture_bundle_id" "$fixture_app/Contents/Info.plist"
rm -rf "$fixture_app/Contents/_CodeSignature"
widget_plist="$fixture_app/Contents/PlugIns/LifeOSMacWidget.appex/Contents/Info.plist"
if [[ -f "$widget_plist" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $fixture_bundle_id.widget" "$widget_plist"
  rm -rf "$fixture_app/Contents/PlugIns/LifeOSMacWidget.appex/Contents/_CodeSignature"
fi

launch_args=()
if [[ $live_mode -eq 0 ]]; then
  launch_args+=("-LifeOSVisualFixtures")
fi

/usr/bin/open -na "$fixture_app" --args "${launch_args[@]}"
echo "LifeOSMac visual fixture launched"
echo "  bundle: $fixture_bundle_id"
echo "  path:   $fixture_app"
if [[ $live_mode -eq 0 ]]; then
  echo "  data:   visual fixtures"
else
  echo "  data:   live"
fi
