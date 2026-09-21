# Wire4FinanceInvestmentCashObservation — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentCashObservation; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentCashObservation: Codable, Equatable, Sendable {
 public let amount: Wire4FinanceInvestmentMoney
 public let observedAt: String
 public let source: String
 public let verificationID: String
 public let consolidationKey: String?
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentCashObservation:
    amount: Wire4FinanceInvestmentMoney
    observedAt: str
    source: str
    verificationID: str
    consolidationKey: str | None
```

```typescript
interface Wire4FinanceInvestmentCashObservation {
 readonly amount: Wire4FinanceInvestmentMoney;
 readonly observedAt: string;
 readonly source: string;
 readonly verificationID: string;
 readonly consolidationKey: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|amount|exact nested Wire4FinanceInvestmentMoney declaration, recursive validation|
|observedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|source|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|verificationID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|consolidationKey|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|

Conversion: static func fromDomain(_ value:FinanceInvestmentCashObservation) throws -> Wire4FinanceInvestmentCashObservation; func toDomain() throws -> FinanceInvestmentCashObservation.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
