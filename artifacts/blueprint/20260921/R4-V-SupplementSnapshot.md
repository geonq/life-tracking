# Wire4SupplementSnapshot — sealed value DTO
Source field authority: ios/Shared/SupplementHistoryDomain.swift, SupplementSnapshot; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementSnapshot: Codable, Equatable, Sendable {
 public let schemaVersion: String
 public let generatedAt: String
 public let revision: String
 public let plans: [Wire4SupplementPlan]
 public let occurrences: [Wire4SupplementOccurrence]
 public let corrections: [Wire4SupplementCorrection]
 public let inventoryEvents: [Wire4InventoryEvent]
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementSnapshot:
    schemaVersion: str
    generatedAt: str
    revision: str
    plans: tuple[Wire4SupplementPlan, ...]
    occurrences: tuple[Wire4SupplementOccurrence, ...]
    corrections: tuple[Wire4SupplementCorrection, ...]
    inventoryEvents: tuple[Wire4InventoryEvent, ...]
```

```typescript
interface Wire4SupplementSnapshot {
 readonly schemaVersion: string;
 readonly generatedAt: string;
 readonly revision: string;
 readonly plans: ReadonlyArray<Wire4SupplementPlan>;
 readonly occurrences: ReadonlyArray<Wire4SupplementOccurrence>;
 readonly corrections: ReadonlyArray<Wire4SupplementCorrection>;
 readonly inventoryEvents: ReadonlyArray<Wire4InventoryEvent>;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|schemaVersion|I64 canonical signed decimal; exact Int64 round trip|
|generatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|revision|I64 canonical signed decimal; exact Int64 round trip|
|plans|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|occurrences|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|corrections|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|inventoryEvents|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|

Conversion: static func fromDomain(_ value:SupplementSnapshot) throws -> Wire4SupplementSnapshot; func toDomain() throws -> SupplementSnapshot.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
