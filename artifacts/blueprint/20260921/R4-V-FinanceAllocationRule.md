# Wire4FinanceAllocationRule — sealed value DTO
Source field authority: ios/Shared/FinanceAllocationDomain.swift, FinanceAllocationRule; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceAllocationRule: Codable, Equatable, Sendable {
 public let id: String
 public let label: String
 public let bucket: String
 public let share: Wire4FinanceAllocationShare
 public let createdAt: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceAllocationRule:
    id: str
    label: str
    bucket: str
    share: Wire4FinanceAllocationShare
    createdAt: str
```

```typescript
interface Wire4FinanceAllocationRule {
 readonly id: string;
 readonly label: string;
 readonly bucket: string;
 readonly share: Wire4FinanceAllocationShare;
 readonly createdAt: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|lowercase canonical UUID; preserve identity|
|label|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|bucket|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|share|exact nested Wire4FinanceAllocationShare declaration, recursive validation|
|createdAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:FinanceAllocationRule) throws -> Wire4FinanceAllocationRule; func toDomain() throws -> FinanceAllocationRule.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
