# R8 data-management streaming contract

Planning-only. R8 replaces `exportPack(...) -> LifeOSDataPackV2` as an implementation interface. The R7 26-pack
manifest remains the wire/archive shape, but export never materializes a domain file, pack or archive in memory.

## Source, frame and sink interfaces

```swift
public struct LifeOSDataExportCursor: Codable, Sendable {
 public let packIndex: UInt16; public let fileIndex: UInt32; public let chunkIndex: UInt32
}
public enum LifeOSArchiveFrameKind: String, Codable, Sendable { case archiveHeader, packHeader, fileChunk, fileFooter, packFooter, archiveFooter }
public struct LifeOSArchiveFrameV4: Sendable {
 public let kind: LifeOSArchiveFrameKind; public let packID: LifeOSDataStoreID?; public let fileIndex: UInt32?
 public let chunkIndex: UInt32?; public let relativePath: String?; public let byteCount: UInt32
 public let sha256: String; public let payload: Data?
}
public protocol LifeOSDataExportSource: Sendable {
 var storeID: LifeOSDataStoreID { get }
 func streamPack(options: LifeOSDataExportOptions, from cursor: LifeOSDataExportCursor?)
   -> AsyncThrowingStream<LifeOSArchiveFrameV4, Error>
}
public protocol LifeOSDataStoreAdapter: LifeOSDataExportSource, Sendable {
 func restorePack(_ pack: LifeOSDataPackV2, from archiveURL: URL, options: LifeOSDataRestoreOptions) async throws
 func deletePack() async throws
}
public protocol LifeOSArchiveSink: Sendable {
 func begin(_ frame: LifeOSArchiveFrameV4) async throws
 func append(_ frame: LifeOSArchiveFrameV4) async throws
 func finishFile(_ frame: LifeOSArchiveFrameV4) async throws
 func finishPack(_ frame: LifeOSArchiveFrameV4) async throws
 func finalize(_ frame: LifeOSArchiveFrameV4) async throws
 func abort() async throws
}
public actor LifeOSDataArchiveWriter {
 public func export(sources: [any LifeOSDataExportSource], sink: any LifeOSArchiveSink,
   options: LifeOSDataExportOptions, resume: LifeOSDataReceiptV4?) async throws -> LifeOSDataReceiptV4
}
public actor LifeOSDataManagement {
 public func export(to destination: URL, options: LifeOSDataExportOptions) async throws -> LifeOSDataReceiptV4
 public func restore(from archiveURL: URL, options: LifeOSDataRestoreOptions) async throws -> LifeOSDataReceiptV4
 public func deleteUserData() async throws -> LifeOSDataReceiptV4
}
```

The sink accepts `archiveHeader` in `begin`, `packHeader` in `begin` after the archive header, only `fileChunk` in
`append`, `fileFooter` in `finishFile`, `packFooter` in `finishPack`, and `archiveFooter` in `finalize`; any other
ordering is `invalidFrameOrder`. The source and sink are actor-isolated by their implementations; the writer never uses
`Task.detached` for UI work and bounds concurrent streams to one pack and one file chunk.

`LifeOSDataStoreAdapter` for each R7 registry row exposes `streamPack`; the adapter reads at most one 1 MiB chunk from
its existing file/Keychain/UserDefaults/gateway source and yields a header, contiguous chunks, footer, then pack footer.
`payload` is nonnil only for `fileChunk`, `payload.count == byteCount <=1 MiB`, and every other frame has nil payload.
Files are bounded by the R7 limits (16 MiB original nutrition photo, 4 MiB other file, 4,096 files, 256 MiB total).
Header/footer metadata is <=32 KiB and contains the declared path, file byte count, final hash and chunk count. The writer
rejects a wrong store order, path, index, size, hash, duplicate chunk or frame kind before writing it.

The exact 26 order is the R7 enum order: `calendar, financeImports, financeRecurring, financeInvestments,
financeBudgets, financeAllocations, financePreferences, financeTravel, training, trainingTemplates, meals,
nutritionGoals, supplements, journal, lifestyle, barcodeRecords, planningJournal, planningFiles, taxSanitized, taxRaw,
usageLocal, clipperLocal, replicationTrust, widgetSnapshot, nutritionPhotoOriginals, recoveryImports`.
P18 owns `LifeOSDataArchiveWriter`, `LifeOSArchiveSink` and receipt cursor handling; P03/P04/P06/P09/P10/P12/P13/P14/P17
own source adapters for their registry rows. P18 never reads a domain model to create a second serialization.

## On-disk frame and finalization rules

`LifeOSFileArchiveSink` creates `<archiveID>.lifeosarchive.partial` on the destination's local volume with mode 0700.
It writes each file to `blobs/<sha256>.chunk.partial` using exclusive/no-follow open, appends bounded payloads, checks the
incremental SHA-256 and byte count at the footer, calls `fsync(file)`, atomically renames the blob, and fsyncs the blobs
directory. It writes each `packs/<storeID>.json.partial`, fsyncs it, renames it, then fsyncs `packs`. It writes the
canonical R7 manifest last, fsyncs it and the root directory, and atomically renames the partial archive to its final
name. Only then does `LifeOSReceiptCoordinator` append `committed`.

The manifest contains metadata/chunk references, never chunk bytes. `archiveHash` and `packHash` are computed from the
canonical manifest/pack bytes plus sorted raw chunk hashes exactly as R7-05 specifies. No `Data`, `Data(contentsOf:)`,
decoded JSON tree, or `[UInt8]` may contain more than one frame payload; a file is never decoded to memory.

## Resume, cancellation and failures

The receipt cursor `(packIndex,fileIndex,chunkIndex)` is advanced only after a blob/footer fsync and a durable receipt
transition. On resume, the sink verifies an existing matching blob hash/size and skips it; a partial or mismatched blob is
deleted only after the receipt points before it, then recreated. A source starts from the cursor and may reread one
bounded chunk. Cancellation stops after the current frame, calls `abort` without deleting a committed archive, and writes
`interrupted`; disk-full writes `diskFull` if possible, preserves the last valid cursor and partial files, and never emits
`committed`. A gateway outage for Windows-local packs yields `gatewayUnavailable` and an incomplete receipt; an empty
substitute is forbidden. `abort` is idempotent and does not follow symlinks.

`LifeOSDataManagement.export` calls `ReceiptCoordinator.prepare` → writer frame loop → sink finalization → receipt
commit. Restore consumes the same manifest through its existing bounded pack reader; this sheet changes export only and
does not authorize a second data-management store. P18 acceptance evidence includes a 256 MiB bound, cancellation at
each frame boundary, crash after every fsync/rename, disk-full, gateway outage and a proof that peak source payload is
<=1 MiB.

## Revision9 supersession

R9-03 is authoritative. It replaces the ambiguous whole-file digest with a chunk-derived digest, typed header/file/
footer frames, a bounded awaitable sink, and explicit 4 MiB ordinary versus 32 MiB domain-envelope outcomes.
