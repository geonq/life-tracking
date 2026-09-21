# SyncConflict — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncConflict: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let conflictID: String
 public let storeID: String
 public let entityID: String
 public let branches: [SyncOperation]
 public let reason: String
 public let resolutionID: String?
}
```
```python
@dataclass(frozen=True)
class SyncConflict:
    schemaVersion: int
    conflictID: str
    storeID: str
    entityID: str
    branches: tuple[SyncOperation, ...]
    reason: str
    resolutionID: str | None
```
```typescript
interface SyncConflict {
 readonly schemaVersion: number;
 readonly conflictID: string;
 readonly storeID: string;
 readonly entityID: string;
 readonly branches: ReadonlyArray<SyncOperation>;
 readonly reason: string;
 readonly resolutionID: string | null;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|conflictID|HASH(C(sorted operationHashes))|
|storeID|U|
|entityID|HASH|
|branches|2...8 unique operations sorted mutationID|
|reason|concurrentEdit\|deleteEdit\|identityRevoked\|externalFile|
|resolutionID|U or null|

Unresolved content cannot GC. More than8 branches blocks new apply with capacity preserving existing/incoming durable inbox. ExternalFile requires existing Planning conflict material; CP-S04 supplies its bridge. The example shows two branch records; domain validity and authentic signatures remain CP-S/CP-W evidence gates.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"branches":[{"baseHash":null,"datasetID":"11111111-1111-4111-8111-111111111111","domain":"calendar","entityID":"0000000000000000000000000000000000000000000000000000000000000000","epoch":"1","keyID":"0000000000000000000000000000000000000000000000000000000000000000","kind":"bootstrap","mutationID":"22222222-2222-4222-8222-222222222222","originID":"22222222-2222-4222-8222-222222222222","parents":[],"payload":{"blobHash":null,"byteCount":0,"hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","inline":"","schemaVersion":1},"schemaVersion":1,"sequence":"1","signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","storeID":"11111111-1111-4111-8111-111111111111"},{"baseHash":null,"datasetID":"11111111-1111-4111-8111-111111111111","domain":"calendar","entityID":"0000000000000000000000000000000000000000000000000000000000000000","epoch":"1","keyID":"0000000000000000000000000000000000000000000000000000000000000000","kind":"bootstrap","mutationID":"33333333-3333-4333-8333-333333333333","originID":"22222222-2222-4222-8222-222222222222","parents":[],"payload":{"blobHash":null,"byteCount":0,"hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","inline":"","schemaVersion":1},"schemaVersion":1,"sequence":"2","signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","storeID":"11111111-1111-4111-8111-111111111111"}],"conflictID":"0000000000000000000000000000000000000000000000000000000000000000","entityID":"0000000000000000000000000000000000000000000000000000000000000000","reason":"concurrentEdit","resolutionID":null,"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"branches":[],"schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
