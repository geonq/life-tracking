# Wire4TrainingTemplateExerciseSnapshot — sealed value DTO
Source field authority: ios/Shared/FitnessTrainingDomain.swift, TrainingTemplateExerciseSnapshot; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4TrainingTemplateExerciseSnapshot: Codable, Equatable, Sendable {
 public let id: String
 public let name: String
 public let muscleGroup: Wire4TrainingMuscleGroup
 public let targetSets: String
 public let targetRepetitions: String
 public let targetLoadKilograms: String?
 public let loadConvention: Wire4TrainingLoadConvention
}
```

```python
@dataclass(frozen=True)
class Wire4TrainingTemplateExerciseSnapshot:
    id: str
    name: str
    muscleGroup: Wire4TrainingMuscleGroup
    targetSets: str
    targetRepetitions: str
    targetLoadKilograms: str | None
    loadConvention: Wire4TrainingLoadConvention
```

```typescript
interface Wire4TrainingTemplateExerciseSnapshot {
 readonly id: string;
 readonly name: string;
 readonly muscleGroup: Wire4TrainingMuscleGroup;
 readonly targetSets: string;
 readonly targetRepetitions: string;
 readonly targetLoadKilograms: string | null;
 readonly loadConvention: Wire4TrainingLoadConvention;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|name|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|muscleGroup|exact nested Wire4TrainingMuscleGroup declaration, recursive validation|
|targetSets|I64 canonical signed decimal; exact Int64 round trip|
|targetRepetitions|I64 canonical signed decimal; exact Int64 round trip|
|targetLoadKilograms|F64(value); finite; preserve exact bits or explicit null|
|loadConvention|exact nested Wire4TrainingLoadConvention declaration, recursive validation|

Conversion: static func fromDomain(_ value:TrainingTemplateExerciseSnapshot) throws -> Wire4TrainingTemplateExerciseSnapshot; func toDomain() throws -> TrainingTemplateExerciseSnapshot.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
