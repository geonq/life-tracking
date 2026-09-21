# Fitness/training/nutrition payload and authority seal
FitnessPayload exact JSON {schemaVersion:1,tag:<closed>,value:<table>}, required3keys; custom Swift Codable enum,
Python frozen tagged dataclass union and TS readonly discriminated union exactly as FinancePayload construction R4-04.
|Tag/store|Value|Stable entity / local filename|
|---|---|---|
|training / FitnessTrainingStore|Wire4TrainingSession|session.id.rawValue / fitness-training-ledger.json|
|meal / NutritionMealStore|Wire4NutritionMeal|meal.id / nutrition-meals.json|
|goal / NutritionGoalStore|Wire4NutritionGoal|goal.id / nutrition-goals.json|
|supplement / SupplementStore|SupplementPlanPayload|plan.id / supplements-v1.json|
|journal / FitnessJournalStore|Wire4FitnessJournalRecord|record.id / fitness-journal.json|
|lifestyleEvent / FitnessLifestyleLedger|Wire4FitnessLifestyleEvent|event.id / fitness-lifestyle-ledger.json|
|lifestyleSettings / same|Wire4FitnessLifestyleSettings|settings:+kind / same|
|barcode / NutritionRecordStore|Wire4NutritionRecord|record.id / nutrition-barcode-records.json|
```swift
public struct SupplementPlanPayload:Codable,Equatable,Sendable {
 public let plan:Wire4SupplementPlan; public let occurrences:[Wire4SupplementOccurrence]
 public let corrections:[Wire4SupplementCorrection]; public let inventoryEvents:[Wire4InventoryEvent]
 public let actionReceipts:[Wire4SupplementActionReceipt]
}
```
```python
@dataclass(frozen=True)
class SupplementPlanPayload:
    plan:Wire4SupplementPlan; occurrences:tuple[Wire4SupplementOccurrence,...]
    corrections:tuple[Wire4SupplementCorrection,...]; inventoryEvents:tuple[Wire4InventoryEvent,...]
    actionReceipts:tuple[Wire4SupplementActionReceipt,...]
```
```typescript
interface SupplementPlanPayload { readonly plan:Wire4SupplementPlan; readonly occurrences:ReadonlyArray<Wire4SupplementOccurrence>; readonly corrections:ReadonlyArray<Wire4SupplementCorrection>; readonly inventoryEvents:ReadonlyArray<Wire4InventoryEvent>; readonly actionReceipts:ReadonlyArray<Wire4SupplementActionReceipt> }
```
All required, no default; related IDs MUST resolve to same plan; arrays<=10000/sorted stable ID, complete aggregate<=32MiB.
Corrections belong plan itself or its occurrence/inventory entity, no unrelated plan overwrite. Unsupported related correction blocks apply.
Taken decrements exactly once through existing action receipt; concurrent changes of SAME plan retain full aggregate conflict,
never silently combine two stock counters. Unrelated plans commute. Repeated button action replays existing receipt.

## Exact adapter/store function boundaries
FitnessPayloadCodec.encode(_ payload:FitnessPayload)throws->Data; decode(_ bytes:Data,kind:SyncStoreKind)throws->FitnessPayload.
FitnessSyncAdapter uses existing store reference; each store adds commitReplication(_ payload:FitnessPayload,operation:SyncOperation?)async throws->SyncCommitReceipt.
Training execute→withPersistenceTransaction→persistCandidate→persistAndVerify remains durability path; remote commit validates
TrainingSession then replaces matching session and freezes applied receipt in same existing candidate. No new TrainingMutation on replay.
Keep sessions/receipts/retiredMutationIDs; wrap with replication. Local command identity and wire mutation identity mapped1:1
by local-only row {commandID:String,mutationID:String} UUIDs; never execute() a received finished command twice.
Meal addConfirmed/correct/softDelete→saveUnlocked; Goal setGoal; Supplement mutate→saveUnlocked; journal upsert/delete/setTagState→persist;
lifestyle addQuantity/correct/delete→mutate→writeState; barcode save→load/replace. All insert replication in candidate before write.
Journal class becomes @MainActor; adapter awaits its commitReplication; records get checked Sendable under R4-16.
Journal nil persistenceURL is rejected identityUnavailable in production; fixture-only policy unchanged for isolated visual tooling.
Raw HealthKit anchors/authorization state never transported. User-approved source-labelled aggregate observations may be projected
for Mac via R4-RELEASE-INTERFACES; no new physiological sample authority in training ledger.

## Barcode and photo authority (no duplicate meal totals)
NutritionRecord retains detailed barcode confirmation/source; confirmed NutritionMeal is sole calorie-total authority.
Add local persisted linkage {recordID:String,mealID:String} both UUID under NutritionMeal envelope, unique recordID/mealID.
Deterministic mealID=first16bytes SHA256('LifeOS/barcode-meal/v1'+NUL+recordID), set RFC4122 version8/variant bits.
Confirmation order: barcode record durable→meal addConfirmed with deterministic ID+linkage→widget publish.
Crash after barcode-only commit recovers by scanning unlinked confirmed records and retrying same mealID; no success until meal commit.
Existing meals with confirmedFromBarcode but no exact record ID remain untouched; never fuzzy-merge by name/time.
Proposals/drafts/photos not in sync/totals; image lineage hashes/IDs only. Provider response always editable proposal until explicit Save.
Photo lineage timestamps strings retain original contract validation; no prompt/credential/raw image leaves in replication archive.
Original photo upload is separate existing consented calorie estimation route with its bounded retention policy.

## Migration/archive/offline
R3 store version changes preserved; arrays converted with old decoders then Wire4 converters; dates exact F64.
FitnessArchive specialized FitnessPayload for ONE kind; include heads/receipts/tombstones and all aggregate payloads.
History store receipts retained, not counted as new sessions; old photos/cache remain device-local, no archive leakage.
Training templates/exercises/set order retained. Completion/edit offline works; Zepp proprietary metrics unsupported, no computed fake parity.
Offline reminders retain exact occurrence/timezone/revision; cancelled/denied OS delivery is not recorded as Taken.
WidgetSnapshotPublisher.mapFitness/mapFitnessWidgets/mapNutrition consume committed sources; no widget writes before meal durable.
Evidence: workout/rest/relaunch/edit, barcode crash-point recovery, photo confirmation/retention/corpus, supplement repeat/DST,
HealthKit physical provenance and source deletions; simulator covers UI/manual workflow only.
