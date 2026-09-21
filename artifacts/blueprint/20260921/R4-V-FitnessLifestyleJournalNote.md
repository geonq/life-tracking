# Wire4FitnessLifestyleJournalNote — sealed value DTO
Source field authority: ios/Shared/FitnessLifestyleLedger.swift, FitnessLifestyleJournalNote; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FitnessLifestyleJournalNote: Codable, Equatable, Sendable {
 public let text: String
 public let createdAt: String
 public let linkage: Wire4FitnessLifestyleJournalLinkage
}
```

```python
@dataclass(frozen=True)
class Wire4FitnessLifestyleJournalNote:
    text: str
    createdAt: str
    linkage: Wire4FitnessLifestyleJournalLinkage
```

```typescript
interface Wire4FitnessLifestyleJournalNote {
 readonly text: string;
 readonly createdAt: string;
 readonly linkage: Wire4FitnessLifestyleJournalLinkage;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|text|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|createdAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|linkage|exact nested Wire4FitnessLifestyleJournalLinkage declaration, recursive validation|

Conversion: static func fromDomain(_ value:FitnessLifestyleJournalNote) throws -> Wire4FitnessLifestyleJournalNote; func toDomain() throws -> FitnessLifestyleJournalNote.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
