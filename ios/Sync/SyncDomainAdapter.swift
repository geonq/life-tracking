import Foundation

public protocol SyncVerifiedPackReader19: Sendable {
    func read(relativePath: String, offset: UInt64, limit: UInt32) throws -> Data
}

public protocol SyncDataStoreAdapter20: Sendable {
    var dataStoreID: LifeOSDataStoreID { get }
    func prepareRestore(_ input: RestorePrepareInput19) async throws -> RestorePrepared19
    func applyRestore(_ context: RestoreApplyContext19, source: any SyncVerifiedPackReader19) async throws -> DataCompletionProof19
    func lookupRestoreProof(_ input: RestorePrepareInput19) async throws -> DataCompletionProof19?
    func inspectRestoreState(_ input: RestorePrepareInput19) async throws -> DataStoreState19
    func prepareDeletion(_ input: DeletionPrepareInput19) async throws -> DeletionPrepared19
    func applyDeletion(_ context: DeletionApplyContext19) async throws -> DeletionAppliedV8
    func inspectDeletion(_ context: DeletionApplyContext19) async throws -> DeletionInspection19
}

public protocol SyncDataManagementProofPort20: Sendable {
    func verifyDataRestoreCompletion(
        receiptID: String,
        workPlan: LifeOSReceiptWorkPlanV8
    ) async throws -> DataRestoreCompletion19
    func persistRemoteDeletionClosure(
        _ closure: RemoteDeletionClosure20
    ) async throws
}

public struct DataRestoreCompletion19: Codable, Equatable, Sendable {
    public let receiptID: String
    public let workPlanHash: String
    public let packProofHashes: [String]
    public let completionRoot: String
    public init(receiptID: String, workPlanHash: String, packProofHashes: [String], completionRoot: String) {
        self.receiptID = receiptID
        self.workPlanHash = workPlanHash
        self.packProofHashes = packProofHashes
        self.completionRoot = completionRoot
    }
}

public protocol SyncDeletionTargetAdapter20: Sendable {
    var dataStoreID: LifeOSDataStoreID { get }
    func prepareDeletion(_ input: DeletionPrepareInput19) async throws -> DeletionPrepared19
    func applyDeletion(_ context: DeletionApplyContext19) async throws -> DeletionAppliedV8
    func inspectDeletion(_ context: DeletionApplyContext19) async throws -> DeletionInspection19
}

public protocol SyncPublicationProofPort20: Sendable {
    func publishFinalWidgetSnapshot() async throws -> String
    func verifyPublicationHash(_ hash: String) async throws
}

public protocol SyncReceiptPersistence20: Sendable {
    func loadFrontier() async throws -> SyncFrontier
    func persistFrontier(_ frontier: SyncFrontier) async throws
    func recordDurableReceipt(_ receipt: SyncCommitReceipt) async throws
    func recordBlocked(_ mutationID: String, reason: SyncFailure) async throws
}

public struct SyncAdapterSet: Sendable {
    public let adapters: [any SyncDomainAdapter]
    public init(adapters: [any SyncDomainAdapter]) throws {
        guard !adapters.isEmpty else {
            self.adapters = []
            return
        }
        var seen = Set<String>()
        for adapter in adapters {
            guard seen.insert(adapter.storeID).inserted else { throw SyncFailure.idCollision }
        }
        self.adapters = adapters.sorted {
            if $0.storeID != $1.storeID { return $0.storeID < $1.storeID }
            return $0.domain.rawValue < $1.domain.rawValue
        }
    }
}
