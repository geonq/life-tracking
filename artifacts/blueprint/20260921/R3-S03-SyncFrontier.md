# SyncFrontier — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncFrontier: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let positions: [SyncPosition]
}
```
```python
@dataclass(frozen=True)
class SyncFrontier:
    schemaVersion: int
    positions: tuple[SyncPosition, ...]
```
```typescript
interface SyncFrontier {
 readonly schemaVersion: number;
 readonly positions: ReadonlyArray<SyncPosition>;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|positions|0...256; unique sorted streams|

Absent stream means through0, not unenrolled; enrolled membership remains authoritative.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"positions":[{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"}],"schemaVersion":1}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"positions":[{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"},{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"}],"schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
