# Additional training-template store and widget projection seal
Source inspection found a separate existing template store; it MUST NOT be missed by session-only replication.
P04 allowlist adds ios/Shared/FitnessStrengthDomain.swift for store section/converters; P10 retains existing UI.
Enrolled store kind adds trainingTemplates in domain fitness; FitnessPayload adds tag trainingTemplate with value below.
```swift
public struct Wire4FitnessStrengthExercise:Codable,Equatable,Sendable {
 public let id:String; public let name:String; public let muscleGroup:String
 public let sets:String; public let repetitions:String; public let loadKilograms:String?
}
public struct Wire4FitnessStrengthTemplate:Codable,Equatable,Sendable {
 public let id:String; public let name:String; public let exercises:[Wire4FitnessStrengthExercise]
 public let createdAt:String; public let updatedAt:String
}
```
```python
@dataclass(frozen=True)
class Wire4FitnessStrengthExercise:
    id:str; name:str; muscleGroup:str; sets:str; repetitions:str; loadKilograms:str|None
@dataclass(frozen=True)
class Wire4FitnessStrengthTemplate:
    id:str; name:str; exercises:tuple[Wire4FitnessStrengthExercise,...]; createdAt:str; updatedAt:str
```
```typescript
interface Wire4FitnessStrengthExercise { readonly id:string; readonly name:string; readonly muscleGroup:"arms"|"core"|"chest"|"back"|"legs"|"shoulders"; readonly sets:string; readonly repetitions:string; readonly loadKilograms:string|null }
interface Wire4FitnessStrengthTemplate { readonly id:string; readonly name:string; readonly exercises:ReadonlyArray<Wire4FitnessStrengthExercise>; readonly createdAt:string; readonly updatedAt:string }
```
All required/no defaults, R4-01 numeric/date conversion; source IDs preserve exact original case/string (not necessarily UUID).
IDs1...128ASCII alnum followed alnum/-/_; name nonblank<=100UTF16; exercises<=100, unique IDs, order retained;
sets/reps exact I64 checked existing FitnessStrengthExercise initializer, optional load finite nonnegative F64.
Wire4FitnessStrengthTemplate.fromDomain(_:) and toDomain() fieldwise, calls FitnessStrengthTemplate.validate.
FitnessTrainingCoordinator.saveTemplate→templateStore.upsert; deleteTemplate→templateStore.delete(id:).
FitnessStrengthTemplateStore adds commitReplication(_ payload:FitnessPayload,operation:SyncOperation?)async throws->SyncCommitReceipt
inside existing serialization path; persist writes wrapper {schemaVersion:1,templates:[FitnessStrengthTemplate],replication:SyncAdapterEnvelope}.
Existing raw-array ISO8601 file fitness-strength-templates.json migrates once, validate all old IDs/exercises/dates before wrapper;
no in-memory templates published before durable success. Add bounded read before Data allocation; original maximumPersistenceBytes
applies to templates subsection,32MiB metadata wrapper. Existing observation notifications delivered after commit on MainActor.
Template store class is @MainActor, including init/upsert/delete/persist; existing upsert/delete signatures remain synchronous throws.
Adapter awaits its async commitReplication; method has no internal await between candidate creation and atomic write/publication.
Coordinator/UI calls remain on MainActor. This supersedes private-writer extraction; no second file owner or redundant facade.
Delete keeps template tombstone; sessions retain immutable templateSnapshot, never retroactively mutate historical sessions.
FitnessArchive for trainingTemplates uses exact trainingTemplate variant, same archive/receipt rules; sync works offline.

## Separate widget snapshots (NOT operation/domain archives)
FutureWidgetSnapshot current schema1 fields: schemaVersion:Int,generatedAt:Date,privacyMode:WidgetPrivacyMode,
finance:WidgetSafeFinanceSummary,fitness:WidgetSafeFitnessSummary,fitnessWidgets:WidgetSafeFitnessWidgetsSummary,
nutrition:WidgetSafeNutritionSummary. Retain exact current Codable implementations/keys and optional legacy defaults.
No new fields/version needed for R4; write with existing WidgetSnapshotPublisher.publish and protected App Group URL.
CalendarWidgetProvider reads CalendarSnapshot; LifeOSTimelineProvider reads SharedSnapshotStore WidgetSnapshot;
FutureModuleTimelineProvider.getTimeline reads FutureWidgetSnapshot. Preserve separate source authorities.
mapFinance/mapFitness/mapFitnessWidgets/mapNutrition only after accepted source commit, content digest no-op skips writes/reloads.
No transport signer/privatekey/outbox/health anchor in extensions. Unknown future snapshot schema shows unavailable, never decode guessed defaults.
This projection cannot serve as canonical HealthKit or bank ledger for replication; it is a bounded rendering cache.

## Revision6 supersession
R6-05 requires the widget projection to be durable before a recovery import reports `committed`; it remains a projection,
never a source of truth or an authority for Usage/Clipper replication.
