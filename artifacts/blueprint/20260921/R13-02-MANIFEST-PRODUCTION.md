# Revision 13 manifest staging, finalization and emission

Planning-only. R13-02 supersedes the R12 assumption that `finishPack` emits a carrier and the R12
`beginArchiveIndex(_:)` input shape. Staging and hashing finish before any archive sink receives a manifest carrier
or a footer.

R14-01 is now final for receipt phases, cursors, durable finalization and recovery; R14-02 is final for the stored
manifest representation and root-hash preimage. This sheet remains authoritative for writer call order and sink
durability only.

## Exact interfaces and durable phases

```swift
public enum LifeOSManifestProductionPhaseV7: String, Codable, Sendable {
 case stagingPack, packFinalized, stagingIndex, manifestFinalized, finalizing
 case emittingData, emittingManifest, emitted, interrupted, failed
}
public struct LifeOSArchiveFinalizationV7: Codable, Sendable {
 public let archiveID: UUID; public let archiveHash: String; public let manifestRootHash: String
 public let packs: [LifeOSPackManifestRefV7]; public let phase: LifeOSManifestProductionPhaseV7
}
public struct LifeOSArchiveSinkCommitV7: Codable, Sendable {
 public let archiveID: UUID; public let archiveHash: String; public let relativePath: String; public let byteCount: UInt64
}
public protocol LifeOSArchiveDataSourceV7: Sendable {
 func frames(from cursor: LifeOSReceiptCursorV6) -> AsyncThrowingStream<LifeOSArchiveFrameV6, Error>
}
public protocol LifeOSArchiveSinkV7: Sendable {
 func append(_ record: LifeOSArchiveRecordV7) async throws
 func sync() async throws
 func finalize() async throws -> LifeOSArchiveSinkCommitV7
}
public actor LifeOSManifestStreamWriterV7 {
 public func beginArchive(_ header: LifeOSArchiveIndexHeaderPayloadV7) async throws
 public func beginPack(_ header: LifeOSPackManifestHeaderPayloadV7) async throws
 public func appendPackFile(_ packIndex: UInt16, file: LifeOSFileManifestV6) async throws
 public func finishPack(_ packIndex: UInt16) async throws -> LifeOSPackManifestRefV7
 public func finishArchiveIndex() async throws -> LifeOSManifestRootV7
 public func finalizeArchive() async throws -> LifeOSArchiveFinalizationV7
 public func emitFinalized(data: any LifeOSArchiveDataSourceV7,
   to sink: any LifeOSArchiveSinkV7) async throws -> LifeOSArchiveSinkCommitV7
}
```

`LifeOSArchiveDataSourceV7.frames` yields only the archive header, pack/file headers, chunks and file footers; it
never yields a pack footer or archive footer. The writer synthesizes those two footer kinds from finalized refs.
`sink.sync()` fsyncs the partial archive and its parent directory. `sink.finalize()` calls `sync`, atomically renames
the fixed `<archiveID>.lifeosarchive.partial` to its final path on the same volume, fsyncs the archive root, and only
then returns `LifeOSArchiveSinkCommitV7`.

The R14-01 V7 receipt phase/cursor and finalization record replace the older V6 checkpoint wording. No production
journal or manifest sidecar is introduced; the V8 receipt authority marker in R14-03 is the only receipt migration
marker.

## Binding call order

1. `beginArchive(header)` validates the closed archive identity and opens the archive receipt in `streaming`.
2. For each pack in index order, call `beginPack`, `appendPackFile` for ordered files, then `finishPack`.
   It writes `manifest/packs/%04d.json.partial`, fsyncs bytes and directory, atomically replaces the final path,
   fsyncs the directory, computes `manifestHash`, and returns the complete `LifeOSPackManifestRefV7`. It emits no
   sink record; the returned ref is the only source for that pack's later footer.
3. After all pack refs exist, call `finishArchiveIndex`. It stages the canonical
   `LifeOSArchiveIndexObjectV7` bytes at `manifest/archive-index.json.partial`, fsyncs and atomically replaces the
   final index, computes `manifestRootHash` from R14-02's object list, and returns `LifeOSManifestRootV7`. It emits
   no sink record; carrier header/chunk/footer records are derived later from the final object bytes.
4. `finalizeArchive` verifies every staged path/ref/count, constructs the exact R12 `LifeOSArchiveHashInputV7`,
   computes `archiveHash`, persists `finalizing` with the root hash and archive hash, and returns
   `LifeOSArchiveFinalizationV7`. No output sink is touched before this method succeeds.
5. `emitFinalized` requires that finalization record and emits: archive header/data frames; each data pack's
   `packFooter` archive frame using its already-finalized manifest and pack hashes; all six manifest carrier
   sequences in pack-index order then archive-index order; and the final `archiveFooter` archive frame using the
   finalized archive hash. It awaits `append` and then `sync` at every bounded cursor boundary. Only after the final
   footer sync does it call `sink.finalize()`. It then calls `LifeOSReceiptStoreV6.finalizeArtifact(_:)` with the
   already persisted archive hash and the sink commit identity, followed by `commitBound(_:expectedArtifactHash:)`;
   only those durable replacements produce `bound` and finally `committed`.

The archive-frame pack footer is emitted only after `finishPack`; the carrier `packFooter` is emitted only after
the same staged pack manifest is readable and verified. The carrier archive footer is emitted only after the index
root and archive hash are fixed. This prevents a footer from claiming a hash or count that was not durable.

## Crash, cancellation and verification order

Before a partial manifest rename, recovery truncates/rebuilds only the unreferenced `.partial` path; an existing
final path is never deleted. After a pack rename but before its receipt cursor, recovery verifies the final path and
replays `finishPack` idempotently. After the index rename, it resumes `finalizeArchive`. During emission, the sink
reopens its fixed partial archive, verifies the last durable frame digest and receipt cursor, then resumes at the
next frame. A crash after `sink.finalize()` but before `committed` finds the final archive by `(archiveID,archiveHash)`
and commits without re-emitting. Cancellation or disk-full preserves the last valid receipt and partial files and
never emits `committed`; `finalize` and recovery are idempotent.

The verifier consumes archive data frames first, validates each finalized pack footer, consumes the six carrier
sequences, compares every path/index/count/hash, then validates the final archive footer and archive hash. It binds
the receipt only after this order succeeds. P18 owns this orchestration in
`ios/Shared/LifeOSDataArchiveWriter.swift`; P01 owns carrier/hash bytes.
