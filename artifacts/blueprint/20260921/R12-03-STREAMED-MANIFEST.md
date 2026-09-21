# R12 streamed V7 manifest carrier and verifier

Planning-only. This sheet supersedes the materialized-manifest assumption in R11-07. Pack and archive manifests
are streamed after all pack footers and are never required as one in-memory `Data` value.

R14-02 remains final for manifest authority and root-hash semantics. R15-03 is now final for canonical ordering,
carrier partition limits and empty-array reconstruction; R15-02 is final for the unified emission cursor. The
streaming interfaces below remain usable only with those current meanings.

## Carrier framing and paths

```swift
public enum LifeOSManifestCarrierKindV7: UInt8, Codable, Sendable {
 case packHeader = 0x01, packChunk = 0x02, packFooter = 0x03
 case archiveHeader = 0x04, archiveChunk = 0x05, archiveFooter = 0x06
}
public struct LifeOSManifestCarrierFrameV7: Sendable {
 public let kind: LifeOSManifestCarrierKindV7; public let relativePath: String
 public let packIndex: UInt16?; public let chunkIndex: UInt32?
 public let metadata: Data; public let payload: Data
}
public enum LifeOSArchiveRecordV7: Sendable {
 case archive(LifeOSArchiveFrameV6); case manifest(LifeOSManifestCarrierFrameV7)
}
public struct LifeOSPackManifestBodyV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let packID: UUID; public let packIndex: UInt16
 public let storeID: String; public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32
 public let declaredByteCount: UInt64; public let files: [LifeOSFileManifestV6]
}
public struct LifeOSPackManifestRefV7: Codable, Sendable {
 public let packID: UUID; public let packIndex: UInt16; public let manifestPath: String
 public let manifestHash: String; public let manifestByteCount: UInt64; public let manifestChunkCount: UInt32
 public let packHash: String; public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32
 public let declaredByteCount: UInt64
}
public struct LifeOSPackFooterReferenceV7: Codable, Sendable {
 public let frameKind: UInt8; public let packID: UUID; public let packIndex: UInt16
 public let manifestRelativePath: String; public let manifestHash: String; public let manifestByteCount: UInt64
 public let manifestChunkCount: UInt32; public let packHash: String; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
}
public struct LifeOSArchiveIndexV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let archiveID: UUID
 public let preparedArtifactID: UUID; public let protection: String; public let representation: String
 public let retention: String; public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64; public let packs: [LifeOSPackManifestRefV7]
}
public struct LifeOSManifestRootV7: Codable, Sendable {
 public let relativePath: String; public let hash: String; public let byteCount: UInt64; public let chunkCount: UInt32
}
public struct LifeOSArchiveFooterReferenceV7: Codable, Sendable {
 public let frameKind: UInt8; public let archiveID: UUID; public let preparedArtifactID: UUID
 public let manifestRelativePath: String; public let manifestRootHash: String; public let manifestByteCount: UInt64
 public let manifestChunkCount: UInt32; public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64; public let archiveHash: String
}
public struct LifeOSPackManifestHeaderV7: Codable, Sendable {
 public let schemaVersion: UInt16; public let tag: String; public let packID: UUID; public let packIndex: UInt16
 public let storeID: String; public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32
 public let declaredByteCount: UInt64
}
public struct LifeOSArchiveVerificationV7: Sendable {
 public let archiveID: UUID; public let manifestRootHash: String; public let archiveHash: String
 public let declaredPackCount: UInt16; public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32
 public let declaredByteCount: UInt64
}
```

The carrier bytes are `UTF8("LIFEMNF") + UInt16BE(7) + UInt8(kind) + UInt16BE(pathLen) + UInt32BE(metaLen) +
UInt32BE(payloadLen) + path + metadata + payload + SHA256(Frame("LifeOS/manifest-carrier/v7", kind+path+
metadata+payload))`. `pathLen<=128`, `metaLen<=8 KiB`, chunk `payloadLen<=1 MiB`, and header/footer
`payloadLen<=64 KiB`; unknown kinds, paths, lengths and nonmatching hashes fail before allocation.

Paths are fixed and NFC: `manifest/packs/0000.json` through `manifest/packs/0025.json`, then
`manifest/archive-index.json`. Carrier order is all archive data frames and pack footers, pack manifest
header/chunks/footer in ascending pack index, then archive-index header/chunks/footer, then the archive frame
`archiveFooter` (0x07). A 0x06 pack-footer payload is `CanonicalJSON(LifeOSPackFooterReferenceV7)` and the
final 0x07 payload is `CanonicalJSON(LifeOSArchiveFooterReferenceV7)`; both are checked against the streamed
manifest. `manifestRelativePath` maps byte-for-byte to the corresponding index `manifestPath`, and
`manifestRootHash` maps to `LifeOSManifestRootV7.hash`; `frameKind` is exactly `0x06` or `0x07` respectively.
The archive footer references the final archive-index hash and counts.

## Sink/source interfaces

```swift
public protocol LifeOSArchiveSinkV7: Sendable {
 func append(_ record: LifeOSArchiveRecordV7) async throws
}
public protocol LifeOSManifestFileStoreV7: Sendable {
 func replace(_ relativePath: String, chunks: AsyncThrowingStream<Data, Error>) async throws -> LifeOSManifestRootV7
 func source(_ relativePath: String, fromChunk: UInt32) -> AsyncThrowingStream<Data, Error>
}
```

```swift
public actor LifeOSManifestStreamWriterV7 {
 public init(sink: any LifeOSArchiveSinkV7, files: any LifeOSManifestFileStoreV7)
 public func beginPack(_ header: LifeOSPackManifestHeaderV7) async throws
 public func appendPackFile(_ packIndex: UInt16, file: LifeOSFileManifestV6) async throws
 public func finishPack(_ packIndex: UInt16) async throws -> LifeOSPackManifestRefV7
 public func beginArchiveIndex(_ index: LifeOSArchiveIndexV7) async throws
 public func finishArchiveIndex() async throws -> LifeOSManifestRootV7
}
public protocol LifeOSManifestSourceV7: Sendable {
 func packManifest(_ packIndex: UInt16, fromChunk: UInt32) -> AsyncThrowingStream<LifeOSManifestCarrierFrameV7, Error>
 func archiveIndex(fromChunk: UInt32) -> AsyncThrowingStream<LifeOSManifestCarrierFrameV7, Error>
}
public struct LifeOSArchiveStreamVerifierV7: Sendable {
 public static func verify(_ records: AsyncThrowingStream<LifeOSArchiveRecordV7, Error>)
   async throws -> LifeOSArchiveVerificationV7
}
```

The writer validates declared counts before `begin`, incrementally encodes each header/file/index value into
canonical JSON, flushes at most 1 MiB per carrier chunk, and computes byte/chunk/hash values itself; callers cannot
claim a hash. `append` is the backpressure boundary: the writer awaits it before advancing a cursor. It writes each
carrier frame through the bounded archive sink, fsyncs each completed manifest path, and returns only after its
footer hash is durable. The source yields frames
from the archive directory or transport stream; it may reopen and resume from `(path,chunkIndex)`. The verifier
consumes records incrementally, spools only bounded observed file digests, compares each pack manifest as it arrives,
then compares the archive index and footer. It never calls `Data(contentsOf:)` for a complete manifest or constructs
the old `[LifeOSPackManifestV6]` archive body. P18 owns the stream writer/source/verifier; P01 owns carrier bytes.

R13-01 is final for all six carrier payload fields and byte decoding; R13-02 is final for the stage/finalize/emit
call order and sink durability. R14-02 makes the two canonical JSON object paths the sole representation and treats
all carrier records as a derived transport projection. R12 remains the historical framing baseline.
