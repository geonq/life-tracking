# SyncEntityVersion
Owner:P01 schema/P02 blob handlers; P01 local receipts. Required keys, no default, rules R3-00.
BlobChunk/BlobRead/BlobResult transient; verified blob bytes persist. EntityVersion/checkpoint/commit receipts persist.
```swift
public struct SyncEntityVersion: Codable, Equatable, Sendable {
 public let entityID: String
 public let heads: [String]
 public let versionHash: String
 public let deleted: Bool
}
```
```python
@dataclass(frozen=True)
class SyncEntityVersion:
    entityID: str
    heads: tuple[str, ...]
    versionHash: str
    deleted: bool
```
```typescript
interface SyncEntityVersion {
 readonly entityID: string;
 readonly heads: ReadonlyArray<string>;
 readonly versionHash: string;
 readonly deleted: boolean;
}
```
|Encoding name|Validation|
|---|---|
|entityID|HASH|
|heads|0...8 unique U, sorted; empty only initial absent|
|versionHash|HASH(C(sorted operation hashes of heads))|
|deleted|true only unconflicted delete head|
Persisted same adapter envelope as domain projection. baseHash operation must equal this versionHash except new/bootstrap. Conflict retains multiple heads; entity not silently deleted.
All versioned records reject version!=1; legacy migration never defaults malformed fields.
Canonical structural JSON (hash-linked examples need real hashes at CP-W):
```json
{"deleted":false,"entityID":"0000000000000000000000000000000000000000000000000000000000000000","heads":[],"versionHash":"0000000000000000000000000000000000000000000000000000000000000000"}
```
Invalid: required fields absent; no write:
```json
{"schemaVersion":0}
```
