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
                    let storeFrontier = frontierForStore(adapter.storeID, in: frontier)
                    let request = SyncExchangeRequest(
                        schemaVersion: 1,
                        storeID: adapter.storeID,
                        received: storeFrontier,
                        upper: nil,
                        operations: page.operations,
                        acknowledgements: page.acknowledgements,
                        limit: SyncContractConstants.maxPageOperations
                    )
                    let response = try await exchangeWithRetry(request)
                    try ensureCurrent(cycleGeneration)
                    endpointID = endpoint.id
                    stored += response.results.filter { $0.disposition == "stored" || $0.disposition == "alreadyStored" }.count
                    try SyncWireCodec.verifyResponseRecords(response, endpoint: endpoint, expectedStoreID: adapter.storeID)
                    guard response.storeID == adapter.storeID,
                          response.operations.allSatisfy({ $0.storeID == adapter.storeID }),
                          response.acknowledgements.allSatisfy({ $0.storeID == adapter.storeID }) else {
                        throw SyncFailure.invalidInput
                    }
                    let responseFrontier = try mergedFrontier(response.upper, into: frontier, for: adapter.storeID)
                    var successfulOperationIDs = Set<String>()

                    for operation in response.operations {
                        do {
                            let receipt = try await adapter.applyRemote(operation)
                            try ensureCurrent(cycleGeneration)
                            switch receipt.disposition {
                            case .applied, .alreadyApplied, .retainedConflict:
                                successfulOperationIDs.insert(operation.mutationID)
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
                                if receipt.disposition == .retainedConflict {
                                    conflicts += 1
                                } else {
                                    applied += 1
                                }
                            case .blockedParent, .rejected:
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

                    frontier = try frontierAfterApplying(
                        current: frontier,
                        response: responseFrontier,
                        operations: response.operations,
                        successfulOperationIDs: successfulOperationIDs,
                        storeID: adapter.storeID,
                        acknowledgementCursorID: endpoint.id
                    )
                    try await frontierStore.persist(frontier)
                    pageCursor = page.cursor
                    hasMore = response.more || page.hasMore
                    exchanges += 1
                    if page.operations.isEmpty && response.operations.isEmpty && response.acknowledgements.isEmpty {
                        hasMore = false
                    }
                }
                _ = try await adapter.checkpoint(frontierForStore(adapter.storeID, in: frontier))
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

    private func frontierForStore(_ storeID: String, in frontier: SyncFrontier) -> SyncFrontier {
        SyncFrontier(
            positions: frontier.positions.filter { $0.stream.storeID == storeID }
        )
    }

    private func mergedFrontier(
        _ storeFrontier: SyncFrontier,
        into globalFrontier: SyncFrontier,
        for storeID: String
    ) throws -> SyncFrontier {
        guard storeFrontier.positions.allSatisfy({ $0.stream.storeID == storeID }) else {
            throw SyncFailure.invalidInput
        }
        let foreignPositions = globalFrontier.positions.filter { $0.stream.storeID != storeID }
        let positions = (foreignPositions + storeFrontier.positions).sorted {
            if $0.stream.storeID != $1.stream.storeID {
                return $0.stream.storeID < $1.stream.storeID
            }
            return $0.stream.originID < $1.stream.originID
        }
        let merged = SyncFrontier(positions: positions)
        try SyncWireCodec.validate(merged)
        return merged
    }

    private func frontierAfterApplying(
        current: SyncFrontier,
        response: SyncFrontier,
        operations: [SyncOperation],
        successfulOperationIDs: Set<String>,
        storeID: String,
        acknowledgementCursorID: String
    ) throws -> SyncFrontier {
        var currentThrough: [String: UInt64] = [:]
        for position in current.positions where position.stream.storeID == storeID {
            currentThrough[position.stream.originID] = try SyncContractValidation.requireUnsigned(position.through)
        }
        var responseThrough: [String: UInt64] = [:]
        for position in response.positions where position.stream.storeID == storeID {
            responseThrough[position.stream.originID] = try SyncContractValidation.requireUnsigned(position.through)
        }
        var operationsByOrigin: [String: [SyncOperation]] = [:]
        for operation in operations {
            operationsByOrigin[operation.originID, default: []].append(operation)
        }
        var safeThrough = currentThrough
        for (originID, target) in responseThrough {
            guard target >= currentThrough[originID, default: 0] else {
                throw SyncFailure.invalidInput
            }
            if originID == acknowledgementCursorID {
                // The gateway cursor is advanced only after the response
                // acknowledgements above have been verified and persisted.
                safeThrough[originID] = target
                continue
            }
            guard let originOperations = operationsByOrigin[originID], !originOperations.isEmpty else {
                // A signed server response can advertise an upper frontier
                // without presenting any device-signed records for it. Keep
                // the durable client frontier unchanged until the contiguous
                // operations have actually been verified and applied.
                safeThrough[originID] = currentThrough[originID, default: 0]
                continue
            }
            var next = safeThrough[originID, default: 0]
            for operation in originOperations.sorted(by: { left, right in
                let leftSequence = (try? SyncContractValidation.requireUnsigned(left.sequence)) ?? 0
                let rightSequence = (try? SyncContractValidation.requireUnsigned(right.sequence)) ?? 0
                return leftSequence < rightSequence
            }) {
                let sequence = try SyncContractValidation.requireUnsigned(operation.sequence, positive: true)
                guard next < UInt64.max,
                      sequence == next + 1,
                      successfulOperationIDs.contains(operation.mutationID) else {
                    break
                }
                next = sequence
            }
            safeThrough[originID] = min(target, max(safeThrough[originID, default: 0], next))
        }
        let foreignPositions = response.positions.filter { $0.stream.storeID != storeID }
        let storePositions = safeThrough.map { originID, through in
            SyncPosition(
                stream: SyncStream(storeID: storeID, originID: originID),
                through: String(through)
            )
        }
        let merged = SyncFrontier(positions: (foreignPositions + storePositions).sorted {
            if $0.stream.storeID != $1.stream.storeID {
                return $0.stream.storeID < $1.stream.storeID
            }
            return $0.stream.originID < $1.stream.originID
        })
        try SyncWireCodec.validate(merged)
        return merged
    }
}
