# SyncCheckpointReceipt
Owner:P01 schema/P02 blob handlers; P01 local receipts. Required keys, no default, rules R3-00.
BlobChunk/BlobRead/BlobResult transient; verified blob bytes persist. EntityVersion/checkpoint/commit receipts persist.
```swift
public struct SyncCheckpointReceipt: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let checkpointHash: String
 public let storeID: String
 public let covered: SyncFrontier
 public let removedOperations: Int
}
```
```python
@dataclass(frozen=True)
class SyncCheckpointReceipt:
    schemaVersion: int
    checkpointHash: str
    storeID: str
    covered: SyncFrontier
    removedOperations: int
```
```typescript
interface SyncCheckpointReceipt {
 readonly schemaVersion: number;
 readonly checkpointHash: string;
 readonly storeID: string;
 readonly covered: SyncFrontier;
 readonly removedOperations: number;
}
```
|Encoding name|Validation|
|---|---|
|schemaVersion|exact1|
|checkpointHash|HASH(checkpoint signing bytes)|
|storeID|U|
|covered|validated covered frontier|
|removedOperations|0...50000|
Local result only; no network checkpoint-install endpoint. Zero removals allowed; invalid archive never yields success. Durable checkpoint before removal.
All versioned records reject version!=1; legacy migration never defaults malformed fields.
Canonical structural JSON (hash-linked examples need real hashes at CP-W):
```json
{"checkpointHash":"0000000000000000000000000000000000000000000000000000000000000000","covered":{"positions":[],"schemaVersion":1},"removedOperations":0,"schemaVersion":1,"storeID":"11111111-1111-4111-8111-111111111111"}
```
Invalid: required fields absent; no write:
```json
{"schemaVersion":0}
```
