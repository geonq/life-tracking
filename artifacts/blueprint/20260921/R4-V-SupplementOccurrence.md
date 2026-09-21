# Wire4SupplementOccurrence — sealed value DTO
Source field authority: ios/Shared/SupplementHistoryDomain.swift, SupplementOccurrence; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementOccurrence: Codable, Equatable, Sendable {
 public let id: String
 public let planID: String
 public let scheduledFor: String
 public let state: Wire4SupplementOccurrenceState
 public let actedAt: String?
 public let snoozedUntil: String?
 public let revision: String
 public let updatedAt: String
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementOccurrence:
    id: str
    planID: str
    scheduledFor: str
    state: Wire4SupplementOccurrenceState
    actedAt: str | None
    snoozedUntil: str | None
    revision: str
    updatedAt: str
```

```typescript
interface Wire4SupplementOccurrence {
 readonly id: string;
 readonly planID: string;
 readonly scheduledFor: string;
 readonly state: Wire4SupplementOccurrenceState;
 readonly actedAt: string | null;
 readonly snoozedUntil: string | null;
 readonly revision: string;
 readonly updatedAt: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|planID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|scheduledFor|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|state|exact nested Wire4SupplementOccurrenceState declaration, recursive validation|
|actedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|snoozedUntil|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|revision|I64 canonical signed decimal; exact Int64 round trip|
|updatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:SupplementOccurrence) throws -> Wire4SupplementOccurrence; func toDomain() throws -> SupplementOccurrence.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
