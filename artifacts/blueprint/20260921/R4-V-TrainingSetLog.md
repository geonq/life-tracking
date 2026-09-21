# Wire4TrainingSetLog — sealed value DTO
Source field authority: ios/Shared/FitnessTrainingDomain.swift, TrainingSetLog; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4TrainingSetLog: Codable, Equatable, Sendable {
 public let id: Wire4TrainingRecordID
 public let kind: Wire4TrainingSetKind
 public let targetRepetitions: String?
 public let targetLoadKilograms: String?
 public let actualRepetitions: String?
 public let actualLoadKilograms: String?
 public let isCompleted: Bool
 public let completedAt: String?
}
```

```python
@dataclass(frozen=True)
class Wire4TrainingSetLog:
    id: Wire4TrainingRecordID
    kind: Wire4TrainingSetKind
    targetRepetitions: str | None
    targetLoadKilograms: str | None
    actualRepetitions: str | None
    actualLoadKilograms: str | None
    isCompleted: bool
    completedAt: str | None
```

```typescript
interface Wire4TrainingSetLog {
 readonly id: Wire4TrainingRecordID;
 readonly kind: Wire4TrainingSetKind;
 readonly targetRepetitions: string | null;
 readonly targetLoadKilograms: string | null;
 readonly actualRepetitions: string | null;
 readonly actualLoadKilograms: string | null;
 readonly isCompleted: boolean;
 readonly completedAt: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|exact nested Wire4TrainingRecordID declaration, recursive validation|
|kind|exact nested Wire4TrainingSetKind declaration, recursive validation|
|targetRepetitions|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|targetLoadKilograms|F64(value); finite; preserve exact bits or explicit null|
|actualRepetitions|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|actualLoadKilograms|F64(value); finite; preserve exact bits or explicit null|
|isCompleted|JSON bool, no integer coercion|
|completedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|

Conversion: static func fromDomain(_ value:TrainingSetLog) throws -> Wire4TrainingSetLog; func toDomain() throws -> TrainingSetLog.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
