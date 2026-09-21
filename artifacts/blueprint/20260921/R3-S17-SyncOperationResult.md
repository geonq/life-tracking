# SyncOperationResult — exact proposed schema
Owner: P02. Lifecycle: transient. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncOperationResult: Codable, Equatable, Sendable {
 public let mutationID: String
 public let disposition: String
 public let error: SyncError?
}
```
```python
@dataclass(frozen=True)
class SyncOperationResult:
    mutationID: str
    disposition: str
    error: SyncError | None
```
```typescript
interface SyncOperationResult {
 readonly mutationID: string;
 readonly disposition: string;
 readonly error: SyncError | null;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|mutationID|U|
|disposition|stored\|alreadyStored\|rejected|
|error|non-null iff rejected|

Accepted stored rows have separate SyncAck. No applied disposition from server spool. Same mutationID/different signed content rejected idCollision; invalid payload digest alone is hashMismatch.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"disposition":"rejected","error":{"code":"missingParent","mutationID":"22222222-2222-4222-8222-222222222222","retryAfterSeconds":null,"schemaVersion":1},"mutationID":"22222222-2222-4222-8222-222222222222"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"disposition":"applied","error":null,"mutationID":"22222222-2222-4222-8222-222222222222"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
