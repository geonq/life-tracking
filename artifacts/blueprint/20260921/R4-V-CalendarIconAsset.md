# Wire4CalendarIconAsset — sealed value DTO
Source field authority: ios/Shared/CalendarIconAsset.swift, CalendarIconAsset; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4CalendarIconAsset: Codable, Equatable, Sendable {
 public let schemaVersion: String
 public let contentHash: String
 public let format: Wire4Format
 public let bytes: String
}
```

```python
@dataclass(frozen=True)
class Wire4CalendarIconAsset:
    schemaVersion: str
    contentHash: str
    format: Wire4Format
    bytes: str
```

```typescript
interface Wire4CalendarIconAsset {
 readonly schemaVersion: string;
 readonly contentHash: string;
 readonly format: Wire4Format;
 readonly bytes: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|schemaVersion|I64 canonical signed decimal; exact Int64 round trip|
|contentHash|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|format|exact nested Wire4Format declaration, recursive validation|
|bytes|base64url, max256KiB; reject before allocation; hash verified before image decoder|

Conversion: static func fromDomain(_ value:CalendarIconAsset) throws -> Wire4CalendarIconAsset; func toDomain() throws -> CalendarIconAsset.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
