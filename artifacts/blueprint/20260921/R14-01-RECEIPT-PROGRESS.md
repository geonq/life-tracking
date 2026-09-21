# Revision 14 receipt progress and finalization

Planning-only. R14-01 supersedes R13-02's receipt phase/checkpoint paragraph and the R12-02 cursor wording.
R13's writer call order remains, but the receipt has one monotonic state machine and one resumable cursor.

R15-01 is now final for the transition, binding, compaction, finalization-hash and artifact-hash schemas. R15-02 is
final for the unified data/carrier emission cursor. This sheet is historical for those clauses.

## Persisted V7 records

```swift
public enum LifeOSReceiptPhaseV7: UInt8, Codable, Sendable {
  case staging = 10, manifestFinalized = 20, emitting = 30
  case sinkFinalized = 40, bound = 50, committed = 60, failed = 90
}
public enum LifeOSReceiptUnitV7: UInt8, Codable, Sendable {
  case manifestPack = 1, archiveHeader = 2, archivePack = 3
  case archiveFooter = 4, finalization = 5
}
public struct LifeOSReceiptCursorV7: Codable, Sendable {
  public let phase: LifeOSReceiptPhaseV7; public let unit: LifeOSReceiptUnitV7
  public let packIndex: UInt16?; public let frameIndex: UInt32; public let chunkIndex: UInt32?
  public let relativePath: String?; public let artifactHash: String?; public let archiveHash: String?
}
public struct LifeOSReceiptFinalizationV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let finalizationID: UUID; public let archiveID: UUID
  public let archiveHash: String; public let artifactHash: String?; public let manifestRootHash: String
  public let relativePath: String; public let byteCount: UInt64; public let fileCount: UInt32
  public let chunkCount: UInt32; public let sinkCommitID: String?; public let status: String
  public let preparedAt: Int64; public let durableAt: Int64?; public let transitionHash: String
}
public struct LifeOSReceiptLogV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let receiptID: UUID; public let attempt: UInt16
  public let phase: LifeOSReceiptPhaseV7; public let cursor: LifeOSReceiptCursorV7
  public let currentUnit: String; public let artifactHash: String?; public let archiveHash: String?
  public let finalization: LifeOSReceiptFinalizationV7?; public let transitions: [LifeOSReceiptTransitionV7]
}
```

The active file is `LifeOSReceiptFileV7 { schemaVersion:7, domain:LifeOSReceiptDomainV6,
 migrationEpoch:UInt64, writeSequence:UInt64, logs:[LifeOSReceiptLogV7] }`. Hashes are lowercase 64-character
SHA-256 strings. `artifactHash` is the SHA-256 of the finalized archive file bytes; `archiveHash` is the semantic
archive hash produced by `finalizeArchive`; they are distinct and both are retained in the log and finalization.
`finalization.status` is `prepared` before sink finalization and `durable` after it. No digest-only record is valid.

`currentUnit` is required UTF-8 canonical JSON, <=4,096 bytes, with exactly sorted keys
`archiveHash,artifactHash,chunkIndex,frameIndex,packIndex,phase,relativePath,unit`; nullability mirrors the
typed cursor. Integers use the existing decimal-string adapter. `archiveHash` is null before
`manifestFinalized`; `artifactHash` is null before `sinkFinalized`; `packIndex` is 0...25 when a pack unit is
active and null for archive header/footer/finalization; `relativePath` is NFC and <=128 bytes when present. All
eight keys are emitted on every record; a nullable value is JSON `null`, never an omitted key.

## Monotonic transitions and APIs

The only permitted phase edges are `staging→staging|manifestFinalized`, `manifestFinalized→emitting`,
`emitting→emitting|sinkFinalized`, `sinkFinalized→bound`, `bound→bound|committed`, and `failed→failed`.
Within a phase, `(unit,packIndex,frameIndex,chunkIndex,relativePath)` is non-decreasing in the writer's declared
order. A same-cursor retry is allowed only when its transition hash and hashes match. No operation may return to
staging, restart emission at a prior pack, clear a hash, or replace a finalization record.

```swift
public struct LifeOSReceiptStageAdvanceV7: Sendable {
  public let receiptID: UUID; public let attempt: UInt16; public let cursor: LifeOSReceiptCursorV7
  public let expectedHeadHash: String
}
public struct LifeOSReceiptManifestFinalizationInputV7: Sendable {
  public let receiptID: UUID; public let attempt: UInt16; public let archiveID: UUID
  public let archiveHash: String; public let manifestRootHash: String; public let relativePath: String
  public let byteCount: UInt64; public let fileCount: UInt32; public let chunkCount: UInt32
  public let expectedHeadHash: String
}
public struct LifeOSReceiptArtifactFinalizationInputV7: Sendable {
  public let receiptID: UUID; public let attempt: UInt16; public let finalizationID: UUID
  public let archiveHash: String; public let artifactHash: String; public let sinkCommitID: String
  public let expectedHeadHash: String
}
public actor LifeOSReceiptStoreV7 {
  public func advanceStage(_ input: LifeOSReceiptStageAdvanceV7) throws -> LifeOSReceiptLogV7
  public func recordManifestFinalization(_ input: LifeOSReceiptManifestFinalizationInputV7) throws -> LifeOSReceiptLogV7
  public func advanceEmission(_ input: LifeOSReceiptStageAdvanceV7) throws -> LifeOSReceiptLogV7
  public func finalizeArtifact(_ input: LifeOSReceiptArtifactFinalizationInputV7) throws -> LifeOSReceiptFinalizationV7
  public func commitBound(_ receiptID: UUID, expectedArtifactHash: String) throws -> LifeOSReceiptLogV7
  public func resumeV7(_ receiptID: UUID) async throws -> LifeOSReceiptLogV7
}
```

Each mutating method locks, validates the old head and edge, appends one transition, rebuilds the complete V7 file,
writes a same-directory `.tmp`, fsyncs it, atomically replaces the selected file, fsyncs its directory, then returns.
`recordManifestFinalization` is durable before emission. `finalizeArtifact` is called only after `sink.finalize()`
returns and stores the artifact hash, sink commit ID and `status=durable` in the same replacement as `sinkFinalized`.
`commitBound` and the binding record are one replacement. `LifeOSReceiptCoordinatorV8` remains the only caller.

## Exact writer and recovery behavior

After the last `finishPack` and `finishArchiveIndex`, P18 calls `recordManifestFinalization`; it then writes the
first emission cursor as `phase=emitting,unit=archiveHeader,packIndex=0,frameIndex=0` for a nonempty pack set.
For an empty pack set it uses `unit=archiveHeader,packIndex=null`; no fake pack is invented. Each durable frame or
pack boundary calls `advanceEmission`; `packIndex` advances only after that pack footer and its carrier sequence
are synced. The final archive footer advances to `unit=archiveFooter`, then sink finalization records
`sinkFinalized` without changing the cursor backwards.

Cancellation, transient I/O failure and disk-full preserve the last valid phase/cursor and return an error; they do
not write `failed` and do not erase hashes. `failed` is reserved for invalid bytes, an impossible edge, or a
permanent identity conflict. `resumeV7` validates the cursor then resumes staging, emits from the recorded frame or
pack, locates `(archiveID,archiveHash)` for `sinkFinalized`, writes the durable finalization if needed, commits the
binding, or returns the already committed result. A crash between file replacement and the caller return is
idempotent because the expected head, finalization ID and hashes are persisted.

V6 migration reads its existing `currentUnit` and state; if the cursor is absent or contradictory it returns
`receiptMigrationMissingCursor` without modifying the file. Otherwise it maps `streaming→staging|emitting` from the
recorded unit, `finalizing→manifestFinalized`, and copies known archiveHash/artifactHash values. V7 is the only
active representation after a successful atomic migration.

P18 owns these records and methods in `ios/Shared/LifeOSReceiptCoordinator.swift` and calls them from
`ios/Shared/LifeOSDataArchiveWriter.swift`. P01 owns canonical framing and hash bytes. No worker may add a second
progress log, phase enum, cursor string or finalization sidecar.
