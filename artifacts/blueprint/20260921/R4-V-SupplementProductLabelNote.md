# Wire4SupplementProductLabelNote — sealed value DTO
Source field authority: ios/Shared/SupplementDomain.swift, SupplementProductLabelNote; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementProductLabelNote: Codable, Equatable, Sendable {
 public let text: String
 public let sourceDate: String
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementProductLabelNote:
    text: str
    sourceDate: str
```

```typescript
interface Wire4SupplementProductLabelNote {
 readonly text: string;
 readonly sourceDate: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|text|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|sourceDate|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|

Conversion: static func fromDomain(_ value:SupplementProductLabelNote) throws -> Wire4SupplementProductLabelNote; func toDomain() throws -> SupplementProductLabelNote.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
