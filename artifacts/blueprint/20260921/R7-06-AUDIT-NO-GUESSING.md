# Revision7 contradiction audit and no-guessing dispatch sheet
Planning-only. R7 is the current authority. A READY verdict means contracts are implementable; it does not claim that
source code, tests, live credentials, device behavior or security evidence already pass.

## Six R7 corrections

|Blocker|Binding decision|Implementation authority|
|---|---|---|
|Recovery shape|One heterogeneous `RecoveryBundleV3` with all 17 `SyncStoreKind` entries; no per-store import API|R7-01; `RecoveryBundleCodec`, `RecoveryBundleWriter`, `RecoveryBundleImporter`|
|Epoch installation|`SyncEpochEnvelopeV2` is owner-Ed25519 signed; membership hash is only an integrity check|R7-02; `SyncTrustStore.install`|
|Historical bootstrap|One authenticated key index per store, max 10,000 records; no global 100,000 bound|R7-02; `bootstrapHistoricalKeys`, `lookupSourceKey`|
|Ledger authority|`SyncAdapterEnvelopeV2` is the only persisted JSON/Planning wrapper; `SyncLedgerV1` is migration input|R7-03; `SyncDomainAdapter` and `PlanningMutationJournal`|
|Calendar local commits|Local edits allocate a `SyncOperation` inside `CalendarStore`; replicated edits receive one; viewport never commits|R7-04; `commitLocal*`, `commitReplicated*`|
|Data management|Exactly 26 registry packs, including `recoveryImports` and original photo bytes in explicit local export|R7-05; `LifeOSDataManagement`|

The recovery bundle signature is `LifeOS/recovery-bundle/v3`; the epoch signature is
`LifeOS/sync-epoch/v2`. Both use framed canonical bytes and the pinned owner key. The bundle carries the owner-signed
epoch envelope and per-store mapping/checkpoint/key-index data, so a new device never reconstructs trust from filenames,
membership hashes, current wall-clock time or a Tailscale peer name.

## R6 name and leaf audit

|Historical name/row|Final owner and behavior|
|---|---|
|`SyncLedgerV1`|Decode-only input to `SyncEnvelopeMigrator.migrateJSONFile`; never persisted after R7 migration|
|`RecoveryArchiveV2`, `ArchiveImportReceiptV2`|Removed final shapes; use `RecoveryBundleV3` and `RecoveryBundleImportReceiptV3`|
|`SyncTrustRecordV2`|Historical input; final trust is `SyncTrustRecordV3` with signed epochs/indexes|
|`FinanceTravelStore`|Local `load/append/update/delete` in R6-02; pack owner in R7-05, never a sync kind|
|`LifeOSDataManagement`|R7-05 directory pack/restore/delete actor; receipts in `data-management-receipts.json`|
|`CalendarCoordinator.commit(CalendarCommitIntent)`|Historical alias only; new UI calls `commitLocal(CalendarLocalEditIntent)`|
|`SyncDomainAdapter`|R7-03 final method set; `kind: SyncStoreKind`, wrapper-owned inbox/ACK/frontier|
|`StorageProtectionAudit`, `FitnessCompactionExecutor`|R6-07 signatures remain; R7-05 invokes their existing protection/retention evidence|
|`BankReadbackClient`|R6-07 throwing `readback() async throws`; no R7 nonthrowing alias is permitted|
|RF-02 travel|`FinanceAnalyticsView.body`; `FinanceTravelStore.load/append/update/delete`; `FinanceTravelProjection.project`; atomic `finance-travel.json`|
|BF-0384 fitness routes|`FitnessView.select`, `applyInitialRouteIfNeeded`, `FitnessPresentationState.receiveExternalRoute`; reads named HealthKit/lifestyle/nutrition repositories; meal writes stay in meal stores|
|DT-03A photo retention|`NutritionPhotoRetentionPolicy.validateAsset/retentionDeadline/decision`, `planFitnessCompaction`, `advanceFitnessCompactionPlan`, `FitnessCompactionExecutor.commit`; never sync/build helpers|

The full R5 leaf audit remains an evidence ledger, but R6-07 plus these final rows are the binding owner map. A generic
`body` or `refresh` is accepted only when the row is explicitly read-only; no worker may bind a route or retention row
to a similarly named helper. Any absent declaration triggers the R6-07 checkpoint with path, current signature and one
proposed compatibility shim before coding.

## Packet ownership and call graph

|Packet|Sealed authority and first function to implement|
|---|---|
|P00|R4 tokens/config; no data authority|
|P01|R7-02/03/04/01 codec, trust, operation allocator, engine adapter calls|
|P02|R4/R5 transport and Windows relay; receives signed frames only|
|P03|Calendar domain and `CalendarStore.commitLocal*`/`commitReplicated*`|
|P04|Finance and `FinanceSyncAdapter` typed payload/deletion dispatch|
|P05|Finance imports/Enable Banking/live unavailable states|
|P06|Fitness/Nutrition adapters, training, meals, photo retention|
|P07|Design tokens/motion tokens; no persistence|
|P08|Calendar UI reducers/coordinator call path in R7-04|
|P09|Finance views/travel projection and wealth projections|
|P10|Fitness/Nutrition UI, compaction and workout presentation|
|P11|HealthKit/Zepp provenance and physical-device gates|
|P12|Usage local history; no sync adapter; Claude/Gemini provider capability UI|
|P13|Tax sanitized store/typed deletion and raw-data boundary|
|P14|App Intents/Shortcuts/lock-screen/widget projections; no networking in widgets|
|P15|Obsidian/iCloud Planning files and `PlanningMutationJournal`|
|P16|App roots, live/unavailable composition, no advisor AI|
|P17|Signing/App Group/install and Windows outage/reconnect evidence|
|P18|Storage audit, data-management actor and release evidence orchestration|

Call graph for sync is `SyncEngine.synchronizeOnce → adapter.recover → frontier → transport → persistInbox →
applyRemote → enumerateAcknowledgements → recordAcknowledgement → advanceFrontier`. Calendar local UI is
`CalendarItemInteractionReducer.finish → CalendarCoordinator.commitLocal → CalendarStore.commitLocalSeries`; remote
Calendar is `persistInbox → CalendarSyncAdapter.applyRemote → CalendarStore.commitReplicatedSeries/deletion`. Data
management is `LifeOSDataManagement → registry adapter.exportPack/restorePack/deletePack`; no caller decodes a domain.

## Final no-guessing checklist

Before editing source, a Luna worker must:

1. Read R7-01…R7-06 and the owning historical R4/R5 sheet.
2. Use exactly the closed 17 sync kinds and 26 data packs; never add Usage, Clipper or travel to replication.
3. Use the exact v2 wrapper/file or `journal.sqlite` column named by R7-03.
4. Preserve `SyncOperation.storeID` as the closed raw-value string and compare it with `kind.rawValue`.
5. Use the signed epoch and bundle framing bytes; never trust only a membership hash.
6. Enforce 10,000 per-store operation/key/ACK/head/conflict/receipt bounds before decoding arrays.
7. Pass explicit checkpoint, mapping, base head, generation, intent ID and resize edge; never infer identity by label.
8. Use typed `DeleteIntent`/`TombstonePayload`; an empty deletion payload is invalid.
9. Allocate local Calendar operations inside the same file transaction; replicated methods never allocate them.
10. Treat inbox insertion, projection, receipt, ACK and frontier as durable state with the R7 transaction order.
11. Preserve receipt lineage and resume after every crash/cancellation/disk-full boundary.
12. Keep raw Tax and nutrition photos out of sync, widgets and provider requests; only explicit local export may carry bytes.
13. Keep Swift values `Sendable`, actor-isolated and bounded; no detached UI task or per-frame allocation.
14. Stop at the checkpoint when a source signature differs; record evidence instead of inventing a shim.
15. Capture the named acceptance evidence before declaring a packet implemented.

## Revision8 supersession

R8-07 replaces the historical P00–P18 table here with the retained `14-OWNERSHIP.json` dependency/allowlist map.
R8-01…07 are the final contracts for the seven R8 corrections; the leaf binding corrections above remain required.

## Revision8 supersession

R8-07 replaces the historical P00-P18 table here with the retained `14-OWNERSHIP.json` dependency/allowlist map.
R8-01…06 are the final contracts for the seven R8 corrections; the leaf binding corrections above remain required.

## Readiness and external evidence

All P00–P18 have a closed implementation contract after R7-01…06. No architecture decision remains for Luna to choose;
the only unresolved items are evidence requiring the user's environment: actual iCloud vault permission, enrolled public
keys, physical iPhone HealthKit/Zepp behavior, live bank consent/exports, Windows gateway availability/outage recovery,
Personal Team signing/App Group behavior, installed iOS/macOS SDK captures, visual/motion review and final batched
security review. Each has an explicit unavailable/offline compile-safe path. These gates do not weaken schema, ownership,
privacy or migration rules and do not justify demo data.
