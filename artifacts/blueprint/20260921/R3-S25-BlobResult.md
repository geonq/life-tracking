# BlobResult
Owner:P01 schema/P02 blob handlers; P01 local receipts. Required keys, no default, rules R3-00.
BlobChunk/BlobRead/BlobResult transient; verified blob bytes persist. EntityVersion/checkpoint/commit receipts persist.
```swift
public struct BlobResult: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let storeID: String
 public let hash: String
 public let receivedThrough: Int
 public let complete: Bool
}
```
```python
@dataclass(frozen=True)
class BlobResult:
    schemaVersion: int
    storeID: str
    hash: str
    receivedThrough: int
    complete: bool
```
```typescript
interface BlobResult {
 readonly schemaVersion: number;
 readonly storeID: string;
 readonly hash: string;
 readonly receivedThrough: number;
 readonly complete: boolean;
}
```
|Encoding name|Validation|
|---|---|
|schemaVersion|exact1|
|storeID|U|
|hash|HASH|
|receivedThrough|0...33554432 contiguous bytes|
|complete|true only full hash checked and file+DB durable|
Incomplete upload cannot be referenced by stored operation. Completion ACK after durable blob rename and transactional metadata, recover orphans by verified hash; never assume atomicity across DB/file.
All versioned records reject version!=1; legacy migration never defaults malformed fields.
Canonical structural JSON (hash-linked examples need real hashes at CP-W):
```json
{"complete":false,"hash":"0000000000000000000000000000000000000000000000000000000000000000","receivedThrough":1,"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}
```
Invalid: required fields absent; no write:
```json
{"schemaVersion":0}
```
