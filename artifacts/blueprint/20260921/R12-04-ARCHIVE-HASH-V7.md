# R12 complete V7 archive-hash contract

Planning-only. This sheet replaces the placeholder archive preimage in R11-07. Swift, Python and TypeScript must
hash the same canonical object and frame bytes.

## Canonical input shapes

```swift
public struct LifeOSArchiveFrameKindsV7: Codable, Sendable {
 public let archiveHeader: UInt8; public let packHeader: UInt8; public let fileHeader: UInt8
 public let chunk: UInt8; public let fileFooter: UInt8; public let packFooter: UInt8; public let archiveFooter: UInt8
}
public struct LifeOSManifestCarrierKindsV7: Codable, Sendable {
 public let packHeader: UInt8; public let packChunk: UInt8; public let packFooter: UInt8
 public let archiveHeader: UInt8; public let archiveChunk: UInt8; public let archiveFooter: UInt8
}
public struct LifeOSArchiveHashInputV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let archiveID: UUID
 public let preparedArtifactID: UUID; public let protection: String; public let representation: String
 public let retention: String; public let manifestPath: String; public let manifestRootHash: String
 public let manifestByteCount: UInt64; public let manifestChunkCount: UInt32
 public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
 public let frameKinds: LifeOSArchiveFrameKindsV7; public let manifestCarrierKinds: LifeOSManifestCarrierKindsV7
 public let packs: [LifeOSPackManifestRefV7]
}
```

The only valid constants are `schemaVersion=7`, `tag="lifeos.archive.v7"`, archive frame kinds
`1,2,3,4,5,6,7`, carrier kinds `1,2,3,4,5,6`, fixed `manifestPath="manifest/archive-index.json"`,
pack paths `manifest/packs/%04d.json`, lower-case UUID text, lower-case 64-character hex hashes, and NFC paths.
`LifeOSPackManifestBodyV7.tag` and `LifeOSPackManifestHeaderV7.tag` are exactly `"lifeos.pack-manifest.v7"`;
`LifeOSArchiveIndexV7.tag` is exactly `"lifeos.archive-index.v7"`.
`packs` is sorted by `packIndex`, contiguous from zero, and its length equals `declaredPackCount` (1...26).
All UInt16/32/64 fields except schema/kind values encode as decimal JSON strings to avoid JavaScript precision loss.

## Canonical object and digest bytes

The canonical object has exactly the JSON keys `archiveID, declaredByteCount, declaredChunkCount,
declaredFileCount, declaredPackCount, frameKinds, manifestByteCount, manifestCarrierKinds, manifestChunkCount,
manifestPath, manifestRootHash, packs, preparedArtifactID, protection, representation, retention, schemaVersion,
tag`. Object keys are sorted by UTF-8 bytes recursively; arrays preserve the order above. JSON is UTF-8 without
whitespace, duplicate keys, floating/nonfinite values or a trailing newline; strings are NFC and use minimal JSON
escaping. Frame-kind values and schemaVersion are JSON numbers; decimal adapters supply every other integer.
Each pack object has exactly `declaredByteCount,declaredChunkCount,declaredFileCount,manifestByteCount,
manifestChunkCount,manifestHash,manifestPath,packHash,packID,packIndex`, sorted by UTF-8 key bytes.

`archiveHash = hex(SHA256(UTF8("LifeOS/archive/v7") + 0x00 + UInt32BE(canonical.count) + canonical))`.
`manifestRootHash` uses the same framing with domain `LifeOS/archive-index/v7`; each `manifestHash` uses
`LifeOS/archive-pack-manifest/v7` over its streamed canonical pack body. The archive-hash preimage excludes
`archiveHash` itself. Swift is `LifeOSArchiveIntegrityV7.archiveHash(_:)`; Python is
`archive_hash_v7(input: ArchiveHashInputV7) -> str`; TypeScript is `archiveHashV7(input: ArchiveHashInputV7): string`.
All three reject missing/extra keys, bad order, noncanonical integers, noncontiguous packs and mismatched counts.

The equivalent transported shapes are binding, not implementation suggestions. The nested key sets are closed;
the typed shapes prevent a loose dictionary from accepting a missing or extra frame kind:

```python
from typing import TypedDict

class ArchiveFrameKindsV7(TypedDict):
    archiveHeader: int; packHeader: int; fileHeader: int; chunk: int
    fileFooter: int; packFooter: int; archiveFooter: int
class ManifestCarrierKindsV7(TypedDict):
    packHeader: int; packChunk: int; packFooter: int
    archiveHeader: int; archiveChunk: int; archiveFooter: int

class ArchivePackRefV7(TypedDict):
    packID: str; packIndex: str; manifestPath: str; manifestHash: str
    manifestByteCount: str; manifestChunkCount: str; packHash: str
    declaredFileCount: str; declaredChunkCount: str; declaredByteCount: str
class ArchiveHashInputV7(TypedDict):
    schemaVersion: int; tag: str; archiveID: str; preparedArtifactID: str
    protection: str; representation: str; retention: str; manifestPath: str
    manifestRootHash: str; manifestByteCount: str; manifestChunkCount: str
    declaredPackCount: str; declaredFileCount: str; declaredChunkCount: str; declaredByteCount: str
    frameKinds: ArchiveFrameKindsV7; manifestCarrierKinds: ManifestCarrierKindsV7; packs: list[ArchivePackRefV7]
```

```typescript
type ArchiveFrameKindsV7 = { archiveHeader:number; packHeader:number; fileHeader:number; chunk:number;
 fileFooter:number; packFooter:number; archiveFooter:number };
type ManifestCarrierKindsV7 = { packHeader:number; packChunk:number; packFooter:number;
 archiveHeader:number; archiveChunk:number; archiveFooter:number };
type ArchivePackRefV7 = { packID:string; packIndex:string; manifestPath:string; manifestHash:string;
 manifestByteCount:string; manifestChunkCount:string; packHash:string; declaredFileCount:string;
 declaredChunkCount:string; declaredByteCount:string };
type ArchiveHashInputV7 = { schemaVersion:number; tag:string; archiveID:string; preparedArtifactID:string;
 protection:string; representation:string; retention:string; manifestPath:string; manifestRootHash:string;
 manifestByteCount:string; manifestChunkCount:string; declaredPackCount:string; declaredFileCount:string;
 declaredChunkCount:string; declaredByteCount:string; frameKinds:ArchiveFrameKindsV7;
 manifestCarrierKinds:ManifestCarrierKindsV7; packs:ArchivePackRefV7[] };
declare function archiveHashV7(input:ArchiveHashInputV7): string;
```

## Cross-language vector and ownership

For a one-pack codec vector with archive/prepared/pack UUIDs `...0001`, `...0002`, and `...0003`, every count
string `"0"` except `declaredPackCount="1"`, `packs=[{packID:"...0003",packIndex:"0",manifestPath:"manifest/packs/0000.json",
manifestHash:"0" repeated 64,manifestByteCount:"0",manifestChunkCount:"0",packHash:"1" repeated 64,
declaredFileCount:"0",declaredChunkCount:"0",declaredByteCount:"0"}]`, and empty strings for protection,
representation and retention, the exact canonical JSON is the 1,127-byte string below and the exact archive hash
is `c8271914d26f7650f76616eb4bfda4f708761eccf31a1bbf1069365b4de3434e`. A production archive cannot use
zero-byte packs; this vector checks codec parity only. P01 owns canonical/hash functions and cross-language contract
fixtures; P18 calls them and binds the result through R12-02. No worker may copy the R11 `{...}` placeholder.

```text
{"archiveID":"00000000-0000-0000-0000-000000000001","declaredByteCount":"0","declaredChunkCount":"0","declaredFileCount":"0","declaredPackCount":"1","frameKinds":{"archiveFooter":7,"archiveHeader":1,"chunk":4,"fileFooter":5,"fileHeader":3,"packFooter":6,"packHeader":2},"manifestByteCount":"0","manifestCarrierKinds":{"archiveChunk":5,"archiveFooter":6,"archiveHeader":4,"packChunk":2,"packFooter":3,"packHeader":1},"manifestChunkCount":"0","manifestPath":"manifest/archive-index.json","manifestRootHash":"0000000000000000000000000000000000000000000000000000000000000000","packs":[{"declaredByteCount":"0","declaredChunkCount":"0","declaredFileCount":"0","manifestByteCount":"0","manifestChunkCount":"0","manifestHash":"0000000000000000000000000000000000000000000000000000000000000000","manifestPath":"manifest/packs/0000.json","packHash":"1111111111111111111111111111111111111111111111111111111111111111","packID":"00000000-0000-0000-0000-000000000003","packIndex":"0"}],"preparedArtifactID":"00000000-0000-0000-0000-000000000002","protection":"","representation":"","retention":"","schemaVersion":7,"tag":"lifeos.archive.v7"}
```
