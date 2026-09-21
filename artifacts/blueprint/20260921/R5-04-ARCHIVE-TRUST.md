# Revision5 recovery archive and historical-key contract
Supersedes the recovery/reseed paragraphs in R4-02 and R4-10. P01 owns the records and verification order;
P02 owns server/relay persistence; each domain adapter owns projection restore.

## Recovery archive records
```swift
public enum ArchiveIdentityState: String, Codable, Sendable { case unmapped, mapped, imported, rejected }
public enum ArchiveImportState: String, Codable, Sendable { case prepared, mapped, projected, committed, rejected }
public struct ArchiveMappedIdentity: Codable, Equatable, Sendable {
 public let sourceOriginID: String; public let sourceKeyID: String; public let targetOriginID: String?
 public let state: ArchiveIdentityState; public let mappingNonce: String
}
public struct ArchiveImportReceipt: Codable, Equatable, Sendable {
 public let archiveID: String; public let targetDeviceID: String; public let targetOriginID: String
 public let sourceEpoch: String; public let receiptRoot: String; public let installedFrontier: SyncFrontier
 public let state: ArchiveImportState; public let idempotencyKey: String
}
public struct RecoveryArchive<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let archiveID: String; public let datasetID: String
 public let storeID: String; public let domain: SyncDomain; public let sourceEpoch: String
 public let sourceOriginID: String; public let frontier: SyncFrontier; public let receiptRoot: String
 public let entities: [ArchivedEntity<Value>]; public let acknowledgements: [SyncAck]
 public let blobs: [ArchiveBlob]; public let mappedIdentity: ArchiveMappedIdentity
 public let importReceipt: ArchiveImportReceipt?; public let signature: String
}
```
All fields are required except explicit-null `targetOriginID` and `importReceipt`; version1. The two state enums are
closed and reject unknown strings. The archive contains the exact signed operations/receipts needed to prove `receiptRoot`,
not merely the latest values. `archiveID` and `idempotencyKey` are UUID/hash bounded by R4 rules. Raw Tax bytes,
HealthKit anchors, provider credentials and vault bookmarks remain excluded. Archive ACKs are <=10,000 (R5-06).

## Trust epochs and verification order
`SyncTrustRecord` stores `currentEpoch` plus `historicalEpochs[0...8]`, each with owner-signed membership, epoch hash,
member public keys, revocation state and checkpoint receipt roots. `SyncTrustStore.key(for:purpose:)` returns
`current` only for live admission, and `historical` or `current` for `archiveImport`; a revoked historical key may
verify an already-issued archive but can never authorize a new live operation.

`RecoveryArchiveVerifier.verify(_:)` performs, in order: bounded bytes/scanner and exact canonical re-encode;
archive signature against the owner key for `sourceEpoch`; dataset/store/domain and checkpoint/root match;
mapped-identity shape and target-device membership; every embedded operation/ACK signature against the member key
from that epoch; payload/blob hashes and typed domain validators; frontier/receipt contiguity. It returns
`historicalVerified` versus `currentVerified`; it never silently treats an old epoch as current.

## Import, mapping and rotation protocol
`SyncTrustStore.prepareImport(archive:targetDeviceID:)` validates but writes no projection. It creates a new target
origin mapping when source and target devices differ; source operations remain immutable with their original origin.
`SyncTrustStore.commitImport(_:)` atomically stores the mapping and `ArchiveImportReceipt`, then calls the typed
adapter restore. `archiveID+targetDeviceID` is unique: an identical retry returns the receipt; a different hash returns
`idCollision`. Crash after mapping but before projection resumes from the receipt state; no visible partial domain
projection or applied frontier is advertised. New local edits use target origin and parent the imported head through
the mapping record; they do not reuse the source sequence.

`install(_ membership:)` persists the owner-signed next epoch and retains the previous epoch until all checkpoint
receipts and recovery archives referencing it are covered. `reseed(checkpoint:archive:)` uses the same verifier,
mapping and typed restore, then allocates from `max(targetSequence)+1`. Epoch mismatch, unknown historical key,
bad root, revoked live member, disk-full or cancellation leaves the prior trust/frontier unchanged and the archive
retryable. A replay never re-runs a domain delete or import.

## Ownership/evidence
P01 owns `key(for:purpose:)`, `RecoveryArchiveVerifier.verify`, `prepareImport`, `commitImport` and receipt state;
P02 owns durable server mappings and DB transaction; P03/P04/P06/P13 own `restoreArchive` projection order.
Evidence must distinguish current live verification, historical archive verification, revoked-key live rejection,
rotation restart, import retry, sequence remap, disk-full and crash at each import boundary.

## Revision6 supersession
R6-04 fixes the concrete `LifeOS/recovery-archive/v2` signature bytes, epoch/index schemas and eight-epoch overflow.
R6-05 fixes receipt-first `prepareImport`/`commitImport` state transitions and crash-safe retry. Use those exact records
and signatures; this R5 text remains the historical rationale.
