# Revision7 manifest
Planning-only. R7 is the current blueprint correction set; R6 and earlier revisions remain history.

|File|Purpose|Lines after final check|
|---|---|---:|
|[R7-READINESS.md](R7-READINESS.md)|Strict verdict, blocker closures and external evidence gates|36|
|[R7-CHANGELOG.md](R7-CHANGELOG.md)|Concise R7 correction record|20|
|[R7-01-RECOVERY-BUNDLE.md](R7-01-RECOVERY-BUNDLE.md)|17-store recovery package, signing, mapping and retry|143|
|[R7-02-EPOCH-BOOTSTRAP.md](R7-02-EPOCH-BOOTSTRAP.md)|Owner-signed epochs and historical-key bootstrap|91|
|[R7-03-LEDGER-ENVELOPE.md](R7-03-LEDGER-ENVELOPE.md)|Single persisted envelope, adapter surface and migration|117|
|[R7-04-CALENDAR-COMMITS.md](R7-04-CALENDAR-COMMITS.md)|Local/replicated Calendar transactions and gestures|145|
|[R7-05-DATA-MANAGEMENT.md](R7-05-DATA-MANAGEMENT.md)|26-pack directory archive, receipts and interruption recovery|157|
|[R7-06-AUDIT-NO-GUESSING.md](R7-06-AUDIT-NO-GUESSING.md)|R6 contradiction audit, packet ownership and checklist|110|

## Read and supersession rule

Read R7-READINESS, R7-CHANGELOG, R7-01 through R7-06, then the owning R4/R5 sheets named by R6-MANIFEST. R7-01…06
supersede conflicting R6 statements. R6/R5/R4 files are retained as history and must not be used to reintroduce a
single-store archive, a 100,000 key index, `SyncLedgerV1` as final storage, local Calendar commits without operations,
or a partial data registry. No source code is part of this manifest.

## Revision8 supersession

R8-MANIFEST is the current line-count and revision manifest. R7 files remain immutable planning history.
