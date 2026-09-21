# Wire4FinanceInvestmentMoney — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentMoney; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentMoney: Codable, Equatable, Sendable {
 public let amount: Wire4FinanceExactDecimal
 public let currency: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentMoney:
    amount: Wire4FinanceExactDecimal
    currency: str
```

```typescript
interface Wire4FinanceInvestmentMoney {
 readonly amount: Wire4FinanceExactDecimal;
 readonly currency: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|amount|exact nested Wire4FinanceExactDecimal declaration, recursive validation|
|currency|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|

Conversion: static func fromDomain(_ value:FinanceInvestmentMoney) throws -> Wire4FinanceInvestmentMoney; func toDomain() throws -> FinanceInvestmentMoney.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
