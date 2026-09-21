# Wire4CalendarItem — sealed value DTO
Source field authority: ios/Shared/CalendarDomain.swift, CalendarItem; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4CalendarItem: Codable, Equatable, Sendable {
 public let id: String
 public let title: String
 public let kind: Wire4CalendarItemKind
 public let icon: String?
 public let iconAsset: Wire4CalendarIconAsset?
 public let systemIconName: String?
 public let status: Wire4CalendarProgress
 public let start: String
 public let end: String
 public let timeZoneIdentifier: String?
 public let recurrence: Wire4CalendarRecurrenceRule?
 public let createdAt: String
 public let updatedAt: String
 public let deletedAt: String?
}
```

```python
@dataclass(frozen=True)
class Wire4CalendarItem:
    id: str
    title: str
    kind: Wire4CalendarItemKind
    icon: str | None
    iconAsset: Wire4CalendarIconAsset | None
    systemIconName: str | None
    status: Wire4CalendarProgress
    start: str
    end: str
    timeZoneIdentifier: str | None
    recurrence: Wire4CalendarRecurrenceRule | None
    createdAt: str
    updatedAt: str
    deletedAt: str | None
```

```typescript
interface Wire4CalendarItem {
 readonly id: string;
 readonly title: string;
 readonly kind: Wire4CalendarItemKind;
 readonly icon: string | null;
 readonly iconAsset: Wire4CalendarIconAsset | null;
 readonly systemIconName: string | null;
 readonly status: Wire4CalendarProgress;
 readonly start: string;
 readonly end: string;
 readonly timeZoneIdentifier: string | null;
 readonly recurrence: Wire4CalendarRecurrenceRule | null;
 readonly createdAt: string;
 readonly updatedAt: string;
 readonly deletedAt: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|lowercase canonical UUID; preserve identity|
|title|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|kind|exact nested Wire4CalendarItemKind declaration, recursive validation|
|icon|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|iconAsset|exact nested Wire4CalendarIconAsset declaration, recursive validation or explicit null|
|systemIconName|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|status|exact nested Wire4CalendarProgress declaration, recursive validation|
|start|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|end|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|timeZoneIdentifier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|recurrence|exact nested Wire4CalendarRecurrenceRule declaration, recursive validation or explicit null|
|createdAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|updatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|deletedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|

Conversion: static func fromDomain(_ value:CalendarItem) throws -> Wire4CalendarItem; func toDomain() throws -> CalendarItem.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
