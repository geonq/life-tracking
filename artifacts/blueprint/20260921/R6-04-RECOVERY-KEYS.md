# Revision6 recovery signing and key custody
Planning-only. R6 keeps SyncWireCodec v1 signatures unchanged and gives recovery archives their own signed domain.

## Canonical archive signature
```swift
public enum RecoverySignatureDomain: Sendable {
 public static let literal = "LifeOS/recovery-archive/v2"
}
public struct RecoverySigningInput: Sendable {
 public let domain: String; public let length: UInt32; public let canonicalUnsigned: Data
 public var bytes: Data { UTF8(domain) + [0] + UInt32BE(length) + canonicalUnsigned }
}
```
`RecoveryArchive.signature` is Ed25519 over `RecoverySigningInput.bytes`. The unsigned value is the archive with the
top-level `signature` omitted and `importReceipt` present as explicit null. `canonicalUnsigned` is produced by the
R4 scanner/writer: ASCII sorted object keys, preserved array order, no whitespace, R4 scalar strings, UTF-8, <=32MiB.
`archiveID`, dataset, domain, store, source epoch, frontier, receipt root, entity/ACK/blob hashes and mapping are all
inside the signed value. Signature verification happens before any projection or trust-file write.
R6's concrete archive is `RecoveryArchiveV2<Value>` with `schemaVersion == 2`, `storeID: SyncStoreKind`,
`mappedIdentity: ArchiveMappedIdentity`, `importReceipt: ArchiveImportReceiptV2?`, bounded `entities`, `acknowledgements`
and `blobs`, and `signature: String`. R5's generic `String` store ID and `ArchiveImportReceipt` name are historical
aliases only; no decoder accepts them as a v2 archive.
```swift
public struct RecoveryArchiveV2<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let archiveID: String; public let datasetID: String; public let storeID: SyncStoreKind
 public let domain: SyncDomain; public let sourceEpoch: String; public let sourceOriginID: String
 public let frontier: SyncFrontier; public let receiptRoot: String; public let entities: [ArchivedEntity<Value>]
 public let acknowledgements: [SyncAck]; public let blobs: [ArchiveBlob]; public let mappedIdentity: ArchiveMappedIdentity
 public let importReceipt: ArchiveImportReceiptV2?; public let signature: String
}
```

## Epoch records and immutable source-key lookup
```swift
public enum SyncEpochState: String, Codable, Sendable { case current, historical, revoked }
public struct SyncEpochMember: Codable, Equatable, Sendable {
 public let deviceID: String; public let keyID: String; public let publicKey: String; public let role: SyncKeyRole
}
public struct SyncTrustEpochRecord: Codable, Equatable, Sendable {
 public let epochID: String; public let previousEpochID: String?; public let state: SyncEpochState
 public let ownerKeyID: String; public let members: [SyncEpochMember]; public let membershipHash: String
 public let checkpointRoot: String; public let createdAt: Date
}
public struct SyncOperationKeyRecord: Codable, Equatable, Sendable {
 public let operationHash: String; public let sourceOriginID: String; public let sourceEpoch: String
 public let sourceKeyID: String; public let signedAt: Date
}
public struct SyncTrustRecordV2: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let datasetID: String; public let currentEpoch: SyncTrustEpochRecord
 public let historicalEpochs: [SyncTrustEpochRecord]; public let operationKeyIndex: [SyncOperationKeyRecord]
}
```
All IDs/hashes/key strings use R4 rules; member count is <=8, historical epochs are 0...8, and the operation index is
<=100,000. `trust.json` remains the only trust file. Every accepted operation appends one immutable key record before
its inbox row is made eligible; lookup uses `(operationHash, sourceOriginID)` and rejects a changed epoch/key.
Unknown fields, duplicate IDs, noncontiguous epoch links, invalid roots, and a ninth historical epoch fail closed.

## Custody and allowed secret visibility
`SyncIdentityStore` owns the device-only Keychain seed (`LifeOS.replication.v1`, dataset/role account,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); only its `sign(kind:bytes:)` method sees private bytes. Recovery
archives, widgets, UserDefaults, logs, CLI arguments and gateway requests receive public key IDs/signatures only.
The Windows relay keeps its service-role seed in the existing DPAPI-protected file; Python receives signing results, not
the seed. Provider bearer tokens remain in their existing Keychain store and never enter replication custody.
The exact generation boundary is `SyncIdentityStore.initialize(role:datasetID:) throws -> SyncPublicIdentity`; the only
private-key operation is `sign(kind:bytes:) throws -> Data`, and `retire(keyID:) throws` makes the key unusable without
deleting its historical public record. Device enrollment is an owner-signed membership install after full fingerprint
confirmation; display names, Tailscale identity and nearby invitations never enroll a device.

## Exact trust operations
```swift
public actor SyncTrustStore {
 public func verificationKey(operationHash: String, originID: String, purpose: SyncVerificationPurpose) throws -> SyncEpochMember
 public func verifyRecoverySignature(_ archiveBytes: Data) throws -> RecoveryVerificationStatus
 public func install(_ next: SyncTrustEpochRecord) throws -> SyncTrustRecordV2
 public func revoke(deviceID: String) throws -> SyncTrustEpochRecord
 public func prepareRotation(replacing: SyncPublicIdentity, checkpoints: [SyncCheckpoint]) throws -> SyncTrustEpochRecord
 public func reseed(checkpoint: SyncCheckpoint, archive: Data) async throws -> SyncCheckpointReceipt
}
public enum SyncVerificationPurpose: Sendable { case liveAdmission, archiveImport }
public enum RecoveryVerificationStatus: Sendable { case currentVerified, historicalVerified }
```
`liveAdmission` resolves only `current`; `archiveImport` resolves the immutable operation record's epoch and permits
historical verification, including a revoked epoch for already-issued bytes. It never authorizes a new live operation.

## Rotation, overflow and reseed
`install` verifies the owner signature, previous epoch link, member limits and checkpoint coverage, then atomically
replaces `trust.json`; it retains the prior epoch as historical. If eight historical records already exist, rotation
returns `.historicalEpochCapacity` and changes nothing. Only an owner-signed checkpoint/reseed that proves every indexed
operation and archive receipt is covered may compact old records; otherwise sync stays local and the user must export.
Reseed verifies the archive signature, every immutable source-key lookup, receipt root, and typed restore before advancing
the target sequence. A failure, cancellation or disk-full leaves the old trust record/frontier and a retryable receipt.

## Errors and evidence
`RecoveryKeyError` is `unknownEpoch`, `unknownKey`, `revokedLiveKey`, `invalidSignature`, `invalidRoot`,
`historicalEpochCapacity`, `rotationBusy`, `identityUnavailable`, `corruptStore`, `diskFull`, `cancelled` or
`unsupportedSchema`. Required evidence covers current/historical distinction, revoked-live rejection, forged source-key
mapping, eight-epoch overflow, restart during rotation, reseed replay and private-key non-disclosure.

## Revision7 supersession

R7-01/R7-02 replace `RecoveryArchiveV2`, its single-store 100,000 index and unsigned `SyncTrustRecordV2` path with the
owner-signed heterogeneous `RecoveryBundleV3`, authenticated `SyncEpochEnvelopeV2` and 10,000-per-store key indexes.
