# R16 post-retirement authority and bounded mutation log

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R16 defines the legal life of canonical receipts after the
immutable legacy-retirement proof. It supersedes any R15 wording that treats
`retired` as a write stop or permits an unbounded log.

## Historical proof plus current inventory

`LifeOSReceiptAuthorityStateV9` is projected as:

```swift
struct LifeOSReceiptAuthorityStateV9: Sendable {
  let authorityID: UUID; let migrationEpoch: UInt64; let phase: LifeOSAuthorityRecoveryPhaseV9
  let retirementProofHash: String?; let retirementProof: LifeOSRetirementProofV9?
  let currentCanonicalInventoryHash: String; let currentCanonicalInventory: [LifeOSFileInventoryV9]
  let lastRecordSequence: UInt64; let lastRecordHash: String
  let fence: LifeOSAuthorityFenceV9
}
```

`retirementProof` and its hash are immutable historical facts. The current
inventory is derived from the last authenticated checkpoint/mutation and may
contain newer receipt heads, compaction or canonical replacements. No later
record overwrites, shortens or re-signs the historical proof. Every
post-retirement record carries `retirementProofHash` and the current expected
inventory hash; the first one also carries `retirementProofSequence`.

The supporting types are exact and persisted only in the authority record or
mutation log:

```swift
struct LifeOSRetirementProofV9: Codable, Sendable {
  let authorityID: UUID; let migrationEpoch: UInt64
  let dispositions: [LifeOSLegacyRetirementDispositionV9]
  let canonicalInventoryHash: String; let lastRecordHash: String
  let proofHash: String; let signerKeyID: String; let signature: Data
}
struct LifeOSFileInventoryV9: Codable, Sendable {
  let domain: String; let relativePath: String; let fileHash: String
  let byteCount: UInt64; let receiptHeadHash: String?
}
struct LifeOSAuthorityFenceV9: Codable, Sendable {
  let migrationEpoch: UInt64; let expectedInventoryHash: String
  let fenceRecordHash: String; let open: Bool
}
struct LifeOSAuthorityCheckpointV9: Codable, Sendable {
  let schemaVersion: UInt16; let authorityID: UUID; let migrationEpoch: UInt64
  let baseSequence: UInt64; let baseHeadHash: String
  let retirementProof: LifeOSRetirementProofV9; let currentInventory: [LifeOSFileInventoryV9]
  let activeIntents: [LifeOSPostRetirementMutationV9]
  let resultInventoryHash: String; let checkpointHash: String
  let signerKeyID: String; let signature: Data
}
```

Inventory entries are sorted by domain, NFC path and lowercase UUID where
present; duplicate paths, unknown domains, changed proof dispositions or a
`checkpointHash` not equal to
`SHA256(Frame("LifeOS/authority-checkpoint/v9", CanonicalJSON(all fields
except checkpointHash/signature)))` are rejected before projection. The
checkpoint carries the complete proof, not only its digest, so log rotation
does not discard historical verification material.

## Legal records and exact APIs

R16 extends `LifeOSAuthorityMutationKindV9` with
`postRetirementCanonicalIntent=8`, `postRetirementCanonicalCommit=9`, and
`checkpoint=10`. Intent/commit payloads retain R15 `authorityID`, sequence,
intent ID, expected inventory, old/new hashes, migration epoch, previous
record hash, device key and signature, plus:

```swift
struct LifeOSPostRetirementMutationV9: Codable, Sendable {
  let intentID: UUID; let receiptID: UUID?; let domain: String
  let relativePath: String; let retirementProofHash: String
  let retirementProofSequence: UInt64; let expectedInventoryHash: String
  let oldFileHash: String?; let newFileHash: String; let resultInventoryHash: String?
  let operation: String // "append", "replace", "compact", or "prune"
}
public actor LifeOSReceiptAuthorityV9 {
  func appendPostRetirementIntent(_ input: LifeOSPostRetirementMutationV9) throws
  func appendPostRetirementCommit(_ input: LifeOSPostRetirementMutationV9) throws
  func compactMutationLogIfNeeded() throws -> LifeOSAuthorityCheckpointV9?
}
```

Allowed: append/resume a canonical receipt, replace a canonical envelope after
CAS, compact a terminal receipt, prune a receipt only after its terminal proof,
and update the canonical inventory through an authenticated intent/commit pair.
The same receipt ID may resume after retirement if its current head matches.
Forbidden: changing `authority-v9.json`, migration epoch, historical proof,
source fingerprints, legacy files, receipt identity, an already committed
transition, or any path outside the canonical allowlist. A missing/changed
proof hash, epoch, previous record, current inventory or fence returns
`authorityReplayConflict` or `postRetirementPathDenied`.

## Replay, fence and retention rules

The epoch never increments after retirement. Sequence is strictly increasing
across all records, including a post-retirement pair and a checkpoint. The
device key remains the only signer; owner authorization is required only for a
new authority, not routine canonical receipt updates. Each intent is durable
before its file replacement; each commit observes the new hash and inventory,
then fsyncs the mutation log and canonical directory. Repeating the same
intent/commit preimage is a no-op; another preimage with the same ID is a
conflict. Legacy paths are never opened by replay after retirement.

## Bounded append-only log and checkpoint rotation

The active mutation log has `maxBytes=67,108,864`, `maxRecords=262,144` and
`maxRecordBytes=65,536`; before an append that would exceed any bound, P18
must compact under the authority lock. A checkpoint contains the full current
inventory, every active intent, terminal receipt heads needed for resume, the
complete historical retirement proof/dispositions, `baseSequence`,
`baseHeadHash`, `retirementProofHash`, `resultInventoryHash`, and an owner/device
authenticated `checkpointHash`.

Rotation is: write checkpoint as the first record of `.next`, fsync it, replay
and verify it, atomically replace the active log, fsync the directory, reopen
and verify, then remove the old log only after the new log is visible. The new
log keeps the old `baseSequence/baseHeadHash`; sequence does not reset. A
crash before replace leaves the old log; after replace reopens the verified
checkpoint. If neither validates, return `authorityCheckpointCorrupt` and
make no projection. Pruning affects only records represented by the complete
checkpoint; it cannot remove the historical proof or an active receipt cursor.

P01 owns mutation/checkpoint bytes and signatures. P18 owns the actor, CAS,
filesystem ordering and replay. P16 may call only the named actor APIs.
