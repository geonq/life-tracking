# Exact common payload/archive and adapter contract
P01 owns declarations; domain files own concrete Value types below. All names proposed, implementation not executed.
R3 operation frame remains v1; operation.payload contains canonical JSON of the appropriate Payload below.
All listed fields REQUIRED/no defaults; optional means required explicit null; root version1; validation R4-01/R3.
```swift
public struct DomainArchive<Value:Codable & Equatable & Sendable>:Codable,Equatable,Sendable {
 public let schemaVersion:Int; public let storeID:String; public let domain:SyncDomain
 public let frontier:SyncFrontier; public let entities:[ArchivedEntity<Value>]
 public let acknowledgements:[SyncAck]; public let blobs:[ArchiveBlob]
}
public struct ArchivedEntity<Value:Codable & Equatable & Sendable>:Codable,Equatable,Sendable {
 public let entityID:String; public let heads:[SyncOperation]; public let value:Value?
 public let deleted:Bool; public let conflict:SyncConflict?
}
public struct ArchiveBlob:Codable,Equatable,Sendable { public let hash:String; public let bytes:String }
```
```python
@dataclass(frozen=True)
class ArchiveBlob: hash:str; bytes:str
@dataclass(frozen=True)
class ArchivedEntity(Generic[T]):
    entityID:str; heads:tuple[SyncOperation,...]; value:T|None; deleted:bool; conflict:SyncConflict|None
@dataclass(frozen=True)
class DomainArchive(Generic[T]):
    schemaVersion:int; storeID:str; domain:SyncDomain; frontier:SyncFrontier
    entities:tuple[ArchivedEntity[T],...]; acknowledgements:tuple[SyncAck,...]; blobs:tuple[ArchiveBlob,...]
```
```typescript
interface ArchiveBlob { readonly hash:string; readonly bytes:string }
interface ArchivedEntity<T> { readonly entityID:string; readonly heads:ReadonlyArray<SyncOperation>; readonly value:T|null; readonly deleted:boolean; readonly conflict:SyncConflict|null }
interface DomainArchive<T> { readonly schemaVersion:number; readonly storeID:string; readonly domain:SyncDomain; readonly frontier:SyncFrontier; readonly entities:ReadonlyArray<ArchivedEntity<T>>; readonly acknowledgements:ReadonlyArray<SyncAck>; readonly blobs:ReadonlyArray<ArchiveBlob> }
```
|Field|Bound, validation, authority|
|---|---|
|schemaVersion/domain/storeID|1/closed enum/canonical UUID matching membership; applying store owns|
|frontier|<=256 contiguous streams; never beyond durable receipts; includes tombstones|
|entities|<=10000 sorted unique entityID, smaller domain cap wins; from SAME committed store revision|
|entityID|64hex derived kind+NUL+stable local ID; never path-to-file directly|
|heads|1...8 sorted mutationID, valid immutable signed operations of same entity/store; referenced ancestors retained until checkpoint|
|value|exact domain type; null allowed when deleted OR unresolved conflict has no previously accepted live value; all branches retained|
|deleted|true iff terminal unconflicted delete; deleted=true requires value=null/conflict=null|
|conflict|complete R3 conflict or null; every branch payload included, unresolved branches never dropped|
|acknowledgements|<=10000 verified distinct mutation/replica/level; all required checkpoint coverage receipts present; R5-06 constant|
|blobs|<=10000 sorted unique hash; each base64url<=32MiBdecoded; hash SHA256 bytes; TOTAL archive<=32MiBdecoded JSON|
All archive bytes are personal data; may leave only to enrolled dataset members, except Tax raw bytes always forbidden.
Archive includes every referenced external payload blob; decoder rejects missing or unused extra blobs/hash mismatch.
If archive cannot fit32MiB, return capacity and DO NOT compact; no automatic splitting format or data eviction.
Local snapshot byte caps still validated separately; wrapper metadata cap32MiB explicitly replaces R3 cap ambiguity.
Existing domain cap never counts twice as allowance: local wrapper <=32MiB and original domain subsection within old cap.
At capacity new mutation fails with recoverable draft; never clear pending to make room. Week outage has no time-based eviction.
Archive creation under store lock captures immutable snapshot; encode outside lock only from frozen Sendable values.

## Concrete archive aliases (Swift/Python/TS same generic specialization)
CalendarArchive=DomainArchive<CalendarSeriesPayload>; FinanceArchive=DomainArchive<FinancePayload>;
FitnessArchive=DomainArchive<FitnessPayload>; PlanningArchive=DomainArchive<PlanningFilePayload>;
TaxArchive=DomainArchive<TaxPublicationPayload>. A store archive contains only its enrolled kind's variant.

## Exact domain adapter methods, one actor per logical store
recover() async throws; pendingPage(after:String?,limit:Int) async throws->[SyncOperation];
applyRemote(_ operation:SyncOperation) async throws->SyncCommitReceipt;
recordAcknowledgement(_ ack:SyncAck) async throws;
makeArchive(through:SyncFrontier) async throws->Data;
restoreArchive(_ bytes:Data,expected:SyncCheckpoint) async throws->SyncCheckpointReceipt;
checkpoint(_ frontier:SyncFrontier) async throws->SyncCheckpointReceipt.
makePayload(entityID:String) async throws->Data and applyPayload(_ bytes:Data,operation:SyncOperation) async throws->SyncCommitReceipt
are private adapter helpers; domain docs name exact typed encoder/decoder. No network inside store transaction.
Recover validates wrapper, heads/blobs/receipts, unsigned outbox; no empty-store fallback on corruptStore.
restoreArchive requires trusted checkpoint hash/current membership, refuses frontier regression/local pending not covered;
uses same original store transaction/recovery path, never a second data authority. External permission unavailable returns identityUnavailable.
checkpoint first makes archive, persists/verifies it, THEN atomically prunes eligible history with all required signatures.
Keep unresolved conflict/inbox/outbox even when old; archived domain records and retained head receipts remain durable.
Swift errors SyncError, Python ReplicationError(code:SyncErrorCode), TS validation returns throws WireDecodeError(code).
No-op emits no sequence; same operation replays original receipt; missingParent stays inbox; sameentity concurrency retainedConflict.
Migration wrapper+bootstrap+original IDs atomically replace, restore old backup only before post-migration edits; R3 rollback rules apply.

## Revision5 supersession
R5-02 owns durable inbox/ACK/frontier sequencing; R5-03 owns typed deletion and forbids empty commit payloads;
R5-04 adds RecoveryArchive, ArchiveMappedIdentity and ArchiveImportReceipt; R5-06 fixes archive ACKs at 10,000.
The R5 recovery record, not this generic archive wrapper, is required for import/reseed/rotation evidence.

## Revision6 supersession
R6-04 defines the concrete v2 recovery archive signing domain and historical-key lookup; R6-05 defines its receipt-first
import/retry state machine. R6-03 retains the 10,000 ACK bound and rejects any larger undecodable archive.
