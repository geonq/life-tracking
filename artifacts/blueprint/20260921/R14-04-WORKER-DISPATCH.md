# Revision 14 worker dispatch

Planning-only. R15-06 is the current Luna dispatch sheet. R14 is the historical ownership baseline. No source path,
store, sidecar, phase enum or manifest representation may be invented.

Read R15-01…06 before source work; stop and escalate if source evidence differs.

|packet|mandatory work|authoritative sheets|allowed existing paths|
|---|---|---|---|
|P01|Canonical JSON, frame bytes, SHA-256 domains, carrier codecs, owner/device signatures and V9 mutation verification|R15-01…04|`ios/Sync/SyncWireCodec.swift`, `ios/Sync/DomainWireValues.swift`, `ios/Sync/SyncTrustStore.swift`|
|P18|V7 receipt transitions, unified cursor, typed hashes, immutable authority, migration/retirement and staged writer|R15-01…05|`ios/Shared/LifeOSReceiptCoordinator.swift`, `ios/Shared/LifeOSDataArchiveWriter.swift`, `ios/Shared/LifeOSDataManagement.swift`|
|P16|Composition only after P01/P18 reports; invoke the named APIs and surface their closed errors|R15-01…06|existing P16 allowlist only|

## Dispatch constraints

P18 must migrate V6 receipts through the existing `currentUnit` or stop with `receiptMigrationMissingCursor`; it may
not guess a phase. `recordManifestFinalization` precedes the first unified emission cursor, emission starts at pack
zero when packs exist, and `finalizeArtifact` follows `sink.finalize()` only. `artifactFileHash`,
`artifactIdentityHash` and `bindingRecordHash` remain distinct fields alongside `archiveHash`.

P01 must treat the two canonical JSON object paths as the only manifest representation. Six carriers are derived
from and reconstructed into those bytes; no carrier file, footer hash or alternate index is persisted. P18 must use
the V9 immutable authority plus authenticated mutation log for every receipt replacement and must never inspect
legacy paths after the retirement proof.

At every packet boundary report the exact symbol, file, phase/cursor, expected hash, durable replacement order,
recovery branch and evidence. Stop for any source signature or path that differs from these sheets and open an
Astra checkpoint; do not create an adapter, journal or fallback to make the mismatch fit.
