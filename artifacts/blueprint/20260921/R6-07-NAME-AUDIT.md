# Revision6 new-name and leaf-binding audit
Planning-only. This is the signature index for every name introduced or changed by R5; a Luna worker may not invent a
replacement. R6-01…06 are the detailed contracts; this sheet closes the remaining cross-sheet references.

## Cross-cutting signatures
```swift
public struct StorageProtectionAuditReport: Sendable {
 public let protectedPaths: [String]; public let unprotectedPaths: [String]; public let missingPaths: [String]
 public let passed: Bool
}
public enum StorageProtectionAuditError: Error, Sendable { case missing, unprotected, symlink, unreadable, invalidRegistry }
public enum StorageProtectionAudit {
 public static func inspect(_ registry: LifeOSDataStoreRegistry, fileManager: FileManager = .default) throws -> StorageProtectionAuditReport
}
public struct FitnessCompactionReceipt: Sendable { public let planID: UUID; public let removed: [String]; public let contentHash: String }
public enum FitnessCompactionError: Error, Sendable { case stalePlan, invalidPlan, diskFull, protectedAsset, interrupted }
public actor FitnessCompactionExecutor {
 public init(fileManager: FileManager = .default)
 public func commit(_ plan: FitnessCompactionPlan, expectedFingerprint: String) throws -> FitnessCompactionReceipt
}
public protocol BankReadbackTransport: Sendable { func fetchFinanceReadback() async throws -> FinanceReadbackResult }
public struct BankReadbackClient: BankReadbackProvider {
 public init(transport: any BankReadbackTransport)
 public func readback() async throws -> FinanceReadbackResult
}
public struct DisabledBankReadbackProvider: BankReadbackProvider {
 public init()
 public func readback() async throws -> FinanceReadbackResult
}
```
`StorageProtectionAudit.inspect` is read-only and maps every R6-02 registry entry; `FitnessCompactionExecutor.commit`
accepts only a previously validated `FitnessCompactionPlan`, rechecks its fingerprint and uses the existing retention
transaction. `BankReadbackClient` conforms `TailscaleSyncClient` to `BankReadbackTransport`; it maps cancellation and
transport failures exactly to R5-05. The disabled provider always throws `.unavailable(.missingConfiguration)`.

## Recovery and Planning signatures
```swift
public struct VerifiedRecoveryArchive: Sendable {
 public let archiveHash: String; public let verification: RecoveryVerificationStatus; public let storeID: SyncStoreKind
 public let sourceEpoch: String; public let operations: [SyncOperation]
}
public enum RecoveryArchiveVerifier {
 public static func verify(_ bytes: Data, trust: SyncTrustRecordV2) throws -> VerifiedRecoveryArchive
}
extension SyncTrustStore {
 public func prepareImport(_ bytes: Data, targetDeviceID: String) async throws -> ArchiveImportReceiptV2
 public func commitImport(_ bytes: Data, targetDeviceID: String, adapters: [SyncStoreKind: any SyncDomainAdapter]) async throws -> ArchiveImportReceiptV2
}
extension PlanningMutationJournal {
 public func stageReplicatedMutation(_ operation: SyncOperation, payload: Data) throws -> PlanningMutationReceipt
}
```
`RecoveryArchiveVerifier.verify` is pure and performs the R6-04 verification order; it never writes. `prepareImport`
performs steps 1…3 of R6-05 and is idempotent. `commitImport` resumes the receipt state and is the only projecting
entry point. `stageReplicatedMutation` uses the existing `journal.sqlite` writer lock and transaction; it does not
create `sync_operations.sqlite` or bypass `PlanningMutationJournal`.

## Data-management and Calendar signatures
`LifeOSDataStoreRegistry` has `public let entries: [LifeOSDataStoreDescriptor]` and
`public init(entries: [LifeOSDataStoreDescriptor]) throws`; `LifeOSDataStoreDescriptor` has
`public init(id:relativePaths:schemaVersion:exportable:)`. The exact public methods are R6-02.
Calendar `makeBeginContext`, `commit`, `commitReplicatedSeries` and `commitReplicatedDeletion` are only the R6-06
signatures. Finance travel `load/append/update/delete` and `FinanceTravelProjection.project` are only R6-02.
No view, widget renderer, usage watcher or clipper reader is a hidden data owner.

## Leaf audit corrections
R5-01 RF-02 now binds `FinanceAnalyticsView.body`, all four `FinanceTravelStore` commands and
`FinanceTravelProjection.project`; it is local manual data, not a finance refresh or replicated kind. R5-01 BF-0384
binds fitness route selection, HealthKit/lifestyle refresh and meal projections; no meal-saving command is used for a
fitness route row. R5-01 DT-03A binds `NutritionPhotoRetentionPolicy` and `FitnessCompactionExecutor`, never a sync or
build helper. R5-01 DT-02C binds R6-02 data management, with its registry/receipt protocol. DA-05/DA-07 use the local
Usage and read-only Clipper owners in R6-01 and have no replicated deletion. Every other R5 leaf was re-read for the
same noun/verb mismatch; a generic `body`, `refresh`, build, or replication helper remains only where the row is truly
read-only or cross-cutting, and its acceptance row names the actual source/command.

## Review gate for unavoidable source drift
If a named existing symbol is absent or its isolation differs, the worker stops before editing and records the exact
source path, current declaration, and proposed compatibility shim in an Astra checkpoint. The checkpoint must bind the
shim to one of these signatures or amend this sheet; it may not add a parallel store, change a closed enum, or silently
rename a persistence owner.

## Revision7 supersession

R7-06 is the final cross-sheet audit and no-guessing checklist. R7-01…05 own every new recovery, envelope, Calendar and
data-management name; R6-07 remains the checkpoint rule for source drift and the R5 leaf-owner corrections.
