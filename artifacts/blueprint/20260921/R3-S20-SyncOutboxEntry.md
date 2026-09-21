# SyncOutboxEntry — exact proposed schema
Owner: P01. Lifecycle: persisted local only. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncOutboxEntry: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let operation: SyncOperation
 public let state: SyncOutboxState
 public let attempts: Int
 public let lastError: String?
 public let acknowledgements: [SyncAck]
}
```
```python
@dataclass(frozen=True)
class SyncOutboxEntry:
    schemaVersion: int
    operation: SyncOperation
    state: SyncOutboxState
    attempts: int
    lastError: str | None
    acknowledgements: tuple[SyncAck, ...]
```
```typescript
interface SyncOutboxEntry {
 readonly schemaVersion: number;
 readonly operation: SyncOperation;
 readonly state: SyncOutboxState;
 readonly attempts: number;
 readonly lastError: string | null;
 readonly acknowledgements: ReadonlyArray<SyncAck>;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|operation|immutable operation; signature may empty ONLY state unsigned|
|state|unsigned\|ready\|awaitingAcks\|blocked|
|attempts|0...2147483647; saturates|
|lastError|taxonomy code or null|
|acknowledgements|0...24 distinct replica+level|

Unsigned signed-operation-shaped record is NOT wire-valid; signatures complete before send. All immutable signed fields allocated at local commit, including keyID. Rotation blocked until unsigned signed/drained; emergency revoke keeps blocked record for explicit reissue.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"acknowledgements":[],"attempts":0,"lastError":null,"operation":{"baseHash":null,"datasetID":"11111111-1111-4111-8111-111111111111","domain":"calendar","entityID":"0000000000000000000000000000000000000000000000000000000000000000","epoch":"1","keyID":"0000000000000000000000000000000000000000000000000000000000000000","kind":"bootstrap","mutationID":"22222222-2222-4222-8222-222222222222","originID":"22222222-2222-4222-8222-222222222222","parents":[],"payload":{"blobHash":null,"byteCount":0,"hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","inline":"","schemaVersion":1},"schemaVersion":1,"sequence":"1","signature":"","storeID":"11111111-1111-4111-8111-111111111111"},"schemaVersion":1,"state":"unsigned"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"schemaVersion":1,"state":"evicted"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
