# Wire4FinanceInvestmentHoldingValuation — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentHoldingValuation; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentHoldingValuation: Codable, Equatable, Sendable {
 public let nativeValue: Wire4FinanceInvestmentMoney
 public let eurValue: Wire4FinanceInvestmentMoney
 public let evidence: Wire4FinanceInvestmentValuationEvidence
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentHoldingValuation:
    nativeValue: Wire4FinanceInvestmentMoney
    eurValue: Wire4FinanceInvestmentMoney
    evidence: Wire4FinanceInvestmentValuationEvidence
```

```typescript
interface Wire4FinanceInvestmentHoldingValuation {
 readonly nativeValue: Wire4FinanceInvestmentMoney;
 readonly eurValue: Wire4FinanceInvestmentMoney;
 readonly evidence: Wire4FinanceInvestmentValuationEvidence;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|nativeValue|exact nested Wire4FinanceInvestmentMoney declaration, recursive validation|
|eurValue|exact nested Wire4FinanceInvestmentMoney declaration, recursive validation|
|evidence|exact nested Wire4FinanceInvestmentValuationEvidence declaration, recursive validation|

Conversion: static func fromDomain(_ value:FinanceInvestmentHoldingValuation) throws -> Wire4FinanceInvestmentHoldingValuation; func toDomain() throws -> FinanceInvestmentHoldingValuation.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
