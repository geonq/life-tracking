# SyncOperation — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncOperation: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let datasetID: String
 public let epoch: String
 public let storeID: String
 public let domain: SyncDomain
 public let originID: String
 public let keyID: String
 public let sequence: String
 public let mutationID: String
 public let entityID: String
 public let parents: [String]
 public let baseHash: String?
 public let kind: SyncOperationKind
 public let payload: SyncPayload
 public let signature: String
}
```
```python
@dataclass(frozen=True)
class SyncOperation:
    schemaVersion: int
    datasetID: str
    epoch: str
    storeID: str
    domain: SyncDomain
    originID: str
    keyID: str
    sequence: str
    mutationID: str
    entityID: str
    parents: tuple[str, ...]
    baseHash: str | None
    kind: SyncOperationKind
    payload: SyncPayload
    signature: str
```
```typescript
interface SyncOperation {
 readonly schemaVersion: number;
 readonly datasetID: string;
 readonly epoch: string;
 readonly storeID: string;
 readonly domain: SyncDomain;
 readonly originID: string;
 readonly keyID: string;
 readonly sequence: string;
 readonly mutationID: string;
 readonly entityID: string;
 readonly parents: ReadonlyArray<string>;
 readonly baseHash: string | null;
 readonly kind: SyncOperationKind;
 readonly payload: SyncPayload;
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
|domain|closed Domain|
|originID|U|
|keyID|HASH of signer public key|
|sequence|POSQ|
|mutationID|U; durable idempotency identity|
|entityID|HASH of local kind+NUL+legacyID|
|parents|0...8 unique sorted U|
|baseHash|HASH or null|
|kind|put\|delete\|resolve\|bootstrap|
|payload|validated bytes/reference|
|signature|SIG; sign(operation,x)|

bootstrap alone may have null base/no parents for existing entity. put new entity may use null base; existing entity requires known parents/base. resolve names>=2 conflicting parents. Delete existing entity requires parents/base; payload empty. No clock-based winner. Sample bootstrap payload needs valid domain content before domain acceptance.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"baseHash":null,"datasetID":"11111111-1111-4111-8111-111111111111","domain":"calendar","entityID":"0000000000000000000000000000000000000000000000000000000000000000","epoch":"1","keyID":"0000000000000000000000000000000000000000000000000000000000000000","kind":"bootstrap","mutationID":"22222222-2222-4222-8222-222222222222","originID":"22222222-2222-4222-8222-222222222222","parents":[],"payload":{"blobHash":null,"byteCount":0,"hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","inline":"","schemaVersion":1},"schemaVersion":1,"sequence":"1","signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","storeID":"11111111-1111-4111-8111-111111111111"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"schemaVersion":1,"sequence":"-1"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
