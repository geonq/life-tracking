# Wire4FinanceRecurringPaymentOverride — sealed value DTO
Source field authority: ios/Shared/FinanceRecurringPayment.swift, FinanceRecurringPaymentOverride; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceRecurringPaymentOverride: Codable, Equatable, Sendable {
 public let key: Wire4FinanceRecurringPaymentKey
 public let cadence: Wire4FinanceRecurringCadence?
 public let anchor: Wire4FinanceRecurringAnchor?
 public let status: Wire4FinanceRecurringPaymentStatus
 public let localRevision: String
 public let updatedAt: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceRecurringPaymentOverride:
    key: Wire4FinanceRecurringPaymentKey
    cadence: Wire4FinanceRecurringCadence | None
    anchor: Wire4FinanceRecurringAnchor | None
    status: Wire4FinanceRecurringPaymentStatus
    localRevision: str
    updatedAt: str
```

```typescript
interface Wire4FinanceRecurringPaymentOverride {
 readonly key: Wire4FinanceRecurringPaymentKey;
 readonly cadence: Wire4FinanceRecurringCadence | null;
 readonly anchor: Wire4FinanceRecurringAnchor | null;
 readonly status: Wire4FinanceRecurringPaymentStatus;
 readonly localRevision: string;
 readonly updatedAt: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|key|exact nested Wire4FinanceRecurringPaymentKey declaration, recursive validation|
|cadence|exact nested Wire4FinanceRecurringCadence declaration, recursive validation or explicit null|
|anchor|exact nested Wire4FinanceRecurringAnchor declaration, recursive validation or explicit null|
|status|exact nested Wire4FinanceRecurringPaymentStatus declaration, recursive validation|
|localRevision|I64 canonical signed decimal; exact Int64 round trip|
|updatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:FinanceRecurringPaymentOverride) throws -> Wire4FinanceRecurringPaymentOverride; func toDomain() throws -> FinanceRecurringPaymentOverride.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
