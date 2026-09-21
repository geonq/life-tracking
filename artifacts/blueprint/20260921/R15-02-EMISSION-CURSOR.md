# Revision 15 unified emission cursor

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R15-02 supersedes R14's receipt cursor and R13's separate data/carrier progress interpretation. One
global next-frame cursor covers the data prefix, manifest carriers and final data footer.

## Closed pass and frame order

```swift
public enum LifeOSEmissionPassV7: UInt8, Codable, Sendable {
  case dataPrefix = 10, manifestCarriers = 20, dataSuffix = 30, done = 40
}
public enum LifeOSEmissionFrameKindV7: UInt8, Codable, Sendable {
  case archiveHeader = 1, dataPackHeader = 2, dataFileHeader = 3, dataFileChunk = 4
  case dataFileFooter = 5, dataPackFooter = 6, manifestPackHeader = 7, manifestPackChunk = 8
  case manifestPackFooter = 9, manifestArchiveHeader = 10, manifestArchiveChunk = 11
  case manifestArchiveFooter = 12, archiveFooter = 13
}
public struct LifeOSEmissionCursorV7: Codable, Sendable {
  public let phase: LifeOSReceiptPhaseV7; public let pass: LifeOSEmissionPassV7
  public let frameKind: LifeOSEmissionFrameKindV7; public let frameOrdinal: UInt64
  public let packIndex: UInt16?; public let chunkIndex: UInt32?; public let relativePath: String?
  public let planHash: String; public let artifactFileHash: String?; public let archiveHash: String?
}
public typealias LifeOSReceiptCursorV7 = LifeOSEmissionCursorV7
```

`frameOrdinal` is the next frame to append, starts at decimal `0`, and is never reset at a pass boundary. The
initial cursor is `dataPrefix/archiveHeader/0/packIndex=null/chunkIndex=null`; after its sync it advances to
`dataPackHeader/1/packIndex=0` when `packCount>0`, or directly to
`manifestCarriers/manifestArchiveHeader/1/packIndex=null` when `packCount=0`. A pack-specific frame always has a
non-null index in `0...(packCount-1)`; an archive-level frame always has `packIndex=null`. `chunkIndex` is non-null
only for `dataFileChunk`, `manifestPackChunk` or `manifestArchiveChunk`, starts at 0 within that sequence, and is
never used as a pack index. `relativePath` is required for file and manifest object frames and null for archive
header/footer frames. `done` has `frameKind=archiveFooter`, `frameOrdinal=totalFrameCount`, and all optional
location fields null.

Within `dataPrefix`, each pack emits `dataPackHeader`, ordered file headers/chunks/footers, then `dataPackFooter`.
Pack indexes increase only after the footer is durable. Within `manifestCarriers`, each pack emits
`manifestPackHeader`, its contiguous partition chunks and `manifestPackFooter`, then the archive index emits
`manifestArchiveHeader`, its chunks and `manifestArchiveFooter`. `dataSuffix` emits exactly one final
`archiveFooter`. No frame can move from a later pass to an earlier pass, decrease `frameOrdinal`, skip a declared
pack, or use null as an alias for pack zero.

`relativePath` is null for `archiveHeader`, `dataPackHeader`, `dataPackFooter` and final `archiveFooter`; it is the
data file path for every `dataFile*` frame, `manifest/packs/%04d.json` for every `manifestPack*` frame and
`manifest/archive-index.json` for every `manifestArchive*` frame. `packIndex` is required for every `dataPack*`,
`dataFile*` and `manifestPack*` frame and null for all archive-level frames. `chunkIndex` is required only for the
three chunk kinds listed above. A `done` cursor remains phase `emitting` until sink finalization changes the receipt
phase; it is a next-position marker, not a second footer.

`currentUnit` is the UTF-8 canonical JSON projection with exactly sorted keys
`archiveHash,artifactFileHash,chunkIndex,frameKind,frameOrdinal,packIndex,pass,phase,planHash,relativePath`.
Every key is present; nullable location/hash values are JSON `null`, and unsigned values are decimal strings.
`frameOrdinal=0` is valid only for the initial archive header. A pack index of `0` is valid only for a
pack-specific frame when `packCount>0`; it is never the encoding for a null archive-level index.

## Plan binding and validation

```swift
public struct LifeOSEmissionPlanV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let archiveID: UUID; public let packCount: UInt16
  public let dataFrameCount: UInt64; public let manifestCarrierCount: UInt64
  public let manifestRootHash: String; public let planHash: String
}
public struct LifeOSEmissionAdvanceV7: Sendable {
  public let receiptID: UUID; public let expectedHeadHash: String
  public let nextCursor: LifeOSEmissionCursorV7; public let durableFrameHash: String
}
public func validateEmissionCursorV7(_ cursor: LifeOSEmissionCursorV7,
  plan: LifeOSEmissionPlanV7, previous: LifeOSEmissionCursorV7?) throws
```

`planHash` is
`hex(SHA256(Frame("LifeOS/emission-plan/v7", CanonicalJSON({schemaVersion:7,archiveID,packCount,
dataFrameCount,manifestCarrierCount,manifestRootHash}))))`. `dataFrameCount` includes archive header, every data
pack/file frame and every data pack footer; `manifestCarrierCount` includes all six carrier kinds, including one
empty-array chunk for each empty pack/index sequence. `totalFrameCount=dataFrameCount+manifestCarrierCount+1`.

Validation checks phase=`emitting`, plan hash, global ordinal, legal pass/frame edge, pack-count bounds `0...26`,
required/null fields, contiguous chunk indexes, declared counts and the previous durable frame hash. It compares
the candidate to the previous cursor by `(pass.rawValue,frameOrdinal)` and rejects `backwardCursor`,
`planMismatch`, `invalidPackIndex`, `invalidChunkIndex`, `invalidNullability`, `missingFrame`, `duplicateFrame`,
or `outOfOrder`. The same next cursor and durable frame hash is an idempotent retry.

## Persistence and recovery

`LifeOSReceiptStoreV7.advanceEmission(_:)` validates this cursor, appends one R15-01 transition and atomically
persists the complete domain file. `LifeOSDataArchiveWriter.emitFinalized` calls it only after `sink.append` and
`sink.sync` for the frame represented by the previous cursor. It begins at the recorded next cursor, verifies the
partial sink's last frame hash and ordinal, and resumes without replaying a durable frame. A crash after sink
finalization but before `sinkFinalized` locates the final archive, recomputes `artifactFileHash`, and continues the
R15-01 calls. Cancellation/disk-full leaves the same cursor and phase; it never writes a lower cursor.

The canonical `currentUnit` projection is the UTF-8 canonical JSON of all cursor fields plus `artifactFileHash` and
`archiveHash`, with no omitted keys; the typed cursor and projection must compare equal on reopen. P18 owns the
writer/cursor calls in `ios/Shared/LifeOSDataArchiveWriter.swift` and
`ios/Shared/LifeOSReceiptCoordinator.swift`.

## R16 current authority

R16-01 replaces the persisted cursor field with the tagged V8 cursor and keeps
the R15 global pass/frame order. R16-02 adds the durable sink frame envelope,
tail discovery, adoption/truncation rules and `durableFrameHash` validation.
Workers must follow R16 before changing this historical V7 emission contract.
