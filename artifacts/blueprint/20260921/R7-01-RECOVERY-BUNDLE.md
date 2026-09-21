# Revision7 heterogeneous recovery bundle
Planning-only. R7 replaces the single-store `RecoveryArchiveV2` plus repeated import calls with one deterministic
heterogeneous package containing every replicated store. The package is a recovery input, never a live sync authority.

## Package shape
```swift
public struct RecoveryBundleManifestV3: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let bundleID: UUID; public let datasetID: String
 public let sourceOriginID: String; public let sourceEpoch: String; public let createdAt: Date
 public let requiredStores: [SyncStoreKind]; public let entries: [RecoveryStoreManifestV3]
 public let optionalSections: [RecoveryOptionalSection]; public let epochEnvelope: SyncEpochEnvelopeV2
 public let signingKeyID: String; public let signature: String
}
public struct RecoveryStoreManifestV3: Codable, Equatable, Sendable {
 public let storeID: SyncStoreKind; public let fileName: String; public let entryHash: String
 public let byteCount: UInt64; public let checkpointHash: String; public let mappingHash: String
}
public struct RecoveryStoreEntryV3: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let storeID: SyncStoreKind
 public let domain: SyncDomain; public let storeUUID: UUID; public let checkpoint: SyncCheckpoint
 public let mapping: RecoveryStoreMappingV3; public let payloadBase64URL: String; public let payloadHash: String
 public let operationHashes: [String]; public let operationKeyIndex: SyncOperationKeyIndexV3
}
public struct RecoveryBundleV3: Sendable {
 public let manifest: RecoveryBundleManifestV3; public let stores: [RecoveryStoreEntryV3]
}
```
The on-disk package is a temporary directory renamed atomically: `manifest.json` plus exactly
`stores/<SyncStoreKind.rawValue>.json` for each entry. It is not a ZIP and has no filesystem metadata authority.
`RecoveryBundleCodec.extract(_ packageURL: URL) throws -> RecoveryBundleV3` rejects symlinks, traversal, unexpected names,
duplicate files, invalid canonical bytes, entry-hash mismatch, manifest-hash mismatch and incomplete packages before
returning a bundle. `RecoveryBundleCodec.pack(_ bundle: RecoveryBundleV3, to: URL) throws` writes the same fixed layout.

## Required and optional content
`requiredStores` and `entries` must contain exactly, once and in enum order: `calendar`, `financeImports`,
`financeRecurring`, `financeInvestments`, `financeBudgets`, `financeAllocations`, `financePreferences`, `training`,
`trainingTemplates`, `meals`, `nutritionGoals`, `supplements`, `journal`, `lifestyle`, `barcodeRecords`, `vault`, `tax`.
An empty store is represented by a validated empty domain archive and an empty key index; omission is
`missingRequiredStore` and blocks the whole import. `RecoveryOptionalSection` is a closed enum of `widgetSnapshot` and
`importReceipt`; either may be absent. A missing widget is rebuilt after projection; a missing receipt is created locally.
Usage, Clipper and manual travel are never bundle stores. Their local data belongs only to R7-05 data-management packs.

## Bounds and authenticated contents
The manifest is <=1MiB; each store entry is <=32MiB encoded; the package is <=256MiB; each store has <=10,000
operation hashes, key records, ACKs, heads and conflicts. `operationHashes` are sorted unique and equal in count and
identity to `operationKeyIndex.records`; every key record is immutable and signed by its referenced source operation.
No array is
larger than 10,000, no decoded file is allocated before its bound is checked, and the package has no global 100,000
index. The manifest signature covers its canonical bytes, every entry hash, required-store list and epoch envelope.
Each entry's payload is the exact canonical bytes returned by its owning adapter; R4 domain codecs remain responsible for
its inner schema. `payloadHash` is SHA-256 of those bytes.

The bundle has its own owner signature. `RecoveryBundleSignatureDomain.literal` is
`LifeOS/recovery-bundle/v3`; `RecoveryBundleCodec.signingBytes` is
`UTF8(literal) + NUL + UInt32BE(C.count) + C`, where C is canonical JSON of `RecoveryBundleManifestV3` with only
`signature` omitted. `signingKeyID` must equal the pinned owner `ownerKeyID` in `epochEnvelope`; Ed25519 signs C's
framed bytes. C uses the R3-00 RFC8785 JSON subset: lexicographic UTF-16 object keys, no whitespace, canonical escaping,
no floating metadata, opaque base64url payloads and documented array sorting. `verify` checks canonical bytes, owner epoch signature, owner pin and then every entry hash before any
adapter sees payload bytes. `signingKeyID` is never a device display name or a Tailscale identity.

```swift
public struct RecoveryStoreMappingV3: Codable, Equatable, Sendable {
 public let sourceDatasetID: String; public let targetDatasetID: String; public let sourceStoreUUID: UUID
 public let targetStoreUUID: UUID; public let sourceOriginID: String; public let targetOriginID: String
 public let mappingHash: String
}
public enum RecoveryBundleCodec {
 public static func signingBytes(_ manifest: RecoveryBundleManifestV3) throws -> Data
 public static func verify(_ bundle: RecoveryBundleV3, pinnedOwner: Data) throws
}
```

The mapping hash is SHA-256 of canonical mapping bytes. The importer derives no identity from a filename; it receives
the mapping from the signed manifest and verifies `targetDatasetID`, target origin and deterministic target UUID before
projection. A target UUID collision with a different source mapping is `mappingCollision` and leaves the target store
unchanged.

## Adapter context and ownership
```swift
public struct RecoveryStoreContextV3: Sendable {
 public let bundleID: UUID; public let storeID: SyncStoreKind; public let checkpoint: SyncCheckpoint
 public let mapping: RecoveryStoreMappingV3; public let sourceKeyIndex: SyncOperationKeyIndexV3
}
public protocol RecoveryBundleAdapter: Sendable {
 func makeRecoveryEntry(_ context: RecoveryStoreContextV3) async throws -> RecoveryStoreEntryV3
 func restoreRecoveryEntry(_ entry: RecoveryStoreEntryV3, context: RecoveryStoreContextV3) async throws -> SyncCheckpointReceipt
}
```
`CalendarSyncAdapter` owns Calendar, `FinanceSyncAdapter` dispatches the seven finance kinds, `FitnessSyncAdapter`
dispatches the eight fitness/nutrition kinds, `PlanningSyncAdapter` owns `vault`, and `TaxSyncAdapter` owns `tax`.
Each adapter must validate that `context.checkpoint`, `context.mapping`, store UUID and key-index hash equal the signed
entry before calling its existing typed store transaction. It may not read another store's payload or select a raw path.
P01 owns `RecoveryBundleCodec` and `RecoveryBundleImporter`; P03/P04/P06/P13 own entry extraction/projection.

## Export, extraction and import call paths
```swift
public enum RecoveryBundleWriter {
 public static func make(bundleID: UUID, epochEnvelope: SyncEpochEnvelopeV2,
   checkpoints: [SyncStoreKind: SyncCheckpoint], mappings: [SyncStoreKind: RecoveryStoreMappingV3],
   adapters: [SyncStoreKind: any RecoveryBundleAdapter]) async throws -> RecoveryBundleV3
}
public enum RecoveryBundleImporter {
 public static func restore(_ bundle: RecoveryBundleV3, targetDeviceID: String, targetOriginID: String,
   adapters: [SyncStoreKind: any RecoveryBundleAdapter]) async throws -> RecoveryBundleImportReceiptV3
}
```

`RecoveryBundleWriter.make`
calls each adapter once in the required-store order, checks all 17 results, signs the manifest, then packs the temporary
directory. `RecoveryBundleImporter.restore` first verifies the manifest/owner envelope/key indexes,
creates the receipt, maps each source store UUID to its target UUID, then calls `restoreRecoveryEntry` in the same fixed
order. A store receives its checkpoint and mapping as `RecoveryStoreContextV3`; the importer never reconstructs them.

## Receipt-first retry
```swift
public enum RecoveryBundleImportState: String, Codable, Sendable {
 case prepared, mapped, projecting, interrupted, failed, committed, rejected
}
public struct RecoveryBundleImportReceiptV3: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let bundleID: UUID; public let bundleHash: String
 public let targetDeviceID: String; public let targetOriginID: String; public let state: RecoveryBundleImportState
 public let completedStores: [SyncStoreKind]; public let nextStoreIndex: Int; public let receiptHash: String
 public let parentReceiptID: UUID?; public let lastErrorCode: String?
}
```
The receipt is durably stored in `recovery-imports.json` before projection. Same bundle/device/hash resumes by
`nextStoreIndex`; committed returns its receipt; a different hash is `idCollision`. Crash after an adapter commit but
before receipt advancement is repaired by that store's operation hashes and checkpoint receipt. Cancellation/disk-full
after preparation writes `interrupted`/`failed` only when that receipt replacement succeeds; no success is returned until
all 17 projections, frontiers and widget rebuild are durable. A missing required entry, bad mapping/checkpoint, stale CAS,
conflict or adapter failure leaves prior stores intact and the receipt retryable; no rollback deletes completed stores.

The only legal transitions are `prepared → mapped → projecting → committed`, or `prepared|mapped|projecting →
interrupted|failed → mapped|projecting` on an identical retry; `rejected` is terminal before projection. `nextStoreIndex`
is the first uncommitted required-store index and `completedStores` is its exact prefix. A retry first asks that adapter
for its durable checkpoint receipt, then either records the missing receipt transition or applies once; it never trusts
the in-memory prefix. A crash at receipt write, adapter commit, widget rebuild or final commit is therefore resumable and
cannot return success early.

## Revision8 supersession

R8-01 is the final bundle contract: `RecoveryBundleV4` carries the authenticated historical epoch chain and R8-03
defines `RecoveryStoreMappingV4`; R8-05 defines receipt identity and transition hashes. R7 V3 remains migration history.
