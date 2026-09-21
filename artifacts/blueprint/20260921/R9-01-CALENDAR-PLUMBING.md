# R9 Calendar command plumbing

Planning-only. This sheet supersedes the R8 Calendar command, gesture and viewport clauses. P03 owns durable
commands/store/adapter functions; P08 owns reducers, gesture ownership and viewport UI; P01 owns SyncOperation,
SyncCommitReceipt and shared error types.

## Final value types

`CalendarSeriesFieldsV4` remains the complete field record: `title:String`, `kind:CalendarItemKind`, `icon:String?`,
`iconAsset:CalendarIconAsset?`, `systemIconName:String?`, `status:CalendarItemStatus`, `start:Date`, `end:Date`,
`timeZoneIdentifier:String?`, `recurrence:CalendarRecurrenceRule?`, and `metadata:CalendarSeriesMetadataV4`.
Metadata is `notes:String?`, `location:String?`, `url:String?`, `tags:[String]`, `custom:[String:String]`. The existing
R8 bounds and validation remain binding: title 240 UTF-8 bytes, notes 4,096, location 240, URL 2,048 HTTPS-only,
32 tags of 64 bytes, 32 custom pairs, `end > start`, valid recurrence/time zone/icon.

```swift
public enum CalendarDeleteScope: String, Codable, Sendable { case occurrence, series }
public enum CalendarResizeEdgeV5: String, Codable, Sendable { case none, start, end }
public struct CalendarSeriesCreateCommandV5: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let intentID: UUID; public let generation: UInt64
 public let seriesID: UUID; public let fields: CalendarSeriesFieldsV4
}
public struct CalendarSeriesUpdateCommandV5: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let intentID: UUID; public let generation: UInt64
 public let seriesID: UUID; public let targetItemID: UUID?; public let scope: CalendarEditScope
 public let expectedHead: String; public let fields: CalendarSeriesFieldsV4
}
public struct CalendarDeleteIntentV5: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let intentID: UUID; public let generation: UInt64
 public let entityID: UUID; public let scope: CalendarDeleteScope; public let baseHead: String
 public let requestedBy: String; public let cascadeEntityIDs: [UUID]; public let reason: String?
}
public struct CalendarTombstonePayloadV5: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let intentID: UUID; public let generation: UInt64
 public let entityID: UUID; public let scope: CalendarDeleteScope; public let deletedBy: String
 public let deleteSequence: String; public let baseHead: String; public let cascadeEntityIDs: [UUID]
}
public struct CalendarSeriesCreateIntentV5: Sendable {
 public let intentID: UUID; public let generation: UInt64; public let seriesID: UUID
 public let fields: CalendarSeriesFieldsV4
}
public enum CalendarSeriesWriteCommandV5: Codable, Equatable, Sendable {
 case create(CalendarSeriesCreateCommandV5), update(CalendarSeriesUpdateCommandV5)
}
```

`generation` is a non-wrapping local UI generation captured at begin and echoed in the command/result. `intentID` is
the deduplication identity; the pair `(storeID,intentID,generation)` is unique for local work. `cascadeEntityIDs` is
empty for occurrence deletion and contains the sorted, unique series members for series deletion (maximum 512). A
series delete never means “delete all records”; unknown IDs reject the command. The tagged command envelope is
`{"tag":"create|update|tombstone","payload":...}` with no compiler enum layout.

## Complete intent and viewport contracts

```swift
public struct CalendarItemBeginContextV5: Sendable {
 public let intentID: UUID; public let generation: UInt64; public let itemID: UUID; public let seriesID: UUID
 public let baseHead: String; public let originalInterval: DateInterval; public let resizeEdge: CalendarResizeEdgeV5
 public let originalFields: CalendarSeriesFieldsV4
}
public struct CalendarItemCommitIntentV5: Sendable {
 public let intentID: UUID; public let generation: UInt64; public let itemID: UUID; public let seriesID: UUID
 public let baseHead: String; public let originalInterval: DateInterval; public let draftInterval: DateInterval
 public let resizeEdge: CalendarResizeEdgeV5; public let originalFields: CalendarSeriesFieldsV4
 public let draftFields: CalendarSeriesFieldsV4
}
public struct CalendarViewportV5: Codable, Equatable, Sendable {
 public let contentSize: CGSize; public let visibleRect: CGRect; public let scale: Double; public let offset: CGPoint
 public let visibleStart: Date; public let visibleEnd: Date
}
public struct CalendarViewportBeginContextV5: Sendable {
 public let gestureID: UUID; public let generation: UInt64; public let initial: CalendarViewportV5
 public let anchorScreen: CGPoint; public let anchorContent: CGPoint
}
public struct CalendarViewportCommitIntentV5: Sendable {
 public let gestureID: UUID; public let generation: UInt64; public let initial: CalendarViewportV5
 public let proposed: CalendarViewportV5; public let cancelled: Bool
}
public typealias CalendarViewportV4 = CalendarViewportV5
public typealias CalendarViewportBeginContextV4 = CalendarViewportBeginContextV5
public typealias CalendarViewportCommitIntentV4 = CalendarViewportCommitIntentV5
```

`CalendarCommandBuilderV5.update(_:) throws -> CalendarSeriesUpdateCommandV5` copies `draftFields`, then replaces
the interval according to `resizeEdge`: `.none` translates the whole original interval by
`draft.start-original.start`; `.start` changes only start; `.end` changes only end. It verifies that the untouched
fields equal the captured original or that the caller supplied the corresponding complete `draftFields`; it never
looks up omitted fields. `create(_ intent:CalendarSeriesCreateIntentV5)` and
`delete(_ intent:CalendarDeleteIntentV5,operationSequence:String)` return the V5 command/payload with intent and
generation unchanged. The builder rejects stale generation, invalid interval, duplicate cascade IDs or a recurrence
edit that cannot be represented by the selected scope.

```swift
public enum CalendarCommandBuilderV5 {
 public static func create(_ intent: CalendarSeriesCreateIntentV5) throws -> CalendarSeriesCreateCommandV5
 public static func update(_ intent: CalendarItemCommitIntentV5) throws -> CalendarSeriesUpdateCommandV5
 public static func delete(_ intent: CalendarDeleteIntentV5, operationSequence: String) throws -> CalendarTombstonePayloadV5
}
```

The retained V4 viewport names are compile-safe aliases to these exact values; no second viewport model is permitted.
Viewport pinch/pan/paging is separate from item drag/resize. With `p = (anchorScreen-initial.offset)/initial.scale`,
`newScale=clamp(initial.scale*exp(deltaMagnification),0.5,4.0)` and
`newOffset=anchorScreen-p*newScale`. Day paging changes dates only; it never calls `CalendarStore`. Item gestures use
the layout transform captured in `CalendarItemBeginContextV5`; interruption/cancel discards the draft.

## Exact call paths and results

```swift
public struct CalendarSeriesCommitResultV5: Sendable {
 public let receipt: SyncCommitReceipt; public let generation: UInt64; public let intentID: UUID
}
public enum CalendarLocalCommandV5: Codable, Equatable, Sendable {
 case create(CalendarSeriesCreateCommandV5), update(CalendarSeriesUpdateCommandV5), delete(CalendarTombstonePayloadV5)
}
public extension CalendarStore {
 func commitLocal(_ command: CalendarLocalCommandV5) throws -> CalendarSeriesCommitResultV5
 func commitReplicatedSeries(_ command: CalendarSeriesWriteCommandV5,
   operation: SyncOperation, receipt: SyncCommitReceipt, generation: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResultV5
 func commitReplicatedDeletion(_ payload: CalendarTombstonePayloadV5, operation: SyncOperation,
   receipt: SyncCommitReceipt, generation: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResultV5
}
```

Local paths are `CalendarCoordinator.beginItemEdit → reducer → CalendarCommandBuilderV5.update →
CalendarCoordinator.commitLocal → CalendarStore.commitLocal`; create/delete use the analogous builder and command.
`commitLocal` allocates operation ID/sequence, applies domain state, appends outbox, advances head, writes receipt and
widget-dirty marker in one atomic store transaction. Remote paths are `SyncEngine.persistInbox →
CalendarSyncAdapter.applyRemote → CalendarStore.commitReplicatedSeries|commitReplicatedDeletion`; remote code uses
the supplied operation/receipt and never allocates a new sequence.

Duplicate `(operationID,payloadHash)` or `(intentID,generation)` returns the durable prior result. Different payload for
the same intent is `intentReuse`; a mismatched `baseHead` is `staleBase` with no write. Equal fields/interval is a
committed no-op with no head advance. Cancellation before the transaction writes nothing; cancellation after the
atomic commit returns the committed result. Every failure leaves the old head and outbox unchanged.

## Revision10 supersession

R10-03 replaces V5 builder inputs and gesture/commit clauses with V6 context, viewport separation
and in-transaction tombstone allocation.
