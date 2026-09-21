# Revision7 authenticated epoch installation and historical-key bootstrap
Planning-only. Membership hashes are an integrity field only; owner authentication is mandatory.

## Owner-signed epoch envelope
```swift
public struct SyncEpochMemberV2: Codable, Equatable, Sendable {
 public let deviceID: String; public let keyID: String; public let publicKey: String
 public let role: SyncKeyRole; public let allowedStores: [SyncStoreKind]
}
public struct SyncMembershipPayloadV2: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let datasetID: String
 public let epochID: String; public let previousEpochID: String?; public let members: [SyncEpochMemberV2]
 public let storeIDs: [SyncStoreKind]; public let checkpointRoot: String; public let issuedAt: Date
}
public struct SyncEpochEnvelopeV2: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let ownerKeyID: String; public let ownerPublicKey: String
 public let membership: SyncMembershipPayloadV2; public let membershipHash: String; public let signature: String
}
```
All fields are required except explicit-null `previousEpochID`; version/tag are `2`/`syncEpochEnvelope`; members are
sorted unique by device ID and capped at8; storeIDs are exactly the closed 17-kind set; IDs/hashes/public keys use R4
canonical rules. `membershipHash = SHA256(CanonicalJSON(membership))`. It is checked but never substitutes for the owner
signature.

The exact owner signing input is `UTF8("LifeOS/sync-epoch/v2") + NUL + UInt32BE(C.count) + C`, where C is canonical
JSON of the envelope with only `signature` removed using the R3-00 RFC8785 subset and documented member/store sorting.
The owner Ed25519 key signs this input. `ownerKeyID` must equal
SHA-256(raw owner public key), and the pinned owner key is the device-only Keychain record for the dataset. The envelope
is itself authenticated before its member list, hash, epoch link or store permissions are trusted.

## Installation and failure path
```swift
public struct SyncTrustRecordV3: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let datasetID: String; public let ownerKeyID: String
 public let current: SyncEpochEnvelopeV2; public let historical: [SyncEpochEnvelopeV2]
 public let operationKeyIndexes: [SyncOperationKeyIndexV3]
}
public enum SyncEpochInstallError: Error, Sendable {
 case invalidCanonicalBytes, invalidSignature, ownerPinMismatch, ownerKeyIDMismatch, membershipHashMismatch
 case datasetMismatch, invalidPreviousEpoch, duplicateMember, invalidStoreSet, historicalEpochCapacity
 case revokedMember, corruptTrustStore, diskFull, cancelled
}
public actor SyncTrustStore {
 public func install(_ envelope: SyncEpochEnvelopeV2) throws -> SyncTrustRecordV3
 public func revoke(deviceID: String) throws -> SyncEpochEnvelopeV2
 public func bootstrapHistoricalKeys(_ bundle: RecoveryBundleV3) throws -> SyncTrustRecordV3
 public func lookupSourceKey(storeID: SyncStoreKind, operationHash: String, originID: String, sequence: String)
   throws -> SyncEpochMemberV2
}
```
`install` verifies bounded canonical bytes → pinned owner key → owner signature → ownerKeyID → dataset → membership
hash → member/store uniqueness → previous epoch/current fence → revocation/capacity, then atomically replaces `trust.json`.
Any failure, cancellation or disk-full leaves the prior trust record and sync fence unchanged and returns the typed error;
there is no fallback to membershipHash, current time, display name or Tailscale identity. A ninth historical envelope is
`.historicalEpochCapacity`; it is retained locally and sync pauses until an owner-signed covered reseed removes it.

## Operation-key index and new-device bootstrap
```swift
public struct SyncOperationKeyRecord: Codable, Equatable, Sendable {
 public let operationHash: String; public let originID: String; public let sequence: String
 public let sourceEpoch: String; public let sourceKeyID: String; public let signedAt: Date
}
public struct SyncOperationKeyIndexV3: Codable, Equatable, Sendable {
 public let storeID: SyncStoreKind; public let records: [SyncOperationKeyRecord]
}
```
There is exactly one index per store entry, records are sorted by `(originID, sequence, operationHash)`, and each index
is capped at10,000. This is the sole R7 bound: there is no 100,000 global index. The bundle manifest authenticates every
index through its entry hash; the index is not rebuilt from mutable current trust state. A new device runs
`bootstrapHistoricalKeys(bundle:)` before any projection: verify the owner envelope, source device member, every index
record's operation signature/hash, one-to-one `operationHashes` coverage, epoch existence and keyID membership, then
persist the historical envelopes and indexes in `trust.json`.

`lookupSourceKey` performs a bounded binary search by store/origin/sequence/hash. It rejects missing/duplicate records,
changed source epoch/key, unknown member, bad operation signature, sequence outside the signed checkpoint, an index over
10,000, or a record not covered by the bundle manifest. `archiveImport` may verify a revoked historical key for bytes
issued in that epoch; `liveAdmission` accepts only the current envelope and non-revoked member. No historical key can
authorize a new operation.

## Rotation/reseed ownership
`SyncTrustStore.prepareRotation(replacing:checkpoints:) throws -> SyncEpochEnvelopeV2` creates the next owner-signed
envelope only after checkpoint coverage; `reseed(checkpoint:bundle:) async throws -> SyncCheckpointReceipt` verifies the
same bundle, maps the target origin, restores all 17 stores and advances sequence to `max(target)+1`. Rotation/reseed
writes the envelope, index and fence before advertising a frontier. Private keys remain in `SyncIdentityStore`; the
gateway sees public keys/signatures only. Required evidence distinguishes owner-pin mismatch, forged hash, historical
verification, revoked-live rejection, index overflow, restart during install and reseed replay.

## Revision8 supersession

R8-01 is final for historical bootstrap: every retained `sourceEpoch` must be covered by a signed chain in the bundle;
R8-02 owns UUID/kind aliases and R8-03 owns all derivation bytes. This R7 sheet is retained for the V2 envelope history.
