# R8 Calendar command and gesture contract

Planning-only. R8 is the final Calendar command surface. A gesture edits a complete series command; it never invents
missing fields or calls the replicated path for a local edit.

## Complete command payload

```swift
public struct CalendarSeriesMetadataV4: Codable, Equatable, Sendable {
 public let notes: String?; public let location: String?; public let url: String?
 public let tags: [String]; public let custom: [String: String]
}
public struct CalendarSeriesFieldsV4: Codable, Equatable, Sendable {
 public let title: String; public let kind: CalendarItemKind; public let icon: String?
 public let iconAsset: CalendarIconAsset?; public let systemIconName: String?; public let status: CalendarItemStatus
 public let start: Date; public let end: Date; public let timeZoneIdentifier: String?
 public let recurrence: CalendarRecurrenceRule?; public let metadata: CalendarSeriesMetadataV4
}
public struct CalendarSeriesCreateCommandV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let seriesID: UUID; public let fields: CalendarSeriesFieldsV4
}
public struct CalendarSeriesUpdateCommandV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let seriesID: UUID; public let targetItemID: UUID?
 public let scope: CalendarEditScope; public let expectedHead: String; public let fields: CalendarSeriesFieldsV4
}
public enum CalendarEditScope: String, Codable, Sendable { case series, occurrence }
public enum CalendarSeriesWriteCommandV4: Codable, Equatable, Sendable {
 case create(CalendarSeriesCreateCommandV4), update(CalendarSeriesUpdateCommandV4)
}
public enum CalendarLocalCommandV4: Codable, Equatable, Sendable {
 case write(CalendarSeriesWriteCommandV4), delete(CalendarDeleteIntentV4)
}
public enum CalendarCommandBuilderV4 {
 public static func update(_ intent: CalendarItemCommitIntentV4) throws -> CalendarSeriesUpdateCommandV4
 public static func makeTombstonePayload(_ intent: CalendarDeleteIntentV4, operationSequence: String)
   throws -> CalendarTombstonePayloadV4
}
```

The associated command enums use explicit tagged Codable objects (`tag` plus `payload`); synthesis must not encode an
unstable compiler case layout. `CalendarSeriesWriteCommandV4` is the only put payload accepted by the sync adapter.

The fields map one-to-one to `CalendarItem`'s title, kind, icon, iconAsset, systemIconName, status, start, end,
timeZoneIdentifier and recurrence; `metadata` is the version-4 series extension. The store, not the command, owns
`createdAt`, `updatedAt`, `deletedAt`, occurrence IDs and logical head. Bounds are title 240 UTF-8 bytes, notes 4,096,
location 240, URL 2,048 and HTTPS-only, 32 tags of 64 bytes, 32 custom pairs with 64-byte keys/256-byte values.
`end > start`, valid timezone/recurrence and icon validators are mandatory. A v3 payload migrates missing metadata to
empty values and preserves old timestamps; a v4 update replaces the complete field set, so “keep” versus “clear” is not
ambiguous.

## Gesture contexts and delete reconciliation

```swift
public enum CalendarResizeEdge: String, Codable, Sendable { case none, start, end }
public struct CalendarItemBeginContextV4: Sendable {
 public let intentID: UUID; public let itemID: UUID; public let seriesID: UUID; public let baseHead: String
 public let originalInterval: DateInterval; public let resizeEdge: CalendarResizeEdge
 public let originalFields: CalendarSeriesFieldsV4
}
public struct CalendarItemCommitIntentV4: Sendable {
 public let intentID: UUID; public let itemID: UUID; public let seriesID: UUID; public let baseHead: String
 public let originalInterval: DateInterval; public let draftInterval: DateInterval
 public let resizeEdge: CalendarResizeEdge; public let fields: CalendarSeriesFieldsV4
}
public struct CalendarDeleteIntentV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let intentID: UUID; public let entityID: UUID
 public let scope: CalendarDeleteScope; public let baseHead: String; public let requestedBy: String
 public let cascadeEntityIDs: [UUID]; public let reason: String?
}
public struct CalendarTombstonePayloadV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let intentID: UUID; public let entityID: UUID
 public let scope: CalendarDeleteScope; public let deletedBy: String; public let deleteSequence: String
 public let baseHead: String; public let cascadeEntityIDs: [UUID]
}
```

`CalendarCommandBuilderV4.update(_:)` copies `originalFields`, replaces only the interval edge requested by
`resizeEdge`, validates `draftInterval`, and returns `CalendarSeriesUpdateCommandV4`. `.none` means move the whole
interval; a recurring series update is rejected when the edit cannot be represented by its recurrence anchor. A local
delete is a `CalendarDeleteIntentV4`; `makeTombstonePayload(intent, operationSequence)` deterministically maps
`requestedBy→deletedBy`, `operationSequence→deleteSequence`, and preserves scope/base/cascade. The outgoing wire operation
contains `CalendarTombstonePayloadV4`, never a raw UI intent. A remote tombstone is decoded into the same payload type;
the adapter does not trust or accept a remote UI request.

## Canonical signatures and call paths

```swift
public struct CalendarSeriesCommitResultV4: Sendable { public let receipt: SyncCommitReceipt; public let generation: UInt64; public let intentID: UUID }
public extension CalendarStore {
 func commitLocal(_ command: CalendarLocalCommandV4) throws -> CalendarSeriesCommitResultV4
 func commitReplicatedSeries(_ command: CalendarSeriesWriteCommandV4,
   operation: SyncOperation, receipt: SyncCommitReceipt, generation: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResultV4
 func commitReplicatedDeletion(_ payload: CalendarTombstonePayloadV4, operation: SyncOperation,
   receipt: SyncCommitReceipt, generation: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResultV4
}
```

Local path: `CalendarCoordinator.commitLocal` → `CalendarStore.commitLocal` → one file transaction allocates the
operation, appends outbox, applies domain fields/tombstone, advances head, records receipt and marks widgets dirty.
Replicated path: `SyncEngine.persistInbox` → `CalendarSyncAdapter.applyRemote` → `CalendarStore.commitReplicatedSeries`
or `commitReplicatedDeletion`; the supplied admission receipt and operation are written in that same transaction and no
new sequence is allocated. `expectedHead`/`baseHead` is a CAS: stale head returns conflict, duplicate intent/operation
returns the existing receipt, cancellation before transaction is a no-op, and a no-op interval/field equality returns a
committed no-op receipt without a head change.

`CalendarViewportBeginContextV4`/`CalendarViewportControllerV4` own paging, scrolling and pinch scale. Item drag/resize
owns the item contexts above; viewport gestures cannot mutate an item draft. Item coordinates use the layout transform
captured at begin, clamp to the timezone/day bounds, and cancel on gesture interruption without persistence.
P03 owns command/store/adapter functions; P08 owns reducers and viewport UI; P01 owns operation/receipt types.

## Revision9 supersession

R9-01 is authoritative. It adds `originalFields`, complete draft fields, intent/generation, `CalendarDeleteScope`,
V5 viewport values, the typed write command and exact local/replicated call paths; the V4 sketches above are history.
