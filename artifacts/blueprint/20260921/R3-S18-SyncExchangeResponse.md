# SyncExchangeResponse — exact proposed schema
Owner: P02. Lifecycle: transient. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncExchangeResponse: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let storeID: String
 public let results: [SyncOperationResult]
 public let operations: [SyncOperation]
 public let acknowledgements: [SyncAck]
 public let upper: SyncFrontier
 public let more: Bool
}
```
```python
@dataclass(frozen=True)
class SyncExchangeResponse:
    schemaVersion: int
    storeID: str
    results: tuple[SyncOperationResult, ...]
    operations: tuple[SyncOperation, ...]
    acknowledgements: tuple[SyncAck, ...]
    upper: SyncFrontier
    more: bool
```
```typescript
interface SyncExchangeResponse {
 readonly schemaVersion: number;
 readonly storeID: string;
 readonly results: ReadonlyArray<SyncOperationResult>;
 readonly operations: ReadonlyArray<SyncOperation>;
 readonly acknowledgements: ReadonlyArray<SyncAck>;
 readonly upper: SyncFrontier;
 readonly more: boolean;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|storeID|U|
|results|one per submitted operation<=128|
|operations|0...128; bytes cap|
|acknowledgements|0...128; all signatures validated|
|upper|frozen server upper|
|more|true iff more rows below upper|

Paginate deterministic originID,sequence ascending within store. Client received counters may lag; duplicates okay. Missing parent is domain apply issue unless authenticated op requires unavailable blob. Capacity causes smaller page, not lost row.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"acknowledgements":[],"more":false,"operations":[],"results":[],"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111","upper":{"positions":[{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"}],"schemaVersion":1}}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"more":"false","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
