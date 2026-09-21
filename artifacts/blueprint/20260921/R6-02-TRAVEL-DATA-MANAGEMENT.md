# Revision6 travel and data-management contracts
Planning-only. This document seals the R5 names `FinanceTravelStore`, `FinanceTravelProjection` and
`LifeOSDataManagement`; no network replication is added.

## Local travel value and store

```swift
public enum FinanceTravelMutation: String, Codable, Sendable { case create, update, delete }
public enum FinanceTravelSource: String, Codable, Sendable { case manual }
public struct FinanceTravelTrip: Codable, Equatable, Identifiable, Sendable {
 public let id: UUID; public let countryCode: String?; public let startDate: Date; public let endDate: Date
 public let label: String?; public let source: FinanceTravelSource; public let createdAt: Date
 public let updatedAt: Date; public let revision: UInt64; public let deletedAt: Date?
}
public struct FinanceTravelReceipt: Codable, Equatable, Sendable {
 public let mutationID: UUID; public let tripID: UUID; public let mutation: FinanceTravelMutation
 public let previousRevision: UInt64?; public let committedRevision: UInt64; public let fileRevision: UInt64
 public let previousReceiptID: UUID?; public let contentHash: String
}
public struct FinanceTravelSnapshot: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let fileRevision: UInt64; public let trips: [FinanceTravelTrip]
 public let receipts: [FinanceTravelReceipt]
}
```

`schemaVersion` is exactly1; `countryCode` is explicit null for an unknown country or an uppercase ISO-3166-1
alpha-2 code; dates are finite and `endDate >= startDate`; label is optional UTF-8 <=120 bytes; at most1024 trips
and256 receipts are retained; IDs are canonical UUIDs, hashes are lowercase SHA-256 and revisions are monotonic.
`fileRevision` is the committed snapshot revision; `previousReceiptID` links the prior receipt, is null only for the
first mutation, and must resolve to the retained prior receipt. A changed chain is corruption, not a fresh empty store.
Deleted trips remain as tombstones until the next user export/checkpoint and never reappear in projection. Source is
always `manual`; automatic transaction inference is a truthful unavailable state until a separately approved source.

```swift
public actor FinanceTravelStore {
 public init(url: URL = Self.defaultURL, fileManager: FileManager = .default)
 public func recover() throws -> FinanceTravelSnapshot
 public func load() throws -> FinanceTravelSnapshot
 public func append(_ trip: FinanceTravelTrip, expectedFileRevision: UInt64?) throws -> FinanceTravelReceipt
 public func update(_ trip: FinanceTravelTrip, expectedRevision: UInt64) throws -> FinanceTravelReceipt
 public func delete(id: UUID, expectedRevision: UInt64) throws -> FinanceTravelReceipt
}
public struct FinanceTravelProjection: Equatable, Sendable {
 public let tripCount: Int; public let knownCountryCounts: [String: Int]; public let unknownTripCount: Int
 public static func project(_ snapshot: FinanceTravelSnapshot) -> Self
}
```

The file is `finance-travel.json` in the existing LifeOS Application Support directory. `append` rejects an
existing live ID; `update` requires the current trip revision; `delete` creates a tombstone and receipt. Every
mutation reads, validates, increments `fileRevision`, appends a receipt, encodes a candidate, flushes the same-volume
temporary file, then uses `replaceItemAt`; the old file remains valid until replacement. `recover` validates the
primary and any temporary candidate, keeps the primary when the candidate is incomplete, and rejects corruption
without returning an empty snapshot. Conflict, disk-full, cancellation and stale expected revision preserve the old
file and return a typed error. Projection is pure O(n) with one country dictionary; no inference or network occurs.

## Data-management values and commands

```swift
public enum LifeOSDataStoreID: String, Codable, Sendable {
 case calendar, financeImports, financeRecurring, financeInvestments, financeBudgets, financeAllocations
 case financePreferences, financeTravel, training, trainingTemplates, meals, nutritionGoals, supplements, journal
 case lifestyle, barcodeRecords, planningJournal, planningFiles, taxSanitized, taxRaw, usageLocal, clipperLocal
 case replicationTrust, widgetSnapshot
}
public enum LifeOSDataOperation: String, Codable, Sendable { case export, restore, delete }
public enum LifeOSDataOperationState: String, Codable, Sendable { case prepared, running, interrupted, failed, committed }
public struct LifeOSDataEntry: Codable, Equatable, Sendable {
 public let storeID: LifeOSDataStoreID; public let relativePath: String; public let schemaVersion: Int
 public let contentHash: String; public let bytes: String?; public let exportable: Bool
}
public struct LifeOSDataArchive: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let archiveID: UUID; public let createdAt: Date
 public let entries: [LifeOSDataEntry]; public let manifestHash: String
}
public struct LifeOSDataReceipt: Codable, Equatable, Sendable {
 public let operationID: UUID; public let operation: LifeOSDataOperation; public let state: LifeOSDataOperationState
 public let archiveID: UUID?; public let archiveHash: String?; public let parentReceiptID: UUID?
 public let completed: [LifeOSDataStoreID]; public let nextIndex: Int; public let errorCode: String?
}
```

`LifeOSDataArchive.schemaVersion == 1`, entries are sorted by store ID, max26 entries and32MiB total decoded bytes.
Export receipts set `archiveID` and null `archiveHash`; restore receipts set both to the verified archive identity;
delete receipts set both null. `parentReceiptID` points to the prior interrupted/prepared receipt for the same operation
lineage and is null only for the first receipt. Receipt IDs, archive hashes and lineage are validated before mutation.
`taxRaw` and original nutrition photos have `exportable=false`, `bytes=nil`, but their protected paths are included
in the manifest so deletion and audit cannot omit them. `taxSanitized` contains only the R4 publication whitelist.
No credentials, private keys, HealthKit anchors, vault bookmarks or raw provider payloads leave the device.

```swift
public actor LifeOSDataManagement {
 public init(registry: LifeOSDataStoreRegistry, fileManager: FileManager = .default)
 public func recover() async throws -> [LifeOSDataReceipt]
 public func export() async throws -> (LifeOSDataArchive, LifeOSDataReceipt)
 public func restore(_ archive: LifeOSDataArchive) async throws -> LifeOSDataReceipt
 public func deleteUserData() async throws -> LifeOSDataReceipt
}
public struct LifeOSDataStoreRegistry: Sendable {
 public let entries: [LifeOSDataStoreDescriptor]
 public init(entries: [LifeOSDataStoreDescriptor]) throws
}
public struct LifeOSDataStoreDescriptor: Sendable {
 public let id: LifeOSDataStoreID; public let relativePaths: [String]; public let schemaVersion: Int
 public let exportable: Bool
 public init(id: LifeOSDataStoreID, relativePaths: [String], schemaVersion: Int, exportable: Bool)
}
```

The registry is a closed allowlist containing every ID above and the existing filenames: `calendar.json`, the six
finance files from R4-04 plus `finance-travel.json`, `fitness-training-ledger.json`,
`fitness-strength-templates.json`, `nutrition-meals.json`, `nutrition-goals.json`, `supplements-v1.json`,
`fitness-journal.json`, `fitness-lifestyle-ledger.json`, `nutrition-barcode-records.json`, Planning's existing
`journal.sqlite`/`cache`/`filesystem` paths, Tax's `documents.json`/`raw/<UUID>.json`/`originals/<UUID>.pdf`, the
existing usage-history key, Clipper's existing local revocation/cache paths, `trust.json`, and the protected widget
snapshot. No caller supplies an arbitrary path.

Export writes a receipt before reading, advances `nextIndex` after each hashed entry, and atomically writes the final
archive plus committed receipt. Restore verifies all hashes and schema before the first write, then restores entries in
registry order using each store's existing atomic transaction; it resumes from `nextIndex` after interruption. Delete
uses the same receipt protocol, removes user content only after its manifest entry is durable, and regenerates a
redacted widget snapshot last. Repeating an operation ID returns its receipt; a changed archive hash is `idCollision`.
Restore skips `exportable=false` entries and preserves their protected local content; it never treats omitted raw tax,
photo, credential, bookmark or HealthKit data as an instruction to delete. A crash at any receipt/entry boundary leaves
the prior store revision or the durable completed prefix; restart follows the receipt lineage rather than starting over.
Release evidence covers every inventory row, crash before/after each entry, disk-full, locked-device, invalid archive,
raw-tax/photo exclusion, restart recovery and a final zero-sensitive-path audit.

## Revision7 supersession

R7-05 replaces the v1 `LifeOSDataArchive`/24-ID shape with the exact 26-pack directory archive, content-addressed
chunks, recovery-imports pack, original-photo policy and receipt lineage. The local travel store signatures remain
valid; its pack adapter is now owned by R7-05.
