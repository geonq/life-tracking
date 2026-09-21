#!/bin/sh
set -eu

# This script renders a reviewable recipe only. It never writes a plist,
# changes Tailscale Serve, or starts a background process.
if [ "${1:-}" != "--print-template" ]; then
  echo "usage: $0 --print-template" >&2
  exit 2
fi

PYTHON_BIN=${LIFEOS_RELAY_PYTHON:-}
if [ -z "$PYTHON_BIN" ]; then
  echo "set LIFEOS_RELAY_PYTHON to a verified Python 3.10+ interpreter" >&2
  exit 2
fi
PYTHON_PATH=$(command -v "$PYTHON_BIN" 2>/dev/null || true)
if [ -z "$PYTHON_PATH" ] || ! "$PYTHON_PATH" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
  echo "LIFEOS_RELAY_PYTHON must resolve to Python 3.10+" >&2
  exit 2
fi
case "$PYTHON_PATH" in
  *[!A-Za-z0-9_./-]*) echo "interpreter path contains unsupported plist characters" >&2; exit 2 ;;
esac

cat <<PLIST
<!-- Review and customize paths before installing this per-user LaunchAgent. -->
<plist version="1.0">
<dict>
  <key>Label</key><string>com.geonq.lifeos.relay</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON_PATH</string>
    <string>/ABSOLUTE/PATH/TO/LifeOS/services/mac-relay/main.py</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>8788</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/lifeos-relay.out</string>
  <key>StandardErrorPath</key><string>/tmp/lifeos-relay.err</string>
</dict>
</plist>
PLIST
