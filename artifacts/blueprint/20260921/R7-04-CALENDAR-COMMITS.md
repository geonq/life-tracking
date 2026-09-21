# Revision7 Calendar local/replicated commit contract
Planning-only. This supersedes the R6 sentence that left local Calendar edits outside operation allocation.

## Final values and return type

```swift
public struct CalendarLocalEditIntent: Sendable {
 public let intentID: UUID; public let generation: UInt64; public let itemID: String
 public let baseHead: String?; public let originalInterval: DateInterval
 public let draftInterval: DateInterval; public let resizeEdge: CalendarResizeEdge
}
public struct CalendarSeriesCommitResult: Codable, Equatable, Sendable {
 public let receipt: SyncCommitReceipt; public let generation: UInt64; public let intentID: UUID
}
public struct CalendarLocalCommitReceipt: Codable, Equatable, Sendable {
 public let operationID: UUID; public let receipt: SyncCommitReceipt; public let generation: UInt64
 public let intentID: UUID; public let outboxState: SyncOutboxState
}
```

`SyncCommitReceipt` is the returned commit proof; it is not an input because the committing store creates it. The
canonical replicated signatures are therefore exactly:

```swift
public func CalendarStore.commitReplicatedSeries(_ payload: CalendarSeriesPayload,
 operation: SyncOperation, generation: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResult
public func CalendarStore.commitReplicatedDeletion(_ intent: DeleteIntent,
 operation: SyncOperation, generation: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResult
```

The returned receipt's `mutationID` equals `operation.mutationID`; for Calendar v2 it must be `intentID.uuidString`.
Legacy non-UUID mutation IDs are converted once by migration with UUIDv5(namespace:Calendar, name:mutationID) and
remain linked by the operation hash. A remote caller may not choose a different `intentID`.

## Local transaction and allocation

```swift
public actor CalendarStore {
 public func commitLocalSeries(_ intent: CalendarLocalEditIntent) throws -> CalendarLocalCommitReceipt
 public func commitLocalDeletion(_ intent: DeleteIntent, generation: UInt64,
   intentID: UUID) throws -> CalendarLocalCommitReceipt
}
public enum SyncOperationAllocator {
 public static func allocateCalendar(intentID: UUID, datasetID: String, storeID: SyncStoreKind,
   domain: SyncDomain, originID: String, epoch: String, keyID: String, sequence: String,
   entityID: String, parentOperationIDs: [String], baseHash: String?, kind: SyncOperationKind,
   payload: SyncPayload) throws -> SyncOperation
}
```

Under the Calendar writer lock, `commitLocalSeries` executes in this order: validate finite dates and minimum
five-minute duration; load the canonical domain file and `SyncAdapterEnvelopeV2`; inspect the intent receipt; compare
`baseHead` with the current item head; read `nextSequence`, the current head operation ID and the device public identity; call
`SyncOperationAllocator.allocateCalendar`; apply the typed payload and new head; append an outbox entry and a local
receipt; increment `nextSequence`; encode the domain plus complete envelope; flush a same-volume candidate; atomically
replace `calendar.json`; then mark the widget snapshot dirty. No await occurs while the writer lock is held.

The operation has `kind == .put`, the payload is the validated Calendar series payload, and `baseHash` is the supplied
head. Delete uses `kind == .delete` and a non-empty `TombstonePayload` made from `DeleteIntent`; it follows the same
allocation and file transaction. The allocator sets `parents` to the current head operation IDs (or an empty array for
a new item), leaves `signature` empty until the outbox signer runs, and never changes the assigned sequence. Missing identity, invalid input, stale head, intent collision, disk-full or corrupt
store aborts before replacement and leaves the old file. The same intent and payload returns the stored receipt;
the same intent with different bytes returns `intentCollision`. A widget write failure leaves the domain receipt valid
and schedules a bounded rebuild; it never rolls back the committed Calendar file.

## Replicated transaction and call path

`SyncEngine.synchronizeOnce` → `CalendarSyncAdapter.recover` → `frontier` → transport →
`persistInbox` → `CalendarSyncAdapter.applyRemote` → one of the two replicated methods above →
`enumerateAcknowledgements` → `recordAcknowledgement` → `advanceFrontier` → widget projection.

`persistInbox` first durably places the signed operation in the Calendar envelope. The replicated method then runs
under the same writer actor, revalidates store/domain/epoch/signature and the operation's base head, and atomically
updates the domain, head, terminal `SyncCommitReceipt`, inbox state and widget-dirty marker in a second candidate
replacement. It never allocates a sequence or outbox operation. A duplicate operation returns its stored receipt;
stale CAS records a typed conflict and retains the incoming inbox row; a delete resolves identity by `entityID` and
never by title/date. Cancellation before replacement writes nothing; after replacement `recover()` returns the durable
receipt. A rejected operation remains blocked and cannot advance a frontier.

## Gesture ownership and reducer inputs

```swift
public struct CalendarItemBeginContext: Sendable {
 public let intentID: UUID; public let generation: UInt64; public let itemID: String; public let baseHead: String
 public let originalInterval: DateInterval; public let resizeEdge: CalendarResizeEdge
 public let pointerOrigin: CGPoint; public let dayInterval: DateInterval; public let hourHeight: Double
 public let scrollOffset: Double
}
public struct CalendarViewportBeginContext: Sendable {
 public let generation: UInt64; public let focalPoint: CGPoint; public let hourHeight: Double
 public let scrollOffset: Double; public let dayIndex: Int
}
public struct CalendarItemDraftState: Sendable { public let context: CalendarItemBeginContext; public let interval: DateInterval }
public struct CalendarViewportState: Sendable {
 public let dayIndex: Int; public let hourHeight: Double; public let scrollOffset: Double; public let focalPoint: CGPoint
}
public struct CalendarItemInteractionReducer: Sendable {
 public static func begin(_ context: CalendarItemBeginContext) throws -> CalendarItemDraftState
 public static func update(_ state: CalendarItemDraftState, pointer: CGPoint) throws -> CalendarItemDraftState
 public static func finish(_ state: CalendarItemDraftState) throws -> CalendarLocalEditIntent?
 public static func cancel(_ state: CalendarItemDraftState) -> CalendarItemDraftState
}
public enum CalendarViewportController {
 public static func begin(_ context: CalendarViewportBeginContext) throws -> CalendarViewportState
 public static func updatePinch(_ state: CalendarViewportState, scale: Double,
   focalPoint: CGPoint) throws -> CalendarViewportState
 public static func page(horizontalDelta: Double) throws -> Int
 public static func scroll(verticalDelta: Double) throws -> Double
}
@MainActor
public extension CalendarCoordinator {
 public func makeItemBeginContext(itemID: String, edge: CalendarResizeEdge, pointer: CGPoint,
   generation: UInt64) throws -> CalendarItemBeginContext
 public func makeViewportBeginContext(focalPoint: CGPoint, generation: UInt64)
   throws -> CalendarViewportBeginContext
 public func commitLocal(_ intent: CalendarLocalEditIntent) async throws -> CalendarLocalCommitReceipt
 public func commitLocalDeletion(_ intent: DeleteIntent, generation: UInt64,
   intentID: UUID) async throws -> CalendarLocalCommitReceipt
}
```

`CalendarViewportController` owns only pinch, page and scroll; it never creates a commit intent. The item reducer owns
drag/leading-resize/trailing-resize and preserves `originalInterval`, `baseHead` and `resizeEdge` through every draft.
Viewport pinch uses `timeAtFocal=(focalY+scrollOffset)/hourHeight`, `newHeight=clamp(oldHeight*scale,32,240)`, and
`newScroll=timeAtFocal*newHeight-focalY`. Item drag translates both interval endpoints by snapped pointer delta;
resize changes only the chosen edge and clamps duration to five minutes.

`finish` returns nil for viewport input, unchanged interval, non-finite values, cancellation or a superseded generation.
`makeItemBeginContext` reads item interval/head under one read lock; `makeViewportBeginContext` reads only viewport
state. `CalendarCoordinator.commitLocal` checks generation and intent ID before and after its actor hop, and the store checks
the base head inside the file transaction. Stale commits preserve the draft for conflict UI; an unchanged/cancelled
gesture writes nothing. Scene loss, Escape, a new begin and cancelled tasks call `cancel`. No animation or viewport
callback calls any store commit.

## Evidence and compatibility

Migration must show legacy local Calendar mutations receive deterministic UUIDv5 mutation IDs, preserve their payload
hashes, and appear once in the v2 outbox. Evidence covers local/remote put/delete, duplicate intent, intent collision,
stale CAS, conflict, cancellation before/after replace, crash recovery, DST, Mac trackpad pinch and iPhone drag/resize.
The compile-safe unavailable state is `identityUnavailable`; it never silently edits a second local store.

## Revision8 supersession

R8-04 is final for complete Calendar create/update/delete commands, gesture contexts, tombstone derivation and the
canonical local/replicated call paths. The interval-only R7 intent and local calls to replicated-only functions are history.
