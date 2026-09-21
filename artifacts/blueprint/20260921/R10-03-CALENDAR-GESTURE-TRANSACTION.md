# R10 Calendar context, gesture and commit transaction

Planning-only. R10 supersedes the V5 calendar command and gesture clauses in R9-01. The builder
creates intent-bearing commands only; sequence-dependent tombstones exist only inside the store's
allocation transaction.

## Values captured at begin

```swift
public enum CalendarEditScopeV6: String, Codable, Sendable { case series, occurrence }
public enum CalendarDeleteScopeV6: String, Codable, Sendable { case series, occurrence }
public enum CalendarResizeEdgeV6: String, Codable, Sendable { case none, start, end }
public struct CalendarLayoutTransformV6: Codable, Sendable {
 public let viewportID: UUID; public let layoutRevision: UInt64; public let originX: Double
 public let originY: Double; public let scaleX: Double; public let scaleY: Double
 public let scrollX: Double; public let scrollY: Double; public let pointsPerMinute: Double
 public let timeZoneID: String
}
public struct CalendarSeriesFieldsV6: Codable, Sendable {
 public let title: String; public let start: Date; public let end: Date; public let allDay: Bool
 public let timeZoneID: String; public let recurrence: CalendarRecurrenceRule?
 public let notes: String?; public let location: String?; public let colorToken: String?
 public let metadata: [String:String]
}
public struct CalendarItemBeginContextV6: Codable, Sendable {
 public let intentID: UUID; public let scope: CalendarEditScopeV6; public let itemID: UUID
 public let seriesID: UUID; public let beginGeneration: UInt64; public let currentGeneration: UInt64
 public let baseHead: String; public let originalInterval: DateInterval
 public let originalFields: CalendarSeriesFieldsV6; public let resizeEdge: CalendarResizeEdgeV6
 public let capturedLayout: CalendarLayoutTransformV6
}
public struct CalendarItemCommitIntentV6: Codable, Sendable {
 public let intentID: UUID; public let scope: CalendarEditScopeV6; public let itemID: UUID
 public let seriesID: UUID; public let beginGeneration: UInt64; public let currentGeneration: UInt64
 public let baseHead: String; public let originalInterval: DateInterval; public let draftInterval: DateInterval
 public let originalFields: CalendarSeriesFieldsV6; public let draftFields: CalendarSeriesFieldsV6
 public let resizeEdge: CalendarResizeEdgeV6; public let capturedLayout: CalendarLayoutTransformV6
}
public struct CalendarCreateIntentV6: Codable, Sendable {
 public let intentID: UUID; public let scope: CalendarEditScopeV6; public let seriesID: UUID; public let beginGeneration: UInt64
 public let currentGeneration: UInt64; public let capturedLayout: CalendarLayoutTransformV6
 public let fields: CalendarSeriesFieldsV6
}
public struct CalendarDeleteIntentV6: Codable, Sendable {
 public let intentID: UUID; public let scope: CalendarDeleteScopeV6; public let itemID: UUID
 public let seriesID: UUID; public let beginGeneration: UInt64; public let currentGeneration: UInt64
 public let baseHead: String; public let originalInterval: DateInterval
 public let originalFields: CalendarSeriesFieldsV6
 public let capturedLayout: CalendarLayoutTransformV6; public let reason: String?
}
public enum CalendarViewportGestureKindV6: String, Codable, Sendable { case pinch, pan, page }
public struct CalendarViewportBeginContextV6: Codable, Sendable {
 public let intentID: UUID; public let viewportID: UUID; public let beginGeneration: UInt64
 public let currentGeneration: UInt64; public let capturedLayout: CalendarLayoutTransformV6
 public let visibleStart: Date; public let visibleEnd: Date; public let startPointX: Double
 public let startPointY: Double; public let gesture: CalendarViewportGestureKindV6
}
public struct CalendarViewportCommitIntentV6: Codable, Sendable {
 public let intentID: UUID; public let viewportID: UUID; public let beginGeneration: UInt64
 public let currentGeneration: UInt64; public let capturedLayout: CalendarLayoutTransformV6
 public let gesture: CalendarViewportGestureKindV6
 public let proposedScaleX: Double; public let proposedScaleY: Double
 public let proposedScrollX: Double; public let proposedScrollY: Double
}
public struct CalendarDraftV6: Codable, Sendable {
 public let originalInterval: DateInterval; public let draftInterval: DateInterval
 public let originalFields: CalendarSeriesFieldsV6; public let draftFields: CalendarSeriesFieldsV6
}
public struct CalendarViewportDraftV6: Codable, Sendable {
 public let capturedLayout: CalendarLayoutTransformV6; public let proposedScaleX: Double
 public let proposedScaleY: Double; public let proposedScrollX: Double; public let proposedScrollY: Double
}
public struct CalendarViewportV6: Codable, Sendable {
 public let viewportID: UUID; public let generation: UInt64; public let scaleX: Double
 public let scaleY: Double; public let scrollX: Double; public let scrollY: Double
}
```

`title` is 1...200 UTF-8 characters, notes 0...4000, location 0...512, time-zone IDs are 1...128
characters, color tokens are 1...64 ASCII, and metadata has <=32 keys with key <=64/value <=256.
Finite dates have `end > start`, and `pointsPerMinute`/scales are finite
and positive. Create intent scope is always `.series`; delete scope is the distinct
`CalendarDeleteScopeV6` (`.series` removes the series, `.occurrence` removes one occurrence).
`currentGeneration` is read at the gesture event immediately before commit; it is not
an estimate. `capturedLayout` is immutable evidence for converting coordinates, never a new source
of truth for the calendar.

## Builder and reducer signatures

```swift
public struct CalendarSeriesCreateCommandV6: Codable, Sendable { public let intent: CalendarCreateIntentV6 }
public struct CalendarSeriesUpdateCommandV6: Codable, Sendable { public let intent: CalendarItemCommitIntentV6 }
public struct CalendarDeleteCommandV6: Codable, Sendable { public let intent: CalendarDeleteIntentV6 }
public enum CalendarLocalCommandV6: Codable, Sendable {
 case create(CalendarSeriesCreateCommandV6), update(CalendarSeriesUpdateCommandV6), delete(CalendarDeleteCommandV6)
}
public enum CalendarGestureReducerV6 {
 public static func beginItem(_ context: CalendarItemBeginContextV6) throws -> CalendarDraftV6
 public static func commitItem(_ intent: CalendarItemCommitIntentV6) throws -> CalendarLocalCommandV6
 public static func beginViewport(_ context: CalendarViewportBeginContextV6) throws -> CalendarViewportDraftV6
 public static func commitViewport(_ intent: CalendarViewportCommitIntentV6) throws -> CalendarViewportV6
}
public enum CalendarCommandBuilderV6 {
 public static func create(_ intent: CalendarCreateIntentV6) throws -> CalendarLocalCommandV6
 public static func update(_ intent: CalendarItemCommitIntentV6) throws -> CalendarLocalCommandV6
 public static func delete(_ intent: CalendarDeleteIntentV6) throws -> CalendarLocalCommandV6
}
```

`CalendarViewportBeginContextV6` captures viewport ID, generation, layout transform, visible date
range, pointer location and gesture kind; `CalendarViewportCommitIntentV6` carries the same ID,
begin/current generations, captured transform and proposed pan/scale. Viewport types contain no item
ID, base head, fields or delete scope. `CalendarDraftV6` contains original plus draft interval/fields;
`CalendarViewportDraftV6` contains only transform values. These two draft types are owned by P08.

On Mac, trackpad pinch, two-finger pan and horizontal paging enter `beginViewport`; item drag/resize
requires an item hit-test and enters `beginItem`. On iPhone, two-finger pinch/pan is viewport-owned;
one-finger drag on a hit item is item-owned. A gesture keeps its owner until end/cancel. Coordinate
conversion is `minutes=(y-originY-scrollY)/(pointsPerMinute*scaleY)` and `xDate` uses the captured
viewport transform; no per-frame allocation or store write occurs.

## Local allocation transaction

```swift
public struct CalendarSeriesCommitResultV6: Codable, Sendable {
 public let intentID: UUID; public let operationID: UUID?; public let generation: UInt64
 public let head: String; public let noOp: Bool
}
public extension CalendarStore {
 func commitLocal(_ command: CalendarLocalCommandV6) throws -> CalendarSeriesCommitResultV6
 func commitReplicatedSeries(_ operation: SyncOperation, receipt: SyncCommitReceipt,
   expectedGeneration: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResultV6
 func commitReplicatedDeletion(_ operation: SyncOperation, receipt: SyncCommitReceipt,
   expectedGeneration: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResultV6
}
public extension CalendarCoordinator {
 func commitLocal(_ command: CalendarLocalCommandV6) throws -> CalendarSeriesCommitResultV6
}
```

`CalendarCoordinator.beginItemEdit` captures the context; reducer → builder →
`CalendarCoordinator.commitLocal` → `CalendarStore.commitLocal` is the only local path.
`CalendarStore.commitLocal` opens the store transaction, reloads current generation/head,
deduplicates `(intentID,beginGeneration)`, checks base head and fields, and returns a prior result for
an identical committed intent. For a real change it allocates operation ID and sequence, then inside
the same transaction constructs `CalendarTombstonePayloadV6` for a delete (including the allocated
sequence), freezes/hash-signs the operation, reduces domain state, advances head/generation, appends
outbox and receipt, and marks widgets dirty. The builder never accepts or returns a sequence.

```swift
public struct CalendarTombstonePayloadV6: Codable, Sendable {
 public let itemID: UUID; public let seriesID: UUID; public let scope: CalendarDeleteScopeV6
 public let deletedAt: Date; public let deleteSequence: String; public let baseHead: String
 public let intentID: UUID
}
```

The replicated path is `SyncEngine.persistInbox → CalendarSyncAdapter.applyRemote →
CalendarStore.commitReplicatedSeries|commitReplicatedDeletion`; the supplied immutable operation
contains its sequence and tombstone payload. Remote apply checks expected generation/CAS, deduplicates
operation hash, writes domain+envelope+receipt+frontier atomically, and never allocates a new sequence.

## Stale, cancel and no-op outcomes

`staleGeneration`, `staleBase`, invalid interval/fields and `intentReuse` are typed errors with no
write. Cancellation before the store transaction writes nothing; cancellation after commit returns
the durable result. Equal interval and fields is `noOp=true` with no sequence/head/generation change.
An already deleted target returns the prior tombstone result when identity matches; a different delete
intent returns `staleBase` or `intentReuse`. A viewport stale generation drops the draft only; it never
mutates calendar data. A failed transaction leaves domain, envelope, outbox and receipt unchanged.

## R11 supersession

R10-03 remains the gesture/transaction history. R11-06 is final for the complete V6 field record and codec:
kind, status, icon, iconAsset, systemIconName and structured metadata are carried through create/update, durable
storage, replication and widget projection with an explicit migration error for unrepresentable legacy data.
