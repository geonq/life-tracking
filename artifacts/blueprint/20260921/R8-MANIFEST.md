# Revision8 manifest

Planning-only. R8 is the current blueprint correction set. All listed documents are <=200 lines; no source edit,
deletion, build, test, xcodegen, commit or push occurred.

|File|Purpose|Lines after final check|
|---|---|---:|
|[00-INDEX.md](00-INDEX.md)|Current read order and strict dispatch rule|38|
|[R8-READINESS.md](R8-READINESS.md)|Seven-blocker verdict and external evidence gates|36|
|[R8-CHANGELOG.md](R8-CHANGELOG.md)|R8 correction record|20|
|[R8-01-HISTORICAL-EPOCH-CHAIN.md](R8-01-HISTORICAL-EPOCH-CHAIN.md)|Authenticated historical epoch chain and recovery trust install|123|
|[R8-02-STORE-ID-MIGRATION.md](R8-02-STORE-ID-MIGRATION.md)|R3 UUID/R7 kind compatibility, streams and transport|128|
|[R8-03-DERIVATION-HASHES.md](R8-03-DERIVATION-HASHES.md)|Canonical mapping, alias and UUIDv5 derivations|71|
|[R8-04-CALENDAR-COMMANDS.md](R8-04-CALENDAR-COMMANDS.md)|Complete Calendar commands, gestures and tombstones|109|
|[R8-05-RECEIPT-IDENTITY.md](R8-05-RECEIPT-IDENTITY.md)|Receipt IDs, transition hashes and bounded retry log|114|
|[R8-06-EXPORT-STREAMING.md](R8-06-EXPORT-STREAMING.md)|Bounded export frames, sink, fsync and resume|92|
|[R8-07-OWNERSHIP.md](R8-07-OWNERSHIP.md)|Canonical P00–P18 ownership/dependency table|58|
|[14-OWNERSHIP.json](14-OWNERSHIP.json)|Machine-readable revision-8 file allowlist metadata|22|
|[R8-MANIFEST.md](R8-MANIFEST.md)|R8 file/line-count manifest|24|

R7-01…06, R7-READINESS, R7-MANIFEST and R7-CHANGELOG contain explicit R8 supersession notes and remain history.
Their post-R8 line counts are recorded in R7-MANIFEST. `R8-07-OWNERSHIP.md` and `14-OWNERSHIP.json` are the only
ownership authorities; R2 packet manifests and older tables cannot authorize edits. R8 readiness is blueprint readiness,
not proof of source correctness or release completion.

The current correction set is [R9-MANIFEST.md](R9-MANIFEST.md) and [R9-READINESS.md](R9-READINESS.md); R9 supersedes
only the clauses named there while this manifest remains the R8 historical inventory.
