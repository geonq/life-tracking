# BlobChunk
Owner:P01 schema/P02 blob handlers; P01 local receipts. Required keys, no default, rules R3-00.
BlobChunk/BlobRead/BlobResult transient; verified blob bytes persist. EntityVersion/checkpoint/commit receipts persist.
```swift
public struct BlobChunk: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let storeID: String
 public let hash: String
 public let totalBytes: Int
 public let offset: Int
 public let bytes: String
}
```
```python
@dataclass(frozen=True)
class BlobChunk:
    schemaVersion: int
    storeID: str
    hash: str
    totalBytes: int
    offset: int
    bytes: str
```
```typescript
interface BlobChunk {
 readonly schemaVersion: number;
 readonly storeID: string;
 readonly hash: string;
 readonly totalBytes: number;
 readonly offset: number;
 readonly bytes: string;
}
```
|Encoding name|Validation|
|---|---|
|schemaVersion|exact1|
|storeID|U|
|hash|HASH whole blob|
|totalBytes|1...33554432|
|offset|0...totalBytes-1; multiple262144 except final|
|bytes|B64 decoded1...262144; offset+length<=totalBytes|
One upload per dataset/store/hash; duplicate same offset+bytes no-op, differing bytes idCollision. Read response identical shape. Complete whole hash verified before final publication. No client filename.
All versioned records reject version!=1; legacy migration never defaults malformed fields.
Canonical structural JSON (hash-linked examples need real hashes at CP-W):
```json
{"bytes":"YQ","hash":"0000000000000000000000000000000000000000000000000000000000000000","offset":0,"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111","totalBytes":1}
```
Invalid: required fields absent; no write:
```json
{"schemaVersion":0}
```
