# Revision 15 receipt relocation recovery

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R15-05 defines the durable per-file inventory and crash protocol beneath R15-04. It preserves
receipt IDs, resumable cursors and terminal states while preventing legacy rediscovery after pruning.

## Durable inventory and derived state

The `fenceOpen` mutation persists exactly three `LifeOSLegacySourceFingerprintV9` entries in its canonical payload;
the replacement intent/commit records persist every canonical destination. There is no mutable recovery sidecar.

```swift
public struct LifeOSLegacySourceFingerprintV9: Codable, Sendable {
  public let sourceID: UUID; public let domain: LifeOSReceiptDomainV6; public let relativePath: String
  public let existed: Bool; public let fileHash: String?; public let byteCount: UInt64
  public let receiptHeadHash: String?; public let observedEpoch: UInt64
}
public struct LifeOSLegacyRetirementDispositionV9: Codable, Sendable {
  public let sourceID: UUID; public let fingerprintHash: String; public let disposition: String
}
public struct LifeOSCanonicalReplacementV9: Codable, Sendable {
  public let intentID: UUID; public let domain: LifeOSReceiptDomainV6; public let relativePath: String
  public let sourceFingerprintID: UUID; public let expectedOldFileHash: String?
  public let expectedNewFileHash: String; public let canonicalCursor: UInt8
  public let state: LifeOSReplacementStateV9; public let mutationSequence: UInt64
}
public struct LifeOSReceiptAuthorityStateV9: Sendable {
  public let phase: LifeOSAuthorityRecoveryPhaseV9; public let migrationEpoch: UInt64; public let canonicalCursor: UInt8
  public let legacyCursor: UInt8; public let sourceInventory: [LifeOSLegacySourceFingerprintV9]
  public let replacements: [LifeOSCanonicalReplacementV9]; public let lastRecordHash: String
  public let canonicalInventoryHash: String; public let retirementProofHash: String?
}
```

The source inventory is ordered recovery, data-management, deletion and contains missing files as `existed=false`
with `fileHash=null`; present files contain lowercase SHA-256 of complete bytes, byte count and validated receipt head.
`LifeOSLegacyRetirementDispositionV9.disposition` is the closed string `missing` or `retired`; any other value is
invalid. Its `fingerprintHash` is `SHA256(Frame("LifeOS/legacy-source-fingerprint/v9",
CanonicalJSON(fingerprint without observedEpoch)))`.
The canonical replacement cursor is 0...3 and advances only after the matching commit record. The legacy cursor is
0...3 and advances only after a matching retirement commit. `state` is derived as `prepared`, `fenced`, `copying`,
`verifying`, `committed`, `retiringLegacy`, `retired` or `blocked`; it is never independently edited.

## Exact crash protocol

1. Create the immutable V9 authority record, then append signed `fenceOpen` with all source fingerprints and the
   canonical baseline. Before this record is durable, a crash leaves no migration intent; the next open may rescan.
   After it is durable, a changed source hash is `externalModification`, never a new candidate.
2. For each canonical domain, append `canonicalReplaceIntent`, write the normalized V7 file to a same-directory
   temporary file, fsync, atomically replace, fsync the directory, hash the result, then append
   `canonicalReplaceCommit`. A crash before replacement sees old hash and replays the same intent; a crash after
   replacement but before commit sees the exact new hash and appends commit; any third hash blocks.
3. After all three commits, append a signed `canonicalVerified` mutation and begin
legacy retirement. For each source, append `legacyRetireIntent`, verify the current bytes equal the recorded source
   fingerprint, unlink only that exact file, fsync its parent, then append `legacyRetireCommit`. Missing files are
   idempotently committed as the recorded `existed=false` state; changed files return `legacyExternalModification`.
4. After all legacy commits, recompute all canonical file hashes and append `retirementProof`. Its preimage is
   `CanonicalJSON({schemaVersion:9,authorityID,migrationEpoch,retirementDispositions:[{sourceID,fingerprintHash,disposition}],
   canonicalInventoryHash,lastRecordHash})`, with dispositions sorted by source ID and framed with
   `LifeOS/receipt-retirement-proof/v9`; its hash and device
   signature are durable before `retired` is observable.

The proof is valid only when every source is `missing` or `retired`, every canonical file has the V9 epoch and the
replayed inventory hash matches. After proof, `open()` validates canonical files and the proof, never reads legacy
paths, and returns the derived state. A restored legacy file therefore cannot revive a pruned receipt. Repeated opens
are read-only verification; a missing authority/log, bad proof, incomplete intent or mismatched file returns
`authorityBootstrapRequired|authorityInvalid|externalModification|receiptRelocationInProgress` without projection.

If `authority-v9.json` is absent, bootstrap may create it only after P01 has an owner key and the locked process has
fixed the exact canonical/legacy allowlists. If the R14 `relocation-v8.json` exists, import its validated inventory
once before creating the V9 `fenceOpen`; never edit it. If legacy or canonical data exists, the new owner record and its first
`fenceOpen` are durably ordered before any file replacement. If the immutable authority exists but its mutation log
is absent, incomplete except for a proven torn final frame, or not rooted at sequence 0, the state is
`authorityInvalid`; workers may not reconstruct it from filenames or timestamps.

## Operation preservation and ownership

Canonical replacement copies complete V7 logs, including every `receiptID`, `operationID`, attempt, R15 transition
chain, compaction anchor, finalization, binding and terminal/error state. It changes only the container path and
authority epoch. No receipt is renumbered or recreated. A V6/R14 source is normalized once before its replacement
intent; the R15-01 migration errors remain visible in the receipt authority state.

P18 owns inventory discovery, intent/commit ordering, replay and proof checks in
`ios/Shared/LifeOSReceiptCoordinator.swift`; P01 owns authenticated mutation bytes. No worker may add a JSON
recovery marker, choose a legacy path, or delete a source without its fingerprint-matched intent/commit pair.

## R16 current authority

R16-03 fixes the bootstrap rule and defines the exact signed pending intent,
post-unlink proof, restart table and atomic visibility. R16-04 governs every
canonical mutation after retirement and the bounded authority-log checkpoint.
