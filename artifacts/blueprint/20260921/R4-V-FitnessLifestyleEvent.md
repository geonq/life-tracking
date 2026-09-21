# Wire4FitnessLifestyleEvent — sealed value DTO
Source field authority: ios/Shared/FitnessLifestyleLedger.swift, FitnessLifestyleEvent; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FitnessLifestyleEvent: Codable, Equatable, Sendable {
 public let id: String
 public let kind: Wire4FitnessLifestyleKind
 public let state: Wire4FitnessLifestyleEventState
 public let value: String?
 public let unit: Wire4FitnessLifestyleUnit?
 public let occurredAt: String
 public let timeZoneIdentifier: String
 public let localDay: String
 public let localTimeFoldPolicy: Wire4FitnessLifestyleLocalTimeFoldPolicy
 public let createdAt: String
 public let updatedAt: String
 public let provenance: Wire4FitnessLifestyleProvenance
 public let sourceSampleUUID: String?
 public let sourceSampleRevision: String?
 public let lineage: Wire4FitnessLifestyleLineage
 public let journalNote: Wire4FitnessLifestyleJournalNote?
 public let isDeleted: Bool
 public let deletedAt: String?
 public let supersededAt: String?
 public let supersededBy: String?
}
```

```python
@dataclass(frozen=True)
class Wire4FitnessLifestyleEvent:
    id: str
    kind: Wire4FitnessLifestyleKind
    state: Wire4FitnessLifestyleEventState
    value: str | None
    unit: Wire4FitnessLifestyleUnit | None
    occurredAt: str
    timeZoneIdentifier: str
    localDay: str
    localTimeFoldPolicy: Wire4FitnessLifestyleLocalTimeFoldPolicy
    createdAt: str
    updatedAt: str
    provenance: Wire4FitnessLifestyleProvenance
    sourceSampleUUID: str | None
    sourceSampleRevision: str | None
    lineage: Wire4FitnessLifestyleLineage
    journalNote: Wire4FitnessLifestyleJournalNote | None
    isDeleted: bool
    deletedAt: str | None
    supersededAt: str | None
    supersededBy: str | None
```

```typescript
interface Wire4FitnessLifestyleEvent {
 readonly id: string;
 readonly kind: Wire4FitnessLifestyleKind;
 readonly state: Wire4FitnessLifestyleEventState;
 readonly value: string | null;
 readonly unit: Wire4FitnessLifestyleUnit | null;
 readonly occurredAt: string;
 readonly timeZoneIdentifier: string;
 readonly localDay: string;
 readonly localTimeFoldPolicy: Wire4FitnessLifestyleLocalTimeFoldPolicy;
 readonly createdAt: string;
 readonly updatedAt: string;
 readonly provenance: Wire4FitnessLifestyleProvenance;
 readonly sourceSampleUUID: string | null;
 readonly sourceSampleRevision: string | null;
 readonly lineage: Wire4FitnessLifestyleLineage;
 readonly journalNote: Wire4FitnessLifestyleJournalNote | null;
 readonly isDeleted: boolean;
 readonly deletedAt: string | null;
 readonly supersededAt: string | null;
 readonly supersededBy: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|lowercase canonical UUID; preserve identity|
|kind|exact nested Wire4FitnessLifestyleKind declaration, recursive validation|
|state|exact nested Wire4FitnessLifestyleEventState declaration, recursive validation|
|value|F64(value); finite; preserve exact bits or explicit null|
|unit|exact nested Wire4FitnessLifestyleUnit declaration, recursive validation or explicit null|
|occurredAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|timeZoneIdentifier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|localDay|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|localTimeFoldPolicy|exact nested Wire4FitnessLifestyleLocalTimeFoldPolicy declaration, recursive validation|
|createdAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|updatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|provenance|exact nested Wire4FitnessLifestyleProvenance declaration, recursive validation|
|sourceSampleUUID|lowercase canonical UUID; preserve identity or explicit null|
|sourceSampleRevision|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|lineage|exact nested Wire4FitnessLifestyleLineage declaration, recursive validation|
|journalNote|exact nested Wire4FitnessLifestyleJournalNote declaration, recursive validation or explicit null|
|isDeleted|JSON bool, no integer coercion|
|deletedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|supersededAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|supersededBy|lowercase canonical UUID; preserve identity or explicit null|

Conversion: static func fromDomain(_ value:FitnessLifestyleEvent) throws -> Wire4FitnessLifestyleEvent; func toDomain() throws -> FitnessLifestyleEvent.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
