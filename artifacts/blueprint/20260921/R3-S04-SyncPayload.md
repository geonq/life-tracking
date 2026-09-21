# SyncPayload — exact proposed schema
Owner: P01. Lifecycle: persisted. All fields inherit required/no-default/v1 rules R3-00.
## Swift / Python / TypeScript
```swift
public struct SyncPayload: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let hash: String
 public let byteCount: Int
 public let inline: String?
 public let blobHash: String?
}
```
```python
@dataclass(frozen=True)
class SyncPayload:
    schemaVersion: int
    hash: str
    byteCount: int
    inline: str | None
    blobHash: str | None
```
```typescript
interface SyncPayload {
 readonly schemaVersion: number;
 readonly hash: string;
 readonly byteCount: number;
 readonly inline: string | null;
 readonly blobHash: string | null;
}
```
## Per-field encoding and validation
|Encoding key (=property)|Constraint; all keys required, nullable explicitly null|
|---|---|
|schemaVersion|POS integer<=65535; exact per-store payload version|
|hash|HASH; SHA256 of raw payload bytes|
|byteCount|0...33554432; stricter store cap wins|
|inline|B64<=65536 decoded or null|
|blobHash|HASH or null|

Exactly one inline/blobHash non-null. blobHash equals hash. Delete payload inline empty, byteCount0, actual SHA256(empty), not zero sample hash. Inline length/hash must match. Blob must be verified durable before operation admission.
Version/migration: payload schemaVersion must equal enrolled store payloadVersion; v1 membership initially allows1 only. Transport version remains1. No default for omitted fields.
## Canonical structural example
```json
{"blobHash":null,"byteCount":0,"hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","inline":"","schemaVersion":1}
```
Example is schema-shape documentation; signed/hash-linked/domain payload examples are not an authentication golden vector.
## Invalid example
```json
{"blobHash":"0000000000000000000000000000000000000000000000000000000000000000","byteCount":0,"hash":"0000000000000000000000000000000000000000000000000000000000000000","inline":"","schemaVersion":1}
```
Reject before mutation; missing required fields, invalid enum/bound, or validation rule cannot be defaulted.
