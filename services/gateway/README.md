# LifeOS gateway

This directory is the tracked gateway source of truth. The Python module is
loopback-only and is authenticated by the exact Tailscale login header; it is
not a deployment bundle.

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
still fails closed. PayPal remains a separate official-eligibility gate and
is not enabled by this source alone.

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
