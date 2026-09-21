# Wire4FitnessLifestyleSettings — sealed value DTO
Source field authority: ios/Shared/FitnessLifestyleLedger.swift, FitnessLifestyleSettings; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FitnessLifestyleSettings: Codable, Equatable, Sendable {
 public let kind: Wire4FitnessLifestyleKind
 public let goal: String?
 public let quickAmount: String?
 public let quickUnit: Wire4FitnessLifestyleUnit?
 public let reminderTimeMinutes: String?
 public let reminderEnabled: Bool
 public let reminderContext: Wire4FitnessLifestyleReminderContext
 public let reminderFoldPolicy: Wire4FitnessLifestyleLocalTimeFoldPolicy
 public let bedtimeMinutes: String?
 public let caffeineCutoffOffsetMinutes: String?
 public let updatedAt: String
}
```

```python
@dataclass(frozen=True)
class Wire4FitnessLifestyleSettings:
    kind: Wire4FitnessLifestyleKind
    goal: str | None
    quickAmount: str | None
    quickUnit: Wire4FitnessLifestyleUnit | None
    reminderTimeMinutes: str | None
    reminderEnabled: bool
    reminderContext: Wire4FitnessLifestyleReminderContext
    reminderFoldPolicy: Wire4FitnessLifestyleLocalTimeFoldPolicy
    bedtimeMinutes: str | None
    caffeineCutoffOffsetMinutes: str | None
    updatedAt: str
```

```typescript
interface Wire4FitnessLifestyleSettings {
 readonly kind: Wire4FitnessLifestyleKind;
 readonly goal: string | null;
 readonly quickAmount: string | null;
 readonly quickUnit: Wire4FitnessLifestyleUnit | null;
 readonly reminderTimeMinutes: string | null;
 readonly reminderEnabled: boolean;
 readonly reminderContext: Wire4FitnessLifestyleReminderContext;
 readonly reminderFoldPolicy: Wire4FitnessLifestyleLocalTimeFoldPolicy;
 readonly bedtimeMinutes: string | null;
 readonly caffeineCutoffOffsetMinutes: string | null;
 readonly updatedAt: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|kind|exact nested Wire4FitnessLifestyleKind declaration, recursive validation|
|goal|F64(value); finite; preserve exact bits or explicit null|
|quickAmount|F64(value); finite; preserve exact bits or explicit null|
|quickUnit|exact nested Wire4FitnessLifestyleUnit declaration, recursive validation or explicit null|
|reminderTimeMinutes|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|reminderEnabled|JSON bool, no integer coercion|
|reminderContext|exact nested Wire4FitnessLifestyleReminderContext declaration, recursive validation|
|reminderFoldPolicy|exact nested Wire4FitnessLifestyleLocalTimeFoldPolicy declaration, recursive validation|
|bedtimeMinutes|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|caffeineCutoffOffsetMinutes|I64 canonical signed decimal; exact Int64 round trip or explicit null|
|updatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|

Conversion: static func fromDomain(_ value:FitnessLifestyleSettings) throws -> Wire4FitnessLifestyleSettings; func toDomain() throws -> FitnessLifestyleSettings.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
