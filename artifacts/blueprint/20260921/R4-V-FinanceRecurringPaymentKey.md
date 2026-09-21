# Wire4FinanceRecurringPaymentKey — sealed value DTO
Source field authority: ios/Shared/FinanceRecurringPayment.swift, FinanceRecurringPaymentKey; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceRecurringPaymentKey: Codable, Equatable, Sendable {
 public let identityVersion: String
 public let sourceNamespace: String
 public let accountID: String
 public let currency: String
 public let normalizedMerchantKey: String
 public let normalizationVersion: String
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceRecurringPaymentKey:
    identityVersion: str
    sourceNamespace: str
    accountID: str
    currency: str
    normalizedMerchantKey: str
    normalizationVersion: str
```

```typescript
interface Wire4FinanceRecurringPaymentKey {
 readonly identityVersion: string;
 readonly sourceNamespace: string;
 readonly accountID: string;
 readonly currency: string;
 readonly normalizedMerchantKey: string;
 readonly normalizationVersion: string;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|identityVersion|I64 canonical signed decimal; exact Int64 round trip|
|sourceNamespace|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|accountID|lowercase canonical UUID; preserve identity|
|currency|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|normalizedMerchantKey|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|normalizationVersion|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|

Conversion: static func fromDomain(_ value:FinanceRecurringPaymentKey) throws -> Wire4FinanceRecurringPaymentKey; func toDomain() throws -> FinanceRecurringPaymentKey.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
