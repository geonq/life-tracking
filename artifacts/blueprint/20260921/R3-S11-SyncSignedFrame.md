# SyncSignedFrame — exact proposed schema
Owner: P01. Lifecycle: transient (nonce reservation on server) . All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncSignedFrame: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let datasetID: String
 public let epoch: String
 public let endpointID: String
 public let senderID: String
 public let keyID: String
 public let requestID: String
 public let nonce: String
 public let method: String
 public let path: String
 public let status: Int
 public let body: String
 public let bodyHash: String
 public let signature: String
}
```
```python
@dataclass(frozen=True)
class SyncSignedFrame:
    schemaVersion: int
    datasetID: str
    epoch: str
    endpointID: str
    senderID: str
    keyID: str
    requestID: str
    nonce: str
    method: str
    path: str
    status: int
    body: str
    bodyHash: str
    signature: str
```
```typescript
interface SyncSignedFrame {
 readonly schemaVersion: number;
 readonly datasetID: string;
 readonly epoch: string;
 readonly endpointID: string;
 readonly senderID: string;
 readonly keyID: string;
 readonly requestID: string;
 readonly nonce: string;
 readonly method: string;
 readonly path: string;
 readonly status: number;
 readonly body: string;
 readonly bodyHash: string;
 readonly signature: string;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|V|
|datasetID|U|
|epoch|POSQ|
|endpointID|U; response signer registered server|
|senderID|U|
|keyID|HASH|
|requestID|U|
|nonce|NONCE; issued one-use server challenge|
|method|literal POST|
|path|one exact R3-01 route<=64bytes|
|status|request0; response valid HTTP status|
|body|B64 decoded<=1048576|
|bodyHash|HASH of exact decoded body|
|signature|SIG; sign(frame,x)|

Request sender app, response sender endpoint; compare response requestID/nonce/path/endpoint/dataset/epoch. Outer encoded bytes<=2097152. Cannot verify only body hash; full frame signature required.
Version/migration: all wire versions other than1 reject; local legacy migration R3-03. Never omit a new required field.
## Canonical structural example
```json
{"body":"e30","bodyHash":"0000000000000000000000000000000000000000000000000000000000000000","datasetID":"11111111-1111-4111-8111-111111111111","endpointID":"11111111-1111-4111-8111-111111111111","epoch":"1","keyID":"0000000000000000000000000000000000000000000000000000000000000000","method":"POST","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","path":"/replication/v1/hello","requestID":"22222222-2222-4222-8222-222222222222","schemaVersion":1,"senderID":"22222222-2222-4222-8222-222222222222","signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","status":0}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"method":"GET","path":"/replication/v1/hello","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
