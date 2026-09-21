# R16 cursor states and pre-emission finalization

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R16 supersedes the R15 cursor field shape while preserving R15
frame order and hash domains. No source, build, test, generated project,
commit or push is changed.

## One persisted cursor and exact variants

`LifeOSReceiptLogV8.cursor` is the only cursor authority. It is a tagged
`Codable, Sendable` enum; no cursor sidecar is allowed:

```swift
enum LifeOSReceiptCursorV8: Codable, Sendable {
  case staging(LifeOSStagingCursorV8)
  case manifestFinalized(LifeOSManifestFinalizedCursorV8)
  case emission(LifeOSEmissionCursorV8)
  case deletion(LifeOSDeletionCursorV8)
  case terminal(LifeOSTerminalCursorV8)
}
```

The wire tag is `kind`: `staging=1`, `manifestFinalized=2`, `emission=3`,
`deletion=4`, `terminal=5`. Every variant emits its complete object with
`schemaVersion=8`, `receiptID`, `operationKind`, and no fields from another
variant. UUIDs are lowercase strings; hashes are lowercase 64-hex strings.

```swift
struct LifeOSStagingCursorV8: Codable, Sendable {
  let schemaVersion: UInt16; let receiptID: UUID; let operationKind: LifeOSReceiptOperationKindV7
  let nextPackIndex: UInt16; let packCount: UInt16; let planHash: String?
  let stagedUnitHash: String?; let manifestRootHash: String?; let archiveHash: String?
}
struct LifeOSManifestFinalizedCursorV8: Codable, Sendable {
  let schemaVersion: UInt16; let receiptID: UUID; let operationKind: LifeOSReceiptOperationKindV7
  let finalizationID: UUID; let archiveID: UUID; let packCount: UInt16; let planHash: String
  let archiveHash: String; let manifestRootHash: String; let preEmissionFinalizationHash: String
  let firstEmissionOrdinal: UInt64
}
struct LifeOSDeletionCursorV8: Codable, Sendable {
  let schemaVersion: UInt16; let receiptID: UUID; let intentID: UUID; let targetIndex: UInt32
  let targetCount: UInt32; let targetID: UUID?; let targetPath: String?; let baseHeadHash: String
  let tombstoneHash: String?; let expectedInventoryHash: String
}
struct LifeOSTerminalCursorV8: Codable, Sendable {
  let schemaVersion: UInt16; let receiptID: UUID; let operationKind: LifeOSReceiptOperationKindV7
  let terminalPhase: LifeOSReceiptPhaseV7; let finalizationID: UUID?; let bindingRecordID: UUID?
  let archiveHash: String?; let artifactFileHash: String?; let artifactIdentityHash: String?
  let finalizationHash: String?; let bindingRecordHash: String?; let lastTransitionHash: String
}
```

`LifeOSEmissionCursorV8` has the R15 emission fields (`archiveID`, `planHash`,
`pass`, `frameKind`, `frameOrdinal`, `packIndex`, `chunkIndex`,
`relativePath`, `manifestRootHash`, `archiveHash`, `artifactFileHash`) plus
`durableFrameHash: String?`. It is the R15 global next-frame cursor, with
`schemaVersion=8`; `durableFrameHash` is null only at ordinal zero and is the
hash of ordinal `frameOrdinal-1` thereafter.

Bounds are `packCount 0...26`, `nextPackIndex 0...packCount`,
`targetCount 1...10,000`, `targetIndex < targetCount`, paths NFC and <=128
UTF-8 bytes, and every hash exactly 32 bytes. A staging cursor has null
`manifestRootHash/archiveHash` until finalization; a manifest-finalized cursor
requires both hashes and `firstEmissionOrdinal=0`; deletion has no frame or
pack fields; terminal has no next-work field.

## Separate validators and allowed transitions

The dispatcher selects exactly one validator from the operation kind and phase:

```swift
func validateStagingCursorV8(_ c: LifeOSStagingCursorV8, phase: LifeOSReceiptPhaseV7) throws
func validateManifestFinalizedCursorV8(_ c: LifeOSManifestFinalizedCursorV8) throws
func validateEmissionCursorV8(_ c: LifeOSEmissionCursorV8, plan: LifeOSEmissionPlanV7,
                              previous: LifeOSEmissionCursorV8?) throws
func validateDeletionCursorV8(_ c: LifeOSDeletionCursorV8, phase: LifeOSReceiptPhaseV7) throws
func validateTerminalCursorV8(_ c: LifeOSTerminalCursorV8) throws
func validateReceiptCursorV8(_ c: LifeOSReceiptCursorV8, phase: LifeOSReceiptPhaseV7) throws
```

`validateReceiptCursorV8` only dispatches; it does not merge rules. Staging may
repeat or advance to `manifestFinalized` for archive operations, or to
`deletion` for `dataDeletion`. `manifestFinalized` may advance only to the
initial emission cursor. Emission may repeat the same `(frameOrdinal,
durableFrameHash)` or advance by exactly one planned frame. Deletion may
repeat or increment `targetIndex`; it advances to terminal at logical sink
commit. Any archive or deletion operation may advance to terminal with
`terminalPhase=sinkFinalized`, then `bound`, then `committed`; failed/cancelled
terminal cursors stop all work. A lower ordinal, changed base head, changed
intent, changed plan or changed hash returns a typed cursor error.

## Pre-emission record and transaction

Before the first sink append, P18 writes this record inside the existing
receipt envelope, never as a sidecar:

```swift
struct LifeOSPreEmissionFinalizationV8: Codable, Sendable {
  let schemaVersion: UInt16; let finalizationID: UUID; let receiptID: UUID
  let operationKind: LifeOSReceiptOperationKindV7; let archiveID: UUID
  let packCount: UInt16; let fileCount: UInt32; let manifestCount: UInt32
  let planHash: String; let archiveHash: String; let manifestRootHash: String
  let createdAt: Int64; let preEmissionFinalizationHash: String
}
struct LifeOSPreEmissionFinalizationInputV8: Sendable {
  let record: LifeOSPreEmissionFinalizationV8; let expectedHeadHash: String
}
```

`preEmissionFinalizationHash` is
`SHA256(Frame("LifeOS/pre-emission-finalization/v8", CanonicalJSON(record
without its hash)))`. `recordPreEmissionFinalization(_:)` validates the plan,
computes the hash and atomically persists the record plus a
`manifestFinalized` transition. Its required order is: canonical objects →
manifest root → semantic archive hash → plan → pre-emission record → initial
emission cursor → sink append. A retry with the same `finalizationID` and
preimage is a no-op; a changed manifest root or archive hash is
`receiptIdentityConflict`.

```swift
public actor LifeOSReceiptStoreV8 {
  func recordPreEmissionFinalization(_ input: LifeOSPreEmissionFinalizationInputV8) throws
    -> LifeOSPreEmissionFinalizationV8
  func advanceEmission(_ input: LifeOSEmissionAdvanceV8) throws -> LifeOSReceiptLogV8
  func advanceDeletion(_ input: LifeOSDeletionAdvanceV8) throws -> LifeOSReceiptLogV8
  func reconcileSinkAhead(_ tail: LifeOSSinkTailV8) throws -> LifeOSSinkRecoveryResultV8
}
```

`LifeOSEmissionAdvanceV8` carries receipt ID, expected head hash, next cursor,
and durable frame hash. `LifeOSDeletionAdvanceV8` carries receipt ID, expected
head, intent ID, target index, tombstone hash and expected inventory hash. Each
method validates before one temp-write/fsync/atomic-replace/fsync-directory
transaction. V7 logs migrate to V8 at open; a failed migration leaves V7
untouched and returns `receiptMigrationNeedsCursorUpgrade`.

## V8 persisted delta and error surface

The emission variant is fully concrete; R15 pass/frame meanings and nullability
remain unchanged:

```swift
struct LifeOSEmissionCursorV8: Codable, Sendable {
  let schemaVersion: UInt16; let receiptID: UUID; let archiveID: UUID
  let planHash: String; let pass: LifeOSEmissionPassV7; let frameKind: LifeOSEmissionFrameKindV7
  let frameOrdinal: UInt64; let packIndex: UInt16?; let chunkIndex: UInt32?
  let relativePath: String?; let manifestRootHash: String; let archiveHash: String
  let artifactFileHash: String?; let durableFrameHash: String?
}
struct LifeOSEmissionAdvanceV8: Sendable {
  let receiptID: UUID; let expectedHeadHash: String
  let nextCursor: LifeOSEmissionCursorV8; let durableFrameHash: String?
}
struct LifeOSDeletionAdvanceV8: Sendable {
  let receiptID: UUID; let expectedHeadHash: String; let intentID: UUID
  let targetIndex: UInt32; let tombstoneHash: String; let expectedInventoryHash: String
}
struct LifeOSReceiptLogV8: Codable, Sendable {
  let schemaVersion: UInt16; let receiptID: UUID; let operationKind: LifeOSReceiptOperationKindV7
  let attempt: UInt16; let phase: LifeOSReceiptPhaseV7; let cursor: LifeOSReceiptCursorV8
  let currentUnit: String; let headHash: String; let durableFrameHash: String?
  let preEmissionFinalization: LifeOSPreEmissionFinalizationV8?
  let finalization: LifeOSReceiptFinalizationV7?; let bindingRecord: LifeOSReceiptBindingRecordV7?
  let anchor: LifeOSReceiptCompactionAnchorV7?; let transitions: [LifeOSReceiptTransitionV8]
}
```

`LifeOSReceiptTransitionV8` is R15-01's complete field set with
`schemaVersion=8`, `cursor: LifeOSReceiptCursorV8`, and
`durableFrameHash: String?`; it adds `recoveryAction: String?` with the closed
values `nil`, `sinkAheadAdopted`, or `invalidSuffixTruncated`. Its transition
hash is the R15 frame domain with the V8 canonical object. `currentUnit` is the
canonical JSON of the tagged cursor plus `durableFrameHash`; it is not a second
cursor. `transitions` is bounded to `262,144` before R16-04 checkpoint
compaction.

`LifeOSReceiptCursorErrorV8` is a closed `Error, Codable, Sendable` enum with
raw values `invalidVariant=1`, `phaseMismatch=2`, `invalidBounds=3`,
`invalidNullability=4`, `backwardCursor=5`, `cursorHashMismatch=6`,
`intentMismatch=7`, `headMismatch=8`, `receiptIdentityConflict=9`,
`receiptMigrationNeedsCursorUpgrade=10`, and `corruptLog=11`. No validator may
map a decode/type error to an empty cursor.
