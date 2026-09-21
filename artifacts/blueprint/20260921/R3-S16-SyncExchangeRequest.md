# SyncExchangeRequest — exact proposed schema
Owner: P01. Lifecycle: transient. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncExchangeRequest: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let storeID: String
 public let received: SyncFrontier
 public let upper: SyncFrontier?
 public let operations: [SyncOperation]
 public let acknowledgements: [SyncAck]
 public let limit: Int
}
```
```python
@dataclass(frozen=True)
class SyncExchangeRequest:
    schemaVersion: int
    storeID: str
    received: SyncFrontier
    upper: SyncFrontier | None
    operations: tuple[SyncOperation, ...]
    acknowledgements: tuple[SyncAck, ...]
    limit: int
```
```typescript
interface SyncExchangeRequest {
 readonly schemaVersion: number;
 readonly storeID: string;
 readonly received: SyncFrontier;
 readonly upper: SyncFrontier | null;
 readonly operations: ReadonlyArray<SyncOperation>;
 readonly acknowledgements: ReadonlyArray<SyncAck>;
 readonly limit: number;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|storeID|U|
|received|durable local inbox coverage|
|upper|server frozen page upper or null|
|operations|0...128 bounded by body cap|
|acknowledgements|0...128 bounded by body cap|
|limit|1...128|

One logical store per request. All operations/frontiers/ACKs match store. upper null starts page snapshot. Received frontier advanced only after local inbox durable, distinct from applied.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"acknowledgements":[],"limit":128,"operations":[],"received":{"positions":[{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"}],"schemaVersion":1},"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111","upper":null}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"limit":129,"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
