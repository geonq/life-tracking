# Revision 14 receipt authority, authorization and retirement

Planning-only. R14-03 supersedes R13-03's path, journal-retention and legacy-cleanup clauses. R14-01 owns the
receipt log schema; this sheet owns authority fencing, migration and retirement. No caller may select a path.

R15-04 and R15-05 are now current for authority authentication, per-file inventory, replacement intents, crash
recovery and retirement proof. The V8 mutable marker below is historical migration input only.

## Fixed authority and marker

The sole authority marker and migration journal is
`Application Support/LifeOS/Receipts/relocation-v8.json`. The three canonical logs remain
`Receipts/recovery-imports.json`, `Receipts/data-management-receipts.json`, and
`Receipts/data-management-deletions.json`. R13's `Receipts/relocation-v7.json` is a one-time legacy journal input;
it is never reopened after V8 import. Legacy inputs are the fixed Replication recovery file and the two fixed
DataManagement files named in R13-03.

```swift
public enum LifeOSReceiptAuthorityPhaseV8: UInt8, Codable, Sendable {
  case bootstrap = 10, prepared = 20, fenced = 30, copying = 40
  case verifying = 50, committed = 60, retiringLegacy = 70, retired = 80, blocked = 90
}
public struct LifeOSReceiptFileFingerprintV8: Codable, Sendable {
  public let domain: LifeOSReceiptDomainV6; public let relativePath: String
  public let fileHash: String; public let headHash: String; public let byteCount: UInt64
  public let writeSequence: UInt64; public let migrationEpoch: UInt64
}
public struct LifeOSReceiptMutationV8: Codable, Sendable {
  public let mutationID: UUID; public let domain: LifeOSReceiptDomainV6
  public let expectedOldFileHash: String; public let expectedNewFileHash: String
  public let expectedOldHeadHash: String; public let expectedNewHeadHash: String
  public let migrationEpoch: UInt64; public let writeSequence: UInt64
}
public struct LifeOSReceiptAuthorityMarkerV8: Codable, Sendable {
  public let schemaVersion: UInt16; public let authority: String; public let migrationID: UUID
  public let migrationEpoch: UInt64; public let phase: LifeOSReceiptAuthorityPhaseV8
  public let canonical: [LifeOSReceiptFileFingerprintV8]; public let sourceInventoryHash: String
  public let canonicalInventoryHash: String; public let legacyCursor: UInt8
  public let legacyRetired: Bool; public let pendingMutation: LifeOSReceiptMutationV8?
  public let retiredAt: Int64?; public let transitionHash: String; public let signature: String
}
```

`relocation-v8.json` is retained permanently in `retired`; it is a completion marker, not a receipt log or binding
sidecar. Its exact transition hash is `SHA256(Frame("LifeOS/receipt-authority/v8",
CanonicalJSON(marker without transitionHash or signature)))`. During migration, `signature` is the pinned-owner
signature over `Frame("LifeOS/receipt-authority-owner/v8", CanonicalJSON(marker without signature))`; P01 verifies it
before any canonical replacement. After retirement, authorized receipt mutations retain that migration signature and
are authorized by the pending-mutation/transition hash protocol below. `canonicalInventoryHash` is the same frame over sorted
`{domain,relativePath,fileHash,headHash,byteCount,writeSequence,migrationEpoch}` entries. `sourceInventoryHash`
is the R13 source candidate hash set. The marker is canonical JSON, owner-signed during migration using the P01
receipt-authority domain, and atomically replaced with fsync of file and directory.

Each canonical `LifeOSReceiptFileV7` has the same `migrationEpoch` as the marker and a monotonic `writeSequence`.
Receipt writes preserve the V7 receipt IDs, log heads and R14-01 phase/cursor. A file hash or head hash is always
computed from complete canonical file bytes, never from a path or timestamp.

## Authorized mutation and external modification

`LifeOSReceiptCoordinatorV8.applyAuthorizedMutation(_:)` is the only canonical writer:

```swift
public actor LifeOSReceiptCoordinatorV8 {
  public func open() throws -> LifeOSReceiptAuthorityMarkerV8
  public func applyAuthorizedMutation(_ mutation: LifeOSReceiptMutationV8,
    write: @Sendable () throws -> Data) throws -> LifeOSReceiptFileV7
  public func migrateAndRetireIfNeeded() throws -> LifeOSReceiptAuthorityMarkerV8
}
```

Under the writer lock, it validates the marker inventory and old file hash, writes the marker with
`pendingMutation`, fsyncs/replaces it, writes the complete new receipt file to a same-directory temporary file,
fsyncs/replaces it and its directory, then computes the new inventory and writes the marker with
`pendingMutation=null`, the new fingerprint and incremented sequence. The mutation returns only after that marker
replacement is durable. A receipt write is authorized only when its epoch, expected old hashes, new hash and
sequence match the pending record.

On open, a pending mutation with the old file hash rolls back the pending marker; a pending mutation with the exact
new hash/head completes the marker; any other bytes, epoch or sequence returns `externalModification` and enters
`blocked`. With no pending mutation, any canonical file differing from the marker inventory, having the wrong
epoch, or failing its receipt chain is external modification. The coordinator never overwrites such a file.

## Migration, retirement and cleanup order

`open()` acquires the lock and follows this closed decision tree:

1. A valid V8 marker resumes its phase. `retired` validates canonical files and returns without reading legacy
   paths. `retiringLegacy` resumes at `legacyCursor`; all other phases resume their recorded cursor.
2. With no V8 marker but a valid R13 V7 journal, validate its owner signature/transition hash and import it as a new
   V8 `migrationEpoch`; do not rediscover candidates after import.
3. With no journal, inspect fixed paths exactly once. If any nonempty legacy file exists, or canonical files are
   missing/V6, create `bootstrap→prepared` and run the R13 merge rules. If only valid V7 canonical files exist,
   create epoch 1 with their fingerprints and no legacy candidates. If nothing exists, create three empty V7 files,
   epoch 1, and a `retired` marker. Invalid nonempty data enters `blocked`; it is never silently discarded.
4. A marker with `retired=true` and a matching inventory is authoritative even if old paths later reappear from a
   backup. Those paths are not candidates and cannot revive pruned receipts.

Migration uses the fixed domain order recovery, data-management, deletion. It writes normalized `.partial` files,
fsyncs, records `fenced`, atomically replaces each canonical file, records its fingerprint before advancing the
cursor, verifies all heads, then records `committed`. It next records `retiringLegacy` and examines legacy paths in
this order: Replication recovery, DataManagement receipts, DataManagement deletions. A present file is deleted only
when its hash equals the recorded source hash; a missing file is recorded as skipped; a changed file returns
`legacyExternalModification` and remains untouched. Each deletion fsyncs the parent and advances `legacyCursor`.
After all three are processed, the marker records `legacyRetired=true`, final canonical inventory, `retiredAt`, and
`retired`; it is never pruned. A crash repeats the cursor step idempotently. Disk-full/cancellation preserves the
last phase and cursor and resumes; it never exposes a partially selected log.

Errors are `markerCorrupt`, `ownerSignatureInvalid`, `externalModification`, `legacyExternalModification`, `migrationConflict`,
`receiptRelocationInProgress`, `diskFull`, `cancelled`, and `capacity`. Repeated opens in `retired` are read-only
validation plus canonical return. P18 owns this contract in the existing
`ios/Shared/LifeOSReceiptCoordinator.swift`; P01 owns canonical bytes and owner-signature verification.
