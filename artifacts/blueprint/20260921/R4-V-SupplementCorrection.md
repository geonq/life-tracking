# Wire4SupplementCorrection — sealed value DTO
Source field authority: ios/Shared/SupplementHistoryDomain.swift, SupplementCorrection; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementCorrection: Codable, Equatable, Sendable {
 public let id: String
 public let entityKind: Wire4SupplementCorrectionEntityKind
 public let entityID: String
 public let field: String
 public let oldValue: Wire4SupplementScalarValue
 public let newValue: Wire4SupplementScalarValue
 public let actorID: String
 public let correctedAt: String
 public let reason: String
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementCorrection:
    id: str
    entityKind: Wire4SupplementCorrectionEntityKind
    entityID: str
    field: str
    oldValue: Wire4SupplementScalarValue
    newValue: Wire4SupplementScalarValue
    actorID: str
    correctedAt: str
    reason: str
```

```typescript
interface Wire4SupplementCorrection {
 readonly id: string;
 readonly entityKind: Wire4SupplementCorrectionEntityKind;
 readonly entityID: string;
 readonly field: string;
 readonly oldValue: Wire4SupplementScalarValue;
 readonly newValue: Wire4SupplementScalarValue;
 readonly actorID: string;
 readonly correctedAt: string;
 readonly reason: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|entityKind|exact nested Wire4SupplementCorrectionEntityKind declaration, recursive validation|
|entityID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|field|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|oldValue|exact nested Wire4SupplementScalarValue declaration, recursive validation|
|newValue|exact nested Wire4SupplementScalarValue declaration, recursive validation|
|actorID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|correctedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|reason|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|

Conversion: static func fromDomain(_ value:SupplementCorrection) throws -> Wire4SupplementCorrection; func toDomain() throws -> SupplementCorrection.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
