# Wire4TrainingRecordID — sealed value DTO
Source field authority: ios/Shared/FitnessTrainingDomain.swift, TrainingRecordID; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4TrainingRecordID: Codable, Equatable, Sendable {
 public let uuid: String
}
```

```python
@dataclass(frozen=True)
class Wire4TrainingRecordID:
    uuid: str
```

```typescript
interface Wire4TrainingRecordID {
 readonly uuid: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|uuid|lowercase canonical UUID; preserve identity|

Conversion: static func fromDomain(_ value:TrainingRecordID) throws -> Wire4TrainingRecordID; func toDomain() throws -> TrainingRecordID.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
