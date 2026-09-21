# Wire4FinanceInvestmentActivity — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentActivity; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentActivity: Codable, Equatable, Sendable {
 public let id: String
 public let source: Wire4FinanceInvestmentSourceIdentity
 public let observedAt: String
 public let kind: Wire4FinanceInvestmentActivityKind
 public let rawTransactionType: String
 public let instrument: String
 public let quantity: Wire4FinanceExactDecimal?
 public let instrumentPrice: Wire4FinanceInvestmentMoney?
 public let fees: Wire4FinanceInvestmentMoney?
 public let debit: Wire4FinanceInvestmentMoney?
 public let credit: Wire4FinanceInvestmentMoney?
 public let sourceRowNumber: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentActivity:
    id: str
    source: Wire4FinanceInvestmentSourceIdentity
    observedAt: str
    kind: Wire4FinanceInvestmentActivityKind
    rawTransactionType: str
    instrument: str
    quantity: Wire4FinanceExactDecimal | None
    instrumentPrice: Wire4FinanceInvestmentMoney | None
    fees: Wire4FinanceInvestmentMoney | None
    debit: Wire4FinanceInvestmentMoney | None
    credit: Wire4FinanceInvestmentMoney | None
    sourceRowNumber: str
```

```typescript
interface Wire4FinanceInvestmentActivity {
 readonly id: string;
 readonly source: Wire4FinanceInvestmentSourceIdentity;
 readonly observedAt: string;
 readonly kind: Wire4FinanceInvestmentActivityKind;
 readonly rawTransactionType: string;
 readonly instrument: string;
 readonly quantity: Wire4FinanceExactDecimal | null;
 readonly instrumentPrice: Wire4FinanceInvestmentMoney | null;
 readonly fees: Wire4FinanceInvestmentMoney | null;
 readonly debit: Wire4FinanceInvestmentMoney | null;
 readonly credit: Wire4FinanceInvestmentMoney | null;
 readonly sourceRowNumber: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|source|exact nested Wire4FinanceInvestmentSourceIdentity declaration, recursive validation|
|observedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|kind|exact nested Wire4FinanceInvestmentActivityKind declaration, recursive validation|
|rawTransactionType|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|instrument|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|quantity|exact nested Wire4FinanceExactDecimal declaration, recursive validation or explicit null|
|instrumentPrice|exact nested Wire4FinanceInvestmentMoney declaration, recursive validation or explicit null|
|fees|exact nested Wire4FinanceInvestmentMoney declaration, recursive validation or explicit null|
|debit|exact nested Wire4FinanceInvestmentMoney declaration, recursive validation or explicit null|
|credit|exact nested Wire4FinanceInvestmentMoney declaration, recursive validation or explicit null|
|sourceRowNumber|I64 canonical signed decimal; exact Int64 round trip|

Conversion: static func fromDomain(_ value:FinanceInvestmentActivity) throws -> Wire4FinanceInvestmentActivity; func toDomain() throws -> FinanceInvestmentActivity.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
