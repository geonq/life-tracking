#!/bin/sh
set -eu

# This script renders a reviewable recipe only. It never writes a plist,
# changes Tailscale Serve, or starts a background process.
if [ "${1:-}" != "--print-template" ]; then
  echo "usage: $0 --print-template" >&2
  exit 2
fi

cat <<'PLIST'
<!-- Review and customize paths before installing this per-user LaunchAgent. -->
<plist version="1.0">
<dict>
  <key>Label</key><string>com.geonq.lifeos.relay</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
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
