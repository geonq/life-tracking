# Wire4FinanceCategoryBudget — sealed value DTO
Source field authority: ios/Shared/FinanceBudgetDomain.swift, FinanceCategoryBudget; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceCategoryBudget: Codable, Equatable, Sendable {
 public let id: String
 public let category: Wire4FinanceTransactionCategory
 public let monthlyLimitCents: String
 public let effectiveFrom: String
 public let createdAt: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceCategoryBudget:
    id: str
    category: Wire4FinanceTransactionCategory
    monthlyLimitCents: str
    effectiveFrom: str
    createdAt: str
```

```typescript
interface Wire4FinanceCategoryBudget {
 readonly id: string;
 readonly category: Wire4FinanceTransactionCategory;
 readonly monthlyLimitCents: string;
 readonly effectiveFrom: string;
 readonly createdAt: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|lowercase canonical UUID; preserve identity|
|category|exact nested Wire4FinanceTransactionCategory declaration, recursive validation|
|monthlyLimitCents|I64 canonical signed decimal; exact Int64 round trip|
|effectiveFrom|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|createdAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:FinanceCategoryBudget) throws -> Wire4FinanceCategoryBudget; func toDomain() throws -> FinanceCategoryBudget.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
