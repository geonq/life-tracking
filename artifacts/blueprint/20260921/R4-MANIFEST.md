# Revision4 manifest — 2026-09-21
Planning-only; verdict READY FOR LUNA. This is implementation-contract readiness, not product/security acceptance.
Source reference remains 321a2b50232cd0e26a975107921b2b4e7498ee0f. No source edits, builds, tests, commits or pushes.
Controller authored revision4; no callable Astra subagent was available. Independent Astra wave review is not claimed complete.

## Corrections from revision3
- Sealed five domain payload/archive families, 57 recursive value sheets, 38 raw enums and two additional template DTOs.
- Fixed canonical codec/signing bytes, native/Windows custody, enrollment, replay, rotation and failure behavior.
- Mapped all258 unique historical requirement IDs plus subsequent requests to packet/functions/evidence.
- Preserved workout-template store separately; defined private Tax publication and barcode-to-meal crash recovery.
- Sealed SQL outbox retry reconstruction, MainActor journal/template ownership and read-only offline health relay.
- Retained baseline iOS17/macOS14; SDK27 enhancements remain guarded with specified baseline fallbacks.
- Added packet readiness, compile-safe unavailable interfaces and mandatory NO-GUESSING dispatch checklist.
No new product decision required; five existing user/device setup categories remain release-evidence gates, not coding choices.
Previous revisions preserved; 00-INDEX-V3.md is the exact pre-revision4 index. R3 readiness remains historical NOT READY.

## Exact files written and historical line counts
All paths below are relative to this directory. R4 remains history; R5 added explicit supersession notes and corrected
function cells in the affected R4 sheets. Every listed file is <=200 lines. R5-MANIFEST is authoritative for R5.
|File|Action|Lines|
|---|---|---:|
|[00-INDEX-V3.md](00-INDEX-V3.md)|added|25|
|[00-INDEX.md](00-INDEX.md)|updated by R5/R6|36|
|[R4-01-VALUE-RULES.md](R4-01-VALUE-RULES.md)|added|52|
|[R4-02-ARCHIVES.md](R4-02-ARCHIVES.md)|added + R5/R6 note|83|
|[R4-03-CALENDAR.md](R4-03-CALENDAR.md)|added + R5/R6 contract|61|
|[R4-04-FINANCE.md](R4-04-FINANCE.md)|added|60|
|[R4-05-FITNESS.md](R4-05-FITNESS.md)|added|69|
|[R4-06-PLANNING.md](R4-06-PLANNING.md)|added + R6 inbox note|78|
|[R4-07-TAX.md](R4-07-TAX.md)|added|57|
|[R4-08-CODEC.md](R4-08-CODEC.md)|added + R5/R6 note|74|
|[R4-09-KEYS.md](R4-09-KEYS.md)|added + R5/R6 note|79|
|[R4-10-TRUST.md](R4-10-TRUST.md)|added + R5/R6 note|69|
|[R4-11-FEATURE-ALGORITHMS.md](R4-11-FEATURE-ALGORITHMS.md)|added + R5/R6 note|92|
|[R4-12-PLATFORM-DEPENDENCIES.md](R4-12-PLATFORM-DEPENDENCIES.md)|added|44|
|[R4-13-SECURITY-EXECUTION.md](R4-13-SECURITY-EXECUTION.md)|added|29|
|[R4-14-TEMPLATES-WIDGETS.md](R4-14-TEMPLATES-WIDGETS.md)|added + R6 note|56|
|[R4-15-TRANSPORT-COMPOSITION.md](R4-15-TRANSPORT-COMPOSITION.md)|added + R5/R6 note|99|
|[R4-16-OWNERSHIP-INTERFACES.md](R4-16-OWNERSHIP-INTERFACES.md)|added + R5/R6 note|72|
|[R4-ENUMS-01.md](R4-ENUMS-01.md)|added|88|
|[R4-ENUMS-02.md](R4-ENUMS-02.md)|added|88|
|[R4-ENUMS-03.md](R4-ENUMS-03.md)|added|88|
|[R4-ENUMS-04.md](R4-ENUMS-04.md)|added|18|
|[R4-LEAVES-01.md](R4-LEAVES-01.md)|added + R5/R6 audit|101|
|[R4-LEAVES-02.md](R4-LEAVES-02.md)|added + R5 audit|97|
|[R4-LEAVES-03.md](R4-LEAVES-03.md)|added + R5 audit|97|
|[R4-MANIFEST.md](R4-MANIFEST.md)|added + R5/R6 note|116|
|[R4-NEW-FEATURES.md](R4-NEW-FEATURES.md)|added|32|
|[R4-NO-GUESSING.md](R4-NO-GUESSING.md)|added + R5/R6 checks|54|
|[R4-READINESS.md](R4-READINESS.md)|added + R5/R6 note|53|
|[R4-RELEASE-INTERFACES.md](R4-RELEASE-INTERFACES.md)|added + R5/R6 contract|64|
|[R4-V-CalendarIconAsset.md](R4-V-CalendarIconAsset.md)|added|44|
|[R4-V-CalendarItem.md](R4-V-CalendarItem.md)|added|84|
|[R4-V-CalendarRecurrenceRule.md](R4-V-CalendarRecurrenceRule.md)|added|40|
|[R4-V-FinanceAllocationRule.md](R4-V-FinanceAllocationRule.md)|added|48|
|[R4-V-FinanceAllocationShare.md](R4-V-FinanceAllocationShare.md)|added|37|
|[R4-V-FinanceCategoryBudget.md](R4-V-FinanceCategoryBudget.md)|added|48|
|[R4-V-FinanceExactDecimal.md](R4-V-FinanceExactDecimal.md)|added|32|
|[R4-V-FinanceImportedInvestmentDetails.md](R4-V-FinanceImportedInvestmentDetails.md)|added|52|
|[R4-V-FinanceImportedMappedIdentity.md](R4-V-FinanceImportedMappedIdentity.md)|added|36|
|[R4-V-FinanceImportedTransaction.md](R4-V-FinanceImportedTransaction.md)|added|80|
|[R4-V-FinanceInvestmentAccountSnapshot.md](R4-V-FinanceInvestmentAccountSnapshot.md)|added|56|
|[R4-V-FinanceInvestmentAccountValuation.md](R4-V-FinanceInvestmentAccountValuation.md)|added|44|
|[R4-V-FinanceInvestmentActivity.md](R4-V-FinanceInvestmentActivity.md)|added|76|
|[R4-V-FinanceInvestmentCashObservation.md](R4-V-FinanceInvestmentCashObservation.md)|added|48|
|[R4-V-FinanceInvestmentHoldingObservation.md](R4-V-FinanceInvestmentHoldingObservation.md)|added|48|
|[R4-V-FinanceInvestmentHoldingValuation.md](R4-V-FinanceInvestmentHoldingValuation.md)|added|40|
|[R4-V-FinanceInvestmentImportReceipt.md](R4-V-FinanceInvestmentImportReceipt.md)|added|52|
|[R4-V-FinanceInvestmentLedger.md](R4-V-FinanceInvestmentLedger.md)|added|40|
|[R4-V-FinanceInvestmentMoney.md](R4-V-FinanceInvestmentMoney.md)|added|36|
|[R4-V-FinanceInvestmentSourceIdentity.md](R4-V-FinanceInvestmentSourceIdentity.md)|added|40|
|[R4-V-FinanceInvestmentValuationEvidence.md](R4-V-FinanceInvestmentValuationEvidence.md)|added|48|
|[R4-V-FinanceRecurringAnchor.md](R4-V-FinanceRecurringAnchor.md)|added|36|
|[R4-V-FinanceRecurringPaymentKey.md](R4-V-FinanceRecurringPaymentKey.md)|added|52|
|[R4-V-FinanceRecurringPaymentOverride.md](R4-V-FinanceRecurringPaymentOverride.md)|added|52|
|[R4-V-FinanceTrackingFrequency.md](R4-V-FinanceTrackingFrequency.md)|added|37|
|[R4-V-FinanceTrackingPreferences.md](R4-V-FinanceTrackingPreferences.md)|added|48|
|[R4-V-FitnessJournalRecord.md](R4-V-FitnessJournalRecord.md)|added|84|
|[R4-V-FitnessLifestyleEvent.md](R4-V-FitnessLifestyleEvent.md)|added|108|
|[R4-V-FitnessLifestyleJournalNote.md](R4-V-FitnessLifestyleJournalNote.md)|added|40|
|[R4-V-FitnessLifestyleLineage.md](R4-V-FitnessLifestyleLineage.md)|added|40|
|[R4-V-FitnessLifestyleSettings.md](R4-V-FitnessLifestyleSettings.md)|added|72|
|[R4-V-FoodEstimateImageHashReference.md](R4-V-FoodEstimateImageHashReference.md)|added|36|
|[R4-V-InventoryEvent.md](R4-V-InventoryEvent.md)|added|76|
|[R4-V-NutritionBarcodeProvenance.md](R4-V-NutritionBarcodeProvenance.md)|added|64|
|[R4-V-NutritionGoal.md](R4-V-NutritionGoal.md)|added|56|
|[R4-V-NutritionMeal.md](R4-V-NutritionMeal.md)|added|96|
|[R4-V-NutritionMealPhotoLineage.md](R4-V-NutritionMealPhotoLineage.md)|added|64|
|[R4-V-NutritionRecord.md](R4-V-NutritionRecord.md)|added|80|
|[R4-V-SupplementActionReceipt.md](R4-V-SupplementActionReceipt.md)|added|60|
|[R4-V-SupplementCorrection.md](R4-V-SupplementCorrection.md)|added|64|
|[R4-V-SupplementDose.md](R4-V-SupplementDose.md)|added|36|
|[R4-V-SupplementForecastAssumptions.md](R4-V-SupplementForecastAssumptions.md)|added|44|
|[R4-V-SupplementNutrientFact.md](R4-V-SupplementNutrientFact.md)|added|52|
|[R4-V-SupplementOccurrence.md](R4-V-SupplementOccurrence.md)|added|60|
|[R4-V-SupplementPlan.md](R4-V-SupplementPlan.md)|added|120|
|[R4-V-SupplementProductLabelNote.md](R4-V-SupplementProductLabelNote.md)|added|36|
|[R4-V-SupplementScalarValue.md](R4-V-SupplementScalarValue.md)|added|45|
|[R4-V-SupplementSchedule.md](R4-V-SupplementSchedule.md)|added|64|
|[R4-V-SupplementSchedulePauseRange.md](R4-V-SupplementSchedulePauseRange.md)|added|36|
|[R4-V-SupplementSnapshot.md](R4-V-SupplementSnapshot.md)|added|56|
|[R4-V-TrainingExerciseLog.md](R4-V-TrainingExerciseLog.md)|added|56|
|[R4-V-TrainingPauseInterval.md](R4-V-TrainingPauseInterval.md)|added|36|
|[R4-V-TrainingRecordID.md](R4-V-TrainingRecordID.md)|added|32|
|[R4-V-TrainingSession.md](R4-V-TrainingSession.md)|added|92|
|[R4-V-TrainingSetLog.md](R4-V-TrainingSetLog.md)|added|60|
|[R4-V-TrainingTemplateExerciseSnapshot.md](R4-V-TrainingTemplateExerciseSnapshot.md)|added|56|
|[R4-V-TrainingTemplateSnapshot.md](R4-V-TrainingTemplateSnapshot.md)|added|40|

## Revision5 supersession

The independent review closure is read first from [R5-MANIFEST.md](R5-MANIFEST.md), [R5-READINESS.md](R5-READINESS.md), and [R5-01-LEAF-AUDIT.md](R5-01-LEAF-AUDIT.md) through [R5-06-BOUNDS.md](R5-06-BOUNDS.md). R5 supersedes only the affected clauses and function cells listed there; this manifest remains the R4 historical inventory.

## Revision6 supersession
The current correction set is [R6-MANIFEST.md](R6-MANIFEST.md) and [R6-READINESS.md](R6-READINESS.md). R6 supersedes
only the listed domain, Planning inbox, recovery, Calendar, release-interface and leaf-binding clauses.
