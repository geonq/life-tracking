# SyncHelloRequest — exact proposed schema
Owner: P01. Lifecycle: transient. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncHelloRequest: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let membershipHash: String
}
```
```python
@dataclass(frozen=True)
class SyncHelloRequest:
    schemaVersion: int
    membershipHash: str
```
```typescript
interface SyncHelloRequest {
 readonly schemaVersion: number;
 readonly membershipHash: string;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|membershipHash|HASH|

Signed; hash must equal server trust. Does not enroll or replace membership.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"membershipHash":"0000000000000000000000000000000000000000000000000000000000000000","schemaVersion":1}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"membershipHash":"0000000000000000000000000000000000000000000000000000000000000000","schemaVersion":2}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
