# Wire4FinanceInvestmentLedger — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentLedger; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentLedger: Codable, Equatable, Sendable {
 public let activities: [Wire4FinanceInvestmentActivity]
 public let accountSnapshots: [Wire4FinanceInvestmentAccountSnapshot]
 public let importReceipts: [Wire4FinanceInvestmentImportReceipt]
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentLedger:
    activities: tuple[Wire4FinanceInvestmentActivity, ...]
    accountSnapshots: tuple[Wire4FinanceInvestmentAccountSnapshot, ...]
    importReceipts: tuple[Wire4FinanceInvestmentImportReceipt, ...]
```

```typescript
interface Wire4FinanceInvestmentLedger {
 readonly activities: ReadonlyArray<Wire4FinanceInvestmentActivity>;
 readonly accountSnapshots: ReadonlyArray<Wire4FinanceInvestmentAccountSnapshot>;
 readonly importReceipts: ReadonlyArray<Wire4FinanceInvestmentImportReceipt>;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|activities|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|accountSnapshots|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|importReceipts|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|

Conversion: static func fromDomain(_ value:FinanceInvestmentLedger) throws -> Wire4FinanceInvestmentLedger; func toDomain() throws -> FinanceInvestmentLedger.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
