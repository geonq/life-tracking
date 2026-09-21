# Wire4FinanceInvestmentHoldingObservation — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentHoldingObservation; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentHoldingObservation: Codable, Equatable, Sendable {
 public let id: String
 public let assetIdentifier: String
 public let quantity: Wire4FinanceExactDecimal
 public let assetCurrency: String
 public let valuation: Wire4FinanceInvestmentHoldingValuation?
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentHoldingObservation:
    id: str
    assetIdentifier: str
    quantity: Wire4FinanceExactDecimal
    assetCurrency: str
    valuation: Wire4FinanceInvestmentHoldingValuation | None
```

```typescript
interface Wire4FinanceInvestmentHoldingObservation {
 readonly id: string;
 readonly assetIdentifier: string;
 readonly quantity: Wire4FinanceExactDecimal;
 readonly assetCurrency: string;
 readonly valuation: Wire4FinanceInvestmentHoldingValuation | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|assetIdentifier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|quantity|exact nested Wire4FinanceExactDecimal declaration, recursive validation|
|assetCurrency|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|valuation|exact nested Wire4FinanceInvestmentHoldingValuation declaration, recursive validation or explicit null|

Conversion: static func fromDomain(_ value:FinanceInvestmentHoldingObservation) throws -> Wire4FinanceInvestmentHoldingObservation; func toDomain() throws -> FinanceInvestmentHoldingObservation.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
