# R9 receipt preparation, projection and finalization

Planning-only. This sheet supersedes R8-05. P18 owns receipt files and `LifeOSReceiptCoordinator`; P01 owns the
canonical hash/framing primitive; domain packets own the transaction marker that proves their projection.

## Prepared identity is separate from final artifact hash

```swift
public enum LifeOSArtifactKindV5: String, Codable, Sendable {
 case recoveryBundle, dataExport, dataRestore, deletionJournal
}
public enum LifeOSReceiptStateV5: String, Codable, Sendable {
 case prepared, mapped, projecting, streaming, deleting, finalizing, bound
 case interrupted, failed, committed, rejected
}
public struct LifeOSPreparedArtifactV5: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID; public let operationID: UUID
 public let domain: LifeOSReceiptDomainV5; public let targetID: String; public let artifactKind: LifeOSArtifactKindV5
 public let preparedArtifactID: UUID; public let preparedAt: Date; public let preparationHash: String
}
public struct LifeOSReceiptCursorV5: Codable, Equatable, Sendable {
 public let packIndex: UInt16; public let fileIndex: UInt32; public let chunkIndex: UInt32
 public let completedUnits: UInt64; public let currentUnit: String?
}
public struct LifeOSReceiptV5: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID; public let operationID: UUID
 public let domain: LifeOSReceiptDomainV5; public let targetID: String; public let artifactKind: LifeOSArtifactKindV5
 public let preparedArtifactID: UUID; public let artifactHash: String?; public let state: LifeOSReceiptStateV5
 public let attempt: UInt32; public let createdAt: Date; public let updatedAt: Date
 public let cursor: LifeOSReceiptCursorV5; public let parentReceiptID: UUID?; public let parentTransitionHash: String
 public let errorCode: LifeOSReceiptErrorCodeV5?; public let transitionHash: String
}
public enum LifeOSReceiptDomainV5: String, Codable, Sendable {
 case recoveryImport, dataExport, dataRestore, dataDeletion
}
public enum LifeOSReceiptErrorCodeV5: String, Codable, Sendable {
 case invalidArchive, receiptIdentityConflict, gatewayUnavailable, cancelled, diskFull, corruptTarget
 case verificationFailed, staleTarget, historyPruned, operationReuse, capacity, aliasRecoveryBlocked
}
public struct LifeOSReceiptAnchorV5: Codable, Sendable {
 public let receiptID: UUID; public let operationID: UUID; public let preparedArtifactID: UUID
 public let artifactHash: String; public let terminalState: LifeOSReceiptStateV5
 public let terminalTransitionHash: String; public let prunedAt: Date
}
public struct LifeOSReceiptLogV5: Codable, Sendable {
 public let schemaVersion: Int; public let transitions: [LifeOSReceiptV5]
 public let anchors: [LifeOSReceiptAnchorV5]; public let logHash: String
}
public struct RecoveryBundleImportReceiptV5: Codable, Sendable {
 public let common: LifeOSReceiptV5; public let bundleID: UUID; public let targetDeviceID: String
 public let targetOriginID: String; public let completedStores: [SyncStoreKind]
}
public struct LifeOSDataReceiptV5: Codable, Sendable {
 public let common: LifeOSReceiptV5; public let archiveID: UUID; public let representation: LifeOSArchiveRepresentationV5
 public let protection: LifeOSArchiveProtectionV5; public let retentionPolicy: LifeOSArchiveRetentionV5
}
public struct LifeOSProjectionMarkerV5: Codable, Sendable {
 public let receiptID: UUID; public let preparedArtifactID: UUID; public let storeID: SyncStoreKind
 public let sourceHash: String; public let projectionVersion: Int
 public let packIndex: UInt16; public let fileIndex: UInt32; public let chunkIndex: UInt32
}
public actor LifeOSReceiptCoordinator {
 public func prepare(datasetID: UUID, domain: LifeOSReceiptDomainV5, operationID: UUID, targetID: String,
   artifactKind: LifeOSArtifactKindV5) async throws -> LifeOSReceiptV5
 public func append(_ receipt: LifeOSReceiptV5) async throws
 public func advance(_ receiptID: UUID, state: LifeOSReceiptStateV5, cursor: LifeOSReceiptCursorV5,
   artifactHash: String?, error: LifeOSReceiptErrorCodeV5?) async throws -> LifeOSReceiptV5
 public func bind(_ receiptID: UUID, artifactHash: String) async throws -> LifeOSReceiptV5
 public func resume(_ receiptID: UUID) async throws -> LifeOSReceiptV5
 public func prune() async throws
}
```

`preparedArtifactID` is deterministic before reading any output. Its UUIDv5 name bytes are
`Frame("LifeOS/receipt-artifact/v5", UInt32BE(16)+datasetID.uuidBytes+len(domain)+UTF8(domain)+operationID.uuidBytes+
len(targetID)+UTF8(targetID)+len(artifactKind)+UTF8(artifactKind))`. `receiptID` is UUIDv5 over
`Frame("LifeOS/receipt-id/v5",datasetID.uuidBytes+operationID.uuidBytes+preparedArtifactID.uuidBytes+targetID+domain)`;
it never includes `artifactHash`. `preparationHash` hashes the prepared identity fields only. All strings are
length-prefixed UTF-8; UUIDs are 16 raw bytes; dates are UTC RFC3339 milliseconds.

For a deletion, `artifactKind=deletionJournal`, `preparedArtifactID` identifies
`Application Support/LifeOS/DataManagement/delete-journal.json`, and the final `artifactHash` is the SHA-256 of the
canonical deletion manifest containing sorted store IDs, old file hashes, deletion fence ID and completed store
markers. It is never the hash of an empty payload. A recovery bundle stores `bundleID` as its typed source identity;
an export/restore stores `archiveID`; both use the separate deterministic `preparedArtifactID` in the common receipt.
V4 `artifactHash`-based receipt IDs decode as historical receipts and are mapped
to the V5 prepared ID only after the old receipt hash verifies.

## Transition hash and concrete receipts

The transition preimage is canonical JSON with exactly these keys and no others:
`schemaVersion,receiptID,operationID,domain,targetID,artifactKind,preparedArtifactID,artifactHash,state,attempt,
createdAt,updatedAt,packIndex,fileIndex,chunkIndex,completedUnits,currentUnit,parentReceiptID,parentTransitionHash,
errorCode`. `artifactHash` and nullable fields encode JSON `null`; dates use the format above. The hash is
`hex(SHA256(Frame("LifeOS/receipt-transition/v5",CanonicalJSON(preimage))))`, where
`Frame(label,C)=UTF8(label)+0x00+UInt32BE(byteCount(C))+C`. `transitionHash` is the only excluded field.
`logHash=hex(SHA256(Frame("LifeOS/receipt-log/v5",CanonicalJSON({schemaVersion,transitions,anchors}))))`; transitions
are sorted by `(operationID,attempt,updatedAt,transitionHash)` and anchors by `(operationID,prunedAt)` before hashing.

`RecoveryBundleImportReceiptV5` and `LifeOSDataReceiptV5` are concrete Codable projections containing every field in
`LifeOSReceiptV5` plus their typed identity fields: recovery adds `bundleID,targetDeviceID,targetOriginID`; data adds
`archiveID,representation,protection,retentionPolicy`. Their custom `init(from:)` encodes the common fields flat at the
top level (there is no wire-level `common` key), reconstructs the common receipt and rejects any omitted transition
input. The common receipt is authoritative; typed projections are atomically updated
with it and must have identical cursor/hash/state.

## State machine and durable binding

Allowed edges are `prepared→mapped|streaming|deleting`, `mapped→projecting`, `projecting→bound`,
`streaming→finalizing`, `deleting→finalizing`, `finalizing→bound`, `bound→committed`. Any active state may become
`interrupted` on cancellation or `failed` on a retryable I/O error; `interrupted|failed→mapped|streaming|deleting`
increments `attempt` (maximum 64). `rejected` is terminal. `createdAt` and `preparedArtifactID` never change;
`updatedAt` is monotone and is written in the same transition as the new cursor.

The exact export order is: (1) allocate operation ID and prepared artifact ID; (2) atomically append `prepared` to
`data-management-receipts.json`; (3) create the partial artifact and append `streaming` with cursor zero; (4) after
each fsynced chunk/file/pack, atomically persist the next cursor and append the matching transition; (5) fsync and
rename the final manifest, compute `artifactHash`; (6) atomically write `{receiptID,preparedArtifactID,artifactHash}`
to the final manifest and append `bound`; (7) append `committed`. A crash before step 6 has `artifactHash=null` and
resumes from the last cursor. No caller may return success before step 7.

Recovery is `prepared→mapped→projecting`; each domain adapter writes its envelope plus
`(receiptID,preparedArtifactID,storeID,sourceHash,projectionVersion)` marker in its own existing envelope transaction,
then P18 advances `packIndex/store cursor`. After the last marker, P18 binds the bundle hash and commits. Deletion
uses the same order with `deleting`; each adapter writes a deletion marker before removing its data, and the final
deletion manifest is bound only after every required store is gone.

`LifeOSReceiptCoordinator.resume(_:)` reads the common receipt, verifies its transition hash chain, compares the
durable marker/file at the authoritative **next** cursor, and replays only work after that cursor. Same receipt,
operation, prepared ID and source hash is idempotent; a different source/artifact identity returns
`receiptIdentityConflict` before mutation. Cancellation leaves the last committed cursor; disk-full leaves the
partial artifact and returns `diskFull`. Log files remain `recovery-imports.json`, `data-management-receipts.json` and
`data-management-deletions.json`, each capped at 256 transitions+anchors with active receipts retained.

## Revision10 supersession

R10-04 replaces per-chunk transition wording with same-state progress, checkpoint cadence, compaction
and bounded resumable receipt history.
