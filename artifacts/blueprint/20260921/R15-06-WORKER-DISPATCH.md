# Revision 15 worker dispatch

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. This is the current Luna dispatch sheet. R15 closes receipt transition/hash, unified cursor,
partition, authority and relocation-recovery gaps without adding source paths.

|packet|exclusive R15 work|authoritative sheets|existing owners/paths|
|---|---|---|---|
|P01|Transition/preimage codecs, canonical partition, owner/device signatures and mutation-frame verification|R15-01…04|`ios/Sync/SyncWireCodec.swift`, `ios/Sync/DomainWireValues.swift`, `ios/Sync/SyncTrustStore.swift`|
|P18|Receipt transition store, unified writer cursor, finalization/binding calls, V9 authority replay and relocation proof|R15-01…05|`ios/Shared/LifeOSReceiptCoordinator.swift`, `ios/Shared/LifeOSDataArchiveWriter.swift`, `ios/Shared/LifeOSDataManagement.swift`|
|P16|Composition after P01/P18; no schema, cursor, path or hash decisions|R15-01…06|existing P16 allowlist in `14-OWNERSHIP.json`|

The old scalar `expectedArtifactHash`, R14 cursor, mutable `relocation-v8.json` marker and any carrier-side
partitioner are not implementation choices. Workers use the typed R15 contracts and stop for source evidence that
differs. P18 persists sinkFinalized, bound and committed through the named atomic calls; P01 owns all canonical
bytes and signatures. No worker may add a sidecar, receipt log, mutable authority state or second manifest.

Each report must include exact symbol/path, transition sequence, cursor/pass/frame, file/identity/binding hashes,
signature/preimage, source fingerprint, append/replace/fsync order, crash branch, error mapping and evidence. P16
does not proceed until P01 and P18 reports agree on the same hashes and planHash.

R16-05 is now the current dispatch sheet. It supersedes this sheet's cursor,
sink recovery, authority bootstrap and retirement wording while retaining the
P01/P18/P16 path ownership and stop-on-source-evidence rule.
