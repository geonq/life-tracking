# Revision 13 receipt authority and legacy relocation

Planning-only. R13-03 resolves the historical split between Replication, DataManagement and the R12
`LifeOS/Receipts` location. Workers must use this fixed resolver; no packet may choose a receipt URL.

R14-03 is the current authority for the relocation journal path, authorized canonical replacements, no-journal
bootstrap, retirement marker and legacy cleanup. The V7 inventory below is retained as migration input history;
workers must read R14-03 before implementing relocation.

## Final inventory

|role|fixed path|authority/policy|
|---|---|---|
|canonical recovery|`Application Support/LifeOS/Receipts/recovery-imports.json`|sole V6 recovery log after commit|
|canonical data|`Application Support/LifeOS/Receipts/data-management-receipts.json`|sole V6 export/restore log after commit|
|canonical deletion|`Application Support/LifeOS/Receipts/data-management-deletions.json`|sole V6 deletion log after commit|
|relocation fence|`Application Support/LifeOS/Receipts/relocation-v7.json`|temporary durable migration journal, never a receipt log|
|legacy recovery|`Application Support/LifeOS/Replication/recovery-imports.json`|read-only migration input; never written after commit|
|legacy data/deletion|`Application Support/LifeOS/DataManagement/data-management-receipts.json` and `data-management-deletions.json`|read-only migration inputs; never authority after commit|

All paths are resolved under the fixed application-support root with no symlink following. Missing legacy files are
allowed; nonempty corrupt files are not ignored. The canonical directory is created 0700 and each receipt file is
0600. The relocation journal is pruned only after two clean canonical opens.

## Exact relocation records and API

```swift
public enum LifeOSReceiptRelocationPhaseV7: String, Codable, Sendable {
 case discovered, validated, prepared, fenced, copying, verifying, committed, rolledBack, blocked
}
public struct LifeOSReceiptRelocationEntryV7: Codable, Sendable {
 public let domain: LifeOSReceiptDomainV6; public let sourcePaths: [String]; public let destinationPath: String
 public let sourceHashes: [String:String]; public let selectedLogHash: String; public let destinationHash: String?
 public let cursor: UInt32
}
public struct LifeOSReceiptRelocationFenceV7: Codable, Sendable {
 public let schemaVersion: Int; public let migrationID: UUID; public let fenceID: UUID
 public let sourceInventoryHash: String; public let selectedInventoryHash: String; public let entryCursor: UInt32
 public let signature: String
}
public struct LifeOSReceiptRelocationJournalV7: Codable, Sendable {
 public let schemaVersion: Int; public let migrationID: UUID; public let fenceID: UUID
 public let phase: LifeOSReceiptRelocationPhaseV7; public let entries: [LifeOSReceiptRelocationEntryV7]
 public let fence: LifeOSReceiptRelocationFenceV7?
 public let entryCursor: UInt32; public let createdAt: Int64; public let updatedAt: Int64
 public let errorCode: String?; public let transitionHash: String
}
public enum LifeOSReceiptRelocationErrorV7: Error, Sendable {
 case receiptRelocationInProgress, receiptRelocationConflict, receiptRelocationFenceInvalid
 case sourceChanged, corruptLog, diskFull, cancelled, capacity
}
public actor LifeOSReceiptRelocatorV7 {
 public func discover() throws -> LifeOSReceiptRelocationJournalV7
 public func migrateIfNeeded() throws -> LifeOSReceiptRelocationJournalV7
 public func recoverInterrupted() throws -> LifeOSReceiptRelocationJournalV7
 public func canonicalURL(_ domain: LifeOSReceiptDomainV6) throws -> URL
}
```

`sourcePaths` is a closed list of at most three fixed paths; `entries` has exactly three domain rows in enum order;
all hashes are lowercase SHA-256 of complete canonical file bytes. The journal uses the existing P01 canonical frame
and is atomically replaced with fsync of file and directory after every phase/cursor. `LifeOSReceiptStoreV6` calls
`migrateIfNeeded` before `logURL`; callers never concatenate `Application Support`, select a legacy path or open a
receipt file directly.

At `fenced`, `fence` is required and its signature is the owner signature over
`Frame("LifeOS/receipt-relocation-fence/v7", CanonicalJSON(fence without signature))`; P01 verifies the pinned owner
key before any destination is selected. `sourceInventoryHash` is the canonical hash of all discovered source hashes,
`selectedInventoryHash` is the canonical hash of the three selected logs, and `entryCursor` is the next domain row.
Precisely, the first is `hex(SHA256(Frame("LifeOS/receipt-relocation-sources/v7",CanonicalJSON({schemaVersion:7,
entries:[{domain,sourcePaths,sourceHashes}]}))))`, and the second is the same form with
`Frame("LifeOS/receipt-relocation-selection/v7",CanonicalJSON({schemaVersion:7,entries:[{domain,selectedLogHash}]}))`.
`transitionHash` uses `Frame("LifeOS/receipt-relocation-journal/v7",CanonicalJSON(journal without transitionHash))`.
Missing/invalid signatures, changed source inventory or a cursor outside `0...3` returns
`receiptRelocationFenceInvalid` and exposes no receipt.

`migrateIfNeeded` is the only startup entry: no journal means it runs discovery; `discovered|validated|prepared`
restarts preparation; `fenced|copying|verifying` calls `recoverInterrupted` under the same lock; `committed` selects
canonical files; `rolledBack` starts a fresh discovery; `blocked` returns `receiptRelocationConflict`. Thus an
interrupted relocation is automatically resumed before an existing operation's `resumeV6` can run.

## Discovery, merge and identity preservation

Discovery verifies every present candidate as a V5/V6 receipt file, migrates V5 to V6 in memory after validating its
old chain, and records the candidate hash. For each `receiptID`, identical complete logs deduplicate. If one valid
transition sequence is an exact hash-chain prefix of another, the longer sequence wins; otherwise a divergent or
corrupt nonempty candidate returns `receiptRelocationConflict` and leaves every source untouched. An absent domain
creates an empty schema-6 file only in the prepared destination. No receipt is selected by timestamp or filename.

The selected log preserves `receiptID`, `operationID`, `preparedArtifactID`, attempt, cursor, source hash, every
transition hash, `parentReceiptID`, `parentTransitionHash`, binding record and terminal state. Relocation changes
only the container file hash and path; it never re-signs or renumbers an operation. An interrupted recovery, export,
restore or deletion therefore resumes from its existing durable cursor after relocation.

## Fence, atomic order and recovery

1. Acquire the existing receipt writer lock; discover fixed paths and write `discovered`/`validated`.
2. Write the normalized three destination files as `.relocation.partial` files, fsync each and the directory, then
   write `prepared`, compute the two inventory hashes, sign the exact fence above and write `fenced`. From `fenced` through `verifying`, normal receipt reads/writes return
   `receiptRelocationInProgress`; only `recoverInterrupted` may proceed.
3. Replace canonical files in recovery, data, deletion enum order with same-volume atomic replace and directory
   fsync. Advance `entryCursor` only after each destination hash equals `selectedLogHash`; then write `verifying`.
4. Reopen all three canonical files, validate every chain and selected hash, write `committed`, and only then let
   `LifeOSReceiptStoreV6.logURL` return canonical paths. Legacy files remain immutable migration evidence.

Before `fenced`, a crash removes only partial destinations and the fixed legacy sources remain readable. During
`copying`, a crash classifies each canonical destination as missing, old or exact-new: exact-new entries are skipped,
missing/old entries are rewritten from the normalized selected log, and mismatches block. After `committed`, a crash
before return is a successful idempotent reopen. Cancellation after the fence leaves the journal and sources in place
and resumes the same migration; disk-full leaves the last verified destination and returns `diskFull`. Cleanup of
legacy files is a separate post-commit operation after two clean opens and is never required for resume.

P18 owns `LifeOSReceiptRelocatorV7`, the fixed path inventory and all receipt reads/writes in the existing
`ios/Shared/LifeOSReceiptCoordinator.swift`; P01 owns canonical bytes/error values. R13-03 supersedes R7/R9/R12
path wording while preserving their receipt state machines and retry guarantees. R14-03 supersedes this sheet's
`relocation-v7.json` retention and legacy-cleanup behavior and defines the permanent V8 authority marker.
