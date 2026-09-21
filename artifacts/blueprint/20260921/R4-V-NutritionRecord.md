# Wire4NutritionRecord — sealed value DTO
Source field authority: ios/Shared/NutritionBarcode.swift, NutritionRecord; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4NutritionRecord: Codable, Equatable, Sendable {
 public let id: String
 public let proposalID: String
 public let barcode: String
 public let basis: Wire4NutritionBarcodeBasis
 public let productName: String?
 public let grams: String?
 public let kcal: String?
 public let proteinGrams: String?
 public let carbsGrams: String?
 public let fatGrams: String?
 public let mealAt: String
 public let confirmedAt: String
 public let source: Wire4NutritionBarcodeProvenance
}
```

```python
@dataclass(frozen=True)
class Wire4NutritionRecord:
    id: str
    proposalID: str
    barcode: str
    basis: Wire4NutritionBarcodeBasis
    productName: str | None
    grams: str | None
    kcal: str | None
    proteinGrams: str | None
    carbsGrams: str | None
    fatGrams: str | None
    mealAt: str
    confirmedAt: str
    source: Wire4NutritionBarcodeProvenance
```

```typescript
interface Wire4NutritionRecord {
 readonly id: string;
 readonly proposalID: string;
 readonly barcode: string;
 readonly basis: Wire4NutritionBarcodeBasis;
 readonly productName: string | null;
 readonly grams: string | null;
 readonly kcal: string | null;
 readonly proteinGrams: string | null;
 readonly carbsGrams: string | null;
 readonly fatGrams: string | null;
 readonly mealAt: string;
 readonly confirmedAt: string;
 readonly source: Wire4NutritionBarcodeProvenance;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|lowercase canonical UUID; preserve identity|
|proposalID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|barcode|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|basis|exact nested Wire4NutritionBarcodeBasis declaration, recursive validation|
|productName|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|grams|F64(value); finite; preserve exact bits or explicit null|
|kcal|F64(value); finite; preserve exact bits or explicit null|
|proteinGrams|F64(value); finite; preserve exact bits or explicit null|
|carbsGrams|F64(value); finite; preserve exact bits or explicit null|
|fatGrams|F64(value); finite; preserve exact bits or explicit null|
|mealAt|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|confirmedAt|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|source|exact nested Wire4NutritionBarcodeProvenance declaration, recursive validation|

Conversion: static func fromDomain(_ value:NutritionRecord) throws -> Wire4NutritionRecord; func toDomain() throws -> NutritionRecord.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
