# SyncStream — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncStream: Codable, Equatable, Sendable {
 public let storeID: String
 public let originID: String
}
```
```python
@dataclass(frozen=True)
class SyncStream:
    storeID: str
    originID: str
```
```typescript
interface SyncStream {
 readonly storeID: string;
 readonly originID: string;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|storeID|U; membership logical store|
|originID|U; enrolled applying device|

Nested identity scoped by parent dataset. Sort by storeID then originID.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"originID":"untrusted name","storeID":"11111111-1111-4111-8111-111111111111"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
