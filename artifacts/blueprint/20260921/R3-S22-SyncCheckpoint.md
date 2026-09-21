# SyncCheckpoint — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncCheckpoint: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let datasetID: String
 public let epoch: String
 public let storeID: String
 public let frontier: SyncFrontier
 public let archive: SyncPayload
 public let receiptRoot: String
 public let creatorID: String
 public let keyID: String
 public let signature: String
}
```
```python
@dataclass(frozen=True)
class SyncCheckpoint:
    schemaVersion: int
    datasetID: str
    epoch: str
    storeID: str
    frontier: SyncFrontier
    archive: SyncPayload
    receiptRoot: str
    creatorID: str
    keyID: str
    signature: str
```
```typescript
interface SyncCheckpoint {
 readonly schemaVersion: number;
 readonly datasetID: string;
 readonly epoch: string;
 readonly storeID: string;
 readonly frontier: SyncFrontier;
 readonly archive: SyncPayload;
 readonly receiptRoot: string;
 readonly creatorID: string;
 readonly keyID: string;
 readonly signature: string;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|datasetID|U|
|epoch|POSQ|
|storeID|U|
|frontier|covered contiguous frontier|
|archive|store-specific complete bounded archive, no raw tax|
|receiptRoot|HASH(C(sorted covered ACK hashes))|
|creatorID|U applying device|
|keyID|HASH|
|signature|SIG; sign(checkpoint,x)|

Archive binds entity state, tombstones and receipt IDs; domain-specific format CP-S. No production GC until archive decoder/restore sealed. Rollback never installs state behind acknowledged frontier.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"archive":{"blobHash":null,"byteCount":0,"hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","inline":"","schemaVersion":1},"creatorID":"22222222-2222-4222-8222-222222222222","datasetID":"11111111-1111-4111-8111-111111111111","epoch":"1","frontier":{"positions":[{"stream":{"originID":"22222222-2222-4222-8222-222222222222","storeID":"11111111-1111-4111-8111-111111111111"},"through":"0"}],"schemaVersion":1},"keyID":"0000000000000000000000000000000000000000000000000000000000000000","receiptRoot":"0000000000000000000000000000000000000000000000000000000000000000","schemaVersion":1,"signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","storeID":"11111111-1111-4111-8111-111111111111"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"epoch":"0","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
