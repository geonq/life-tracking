# SyncChallengeRequest — exact proposed schema
Owner: P02. Lifecycle: transient. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncChallengeRequest: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let datasetID: String
 public let senderID: String
}
```
```python
@dataclass(frozen=True)
class SyncChallengeRequest:
    schemaVersion: int
    datasetID: str
    senderID: str
```
```typescript
interface SyncChallengeRequest {
 readonly schemaVersion: number;
 readonly datasetID: string;
 readonly senderID: string;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|datasetID|U|
|senderID|U|

Unauthenticated challenge issuance reveals no data/membership; unknown IDs same response shape/rate limits.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"datasetID":"11111111-1111-4111-8111-111111111111","schemaVersion":1,"senderID":"22222222-2222-4222-8222-222222222222"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"schemaVersion":1,"senderID":"AAAA"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
