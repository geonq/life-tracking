# Wire4FinanceTrackingFrequency — sealed value DTO
Source field authority: ios/Shared/FinanceTrackingPreferences.swift, FinanceTrackingFrequency; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceTrackingFrequency: Codable, Equatable, Sendable {
 public let tag: String
 public let day: String?
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceTrackingFrequency:
    tag: str
    day: str | None
```

```typescript
interface Wire4FinanceTrackingFrequency {
 readonly tag: string;
 readonly day: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|tag|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|day|I64 canonical signed decimal; exact Int64 round trip or explicit null|

Conversion: static func fromDomain(_ value:FinanceTrackingFrequency) throws -> Wire4FinanceTrackingFrequency; func toDomain() throws -> FinanceTrackingFrequency.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
Associated enum mapping is explicitly sealed in R4-01; no synthesized associated-value Codable.
