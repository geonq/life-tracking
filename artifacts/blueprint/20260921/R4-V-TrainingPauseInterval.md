# Wire4TrainingPauseInterval — sealed value DTO
Source field authority: ios/Shared/FitnessTrainingDomain.swift, TrainingPauseInterval; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4TrainingPauseInterval: Codable, Equatable, Sendable {
 public let startedAt: String
 public let endedAt: String?
}
```

```python
@dataclass(frozen=True)
class Wire4TrainingPauseInterval:
    startedAt: str
    endedAt: str | None
```

```typescript
interface Wire4TrainingPauseInterval {
 readonly startedAt: string;
 readonly endedAt: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|startedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|endedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|

Conversion: static func fromDomain(_ value:TrainingPauseInterval) throws -> Wire4TrainingPauseInterval; func toDomain() throws -> TrainingPauseInterval.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
