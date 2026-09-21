# Wire4FinanceInvestmentAccountSnapshot — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentAccountSnapshot; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentAccountSnapshot: Codable, Equatable, Sendable {
 public let source: Wire4FinanceInvestmentSourceIdentity
 public let observedAt: String
 public let verifiedCash: Wire4FinanceInvestmentCashObservation?
 public let holdings: [Wire4FinanceInvestmentHoldingObservation]
 public let cashCoverage: Wire4FinanceInvestmentAccountCoverage
 public let holdingsCoverage: Wire4FinanceInvestmentAccountCoverage
 public let totalValuation: Wire4FinanceInvestmentAccountValuation?
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentAccountSnapshot:
    source: Wire4FinanceInvestmentSourceIdentity
    observedAt: str
    verifiedCash: Wire4FinanceInvestmentCashObservation | None
    holdings: tuple[Wire4FinanceInvestmentHoldingObservation, ...]
    cashCoverage: Wire4FinanceInvestmentAccountCoverage
    holdingsCoverage: Wire4FinanceInvestmentAccountCoverage
    totalValuation: Wire4FinanceInvestmentAccountValuation | None
```

```typescript
interface Wire4FinanceInvestmentAccountSnapshot {
 readonly source: Wire4FinanceInvestmentSourceIdentity;
 readonly observedAt: string;
 readonly verifiedCash: Wire4FinanceInvestmentCashObservation | null;
 readonly holdings: ReadonlyArray<Wire4FinanceInvestmentHoldingObservation>;
 readonly cashCoverage: Wire4FinanceInvestmentAccountCoverage;
 readonly holdingsCoverage: Wire4FinanceInvestmentAccountCoverage;
 readonly totalValuation: Wire4FinanceInvestmentAccountValuation | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|source|exact nested Wire4FinanceInvestmentSourceIdentity declaration, recursive validation|
|observedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|verifiedCash|exact nested Wire4FinanceInvestmentCashObservation declaration, recursive validation or explicit null|
|holdings|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|cashCoverage|exact nested Wire4FinanceInvestmentAccountCoverage declaration, recursive validation|
|holdingsCoverage|exact nested Wire4FinanceInvestmentAccountCoverage declaration, recursive validation|
|totalValuation|exact nested Wire4FinanceInvestmentAccountValuation declaration, recursive validation or explicit null|

Conversion: static func fromDomain(_ value:FinanceInvestmentAccountSnapshot) throws -> Wire4FinanceInvestmentAccountSnapshot; func toDomain() throws -> FinanceInvestmentAccountSnapshot.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
