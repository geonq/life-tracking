# Wire4FinanceAllocationShare — sealed value DTO
Source field authority: ios/Shared/FinanceAllocationDomain.swift, FinanceAllocationShare; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceAllocationShare: Codable, Equatable, Sendable {
 public let tag: String
 public let value: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceAllocationShare:
    tag: str
    value: str
```

```typescript
interface Wire4FinanceAllocationShare {
 readonly tag: string;
 readonly value: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|tag|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|value|I64 canonical signed decimal; exact Int64 round trip|

Conversion: static func fromDomain(_ value:FinanceAllocationShare) throws -> Wire4FinanceAllocationShare; func toDomain() throws -> FinanceAllocationShare.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
Associated enum mapping is explicitly sealed in R4-01; no synthesized associated-value Codable.
