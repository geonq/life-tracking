# Wire4NutritionGoal — sealed value DTO
Source field authority: ios/Shared/NutritionGoalDomain.swift, NutritionGoal; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4NutritionGoal: Codable, Equatable, Sendable {
 public let id: String
 public let effectiveFrom: String
 public let calorieTarget: String?
 public let proteinGramsTarget: String?
 public let carbGramsTarget: String?
 public let fatGramsTarget: String?
 public let createdAt: String
}
```

```python
@dataclass(frozen=True)
class Wire4NutritionGoal:
    id: str
    effectiveFrom: str
    calorieTarget: str | None
    proteinGramsTarget: str | None
    carbGramsTarget: str | None
    fatGramsTarget: str | None
    createdAt: str
```

```typescript
interface Wire4NutritionGoal {
 readonly id: string;
 readonly effectiveFrom: string;
 readonly calorieTarget: string | null;
 readonly proteinGramsTarget: string | null;
 readonly carbGramsTarget: string | null;
 readonly fatGramsTarget: string | null;
 readonly createdAt: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|lowercase canonical UUID; preserve identity|
|effectiveFrom|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|calorieTarget|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|proteinGramsTarget|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|carbGramsTarget|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|fatGramsTarget|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|createdAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:NutritionGoal) throws -> Wire4NutritionGoal; func toDomain() throws -> NutritionGoal.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
