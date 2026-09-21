# Revision 11 changelog

Planning-only. No Swift/TypeScript/Python source, generated project, build artifact, commit or push changed.

R11 closes seven independent-review blockers:

- R11-01 makes the Planning `journal.sqlite`/`sync_meta` transaction one step in the alias fence, with a
  single UTF-8 path order, backups, trust-last commit and crash recovery.
- R11-02 adds a signed response nonce carrier and exact status/header/body/request/epoch signature bytes.
- R11-03 raises `/blob/read` to a mathematically safe raw cap while keeping decoded chunks at 262,144 bytes.
- R11-04 defines V6 artifact-hash binding, durable finalize/commit APIs and crash-idempotent recovery.
- R11-05 replaces the incorrect 39/40 proof with bounds for 106,496 files, 106,752 chunks and 213,248 units.
- R11-06 carries every Calendar field and structured metadata through codec, migration and create/update paths.
- R11-07 replaces oversized footers with compact references to a separately authenticated streamed manifest.

R9-04 and R10-01…05 received supersession notes. The existing P00–P18 allowlist remains the sole source-path
allowlist because R11 adds contracts only at existing P01/P02/P03/P05/P06/P08/P18 ownership boundaries.
