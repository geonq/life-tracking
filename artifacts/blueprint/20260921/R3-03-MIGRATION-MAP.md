# Exact current-format migration map
Source inspection date2026-09-21; P03/P04/P13 own changes. No migration executed.
Every new replication field is optional ONLY when decoding listed legacy version, required on new version.
Unknown future schema fails read-only; never filter/drop unknown fields to make it fit.
Local defaults after reviewed migration: schemaVersion1, membership IDs/epoch, nextSequence1,
received/applied empty frontiers, outbox/inbox/conflicts/ACKs/entities empty; bootstrap existing records explicitly.
Do not silently default corrupted/partial new envelope to these values.
Old payload bytes backed up exactly before write; complete byte caps include metadata and pending data.

|Store/current format|Target format and exact existing keys retained|Migration owner|
|---|---|---|
|CalendarStore raw CalendarSnapshot|new wrapper {schemaVersion:1,snapshot:CalendarSnapshot,replication:SyncAdapterEnvelope}|P03|
|FinanceImportedTransactionStoreEnvelope v4|v5 adds replication; retains transactions,remoteRevision,remoteETag,remoteRecordRevisions,remoteTombstones,outbox,importMappings,importBatches,legacyIdentityMappingIDs,legacyGenericTransactionIDs|P03|
|FinanceRecurringPaymentStoreState v1|v2 adds replication; retains financeTimeZoneIdentifier,revision,overrides,evidenceCache|P03|
|FinanceInvestmentActivityStoreState v1|v2 adds replication; retains revision,ledger|P03|
|FinanceBudgetStoreEnvelope v1|v2 retains budgets,adds replication|P03|
|FinanceAllocationStoreEnvelope v1|v2 retains rules,adds replication|P03|
|FinanceTrackingPreferencesEnvelope v1|v2 retains committed,draft; adds replication; draft never transmitted|P03|
|TrainingLedgerEnvelope v2|v3 retains sessions,receipts,retiredMutationIDs; adds replication|P04|
|NutritionMealStoreEnvelope v1|v2 retains meals; adds replication; absent legacy meals accepted only as legacy decoder currently allows|P04|
|NutritionGoalStoreEnvelope v1|v2 retains goals; adds replication|P04|
|SupplementStoreEnvelope v1|v2 retains snapshot,actionReceipts; adds replication|P04|
|FitnessJournalStore raw [FitnessJournalRecord]|wrapper {schemaVersion:1,records:[FitnessJournalRecord],replication:SyncAdapterEnvelope}|P04|
|FitnessLifestyleStorageEnvelope v1|v2 retains events,settings; adds replication|P04|
|NutritionRecordStore raw [NutritionRecord]|wrapper {schemaVersion:1,records:[NutritionRecord],replication:SyncAdapterEnvelope}|P04|
|TaxDocumentStore raw [TaxDocument]|wrapper {schemaVersion:1,documents:[TaxDocument],replication:SyncAdapterEnvelope}; protected local-only cache references separate from DTO|P13|
|PlanningVaultStore journals/SQLite|CP-S04 needs exact current SQLite schema/transaction seam; no guessed ALTER TABLE or side journal|P06/P05|
|FutureWidgetSnapshot|existing schema retained until P14 per-field new need; derived only, NEVER add replication envelope|P14|
|Windows provider/import files|remain current provider formats; replication DB new separate transport spool; no reset of revision/ETag/consent|P02/P17|

## Cutover transaction
Acquire process+cross-process lock→read bounded old bytes→validate all old records→write exclusive hashed backup→
construct wrapped state+bootstrap pending receipts→write/protect/flush temp→validate→atomic replace→publish memory.
A backup success is not migration success; reopen new envelope before reporting complete.
Interruption before replace leaves old file; after replace new file self-describes; repeat migration no-op.
Do not make source load methods perform a partial migration before wrapper/receipt API is integrated.
Null optional old field stays null; legacy IDs/dates/units/unknown compatible Canvas fields retained verbatim.
Pure payload projection keeps legacy original identity for exact lookup; wire hash ID not a replacement local ID.

## Legacy pending finance
Preserve attemptedRequest.baseRevision/ifMatch/idempotencyKey/body byte-for-byte and supersededAttemptKeys.
Each legacy outbox entry remains blocked-from-v1-submission until original endpoint receipt queried/confirmed.
No repeated money mutation through two transport paths. Migration copies pending state; does not presume remote acceptance.
After original ACK, mark legacy entry resolved in same store save then create v1 bootstrap/current-state op if needed.
Uncertain legacy attempt remains retained while Windows offline; new local edits still need distinct causal lineage.
CP-S02 must bind existing remoteRecordRevisions to entity heads before new writes cross the v1 cutover.

## Rollback
Before cutover existing binary may read old backup only. After new local edit, restoring old file loses data and is forbidden.
Old decoders often reject new keys; rollback starts compatible binary or stays stopped/read-only with recovery export.
Do not strip replication fields for old binary; no downgrade migration without proof preserving pending/conflicts/receipts.
Binary rollback and data rollback are separate. Signed membership checkpoint guards device reseed, not arbitrary backup restore.
New epoch/reseed cannot silently discard local pending work; explicit recovery review retains blocked operations.

## Disk and protection
Inherit stricter existing caps; Finance imported8MiB, recurring4MiB, investment8MiB.
Set explicit8MiB cap for currently unbounded small ledger wrappers; no unbounded Data(contentsOf:) before size/stream check.
Training/Calendar/Tax/Planning existing lower limits win; do not enlarge silently to fit metadata.
At capacity reject next save with recoverable draft, retain old bytes; no deleting original PDF/user record/outbox.
Widgets consume after committed domain revision only; same digest means no write/reload.
