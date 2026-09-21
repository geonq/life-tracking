# SyncChallenge — exact proposed schema
Owner: P02. Lifecycle: transient. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncChallenge: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let nonce: String
 public let expiresInSeconds: Int
}
```
```python
@dataclass(frozen=True)
class SyncChallenge:
    schemaVersion: int
    nonce: str
    expiresInSeconds: int
```
```typescript
interface SyncChallenge {
 readonly schemaVersion: number;
 readonly nonce: string;
 readonly expiresInSeconds: number;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|nonce|NONCE|
|expiresInSeconds|exact120|

Bound server-side to requesting dataset/sender and boot generation, monotonic120s expiry; consumed once. Outstanding requests invalid after restart; fresh challenge required.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"expiresInSeconds":120,"nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","schemaVersion":1}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"expiresInSeconds":0,"nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
