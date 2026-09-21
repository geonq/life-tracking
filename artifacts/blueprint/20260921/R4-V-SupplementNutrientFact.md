# Wire4SupplementNutrientFact — sealed value DTO
Source field authority: ios/Shared/SupplementDomain.swift, SupplementNutrientFact; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementNutrientFact: Codable, Equatable, Sendable {
 public let nutrientID: String
 public let name: String
 public let amountPerUnit: String
 public let unit: String
 public let labelBasisUnits: String?
 public let nrvPercent: String?
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementNutrientFact:
    nutrientID: str
    name: str
    amountPerUnit: str
    unit: str
    labelBasisUnits: str | None
    nrvPercent: str | None
```

```typescript
interface Wire4SupplementNutrientFact {
 readonly nutrientID: string;
 readonly name: string;
 readonly amountPerUnit: string;
 readonly unit: string;
 readonly labelBasisUnits: string | null;
 readonly nrvPercent: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|nutrientID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|name|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|amountPerUnit|F64(value); finite; preserve exact bits|
|unit|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|labelBasisUnits|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|nrvPercent|F64(value); finite; preserve exact bits or explicit null|

Conversion: static func fromDomain(_ value:SupplementNutrientFact) throws -> Wire4SupplementNutrientFact; func toDomain() throws -> SupplementNutrientFact.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
