# SyncHelloResponse — exact proposed schema
Owner: P02. Lifecycle: transient. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncHelloResponse: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let membershipHash: String
 public let maximumPageOperations: Int
 public let maximumBodyBytes: Int
}
```
```python
@dataclass(frozen=True)
class SyncHelloResponse:
    schemaVersion: int
    membershipHash: str
    maximumPageOperations: int
    maximumBodyBytes: int
```
```typescript
interface SyncHelloResponse {
 readonly schemaVersion: number;
 readonly membershipHash: string;
 readonly maximumPageOperations: number;
 readonly maximumBodyBytes: number;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|membershipHash|HASH|
|maximumPageOperations|exact128|
|maximumBodyBytes|exact1048576|

Mismatch requires local trust repair; no silent endpoint fallback.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"maximumBodyBytes":1048576,"maximumPageOperations":128,"membershipHash":"0000000000000000000000000000000000000000000000000000000000000000","schemaVersion":1}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"maximumBodyBytes":1048576,"maximumPageOperations":0,"membershipHash":"0000000000000000000000000000000000000000000000000000000000000000","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
