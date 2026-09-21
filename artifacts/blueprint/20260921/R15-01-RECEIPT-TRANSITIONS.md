# Revision 15 receipt transitions, binding and migration

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R15-01 supersedes R14-01's receipt record, hash-field and finalization clauses. R15-02 owns the
canonical emission cursor used by every transition. R15 separates archive file bytes from semantic identity.

## Complete V7 persisted records

```swift
public enum LifeOSReceiptOperationKindV7: UInt8, Codable, Sendable {
  case recoveryImport = 1, dataExport = 2, dataRestore = 3, dataDeletion = 4
}
public struct LifeOSReceiptTransitionV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let sequence: UInt32; public let transitionID: UUID
  public let receiptID: UUID; public let operationKind: LifeOSReceiptOperationKindV7; public let attempt: UInt16
  public let fromPhase: LifeOSReceiptPhaseV7?; public let toPhase: LifeOSReceiptPhaseV7
  public let expectedHeadHash: String?; public let previousTransitionHash: String?
  public let cursor: LifeOSReceiptCursorV7; public let archiveHash: String?
  public let artifactFileHash: String?; public let artifactIdentityHash: String?
  public let finalizationHash: String?; public let bindingRecordHash: String?
  public let finalizationID: UUID?; public let bindingRecordID: UUID?; public let errorCode: String?
  public let createdAt: Int64; public let transitionHash: String
}
public struct LifeOSReceiptFinalizationV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let finalizationID: UUID; public let receiptID: UUID
  public let attempt: UInt16; public let operationKind: LifeOSReceiptOperationKindV7; public let archiveID: UUID?
  public let preparedArtifactID: UUID?; public let archiveHash: String?; public let manifestRootHash: String?
  public let artifactFileHash: String?; public let artifactIdentityHash: String
  public let relativePath: String; public let representation: String; public let protection: String
  public let retention: String; public let byteCount: UInt64; public let fileCount: UInt32
  public let chunkCount: UInt32; public let sinkCommitID: String; public let durableAt: Int64
  public let finalizationHash: String
}
public struct LifeOSReceiptBindingRecordV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let bindingRecordID: UUID; public let receiptID: UUID
  public let attempt: UInt16; public let finalizationID: UUID; public let archiveHash: String?
  public let artifactFileHash: String?; public let artifactIdentityHash: String; public let finalizationHash: String
  public let relativePath: String; public let representation: String; public let protection: String
  public let retention: String; public let byteCount: UInt64; public let fileCount: UInt32
  public let chunkCount: UInt32; public let boundAt: Int64; public let bindingRecordHash: String
}
public struct LifeOSReceiptCompactionAnchorV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let anchorID: UUID; public let receiptID: UUID
  public let firstRetainedSequence: UInt32; public let compactedThroughSequence: UInt32
  public let compactedThroughHash: String; public let phase: LifeOSReceiptPhaseV7
  public let cursor: LifeOSReceiptCursorV7; public let archiveHash: String?
  public let artifactFileHash: String?; public let artifactIdentityHash: String?
  public let finalizationHash: String?; public let bindingRecordHash: String?
  public let terminal: Bool; public let anchorHash: String
}
```

`LifeOSReceiptLogV7` is `{schemaVersion,receiptID,operationKind,attempt,phase,cursor,currentUnit,headHash,
archiveHash,artifactFileHash,artifactIdentityHash,finalization,bindingRecord,anchor,transitions}`. The projections
must equal the last transition or anchor; the transition chain plus anchor is authoritative. `LifeOSReceiptFileV7`
remains the three R14 domain files and contains these logs. All hashes are lowercase 64-character SHA-256 strings;
all unsigned integers use the existing decimal-string JSON adapter and all nullable keys are emitted as `null`.
`schemaVersion=7`; sequences are contiguous from 0 or `anchor.compactedThroughSequence+1`, `attempt` is 0...65535,
`relativePath` is NFC and <=128 UTF-8 bytes, and `errorCode` is null or one closed ASCII error name <=64 bytes.
`firstRetainedSequence` is <=`compactedThroughSequence+1`; `compactedThroughHash` must equal the last removed
transition hash. `anchorHash` is `SHA256(Frame("LifeOS/receipt-anchor/v7", CanonicalJSON(anchor without anchorHash)))`.
On reopen, a projection mismatch, sequence gap, invalid phase edge, hash length, nullability or anchor range is
`corruptLog`.

## Exact hash inputs and hash split

`artifactFileHash = hex(SHA256(finalArchiveFileBytes))`; it is the only hash of sink bytes. It is null for a
logical deletion operation. `artifactIdentityHash` is
`hex(SHA256(Frame("LifeOS/artifact-identity/v7", CanonicalJSON({schemaVersion:7,preparedArtifactID,archiveID,
archiveHash,manifestRootHash,relativePath,representation,protection,retention,byteCount,fileCount,chunkCount}))))`;
null identity inputs are permitted only for deletion, whose identity object contains `{schemaVersion:7,
operationKind:"dataDeletion",receiptID,attempt,relativePath,retention}`. `artifactIdentityHash` never includes
the file bytes.

`finalizationHash` is
`hex(SHA256(Frame("LifeOS/receipt-finalization/v7", CanonicalJSON(finalization without finalizationHash))))`;
the finalization object contains `artifactFileHash` and `artifactIdentityHash` (null file hash only for deletion).
`bindingRecordHash` is
`hex(SHA256(Frame("LifeOS/receipt-binding/v7", CanonicalJSON(binding record without bindingRecordHash))))`.
`transitionHash` is
`hex(SHA256(Frame("LifeOS/receipt-transition/v7", CanonicalJSON(transition without transitionHash))))`.
Each preimage includes every field shown, including nulls, IDs, sequence, cursor and previous hash.

`expectedArtifactHash` is now the typed compatibility carrier:

```swift
public struct LifeOSExpectedArtifactHashV7: Sendable {
  public let artifactFileHash: String?; public let artifactIdentityHash: String
  public let bindingRecordHash: String
}
```

The exact inputs are:

```swift
public struct LifeOSReceiptManifestFinalizationInputV7: Sendable {
  public let receiptID: UUID; public let attempt: UInt16; public let operationKind: LifeOSReceiptOperationKindV7
  public let archiveID: UUID?; public let archiveHash: String?; public let manifestRootHash: String?
  public let expectedHeadHash: String
}
public struct LifeOSReceiptArtifactFinalizationInputV7: Sendable {
  public let receiptID: UUID; public let attempt: UInt16; public let finalizationID: UUID
  public let operationKind: LifeOSReceiptOperationKindV7; public let archiveID: UUID?
  public let preparedArtifactID: UUID?; public let archiveHash: String?; public let manifestRootHash: String?
  public let artifactFileHash: String?; public let artifactIdentityHash: String; public let relativePath: String
  public let representation: String; public let protection: String; public let retention: String
  public let byteCount: UInt64; public let fileCount: UInt32; public let chunkCount: UInt32
  public let sinkCommitID: String; public let durableAt: Int64; public let expectedHeadHash: String
}
```

For archive operations the finalization input requires all archive IDs, hashes and a verified raw file hash. For
deletion it requires `operationKind=dataDeletion`, null archive/file hashes, an identity hash over the deletion
preimage and `sinkCommitID="logical-deletion:<receiptID>"`; this is a typed logical finalization, not a fake file.

`commitBound(_:expectedArtifactHash:)` requires equality with the stored three values: file hash (including null
for deletion), identity hash and binding hash. The old V6 scalar is accepted only by the migration shim as a
candidate `artifactFileHash`; it cannot commit until identity and binding hashes are recomputed and matched.

## Durable call order

`recordManifestFinalization(_:)` appends `manifestFinalized` with archive/manifest hashes. After `sink.finalize()` has
returned, P18 hashes the final file and calls `finalizeArtifact(_:)`; one atomic replacement appends
`sinkFinalized`, stores `LifeOSReceiptFinalizationV7`, and persists `finalizationHash`. It then calls
`bindArtifact(_:)`; one replacement stores the complete binding record and appends `bound`. Finally it calls
`commitBound(_:expectedArtifactHash:)`; one replacement validates all three equalities and appends `committed`.
The terminal transitions all retain the same finalization/binding IDs and hashes. A retry with the same IDs and
preimages returns the stored result; a different hash is `receiptIdentityConflict`.

`finalizeArtifact` recomputes the raw bytes hash from the fixed finalized path and recomputes the identity preimage;
input values that differ are rejected before the replacement. `bindArtifact` recomputes `finalizationHash` and
`bindingRecordHash`; `commitBound` compares the typed expected carrier to the stored finalization and binding record.

```swift
public actor LifeOSReceiptStoreV7 {
  public func finalizeArtifact(_ input: LifeOSReceiptArtifactFinalizationInputV7) throws -> LifeOSReceiptFinalizationV7
  public func bindArtifact(_ receiptID: UUID, expectedFinalizationHash: String) throws -> LifeOSReceiptBindingRecordV7
  public func commitBound(_ receiptID: UUID, expectedArtifactHash: LifeOSExpectedArtifactHashV7) throws -> LifeOSReceiptLogV7
  public func compact(_ receiptID: UUID, through sequence: UInt32) throws -> LifeOSReceiptCompactionAnchorV7
}
```

Every call validates the head/CAS, appends a transition, writes a complete temporary domain file, fsyncs, atomically
replaces and fsyncs the directory. Compaction retains a complete anchor, copies binding/finalization fields, and
retains transitions after `firstRetainedSequence`; it never compacts an active nonterminal state past its current
head. Recovery/deletion/terminal states are never represented by a digest-only anchor.

## V6 migration

Migration validates the V6 chain before writing V7. `streaming` maps from its recorded unit to `staging` or
`emitting`; `finalizing` maps to `manifestFinalized`; `bound` maps to V7 bound only when its complete binding is
present; `committed|completed|terminal` maps to committed only after the terminal chain and required hashes verify;
`failed|cancelled` remains `failed` with its error and cursor. Recovery/export/restore V6 `artifactHash` is copied
as a candidate file hash only when the final archive exists and its raw bytes hash identically; V6 `archiveHash`
maps to semantic archiveHash. The identity and binding hashes are then recomputed and compared. A deletion receipt
maps to `dataDeletion`, keeps file/semantic hashes null, and preserves its terminal intent/receipt IDs.

Missing final bytes, an ambiguous V6 scalar, absent binding, or a chain mismatch returns
`receiptMigrationNeedsArtifactFile|receiptMigrationNeedsBinding|receiptMigrationAmbiguous|corruptLog` and leaves
the V6 file untouched. A successful V7 replacement is the only migration commit. P18 owns this sheet in
`ios/Shared/LifeOSReceiptCoordinator.swift`; P01 owns canonical preimages.

## R16 current authority

R16-01 is current for the tagged `LifeOSReceiptCursorV8`, V8 receipt log and
transition delta, separate validators, pre-emission finalization record and
manifest-root-before-emission ordering. R16-02 is current for durable frame
hashes and sink-ahead recovery. This R15 sheet remains the historical source
for the complete finalization/binding hash preimages and V6 migration fields.
