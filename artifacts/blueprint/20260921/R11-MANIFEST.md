# Revision 11 manifest — final correction set

Planning-only. R11 is documentation refinement. No Swift/TypeScript/Python source, generated project, build,
test, xcodegen, commit or push was performed. Every file listed here is <=200 lines. R11 supersedes the clauses
named below; earlier revisions remain historical context.

## R11 files and line counts

|File|Action|Lines|
|---|---|---:|
|[00-INDEX.md](00-INDEX.md)|revision11 read order/verdict|35|
|[R11-READINESS.md](R11-READINESS.md)|seven-blocker readiness|36|
|[R11-CHANGELOG.md](R11-CHANGELOG.md)|correction summary|17|
|[R11-MANIFEST.md](R11-MANIFEST.md)|this manifest|47|
|[R11-01-ALIAS-PLANNING-FENCE.md](R11-01-ALIAS-PLANNING-FENCE.md)|SQL alias fence and recovery|106|
|[R11-02-HTTP-NONCE-RESPONSES.md](R11-02-HTTP-NONCE-RESPONSES.md)|response nonce/signature contract|73|
|[R11-03-BLOB-BOUNDS.md](R11-03-BLOB-BOUNDS.md)|route/blob caps|49|
|[R11-04-RECEIPT-V6-FINALIZE.md](R11-04-RECEIPT-V6-FINALIZE.md)|V6 artifact finalization|65|
|[R11-05-RECEIPT-CAPACITY.md](R11-05-RECEIPT-CAPACITY.md)|bounded progress proof|54|
|[R11-06-CALENDAR-FIELDS-CODEC.md](R11-06-CALENDAR-FIELDS-CODEC.md)|field-preserving codec|64|
|[R11-07-ARCHIVE-FOOTER-MANIFEST.md](R11-07-ARCHIVE-FOOTER-MANIFEST.md)|compact footer/manifest|57|

## Affected history and ownership

|File|Lines|R11 treatment|
|---|---:|---|
|R9-04-ALIAS-MIGRATION.md|114|R11-01 supersession note|
|R10-01-PLANNING-SQLITE.md|145|R11-01 final alias bridge|
|R10-02-HTTP-CARRIERS.md|187|R11-02/03 final response/caps|
|R10-03-CALENDAR-GESTURE-TRANSACTION.md|176|R11-06 final fields|
|R10-04-RECEIPT-PROGRESS.md|133|R11-04/05 finalization/capacity|
|R10-05-ARCHIVE-INTEGRITY.md|138|R11-07 final footer layout|
|R10-MANIFEST.md|45|R11 historical pointer|
|14-OWNERSHIP.json|1|revision11 metadata, existing 203-path allowlist; no new source path|

R11 contracts use the existing non-overlapping packets: P01 owns canonical values/codecs/bytes/errors; P02 owns
HTTP sessions and route handlers; P03 owns Calendar model/store; P05 owns Planning SQLite; P01 owns trust migration;
P06 owns filesystem staging/backup/fsync; P08 owns Calendar gestures; P18 owns receipts/archive streaming.
Dependencies are R11-01→P05/P06, R11-02→P01/P02, R11-03→R11-02/P01/P02, R11-04/05→P18, R11-06→P01/P03/P08,
and R11-07→P01/P18. No packet receives overlapping write ownership.

## Audit result

The R10 route table, receipt cadence, Calendar partial-field shape, alias JSON-only assumption and oversized-footer
assumption are explicitly historical. The R11 read order is the current authority. The allowlist still has one owner
per implementation path; R11 adds no path. All seven readiness rows are sealed, so the planning verdict is
**READY FOR LUNA**. Live/device/security/storage evidence remains external and does not change this contract verdict.

R12 is the next correction authority for trust ownership/recovery, receipt binding persistence, streamed manifests
and the V7 archive hash. Read R12 before dispatch; this R11 inventory is historical after that revision.
In particular, the historical P05 trust-migration wording above is superseded: `SyncTrustStore.swift` is P01-only
and P05 implements only the injected SQL port.
