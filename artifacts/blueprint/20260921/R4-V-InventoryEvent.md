# Wire4InventoryEvent — sealed value DTO
Source field authority: ios/Shared/SupplementHistoryDomain.swift, InventoryEvent; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4InventoryEvent: Codable, Equatable, Sendable {
 public let id: String
 public let planID: String
 public let kind: Wire4InventoryEventKind
 public let delta: String
 public let stockAfter: String
 public let occurredAt: String
 public let occurrenceID: String?
 public let costCents: String?
 public let batch: String?
 public let expiry: String?
 public let source: String?
 public let forecastAssumptions: Wire4SupplementForecastAssumptions?
}
```

```python
@dataclass(frozen=True)
class Wire4InventoryEvent:
    id: str
    planID: str
    kind: Wire4InventoryEventKind
    delta: str
    stockAfter: str
    occurredAt: str
    occurrenceID: str | None
    costCents: str | None
    batch: str | None
    expiry: str | None
    source: str | None
    forecastAssumptions: Wire4SupplementForecastAssumptions | None
```

```typescript
interface Wire4InventoryEvent {
 readonly id: string;
 readonly planID: string;
 readonly kind: Wire4InventoryEventKind;
 readonly delta: string;
 readonly stockAfter: string;
 readonly occurredAt: string;
 readonly occurrenceID: string | null;
 readonly costCents: string | null;
 readonly batch: string | null;
 readonly expiry: string | null;
 readonly source: string | null;
 readonly forecastAssumptions: Wire4SupplementForecastAssumptions | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|planID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|kind|exact nested Wire4InventoryEventKind declaration, recursive validation|
|delta|I64 canonical signed decimal; exact Int64 round trip|
|stockAfter|I64 canonical signed decimal; exact Int64 round trip|
|occurredAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|occurrenceID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|costCents|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|batch|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|expiry|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|source|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|forecastAssumptions|exact nested Wire4SupplementForecastAssumptions declaration, recursive validation or explicit null|

Conversion: static func fromDomain(_ value:InventoryEvent) throws -> Wire4InventoryEvent; func toDomain() throws -> InventoryEvent.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
