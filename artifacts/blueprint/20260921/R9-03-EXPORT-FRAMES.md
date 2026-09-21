# R9 typed export frames, chunking and backpressure

Planning-only. This sheet supersedes R8-06 and the conflicting whole-file-hash wording in R7-05. P18 owns the
writer/sink and receipt cursor; each domain packet owns its bounded source projection. P01 owns canonical JSON and
hash framing. No JavaScript runtime or second archive format is introduced.

## Typed values and wire frame

```swift
public enum LifeOSArchiveFileClassV5: String, Codable, Sendable { case ordinary, domainEnvelope }
public enum LifeOSArchiveProtectionV5: String, Codable, Sendable { case completeFile, afterFirstUnlock, none }
public enum LifeOSArchiveRepresentationV5: String, Codable, Sendable { case canonicalJSON, opaqueBytes }
public enum LifeOSArchiveRetentionV5: String, Codable, Sendable { case syncAllowed, deviceOnly, deleteAfterImport }
public struct LifeOSArchiveHeaderV5: Codable, Sendable {
 public let schemaVersion: Int; public let archiveID: UUID; public let receiptID: UUID; public let preparedArtifactID: UUID
 public let protection: LifeOSArchiveProtectionV5; public let representation: LifeOSArchiveRepresentationV5
 public let retention: LifeOSArchiveRetentionV5; public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64; public let createdAt: Date
}
public struct LifeOSArchivePackHeaderV5: Codable, Sendable {
 public let packID: UUID; public let packIndex: UInt16; public let storeID: String
 public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
}
public struct LifeOSArchiveFileHeaderV5: Codable, Sendable {
 public let fileID: UUID; public let relativePath: String; public let fileClass: LifeOSArchiveFileClassV5
 public let protection: LifeOSArchiveProtectionV5; public let representation: LifeOSArchiveRepresentationV5
 public let retention: LifeOSArchiveRetentionV5; public let declaredByteCount: UInt64; public let declaredChunkCount: UInt32
}
public struct LifeOSArchiveChunkV5: Sendable {
 public let fileID: UUID; public let chunkIndex: UInt32; public let offset: UInt64; public let bytes: Data
 public let chunkHash: String
}
public struct LifeOSArchiveFileFooterV5: Codable, Sendable {
 public let fileID: UUID; public let actualByteCount: UInt64; public let actualChunkCount: UInt32; public let fileDigest: String
}
public struct LifeOSArchivePackFooterV5: Codable, Sendable {
 public let packID: UUID; public let actualFileCount: UInt32; public let actualChunkCount: UInt32
 public let actualByteCount: UInt64; public let packHash: String
}
public struct LifeOSArchiveFooterV5: Codable, Sendable {
 public let archiveID: UUID; public let actualPackCount: UInt16; public let actualFileCount: UInt32
 public let actualChunkCount: UInt32; public let actualByteCount: UInt64; public let archiveHash: String
}
public enum LifeOSArchiveFrameV5: Sendable {
 case archiveHeader(LifeOSArchiveHeaderV5), packHeader(LifeOSArchivePackHeaderV5)
 case fileHeader(LifeOSArchiveFileHeaderV5), chunk(LifeOSArchiveChunkV5)
 case fileFooter(LifeOSArchiveFileFooterV5), packFooter(LifeOSArchivePackFooterV5)
 case archiveFooter(LifeOSArchiveFooterV5)
}
public struct LifeOSDataExportOptionsV5: Sendable {
 public let includeProtectedLocalAssets: Bool; public let destinationIsLocal: Bool
 public let maxArchiveBytes: UInt64; public let ordinaryFileLimit: UInt64; public let domainEnvelopeLimit: UInt64
}
public enum LifeOSExportCapacityErrorV5: Error, Sendable {
 case ordinaryFileTooLarge(UInt64), domainEnvelopeTooLarge(UInt64), archiveTooLarge(UInt64)
 case chunkTooLarge, frameTooLarge, backpressureExceeded, diskFull, cancelled
}
```

The stream is a sequence of tagged frames: `archiveHeader`, `packHeader`, `fileHeader`, `chunk`, `fileFooter`,
`packFooter`, `archiveFooter`. The byte framing is exactly
`UTF8("LIFEOSAR") + UInt16BE(5) + UInt8(kind) + UInt32BE(metadataLength) + UInt32BE(payloadLength) + metadata +
payload + SHA256(Frame("LifeOS/archive-frame/v5",kindByte+metadata+payload))`. Metadata is canonical JSON with
sorted keys, UTC millisecond dates and no whitespace. Header/footer payload is empty; a chunk payload is raw bytes.
`metadataLength <= 32 KiB`; `payloadLength <= 1 MiB`; the frame hash is 32 raw bytes encoded as lower-case hex only
inside JSON receipts. Unknown kinds, trailing bytes, duplicate footer or mismatched lengths are rejected before
allocation.

`chunkHash=hex(SHA256(bytes))`. There is deliberately no independent raw whole-file hash. The exact file digest is
`hex(SHA256(Frame("LifeOS/file-digest/v5",CanonicalJSON({fileID,declaredByteCount,orderedChunkHashes}))))`;
`packHash` is the same construction with label `LifeOS/pack-digest/v5` and ordered `(fileID,fileDigest)` entries;
`archiveHash` uses `LifeOS/archive-digest/v5` and ordered `(packID,packHash)` entries plus declared counts. Thus the
final artifact hash is reproducible from individually hashed chunks without a whole-file/chunk mismatch.

`LifeOSDataExportOptionsV5` is accepted only when `destinationIsLocal` is true,
`maxArchiveBytes <= 256*1024*1024`, `ordinaryFileLimit == 4*1024*1024` and
`domainEnvelopeLimit == 32*1024*1024`; a caller cannot raise a hard limit. `includeProtectedLocalAssets` changes
retention/protection metadata and never changes these byte bounds.

## Source, sink and finalization

```swift
public enum LifeOSArchiveWriteOutcome: Sendable { case accepted, finalized }
public protocol LifeOSArchiveFrameSink: Sendable {
 func accept(_ frame: LifeOSArchiveFrameV5) async throws -> LifeOSArchiveWriteOutcome
 func abort() async
}
public enum LifeOSArchiveFrameCodec {
 public static func encode(_ frame: LifeOSArchiveFrameV5) throws -> Data
 public static func decode(_ bytes: Data, limit: Int) throws -> LifeOSArchiveFrameV5
}
public protocol LifeOSDataExportSource: Sendable {
 var storeID: String { get }
 func describePack(options: LifeOSDataExportOptionsV5) async throws -> LifeOSArchivePackHeaderV5
 func producePack(options: LifeOSDataExportOptionsV5, from: LifeOSReceiptCursorV5,
   to sink: any LifeOSArchiveFrameSink) async throws
}
public struct LifeOSDataArchiveWriter: Sendable {
 public func export(sources: [any LifeOSDataExportSource], sink: any LifeOSArchiveFrameSink,
   options: LifeOSDataExportOptionsV5, resume: LifeOSDataReceiptV5?) async throws -> LifeOSDataReceiptV5
}
```

`LifeOSArchiveFrameV5` is an explicit Swift tagged enum over the seven structs above; its Codable representation is
`{"tag":...,"metadata":...,"bytesBase64":...}` only for tests, never for the streaming wire. Sources first
`describePack` all 26 registry entries using bounded `stat`/metadata reads, so declared counts are known without
loading file contents. Writer order is fixed registry order, then sorted relative path. A source calls `accept` and
awaits it before producing the next frame; the sink has capacity for exactly two frames and 2 MiB total. The writer
requires exactly 26 unique `storeID` values in registry order. It never
drops or replaces a frame. A cancelled waiter throws `cancelled`; an implementation that attempts to exceed the
capacity throws `backpressureExceeded` and leaves the last cursor durable.

For each chunk the sink opens `blobs/<chunkHash>.partial` with exclusive/no-follow flags, writes bytes, fsyncs,
atomically renames to `blobs/<chunkHash>`, and records the hash once. Receiving `fileFooter` fsyncs the ordered chunk
manifest and atomically replaces the pack manifest entry; receiving `packFooter` fsyncs the pack manifest; receiving
`archiveFooter` fsyncs the archive manifest and atomically renames the archive directory. The writer then binds the
final `archiveHash` to the R9 receipt. There is no raw file temp or whole-file digest to get out of sync. Crash recovery ignores unreferenced partial blobs and resumes at the receipt's next
`packIndex,fileIndex,chunkIndex`.

## Capacity and failure outcomes

`LifeOSExportCapacityErrorV5` has `ordinaryFileTooLarge(bytes,limit:4MiB)`, `domainEnvelopeTooLarge(bytes,limit:32MiB)`,
`archiveTooLarge(bytes,limit:256MiB)`, `chunkTooLarge`, `frameTooLarge`, `backpressureExceeded`, `diskFull` and
`cancelled`. An ordinary file over 4 MiB is rejected before its `fileHeader`; it is never silently split into a larger
ordinary object. A domain envelope may be streamed in <=1 MiB chunks up to 32 MiB; above that it is rejected before
emitting its header. An envelope over 32 MiB is also rejected by the sync decoder, so no schema-valid undecodable
state exists. A limit failure leaves the prior receipt cursor and deletes only unreferenced partial metadata.

## Revision10 supersession

R10-04 is final for receipt progress cadence; R10-05 is final for numeric frame kinds and identity-
bearing archive digest/manifest verification.
