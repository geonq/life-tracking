# SyncAck — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncAck: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let datasetID: String
 public let epoch: String
 public let storeID: String
 public let mutationID: String
 public let operationHash: String
 public let replicaID: String
 public let keyID: String
 public let level: SyncAckLevel
 public let resultHash: String
 public let signature: String
}
```
```python
@dataclass(frozen=True)
class SyncAck:
    schemaVersion: int
    datasetID: str
    epoch: str
    storeID: str
    mutationID: str
    operationHash: str
    replicaID: str
    keyID: str
    level: SyncAckLevel
    resultHash: str
    signature: str
```
```typescript
interface SyncAck {
 readonly schemaVersion: number;
 readonly datasetID: string;
 readonly epoch: string;
 readonly storeID: string;
 readonly mutationID: string;
 readonly operationHash: string;
 readonly replicaID: string;
 readonly keyID: string;
 readonly level: SyncAckLevel;
 readonly resultHash: string;
 readonly signature: string;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|datasetID|U|
|epoch|POSQ|
|storeID|U|
|mutationID|U|
|operationHash|HASH over operation signing bytes|
|replicaID|U; actual signer/receipt producer|
|keyID|HASH|
|level|stored\|applied\|retainedConflict|
|resultHash|HASH of stored operation or applied state/conflict|
|signature|SIG; sign(acknowledgement,x)|

Transport replicas may issue stored only; applying device signs applied/conflict. Same ID/hash/level receipt immutable. Rejection/missing parent never ACK. Windows stored plus both Apple applied/retainedConflict needed for history GC, unresolved conflict content retained.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"datasetID":"11111111-1111-4111-8111-111111111111","epoch":"1","keyID":"0000000000000000000000000000000000000000000000000000000000000000","level":"stored","mutationID":"22222222-2222-4222-8222-222222222222","operationHash":"0000000000000000000000000000000000000000000000000000000000000000","replicaID":"11111111-1111-4111-8111-111111111111","resultHash":"0000000000000000000000000000000000000000000000000000000000000000","schemaVersion":1,"signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","storeID":"11111111-1111-4111-8111-111111111111"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"level":"rejected","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
