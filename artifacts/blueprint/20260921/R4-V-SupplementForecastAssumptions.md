# Wire4SupplementForecastAssumptions — sealed value DTO
Source field authority: ios/Shared/SupplementHistoryDomain.swift, SupplementForecastAssumptions; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementForecastAssumptions: Codable, Equatable, Sendable {
 public let dosesPerScheduledDay: String
 public let scheduledDaysPerWeek: String
 public let inventoryUnitsPerDose: String
 public let asOf: String
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementForecastAssumptions:
    dosesPerScheduledDay: str
    scheduledDaysPerWeek: str
    inventoryUnitsPerDose: str
    asOf: str
```

```typescript
interface Wire4SupplementForecastAssumptions {
 readonly dosesPerScheduledDay: string;
 readonly scheduledDaysPerWeek: string;
 readonly inventoryUnitsPerDose: string;
 readonly asOf: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|dosesPerScheduledDay|F64(value); finite; preserve exact bits|
|scheduledDaysPerWeek|I64 canonical signed decimal; exact Int64 round trip|
|inventoryUnitsPerDose|I64 canonical signed decimal; exact Int64 round trip|
|asOf|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:SupplementForecastAssumptions) throws -> Wire4SupplementForecastAssumptions; func toDomain() throws -> SupplementForecastAssumptions.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
