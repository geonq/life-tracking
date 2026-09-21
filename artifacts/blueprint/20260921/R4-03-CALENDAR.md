# Calendar payload, archive and store seal
P03 owns ios/Sync/CalendarSyncAdapter.swift and CalendarStore.swift/CalendarDomain.swift/CalendarCoordinator.swift.
```swift
public struct CalendarSeriesPayload:Codable,Equatable,Sendable {
 public let schemaVersion:Int; public let tag:String; public let seriesID:String; public let items:[Wire4CalendarItem]
}
```
```python
@dataclass(frozen=True)
class CalendarSeriesPayload:
    schemaVersion:int; tag:str; seriesID:str; items:tuple[Wire4CalendarItem,...]
```
```typescript
interface CalendarSeriesPayload { readonly schemaVersion:number; readonly tag:"calendarSeries"; readonly seriesID:string; readonly items:ReadonlyArray<Wire4CalendarItem> }
```
All keys required; version1/tag calendarSeries; seriesID canonical UUID of original master; items1...1024 distinct IDs.
Each item exact R4-V-CalendarItem plus nested sheets; total legacy CalendarSnapshot <=256KiB/1024items.
Single nonrecurring item is seriesID=item.id. Recurrence splits keep original seriesID; array sorted UUID, display derived by date.
Store wrapper adds seriesMembership:[CalendarSeriesLink] where CalendarSeriesLink {itemID:String,seriesID:String} required UUIDs;
Swift Codable/Sendable, Python frozen dataclass(str,str), TS readonly strings. Unique itemID,<=1024 links; persisted local.
Wire key entityID=SHA256('calendar'+NUL+seriesID). Transient occurrenceSourceID never encoded.
Deletion of a whole series carries a typed `DeleteIntent` payload and is applied by
`CalendarStore.commitReplicatedDeletion`; an empty payload is invalid. Subset deletion carries updated series payload
with item's valid deletedAt; no expanded-occurrence persistence. Single-occurrence exclusion uses a split of master into
before/after recurrence anchors plus optional replacement, all committed in SAME series operation; preserve timezone/DST.

## Exact functions
CalendarPayloadCodec.encode(seriesID:UUID,items:[CalendarItem])throws->Data; decode(_ bytes:Data)throws->CalendarSeriesPayload.
CalendarStore.commitReplicatedSeries(_ payload:CalendarSeriesPayload,operation:SyncOperation?)throws->SyncCommitReceipt
executes existing mutate read/validate/replace path, replacing ONLY mapped series items and membership links; untouched series survive.
CalendarSyncAdapter.makePayload loads committed series through encode; applyPayload decodes then invokes commitReplicatedSeries.
Local CalendarCoordinator.save/delete→performPersist→CalendarStore.commitReplicatedSeries; no legacy remote timestamp merge
on authenticated v1 route. Legacy file merged(with:) retained solely for pre-cutover import under explicit legacy mode.
CalendarStore.load/save dispatch wrapperVersion1 versus old snapshot; all existing save callers enter replicated transaction.
CalendarStore.load reads wrapper<=32MiB then validates snapshot<=256KiB; never increase original item/asset limits.
Under commit lock check expected heads→allocate sequence→candidate snapshot+replication+seriesMembership→atomic temp/replace;
cache/publication after durability only. Adapter alreadyApplied never changes updatedAt to now.

## Migration and archive
Legacy CalendarSnapshot decoder validates aliases/defaults; group each stored item into own series initially, never guess lineage
from title/timing. Existing transient occurrence invalid; block migration with retained source. No record ID replacement.
Bootstrap operation for each initial series, preserve source Date bits/icon bytes, empty frontiers only on initial migration.
CalendarArchive uses R4-02 with one value per series and authenticated heads/tombstones/blobs; icons may leave as user-owned data.
Store calendar.json existing URL/App Group chosen by existing composition; do not create a second Calendar.sqlite.
Restore archive through commitReplicatedSeries bulk transaction; all IDs/caps validated BEFORE replacement.
Missing endpoint doesn't block local edits; diskFull retains draft and old bytes; duplicate/current no-op; concurrent series keeps branches.

## Widget projection
CalendarWidgetProvider.getTimeline reads committed CalendarSnapshot; NextEventWidget uses same provider.
No replication envelope exposed to widgets; source publish after commit, timeline picks next event in actual timezone.
Now label only today column, one label; scroll and pinch logic20/27 unchanged. No raw sync errors in widget UI.
Release evidence: series split/undo, DST23/25h, max-size migration,8day outage/reconnect, duplicate/tamper, widget deep link.

## Revision5 supersession
Whole-series deletion is CalendarStore.commitReplicatedDeletion(DeleteIntent,operation:); the series payload path
rejects an empty items array. Gesture begin/commit uses CalendarBeginContext and CalendarCommitIntent from R5-03,
including original interval, base head and explicit resize edge, with a writer-lock CAS before save.

## Revision6 supersession
R6-06 is the final Calendar interface: `commitReplicatedSeries` and deletion require operation, generation and intent ID;
viewport pinch/page/scroll and item drag/resize have separate owners and use the R6 commit formulas.
