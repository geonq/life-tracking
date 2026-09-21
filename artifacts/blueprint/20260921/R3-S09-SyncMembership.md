# SyncMembership — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncMembership: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let datasetID: String
 public let epoch: String
 public let previousHash: String?
 public let ownerKeyID: String
 public let members: [SyncMember]
 public let stores: [SyncStoreDescriptor]
 public let signature: String
}
```
```python
@dataclass(frozen=True)
class SyncMembership:
    schemaVersion: int
    datasetID: str
    epoch: str
    previousHash: str | None
    ownerKeyID: str
    members: tuple[SyncMember, ...]
    stores: tuple[SyncStoreDescriptor, ...]
    signature: str
```
```typescript
interface SyncMembership {
 readonly schemaVersion: number;
 readonly datasetID: string;
 readonly epoch: string;
 readonly previousHash: string | null;
 readonly ownerKeyID: string;
 readonly members: ReadonlyArray<SyncMember>;
 readonly stores: ReadonlyArray<SyncStoreDescriptor>;
 readonly signature: string;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|datasetID|U|
|epoch|POSQ|
|previousHash|HASH or null only epoch1|
|ownerKeyID|HASH; locally pinned offline owner key|
|members|1...8 unique deviceID/keyID, sorted deviceID|
|stores|1...32 unique storeID/kind sorted storeID|
|signature|SIG; sign(membership,x)|

First membership/fingerprint confirmed out of band. Network cannot enroll. Updates epoch exactly+1 and previousHash matches current; owner key unchanged. Revocation stops admission under store fence. Rollback membership rejected.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"datasetID":"11111111-1111-4111-8111-111111111111","epoch":"1","members":[{"deviceID":"11111111-1111-4111-8111-111111111111","endpoint":null,"keyID":"0000000000000000000000000000000000000000000000000000000000000000","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","role":"applying"}],"ownerKeyID":"0000000000000000000000000000000000000000000000000000000000000000","previousHash":null,"schemaVersion":1,"signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","stores":[{"domain":"calendar","kind":"calendar","payloadVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}]}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"epoch":"0","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
