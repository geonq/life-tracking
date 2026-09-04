# Hermes Clipper handoff

Hermes must produce a normalized `ClipperSnapshot` JSON document using the
contract in `packages/contracts/src/clipper.ts`. It keeps all platform
credentials and platform-specific mapping. The uploader accepts only an
`availability: "observed"` snapshot and sends it to the exact local Node route:

```sh
python3 scripts/clipper/hermes_uploader.py \
  --snapshot PATH_TO_PRIVATE_SNAPSHOT.json \
  --secret-file PATH_TO_PRIVATE_CLIPPER_INGEST_SECRET
```

The secret file must be a regular mode-0600 file containing 32–256 visible
ASCII characters. The snapshot and request are bounded to 1 MiB. The request
uses a deterministic SHA-256-derived `Idempotency-Key`, so retrying the same
snapshot is safe. A failed request leaves the source snapshot untouched for
the next scheduled attempt. The uploader never logs snapshot contents,
credentials, or the response body.

The Node store also protects the latest observation from delayed out-of-order
posts: it journals the key but keeps the newer snapshot authoritative. The
Node API performs the authoritative full-schema validation and durable
latest-snapshot/idempotency persistence. A successful upload is not proof of
native app readback; that remains an acceptance gate.
