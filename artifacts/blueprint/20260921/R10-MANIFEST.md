# Revision 10 manifest — final contract correction

Planning-only. R10 is documentation refinement. No Swift/TypeScript/Python source was edited, deleted,
built, tested, generated, committed or pushed. Every listed file is <=200 lines. R10 supersedes the
clauses named in its five sheets; R9 and older revisions remain history.

## Current read set and line counts

|File|Action|Lines|
|---|---|---:|
|[00-INDEX.md](00-INDEX.md)|updated R10 read order/verdict|37|
|[R10-READINESS.md](R10-READINESS.md)|sealed five blockers and gates|38|
|[R10-CHANGELOG.md](R10-CHANGELOG.md)|summarized corrections|20|
|[R10-MANIFEST.md](R10-MANIFEST.md)|this manifest|45|
|[R10-01-PLANNING-SQLITE.md](R10-01-PLANNING-SQLITE.md)|SQLite/file-journal authority and migration|143|
|[R10-02-HTTP-CARRIERS.md](R10-02-HTTP-CARRIERS.md)|route carriers and verification|185|
|[R10-03-CALENDAR-GESTURE-TRANSACTION.md](R10-03-CALENDAR-GESTURE-TRANSACTION.md)|calendar V6 inputs and transactions|175|
|[R10-04-RECEIPT-PROGRESS.md](R10-04-RECEIPT-PROGRESS.md)|progress/checkpoint/compaction contract|132|
|[R10-05-ARCHIVE-INTEGRITY.md](R10-05-ARCHIVE-INTEGRITY.md)|frame kinds and identity digests|137|
|[14-OWNERSHIP.json](14-OWNERSHIP.json)|metadata revision 10; unchanged packet paths|1|

## Historical sheets with R10 supersession notes

|File|Lines after note|
|---|---:|
|R9-01-CALENDAR-PLUMBING.md|140|
|R9-02-RECEIPT-LIFECYCLE.md|138|
|R9-03-EXPORT-FRAMES.md|132|
|R9-05-HANDSHAKE-SIGNING.md|118|
|R9-06-OWNERSHIP-CAPACITY.md|88|
|R7-03-LEDGER-ENVELOPE.md|122|
|R7-05-DATA-MANAGEMENT.md|162|
|R3-01-HTTP.md|61|
|R3-02-TRANSACTIONS.md|65|

`R9-04-ALIAS-MIGRATION.md` was later amended by R11-01; the R9 manifest, readiness and changelog remain
historical records. R11 supersedes the affected R10 clauses and is the current plan authority; this R10
manifest remains a historical revision record.

R12 is the current correction authority after R11; this file is retained only as the R10 inventory.

## Ownership and audit result

`14-OWNERSHIP.json` retains one non-overlapping P00–P18 path owner and adds no new implementation path;
R10 only refines contracts at existing P01/P02/P03/P05/P06/P08/P18 boundaries. `jq empty` and a unique
path audit are required before dispatch. The readiness verdict is **READY FOR LUNA** for planning only;
external release evidence remains open.
