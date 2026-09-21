# Wire4FitnessJournalRecord — sealed value DTO
Source field authority: ios/Shared/FitnessJournalStore.swift, FitnessJournalRecord; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FitnessJournalRecord: Codable, Equatable, Sendable {
 public let id: String
 public let title: String
 public let emoji: String
 public let section: Wire4Section
 public let date: String
 public let source: Wire4Source
 public let provenance: String
 public let tagState: Wire4TagState
 public let quantity: String?
 public let unit: String?
 public let observedValue: String?
 public let window: String?
 public let quantityInput: String?
 public let editable: Bool
}
```

```python
@dataclass(frozen=True)
class Wire4FitnessJournalRecord:
    id: str
    title: str
    emoji: str
    section: Wire4Section
    date: str
    source: Wire4Source
    provenance: str
    tagState: Wire4TagState
    quantity: str | None
    unit: str | None
    observedValue: str | None
    window: str | None
    quantityInput: str | None
    editable: bool
```

```typescript
interface Wire4FitnessJournalRecord {
 readonly id: string;
 readonly title: string;
 readonly emoji: string;
 readonly section: Wire4Section;
 readonly date: string;
 readonly source: Wire4Source;
 readonly provenance: string;
 readonly tagState: Wire4TagState;
 readonly quantity: string | null;
 readonly unit: string | null;
 readonly observedValue: string | null;
 readonly window: string | null;
 readonly quantityInput: string | null;
 readonly editable: boolean;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|title|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|emoji|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|section|exact nested Wire4Section declaration, recursive validation|
|date|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|source|exact nested Wire4Source declaration, recursive validation|
|provenance|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|tagState|exact nested Wire4TagState declaration, recursive validation|
|quantity|F64(value); finite; preserve exact bits or explicit null|
|unit|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|observedValue|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|window|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|quantityInput|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|editable|JSON bool, no integer coercion|

Conversion: static func fromDomain(_ value:FitnessJournalRecord) throws -> Wire4FitnessJournalRecord; func toDomain() throws -> FitnessJournalRecord.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
