import Foundation

public actor SyncEngine {
    private let adapters: [any SyncDomainAdapter]
    private let transport: SyncTransport
    private let identity: SyncIdentityStore
    private let frontierStore: any SyncFrontierStore
    private let endpoint: SyncEndpoint
    private var generation: UInt64 = 0
    private var running = false
    private var stopped = false

    public init(
        adapters: [any SyncDomainAdapter],
        transport: SyncTransport,
        identity: SyncIdentityStore,
        frontierStore: any SyncFrontierStore,
        endpoint: SyncEndpoint
    ) throws {
        let set = try SyncAdapterSet(adapters: adapters)
        self.adapters = set.adapters
        self.transport = transport
        self.identity = identity
        self.frontierStore = frontierStore
        self.endpoint = endpoint
    }

    public func stop() async {
        stopped = true
        generation &+= 1
    }

    public func resume() async {
        stopped = false
    }

    public func synchronizeOnce(reason: SyncReason) async throws -> SyncCycleReport {
        guard !running else { throw SyncFailure.busy }
        guard !stopped else { throw SyncFailure.cancelled }
        running = true
        let cycleGeneration = generation
        defer { running = false }

        do {
            for adapter in adapters {
                try Task.checkCancellation()
                try await adapter.recover()
                try ensureCurrent(cycleGeneration)
            }

            var frontier = try await frontierStore.loadFrontier()
            try SyncWireCodec.validate(frontier)
            var stored = 0
            var applied = 0
            var conflicts = 0
            var blocked = 0
            var pending = 0
            var endpointID = ""
            let localIdentity = try await identity.identity()
            let maximumExchanges = reason == .background ? 1 : 5

            for adapter in adapters {
                var pageCursor: SyncFrontier? = nil
                var exchanges = 0
                var hasMore = true
                while hasMore && exchanges < maximumExchanges {
                    try Task.checkCancellation()
                    try ensureCurrent(cycleGeneration)
                    let page = try await adapter.pendingPage(after: pageCursor, limit: SyncContractConstants.maxPageOperations)
                    try ensureCurrent(cycleGeneration)
                    pending += page.operations.count
                    let request = SyncExchangeRequest(
                        schemaVersion: 1,
                        storeID: adapter.storeID,
                        received: frontier,
                        upper: nil,
                        operations: page.operations,
                        acknowledgements: page.acknowledgements,
                        limit: min(SyncContractConstants.maxPageOperations, max(1, page.operations.count))
                    )
                    let response = try await exchangeWithRetry(request)
                    try ensureCurrent(cycleGeneration)
                    endpointID = endpoint.id
                    stored += response.results.filter { $0.disposition == "stored" || $0.disposition == "alreadyStored" }.count

                    for operation in response.operations {
                        do {
                            let receipt = try await adapter.applyRemote(operation)
                            try ensureCurrent(cycleGeneration)
                            let acknowledgement = try await identity.signAcknowledgement(
                                SyncAck(
                                    schemaVersion: 1,
                                    datasetID: operation.datasetID,
                                    epoch: operation.epoch,
                                    storeID: operation.storeID,
                                    mutationID: operation.mutationID,
                                    operationHash: try SyncWireCodec.operationHash(for: operation),
                                    replicaID: localIdentity.deviceID,
                                    keyID: localIdentity.keyID,
                                    level: receipt.disposition == .retainedConflict ? .retainedConflict : .applied,
                                    resultHash: receipt.entityVersion,
                                    signature: ""
                                )
                            )
                            try await adapter.recordAcknowledgement(acknowledgement)
                            switch receipt.disposition {
                            case .retainedConflict:
                                conflicts += 1
                            case .blockedParent:
                                blocked += 1
                            case .applied, .alreadyApplied:
                                applied += 1
                            case .rejected:
                                blocked += 1
                            }
                        } catch SyncFailure.missingParent {
                            blocked += 1
                        } catch SyncFailure.conflict {
                            conflicts += 1
                        }
                    }
                    for acknowledgement in response.acknowledgements {
                        try await adapter.recordAcknowledgement(acknowledgement)
                    }

                    frontier = response.upper
                    try SyncWireCodec.validate(frontier)
                    try await frontierStore.persist(frontier)
                    pageCursor = page.cursor
                    hasMore = response.more || page.hasMore
                    exchanges += 1
                    if page.operations.isEmpty && response.operations.isEmpty && response.acknowledgements.isEmpty {
                        hasMore = false
                    }
                }
                _ = try await adapter.checkpoint(frontier)
                try ensureCurrent(cycleGeneration)
            }

            return SyncCycleReport(
                stored: stored,
                applied: applied,
                conflicts: conflicts,
                blocked: blocked,
                pending: pending,
                endpointID: endpointID,
                completedAt: Date()
            )
        } catch is CancellationError {
            throw SyncFailure.cancelled
        } catch let failure as SyncFailure {
            throw failure
        } catch {
            throw SyncFailure.offline
        }
    }

    private func exchangeWithRetry(_ request: SyncExchangeRequest) async throws -> SyncExchangeResponse {
        var attempt = 0
        var delayNanoseconds: UInt64 = 50_000_000
        while true {
            do {
                return try await transport.exchange(request: request, endpoint: endpoint)
            } catch let failure as SyncFailure where failure == .offline || failure == .timedOut {
                guard attempt < 4 else { throw failure }
                attempt += 1
                try await Task.sleep(nanoseconds: delayNanoseconds)
                delayNanoseconds = min(delayNanoseconds * 2, 1_000_000_000)
            }
        }
    }

    private func ensureCurrent(_ cycleGeneration: UInt64) throws {
        guard cycleGeneration == generation, !stopped else { throw SyncFailure.staleGeneration }
    }
}
