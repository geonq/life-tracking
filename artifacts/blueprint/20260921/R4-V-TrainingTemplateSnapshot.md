# Wire4TrainingTemplateSnapshot — sealed value DTO
Source field authority: ios/Shared/FitnessTrainingDomain.swift, TrainingTemplateSnapshot; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4TrainingTemplateSnapshot: Codable, Equatable, Sendable {
 public let templateID: String
 public let name: String
 public let exercises: [Wire4TrainingTemplateExerciseSnapshot]
}
```

```python
@dataclass(frozen=True)
class Wire4TrainingTemplateSnapshot:
    templateID: str
    name: str
    exercises: tuple[Wire4TrainingTemplateExerciseSnapshot, ...]
```

```typescript
interface Wire4TrainingTemplateSnapshot {
 readonly templateID: string;
 readonly name: string;
 readonly exercises: ReadonlyArray<Wire4TrainingTemplateExerciseSnapshot>;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|templateID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|name|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|exercises|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|

Conversion: static func fromDomain(_ value:TrainingTemplateSnapshot) throws -> Wire4TrainingTemplateSnapshot; func toDomain() throws -> TrainingTemplateSnapshot.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
