# SyncMember — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncMember: Codable, Equatable, Sendable {
 public let deviceID: String
 public let keyID: String
 public let publicKey: String
 public let role: SyncReplicaRole
 public let endpoint: String?
}
```
```python
@dataclass(frozen=True)
class SyncMember:
    deviceID: str
    keyID: str
    publicKey: str
    role: SyncReplicaRole
    endpoint: str | None
```
```typescript
interface SyncMember {
 readonly deviceID: string;
 readonly keyID: string;
 readonly publicKey: string;
 readonly role: SyncReplicaRole;
 readonly endpoint: string | null;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|deviceID|U|
|keyID|HASH(publicKey)|
|publicKey|KEY|
|role|applying\|storing|
|endpoint|exact HTTPS origin<=253bytes; no path/query/userinfo or null|

Mac app, iPhone app and Mac relay are distinct keys/IDs; relay storing, app applying. Max8 members. PublicKey hash consistency required.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"deviceID":"11111111-1111-4111-8111-111111111111","endpoint":null,"keyID":"0000000000000000000000000000000000000000000000000000000000000000","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","role":"applying"}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"deviceID":"11111111-1111-4111-8111-111111111111","endpoint":null,"keyID":"0000000000000000000000000000000000000000000000000000000000000000","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","role":"owner-admin-shell"}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
