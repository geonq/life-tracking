# Revision 15 manifest — final correction set

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R15 supersedes the named R12/R14 clauses and adds no source path. Every listed file is <=200 lines.

## Current files and line counts

|file|action|lines|
|---|---|---:|
|[00-INDEX.md](00-INDEX.md)|revision15 read order/verdict|37|
|[R15-READINESS.md](R15-READINESS.md)|six-blocker readiness|37|
|[R15-CHANGELOG.md](R15-CHANGELOG.md)|correction summary|22|
|[R15-MANIFEST.md](R15-MANIFEST.md)|this manifest|41|
|[R15-01-RECEIPT-TRANSITIONS.md](R15-01-RECEIPT-TRANSITIONS.md)|receipt schema, hashes, calls and migration|168|
|[R15-02-EMISSION-CURSOR.md](R15-02-EMISSION-CURSOR.md)|unified monotonic emission cursor|104|
|[R15-03-CARRIER-PARTITION.md](R15-03-CARRIER-PARTITION.md)|deterministic carrier partition/vector|73|
|[R15-04-AUTHORITY-RECORD.md](R15-04-AUTHORITY-RECORD.md)|immutable authority and authenticated mutations|101|
|[R15-05-RELOCATION-RECOVERY.md](R15-05-RELOCATION-RECOVERY.md)|inventory, intents, crash recovery and proof|90|
|[R15-06-WORKER-DISPATCH.md](R15-06-WORKER-DISPATCH.md)|current worker prompt|23|
|[14-OWNERSHIP.json](14-OWNERSHIP.json)|revision15 metadata; 203 unique paths|1|

## Affected contracts

|file|R15 treatment|
|---|---|
|R12-02-RECEIPT-BINDING-PERSISTENCE.md|R15-01 replaces single artifactHash semantics and V6 binding migration|
|R12-03-STREAMED-MANIFEST.md|R15-02/03 define cursor and partition behavior|
|R14-01-RECEIPT-PROGRESS.md|R15-01/02 supersede record and cursor details|
|R14-02-MANIFEST-REPRESENTATION.md|R15-03 supersedes partition details|
|R14-03-RECEIPT-RETIREMENT.md|R15-04/05 supersede mutable marker and recovery details|
|R14-04-WORKER-DISPATCH.md|R15-06 is the current dispatch prompt|
|R14-MANIFEST.md|R15 pointer and historical line-count authority|

P01 owns canonical bytes, partitioning and signatures. P18 owns receipt transitions, writer cursor, authority replay
and relocation. P16 composes only after P01/P18. The readiness verdict is **READY FOR LUNA** for planning only;
external evidence gates remain open.

R16 is the current correction authority. R16-01 supersedes the persisted V7
cursor, R16-02 supersedes sink crash recovery, R16-03 supersedes missing-log
bootstrap and legacy unlink recovery, and R16-04 supersedes post-retirement
write/retention behavior. R16-MANIFEST.md contains the refreshed line-count and
ownership manifest.
