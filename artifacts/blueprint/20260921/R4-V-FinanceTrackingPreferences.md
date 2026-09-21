# Wire4FinanceTrackingPreferences — sealed value DTO
Source field authority: ios/Shared/FinanceTrackingPreferences.swift, FinanceTrackingPreferences; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceTrackingPreferences: Codable, Equatable, Sendable {
 public let frequency: Wire4FinanceTrackingFrequency
 public let cycleAnchorDate: String
 public let incomeTrackingEnabled: Bool
 public let expenseTrackingEnabled: Bool
 public let updatedAt: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceTrackingPreferences:
    frequency: Wire4FinanceTrackingFrequency
    cycleAnchorDate: str
    incomeTrackingEnabled: bool
    expenseTrackingEnabled: bool
    updatedAt: str
```

```typescript
interface Wire4FinanceTrackingPreferences {
 readonly frequency: Wire4FinanceTrackingFrequency;
 readonly cycleAnchorDate: string;
 readonly incomeTrackingEnabled: boolean;
 readonly expenseTrackingEnabled: boolean;
 readonly updatedAt: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|frequency|exact nested Wire4FinanceTrackingFrequency declaration, recursive validation|
|cycleAnchorDate|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|incomeTrackingEnabled|JSON bool, no integer coercion|
|expenseTrackingEnabled|JSON bool, no integer coercion|
|updatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:FinanceTrackingPreferences) throws -> Wire4FinanceTrackingPreferences; func toDomain() throws -> FinanceTrackingPreferences.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
