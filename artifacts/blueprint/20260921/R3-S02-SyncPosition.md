# SyncPosition — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncPosition: Codable, Equatable, Sendable {
 public let stream: SyncStream
 public let through: String
}
```
```python
@dataclass(frozen=True)
class SyncPosition:
    stream: SyncStream
    through: str
```
```typescript
interface SyncPosition {
 readonly stream: SyncStream;
 readonly through: string;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|stream|validated stream|
|through|Q; highest CONTIGUOUS durable sequence|

Missing sequence cannot be acknowledged by taking maximum observed. Zero means no operations.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"01"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
