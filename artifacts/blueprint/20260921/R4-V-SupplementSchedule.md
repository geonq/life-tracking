# Wire4SupplementSchedule — sealed value DTO
Source field authority: ios/Shared/SupplementDomain.swift, SupplementSchedule; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementSchedule: Codable, Equatable, Sendable {
 public let weekdays: [String]
 public let localTime: String
 public let timeZoneIdentifier: String
 public let timingNote: String?
 public let startDate: String
 public let endDate: String?
 public let pauseRanges: [Wire4SupplementSchedulePauseRange]
 public let notificationPreference: Wire4SupplementNotificationPreference
 public let calendarOverlayEnabled: Bool
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementSchedule:
    weekdays: tuple[str, ...]
    localTime: str
    timeZoneIdentifier: str
    timingNote: str | None
    startDate: str
    endDate: str | None
    pauseRanges: tuple[Wire4SupplementSchedulePauseRange, ...]
    notificationPreference: Wire4SupplementNotificationPreference
    calendarOverlayEnabled: bool
```

```typescript
interface Wire4SupplementSchedule {
 readonly weekdays: ReadonlyArray<string>;
 readonly localTime: string;
 readonly timeZoneIdentifier: string;
 readonly timingNote: string | null;
 readonly startDate: string;
 readonly endDate: string | null;
 readonly pauseRanges: ReadonlyArray<Wire4SupplementSchedulePauseRange>;
 readonly notificationPreference: Wire4SupplementNotificationPreference;
 readonly calendarOverlayEnabled: boolean;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|weekdays|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|localTime|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|timeZoneIdentifier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|timingNote|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|startDate|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|endDate|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|pauseRanges|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|notificationPreference|exact nested Wire4SupplementNotificationPreference declaration, recursive validation|
|calendarOverlayEnabled|JSON bool, no integer coercion|

Conversion: static func fromDomain(_ value:SupplementSchedule) throws -> Wire4SupplementSchedule; func toDomain() throws -> SupplementSchedule.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
