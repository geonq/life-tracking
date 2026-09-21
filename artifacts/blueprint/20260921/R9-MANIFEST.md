# Revision9 manifest — independent-review closure

Planning-only. R9 is documentation refinement; no Swift/TypeScript/Python source was edited, deleted, built, tested,
generated, committed or pushed. Every listed document is <=200 lines. R9 supersedes only the clauses named in its six
contract sheets; R8 and older revisions remain history.

## Current read set and line counts

|File|Action|Lines|
|---|---|---:|
|[00-INDEX.md](00-INDEX.md)|updated read order/verdict|36|
|[R9-READINESS.md](R9-READINESS.md)|added final blocker ledger/verdict|39|
|[R9-CHANGELOG.md](R9-CHANGELOG.md)|added correction summary|15|
|[R9-MANIFEST.md](R9-MANIFEST.md)|added file/line-count manifest|44|
|[R9-01-CALENDAR-PLUMBING.md](R9-01-CALENDAR-PLUMBING.md)|added V5 command/gesture contract|135|
|[R9-02-RECEIPT-LIFECYCLE.md](R9-02-RECEIPT-LIFECYCLE.md)|added prepared/final/resume contract|133|
|[R9-03-EXPORT-FRAMES.md](R9-03-EXPORT-FRAMES.md)|added typed frame/chunk/backpressure contract|127|
|[R9-04-ALIAS-MIGRATION.md](R9-04-ALIAS-MIGRATION.md)|added journal/fence/recovery contract|107|
|[R9-05-HANDSHAKE-SIGNING.md](R9-05-HANDSHAKE-SIGNING.md)|added inner/detached signature contract|113|
|[R9-06-OWNERSHIP-CAPACITY.md](R9-06-OWNERSHIP-CAPACITY.md)|added canonical P00–P18/path/capacity table|83|
|[14-OWNERSHIP.json](14-OWNERSHIP.json)|updated revision-9 allowlist; compact JSON|1|

## Historical sheets updated with supersession notes

|File|Lines after R9 note|
|---|---:|
|R8-02-STORE-ID-MIGRATION.md|133|
|R8-04-CALENDAR-COMMANDS.md|114|
|R8-05-RECEIPT-IDENTITY.md|119|
|R8-06-EXPORT-STREAMING.md|97|
|R8-07-OWNERSHIP.md|63|
|R8-CHANGELOG.md|25|
|R8-MANIFEST.md|27|

## Exact R9 allowlist additions

P01: `ios/Sync/SyncTrustStore.swift`, `ios/Sync/DomainWireValues.swift`.
P03: `ios/Shared/FinanceTravelStore.swift`.
P05: `ios/Planning/PlanningMutationJournal.swift`.
P06: `ios/Planning/PlanningFilesystemPublication.swift`.
P09: `ios/Shared/FinanceTravelProjection.swift`.

These paths are each present once in `14-OWNERSHIP.json`; no Usage/Clipper replication adapter or second persistence
authority was added. The final readiness verdict is in R9-READINESS.md.
