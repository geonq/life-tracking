# Revision 14 manifest — historical correction set

Planning-only. R15 is the current authority. R14 supersedes the named R12/R13 clauses for its historical scope and
adds no source path. Every listed file is <=200 lines.

## Current files and line counts

|file|action|lines|
|---|---|---:|
|[00-INDEX.md](00-INDEX.md)|revision14 read order/verdict|30|
|[R14-READINESS.md](R14-READINESS.md)|historical three-blocker readiness|35|
|[R14-CHANGELOG.md](R14-CHANGELOG.md)|correction summary|17|
|[R14-MANIFEST.md](R14-MANIFEST.md)|this manifest|33|
|[R14-01-RECEIPT-PROGRESS.md](R14-01-RECEIPT-PROGRESS.md)|historical monotonic receipt/finalization contract|116|
|[R14-02-MANIFEST-REPRESENTATION.md](R14-02-MANIFEST-REPRESENTATION.md)|historical stored manifest authority|93|
|[R14-03-RECEIPT-RETIREMENT.md](R14-03-RECEIPT-RETIREMENT.md)|historical V8 authority/migration|111|
|[R14-04-WORKER-DISPATCH.md](R14-04-WORKER-DISPATCH.md)|historical worker prompt|28|
|[14-OWNERSHIP.json](14-OWNERSHIP.json)|historical allowlist; 203 unique paths|1|

## Affected contracts

|file|R14 treatment|
|---|---|
|R12-02-RECEIPT-BINDING-PERSISTENCE.md|R14-01 owns active V7 progress/finalization; R14-03 owns authority fencing|
|R12-03-STREAMED-MANIFEST.md|R14-02 owns stored object bytes and reconstruction|
|R13-02-MANIFEST-PRODUCTION.md|R14-01 owns receipt state; R14-02 owns representation|
|R13-03-RECEIPT-RELOCATION.md|R14-03 supersedes journal path, no-journal and retirement behavior|
|R13-04-WORKER-DISPATCH.md|R14-04 is the current dispatch prompt|
|R13-MANIFEST.md|R14 pointer and historical line-count authority; R15 is current|

P01 owns canonical JSON, carrier bytes and signature verification. P18 owns receipt progress, writer orchestration,
authority marker and migration. P16 composes only after P01/P18. R15-01…06 are now the current correction authority;
the R14 readiness verdict remains historical and external evidence gates remain open.
