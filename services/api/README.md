# API security and adapter boundary

The local API has two truthful modes. `/health`, `/api/overview`, and `/api/codex`
serve explicitly labeled `Demo data` fixtures. `/api/codex/live` and the
potentially-live `/api/usage` route use the bounded adapters; `/api/usage` is
side-effect-free and reports live Codex observations plus any bounded Claude
history that was explicitly ingested.

The production listener binds to loopback (`127.0.0.1`). Claude statusline
ingestion (`POST /api/usage/claude-ingest`, with the legacy alias
`/api/claude/statusline`) is disabled unless enabled, loopback-only,
Bearer-authenticated, and bounded to a 16 KiB JSON body. The authenticated
Claude and Codex endpoints below are the only Usage history writers. History is
normalized to the shared contract, retained for at most 500 samples/30 days,
and written through a temporary file with mode `0600`; a Usage read never
writes history.

Adapters return only normalized quota fields. Unknown, sensitive, prompt, path,
account, thread, and other content fields are discarded; credentials and raw
content are not exposed or persisted. Live integrations must obtain credentials
server-side, preserve source/provenance and freshness, and keep the constrained
connector-state enum. Never infer live values from the demo fixtures.

The Windows Codex collector is opt-in with `CODEX_INGEST_ENABLED=true` and an
absolute, restrictive file-only `CODEX_INGEST_SECRET_FILE`. On Windows, keep
the secret ACL readable only by the scheduled-task/API identity; Node cannot
prove NTFS ACLs portably, so deployment must enforce that ACL. It posts the exact sanitized
`{ "windows": [{ "minutes": 300|10080, "usedPercent": number, "resetAt"?: ISO }] }`
shape to loopback `127.0.0.1:8787/api/usage/codex-ingest`; unknown fields,
duplicate windows, malformed values, and oversized bodies are rejected. After
`npm run build`, a scheduled task can invoke `npm run codex-collector` (or
`node dist/codex-collector.js`). The collector prints only `success` or
`unavailable` and never follows redirects or uses a proxy.

Keep `USAGE_STORE_PATH` in a dedicated API-writable directory. Startup rejects
relative paths, missing or directly reparse-linked parents, unsafe POSIX modes,
and corrupt history without creating or truncating the store; Windows ACLs for
that directory remain an external service-account deployment requirement.

The compiled API entrypoint binds only after readiness succeeds and drains its
loopback listener on redirected-stdin EOF, SIGTERM, or SIGINT. It exits
successfully only after active requests close; startup/listen failures emit only
the generic `startup_failed` status.

## Germany-capable barcode nutrition lookup

`GET /api/nutrition/barcode/{barcode}` (with the gateway alias
`/nutrition/barcode/{barcode}`) is a read-only, bounded Open Food Facts adapter.
The Node API binds to loopback; the route is intentionally unauthenticated at
this process boundary because the authenticated Tailscale gateway must be the
only remote ingress and proxy it to loopback. Never expose the Node listener
directly or bind it to a broad interface.

The adapter accepts only checksum-valid EAN-8, EAN-13, or UPC-A input (UPC-A is
canonicalized to EAN-13), requests Open Food Facts API v3.6 with German
localization, and sends only an allowlisted field set. It uses a 5-second
timeout, manual redirects, a 256 KiB response cap, a 15 requests/minute/IP
client-side limit, bounded in-memory LRU caching (1,000 entries), and
exponential backoff for 429/503 responses. Product data is mapped only when
provider values are finite and within the contract bounds; missing values stay
missing and no kcal/kJ or serving conversion is inferred.

The production composition root enables this adapter only when
`OPEN_FOOD_FACTS_ENABLED` is exactly `true` and
`OPEN_FOOD_FACTS_CONTACT_EMAIL` is a bounded, ASCII, syntax-validated operator
email. Missing or invalid configuration remains available as an explicit
`configuration_unavailable` result and makes no upstream request. The contact
is used only in the required User-Agent; it is never returned or logged. Keep
that configuration in the Windows service environment boundary. The response carries explicit Open Food Facts attribution,
ODbL-1.0/DbCL-1.0 licensing, and the warning that volunteer-sourced data is not
guaranteed accurate, complete, or reliable. Remote product image URLs are not
returned, so the native client cannot make a second uncontrolled request.

The Swift client validates the barcode again, performs a bounded GET through the
authenticated gateway, and decodes only the normalized contract. On iPhone, the
native scanner is permission/availability-gated, captures one EAN-8/EAN-13 code
(UPC-A is reported by AVFoundation as EAN-13), and hands only the normalized
code to the same lookup flow; denied/unavailable devices retain manual entry.
A found result becomes an editable proposal; only an explicit confirmation may
be turned into a `NutritionRecord`, and persistence is a separate local-store
call. No camera frames are stored or uploaded.
