# Revision7 complete data-management archive contract
Planning-only. R7 supersedes the R6 in-memory `LifeOSDataArchive` shape with one directory pack covering the complete
closed registry. It is a user-initiated local backup/restore surface, never a sync protocol.

## Closed 26-pack registry

```swift
public enum LifeOSDataStoreID: String, Codable, Sendable {
 case calendar, financeImports, financeRecurring, financeInvestments, financeBudgets, financeAllocations
 case financePreferences, financeTravel, training, trainingTemplates, meals, nutritionGoals, supplements, journal
 case lifestyle, barcodeRecords, planningJournal, planningFiles, taxSanitized, taxRaw, usageLocal, clipperLocal
 case replicationTrust, widgetSnapshot, nutritionPhotoOriginals, recoveryImports
}
public enum LifeOSDataHost: String, Codable, Sendable { case apple, windows }
public enum LifeOSDataRepresentation: String, Codable, Sendable { case bytes, keyValue, manifestOnly }
public enum LifeOSDataSyncPolicy: String, Codable, Sendable { case never, metadataOnly, replicated }
public struct LifeOSDataFileEntryV2: Codable, Equatable, Sendable {
 public let host: LifeOSDataHost; public let relativePath: String; public let representation: LifeOSDataRepresentation
 public let byteCount: UInt64
 public let sha256: String; public let chunks: [LifeOSDataChunkRef]; public let protection: String
 public let syncPolicy: LifeOSDataSyncPolicy; public let retentionUntil: Date?
}
public struct LifeOSDataChunkRef: Codable, Equatable, Sendable {
 public let fileName: String; public let byteCount: UInt32; public let sha256: String
}
public struct LifeOSDataPackV2: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let storeID: LifeOSDataStoreID; public let files: [LifeOSDataFileEntryV2]
 public let packHash: String
}
public struct LifeOSDataArchiveV2: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let archiveID: UUID; public let createdAt: Date
 public let packs: [LifeOSDataPackV2]; public let totalBytes: UInt64; public let archiveHash: String
}
```

The archive is exactly `manifest.json`, one `packs/<storeID>.json` for every one of the 26 IDs in enum order, and
content-addressed `blobs/<sha256>.chunk` files. `manifest.json` contains `LifeOSDataArchiveV2`; pack JSON contains its
file entries. A pack may contain many files but is never omitted; an empty store has `files=[]`. A chunk is decoded
only after its declared size and hash are checked. `archiveHash` is SHA-256 of canonical manifest bytes with
`archiveHash` omitted followed by the sorted raw 32-byte chunk hashes; `packHash` is the same rule for its pack.

Bounds are: 26 packs, 4,096 file entries total, 1 MiB per chunk, 16 MiB per original nutrition photo, 4 MiB per other
ordinary file, 256 MiB total decoded bytes, 256 receipt-log records and 32 KiB per manifest/pack JSON. Paths are UTF-8,
relative, normalized, traversal-free, and must match the descriptor allowlist. No symlink or unlisted blob is accepted.

## Registry paths, authority and privacy

|ID|Exact source path/pattern and representation|Policy|
|---|---|---|
|calendar|`Application Support/LifeOS/calendar.json`|replicated|
|financeImports|`finance-imported-transactions.json`|replicated|
|financeRecurring|`finance-recurring-payments.json`|replicated|
|financeInvestments|`finance-investment-activity.json`|replicated|
|financeBudgets|`finance-budgets.json`|replicated|
|financeAllocations|`finance-allocation-rules.json`|replicated|
|financePreferences|`finance-tracking-preferences.json`|replicated|
|financeTravel|`finance-travel.json`|never|
|training|`fitness-training-ledger.json`|replicated|
|trainingTemplates|`fitness-strength-templates.json`|replicated|
|meals|`nutrition-meals.json`|replicated|
|nutritionGoals|`nutrition-goals.json`|replicated|
|supplements|`supplements-v1.json`|replicated|
|journal|`fitness-journal.json`|replicated|
|lifestyle|`fitness-lifestyle-ledger.json`|replicated|
|barcodeRecords|`nutrition-barcode-records.json`|replicated|
|planningJournal|`LifeOS/Planning/<vaultID>/journal.sqlite`|replicated|
|planningFiles|`LifeOS/Planning/<vaultID>/{cache,filesystem}/<allowlisted-name>`|metadataOnly|
|taxSanitized|`TaxDocuments/documents.json`|replicated|
|taxRaw|`TaxDocuments/{raw/<UUID>.json,originals/<UUID>.pdf}`|never|
|usageLocal|iOS `UserDefaults.standard[LifeOS.Usage.history.v1]`; Windows `resolve(USAGE_STORE_PATH ?? usage-history.jsonl)`|never|
|clipperLocal|iOS `UserDefaults.standard[LifeOS.Clipper.locallyRevoked.v1]`; Windows `resolve(CLIPPER_STORE_PATH ?? clipper-snapshot.json)`|never|
|replicationTrust|`Application Support/LifeOS/Replication/trust.json`|never|
|widgetSnapshot|validated App Group `future-widget-snapshot.v1.json`|metadataOnly|
|nutritionPhotoOriginals|`Nutrition/Photos/originals/<UUID>.(heic|jpg|png)`|never|
|recoveryImports|`Application Support/LifeOS/Replication/recovery-imports.json`|never|

The descriptor binds each row to its existing store adapter and rejects arbitrary paths. `taxRaw` and
`nutritionPhotoOriginals` contain actual bytes in an explicit local data-management export, but their bytes are never
placed in `RecoveryBundleV3`, Tailscale sync, widgets, or a provider request. Nutrition originals retain until the
per-photo `NutritionPhotoRetentionPolicy` deadline or explicit user deletion; deletion is recorded and irreversible.
Protected local assets require `includeProtectedLocalAssets == true`; the default full local export sets it true and
labels the archive sensitive. A destination must be a local filesystem volume; no automatic upload is performed.
The `usageLocal` and `clipperLocal` Windows entries are read through the authenticated gateway/SSH adapter only when
the Windows service is reachable; an outage yields `gatewayUnavailable` and an incomplete export, never an empty local
replacement. The two iOS UserDefaults values remain separate file entries in their pack. Restore sends the Windows
entries only to the validated service data root and rejects arbitrary environment-path changes.

## Adapter and receipt signatures

```swift
public protocol LifeOSDataStoreAdapter: Sendable {
 var storeID: LifeOSDataStoreID { get }
 func exportPack(options: LifeOSDataExportOptions) async throws -> LifeOSDataPackV2
 func restorePack(_ pack: LifeOSDataPackV2, from archiveURL: URL, options: LifeOSDataRestoreOptions) async throws
 func deletePack() async throws
}
public struct LifeOSDataStoreDescriptor: Sendable {
 public let storeID: LifeOSDataStoreID; public let allowedPaths: [String]; public let schemaVersion: Int
 public let hosts: [LifeOSDataHost]; public let adapter: any LifeOSDataStoreAdapter
}
public struct LifeOSDataStoreRegistry: Sendable {
 public let descriptors: [LifeOSDataStoreDescriptor]
 public init(descriptors: [LifeOSDataStoreDescriptor]) throws
}
public struct LifeOSDataExportOptions: Sendable { public let includeProtectedLocalAssets: Bool; public let destinationIsLocal: Bool }
public struct LifeOSDataRestoreOptions: Sendable { public let preserveProtectedLocalAssets: Bool }
public enum LifeOSDataOperation: String, Codable, Sendable { case export, restore, delete }
public enum LifeOSDataReceiptState: String, Codable, Sendable { case prepared, running, interrupted, failed, committed }
public struct LifeOSDataReceiptV2: Codable, Equatable, Sendable {
 public let receiptID: UUID; public let operationID: UUID; public let operation: LifeOSDataOperation
 public let state: LifeOSDataReceiptState; public let archiveID: UUID?; public let archiveHash: String?
 public let parentReceiptID: UUID?; public let parentLineageHash: String; public let completedPacks: [LifeOSDataStoreID]
 public let currentFileIndex: Int; public let nextPackIndex: Int; public let errorCode: String?
 public let createdAt: Date; public let updatedAt: Date
}
public actor LifeOSDataManagement {
 public func recover() async throws -> [LifeOSDataReceiptV2]
 public func export(to destination: URL, options: LifeOSDataExportOptions) async throws -> LifeOSDataReceiptV2
 public func restore(from archiveURL: URL, options: LifeOSDataRestoreOptions) async throws -> LifeOSDataReceiptV2
 public func deleteUserData() async throws -> LifeOSDataReceiptV2
}
```

`LifeOSDataStoreRegistry` owns the 26 adapters; no caller supplies an adapter for an unlisted ID. `exportPack` reads
the source through the existing owner (CalendarStore, FinanceTravelStore, Finance stores, Fitness/Nutrition stores,
PlanningMutationJournal, TaxDocumentStore, UsageHistoryPersistence, Clipper persistence, trust store, widget store,
photo store or recovery-import store). `restorePack` invokes the same owner's validated atomic restore; it never
decodes a domain in `LifeOSDataManagement`. Key-value entries encode canonical key/value bytes, not a guessed plist.

Receipts are an append-only bounded `data-management-receipts.json` log under
`Application Support/LifeOS/DataManagement`, atomically replaced after each state transition. `receiptID` is UUIDv5
over `operationID|archiveID|state|nextPackIndex|currentFileIndex`; `parentReceiptID` names the previous record and
`parentLineageHash` is its receipt hash (null parent uses SHA-256 of the empty byte string). Duplicate operation ID
and archive hash returns the last committed receipt; a changed hash is `idCollision`.

## Packing, restore, delete and interruption

Export writes `prepared`, creates `<destination>/<archiveID>.lifeosarchive.partial`, streams all 26 packs in enum order,
fsyncs each blob and pack, writes the canonical manifest, atomically renames the directory, then writes `committed`.
Restore verifies every manifest, pack, path, chunk and hash before touching a store; it writes `running`, restores one
pack through its adapter, records `nextPackIndex` and repeats. Each adapter transaction is atomic; a crash after a pack
commit but before its receipt is repaired by comparing the store's pack hash, then the receipt advances without a second
mutation. Delete writes a durable `running` receipt before each `deletePack`, removes user content in registry order,
keeps `replicationTrust` until the final fence is recorded, and regenerates the redacted widget snapshot last.

Cancellation before the first durable receipt does nothing; after it writes `interrupted` and resumes from the stored
indices. Disk-full preserves the last valid receipt and source pack; if a failure receipt can be written it is retryable.
Interrupted deletion never reports success and resumes from the completed prefix. Restore preserves protected local
assets when `preserveProtectedLocalAssets` is true; explicit full restore may replace them only after hash verification.
Legacy R6 archives migrate with `LifeOSDataArchiveMigrator.v2`, mapping old entries to these packs, adding empty packs
for the new IDs, and retaining an audit receipt for omitted raw/photo bytes; no missing asset is silently treated as a
successful deletion.

## Revision8 supersession

R8-05 is final for unique receipt IDs, transition hashes, lineage and bounded pruning. R8-06 is final for streaming
source/sink interfaces, frame bounds, fsync/atomic finalization and cancellation; R7 `exportPack` is history only.

## Revision10 supersession

R10-04 and R10-05 are final for receipt progress and manifest identity/digest verification; this registry
remains the closed 26-pack source of store IDs.
