# Revision 2 shared contracts — P01 owner
All declarations below are PROPOSED additions, not claims about current compiled source.
CP-B must seal complete Codable field definitions and cross-language vectors before implementation.
No domain model should be replaced by a second generic JSON authority.

## Concrete public boundary (Swift)
```swift
public enum SyncFailure: String, Error, Codable, Sendable {
 case invalidInput, unsupportedSchema, unauthenticated, revoked, replay
 case hashMismatch, missingParent, conflict, staleBase, capacity, diskFull
 case corruptStore, busy, offline, timedOut, cancelled, identityUnavailable
}
public enum SyncDisposition: String, Codable, Sendable {
 case applied, retainedConflict, alreadyApplied, blockedParent, rejected
}
public struct SyncStreamID: Codable, Hashable, Sendable {
 public let datasetID: UUID; public let domain: String
 public let storeID: UUID; public let originDeviceID: UUID
}
public struct SyncFrontier: Codable, Equatable, Sendable {
 public let contiguous: [SyncStreamID: UInt64]
}
public struct SyncMutationContext: Sendable {
 public let mutationID: UUID; public let expectedVersion: String?
 public let parents: [UUID]; public let generation: UInt64
}
public struct SyncCommitReceipt: Codable, Equatable, Sendable {
 public let mutationID: UUID; public let payloadHash: String
 public let entityVersion: String; public let disposition: SyncDisposition
}
public protocol SyncDomainAdapter: Sendable {
 var storeID: UUID { get }
 var domain: String { get }
 func recover() async throws
 func pendingPage(after: String?, limit: Int) async throws -> SyncPage
 func applyRemote(_ operation: SyncOperation) async throws -> SyncCommitReceipt
 func recordAcknowledgement(_ acknowledgement: SyncAck) async throws
 func checkpoint(_ frontier: SyncFrontier) async throws -> SyncCheckpointReceipt
}
```
SyncOperation/SyncPage/SyncAck/SyncCheckpointReceipt field schema: CP-B must expand revision1 02/15;
no unresolved type alias may reach a Luna dispatch. Dictionary frontiers encode as sorted stream-entry arrays.
UInt64 sequence encodes canonical decimal string in JSON; reject leading zero/sign/overflow except "0".
Persistent storeID is stable random UUID established at migration; never derived from filesystem path.
Sequence belongs to dataset/domain/storeID/origin; this supersedes revision1's domain-only sequence stream.
Different finance stores cannot coordinate a single sequence without a new transaction coordinator, which is forbidden.
Per-stream ACK gaps bounded1024; canonical stable sorting includes all stream identity components.

## Engine contract (ios/Sync/SyncEngine.swift)
actor SyncEngine owns adapters, one cancellable Task, generation UInt64 and monotonic retry state.
func synchronizeOnce(reason: SyncReason) async throws -> SyncCycleReport
func stop() async; func resume() async; repeated resume/stop are no-ops.
SyncReason enum: foreground, manual, background, localMutation, connectivityChanged.
SyncCycleReport: stored/applied/conflict/blocked counts, pending count, endpointID, completedAt.
Each cycle: recover once→read local bounded page→exchange→validate response→apply→persist ACK→next page.
At most128 operations/1MiB each page, five exchanges per foreground cycle; one endpoint request in flight.
Never hold a store lock across await/network. Actors are reentrant: compare generation after every await.
Stop prevents scheduling next work; already durably committed work remains valid and replayable.
An old completion cannot change UI or advance a non-durable frontier; a valid committed receipt may be re-enumerated.
Transient backoff uses injected monotonic Clock, full jitter; auth/schema errors stop retries.
Empty page ends cycle; offline keeps local records/pending ops; duplicate same hash returns original receipt.

## Wire and identity contract
SyncWireCodec.encodeSignedFrame(request:key:) throws -> Data; verifyFrame(_:trust:nonce:) throws -> VerifiedFrame.
Types reside in existing P01-owned files, not arbitrary helper packages; signatures sealed at CP-B.
SyncTransport.exchange(_ request: Data, endpoint: SyncEndpoint) async throws -> Data.
SyncEndpoint = registered ID, exact HTTPS origin, pinned signing public key, dataset/epoch; no wildcard host.
Request authentication binds body hash, method/path, dataset, epoch and nonce as revision1 15 specifies.
Add storeID to signed operation frame; include signature algorithm identifier fixed to Ed25519 v1.
Unknown JSON keys: versioned wire envelope rejects unknown fields/duplicate keys; file codecs preserve extension fields.
Key loading precedes transaction; transaction creates immutable unsigned operation+hash+sequence atomically.
Signing may happen after commit: persisted bytes freeze identity, retry signs identical bytes; never reread changed entity state.
Key unavailable leaves pending unsigned operation; not a successful sync. Revoked generation cannot send.
CP-B must specify key rotation handling for pre-rotation unsigned operations before enrollment is implemented.

## Composition graph
P07 tokens→P06/P08/P09/P10/P12/P13/P14 views.
P01 interfaces→P02 relay, P03/P04/P06/P13 adapters→P16 application roots→P18 journeys.
P04 training DTO/receipt→P11 exporter→P10 workout UI→P14 intents; P16 injects platform implementation.
P09 sanitized finance snapshot→P16 Home and P14 widgets; no widget provider networking.
P13 sanitized publication DTO→P02 gateway route admission; raw cache never crosses this edge.
P16 membership substep precedes W1; final composition follows product interfaces. No circular source ownership.
