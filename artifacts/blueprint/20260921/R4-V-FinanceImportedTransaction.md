# Wire4FinanceImportedTransaction — sealed value DTO
Source field authority: ios/Shared/FinanceImportedTransaction.swift, FinanceImportedTransaction; proposed wire-only value, no new store.
Inherits R4-01 rules: all fields REQUIRED, explicit null for nullable, no defaults; v1 tagged parent.
P01 owns definition in ios/Sync/DomainWireValues.swift; P03/P04 own converters, P02 stores opaque signed bytes.
Every field persists only inside owning domain payload/archive; same-spelled local property is conversion source.

```swift
public struct Wire4FinanceImportedTransaction: Codable, Equatable, Sendable {
 public let id: String
 public let bookedAt: String
 public let amountCents: String
 public let description: String
 public let category: String?
 public let sourceCategory: String?
 public let providerCode: String?
 public let source: Wire4FinanceImportSource
 public let identityScheme: Wire4FinanceImportedIdentityScheme
 public let mappedIdentity: Wire4FinanceImportedMappedIdentity?
 public let importedAt: String
 public let kind: Wire4FinanceImportedTransactionKind
 public let investment: Wire4FinanceImportedInvestmentDetails?
}
```

```python
@dataclass(frozen=True)
class Wire4FinanceImportedTransaction:
    id: str
    bookedAt: str
    amountCents: str
    description: str
    category: str | None
    sourceCategory: str | None
    providerCode: str | None
    source: Wire4FinanceImportSource
    identityScheme: Wire4FinanceImportedIdentityScheme
    mappedIdentity: Wire4FinanceImportedMappedIdentity | None
    importedAt: str
    kind: Wire4FinanceImportedTransactionKind
    investment: Wire4FinanceImportedInvestmentDetails | None
```

```typescript
interface Wire4FinanceImportedTransaction {
 readonly id: string;
 readonly bookedAt: string;
 readonly amountCents: string;
 readonly description: string;
 readonly category: string | null;
 readonly sourceCategory: string | null;
 readonly providerCode: string | null;
 readonly source: Wire4FinanceImportSource;
 readonly identityScheme: Wire4FinanceImportedIdentityScheme;
 readonly mappedIdentity: Wire4FinanceImportedMappedIdentity | null;
 readonly importedAt: string;
 readonly kind: Wire4FinanceImportedTransactionKind;
 readonly investment: Wire4FinanceImportedInvestmentDetails | null;
}
```

|Encoding key|Exact conversion / bound in addition to domain validation|
|---|---|
|id|lowercase canonical UUID; preserve identity|
|bookedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|amountCents|I64 canonical signed decimal; exact Int64 round trip|
|description|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win|
|category|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|sourceCategory|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|providerCode|UTF8 max4096bytes; no NUL; no normalization; field-specific R4-01 bounds win or explicit null|
|source|exact nested Wire4FinanceImportSource declaration, recursive validation|
|identityScheme|exact nested Wire4FinanceImportedIdentityScheme declaration, recursive validation|
|mappedIdentity|exact nested Wire4FinanceImportedMappedIdentity declaration, recursive validation or explicit null|
|importedAt|F64(date.timeIntervalSinceReferenceDate); finite, exact bits|
|kind|exact nested Wire4FinanceImportedTransactionKind declaration, recursive validation|
|investment|exact nested Wire4FinanceImportedInvestmentDetails declaration, recursive validation or explicit null|

Conversion: static func fromDomain(_ value:FinanceImportedTransaction) throws -> Wire4FinanceImportedTransaction; func toDomain() throws -> FinanceImportedTransaction.
Fieldwise in table order; invoke existing validated initializer/validator; reject rather than sanitize wire values.
Failures: invalidInput (bounds/invariant), unsupportedSchema (tag/version), capacity (aggregate bytes).
Forward unknown/missing/duplicate keys reject; backward decode uses legacy store decoder only, then fromDomain.
