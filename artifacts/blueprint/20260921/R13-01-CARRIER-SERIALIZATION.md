# Revision 13 exact manifest-carrier serialization

Planning-only. R13-01 supersedes the R12 carrier-byte ambiguity. The six manifest carrier kinds are a closed
wire family; every implementation must accept the same bytes and reject the same invalid input.

## Outer frame and common metadata

```swift
public enum LifeOSManifestCarrierKindV7: UInt8, Codable, Sendable {
 case packHeader = 0x01, packChunk = 0x02, packFooter = 0x03
 case archiveHeader = 0x04, archiveChunk = 0x05, archiveFooter = 0x06
}
public struct LifeOSManifestCarrierMetadataV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String
 public let packIndex: String?; public let chunkIndex: String?; public let payloadEncoding: String
}
public struct LifeOSManifestCarrierFrameV7: Sendable {
 public let kind: LifeOSManifestCarrierKindV7; public let relativePath: String
 public let metadata: Data; public let payload: Data
}
```

The exact bytes are `UTF8("LIFEMNF") + UInt16BE(7) + kind.rawValue + UInt16BE(pathLen) + UInt32BE(metaLen) +
UInt32BE(payloadLen) + path + metadata + payload + SHA256(Frame("LifeOS/manifest-carrier/v7",
kind.rawValue+path+metadata+payload))`. `Frame(domain,payload)` is `UTF8(domain)+0x00+UInt32BE(payload.count)+payload`.
The length fields cover only their following byte region; all integers are big-endian. Maximums are
`pathLen=128`, `metaLen=8,192`, header/footer `payloadLen=65,536`, chunk `payloadLen=1,048,576`, and complete
frame bytes `<=1,056,948`. Lengths are checked before allocation or JSON decoding.

`metadata` is canonical UTF-8 JSON with exactly the keys `chunkIndex,packIndex,payloadEncoding,schemaVersion,tag`.
It always has `schemaVersion=7`, `tag="lifeos.manifest-carrier.v7"`, and `payloadEncoding="canonical-json"`.
For `packHeader|packChunk|packFooter`, `packIndex` is a required decimal string in `0...25`; for archive kinds it
is JSON `null`. For `packChunk|archiveChunk`, `chunkIndex` is a required decimal string in `0...255`; for headers
and footers it is JSON `null`. No other JSON null is permitted. The outer path is NFC UTF-8 and is exactly
`manifest/packs/%04d.json` for pack kinds or `manifest/archive-index.json` for archive kinds.

## Six payload objects

All payloads are canonical JSON objects with no omitted or extra keys. `schemaVersion` and the present `carrierKind`
field are JSON numbers; UUIDs, hashes, paths and tags are strings; every other UInt16/32/64 is a decimal JSON string. Payload
`packIndex`/`chunkIndex` copies the non-null metadata value and must compare equal; archive payloads have no pack index.

```swift
public struct LifeOSPackManifestHeaderPayloadV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let packID: UUID; public let packIndex: UInt16
 public let storeID: String; public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32
 public let declaredByteCount: UInt64
}
public struct LifeOSPackManifestChunkPayloadV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let packID: UUID
 public let packIndex: UInt16; public let chunkIndex: UInt32; public let firstFileIndex: UInt32
 public let files: [LifeOSFileManifestV6]
}
public struct LifeOSPackManifestFooterPayloadV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let carrierKind: UInt8
 public let packID: UUID; public let packIndex: UInt16; public let manifestPath: String
 public let manifestHash: String; public let manifestByteCount: UInt64; public let manifestChunkCount: UInt32
 public let packHash: String; public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32
 public let declaredByteCount: UInt64
}
public struct LifeOSArchiveIndexHeaderPayloadV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let archiveID: UUID
 public let preparedArtifactID: UUID; public let protection: String; public let representation: String
 public let retention: String; public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
}
public struct LifeOSArchiveIndexChunkPayloadV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let archiveID: UUID
 public let chunkIndex: UInt32; public let firstPackIndex: UInt16; public let packs: [LifeOSPackManifestRefV7]
}
public struct LifeOSArchiveIndexFooterPayloadV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let carrierKind: UInt8
 public let archiveID: UUID; public let preparedArtifactID: UUID; public let manifestPath: String
 public let manifestRootHash: String; public let manifestByteCount: UInt64; public let manifestChunkCount: UInt32
 public let declaredPackCount: UInt16; public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32
 public let declaredByteCount: UInt64
}
```

The transport equivalents are concrete, not generic maps:

```python
from typing import TypedDict

class CarrierMetadataV7(TypedDict):
    schemaVersion: int; tag: str; packIndex: str | None; chunkIndex: str | None; payloadEncoding: str
class PackHeaderPayloadV7(TypedDict):
    schemaVersion: int; tag: str; packID: str; packIndex: str; storeID: str
    declaredFileCount: str; declaredChunkCount: str; declaredByteCount: str
class PackChunkPayloadV7(TypedDict):
    schemaVersion: int; tag: str; packID: str; packIndex: str; chunkIndex: str; firstFileIndex: str
    files: list[dict]
class PackFooterPayloadV7(TypedDict):
    schemaVersion: int; tag: str; carrierKind: int; packID: str; packIndex: str; manifestPath: str
    manifestHash: str; manifestByteCount: str; manifestChunkCount: str; packHash: str
    declaredFileCount: str; declaredChunkCount: str; declaredByteCount: str
class ArchiveHeaderPayloadV7(TypedDict):
    schemaVersion: int; tag: str; archiveID: str; preparedArtifactID: str; protection: str
    representation: str; retention: str; declaredPackCount: str; declaredFileCount: str
    declaredChunkCount: str; declaredByteCount: str
class ArchiveChunkPayloadV7(TypedDict):
    schemaVersion: int; tag: str; archiveID: str; chunkIndex: str; firstPackIndex: str; packs: list[dict]
class ArchiveFooterPayloadV7(TypedDict):
    schemaVersion: int; tag: str; carrierKind: int; archiveID: str; preparedArtifactID: str
    manifestPath: str; manifestRootHash: str; manifestByteCount: str; manifestChunkCount: str
    declaredPackCount: str; declaredFileCount: str; declaredChunkCount: str; declaredByteCount: str
```

TypeScript declares the same six interfaces, with `number` replacing Python `int`, `string` replacing `str`,
`null` replacing `None`, and `CarrierPayloadV7` as a `kind`-discriminated union. `CarrierFrameV7` is
`{kind:1|2|3|4|5|6; relativePath:string; metadata:CarrierMetadataV7; payload:CarrierPayloadV7}`. The Python
`files/packs` members use the existing exact `LifeOSFileManifestV6`/`LifeOSPackManifestRefV7` shapes; neither
implementation may replace the union with `dict[str,Any]`, `Record<string,unknown>` or an unvalidated JSON tree.

The payload tags are respectively `lifeos.pack-manifest.v7`, `lifeos.pack-manifest-chunk.v7`,
`lifeos.pack-manifest-footer.v7`, `lifeos.archive-index.v7`, `lifeos.archive-index-chunk.v7`, and
`lifeos.archive-index-footer.v7`; `carrierKind` is `0x03` or `0x06`. Pack chunks contain 1...4,096 files and
archive chunks contain 1...26 refs; `firstFileIndex`/`firstPackIndex` and arrays must be contiguous and ordered.
Manifest byte count is <=256 MiB and manifest chunk count is 1...256. The R12 `LifeOSPackFooterReferenceV7` and
`LifeOSArchiveFooterReferenceV7` remain archive-data-frame payloads; they are not these six carrier payloads.

## Cross-language codec and validation

Swift exposes `LifeOSManifestCarrierCodecV7.encode(_:) throws -> Data`, `decode(_:) throws ->
LifeOSManifestCarrierFrameV7`, and `validate(_:) throws`. Python exposes
`encode_manifest_carrier_v7(frame: CarrierFrameV7) -> bytes` and `decode_manifest_carrier_v7(data: bytes) ->
CarrierFrameV7`; TypeScript exposes `encodeManifestCarrierV7(frame: CarrierFrameV7): Uint8Array` and
`decodeManifestCarrierV7(data: Uint8Array): CarrierFrameV7`. Each uses the same recursively UTF-8-key-sorted,
NFC, no-whitespace canonical JSON, decimal-string integer adapters and raw-byte digest above. Each decoder calls
the same `validate` sequence and maps failures to the closed error names below; a loose dictionary is not an accepted API.

Decode order is magic/version/kind, length bounds, path and expected path, metadata canonicality/nullability,
payload canonicality/tag/key set, identity/count/index bounds, digest, then stream-order validation. The closed
errors are `badMagic`, `unsupportedVersion`, `unknownKind(UInt8)`, `badLength`, `invalidPath`, `nonCanonicalJSON`,
`invalidMetadata`, `invalidPayload`, `invalidNullability`, `identityMismatch`, `countMismatch`, `outOfOrder`,
`duplicate`, `digestMismatch`, `capacity`, `cancelled`, and `diskFull`. Unknown keys, duplicate JSON keys, numeric
counts, base64 payloads, wrong nulls or a hash mismatch fail before projection.

P01 owns these bytes/codecs in `ios/Sync/SyncWireCodec.swift`; P18 calls them from
`ios/Shared/LifeOSDataArchiveWriter.swift`. No carrier serializer, payload key set or hash implementation may be
added elsewhere.
