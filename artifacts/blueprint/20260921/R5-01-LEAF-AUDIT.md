# Revision5 leaf-binding audit — false-owner corrections
Planning-only. This supersedes the function column of the listed R4 leaf rows.
The audit read all 258 rows, compared the requirement noun/verb with the named source owner,
and rejected a generic refresh, view, or storage helper when it could not perform that row.
Generic render functions remain only for rows that are genuinely presentation-only.

## Corrected fitness bindings
|IDs|Owner and exact functions|Durability and acceptance|
|---|---|---|
|BF-0384|`FitnessView.select(_:)`, `FitnessView.applyInitialRouteIfNeeded`, `FitnessPresentationState.receiveExternalRoute`; read `HealthKitFitnessRepository.refresh`, `FitnessLifestyleRepository.refresh`, `NutritionMealStore.meals(on:calendar:)`, `NutritionMealStore.dailyTotals(on:calendar:)`|Route changes are transient; manual journal/lifestyle/meal commands commit through their stores before the next snapshot. Verify every section route, missing source, relaunch and stale refresh.| 
|BF-0392|`FitnessTrainingView.body`, `FitnessTrainingCoordinator.historyProjection(for:)`, `HealthKitFitnessRepository.refresh`|Projection is read-only; imported workout identity remains source-labelled. Verify load/focus/recovery and strength units with no Zepp score fabrication.| 
|BF-0393|`FitnessTrainingView.body`, `FitnessTrainingCoordinator.saveTemplate(_:)`, `deleteTemplate(id:)`, `historyProjection(for:)`|Template command persists before publication; deleting a template leaves session snapshots unchanged. Verify add/edit/delete/relaunch.| 
|BF-0415…BF-0423|`FitnessNutritionView.body`, `NutritionMealStore.meals(on:calendar:)`, `dailyTotals(on:calendar:)`, `NutritionGoalStore.currentGoal(on:calendar:)`, `FitnessNutritionSnapshot.includingLocalMeals(_:for:calendar:)`|Only confirmed meals and dated goals enter totals; drafts, proposals and unavailable glucose stay separate. Verify empty/range/goal/independent-source states.| 
|BF-0427…BF-0432|`FitnessLifestyleRepository.events(on:kind:timeZoneIdentifier:)`, `summary(on:kind:timeZoneIdentifier:)`, `settings(for:)`; `FitnessLifestyleLedgerStore.addQuantity`, `editQuantity`, `addNone`, `addAlcoholFree`, `saveSettings`; `FitnessLifestyleReminderCoordinator.reconcile`|Each fact is an atomic ledger event with local-day/time-zone capture; settings/reminders are separate commits. Verify quick/custom/none, edit/delete, DST, denied permission and relaunch.| 
|BF-0433|`FitnessJournalStore.upsert`, `delete`, `setTagState`; `FitnessView.records(at:)` and `FitnessView.body`|Journal annotation is the durable owner; health refresh only supplies source observations. Verify Active/Sick/Injured/Training-break history and audit after relaunch.| 
All other BF rows retain `FitnessView` plus `HealthKitFitnessRepository.refresh` only where their text is a read-only HealthKit projection;
the acceptance row must name the metric source and unavailable state, never imply that refresh persists a manual fact.

## Corrected finance bindings
|IDs|Owner and exact functions|Durability and acceptance|
|---|---|---|
|RF-01|`FinanceView.body`, `FinanceCoordinator.refresh`, `FinancePresentationState.receiveExternalRoute`|Read-only source snapshot; verify account/search/navigation context.| 
|RF-02|`FinanceAnalyticsView.body`, `FinanceTravelStore.load/append/update/delete`, `FinanceTravelProjection.project`|`finance-travel.json` atomic replace; manual trips are validated and committed before map/count projection. Unknown country data stays unavailable. Verify add/edit/delete/relaunch and Reduce Motion.| 
|RF-03|`FinanceAnalyticsView.body`, `FinanceWealthProjector.project`, `FinanceView.points(for:range:)`|Wealth reads existing observations; spending-abroad/travel remain explicit unavailable until their source exists. Verify no fabricated EUR country inference.| 
|RF-04|`FinanceBudgetStore.setBudget`, `remove(category:)`, `currentBudgets(on:calendar:)`|Dated budget history atomic; verify invalid category/amount, save, cancel, relaunch.| 
|RF-05…RF-06|`FinanceAllocationStore.create`, `update`, `remove`, `preview(incomeCents:)`|Rule mutation atomic; preview is pure and does not persist. Verify percentages, consent and invalid totals.| 
|RF-07|`FinanceWealthProjector.project`, `FinanceInvestmentActivityStore.load`, `upsertAccountSnapshot`|Exact decimal/observation evidence drives projection; verify stale/excluded holdings.| 
|RF-08…RF-11, RF-14…RF-19|`FinanceView.chartState`, `points(for:range:)`, `barBuckets(for:range:)`, `filteredTransactions`, `chartSelectionContext`, `FinanceChartModeViews`|Selection is transient; transaction/category aggregation is source snapshot only. Verify mode/range/scrub/merchant drilldown and no layout jump.| 
|RF-12, RF-20, RF-21|`FinancePresentationState.rememberMainScrollAnchor`, `selectionAfterRefresh`, `receiveExternalRoute`|Route state is restored by stable IDs/range; refresh never resets user context. Verify back, deep link and stale source.| 
|RF-13|`FinanceTrackingPreferencesStore.saveDraft`, `commitDraft`, `discardDraft`, `current`|Draft and committed envelope are distinct atomic states. Verify cancel, no-draft error and relaunch.| 

## Corrected retention, sync and settings bindings
|IDs|Owner and exact functions|Acceptance|
|---|---|---|
|DT-02A|`SyncIdentityStore`, `TaxDocumentStore.save`, `FitnessRetentionSnapshot.validate`; new `StorageProtectionAudit.inspect`|Keychain/file protection is checked per storage class; locked/denied fails closed.| 
|DT-02B|`CalendarStore.save`, `TaxDocumentStore.save`, `PlanningMutationJournal.stageMutationLocked`, each domain `commitReplicated*`|One domain transaction plus atomic file replace; crash before commit leaves old revision.| 
|DT-02C|`LifeOSDataManagement.export`, `restore`, `deleteUserData`; `LifeOSDataStoreRegistry.entries`; `WidgetSnapshotPublisher.publish`|Export/restore/delete enumerates the R6-02 registered stores and widget cache; receipt proves completion. It is not a generic replicated-domain restore.| 
|DT-03A|`NutritionPhotoRetentionPolicy.validateAsset`, `retentionDeadline`, `decision`; `planFitnessCompaction`; `advanceFitnessCompactionPlan`|Three images/meal, 90/365-day clocks, <=500KiB derivative; export/provenance proof precedes removal. Verify pinned/exported assets survive.| 
|DT-03B|`NutritionPhotoRetentionPolicy.storageState`, `FitnessStorageLimits`, `planFitnessCompaction`, `free_bytes`|Thresholds cover database/WAL/cache/log/backup/temp measurements; ingest gate returns before allocation.| 
|DT-03C|`planFitnessCompaction`, `advanceFitnessCompactionPlan`; new `FitnessCompactionExecutor.commit`|Plan→stage→validate→export/provenance→atomic commit; CAS mismatch/disk-full retains source and audit.| 
|ST-02A…ST-02B|`HealthKitProductionBridge.requestReadAuthorization`, `storedStates`, `startObservers`, `HealthKitFitnessRepository.refresh`|Permission/device states are mapped without treating denial as empty data.| 
|ST-03A…ST-03B|`SyncStorageSettingsConfiguration.checkConnection`, `TailscaleSyncClient.requestBankConsent`, `bankConsentStatus`|Gateway owns credentials; status/revoke/retry never expose raw token.| 

## Other leaf classes audited
NU rows now distinguish `saveMealDurably`, `confirmBarcodeProposal`, `confirmPhotoProposal`, `FoodPhotoPreparationCoordinator.makeManifest`,
and `NutritionPhotoRetentionPolicy`; PC rows use `BankReadbackProvider.readback` or the importer, never a Usage descriptor.
DA rows use the typed per-domain adapter/commit functions in R5-03; CA rows use the complete context/intent in R5-03.
HK, SU, US, CL, WG, IA, UX/RM, SG and QA rows were checked and retain their owners because their named functions directly own
the corresponding source, renderer, route, motion token, release verifier, or test lane. QA's shared runner is intentional and not a data owner.
No row may cite `SyncDomainAdapter` alone when a typed domain store function exists.

## Revision6 supersession
R6-01 closes Usage/Clipper outside the replicated enum, R6-02 supplies the travel/data-management signatures, R6-06
supplies the canonical Calendar commit/gesture signatures, and R6-07 is the final audit for every R5-introduced name.
