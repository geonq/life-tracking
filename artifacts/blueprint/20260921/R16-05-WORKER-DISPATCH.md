# Revision 16 worker dispatch

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R16 seals cursor variants, sink-ahead recovery, authority
bootstrap/unlink recovery and post-retirement mutation rules. It adds no source
path and does not authorize source edits until the worker reads the current
allowlist.

|packet|exclusive R16 responsibility|required sheets|existing owner paths|
|---|---|---|---|
|P01|V8 cursor/frame/preimage codecs, durable frame hash, authority intent/proof/checkpoint bytes, signatures and errors|R16-01…04|`ios/Sync/SyncWireCodec.swift`, `ios/Sync/DomainWireValues.swift`, `ios/Sync/SyncTrustStore.swift`|
|P18|Receipt V8 persistence/migration, sink discovery/adoption/truncation, authority actor, filesystem/fsync/CAS/replay and bounded rotation|R16-01…04|`ios/Shared/LifeOSReceiptCoordinator.swift`, `ios/Shared/LifeOSDataArchiveWriter.swift`, `ios/Shared/LifeOSDataManagement.swift`|
|P16|Call composition only after P01/P18 reports agree; no new schema, store, sidecar, path, cursor or hash|R16-01…05|existing P16 allowlist in `14-OWNERSHIP.json`|

Dispatch order is P01 codec/error surface → P18 receipt/sink → P18 authority
replay → P16 composition. The implementation report must name the exact
source symbol, cursor variant, phase edge, frame ordinal/hash, authority
sequence/previous hash, fsync boundary, crash branch and evidence. A worker
stops if the repository lacks a named symbol or the actual V7 envelope cannot
be migrated to the R16 V8 tagged cursor; it does not infer a second store.

R16 rejects: a cursor sidecar, receipt rewind, a sink frame without an ordinal
and hash, automatic reconstruction of an authority log, absence-only retirement
without a pending authenticated intent, mutation of the historical proof, an
unbounded append log, or direct legacy reads after retirement. P16 must call
`reconcileSinkAhead`, `bootstrapExistingAuthority`,
`recoverPendingLegacyRetirement`, and the post-retirement actor methods rather
than reproduce their logic.
