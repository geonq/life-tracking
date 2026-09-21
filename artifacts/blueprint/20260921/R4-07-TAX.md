# Tax/documents sanitized payload and raw-data boundary seal
P13 owns TaxDocuments.swift and ios/Sync/TaxSyncAdapter.swift. Source-of-truth: local TaxDocumentStore plus retained originals.
```swift
public struct TaxPublicationPayload:Codable,Equatable,Sendable {
 public let schemaVersion:Int; public let tag:String; public let id:String; public let documentType:String
 public let taxYear:Int?; public let dates:[String]; public let amounts:[TaxPublishedAmount]; public let confidence:String
}
public struct TaxPublishedAmount:Codable,Equatable,Sendable { public let value:String; public let label:String }
```
```python
@dataclass(frozen=True)
class TaxPublishedAmount: value:str; label:str
@dataclass(frozen=True)
class TaxPublicationPayload:
    schemaVersion:int; tag:str; id:str; documentType:str; taxYear:int|None
    dates:tuple[str,...]; amounts:tuple[TaxPublishedAmount,...]; confidence:str
```
```typescript
interface TaxPublishedAmount { readonly value:string; readonly label:"tax"|"payment"|"refund"|"other" }
interface TaxPublicationPayload { readonly schemaVersion:1; readonly tag:"taxPublication"; readonly id:string; readonly documentType:"assessment"|"invoice"|"statement"|"other"; readonly taxYear:number|null; readonly dates:ReadonlyArray<string>; readonly amounts:ReadonlyArray<TaxPublishedAmount>; readonly confidence:"low"|"medium"|"high" }
```
All required; id canonical originalUUID; taxYear1900...2199 or null; dates<=256 strict GregorianYYYY-MM-DD;
amounts<=256 value canonical signed decimal <=32chars/2fraction digits, label closed above; bytes<=64KiB/record.
confidence map existing TaxConfidence raw case by exact low/medium/high; any different source case maps low.
DO NOT export title,issuer,taxpayerIdentifier,referenceIdentifier,evidence snippets,pages,warnings,original paths/PDFs.
This restrictive whitelist supersedes earlier unspecified TaxPublicationRecord. User free text never silently treated as sanitized.
TaxPublicationCodec.fromDocument(_ document:TaxDocument)throws->TaxPublicationPayload:
id exact; documentType exact lower-case English listed case else other; year in range else null;
dates retain only strictly parseable source date values; amounts use existing TaxPrivacy.sanitizeAmountValue then canonical money parser,
noncanonical/unparseable row excluded with LOCAL migration diagnostic count; label exact listed case else other; no evidence field.
TaxPublicationCodec.decode(_ data:Data)throws->TaxPublicationPayload rejects unknown keys/types/prefixes before storage.
TaxPublicationCodec.localProjection(_ payload:TaxPublicationPayload)->TaxDocument constructs title='Tax document',documentType,
taxYear,dates(with empty evidence),amounts(with empty evidence),confidence; identifiers nil,pages=[],warnings=[].
No raw helper text falsely claims exact original has been received.

## Exact existing-store integration
TaxDocumentStore.save/delete→persist remain local command API; actor TaxSyncAdapter owns serialization of all access.
Add TaxDocumentStore.commitReplication(_ payload:TaxPublicationPayload,operation:SyncOperation?)throws->SyncCommitReceipt;
merge only published fields for matching ID, retain device-local original/evidence fields under local private cache map.
New wrapper documents:[TaxDocument],replication:SyncAdapterEnvelope,publication:[TaxPublicationPayload]; all version1 required;
legacy raw array migrates, original bytes protected+backup verified before wrapper replace. Never delete original during migration.
Local private cache raw/<UUID>.json and originals/<UUID>.pdf under SAME existing TaxDocumentStore.directory;
rawCacheIndex:[{id:String,digest:String}] UUID/HASH required, local-only, max10000; protected on iOS .completeFileProtection.
Mac directories0700/files0600; exclude raw directories from sync adapter/archive enumeration (closed allowlist, no directory walk).
If backup/protection unavailable, fail migration identityUnavailable/diskFull, keep source; no fake sanitized success.
Receipts/entity heads/publication candidate persist atomically via existing persist path; actor releases only after replace.
Remote delete hides publication but preserves raw archive under explicit local retention/export policy, never unlinks original PDF.
User explicit raw delete is separate confirmed local command, not remotely triggered by operation.

## Archive/rollback/widget
TaxArchive=DomainArchive<TaxPublicationPayload>, sanitized only; raw archive backup NEVER transported automatically.
Restore merge publication through same transaction without replacing existing private cache; missing originals display unavailable.
Legacy raw array defaults decode only locally; future wire fields/schema fail closed; no fallback exporting full TaxDocument Codable.
Tax has no registered widget producer; don't add a tax widget as part of sync integration.
CSV export remains local explicit action, TaxCSVExporter.escape neutralizes dangerous leading control/=+-@ before CSV quoting.
Evidence: identifiers in every source field absent from payload/archive, raw-cache permissions/backup/restart, crash-safe replace,
CSV formula/parser bounds, remote delete cannot destroy originals; physical lock protection proof later.
