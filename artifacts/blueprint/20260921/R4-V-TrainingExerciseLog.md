# Wire4TrainingExerciseLog — sealed value DTO
Source field authority: ios/Shared/FitnessTrainingDomain.swift, TrainingExerciseLog; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4TrainingExerciseLog: Codable, Equatable, Sendable {
 public let id: Wire4TrainingRecordID
 public let templateExerciseID: String?
 public let name: String
 public let muscleGroup: Wire4TrainingMuscleGroup
 public let loadConvention: Wire4TrainingLoadConvention
 public let sets: [Wire4TrainingSetLog]
 public let notes: String?
}
```

```python
@dataclass(frozen=True)
class Wire4TrainingExerciseLog:
    id: Wire4TrainingRecordID
    templateExerciseID: str | None
    name: str
    muscleGroup: Wire4TrainingMuscleGroup
    loadConvention: Wire4TrainingLoadConvention
    sets: tuple[Wire4TrainingSetLog, ...]
    notes: str | None
```

```typescript
interface Wire4TrainingExerciseLog {
 readonly id: Wire4TrainingRecordID;
 readonly templateExerciseID: string | null;
 readonly name: string;
 readonly muscleGroup: Wire4TrainingMuscleGroup;
 readonly loadConvention: Wire4TrainingLoadConvention;
 readonly sets: ReadonlyArray<Wire4TrainingSetLog>;
 readonly notes: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|exact nested Wire4TrainingRecordID declaration, recursive validation|
|templateExerciseID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|name|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|muscleGroup|exact nested Wire4TrainingMuscleGroup declaration, recursive validation|
|loadConvention|exact nested Wire4TrainingLoadConvention declaration, recursive validation|
|sets|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|notes|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|

Conversion: static func fromDomain(_ value:TrainingExerciseLog) throws -> Wire4TrainingExerciseLog; func toDomain() throws -> TrainingExerciseLog.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
