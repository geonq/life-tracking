# Revision6 closed replication-domain decision
Planning-only. R6 supersedes R5 references to `UsageSyncAdapter` and `ClipperSyncAdapter`.

## Closed replicated set

`SyncDomain` remains exactly `calendar`, `finance`, `fitness`, `planning`, `tax`.
`SyncStoreKind` remains exactly the R4-15 seventeen values: `calendar`, `financeImports`, `financeRecurring`,
`financeInvestments`, `financeBudgets`, `financeAllocations`, `financePreferences`, `training`,
`trainingTemplates`, `meals`, `nutritionGoals`, `supplements`, `journal`, `lifestyle`, `barcodeRecords`, `vault`,
`tax`. No usage or clipper case, payload, archive specialization, adapter, ACK stream, tombstone stream or
`SyncOperation` is permitted for either feature.
Manual travel is also local-only in R6: `FinanceTravelStore` is a data-management/export surface, not a sixth
replicated domain or a `SyncStoreKind` case. Its local file is covered by R6-02 and is never sent as a sync payload.

## Usage is local-only

The usage watcher is a local presentation/history feature. Its exact owners remain
`UsageCoordinator.refresh() async`, `UsageCoordinator.cancel()`,
`UsageCoordinator.saveUsageManualReading(_ reading: UsageManualReading) -> Bool`,
`UsageCoordinator.saveUsageManualReadings(_ readings: [UsageManualReading]) -> Bool`, and
`UsageCoordinator.deleteUsageManualReadings() -> Bool`, backed by the existing `UsageHistoryPersistence.load/save`.
`UsageHistoryLedger.append` and `delete(provider:window:...)` remain pure ledger mutations before the one local save.
The persistence key/file is the existing local usage-history store; no new sync file is introduced.

The UI labels this source `This device only` when the selected provider is usage. A failed local save retains the
previous history and returns the existing manual-reading failure; refresh cancellation cannot erase history.
There is no Usage payload/archive, replicated deletion, frontier, inbox, or outbox. DA-05A/B therefore move to P12
and are accepted only with local relaunch, duplicate, delete, stale-provider and offline evidence.

## Clipper is read-only gateway data

Clipper has no editable replicated domain. Exact owners are the existing
`ClipperCoordinator.refresh() async`, `retry() async`, `cancel()`, `revokeLocally()`, `clearLocalRevocation()`,
`ClipperStore.ingestLoaded(...)` and `ClipperStore.readCommitted()`.
The gateway/API remains the source of the typed snapshot; local revocation state remains the existing
`UserDefaultsClipperRevocationPersistence` key. A refresh replaces the local read cache only after a validated
snapshot; retry reuses the request identity; revoke clears visible data and blocks refresh until explicit re-enable.

There is no Clipper payload/archive, `ClipperSyncAdapter`, replicated deletion, frontier, inbox, or ACK stream.
DA-07A/B move to P02/P16 and require live-readonly evidence for source, stale, partial, revoke, retry and restart.
The gateway route is still authenticated and bounded; “read-only” does not mean unauthenticated.

## Binding corrections

R4-LEAVES-03 DA-05A/B and DA-07A/B use the local/read-only owners above and no `SyncDomainAdapter` symbol.
R5-01 no longer names either invented adapter. `R4-15`, `R4-16`, `R4-NEW-FEATURES` and the R5 readiness table
must treat these as capability surfaces outside the replicated set. Any future cross-device sync requires a new
revision with a new closed enum, payload, archive, migration and security review; Luna cannot add one opportunistically.

## Revision7 supersession

R7-06 keeps this closed-domain decision. R7-05 is authoritative for the 26 local data-management packs; none of those
added IDs is a replicated `SyncStoreKind`.
