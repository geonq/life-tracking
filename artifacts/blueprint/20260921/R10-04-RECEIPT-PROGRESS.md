# R10 receipt progress, checkpoints and bounded history

Planning-only. R10 supersedes the progress cadence and log-cap clauses in R9-02 and R9-03. A
receipt may make durable progress while remaining in the same state; progress is not forced to invent
a state transition.

## Durable progress values

```swift
public struct LifeOSReceiptCursorV6: Codable, Sendable, Comparable {
 public let packIndex: UInt16; public let fileIndex: UInt32; public let chunkIndex: UInt32
 public let completedUnits: UInt64; public let currentUnit: String?
}
public enum LifeOSReceiptStateV6: String, Codable, Sendable {
 case prepared, mapped, projecting, streaming, deleting, finalizing, bound, interrupted, failed, committed, rejected
}
public struct LifeOSReceiptV6: Codable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID; public let operationID: UUID
 public let domain: String; public let targetID: String; public let artifactKind: String
 public let preparedArtifactID: UUID; public let artifactHash: String?; public let state: LifeOSReceiptStateV6
 public let attempt: UInt16; public let createdAt: Int64; public let updatedAt: Int64
 public let cursor: LifeOSReceiptCursorV6; public let parentReceiptID: UUID?
 public let parentTransitionHash: String?; public let errorCode: String?; public let transitionHash: String
 public let sourceManifestHash: String
}
public struct LifeOSReceiptCheckpointV6: Codable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID; public let attempt: UInt16
 public let cursor: LifeOSReceiptCursorV6; public let cursorHash: String
 public let transitionHash: String; public let sourceManifestHash: String; public let createdAt: Int64
}
public struct LifeOSReceiptTransitionV6: Codable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID; public let sequence: UInt32
 public let operationID: UUID; public let domain: String
 public let targetID: String; public let artifactKind: String; public let preparedArtifactID: UUID
 public let artifactHash: String?; public let state: LifeOSReceiptStateV6; public let attempt: UInt16
 public let cursor: LifeOSReceiptCursorV6; public let createdAt: Int64; public let updatedAt: Int64
 public let parentReceiptID: UUID?; public let parentTransitionHash: String?; public let errorCode: String?
 public let sourceManifestHash: String; public let transitionHash: String
}
public struct LifeOSReceiptLogV6: Codable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID
 public let anchor: LifeOSReceiptCheckpointV6?; public let transitions: [LifeOSReceiptTransitionV6]
}
```

`LifeOSReceiptV5` is migration input only. The final receipt head is `LifeOSReceiptV6`, with
`cursor` represented by `LifeOSReceiptCursorV6`; its v6 encoding is stored in the existing
`recovery-imports.json`, `data-management-receipts.json` or `data-management-deletions.json` file.
Opening a v5 log writes a v6 temporary log after verifying its old hash chain, then atomically replaces
it; a failed conversion leaves the v5 log readable and returns `corruptLog`.
`attempt` is 1...64, timestamps are UTC milliseconds and monotone, cursor indexes are bounded by
the archive manifest, and all arrays are sorted by sequence. A log entry is canonical JSON with
unknown keys rejected.
`Comparable` orders `(packIndex,fileIndex,chunkIndex,completedUnits,currentUnit ?? "")` in that
order; a cursor may advance only in that lexicographic order.

## Same-state rule and transition bytes

The only state edges are `prepared→mapped|streaming|deleting`, `mapped→projecting`,
`projecting→bound`, `streaming|deleting→finalizing`, `finalizing→bound`, and `bound→committed`;
any active state may go to `interrupted|failed`, and those states may resume to `mapped|streaming|deleting`.
`rejected` is terminal. `advance` accepts a state change only on those edges, or accepts the same
state when the new cursor is lexicographically greater, `updatedAt` is greater, and the source
manifest hash is equal.
The same `(state,cursor,attempt,sourceManifestHash)` is an idempotent retry returning the existing
transition. A same cursor with different inputs is `receiptIdentityConflict`; a terminal receipt
cannot progress. `attempt` changes only when `interrupted|failed` resumes.

The v6 preimage is exactly:
`{schemaVersion:6,receiptID,sequence,operationID,domain,targetID,artifactKind,preparedArtifactID,
artifactHash,state,attempt,createdAt,updatedAt,packIndex,fileIndex,chunkIndex,completedUnits,
currentUnit,parentReceiptID,parentTransitionHash,errorCode,sourceManifestHash}`. Hash is
`hex(SHA256(Frame("LifeOS/receipt-transition/v6",CanonicalJSON(preimage))))`; the v6 frame is the
same domain-NUL-UInt32BE-length-payload format as R10-02. `cursorHash` is SHA-256 of the canonical
cursor object. No transition is accepted without the previous hash or a valid anchor.

## Store API and atomic order

```swift
public enum LifeOSReceiptErrorV6: Error, Sendable {
 case invalidTransition, receiptIdentityConflict, historyCapacity, historyPruned
 case corruptLog, diskFull, cancelled, sourceChanged
}
public actor LifeOSReceiptStoreV6 {
 public func prepare(_ receipt: LifeOSReceiptV6) throws -> LifeOSReceiptV6
 public func advance(_ receiptID: UUID, state: LifeOSReceiptStateV6,
   cursor: LifeOSReceiptCursorV6, sourceManifestHash: String) throws -> LifeOSReceiptV6
 public func checkpoint(_ receiptID: UUID, sourceManifestHash: String) throws -> LifeOSReceiptCheckpointV6
 public func compact(_ receiptID: UUID) throws
 public func resume(_ receiptID: UUID) throws -> LifeOSReceiptV6
}
```

Every mutation takes the actor fence, reads the current head/anchor, validates identity and bounds,
writes a complete temporary JSON log, fsyncs the file, atomically replaces the existing log, fsyncs
its directory, and then returns. `checkpoint` first verifies every referenced chunk/file/pack
manifest and stores the cursor hash plus current transition hash. The receipt head is not advanced
before the artifact evidence is durable. A crash before rename leaves the old valid log; after rename
the new chain is authoritative. Disk-full leaves the previous log and returns `diskFull`.

## 256 MiB export bound and cadence

Chunks are at most 1 MiB, so a 256 MiB archive has at most 256 chunks. A progress transition is
written after each 32 fsynced chunks and at each of at most 26 pack boundaries. File manifests and
chunk blobs are durable evidence but do not each consume a transition. One attempt therefore has an
exact maximum of `2 lifecycle entries (prepared,streaming) + 8 chunk checkpoints + 26 pack
checkpoints + 3 lifecycle entries (finalizing,bound,committed) = 39 normal transitions`; one
terminal interruption/failure may add one.

An explicit `interrupted|failed` marker adds at most one record to that attempt, so
`maxTransitionsPerAttempt=40`, `maxActiveTransitions=64` and `maxLogRecords=256` (transitions plus
anchors) are hard constants. Before an active log reaches 64, `compact` writes one checkpoint anchor
for all verified prefix transitions, fsyncs the replacement log, and prunes only transitions covered
by that anchor. Completed/failed prior attempts are compacted before a new attempt; the current
attempt's latest checkpoint is never pruned. A 256 MiB export can therefore retry without exceeding
the active bound; if no verified checkpoint can be retained, it returns `historyCapacity` and leaves
the artifact/receipt unchanged.

## Resume and crash cases

`resume` verifies the anchor chain, current transition, prepared identity and source manifest, then
scans the durable manifest from `cursor`. A chunk fsynced before a crash but before its checkpoint is
accepted by hash and skipped; a chunk without a durable hash is rewritten. A crash while replacing
the log selects the old or new complete file by hash; a crash after compaction resumes from the anchor.
If the requested cursor was pruned and the manifest cannot reconstruct it, `historyPruned` is returned
before mutation and a new receipt is required. Cancellation leaves the last renamed log; success is
reported only after `committed` is durable.

## R11 supersession

R10-04 remains the receipt schema/history. R11-04 is final for V6 artifact binding and two-step finalization;
R11-05 supersedes the 39/40 transition calculation with 106,496-file, 106,752-chunk, 213,248-work-unit bounds,
27 work checkpoints, 26 pack checkpoints and a 59-record maximum active attempt.

R12-02 supersedes the V6 binding persistence detail: `LifeOSReceiptLogV6` carries the complete binding record,
and every bound/committed transition carries its `bindingRecordHash`.
