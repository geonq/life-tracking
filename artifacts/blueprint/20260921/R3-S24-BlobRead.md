# BlobRead
Owner:P01 schema/P02 blob handlers; P01 local receipts. Required keys, no default, rules R3-00.
BlobChunk/BlobRead/BlobResult transient; verified blob bytes persist. EntityVersion/checkpoint/commit receipts persist.
```swift
public struct BlobRead: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let storeID: String
 public let hash: String
 public let offset: Int
}
```
```python
@dataclass(frozen=True)
class BlobRead:
    schemaVersion: int
    storeID: str
    hash: str
    offset: int
```
```typescript
interface BlobRead {
 readonly schemaVersion: number;
 readonly storeID: string;
 readonly hash: string;
 readonly offset: number;
}
```
|Encoding name|Validation|
|---|---|
|schemaVersion|exact1|
|storeID|U|
|hash|HASH|
|offset|0...33554431; multiple262144|
Reply chunk<=262144decoded; unknown/incomplete blob invalidInput; only current membership store access.
All versioned records reject version!=1; legacy migration never defaults malformed fields.
Canonical structural JSON (hash-linked examples need real hashes at CP-W):
```json
{"hash":"0000000000000000000000000000000000000000000000000000000000000000","offset":0,"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}
```
Invalid: required fields absent; no write:
```json
{"schemaVersion":0}
```
