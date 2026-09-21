# Wire4SupplementScalarValue — sealed value DTO
Source field authority: ios/Shared/SupplementHistoryDomain.swift, SupplementScalarValue; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementScalarValue: Codable, Equatable, Sendable {
 public let tag: String
 public let stringValue: String?
 public let numberValue: String?
 public let boolValue: Bool?
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementScalarValue:
    tag: str
    stringValue: str | None
    numberValue: str | None
    boolValue: bool | None
```

```typescript
interface Wire4SupplementScalarValue {
 readonly tag: string;
 readonly stringValue: string | null;
 readonly numberValue: string | null;
 readonly boolValue: boolean | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|tag|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|stringValue|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|numberValue|F64(value); finite; preserve exact bits or explicit null|
|boolValue|JSON bool, no integer coercion or explicit null|

Conversion: static func fromDomain(_ value:SupplementScalarValue) throws -> Wire4SupplementScalarValue; func toDomain() throws -> SupplementScalarValue.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
Associated enum mapping is explicitly sealed in R4-01; no synthesized associated-value Codable.
