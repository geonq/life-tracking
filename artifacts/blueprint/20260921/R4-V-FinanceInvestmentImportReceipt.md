# Wire4FinanceInvestmentImportReceipt — sealed value DTO
Source field authority: ios/Shared/FinanceInvestmentDomain.swift, FinanceInvestmentImportReceipt; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceInvestmentImportReceipt: Codable, Equatable, Sendable {
 public let id: String
 public let source: Wire4FinanceInvestmentSourceIdentity
 public let fileSHA256: String
 public let observedAt: String
 public let dataRowCount: String
 public let activityIDs: [String]
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceInvestmentImportReceipt:
    id: str
    source: Wire4FinanceInvestmentSourceIdentity
    fileSHA256: str
    observedAt: str
    dataRowCount: str
    activityIDs: tuple[str, ...]
```

```typescript
interface Wire4FinanceInvestmentImportReceipt {
 readonly id: string;
 readonly source: Wire4FinanceInvestmentSourceIdentity;
 readonly fileSHA256: string;
 readonly observedAt: string;
 readonly dataRowCount: string;
 readonly activityIDs: ReadonlyArray<string>;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|source|exact nested Wire4FinanceInvestmentSourceIdentity declaration, recursive validation|
|fileSHA256|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|observedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|dataRowCount|I64 canonical signed decimal; exact Int64 round trip|
|activityIDs|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|

Conversion: static func fromDomain(_ value:FinanceInvestmentImportReceipt) throws -> Wire4FinanceInvestmentImportReceipt; func toDomain() throws -> FinanceInvestmentImportReceipt.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
