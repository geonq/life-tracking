# Wire4FitnessLifestyleLineage — sealed value DTO
Source field authority: ios/Shared/FitnessLifestyleLedger.swift, FitnessLifestyleLineage; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FitnessLifestyleLineage: Codable, Equatable, Sendable {
 public let rootEventID: String
 public let parentEventID: String?
 public let revision: String
}
```

```python
@dataclass(frozen=True)
class Wire4FitnessLifestyleLineage:
    rootEventID: str
    parentEventID: str | None
    revision: str
```

```typescript
interface Wire4FitnessLifestyleLineage {
 readonly rootEventID: string;
 readonly parentEventID: string | null;
 readonly revision: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|rootEventID|lowercase canonical UUID; preserve identity|
|parentEventID|lowercase canonical UUID; preserve identity or explicit null|
|revision|I64 canonical signed decimal; exact Int64 round trip|

Conversion: static func fromDomain(_ value:FitnessLifestyleLineage) throws -> Wire4FitnessLifestyleLineage; func toDomain() throws -> FitnessLifestyleLineage.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
