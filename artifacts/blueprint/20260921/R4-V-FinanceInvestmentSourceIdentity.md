# Wire4FinanceInvestmentSourceIdentity — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentSourceIdentity; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentSourceIdentity: Codable, Equatable, Sendable {
 public let provider: Wire4FinanceInvestmentProvider
 public let accountID: String
 public let schemaVersion: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentSourceIdentity:
    provider: Wire4FinanceInvestmentProvider
    accountID: str
    schemaVersion: str
```

```typescript
interface Wire4FinanceInvestmentSourceIdentity {
 readonly provider: Wire4FinanceInvestmentProvider;
 readonly accountID: string;
 readonly schemaVersion: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|provider|exact nested Wire4FinanceInvestmentProvider declaration, recursive validation|
|accountID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|schemaVersion|I64 canonical signed decimal; exact Int64 round trip|

Conversion: static func fromDomain(_ value:FinanceInvestmentSourceIdentity) throws -> Wire4FinanceInvestmentSourceIdentity; func toDomain() throws -> FinanceInvestmentSourceIdentity.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
