# Claude Code usage forwarder

This directory contains a small, stdlib-only Mac helper for forwarding the
rate-limit fields that Claude Code exposes to its status-line command. The
repository also contains a safe, explicit installer; it does not modify
`~/.claude` unless run with `--apply`.

## Intended flow

1. Claude Code invokes `claude_statusline_collector.py --spool PATH` as its
   status-line command and sends its JSON status object on stdin. Claude Code
   documents these fields as `rate_limits.five_hour` and `rate_limits.seven_day`;
   they are available to Claude.ai Pro/Max subscribers after the first response.
2. The collector keeps one private JSON slot at `PATH`, replacing it
   atomically with mode `0600` on each valid sample. It prints a short status
   such as `CLAUDE USAGE 5h 12.5% · 7d 80%`.
3. A per-user `launchd` job invokes
   `claude_usage_uploader.py --spool PATH --config CONFIG` periodically.
   The uploader atomically renames the latest slot to a fixed private
   `PATH`-sibling claim before sending. A valid claim is retried first; a 2xx
   response deletes only that claim. Failed network/server/config attempts
   retain it for the next run, while the collector remains free to replace a
   newer latest slot.
4. `CONFIG` is a local JSON file with exactly one key, for example:

   ```json
   {"endpoint":"https://your-device.your-tailnet.ts.net:8420/usage/claude-ingest"}
   ```

   The configured LifeOS endpoint is
   `https://geonqserver.tail5f8789.ts.net:8420/usage/claude-ingest`. The
   installer defaults to this exact approved host but validates any override
   against the same HTTPS/Tailscale/path policy.

## Install on the Mac that runs Claude Code

From the repository root, preview the paths first:

```sh
python3 scripts/usage/install_claude_forwarder.py
```

Apply the configuration after reviewing the dry run:

```sh
python3 scripts/usage/install_claude_forwarder.py --apply --load-agent
```

The installer merges only the `statusLine` setting into the existing
`~/.claude/settings.json`, saves a private pre-change backup, writes a private
endpoint config and spool directory under `~/.lifeos/claude-usage`, and loads
`com.lifeos.claude-usage-uploader`. It never writes an API key or bearer token.
`--load-agent` is optional; without it, the plist is written but not loaded.
The uploader runs at login and every 60 seconds. The status line intentionally
does not use a periodic refresh: rerunning it without a new Claude response
would make an old quota sample look newly observed. After the next Claude
response, verify the chain with:

```sh
python3 scripts/usage/claude_usage_uploader.py \
  --spool "$HOME/.lifeos/claude-usage/claude-usage.json" \
  --config "$HOME/.lifeos/claude-usage/endpoint.json"
```

Then the LifeOS API must return an observed Claude window from `/api/usage`.
An absent `rate_limits` object is reported as unavailable; the forwarder never
turns missing data into zero.

## Privacy and trust boundary

- The collector parses at most 64 KiB, rejects malformed JSON, duplicate keys,
  `NaN`/`Infinity`, and type coercion, and allowlists only finite numeric
  `used_percentage` values from 0–100 and positive finite `resets_at` epochs
  under `five_hour` and `seven_day`.
- Session IDs, transcript paths, workspace data, model names, and all unknown
  fields are discarded and never enter the spool or request body. Missing
  quota remains missing; no zero or other fabricated value is emitted.
- The spool is a single overwritten file, not a history, and is atomically
  replaced with mode `0600`. During an outage there can be one retry claim
  plus one newer latest slot, never an unbounded history. The uploader bounds
  both files' reads to 16 KiB and revalidates the exact spool shape before
  posting.
- The endpoint config is also required to be a mode `0600` regular file: it
  controls the only outbound trust destination.
- The endpoint must be HTTPS, have a hostname ending in `.ts.net`, use only
  port `8420` or `443`, and have exactly `/usage/claude-ingest` with no
  userinfo, query, or fragment. TLS uses the platform trust store.
- The POST has `Content-Type: application/json` and, when sent by the
  uploader, a locally derived `X-Observed-At` capture timestamp. The gateway
  validates and normalizes that timestamp before forwarding it to Node. No
  Authorization header, cookie, redirect following, response-body logging, or
  sensitive error output is used. A timeout or network/server failure only
  produces `CLAUDE USAGE unavailable` and a nonfatal exit.

The endpoint identity and Tailscale Serve remain runtime prerequisites. The
installer cannot manufacture a Claude.ai subscription response or prove a
Windows gateway from this Mac; the final acceptance step must observe a real
Claude window in `/api/usage`.

## Local verification

From the repository root:

```sh
python3 -m unittest discover -s scripts/usage/tests -p 'test_*.py'
python3 -m py_compile scripts/usage/*.py
```
