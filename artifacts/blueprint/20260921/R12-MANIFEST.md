# Revision 12 manifest — final correction set

Planning-only. No source, build product, generated project, test result, commit or push changed. Every file listed
is <=200 lines. R12 supersedes the clauses named below; R11 and earlier remain historical context.

## Current files and line counts

|File|Action|Lines|
|---|---|---:|
|[00-INDEX.md](00-INDEX.md)|revision12 read order/verdict|30|
|[R12-READINESS.md](R12-READINESS.md)|five-blocker readiness|33|
|[R12-CHANGELOG.md](R12-CHANGELOG.md)|correction summary|24|
|[R12-MANIFEST.md](R12-MANIFEST.md)|this manifest|41|
|[R12-01-TRUST-ALIAS-RECOVERY.md](R12-01-TRUST-ALIAS-RECOVERY.md)|ownership and interrupted recovery|99|
|[R12-02-RECEIPT-BINDING-PERSISTENCE.md](R12-02-RECEIPT-BINDING-PERSISTENCE.md)|historical durable binding record|94|
|[R12-03-STREAMED-MANIFEST.md](R12-03-STREAMED-MANIFEST.md)|carrier/sink/source/verifier|126|
|[R12-04-ARCHIVE-HASH-V7.md](R12-04-ARCHIVE-HASH-V7.md)|cross-language hash bytes|109|
|[R12-05-WORKER-DISPATCH.md](R12-05-WORKER-DISPATCH.md)|current packet prompt|26|
|[14-OWNERSHIP.json](14-OWNERSHIP.json)|historical allowlist; 203 unique paths|1|

## Superseded/affected sheets

|File|R12 treatment|
|---|---|
|R11-01-ALIAS-PLANNING-FENCE.md|R12-01 ownership/recovery final|
|R11-04-RECEIPT-V6-FINALIZE.md|R12-02 binding persistence final|
|R11-07-ARCHIVE-FOOTER-MANIFEST.md|R12-03/04 streaming/hash final|
|R10-04-RECEIPT-PROGRESS.md|R12-02 log/transition fields final|
|R10-05-ARCHIVE-INTEGRITY.md|R12-03/04 V7 carrier/hash final|

## Ownership audit

P01 owns `SyncTrustStore.swift`, canonical bytes, archive hash and the alias/file/Planning port protocols. P05 owns
`PlanningMutationJournal.swift` and the SQL port implementation; P06 owns filesystem operations. P18 owns receipt
logs and manifest streaming. P16 only composes injected ports. The dependency edges are P00→P01→P05→P06 and
P01/P06/P15→P18→P16; no cycle,
duplicate trust store, receipt sidecar, materialized archive authority or second hash implementation is permitted.

R13 is the next correction authority for carrier serialization, production order and receipt relocation. Read R13
before dispatch. R12 remains historical for the trust, binding, streaming and archive-hash contracts it does not
supersede; the readiness verdict was **READY FOR LUNA** for that historical revision.
