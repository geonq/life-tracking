# Wire4SupplementPlan — sealed value DTO
Source field authority: ios/Shared/SupplementDomain.swift, SupplementPlan; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementPlan: Codable, Equatable, Sendable {
 public let id: String
 public let name: String
 public let brand: String
 public let productIdentifier: String?
 public let form: Wire4SupplementForm
 public let strength: String
 public let servingUnit: String
 public let userDose: Wire4SupplementDose?
 public let nutrientFacts: [Wire4SupplementNutrientFact]
 public let inventoryUnitsPerDose: String
 public let schedule: Wire4SupplementSchedule
 public let source: Wire4SupplementSource
 public let productLabelNote: Wire4SupplementProductLabelNote?
 public let notes: String?
 public let stockUnits: String
 public let reorderThreshold: String
 public let expectedLeadTimeDays: String?
 public let expiryDate: String?
 public let supplier: String?
 public let reminderEnabled: Bool
 public let lockScreenRedacted: Bool
 public let revision: String
 public let updatedAt: String
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementPlan:
    id: str
    name: str
    brand: str
    productIdentifier: str | None
    form: Wire4SupplementForm
    strength: str
    servingUnit: str
    userDose: Wire4SupplementDose | None
    nutrientFacts: tuple[Wire4SupplementNutrientFact, ...]
    inventoryUnitsPerDose: str
    schedule: Wire4SupplementSchedule
    source: Wire4SupplementSource
    productLabelNote: Wire4SupplementProductLabelNote | None
    notes: str | None
    stockUnits: str
    reorderThreshold: str
    expectedLeadTimeDays: str | None
    expiryDate: str | None
    supplier: str | None
    reminderEnabled: bool
    lockScreenRedacted: bool
    revision: str
    updatedAt: str
```

```typescript
interface Wire4SupplementPlan {
 readonly id: string;
 readonly name: string;
 readonly brand: string;
 readonly productIdentifier: string | null;
 readonly form: Wire4SupplementForm;
 readonly strength: string;
 readonly servingUnit: string;
 readonly userDose: Wire4SupplementDose | null;
 readonly nutrientFacts: ReadonlyArray<Wire4SupplementNutrientFact>;
 readonly inventoryUnitsPerDose: string;
 readonly schedule: Wire4SupplementSchedule;
 readonly source: Wire4SupplementSource;
 readonly productLabelNote: Wire4SupplementProductLabelNote | null;
 readonly notes: string | null;
 readonly stockUnits: string;
 readonly reorderThreshold: string;
 readonly expectedLeadTimeDays: string | null;
 readonly expiryDate: string | null;
 readonly supplier: string | null;
 readonly reminderEnabled: boolean;
 readonly lockScreenRedacted: boolean;
 readonly revision: string;
 readonly updatedAt: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|name|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|brand|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|productIdentifier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|form|exact nested Wire4SupplementForm declaration, recursive validation|
|strength|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|servingUnit|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|userDose|exact nested Wire4SupplementDose declaration, recursive validation or explicit null|
|nutrientFacts|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|inventoryUnitsPerDose|I64 canonical signed decimal; exact Int64 round trip|
|schedule|exact nested Wire4SupplementSchedule declaration, recursive validation|
|source|exact nested Wire4SupplementSource declaration, recursive validation|
|productLabelNote|exact nested Wire4SupplementProductLabelNote declaration, recursive validation or explicit null|
|notes|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|stockUnits|I64 canonical signed decimal; exact Int64 round trip|
|reorderThreshold|I64 canonical signed decimal; exact Int64 round trip|
|expectedLeadTimeDays|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|expiryDate|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|supplier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|reminderEnabled|JSON bool, no integer coercion|
|lockScreenRedacted|JSON bool, no integer coercion|
|revision|I64 canonical signed decimal; exact Int64 round trip|
|updatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:SupplementPlan) throws -> Wire4SupplementPlan; func toDomain() throws -> SupplementPlan.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
