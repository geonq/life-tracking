# Revision9 readiness

Planning-only. R9 changes only documents under `artifacts/blueprint/20260921/`; no source was edited, deleted,
built, tested, generated, committed or pushed.

## Verdict

**READY FOR LUNA — all seven independent-review blockers are sealed for implementation.**

|Blocker|Final contract|Authority|
|---|---|---|
|Calendar command plumbing|V5 original/draft fields, intent/generation, delete scope, viewport types, CAS and separate call paths|R9-01|
|Receipt preparation/finalization|Prepared artifact ID/hash-null state, deletion artifact, durable bind and terminal transitions|R9-02|
|Receipt projection/resume|Concrete common receipt includes attempt/timestamps/pack-file-chunk cursor and every hash input|R9-02|
|Export framing/chunks|Typed header/file/chunk/footer bytes, chunk-derived digest, <=1 MiB chunks and awaitable bounded sink|R9-03|
|Store-ID alias migration|18-path journal, staged hashes, owner fence, resumable cursor and mixed-set fail-closed recovery|R9-04|
|Handshake|Signed inner envelope plus detached HTTP carrier, canonical bytes, ordered verification and P02 mapping|R9-05|
|Allowlist/capacity|One P00–P18 table, required paths added once, and 4 MiB/32 MiB/2 MiB outcomes|R9-06 + 14-OWNERSHIP.json|

## Readiness audit

R9 cross-checked every newly introduced type and named function against R9-01…06, retained R8 clauses and the JSON
allowlist. `SyncTrustStore.swift`, `DomainWireValues.swift`, `PlanningMutationJournal.swift`,
`PlanningFilesystemPublication.swift`, `FinanceTravelStore.swift` and `FinanceTravelProjection.swift` have one
explicit owner. `UsageSyncAdapter` and `ClipperSyncAdapter` remain local/read-only and are not replication packets.
The final persisted replication wrapper remains `SyncAdapterEnvelopeV2`; JSON domain inbox/ACK/frontier state stays in
the existing envelope and Planning stays in its existing `journal.sqlite`. No second database or sidecar authority is
introduced.

The seven review contradictions therefore have no remaining architecture blocker. A Luna worker must still stop on
source evidence that contradicts a type, byte rule, path or transaction order and request an Astra contract amendment;
that is execution review, not an unresolved design choice.

## True external evidence gates

Implementation and release still require live gateway/Windows outage proof, real Enable Banking/Trade Republic/Robinhood
fixtures, physical iPhone HealthKit/Zepp behavior, iCloud Obsidian permission, Personal Team signing/App Group and
seven-day renewal, installed SDK/device captures, visual/motion acceptance, security/penetration evidence and storage
telemetry. These gates cannot be sealed by documentation and do not change the blueprint verdict.
