# Wire4FinanceInvestmentValuationEvidence — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentValuationEvidence; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentValuationEvidence: Codable, Equatable, Sendable {
 public let priceSource: String
 public let priceObservedAt: String
 public let fxSource: String?
 public let fxObservedAt: String?
 public let fxRate: Wire4FinanceExactDecimal?
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentValuationEvidence:
    priceSource: str
    priceObservedAt: str
    fxSource: str | None
    fxObservedAt: str | None
    fxRate: Wire4FinanceExactDecimal | None
```

```typescript
interface Wire4FinanceInvestmentValuationEvidence {
 readonly priceSource: string;
 readonly priceObservedAt: string;
 readonly fxSource: string | null;
 readonly fxObservedAt: string | null;
 readonly fxRate: Wire4FinanceExactDecimal | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|priceSource|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|priceObservedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|fxSource|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|fxObservedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|fxRate|exact nested Wire4FinanceExactDecimal declaration, recursive validation or explicit null|

Conversion: static func fromDomain(_ value:FinanceInvestmentValuationEvidence) throws -> Wire4FinanceInvestmentValuationEvidence; func toDomain() throws -> FinanceInvestmentValuationEvidence.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
