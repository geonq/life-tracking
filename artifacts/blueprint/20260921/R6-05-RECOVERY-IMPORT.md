# Revision6 recovery import retry contract
Planning-only. Import receipt durability precedes every projection and is the only authority for retry progress.

## Receipt and persistent owner
```swift
public enum ArchiveImportState: String, Codable, Sendable {
 case prepared, mapped, projecting, interrupted, failed, committed, rejected
}
public struct ArchiveImportReceiptV2: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let archiveID: String; public let archiveHash: String
 public let targetDeviceID: String; public let targetOriginID: String; public let sourceEpoch: String
 public let idempotencyKey: String; public let state: ArchiveImportState; public let completedStores: [SyncStoreKind]
 public let nextStoreIndex: Int; public let installedFrontier: SyncFrontier?; public let attempt: UInt64
 public let lastErrorCode: String?
}
public actor SyncRecoveryImportStore {
 public init(url: URL)
 public func load(archiveID: String, targetDeviceID: String) throws -> ArchiveImportReceiptV2?
 public func write(_ receipt: ArchiveImportReceiptV2) throws
}
```
`schemaVersion == 2`; IDs/hashes use R4 rules, stores are sorted unique members of the closed 17-kind enum, and
`nextStoreIndex == completedStores.count`. The receipt file is `recovery-imports.json` inside the existing private
`Application Support/LifeOS/Replication` directory and is atomically replaced under the existing trust-store writer
lock. It is a receipt index, not a second domain database. `archiveHash` is SHA-256 of the exact received archive bytes;
`idempotencyKey = SHA256(archiveHash + targetDeviceID + targetOriginID)`.

## State machine and exact call order
`SyncTrustStore.commitImport(_ bytes: Data, targetDeviceID: String, adapters: [SyncStoreKind: any SyncDomainAdapter]) async
throws -> ArchiveImportReceiptV2` is the single entry point. It executes:

1. Bound/read/canonicalize bytes; `RecoveryArchiveVerifier.verify` resolves each operation's immutable source epoch/key.
   If a committed receipt has the same key and hash, return it; a different hash returns `idCollision`.
2. Write `prepared` with an empty completed list and `nextStoreIndex=0`; flush and replace before any projection.
3. Persist the source→target identity mapping in the same receipt transaction; write `mapped`.
4. Write `projecting`; for each store in fixed `SyncStoreKind` order, call its `restoreArchive` with the mapped origin.
   The adapter commits its domain payload, inbox/receipt/frontier and widget projection in its own existing transaction.
5. After each successful adapter receipt, write the receipt with that store in `completedStores` and increment
   `nextStoreIndex`. Only after every adapter and the combined frontier are durable write `committed` and return success.

The projection order is exactly `calendar, financeImports, financeRecurring, financeInvestments, financeBudgets,
financeAllocations, financePreferences, training, trainingTemplates, meals, nutritionGoals, supplements, journal,
lifestyle, barcodeRecords, vault, tax`; the archive must carry the required store entries and rejects an omitted or
duplicated store before step 2. No adapter may report completion from an in-memory projection.

## Retry, crash and cancellation semantics
An identical retry reads the receipt: `prepared` resumes mapping, `mapped` resumes `projecting`, `projecting` or
`interrupted` resumes at `nextStoreIndex`, `failed` retries the recorded store, and `committed` returns the stored
receipt without applying anything. A crash before receipt write leaves no import state; after each write, restart sees
that state. A crash after an adapter commit but before its receipt update is repaired by the adapter's operation hash
and receipt lookup, then the import receipt advances without a second mutation. A crash after final projection but before
`committed` repeats only receipt/frontier inspection.

Cancellation before `prepared` writes nothing. Cancellation after `prepared`/`mapped`/`projecting` writes
`interrupted` and never reports success. Disk-full writes `failed` only if that receipt replacement succeeds; otherwise
the previous valid receipt remains and the next retry reopens the last durable state. Projection is forward-only: no
rollback deletes already committed domain data. A failed retry preserves the exact error and remains retryable.

## Error and release evidence
`RecoveryImportError` is `invalidArchive`, `invalidMapping`, `idCollision`, `missingAdapter`, `unsupportedSchema`,
`staleFrontier`, `conflict`, `diskFull`, `cancelled`, `storageCorrupt` or `projectionFailed`. A rejected archive creates
no receipt unless a validated `rejected` receipt can be atomically stored. Evidence must kill the process at every numbered
boundary, repeat an import after each kill, replay a committed archive, alter one byte, fill the disk, and prove that
success is impossible until all receipt, domain, frontier and widget writes are durable.

## Revision7 supersession

R7-01 replaces the single-store `ArchiveImportReceiptV2` flow with `RecoveryBundleImportReceiptV3` and its fixed
17-store projection order. R7-05 separately covers the 26-pack user data archive; the two receipt authorities remain
distinct.
