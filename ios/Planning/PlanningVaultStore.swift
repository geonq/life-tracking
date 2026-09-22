import Foundation

public actor PlanningVaultStore {
    public let applicationSupportDirectory: URL
    public let deviceID: UUID

    private let access: PlanningVaultAccess
    private let coordination: PlanningCoordinatedAccess
    private let testBarrier: ((PlanningFilesystemBarrier) throws -> Void)?
    private let clock: () -> Date
    private var journal: PlanningMutationJournal?
    private var publication: PlanningFilesystemPublication?
    private var cache: PlanningVaultCache?
    private var recoveryCursor: PlanningPublicationRecoveryCursor?

    public init(
        applicationSupportDirectory: URL,
        deviceID: UUID = UUID()
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.deviceID = deviceID
        self.access = PlanningVaultAccess(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID
        )
        self.coordination = PlanningCoordinatedAccess()
        self.testBarrier = nil
        self.clock = { Date() }
    }

    internal init(
        access: PlanningVaultAccess,
        applicationSupportDirectory: URL,
        deviceID: UUID,
        coordination: PlanningCoordinatedAccess = PlanningCoordinatedAccess(),
        testBarrier: ((PlanningFilesystemBarrier) throws -> Void)? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.deviceID = deviceID
        self.access = access
        self.coordination = coordination
        self.testBarrier = testBarrier
        self.clock = clock
    }

    internal static func makeTesting(
        rootURL: URL,
        applicationSupportDirectory: URL,
        deviceID: UUID = UUID(),
        coordination: PlanningCoordinatedAccess = PlanningCoordinatedAccess(),
        testBarrier: ((PlanningFilesystemBarrier) throws -> Void)? = nil,
        clock: @escaping () -> Date = { Date() }
    ) throws -> PlanningVaultStore {
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: rootURL,
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID
        )
        return PlanningVaultStore(
            access: access,
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID,
            coordination: coordination,
            testBarrier: testBarrier,
            clock: clock
        )
    }

    @discardableResult
    public func select(
        selection: PlanningUserSelectedDirectory,
        intent: PlanningVaultSelectionIntent
    ) throws -> PlanningVaultAccessSnapshot {
        if case let .attach(expectedVaultID) = intent {
            let identity = try access.inspectExistingSelection(selection)
            guard identity.vaultID == expectedVaultID else {
                throw PlanningFilesystemError.identityChanged
            }
            let prepared = try prepareResources(for: expectedVaultID)
            do {
                let snapshot = try access.select(selection: selection, intent: intent)
                install(prepared)
                return snapshot
            } catch {
                prepared.closeIfOwned()
                if access.snapshot.state != .ready {
                    discardResources()
                }
                throw error
            }
        }
        var prepared: PreparedResources?
        do {
            let snapshot = try access.select(selection: selection, intent: intent) { vaultID in
                prepared = try prepareResources(for: vaultID)
            }
            // Access has committed; installation cannot throw or suspend.
            if let prepared {
                install(prepared)
            }
            return snapshot
        } catch {
            prepared?.closeIfOwned()
            if access.snapshot.state != .ready {
                discardResources()
            }
            throw error
        }
    }

    /// Attaches an existing, explicitly selected vault. Inspection is kept
    /// separate from selection so the marker identity is checked before the
    /// store changes its active generation; `select` then validates it again
    /// immediately before taking authority.
    @discardableResult
    public func attachExisting(
        selection: PlanningUserSelectedDirectory
    ) throws -> PlanningVaultAccessSnapshot {
        let identity = try access.inspectExistingSelection(selection)
        return try select(
            selection: selection,
            intent: .attach(expectedVaultID: identity.vaultID)
        )
    }

    @discardableResult
    public func restore() throws -> PlanningVaultAccessSnapshot {
        var prepared: PreparedResources?
        do {
            let snapshot = try access.restore { vaultID in
                prepared = try prepareResources(for: vaultID)
            }
            // No suspension or throwing operation between restored access and
            // installation. Existing resources remain intact until this point.
            if let prepared {
                install(prepared)
            } else {
                discardResources()
            }
            return snapshot
        } catch {
            // Reused resources are closed by discard; newly owned candidates
            // are distinct from the installed journal and are closed here.
            prepared?.closeIfOwned()
            discardResources()
            throw error
        }
    }

    private func discardResources() {
        journal?.close()
        journal = nil
        publication = nil
        cache = nil
        recoveryCursor = nil
    }

    public func read(_ path: PlanningStoredPath) throws -> PlanningVaultReadResult {
        do {
            return try readImplementation(path)
        } catch {
            PlanningDiagnostics.emit(
                PlanningDiagnostic(
                    stage: .storeRead,
                    code: PlanningDiagnostics.code(for: error)
                )
            )
            throw error
        }
    }

    private func readImplementation(_ path: PlanningStoredPath) throws -> PlanningVaultReadResult {
        guard let vaultID = access.snapshot.vaultID,
              let generation = access.snapshot.selectionGeneration else {
            throw PlanningFilesystemError.unselected
        }
        guard let cache else { throw PlanningFilesystemError.unavailable("cache") }
        do {
            guard let rootURL = access.selectedRootURL else {
                throw PlanningFilesystemError.unselected
            }
            let token = PlanningCoordinationToken(generation: generation)
            let documentURL = rootURL
                .appendingPathComponent("LifeOS", isDirectory: true)
                .appendingPathComponent(path.value, isDirectory: false)
            let raw = try coordination.read(
                targetURL: documentURL,
                namespaceURL: rootURL,
                token: token
            ) { _ in
                try self.access.withLease(
                    coordinatedRootURL: rootURL,
                    expectedGeneration: generation
                ) { lease in
                    try PlanningSafeFileIO.readBounded(lease, path: path)
                }
            }
            guard let raw else {
                let absent = try PlanningDocumentSnapshot(path: path, bytes: Data(), version: .absent)
                return PlanningVaultReadResult(
                    snapshot: absent,
                    version: .absent,
                    vaultID: vaultID,
                    selectionGeneration: generation,
                    stale: false,
                    accessState: .ready,
                    fromCache: false
                )
            }
            let version = PlanningContentVersion(data: raw.data)
            do {
                let observation = try PlanningFileObservation(
                    path: path,
                    version: version,
                    identity: raw.identity,
                    byteCount: raw.data.count
                )
                let snapshot = try PlanningDocumentSnapshot(
                    path: path,
                    bytes: raw.data,
                    version: version,
                    observation: observation
                )
                try? cache.store(snapshot, vaultID: vaultID, selectionGeneration: generation)
                return PlanningVaultReadResult(
                    snapshot: snapshot,
                    version: version,
                    vaultID: vaultID,
                    selectionGeneration: generation,
                    stale: false,
                    accessState: .ready,
                    fromCache: false
                )
            } catch {
                if let cached = try? cache.loadLatest(
                    vaultID: vaultID,
                    selectionGeneration: generation,
                    path: path
                ) {
                    return PlanningVaultReadResult(
                        snapshot: cached,
                        version: cached.version,
                        vaultID: vaultID,
                        selectionGeneration: generation,
                        stale: true,
                        accessState: .temporarilyUnavailable,
                        fromCache: true
                    )
                }
                throw PlanningFilesystemError.malformedDocument
            }
        } catch let error as PlanningFilesystemError {
            if let cached = try? cache.loadLatest(
                vaultID: vaultID,
                selectionGeneration: generation,
                path: path
            ) {
                switch error {
                case .providerOffline, .notDownloaded, .permissionDenied, .unavailable:
                    return PlanningVaultReadResult(
                        snapshot: cached,
                        version: cached.version,
                        vaultID: vaultID,
                        selectionGeneration: generation,
                        stale: true,
                        accessState: .temporarilyUnavailable,
                        fromCache: true
                    )
                default:
                    break
                }
            }
            throw error
        } catch {
            throw PlanningFilesystemError.unavailable("read")
        }
    }

    @discardableResult
    public func stage(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext? = nil
    ) throws -> PlanningMutationReceipt {
        let snapshot = access.snapshot
        guard snapshot.state == .ready else { throw PlanningFilesystemError.unselected }
        try validate(expectedContext: expectedContext, against: snapshot)
        guard let journal else { throw PlanningFilesystemError.unselected }
        return try journal.stageMutation(request)
    }

    public func publish(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext? = nil
    ) throws -> PlanningFilesystemPublishResult {
        let snapshot = access.snapshot
        try validate(expectedContext: expectedContext, against: snapshot)
        guard let publication else { throw PlanningFilesystemError.unselected }
        guard snapshot.capabilities.canPublish else {
            throw PlanningFilesystemError.unsupportedFilesystem
        }
        return try publication.publish(request)
    }

    private func validate(
        expectedContext: PlanningCanvasAccessContext?,
        against snapshot: PlanningVaultAccessSnapshot
    ) throws {
        guard let expectedContext else { return }
        guard snapshot.vaultID == expectedContext.vaultID,
              snapshot.selectionGeneration == expectedContext.selectionGeneration,
              snapshot.state == .ready else {
            throw PlanningFilesystemError.needsReselection
        }
    }

    public func publishPendingPage(
        after cursor: PlanningPublicationRecoveryCursor? = nil
    ) throws -> PlanningFilesystemRecoveryReport {
        guard let journal, let publication else { throw PlanningFilesystemError.unselected }
        guard access.snapshot.capabilities.canPublish else {
            throw PlanningFilesystemError.unsupportedFilesystem
        }
        let requestedCursor = cursor ?? recoveryCursor
        let page = try journal.loadPublicationRecoveryPage(after: requestedCursor)
        let startingCursor: PlanningPublicationRecoveryCursor
        if let requestedCursor {
            startingCursor = requestedCursor
        } else {
            startingCursor = try PlanningPublicationRecoveryCursor(
                vaultID: page.nextCursor.vaultID,
                maximumSequence: page.nextCursor.maximumSequence,
                lastExaminedSequence: 0
            )
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var reconciled = 0
        var blocked = 0
        var examined = 0
        var lastExaminedSequence = startingCursor.lastExaminedSequence
        var errors: [String] = []
        var exceededBudget = false
        let hasBudget: () -> Bool = {
            DispatchTime.now().uptimeNanoseconds - startedAt
                < PlanningStorageLimits.recoveryBudgetNanoseconds
        }
        if hasBudget() {
            do {
                errors.append(contentsOf: try publication.cleanupPublishedArtifacts(
                    deadlineNanoseconds: startedAt + PlanningStorageLimits.recoveryBudgetNanoseconds
                ))
            } catch {
                errors.append(planningFilesystemSafeErrorCode(error))
            }
        } else {
            exceededBudget = true
            errors.append("recoveryBudget")
        }
        for entry in page.entries {
            guard hasBudget() else {
                exceededBudget = true
                errors.append("recoveryBudget")
                break
            }
            do {
                let result = try publication.reconcile(entry)
                do {
                    try publication.cleanupPublishedEvidence(
                        for: entry.recovery.request.mutationID
                    )
                } catch {
                    errors.append(planningFilesystemSafeErrorCode(error))
                }
                switch result.status {
                case .published, .reconciled: reconciled += 1
                case .blocked, .conflicted: blocked += 1
                case .staged, .queued: break
                }
                if let errorCode = result.errorCode { errors.append(errorCode) }
            } catch {
                blocked += 1
                errors.append(planningFilesystemSafeErrorCode(error))
            }
            examined += 1
            lastExaminedSequence = entry.sequence
        }
        let nextCursor: PlanningPublicationRecoveryCursor
        if exceededBudget {
            nextCursor = try PlanningPublicationRecoveryCursor(
                vaultID: page.nextCursor.vaultID,
                maximumSequence: page.nextCursor.maximumSequence,
                lastExaminedSequence: lastExaminedSequence
            )
        } else {
            nextCursor = page.nextCursor
        }
        recoveryCursor = exceededBudget || !page.endOfPass ? nextCursor : nil
        return PlanningFilesystemRecoveryReport(
            examined: examined,
            reconciled: reconciled,
            blocked: blocked,
            nextCursor: nextCursor,
            endOfPass: !exceededBudget && page.endOfPass,
            errorCodes: errors
        )
    }

    @discardableResult
    public func resolveConflict(
        _ conflictID: UUID,
        resolution: PlanningConflictResolution
    ) throws -> PlanningConflictResolutionReceipt {
        guard let journal else { throw PlanningFilesystemError.unselected }
        return try journal.resolveConflict(conflictID, resolution: resolution)
    }

    public func status() throws -> PlanningStoreStatus {
        let accessSnapshot = access.snapshot
        guard let journal else {
            return try PlanningStoreStatus(
                accessState: accessSnapshot.state,
                pendingMutationCount: 0,
                openConflictCount: 0,
                retainedPayloadBytes: 0,
                databaseBytes: 0
            )
        }
        let stored = try journal.status()
        return try PlanningStoreStatus(
            accessState: accessSnapshot.state,
            pendingMutationCount: stored.pendingMutationCount,
            openConflictCount: stored.openConflictCount,
            retainedPayloadBytes: stored.retainedPayloadBytes,
            databaseBytes: stored.databaseBytes,
            lastErrorCode: stored.lastErrorCode
        )
    }

    public func currentCanvasAccessContext() throws -> PlanningCanvasAccessContext {
        let snapshot = access.snapshot
        guard snapshot.state == .ready,
              let vaultID = snapshot.vaultID,
              let selectionGeneration = snapshot.selectionGeneration else {
            let error: PlanningFilesystemError = snapshot.state == .needsReselection
                ? .needsReselection
                : .unselected
            PlanningDiagnostics.emit(
                PlanningDiagnostic(stage: .storeContext, code: error.stableCode)
            )
            throw error
        }
        return PlanningCanvasAccessContext(
            vaultID: vaultID,
            selectionGeneration: selectionGeneration
        )
    }

    public func accessSnapshot() -> PlanningVaultAccessSnapshot {
        access.snapshot
    }

    public func resolveCanvasReference(_ reference: String) throws -> PlanningVaultReadResult? {
        guard reference.hasPrefix("LifeOS/") else { return nil }
        let suffix = String(reference.dropFirst("LifeOS/".count)).split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        guard !suffix.isEmpty else { return nil }
        let path = try PlanningStoredPath(suffix)
        return try read(path)
    }

    public func close() {
        journal?.close()
        journal = nil
        publication = nil
        cache = nil
        recoveryCursor = nil
        access.close()
    }

    internal func closeInstalledJournalForTesting() {
        journal?.close()
    }

    private final class PreparedResources {
        let journal: PlanningMutationJournal
        let publication: PlanningFilesystemPublication
        let cache: PlanningVaultCache
        private let ownsJournal: Bool

        init(
            journal: PlanningMutationJournal,
            publication: PlanningFilesystemPublication,
            cache: PlanningVaultCache,
            ownsJournal: Bool
        ) {
            self.journal = journal
            self.publication = publication
            self.cache = cache
            self.ownsJournal = ownsJournal
        }

        func closeIfOwned() {
            if ownsJournal {
                journal.close()
            }
        }
    }

    private func prepareResources(for vaultID: UUID) throws -> PreparedResources {
        if let currentJournal = journal,
           currentJournal.vault.vaultID == vaultID,
           currentJournal.isReady,
           let currentPublication = publication,
           let currentCache = cache {
            // Reattaching the already active vault can reuse the resources
            // that are already prepared without opening the same writer lock.
            return PreparedResources(
                journal: currentJournal,
                publication: currentPublication,
                cache: currentCache,
                ownsJournal: false
            )
        }

        let identity = try PlanningVaultIdentity(vaultID: vaultID)
        let candidateJournal = PlanningMutationJournal(
            applicationSupportDirectory: applicationSupportDirectory,
            vault: identity,
            deviceID: deviceID,
            clock: clock
        )
        do {
            try candidateJournal.openValidated()
        } catch {
            candidateJournal.close()
            throw error
        }
        let candidatePublication = PlanningFilesystemPublication(
            journal: candidateJournal,
            access: access,
            applicationSupportDirectory: applicationSupportDirectory,
            coordination: coordination,
            testBarrier: testBarrier,
            clock: clock
        )
        let candidateCache = PlanningVaultCache(
            directory: applicationSupportDirectory
                .appendingPathComponent("LifeOS", isDirectory: true)
                .appendingPathComponent("Planning", isDirectory: true)
                .appendingPathComponent(vaultID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
        )
        return PreparedResources(
            journal: candidateJournal,
            publication: candidatePublication,
            cache: candidateCache,
            ownsJournal: true
        )
    }

    private func install(_ prepared: PreparedResources) {
        if let currentJournal = journal, currentJournal === prepared.journal {
            return
        }
        let oldJournal = journal
        journal = prepared.journal
        publication = prepared.publication
        cache = prepared.cache
        recoveryCursor = nil
        oldJournal?.close()
    }
}
