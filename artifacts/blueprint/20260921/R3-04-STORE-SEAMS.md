# Concrete store integration and decoder authority
All paths repository-relative. Existing symbols below inspected, not invented worker APIs.
Protocol raw payload schema is exact EXISTING validated DTO serialization only after CP-S field whitelist seals it.
Do not permit JSON arbitrary object decoder, whole-store-overwrite operation, or generic model reflection.

|Logical kind/domain|Existing file and call order (entry→durability)|Per-entity payload authority / gate|
|---|---|---|
|calendar/calendar|ios/Shared/CalendarCoordinator.swift save/delete→performPersist; CalendarStore.swift mutate→load→save|CalendarItem; CP-S01 groups recurrence master/exceptions atomically|
|financeImports/finance|FinanceImportedTransactionStore.swift commitPreparedImport→commitTransactions→saveStateUnlocked|FinanceImportedTransaction; CP-S02 existing attempted receipt/revision mapping|
|financeRecurring/finance|FinanceRecurringPaymentStore.swift saveOverride/clearOverride→saveUnlocked|FinanceRecurringPaymentOverride; evidenceCache local derived, not user op|
|financeInvestments/finance|FinanceInvestmentActivityStore.swift merge/upsertAccountSnapshot→saveUnlocked|FinanceInvestmentLedger typed activity/snapshot variants; CP-S02 exact variant keys|
|financeBudgets/finance|FinanceBudgetStore.swift setBudget/remove→saveUnlocked|FinanceCategoryBudget dated rows; removal preserves historical contract|
|financeAllocations/finance|FinanceAllocationStore.swift create/update/remove→saveUnlocked|FinanceAllocationRule|
|financePreferences/finance|FinanceTrackingPreferencesStore.swift commit/commitDraft→saveUnlocked|FinanceTrackingPreferences committed only; saveDraft no transport|
|training/fitness|FitnessTrainingStore.swift execute→withPersistenceTransaction→persistCandidate→persistAndVerify→replaceData|TrainingSession/TrainingMutation validated lineage, CP-S03 maps receipt not new ledger|
|meals/fitness|NutritionMealStore.swift addConfirmed/correct/softDelete→saveUnlocked|NutritionMeal confirmed only|
|nutritionGoals/fitness|NutritionGoalStore.swift setGoal→saveUnlocked|NutritionGoal|
|supplements/fitness|SupplementStore.swift mutate→saveUnlocked; actionReceipts retained|SupplementSnapshot changes + occurrence receipt; CP-S03 entity partition avoids inventory race|
|journal/fitness|FitnessJournalStore.swift upsert/delete/setTagState→persist|FitnessJournalRecord; convert array wrapper, no nil-path success in production|
|lifestyle/fitness|FitnessLifestyleLedger.swift addQuantity/correct/delete→mutate→writeState|FitnessLifestyleEvent/settings, retain lineage/readOnlyError|
|barcodeRecords/fitness|NutritionBarcode.swift NutritionRecordStore.save→load→temp/replace|NutritionRecord; CP-S03 linkage to confirmed meal to prevent totals duplication|
|vault/planning|PlanningVaultStore.swift read→stage→publish; resolveConflict/publishPendingPage|PlanningMutationRequest+content version; CP-S04 exact journal/inbox transaction|
|tax/tax|TaxDocuments.swift TaxDocumentStore.save/delete→persist|TaxPublicationRecord whitelist R2-P13, CP-S05 exact tax IDs/fields mapping|

All unqualified store filenames above are ios/Shared/. P03/P04/P06/P13 existing-file owners retained.
NEW allowlist amendment: P04 owns ios/Shared/NutritionBarcode.swift store section only; P10 consumes public API.
P16 owns ios/Shared/ClipperCoordinator.swift only for composition fixes after CP-F01; existing provider authority retained.
P02 owns services/api/src/nutrition-photo.ts and services/api/src/clipper-store.ts for proven gateway/collector gaps,
not a new services/gateway/nutrition.py. P15 security findings return to P02 for those files.
P01 owns SyncAdapterEnvelope and SyncDomainAdapter; every store owner implements same exact adapter methods:
recover() async throws; pendingPage(after:String?,limit:Int) async throws -> [SyncOperation];
applyRemote(_ operation:SyncOperation) async throws -> SyncCommitReceipt;
recordAcknowledgement(_ ack:SyncAck) async throws; checkpoint(_ frontier:SyncFrontier) async throws -> SyncCheckpointReceipt.
The obsolete SyncPage placeholder is replaced by [SyncOperation]; after is local opaque bounded cursor<=256bytes,
CP-S defines exact cursor as base64url C({originID,sequence}) for the selected store; no network trust implied.
All adapter methods actor-isolated; synchronous locked store methods execute on owned actor, not MainActor disk work.

## Genuinely unsealed domain mappings — pre-code Astra actions
CP-S01: inspect CalendarSnapshot/CalendarItem and actual recurrence edit helpers, define series command payload schema and rollback fixture.
CP-S02: enumerate exact finance DTO CodingKeys, activity variants, legacy revision→entity-head conversion; immutable payload map.
CP-S03: enumerate training/supplement/meal/barcode keys, define export/occurrence lineage and multi-record atomic aggregate.
CP-S04: exact journal symbols and reviewed allowlist now in R3-06; seal additive SQL and publication ACK recovery boundary.
CP-S05: inspect TaxDocument.id/amount/reference keys; complete sanitized payload and protected raw-cache migration mapping.
Each result is a <=200-line per-domain coding-key table with types/bounds/defaults and signed operation→existing reducer call.
Until these five tables exist, domain payload schemas are NOT sealed; Luna cannot infer field names from broad DTO names.

## Widget/gateway seams already exact
WidgetSnapshotPublisher.publish(finance:fitness:fitnessWidgets:nutrition:privacyMode:now:onWriteFailure:)->Bool
maps via mapFinance/mapFitness/mapFitnessWidgets/mapNutrition; contentEquals excludes generatedAt.
P14 executes after domain commit, never network arrival. false can mean unchanged OR failure; inspect failure callback.
Gateway main.py require_tailscale_identity→new replication handler→ReplicationStore transaction→signed reply.
Current get_nutrition_barcode/post_nutrition_photo_proposal and _validate_clipper_snapshot remain independent provider routes.
Tax raw data must fail encoder whitelist before generic SyncPayload is created; decoder repeats whitelist check.
