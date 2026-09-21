# Final engine/server interfaces and read-only outage projection
Supersedes undefined SyncPage/VerifiedExchange/OperationPage placeholders in18/R2-P02. P01/P02 own definitions.
```swift
public enum SyncReason:String,Sendable {case foreground,manual,background,localMutation,connectivityChanged}
public struct SyncCycleReport:Sendable {
 public let stored:Int;public let applied:Int;public let conflicts:Int;public let blocked:Int;public let pending:Int
 public let endpointID:String?;public let completedAt:Date
}
public struct FrameExpectation:Sendable {
 public let datasetID:String;public let epoch:String;public let endpointID:String;public let requestID:String
 public let nonce:String;public let method:String;public let path:String;public let status:Int
}
public protocol SyncDomainAdapter:Sendable {
 var storeID:String {get};var domain:SyncDomain {get}
 func recover()async throws
 func pendingPage(after:String?,limit:Int)async throws->[SyncOperation]
 func applyRemote(_ operation:SyncOperation)async throws->SyncCommitReceipt
 func recordAcknowledgement(_ ack:SyncAck)async throws
 func makeArchive(through:SyncFrontier)async throws->Data
 func restoreArchive(_ bytes:Data,expected:SyncCheckpoint)async throws->SyncCheckpointReceipt
 func checkpoint(_ frontier:SyncFrontier)async throws->SyncCheckpointReceipt
}
```
Actor adapters expose nonisolated immutable storeID/domain; same R3 strings, not conflicting UUID dictionary frontier.
FrameExpectation fields exactly outbound request plus expected HTTP status; no defaults. Report counts>=0/transient, no persisted version.
SyncStoreKind raw enum=calendar,financeImports,financeRecurring,financeInvestments,financeBudgets,financeAllocations,
financePreferences,training,trainingTemplates,meals,nutritionGoals,supplements,journal,lifestyle,barcodeRecords,vault,tax.
Bind kinds→domain exactly R3-04 plus trainingTemplates fitness. No user-controlled codec selector.

## Exact Python server API (replication.py, equivalents in Mac relay)
@dataclass(frozen=True) class VerifiedPeer: dataset_id:str;sender_id:str;epoch:str;endpoint_id:str;request_id:str;nonce:str
VerifiedPeer constructed ONLY validate_signed_request(method:str,path:str,body:bytes,trust:SyncTrustRecord)->tuple[VerifiedPeer,WireJSON].
Frame signature and endpoint/bodyhash/nonce verification then exact path body decoder; forged peer context not accepted from JSON.
ReplicationStore.append(request:SyncExchangeRequest,peer:VerifiedPeer)->SyncExchangeResponse;
read_page(store_id:str,received:SyncFrontier,upper:SyncFrontier|None,limit:int,peer:VerifiedPeer)->tuple[tuple[SyncOperation,...],SyncFrontier,bool];
ack(receipt:SyncAck,peer:VerifiedPeer)->SyncAck; put_blob(chunk:BlobChunk,peer:VerifiedPeer)->BlobResult;
read_blob(request:BlobRead,peer:VerifiedPeer)->BlobChunk; install_membership(membership:SyncMembership)->None.
Routes challenge/hello/exchange/ack/blob/blob-read/health map exactly R3-01; handlers names issue_challenge,hello,exchange,
acknowledge,put_blob,read_blob,health. Public errors R3-S29; authenticated errors full signed SyncError.
Stored ACK freeze and data rows same BEGIN IMMEDIATE; signing helper after commit; failure sign returns503, retry retrieves same record.
No checkpoint REST installation; operator local install_membership/reseed only signed/pinned interfaces R4-10.
SQLite operations/acks/blobs/membership schema R3-02, keyed operations UNIQUE stream+8byte seq; no fake domain applied ACK.
Blob offset always multiple262144; chunk length=min(262144,totalBytes-offset); total fixed1...32MiB;
exclusive same-hash staging, per-offset exact comparison, complete hash before atomic rename; incomplete bytes never referenced by op.
Staging cleanup only unreferenced incomplete24h; disk-full never removes referenced payload/receipt. Body/DB cap R3 enforced before allocation.

## Engine call order (SyncEngine actor)
init(adapters:[any SyncDomainAdapter],transport:SyncTransport,identity:SyncIdentityStore,trust:SyncTrustStore).
synchronizeOnce(reason:) captures generation; recover once→enumerate each store round-robin(max5exchanges/cycle)→freeze page128/bytecap→
request new challenge→sign frame→exchange→validate typed response→persist inbox→apply domain→persist ACK→next page.
No lock across network; compare generation after every await. request failure does not consume local operation ID.
Cursor exact base64url canonical {originID:UUID,sequence:Q} per store; nil means start. Never advance by max(received across gaps).
stop increments generation/cancels one task, waits owned callbacks; durable receipt remains pending for next resume.
Empty cycle zero counts/no network if no selected endpoint; error offline reported via capability, preserves store.
Endpoint selection: reachable enrolled Mac relay first during Windows outage; otherwise configured Windows; never arbitrary discovery.
One network request + one writer batch at a time; UI snapshots MainActor after commit, remote signal alone cannot publish widget.

## Read-only health projection during Windows outage
Existing LifeOSApp.publishFitnessObservation/current envelope retained. P11 adds ObservationRelayPublisher, not a new health store.
public struct SignedHealthObservation:Codable,Equatable,Sendable {
 public let schemaVersion:Int; public let datasetID:String; public let originID:String; public let keyID:String
 public let sequence:String; public let body:String; public let bodyHash:String; public let signature:String
}
Required keys, version1/UUID/HASH/Q/base64url<=128KiB.
Python frozen dataclass fields int,str…; TS readonly same fields, body is opaque bytes of existing FitnessObservationEnvelope.encoded().
Signature kind observation added to SyncSignedKind; signing bytes same R4-08 with literal 'observation'; app only, relay cannot sign origin.
origin must enrolled applying iPhone selected in trust; sequence monotonically allocated in local health-observation-outbox.json,
wrapper {schemaVersion:1,nextSequence:Q,pending:SignedHealthObservation?}; explicit null when drained, private atomic file.
Coalesce newer observation only AFTER newer pending durable; latest source snapshot is replaceable projection, not editable domain history.
Routes POST /replication/v1/observation Frame(SignedHealthObservation)→Frame(SignedHealthObservation) echo;
POST /replication/v1/observation/read Frame({schemaVersion:1,originID:UUID})→Frame(SignedHealthObservation or null).
Same challenge/frame limits/auth; signature verify on embedded record, body existing128KiB validator, selected origin only.
SQLite observations(origin_id TEXT PRIMARY KEY,sequence_sort BLOB8 NOT NULL,encoded BLOB NOT NULL) in relay/gateway DB;
new seq replaces lower only after commit, same seq/samehash no-op, same seq/differenthash idCollision, lower seq ignored with latest reply.
Mac validates embedded iPhone signature then existing FitnessObservationEnvelope.decode before display; uses original observedAt/stale logic.
Windows reconciliation keeps highest validated sequence of same origin; no Date-based conflict or raw HealthKit anchor transfer.
ObservationRelayPublisher.publish(_ value:FitnessObservationEnvelope)async throws→persist/sign/send; readLatest(originID:String)async throws->FitnessObservationEnvelope?.
No change existing provider routes; Windows existing endpoint and relay accept same signed projection as separate cache transport.
Physical HealthKit permissions/source comparison remain release proof; unavailable permission yields no fabricated observation.

## Observation admission and cancellation seal
ObservationRelayPublisher is an actor with one owned drain Task and generation UInt64; publish coalesces newest source value.
Sign candidate using captured nextSequence; after await, recheck generation/current sequence before atomic outbox replacement.
If changed, discard signature and retry newest candidate; if Keychain locked keep old pending, return identityUnavailable.
Allocate nextSequence only in same atomic file replace as newly signed pending; UInt64 overflow returns capacity, no wrap.
No raw/unsigned observation bytes persist in this outbox; existing source projection remains authority for later retry.
On response, clear pending only if echoed sequence/hash equals current pending; higher validated server sequence requires
local sequence reconciliation to max+1 under actor before next publish, never erases newer local source projection.
readLatest returns nil only authenticated null; transport/decoding failures throw corresponding SyncError.

## Revision5 engine/deletion amendment
R5-02 adds durable persistInbox, enumerateAcknowledgements, frontier and advanceFrontier to this protocol and
fixes the engine transaction order. R5-03 supplies typed deletion/CAS semantics. Implementers must use those amended
signatures rather than the shorter R4 protocol block above.
Cancellation after durable replace retains pending; no unsent-data eviction on network failure or seven-day outage.

## Revision6 supersession
R6-01 removes Usage and Clipper from the replicated composition; R6-03 fixes Planning's existing SQLite storage; and
R6-06 fixes the Calendar commit/generation/intent call path. These are the final transport boundaries.
