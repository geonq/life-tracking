# R8 historical epoch-chain contract

Planning-only. This sheet supersedes the R7 single-epoch field in the recovery bundle. A bundle is accepted only when
every `sourceEpoch` referenced by every retained operation-key record is covered by an authenticated chain entry.

## Bundle and chain types

```swift
public struct SyncEpochCoverageV4: Codable, Equatable, Sendable {
 public let storeID: SyncStoreKind; public let epochID: String; public let operationCount: UInt32
 public let firstSequence: String?; public let lastSequence: String?; public let operationHashRoot: String
}
public struct SyncEpochChainEntryV4: Codable, Equatable, Sendable {
 public let envelope: SyncEpochEnvelopeV2; public let envelopeHash: String
 public let previousEnvelopeHash: String?; public let coverage: [SyncEpochCoverageV4]
}
public struct SyncEpochChainV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let datasetID: String
 public let ownerKeyID: String; public let entries: [SyncEpochChainEntryV4]
 public let chainHash: String; public let signature: String
}
public struct RecoveryBundleManifestV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let bundleID: UUID; public let datasetID: String
 public let sourceOriginID: String; public let createdAt: Date; public let requiredStores: [SyncStoreKind]
 public let entries: [RecoveryStoreManifestV4]; public let epochChain: SyncEpochChainV4
 public let storeAliases: SyncStoreAliasEnvelopeV4; public let signingKeyID: String; public let signature: String
}
public struct RecoveryStoreManifestV4: Codable, Equatable, Sendable {
 public let storeID: SyncStoreKind; public let fileName: String; public let entryHash: String
 public let byteCount: UInt64; public let checkpointHash: String; public let mappingHash: String
}
public struct RecoveryStoreEntryV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let storeID: SyncStoreKind
 public let domain: SyncDomain; public let storeUUID: UUID; public let checkpoint: SyncCheckpoint
 public let mapping: RecoveryStoreMappingV4; public let payloadBase64URL: String; public let payloadHash: String
 public let operationHashes: [String]; public let operationKeyIndex: SyncOperationKeyIndexV3
}
public struct RecoveryBundleV4: Sendable { public let manifest: RecoveryBundleManifestV4; public let stores: [RecoveryStoreEntryV4] }
public struct RecoveryStoreContextV4: Sendable {
 public let bundleID: UUID; public let storeID: SyncStoreKind; public let checkpoint: SyncCheckpoint
 public let mapping: RecoveryStoreMappingV4; public let sourceKeyIndex: SyncOperationKeyIndexV3
}
public enum RecoveryBundleCodecV4 {
 public static func extract(_ packageURL: URL) throws -> RecoveryBundleV4
 public static func pack(_ bundle: RecoveryBundleV4, to packageURL: URL) throws
 public static func verify(_ bundle: RecoveryBundleV4, pinnedOwner: Data) throws
}
public protocol RecoveryBundleAdapterV4: Sendable {
 func makeRecoveryEntry(_ context: RecoveryStoreContextV4) async throws -> RecoveryStoreEntryV4
 func restoreRecoveryEntry(_ entry: RecoveryStoreEntryV4, context: RecoveryStoreContextV4)
   async throws -> SyncCheckpointReceipt
}
public enum RecoveryBundleWriterV4 {
 public static func make(bundleID: UUID, datasetID: String, sourceOriginID: String,
   epochChain: SyncEpochChainV4, storeAliases: SyncStoreAliasEnvelopeV4,
   checkpoints: [SyncStoreKind: SyncCheckpoint], mappings: [SyncStoreKind: RecoveryStoreMappingV4],
   adapters: [SyncStoreKind: any RecoveryBundleAdapterV4]) async throws -> RecoveryBundleV4
}
public enum RecoveryBundleImporterV4 {
 public static func restore(_ bundle: RecoveryBundleV4, targetDeviceID: String, targetOriginID: String,
   adapters: [SyncStoreKind: any RecoveryBundleAdapterV4]) async throws -> RecoveryBundleImportReceiptV4
}
```

`requiredStores` and `entries` contain the closed 17-store set once, in `SyncStoreKind` order. Empty stores still have
an entry and an empty key index. The package is a temporary directory with `manifest.json` and exactly
`stores/<kind.rawValue>.json`; `RecoveryBundleCodecV4.extract/pack` rejects symlinks, traversal, duplicate names and
unexpected files before decoding. Bounds are: manifest 1 MiB, entry 32 MiB, package 256 MiB, nine chain entries,
17 coverage rows per entry, 10,000 operation hashes/key records per store, and 10,000 total records per index.

## Chain coverage and signing bytes

Entries are ordered oldest to newest. The first has `previousEnvelopeHash == nil`; each later entry has the immediately
previous `envelopeHash`. `epochID` and `envelopeHash` are unique, the envelope dataset and owner match the chain, and
the chain has at most eight historical epochs plus the current epoch. `envelopeHash` is
`SHA256(CanonicalJSON(envelope))`, including its existing signature. For each store/epoch, sort operation hashes by
`(originID, sequence, operationHash)` and compute `operationHashRoot` as
`SHA256(UTF8("LifeOS/recovery-epoch-coverage/v4") + NUL + UInt32BE(C.count) + C)`, where C is canonical JSON of the
sorted hash strings. `operationCount`, first/last sequence and root must equal the entry's key-index records.
Coverage contains exactly one row per closed store, sorted by `storeID.rawValue`; an empty row has count zero and both
sequence fields null. Nonempty rows have both sequences, a nonblank epoch ID and a root; duplicate store/epoch rows are
rejected before signature verification completes.

`SyncEpochChainV4` signing bytes are
`UTF8("LifeOS/sync-epoch-chain/v4") + NUL + UInt32BE(C.count) + C`, where C is canonical JSON of the chain with only
`signature` omitted, including entry order and coverage. The pinned owner Ed25519 key signs those bytes. The outer
manifest uses `UTF8("LifeOS/recovery-bundle/v4") + NUL + UInt32BE(C.count) + C`, where C is canonical JSON with only
`signature` omitted and includes each entry hash, `chainHash` and alias-envelope hash. R3-00 canonical JSON rules apply:
UTF-16 key order, no whitespace, canonical escaping, no floats in metadata, and documented sorted arrays.
Before signing, `chainHash` is `hex(SHA256(Frame("LifeOS/sync-epoch-chain-hash/v4", C0)))`, where C0 is canonical JSON
of `schemaVersion,tag,datasetID,ownerKeyID,entries` with both `chainHash` and `signature` omitted. The signed C then
includes that computed chainHash. Every coverage row has `sourceEpoch == epochID`; a key record with another source epoch
is an uncovered operation and is rejected.

## New-device verification and trust persistence

```swift
public actor SyncTrustStore {
 public func bootstrapHistoricalKeys(_ bundle: RecoveryBundleV4) async throws -> SyncTrustRecordV4
 public func lookupSourceKey(storeID: SyncStoreKind, operationHash: String, originID: String, sequence: String)
   throws -> SyncEpochMemberV2
}
public struct SyncTrustRecordV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let datasetID: String; public let ownerKeyID: String
 public let currentEpochID: String; public let epochChain: SyncEpochChainV4
 public let operationKeyIndexes: [SyncOperationKeyIndexV3]; public let storeAliases: SyncStoreAliasEnvelopeV4
 public let installedBundleID: UUID; public let trustHash: String
}
```

`bootstrapHistoricalKeys` verifies canonical bounds, pinned owner, outer signature, alias signature, chain signature,
chain links/order, every embedded epoch signature, dataset/store permissions, every operation signature and hash, and
one-to-one coverage between `operationHashes`, key records and chain coverage. A `sourceEpoch` missing from the chain,
an unreferenced chain epoch, duplicate record, revoked current member, invalid signature or sequence fence returns a typed
error and leaves the existing `trust.json` and sync fence unchanged. Successful installation writes one atomic
`trust.json` containing the chain, indexes and aliases; no projection or live advertisement happens before that write.
Historical keys verify archived bytes only. `liveAdmission` accepts only the current, non-revoked epoch. Cancellation,
disk-full and restart before the final rename preserve the old trust record; retry repeats verification idempotently.

`R7 RecoveryBundleV3` is readable only when all operations use its single `epochEnvelope`; otherwise it returns
`historicalEpochChainRequired`. V4 is the only writer after migration. `RecoveryBundleCodecV4.verify`,
`SyncTrustStore.bootstrapHistoricalKeys`, and `RecoveryBundleImporterV4.restore` are owned by P01; domain adapters only
receive a verified `RecoveryStoreEntryV4` and cannot install trust.
