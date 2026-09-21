# SyncError — exact proposed schema
Owner: P01. Lifecycle: transient; local lastError field persists code only. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncError: Error, Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let code: SyncErrorCode
 public let mutationID: String?
 public let retryAfterSeconds: Int?
}
```
```python
@dataclass(frozen=True)
class SyncError:
    schemaVersion: int
    code: SyncErrorCode
    mutationID: str | None
    retryAfterSeconds: int | None
```
```typescript
interface SyncError {
 readonly schemaVersion: number;
 readonly code: SyncErrorCode;
 readonly mutationID: string | null;
 readonly retryAfterSeconds: number | null;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|code|closed taxonomy R3-01|
|mutationID|U or null|
|retryAfterSeconds|1...900 or null|

No raw message/payload/stack/user identifiers. Auth errors unsigned constant401 before trust; signed errors only after authenticated frame.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"code":"offline","mutationID":null,"retryAfterSeconds":null,"schemaVersion":1}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"code":"unknown-error","mutationID":null,"retryAfterSeconds":null,"schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
