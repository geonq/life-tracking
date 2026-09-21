# Wire4NutritionMealPhotoLineage — sealed value DTO
Source field authority: ios/Shared/NutritionDomain.swift, NutritionMealPhotoLineage; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4NutritionMealPhotoLineage: Codable, Equatable, Sendable {
 public let proposalID: String
 public let requestID: String
 public let requestTimestamp: String
 public let generatedAt: String
 public let provider: String
 public let modelIdentifier: String
 public let modelVersion: String
 public let policyVersion: String
 public let sanitizedImageHashes: [Wire4FoodEstimateImageHashReference]
}
```

```python
@dataclass(frozen=True)
class Wire4NutritionMealPhotoLineage:
    proposalID: str
    requestID: str
    requestTimestamp: str
    generatedAt: str
    provider: str
    modelIdentifier: str
    modelVersion: str
    policyVersion: str
    sanitizedImageHashes: tuple[Wire4FoodEstimateImageHashReference, ...]
```

```typescript
interface Wire4NutritionMealPhotoLineage {
 readonly proposalID: string;
 readonly requestID: string;
 readonly requestTimestamp: string;
 readonly generatedAt: string;
 readonly provider: string;
 readonly modelIdentifier: string;
 readonly modelVersion: string;
 readonly policyVersion: string;
 readonly sanitizedImageHashes: ReadonlyArray<Wire4FoodEstimateImageHashReference>;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|proposalID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|requestID|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|requestTimestamp|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|generatedAt|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|provider|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|modelIdentifier|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|modelVersion|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|policyVersion|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|sanitizedImageHashes|ordered array; max10000 elements; aggregate byte cap wins; element validator applies|

Conversion: static func fromDomain(_ value:NutritionMealPhotoLineage) throws -> Wire4NutritionMealPhotoLineage; func toDomain() throws -> NutritionMealPhotoLineage.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
