# SyncAdapterEnvelope — exact proposed schema
Owner: P01. Lifecycle: persisted same local store transaction. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncAdapterEnvelope: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let storeID: String
 public let datasetID: String
 public let localOriginID: String
 public let epoch: String
 public let nextSequence: String
 public let received: SyncFrontier
 public let applied: SyncFrontier
 public let outbox: [SyncOutboxEntry]
 public let inbox: [SyncOperation]
 public let entities: [SyncEntityVersion]
 public let conflicts: [SyncConflict]
 public let acknowledgements: [SyncAck]
}
```
```python
@dataclass(frozen=True)
class SyncAdapterEnvelope:
    schemaVersion: int
    storeID: str
    datasetID: str
    localOriginID: str
    epoch: str
    nextSequence: str
    received: SyncFrontier
    applied: SyncFrontier
    outbox: tuple[SyncOutboxEntry, ...]
    inbox: tuple[SyncOperation, ...]
    entities: tuple[SyncEntityVersion, ...]
    conflicts: tuple[SyncConflict, ...]
    acknowledgements: tuple[SyncAck, ...]
```
```typescript
interface SyncAdapterEnvelope {
 readonly schemaVersion: number;
 readonly storeID: string;
 readonly datasetID: string;
 readonly localOriginID: string;
 readonly epoch: string;
 readonly nextSequence: string;
 readonly received: SyncFrontier;
 readonly applied: SyncFrontier;
 readonly outbox: ReadonlyArray<SyncOutboxEntry>;
 readonly inbox: ReadonlyArray<SyncOperation>;
 readonly entities: ReadonlyArray<SyncEntityVersion>;
 readonly conflicts: ReadonlyArray<SyncConflict>;
 readonly acknowledgements: ReadonlyArray<SyncAck>;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|storeID|U|
|datasetID|U|
|localOriginID|U|
|epoch|POSQ|
|nextSequence|POSQ|
|received|durable inbox frontier|
|applied|durably projected or retainedConflict frontier|
|outbox|0...10000 and enclosing-store byte cap|
|inbox|0...10000 and enclosing-store cap|
|entities|0...10000 sorted unique entityID; same transaction as projection; stricter store cap wins|
|conflicts|0...1000 and enclosing-store cap|
|acknowledgements|0...30000 and enclosing-store cap|

Optional replication key absent ONLY in legacy store -> explicit migration; never default from wire. nextSequence must exceed every allocated local sequence. Byte cap includes payloads. Received/applied frontiers cannot assert missing durable receipts.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"acknowledgements":[],"applied":{"positions":[{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"}],"schemaVersion":1},"conflicts":[],"datasetID":"11111111-1111-4111-8111-111111111111","entities":[],"epoch":"1","inbox":[],"localOriginID":"22222222-2222-4222-8222-222222222222","nextSequence":"1","outbox":[],"received":{"positions":[{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"}],"schemaVersion":1},"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"nextSequence":"0","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
