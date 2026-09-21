# Wire4FinanceImportedInvestmentDetails — sealed value DTO
Source field authority: ios/Shared/FinanceImportedTransaction.swift, FinanceImportedInvestmentDetails; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceImportedInvestmentDetails: Codable, Equatable, Sendable {
 public let symbol: String?
 public let assetClass: String?
 public let quantity: String?
 public let unitPriceCents: String?
 public let tradeType: String?
 public let currency: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceImportedInvestmentDetails:
    symbol: str | None
    assetClass: str | None
    quantity: str | None
    unitPriceCents: str | None
    tradeType: str | None
    currency: str
```

```typescript
interface Wire4FinanceImportedInvestmentDetails {
 readonly symbol: string | null;
 readonly assetClass: string | null;
 readonly quantity: string | null;
 readonly unitPriceCents: string | null;
 readonly tradeType: string | null;
 readonly currency: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|symbol|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|assetClass|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|quantity|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|unitPriceCents|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|tradeType|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|currency|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|

Conversion: static func fromDomain(_ value:FinanceImportedInvestmentDetails) throws -> Wire4FinanceImportedInvestmentDetails; func toDomain() throws -> FinanceImportedInvestmentDetails.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
