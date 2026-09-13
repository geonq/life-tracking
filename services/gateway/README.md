# LifeOS gateway

This directory is the tracked gateway source of truth. The Python module is
loopback-only and accepts protected routes only after the reviewed Windows
launcher proves both the exact Tailscale login and the trusted Serve transport;
it is not a deployment bundle.

The launcher receives Serve's identity and app-capability headers on the
loopback hop, but those headers are not trusted merely because they came from
an HTTP client. On Windows, the launcher maps the exact established gateway
connection to its owning PID with `GetExtendedTcpTable` and compares that PID
with the running Tailscale SCM service from `QueryServiceStatusEx`. A direct
local caller, an unknown service, an ambiguous connection, or a failed OS
query cannot cause the private gateway header to be injected. `/health`
remains available for the service host's local liveness probe; protected
routes fail closed.

If a remote Windows gateway has drifted, replace that remote source only after
the isolated gateway test suite and Python compile check pass against this
tracked copy. Do not deploy from this note or as part of source review.

Live Finance is owned here through the Enable Banking adapter and exposed via
the authenticated `/finance/summary` route. Transaction pages follow bounded
`continuation_key` values, including empty intermediate pages; malformed,
repeated, or over-limit pagination fails closed instead of presenting a
partial ledger as complete. A failed refresh can serve the last complete,
validated snapshot; its original observation time is retained and aged
observations are marked `stale`/`refresh_due`, while malformed cache state
still fails closed. Only the reviewed Enable Banking connector is enabled for
live bank data; unsupported providers remain unavailable until implemented and
reviewed. Its URL boundary is fail-closed: the API base must be exactly
`https://api.enablebanking.com`, the registered redirect must be exactly
`https://geonqserver.tail5f8789.ts.net:8420/finance/callback`, and the provider
handoff must be an HTTPS `https://auth.enablebanking.com/ais/start` URL carrying
only its bounded opaque session query. The gateway never follows provider
redirects, and the callback page is static; neither destination is taken from
the request or reflected provider text.

Manual CSV history has a separate gateway authority at `GET`/conditional `PUT
/finance/imported`. The v2 `finance/manual_import` snapshot uses stable
lowercase UUID rows, EUR integer cents, UTF-8 bounded source text, per-row
`sourceRevision` values, and deletion tombstones. Source corrections use an
`upsert` with a matching immutable `expectedSourceRevision`; category changes
use `categorySet`/`categoryClear` with the same source precondition. A deleted
ID can only be brought back by `restore` naming the matching tombstone
revision, so a normal CSV reimport cannot resurrect it.

`PUT` requires the current strong `If-Match` ETag and a printable
`Idempotency-Key`. The native outbox persists the canonical request bytes,
base revision, headers, and lifetime attempt count before transmission. Exact
key/body retries replay the original receipt even after the authority advances;
key/body changes conflict. Each request is capped at 512 KiB and 512
operations, and the state envelope is atomically replaced with restrictive
file permissions and an explicitly migrated, bounded replay journal. The phone
keeps its local import and durable outbox first, then fetches and pushes through
the existing Tailscale trusted edge; this route never changes the live Enable
Banking summary.

When loading an older valid snapshot, the adapter conservatively re-runs the
current merchant categorizer only for rows still labeled `Uncategorized`; it
does not overwrite any explicit category. The complete repaired snapshot is
validated again before it is returned. This lets a deployment repair a stale
category vocabulary even when the provider is temporarily unavailable.

The authenticated `GET /nutrition/barcode/<ean>` route proxies only the
normalized Open Food Facts contract from the loopback Node API. It validates
the EAN checksum, response schema, and 256 KiB bound before returning data;
provider payloads and malformed responses never reach the phone.

The authenticated `POST /nutrition/photo-proposal` route treats the iPhone
manifest as untrusted: before forwarding it to the loopback Node adapter, the
gateway recomputes each image's base64 byte length and SHA-256, checks the
sanitized flag, dimensions, aggregate limit, and JPEG/PNG/HEIC/WebP magic
bytes. Client-provided lineage is therefore not accepted as proof of the
uploaded bytes.

## Windows supplement reference catalog

`GET /supplements/catalog?q=<term>&limit=<1-20>` is an authenticated,
read-only search boundary for a Windows SQLite reference database. Configure
the absolute database path with `LIFEOS_SUPPLEMENT_CATALOG_PATH`; the default
is `data/supplements.sqlite3`. The database is never served directly and the
HTTP route has no write operation. The required tables are
`supplement_entries(id, name, brand, product_identifier, form, serving_unit,
source, source_date)` and
`supplement_nutrients(entry_id, nutrient_id, nutrient_name, amount_per_unit,
unit, label_basis_units, nrv_percent)`. Searches are parameterized and bounded
to 20 products and 64 nutrient facts per product. `amount_per_unit` is the
amount in one tablet/capsule/etc.; `label_basis_units` separately preserves
the package's daily-dose basis. Populate this database from reviewed label
facts on Windows. The app only copies a selected result into a local,
user-confirmed plan; no medical recommendation or interaction check is
performed.

The tracked `supplement_catalog_seed.sql` contains facts transcribed from the
four package-label photos supplied for the initial catalog. It intentionally
leaves the electrolyte product's nutrient list empty because the photo does
not show the per-tablet calcium/magnesium split. Apply the schema and seed on
the Windows host as an operator action; the presence of this SQL file is not
deployment proof that the catalog is populated.
