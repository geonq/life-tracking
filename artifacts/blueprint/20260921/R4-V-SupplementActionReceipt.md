# Wire4SupplementActionReceipt — sealed value DTO
Source field authority: ios/Shared/SupplementStore.swift, SupplementActionReceipt; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4SupplementActionReceipt: Codable, Equatable, Sendable {
 public let actionID: String
 public let occurrenceID: String
 public let planID: String
 public let action: Wire4SupplementAction
 public let occurredAt: String
 public let snoozeUntil: String?
 public let baseRevision: String
 public let sourceDeviceID: String
}
```

```python
@dataclass(frozen=True)
class Wire4SupplementActionReceipt:
    actionID: str
    occurrenceID: str
    planID: str
    action: Wire4SupplementAction
    occurredAt: str
    snoozeUntil: str | None
    baseRevision: str
    sourceDeviceID: str
```

```typescript
interface Wire4SupplementActionReceipt {
 readonly actionID: string;
 readonly occurrenceID: string;
 readonly planID: string;
 readonly action: Wire4SupplementAction;
 readonly occurredAt: string;
 readonly snoozeUntil: string | null;
 readonly baseRevision: string;
 readonly sourceDeviceID: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|actionID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|occurrenceID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|planID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|action|exact nested Wire4SupplementAction declaration, recursive validation|
|occurredAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|snoozeUntil|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|baseRevision|I64 canonical signed decimal; exact Int64 round trip|
|sourceDeviceID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|

Conversion: static func fromDomain(_ value:SupplementActionReceipt) throws -> Wire4SupplementActionReceipt; func toDomain() throws -> SupplementActionReceipt.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
