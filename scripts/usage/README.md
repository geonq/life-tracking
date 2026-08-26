# Claude Code usage forwarder

This directory contains a small, stdlib-only Mac helper for forwarding the
rate-limit fields that Claude Code exposes to its status-line command. It is
not installed yet: no `~/.claude` file, launch agent, or endpoint has been
created or modified by this repository.

## Intended flow

1. Claude Code invokes `claude_statusline_collector.py --spool PATH` as its
   status-line command and sends its JSON status object on stdin.
2. The collector keeps one private JSON slot at `PATH`, replacing it
   atomically with mode `0600` on each valid sample. It prints a short status
   such as `CLAUDE USAGE 5h 12.5% · 7d 80%`.
3. A future per-user `launchd` job invokes
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

   The placeholder above is not a real endpoint or identity. The intended
   service is a Tailscale Serve HTTPS endpoint on port `8420` (or `443`) with
   the exact path `/usage/claude-ingest`.

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

The launchd plist, endpoint identity, credentials, and installation remain
deliberately unspecified and not-yet-installed.

## Local verification

From the repository root:

```sh
python3 -m unittest discover -s scripts/usage/tests -p 'test_*.py'
python3 -m py_compile scripts/usage/*.py
```
