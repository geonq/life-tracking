# Wire4NutritionBarcodeProvenance — sealed value DTO
Source field authority: ios/Shared/NutritionBarcode.swift, NutritionBarcodeProvenance; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4NutritionBarcodeProvenance: Codable, Equatable, Sendable {
 public let source: String
 public let apiVersion: String
 public let apiURL: String
 public let productURL: String?
 public let fetchedAt: String
 public let databaseLicense: String
 public let contentLicense: String
 public let attribution: String
 public let dataQualityWarning: String
}
```

```python
@dataclass(frozen=True)
class Wire4NutritionBarcodeProvenance:
    source: str
    apiVersion: str
    apiURL: str
    productURL: str | None
    fetchedAt: str
    databaseLicense: str
    contentLicense: str
    attribution: str
    dataQualityWarning: str
```

```typescript
interface Wire4NutritionBarcodeProvenance {
 readonly source: string;
 readonly apiVersion: string;
 readonly apiURL: string;
 readonly productURL: string | null;
 readonly fetchedAt: string;
 readonly databaseLicense: string;
 readonly contentLicense: string;
 readonly attribution: string;
 readonly dataQualityWarning: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|source|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|apiVersion|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|apiURL|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|productURL|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|fetchedAt|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|databaseLicense|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|contentLicense|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|attribution|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|dataQualityWarning|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|

Conversion: static func fromDomain(_ value:NutritionBarcodeProvenance) throws -> Wire4NutritionBarcodeProvenance; func toDomain() throws -> NutritionBarcodeProvenance.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
