# Wire4CalendarRecurrenceRule — sealed value DTO
Source field authority: ios/Shared/CalendarDomain.swift, CalendarRecurrenceRule; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4CalendarRecurrenceRule: Codable, Equatable, Sendable {
 public let frequency: Wire4CalendarRecurrenceFrequency
 public let interval: String
 public let until: String?
}
```

```python
@dataclass(frozen=True)
class Wire4CalendarRecurrenceRule:
    frequency: Wire4CalendarRecurrenceFrequency
    interval: str
    until: str | None
```

```typescript
interface Wire4CalendarRecurrenceRule {
 readonly frequency: Wire4CalendarRecurrenceFrequency;
 readonly interval: string;
 readonly until: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|frequency|exact nested Wire4CalendarRecurrenceFrequency declaration, recursive validation|
|interval|I64 canonical signed decimal; exact Int64 round trip|
|until|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|

Conversion: static func fromDomain(_ value:CalendarRecurrenceRule) throws -> Wire4CalendarRecurrenceRule; func toDomain() throws -> CalendarRecurrenceRule.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
