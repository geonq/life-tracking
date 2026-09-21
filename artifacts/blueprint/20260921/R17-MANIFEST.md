# Revision 17 manifest

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Planning-only. R17-08 is section-level precedence authority; contractFiles in14 is ordered packet authority.
No source paths added. Existing203-path allowlist and acyclic dependency graph are preserved.

## Changed files and actual line counts

|file|lines|
|---|---:|
|00-INDEX.md|31|
|11-WORKER-PROMPTS.md|126|
|14-OWNERSHIP.json|1|
|R15-01-RECEIPT-TRANSITIONS.md|170|
|R15-02-EMISSION-CURSOR.md|106|
|R15-03-CARRIER-PARTITION.md|75|
|R15-04-AUTHORITY-RECORD.md|103|
|R15-05-RELOCATION-RECOVERY.md|92|
|R15-06-WORKER-DISPATCH.md|25|
|R15-MANIFEST.md|43|
|R15-READINESS.md|39|
|R16-01-CURSOR-STATES.md|183|
|R16-02-SINK-AHEAD-RECOVERY.md|132|
|R16-03-RELOCATION-CRASH-RECOVERY.md|96|
|R16-04-POST-RETIREMENT-MUTATIONS.md|130|
|R16-05-WORKER-DISPATCH.md|29|
|R16-CHANGELOG.md|20|
|R16-MANIFEST.md|36|
|R16-READINESS.md|35|
|R17-01-LIFECYCLE.md|105|
|R17-02-CONTAINER-MIGRATION.md|90|
|R17-03-FRAMES.md|64|
|R17-04-SINK-RECOVERY.md|85|
|R17-05-AUTHORITY-RETIREMENT.md|107|
|R17-06-CHECKPOINT.md|72|
|R17-07-FILE-INVENTORY.md|82|
|R17-08-DISPATCH.md|78|
|R17-CHANGELOG.md|16|
|R17-MANIFEST.md|46|
|R17-READINESS.md|31|

## Ownership and bounds validation

All19 packets have explicit read maps. Existing path/status/fingerprint entries and dependencies are unchanged.
P01 owns pure schema/signature contracts; P18 owns persistence/recovery; P16 composes after P18-I.
R17-01…07 replace the corresponding R15/R16 sections; R17-08 lists retained clauses explicitly.
No execution/build/test/generated/dependency changes; no commit/push. Readiness is editor assessment, independent acceptance pending.
