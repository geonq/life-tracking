# Wire4SupplementSchedulePauseRange — sealed value DTO
Source field authority: ios/Shared/SupplementDomain.swift, SupplementSchedulePauseRange; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementSchedulePauseRange: Codable, Equatable, Sendable {
 public let startDate: String
 public let endDate: String
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementSchedulePauseRange:
    startDate: str
    endDate: str
```

```typescript
interface Wire4SupplementSchedulePauseRange {
 readonly startDate: string;
 readonly endDate: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|startDate|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|endDate|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|

Conversion: static func fromDomain(_ value:SupplementSchedulePauseRange) throws -> Wire4SupplementSchedulePauseRange; func toDomain() throws -> SupplementSchedulePauseRange.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
