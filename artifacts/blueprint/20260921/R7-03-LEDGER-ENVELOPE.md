# Revision7 single persisted sync envelope
Planning-only. R7 makes `SyncAdapterEnvelopeV2` the only durable authority for each replicated store. R6's
`SyncLedgerV1`, empty `sync_meta` arrays and parallel interpretations are migration history, never final state.

## Final wrapper
```swift
public struct SyncFrontierRecordV2: Codable, Equatable, Sendable {
 public let replicaID: String; public let received: SyncFrontier; public let applied: SyncFrontier
 public let acknowledged: SyncFrontier
}
public struct SyncHeadRecordV2: Codable, Equatable, Sendable {
 public let entityID: String; public let head: String; public let operationHash: String?; public let deleted: Bool
}
public struct SyncAdapterEnvelopeV2: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let datasetID: String
 public let storeID: SyncStoreKind; public let storeUUID: UUID; public let originID: String; public let epoch: String
 public let nextSequence: String; public let frontiers: [SyncFrontierRecordV2]
 public let outbox: [SyncOutboxEntry]; public let inbox: [SyncInboxRecord]; public let acknowledgements: [SyncAck]
 public let heads: [SyncHeadRecordV2]; public let conflicts: [SyncConflict]; public let receipts: [SyncCommitReceipt]
}
public struct SyncDomainFileEnvelopeV2<Domain: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let domain: Domain; public let sync: SyncAdapterEnvelopeV2
}
```
The final root version/tag is `2`/`syncAdapterEnvelope`; `storeUUID` is stable per `(datasetID, storeID)` and must match
the migration record. Arrays are sorted by their stated IDs/sequence, duplicates reject, and each outbox/inbox/ACK/head/
conflict/receipt array is <=10,000; frontiers are <=8; decoded envelope and domain bytes are <=32MiB. All required fields
are present, nullable fields are explicit null, and `sync.storeID`, dataset, epoch and heads are the only authority for
replication state. Domain values remain under `domain`; widgets never become a second copy.
The JSON bytes use the R3-00 canonical subset and preserve the exact field names shown here in Python/TypeScript; only
Swift's `SyncStoreKind` wrapper is converted to its raw string. Unknown keys, duplicate keys and noncanonical numbers
are rejected before an envelope is persisted.

## Owning files and Planning storage
JSON domains persist one `SyncDomainFileEnvelopeV2` in their existing file: `calendar.json`; the six Finance files;
the eight Fitness/Nutrition files; and Tax `documents.json`. No `SyncLedgerV1` or sidecar inbox survives migration.
Planning owns the same canonical envelope bytes in `LifeOS/Planning/<vaultID>/journal.sqlite`, column
`sync_meta.envelope`, keyed by `storeID='vault'`. `sync_operations` and `sync_receipts` are bounded SQL indexes/materialized
projections of that envelope, written in the same SQLite transaction; they are rebuilt from the canonical envelope when
their row digest differs and are never independently authoritative. The existing `mutations`/publication tables remain
the local filesystem journal.

## Final adapter surface

```swift
public protocol SyncDomainAdapter: Sendable {
 var kind: SyncStoreKind { get }
 func recover() async throws
 func frontier() async throws -> SyncFrontierSnapshot
 func pendingPage(after cursor: String?, limit: Int) async throws -> [SyncOperation]
 func persistInbox(_ operations: [SyncOperation]) async throws -> SyncInboxBatchResult
 func applyRemote(_ operation: SyncOperation) async throws -> SyncCommitReceipt
 func enumerateAcknowledgements(after cursor: String?, limit: Int) async throws -> SyncAckPage
 func recordAcknowledgement(_ ack: SyncAck) async throws
 func advanceFrontier(_ frontier: SyncFrontier, receiptIDs: [String]) async throws -> SyncFrontierAdvanceResult
 func checkpoint(_ frontier: SyncFrontier) async throws -> SyncCheckpointReceipt
}
```

This is the R5 method set with the final closed `SyncStoreKind` owner; the old generic `makeArchive/restoreArchive`
methods are removed in favor of `RecoveryBundleAdapter.makeRecoveryEntry/restoreRecoveryEntry` from R7-01. Every method
loads and validates the same `SyncAdapterEnvelopeV2`; `recover()` returns no second value and only repairs that wrapper
or its documented Planning SQL projections. `persistInbox` validates the bounded batch and replaces the JSON wrapper
once, or commits the equivalent Planning SQL transaction. It returns duplicate/blocked IDs from durable rows, never a
preview. `applyRemote` owns the projection plus terminal receipt transition; `recordAcknowledgement` and
`advanceFrontier` cannot expose progress without that receipt in the same wrapper. Cancellable callers may stop between
methods; a committed wrapper is always replayable by `recover()`.

`SyncOperation.storeID` remains the R3 wire string for backward compatibility and must equal `kind.rawValue`; the
stable UUID is `SyncAdapterEnvelopeV2.storeUUID`. `SyncCheckpointReceipt.storeID` follows the same rule. No worker may
change the wire field to a second UUID-shaped store identifier or add a parallel ledger type.

## Exact migration functions
```swift
public enum SyncEnvelopeMigrationError: Error, Sendable {
 case invalidLegacy, duplicatePending, pendingTooLarge, invalidStoreUUID, unsupportedSchema, diskFull, corruptBackup
}
public struct SyncLegacySidecar: Sendable {
 public let relativePath: String; public let bytes: Data
}
public enum SyncEnvelopeMigrator {
 public static func deterministicStoreUUID(datasetID: String, storeID: SyncStoreKind) -> UUID
 public static func migrateJSONFile(storeID: SyncStoreKind, datasetID: String, legacyFile: Data,
   pendingFiles: [SyncLegacySidecar], revisionFile: SyncLegacySidecar?, legacyLedger: SyncLedgerV1?) throws -> Data
}
extension PlanningMutationJournal {
 public func migrateSyncEnvelopeV3(datasetID: String) throws
 public func loadCanonicalSyncEnvelope() throws -> SyncAdapterEnvelopeV2
}
```
Migration decodes the current domain with its old validated decoder, reads every current pending JSON/request file into
`SyncLegacySidecar` values, reads the current revision sidecar when present, preserves operation IDs/bytes/idempotency
keys, and converts `SyncLedgerV1` rows into the final arrays. Sidecar paths must match the owning store's closed
allowlist; an unrecognized path stops at the R6-07 checkpoint instead of being copied. If the current
file has no UUID, `deterministicStoreUUID` uses UUIDv5 over `datasetID + NUL + storeID`; it never generates a new UUID
on relaunch. A malformed pending item is retained as a bounded `blocked` inbox/outbox record with its error, never
silently dropped. The old file is hashed and retained as `.r1.backup` until the new candidate is committed.

JSON migration order is lock → decode/validate all legacy inputs → construct one envelope → validate bounds/hashes →
flush same-volume candidate → atomic replace → remove only a verified temporary. Planning migration is the existing
exclusive writer lock → `BEGIN EXCLUSIVE` → create/upgrade v3 tables → write canonical `sync_meta.envelope` and derived
indexes → `PRAGMA user_version=3` → COMMIT. A crash before commit leaves the old journal; a mismatch after restart
rebuilds indexes from `sync_meta.envelope`; disk-full leaves the old file and pending operations intact.

## Runtime transaction and no-duplicate rule
Every JSON `persistInbox`, local mutation, remote apply, ACK and frontier advance reads and replaces the same domain
file once; the resulting bytes contain domain data plus the complete envelope. Planning performs the equivalent changes
to canonical envelope and SQL projections in one transaction. `SyncAdapterEnvelopeV2` is the only value passed to
`recover`, `frontier`, `pendingPage`, `enumerateAcknowledgements`, `recordAcknowledgement` and `advanceFrontier`.
No worker may reintroduce `SyncLedgerV1`, a `sync_frontiers` table, an inbox sidecar, or a second in-memory store.
Cancellation before replace/COMMIT writes nothing; after it leaves the committed envelope for `recover()`. Corrupt
canonical bytes fail closed with the last verified backup/recovery receipt; they never return an empty success.

## Revision8 supersession

R8-02 supplies the UUID-to-kind compatibility layer without changing signed V1 bytes, and R8-07 is the canonical packet
allowlist and ownership table. `SyncAdapterEnvelopeV2` remains the sole persisted wrapper; aliases are trust data.

## Revision10 supersession

R10-01 is final for Planning's SQLite transaction/migration/fence and its derived publication file journal;
the envelope remains authoritative and is never replaced by JSON.
