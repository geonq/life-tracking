# Revision5 durable sync-engine contract
Supersedes the adapter call order in R4-15 and the protocol-only wording in R4-16.
P01 owns these shared result types and `SyncEngine`; P03/P04/P06/P13 own adapter implementations;
P02 owns transport. No network callback may mutate a domain store directly.

## Exact adapter surface
```swift
public struct SyncInboxBatchResult: Sendable {
 public let durableOperationIDs: [String]; public let duplicateOperationIDs: [String]
 public let blockedOperationIDs: [String]; public let nextCursor: String?
}
public struct SyncAckPage: Sendable {
 public let acknowledgements: [SyncAck]; public let nextCursor: String?; public let hasMore: Bool
}
public struct SyncFrontierSnapshot: Sendable { public let received: SyncFrontier; public let applied: SyncFrontier }
public struct SyncFrontierAdvanceResult: Sendable { public let frontier: SyncFrontier; public let advanced: Bool }
public protocol SyncDomainAdapter: Sendable {
 func recover() async throws
 func frontier() async throws -> SyncFrontierSnapshot
 func pendingPage(after cursor: String?, limit: Int) async throws -> [SyncOperation]
 func persistInbox(_ operations: [SyncOperation]) async throws -> SyncInboxBatchResult
 func applyRemote(_ operation: SyncOperation) async throws -> SyncCommitReceipt
 func enumerateAcknowledgements(after cursor: String?, limit: Int) async throws -> SyncAckPage
 func recordAcknowledgement(_ ack: SyncAck) async throws
 func advanceFrontier(_ frontier: SyncFrontier, receiptIDs: [String]) async throws -> SyncFrontierAdvanceResult
 func makeArchive(through: SyncFrontier) async throws -> Data
 func restoreArchive(_ bytes: Data, expected: SyncCheckpoint) async throws -> SyncCheckpointReceipt
 func checkpoint(_ frontier: SyncFrontier) async throws -> SyncCheckpointReceipt
}
```
`SyncInboxBatchResult` is a durable result, not a validation preview. `persistInbox` validates each signed
operation and inserts it into the adapter's `sync_operations`/inbox table in one transaction; duplicate hashes
return the original identity, conflicting identity returns `idCollision`, and unsupported payload remains blocked.
No row is acknowledged merely because it was inserted.

## Transaction and call graph
`SyncEngine.synchronizeOnce` → `recover` → `frontier` → transport challenge/exchange →
`persistInbox` → for each durable operation `applyRemote` → `enumerateAcknowledgements` → sign/send ACKs →
`recordAcknowledgement` → `advanceFrontier` → publish accepted snapshots/widgets.
`applyRemote` atomically validates current entity head, applies or records a full conflict, stores the receipt,
and marks the inbox row applied/conflict. A duplicate returns that stored receipt without calling a domain command.
`enumerateAcknowledgements` returns durable stored/applied receipts sorted `(storeID,originID,sequence,level)`;
the cursor is opaque canonical bytes and cannot skip a gap. `recordAcknowledgement` is idempotent on
`(mutationID,replicaID,level)` and rejects a forged level/identity. `advanceFrontier` runs in the same writer
transaction as its receipt check: every sequence through the requested point must have a durable inbox row and
terminal receipt. It returns unchanged for a repeated request and throws `missingParent`, `gap`, or `staleEpoch`
without changing the frontier.

## Durable ownership and cancellation
P01 owns frontier/inbox/receipt state; domain stores own projections and tombstones. P03/P04/P06/P13 must call
the existing store transaction before returning `SyncCommitReceipt`; no in-memory inbox or frontier is authoritative.
Before `persistInbox`, cancellation returns `CancellationError` and writes nothing. After inbox commit, cancellation
leaves inbox rows for recovery. After domain commit, cancellation leaves the terminal receipt and ACK enumeration
pending. Network retry reuses the same operation hash/idempotency key with a fresh request nonce; it never allocates
a new operation. An engine generation check after every await suppresses stale UI publication but never rolls back
durable state. `stop()` cancels and awaits the owned task only.

## Bounds and evidence
Each page is <=128 operations and <=1MiB decoded; `persistInbox` rejects before allocation if the page is larger.
Ack pages are <=256; archive ACKs are capped at10,000 by R5-06. Evidence must cover crash after inbox insert,
crash after projection, duplicate operation, duplicate ACK, out-of-order sequence, cancellation at each await,
and frontier retry. These are execution evidence gates; the interfaces are no longer open design choices.

## Revision6 supersession
R6-03 is authoritative for durable ownership: JSON domains embed one ledger, while Planning uses the existing
`journal.sqlite` schema-v3 `sync_operations`, `sync_receipts` and `sync_meta` envelope. It forbids a second database and
forbids inventing separate `sync_acknowledgements` or `sync_frontiers` tables.
