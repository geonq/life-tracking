# Wire4TrainingSession — sealed value DTO
Source field authority: ios/Shared/FitnessTrainingDomain.swift, TrainingSession; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4TrainingSession: Codable, Equatable, Sendable {
 public let id: Wire4TrainingRecordID
 public let revision: String
 public let activityKind: Wire4TrainingActivityKind
 public let title: String
 public let createdAt: String
 public let updatedAt: String
 public let startedAt: String
 public let endedAt: String?
 public let timeZoneIdentifier: String
 public let templateID: String?
 public let templateSnapshot: Wire4TrainingTemplateSnapshot?
 public let pauses: [Wire4TrainingPauseInterval]
 public let status: Wire4TrainingSessionStatus
 public let exercises: [Wire4TrainingExerciseLog]
 public let notes: String?
 public let importedRecordKey: String?
}
```

```python
@dataclass(frozen=True)
class Wire4TrainingSession:
    id: Wire4TrainingRecordID
    revision: str
    activityKind: Wire4TrainingActivityKind
    title: str
    createdAt: str
    updatedAt: str
    startedAt: str
    endedAt: str | None
    timeZoneIdentifier: str
    templateID: str | None
    templateSnapshot: Wire4TrainingTemplateSnapshot | None
    pauses: tuple[Wire4TrainingPauseInterval, ...]
    status: Wire4TrainingSessionStatus
    exercises: tuple[Wire4TrainingExerciseLog, ...]
    notes: str | None
    importedRecordKey: str | None
```

```typescript
interface Wire4TrainingSession {
 readonly id: Wire4TrainingRecordID;
 readonly revision: string;
 readonly activityKind: Wire4TrainingActivityKind;
 readonly title: string;
 readonly createdAt: string;
 readonly updatedAt: string;
 readonly startedAt: string;
 readonly endedAt: string | null;
 readonly timeZoneIdentifier: string;
 readonly templateID: string | null;
 readonly templateSnapshot: Wire4TrainingTemplateSnapshot | null;
 readonly pauses: ReadonlyArray<Wire4TrainingPauseInterval>;
 readonly status: Wire4TrainingSessionStatus;
 readonly exercises: ReadonlyArray<Wire4TrainingExerciseLog>;
 readonly notes: string | null;
 readonly importedRecordKey: string | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|exact nested Wire4TrainingRecordID declaration, recursive validation|
|revision|I64 canonical signed decimal; exact Int64 round trip|
|activityKind|exact nested Wire4TrainingActivityKind declaration, recursive validation|
|title|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|createdAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|updatedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|startedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|endedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits or explicit null|
|timeZoneIdentifier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|templateID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|templateSnapshot|exact nested Wire4TrainingTemplateSnapshot declaration, recursive validation or explicit null|
|pauses|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|status|exact nested Wire4TrainingSessionStatus declaration, recursive validation|
|exercises|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|
|notes|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|importedRecordKey|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|

Conversion: static func fromDomain(_ value:TrainingSession) throws -> Wire4TrainingSession; func toDomain() throws -> TrainingSession.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
