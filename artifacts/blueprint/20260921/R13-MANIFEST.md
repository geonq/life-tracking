# Revision 13 manifest — historical correction set

Planning-only. R14 is the current authority. R13 supersedes the named R12 clauses for its historical scope and adds
no source path. Every listed file is <=200 lines.

## Current files and line counts

|file|action|lines|
|---|---|---:|
|[00-INDEX.md](00-INDEX.md)|revision13 read order/verdict|30|
|[R13-READINESS.md](R13-READINESS.md)|historical three-blocker readiness|30|
|[R13-CHANGELOG.md](R13-CHANGELOG.md)|correction summary|17|
|[R13-MANIFEST.md](R13-MANIFEST.md)|this manifest|31|
|[R13-01-CARRIER-SERIALIZATION.md](R13-01-CARRIER-SERIALIZATION.md)|six carrier schemas/codecs|141|
|[R13-02-MANIFEST-PRODUCTION.md](R13-02-MANIFEST-PRODUCTION.md)|historical staging/finalization/emission|94|
|[R13-03-RECEIPT-RELOCATION.md](R13-03-RECEIPT-RELOCATION.md)|historical receipt authority/migration|116|
|[R13-04-WORKER-DISPATCH.md](R13-04-WORKER-DISPATCH.md)|historical worker prompt|22|
|[14-OWNERSHIP.json](14-OWNERSHIP.json)|historical allowlist; 203 unique paths|1|

## R13 supersession and ownership

|affected sheet|R13 treatment|
|---|---|
|R12-02-RECEIPT-BINDING-PERSISTENCE.md|R13-03 fixes location/discovery authority|
|R12-03-STREAMED-MANIFEST.md|R13-01 fixes carrier payloads; R13-02 fixes production order|
|R12-05-WORKER-DISPATCH.md|R13-04 is the current dispatch prompt|
|R12-MANIFEST.md|R13 pointer and corrected historical line counts; R14 is current|

P01 owns carrier/canonical bytes. P18 owns production, sink durability, receipt relocation and receipt logs. P16
composes only after P01/P18. R14-01…04 are now the current correction authority; the R13 readiness verdict remains
historical and external evidence gates remain open.
