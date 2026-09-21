# SyncCommitReceipt
Owner:P01 schema/P02 blob handlers; P01 local receipts. Required keys, no default, rules R3-00.
BlobChunk/BlobRead/BlobResult transient; verified blob bytes persist. EntityVersion/checkpoint/commit receipts persist.
```swift
public struct SyncCommitReceipt: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let mutationID: String
 public let operationHash: String
 public let entityVersion: String
 public let disposition: String
}
```
```python
@dataclass(frozen=True)
class SyncCommitReceipt:
    schemaVersion: int
    mutationID: str
    operationHash: str
    entityVersion: str
    disposition: str
```
```typescript
interface SyncCommitReceipt {
 readonly schemaVersion: number;
 readonly mutationID: string;
 readonly operationHash: string;
 readonly entityVersion: string;
 readonly disposition: string;
}
```
|Encoding name|Validation|
|---|---|
|schemaVersion|exact1|
|mutationID|U|
|operationHash|HASH|
|entityVersion|HASH|
|disposition|applied\|retainedConflict\|alreadyApplied|
Local durable domain receipt, not server stored ACK. Errors thrown separately; cannot return rejected as successful commit.
All versioned records reject version!=1; legacy migration never defaults malformed fields.
Canonical structural JSON (hash-linked examples need real hashes at CP-W):
```json
{"disposition":"applied","entityVersion":"0000000000000000000000000000000000000000000000000000000000000000","mutationID":"11111111-1111-4111-8111-111111111111","operationHash":"0000000000000000000000000000000000000000000000000000000000000000","schemaVersion":1}
```
Invalid: required fields absent; no write:
```json
{"schemaVersion":0}
```
