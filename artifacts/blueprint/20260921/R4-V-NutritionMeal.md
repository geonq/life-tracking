# Wire4NutritionMeal — sealed value DTO
Source field authority: ios/Shared/NutritionMealDomain.swift, NutritionMeal; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4NutritionMeal: Codable, Equatable, Sendable {
 public let id: String
 public let loggedAt: String
 public let timeZoneIdentifier: String?
 public let name: String
 public let kcal: String?
 public let proteinGrams: String?
 public let carbGrams: String?
 public let fatGrams: String?
 public let portionGrams: String?
 public let portionUnit: Wire4FoodUnit?
 public let journalNote: String?
 public let provenance: Wire4NutritionMealProvenance
 public let createdAt: String
 public let revision: String
 public let supersedesID: String?
 public let deletedAt: String?
 public let photoLineage: Wire4NutritionMealPhotoLineage?
}
```

```python
@dataclass(frozen=True)
class Wire4NutritionMeal:
    id: str
    loggedAt: str
    timeZoneIdentifier: str | None
    name: str
    kcal: str | None
    proteinGrams: str | None
    carbGrams: str | None
    fatGrams: str | None
    portionGrams: str | None
    portionUnit: Wire4FoodUnit | None
    journalNote: str | None
    provenance: Wire4NutritionMealProvenance
    createdAt: str
    revision: str
    supersedesID: str | None
    deletedAt: str | None
    photoLineage: Wire4NutritionMealPhotoLineage | None
```

```typescript
interface Wire4NutritionMeal {
 readonly id: string;
 readonly loggedAt: string;
 readonly timeZoneIdentifier: string | null;
 readonly name: string;
 readonly kcal: string | null;
 readonly proteinGrams: string | null;
 readonly carbGrams: string | null;
 readonly fatGrams: string | null;
 readonly portionGrams: string | null;
 readonly portionUnit: Wire4FoodUnit | null;
 readonly journalNote: string | null;
 readonly provenance: Wire4NutritionMealProvenance;
 readonly createdAt: string;
 readonly revision: string;
 readonly supersedesID: string | null;
 readonly deletedAt: string | null;
 readonly photoLineage: Wire4NutritionMealPhotoLineage | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|lowercase canonical UUID; preserve identity|
|loggedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|timeZoneIdentifier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|name|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|kcal|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|proteinGrams|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|carbGrams|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|fatGrams|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|portionGrams|F64(value); finite; preserve exact bits or explicit null|
|portionUnit|exact nested Wire4FoodUnit declaration, recursive validation or explicit null|
|journalNote|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|provenance|exact nested Wire4NutritionMealProvenance declaration, recursive validation|
|createdAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|revision|I64 canonical signed decimal; exact Int64 round trip|
|supersedesID|lowercase canonical UUID; preserve identity or explicit null|
|deletedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|photoLineage|exact nested Wire4NutritionMealPhotoLineage declaration, recursive validation or explicit null|

Conversion: static func fromDomain(_ value:NutritionMeal) throws -> Wire4NutritionMeal; func toDomain() throws -> NutritionMeal.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
