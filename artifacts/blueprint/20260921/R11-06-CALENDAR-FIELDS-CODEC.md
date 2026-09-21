# R11 calendar V6 field preservation and codec

Planning-only. This sheet amends R10-03 and R9-01. The current source `CalendarItem` already owns `kind`, `status`,
`icon`, `iconAsset`, `systemIconName`, interval, time zone and recurrence; V6 adds the structured metadata record
to the command/replication boundary and the durable item without dropping any existing value.

## Complete field contract

```swift
public struct CalendarSeriesMetadataV4: Codable, Equatable, Sendable {
 public let notes: String?; public let location: String?; public let url: String?
 public let tags: [String]; public let custom: [String:String]
}
public struct CalendarSeriesFieldsV6: Codable, Equatable, Sendable {
 public let title: String; public let kind: CalendarItemKind; public let icon: String?
 public let iconAsset: CalendarIconAsset?; public let systemIconName: String?
 public let status: CalendarProgress; public let start: Date; public let end: Date
 public let allDay: Bool; public let timeZoneIdentifier: String?; public let recurrence: CalendarRecurrenceRule?
 public let metadata: CalendarSeriesMetadataV4
}
```

The metadata bounds are notes <=4,096 UTF-8 bytes, location <=240, HTTPS URL <=2,048, 32 unique tags of
<=64 bytes and 32 custom pairs with key <=64/value <=256. The existing title/icon/time-zone/recurrence bounds
remain binding. The current source has no `allDay` property, so P03 adds `allDay: Bool` to `CalendarItem`, its
initializer/updater, CodingKeys and canonical hash; it is durable V6 data, not a derived display hint. Legacy
payloads from versions before this field record `allDay=false` explicitly; a later V6 payload missing it is invalid.
Unknown enum values, invalid icon assets, or
nonempty legacy fields that cannot map to V6 return `unsupportedCalendarField`; they never silently disappear.

## Codec and migration

```swift
public enum CalendarFieldsCodecV6 {
 public static func encode(_ fields: CalendarSeriesFieldsV6) throws -> Data
 public static func decode(_ data: Data) throws -> CalendarSeriesFieldsV6
 public static func migrateLegacy(_ data: Data, sourceVersion: Int) throws -> CalendarSeriesFieldsV6
}
```

Canonical keys are `title,kind,icon,iconAsset,systemIconName,status,start,end,allDay,timeZoneIdentifier,
recurrence,metadata`; null icon sources are explicit. Legacy bytes missing `kind` map to `.event` only because
that is the documented R1 default; a missing status is rejected unless the legacy decoder records an explicit
`.planned` compatibility marker. Missing metadata maps to an empty record only when the legacy version predates
metadata. Present fields are copied byte-for-byte after canonical validation. `CalendarItem.init(from:)` and
`encode(to:)` retain their existing validation, while P03 adds the metadata and `allDay` fields to the durable
model and its
`updating`/hash paths.

## Create/update and gesture access

`CalendarSeriesCreateCommandV6.fields` and `CalendarSeriesUpdateCommandV6.fields` are this complete record;
`CalendarItemBeginContextV6.originalFields` and `CalendarItemCommitIntentV6.draftFields` use the same type.
`CalendarCommandBuilderV6.create/update` copies every field and changes only the interval selected by
`resizeEdge`; it never performs a partial-field lookup. `CalendarStore.commitLocal` calls the model initializer/
updater with all fields in one transaction. `CalendarSyncAdapter.applyRemote` decodes the same codec before CAS;
`CalendarStore.commitReplicatedSeries` stores the complete record.

The canonical local path is `CalendarCoordinator.beginItemEdit → CalendarCommandBuilderV6.update →
CalendarCoordinator.commitLocal → CalendarStore.commitLocal`; remote is `persistInbox →
CalendarSyncAdapter.applyRemote → CalendarStore.commitReplicatedSeries`. A create/update with identical full
fields is a no-op; stale base/generation or invalid metadata writes nothing. Acceptance creates and edits an item
with every icon/status/kind/metadata field, encodes/decodes it, migrates it, and proves the persisted hash and
widget projection retain every value. P03 owns model/storage; P08 owns gesture capture; P01 owns wire codec.
