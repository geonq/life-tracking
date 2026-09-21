# SyncStoreDescriptor — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncStoreDescriptor: Codable, Equatable, Sendable {
 public let storeID: String
 public let domain: SyncDomain
 public let kind: String
 public let payloadVersion: Int
}
```
```python
@dataclass(frozen=True)
class SyncStoreDescriptor:
    storeID: str
    domain: SyncDomain
    kind: str
    payloadVersion: int
```
```typescript
interface SyncStoreDescriptor {
 readonly storeID: string;
 readonly domain: SyncDomain;
 readonly kind: string;
 readonly payloadVersion: number;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|storeID|U|
|domain|closed Domain|
|kind|closed R3-04 kind|
|payloadVersion|1...65535|

One membership mapping per kind (one selected vault in v1); per-device paths never encoded. Kind fixes exact decoder.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"domain":"calendar","kind":"calendar","payloadVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"domain":"calendar","kind":"run-command","payloadVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
