# Revision6 per-domain inbox, ACK and frontier persistence
Planning-only. R6 replaces the ambiguous R5 phrase “sync_operations/inbox table” with one storage rule per owner.
No second database or parallel domain store is permitted.

## Shared embedded ledger

```swift
public enum SyncInboxState: String, Codable, Sendable { case inbox, applied, conflict, blocked }
public struct SyncInboxRecord: Codable, Equatable, Sendable {
 public let operationHash: String; public let operation: SyncOperation; public let state: SyncInboxState
 public let receiptID: String?; public let errorCode: String?
}
public struct SyncLedgerV1: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let storeID: SyncStoreKind; public let inbox: [SyncInboxRecord]
 public let acknowledgements: [SyncAck]; public let frontier: SyncFrontier; public let receipts: [SyncCommitReceipt]
}
```

The ledger is required after migration, version1, bounded to 10,000 inbox records, 10,000 ACKs and 10,000 receipts
per store, with a 32MiB encoded store cap. Hashes, operation IDs and receipt IDs are unique; ACKs and frontier
positions cannot get ahead of terminal receipts. A blocked or conflict row remains durable. JSON decoders reject
unknown keys, duplicate IDs, oversized arrays and a frontier gap before mutation.

## JSON-envelope domains

Calendar embeds `sync: SyncLedgerV1` in the existing `calendar.json` wrapper. Each Finance store embeds the same
ledger in its existing file: `finance-imported-transactions.json`, `finance-recurring-payments.json`,
`finance-investment-activity.json`, `finance-budgets.json`, `finance-allocation-rules.json` and
`finance-tracking-preferences.json`. Fitness uses the existing files `fitness-training-ledger.json`,
`fitness-strength-templates.json`, `nutrition-meals.json`, `nutrition-goals.json`, `supplements-v1.json`,
`fitness-journal.json`, `fitness-lifestyle-ledger.json` and `nutrition-barcode-records.json`; Tax embeds it in
the sanitized `documents.json` wrapper. The owning store envelope keeps its existing domain fields and adds only
the required `sync` member at its next schema version; no sidecar inbox file is created.

The exact owner calls are `CalendarStore`, each `FinanceSyncAdapter`-selected existing Finance store,
`FitnessSyncAdapter`-selected existing Fitness/Nutrition store, `PlanningMutationJournal` for Planning and
`TaxDocumentStore`. `Usage` and `Clipper` are excluded by R6-01.

For a JSON owner, `persistInbox` performs: actor/lock acquire → decode primary → validate operation/signature and
ledger bounds → append or classify duplicate → encode one candidate containing domain bytes plus ledger → flush and
protect same-volume temporary → atomic `replaceItemAt` → return `SyncInboxBatchResult`. A cancellation before replace
writes nothing; after replace the durable rows are recovered even if the caller stops.

`applyRemote` performs the same single-file transaction: load ledger and domain → verify base head → apply typed
projection or conflict/tombstone → append `SyncCommitReceipt` → mark inbox terminal → advance contiguous frontier →
encode/flush/replace once. `recordAcknowledgement` and `advanceFrontier` each replace the same envelope; no ACK or
frontier is visible before the receipt is in that file. A restart calls `recover()` before any network exchange,
replays only `inbox` rows, and returns stored receipts for `applied/conflict` rows.

## Planning journal owner

Planning uses the existing `PlanningMutationJournal` SQLite file at
`LifeOS/Planning/<vaultID>/journal.sqlite`; no new SQLite file is allowed. R4's planned schema version3 is the final
sync schema for this revision: `sync_operations(mutation_id, operation_hash, encoded, local_mutation_id, state,
outbox_state, attempts, last_error)`, `sync_receipts(mutation_id, replica_id, level, encoded)` and
`sync_meta(store_id, dataset_id, origin_id, epoch, next_sequence, envelope)`. `sync_operations` is the durable inbox
and outbox, `sync_receipts` is the ACK enumeration, and the canonical `SyncAdapterEnvelope` in `sync_meta.envelope`
holds the frontier. R6 explicitly forbids new `sync_acknowledgements`, `sync_frontiers`, `sync_operations.sqlite` or
any other parallel table/file. `state` additionally admits `blocked`; `outbox_state` remains the R4 closed set.

The current source journal is schema v2; implementation migrates v1→v2 using the existing code, then v2→v3 under the
same writer lock with the exact R4 tables/columns/indexes, preserving every local mutation and receipt. The migration
does not publish files or invent an inbox row. Existing `sync_meta` envelope arrays are reconstructed from the SQL
rows; no duplicate copy becomes authoritative.

`PlanningMutationJournal.stageReplicatedMutation` and `PlanningVaultStore.stageReplicatedDeletion` run under the
existing writer lock and one `BEGIN EXCLUSIVE` transaction: validate/bind operation → insert or classify the
`sync_operations` inbox row → apply or record conflict → insert `sync_receipts` terminal receipt → update the
`sync_meta` frontier only when contiguous → update publication journal state → COMMIT. Rollback leaves every prior row
unchanged. `recover()` reads only this database, marks an in-progress publication interrupted, and resumes from its
durable receipt; it never reconstructs a second in-memory authority.

## Server/relay ownership and restart order

P02 keeps the existing `replication.sqlite` database and its existing `operations`, `acks`, `blobs`, and membership
tables. It may add the named receipt/frontier columns only through the existing schema migration; it must not create
`sync_operations.sqlite`. `ReplicationStore.append` inserts the operation and ACK/receipt rows in its current
transaction, then signs the response after commit. A crash before commit is retried with the same operation hash;
after commit the original receipt is returned. JSON stores, Planning SQLite, and the server database each own their
rows; none mirrors another store's inbox.

Acceptance evidence must show cold restart at every commit boundary, leftover temp file handling, duplicate operation,
duplicate ACK, frontier gap, conflict, blocked schema, cancellation and disk-full. A passed network exchange without
durable local evidence is insufficient.

## Revision7 supersession

R7-03 supersedes `SyncLedgerV1` as final storage and makes `SyncAdapterEnvelopeV2` the single wrapper containing inbox,
outbox, ACKs, heads, conflicts, receipts and all frontiers. The adapter method set and Planning authority in R7-03 are
the implementation binding.
