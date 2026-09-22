import Combine
import Foundation

private final class PlanningWorkspaceLeaseRegistry: @unchecked Sendable {
    static let shared = PlanningWorkspaceLeaseRegistry()

    private let lock = NSLock()
    private var owners: [String: UUID] = [:]

    func acquire(key: String, owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owners[key] == nil || owners[key] == owner else { return false }
        owners[key] = owner
        return true
    }

    func release(key: String, owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard owners[key] == owner else { return }
        owners.removeValue(forKey: key)
    }
}

private final class PlanningWorkspaceLeaseToken: @unchecked Sendable {
    private let registry: PlanningWorkspaceLeaseRegistry
    private let key: String
    private let owner: UUID
    private let lock = NSLock()
    private var didRelease = false

    init(
        registry: PlanningWorkspaceLeaseRegistry,
        key: String,
        owner: UUID
    ) {
        self.registry = registry
        self.key = key
        self.owner = owner
    }

    func release() {
        lock.lock()
        guard !didRelease else {
            lock.unlock()
            return
        }
        didRelease = true
        lock.unlock()
        registry.release(key: key, owner: owner)
    }

    deinit {
        release()
    }
}

/// The lifecycle states exposed by the Calendar planning surface. A state is
/// deliberately narrower than the filesystem state: it describes what the
/// user can do next without claiming that a stale read is current.
public enum PlanningWorkspacePhase: String, Equatable, Sendable {
    case idle
    case restoring
    case unselected
    case attaching
    case ready
    case opening
    case showingCanvas
    case needsReselection
    case unavailable
    case failed
}

public enum PlanningWorkspaceFailureCategory: String, Equatable, Sendable {
    case invalidPath
    case notFound
    case needsReselection
    case unavailable
    case readFailed
    case decodeFailed
    case contextMismatch
    case readOnly
    case unknown
}

private enum PlanningWorkspaceRetryIntent: Equatable {
    case restore
    case openPath(String)
}

private struct PlanningWorkspacePresentationToken: Equatable, Sendable {
    let id: UUID
}

/// Read-only production adapter for the first mounted Canvas workspace. It
/// keeps all filesystem authority inside PlanningVaultStore while ensuring an
/// absent Canvas is an error rather than the session's empty-document case.
public actor PlanningReadOnlyCanvasPersistence: PlanningCanvasPersistence {
    private let store: PlanningVaultStore

    public init(store: PlanningVaultStore) {
        self.store = store
    }

    public func context() async throws -> PlanningCanvasAccessContext {
        try await store.currentCanvasAccessContext()
    }

    public func read(_ path: PlanningStoredPath) async throws -> PlanningCanvasPersistenceRead {
        let result = try await store.read(path)
        guard result.version != .absent,
              let snapshot = result.snapshot,
              let vaultID = result.vaultID,
              let selectionGeneration = result.selectionGeneration else {
            throw PlanningFilesystemError.notFound
        }
        let context = PlanningCanvasAccessContext(
            vaultID: vaultID,
            selectionGeneration: selectionGeneration
        )
        return PlanningCanvasPersistenceRead(
            path: path,
            bytes: snapshot.bytes,
            version: result.version,
            isAbsent: false,
            stale: result.stale,
            accessState: result.accessState,
            context: context
        )
    }

    public func stage(
        _: PlanningMutationRequest,
        expectedContext _: PlanningCanvasAccessContext
    ) async throws -> PlanningMutationReceipt {
        throw PlanningFilesystemError.readOnly
    }

    public func publish(
        _: PlanningMutationRequest,
        expectedContext _: PlanningCanvasAccessContext
    ) async throws -> PlanningFilesystemPublishResult {
        throw PlanningFilesystemError.readOnly
    }
}

/// Owns one planning workspace per app scene. Store lifecycle operations are
/// serialized through a cancellable task chain; the generation check remains
/// necessary because a synchronous actor operation may complete after task
/// cancellation.
@MainActor
public final class PlanningWorkspaceCoordinator: ObservableObject {
    private static let ownerDefaultsKey = "LifeOS.planning.localGrantOwner.v1"

    public let localGrantOwnerID: UUID
    public let store: PlanningVaultStore

    @Published public private(set) var phase: PlanningWorkspacePhase = .idle
    @Published public private(set) var accessSnapshot: PlanningVaultAccessSnapshot
    @Published public private(set) var project: PlanningProjectCoordinator?
    @Published public private(set) var openedPath: PlanningStoredPath?
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastFailure: PlanningWorkspaceFailureCategory?
    @Published public private(set) var lastDiagnostic: PlanningDiagnostic?
    @Published public private(set) var isMounted = false
    @Published public var pathInput: String

    private let coordinatorID = UUID()
    private let workspaceKey: String
    private var workspaceLease: PlanningWorkspaceLeaseToken?
    private var operationGeneration: UInt64 = 0
    private var lifecycleTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupID: UUID?
    private var retryIntent: PlanningWorkspaceRetryIntent = .restore
    private var presentationTokenID = UUID()
#if DEBUG
    /// Test-only suspension point for exercising generation and teardown races
    /// against the real store/session pipeline. It is absent from release code.
    nonisolated(unsafe) internal static var beforeDeinitStoreClose: (@Sendable () async -> Void)?
    internal var beforePresentationOpen: (@Sendable () async -> Void)?
    /// Test-only suspension point between retry restoration and Canvas opening.
    internal var beforeRetryOpen: (@Sendable () async -> Void)?
    /// Test-only suspension point before the non-supersedable store cleanup.
    internal var beforeCleanupClose: (@Sendable () async -> Void)?
#endif

    public init(
        applicationSupportDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        defaultCanvasPath: String = "Projects/Personal.canvas"
    ) {
        let ownerID: UUID
        if let stored = defaults.string(forKey: Self.ownerDefaultsKey),
           let decoded = UUID(uuidString: stored) {
            ownerID = decoded
        } else {
            ownerID = UUID()
            defaults.set(ownerID.uuidString.lowercased(), forKey: Self.ownerDefaultsKey)
        }

        let support = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LifeOS", isDirectory: true)
        self.localGrantOwnerID = ownerID
        self.workspaceKey = support.standardizedFileURL.path
        self.store = PlanningVaultStore(
            applicationSupportDirectory: support,
            deviceID: ownerID
        )
        self.accessSnapshot = PlanningVaultAccessSnapshot(
            state: .unselected,
            vaultID: nil,
            selectionGeneration: nil,
            rootIdentity: nil,
            lifeOSIdentity: nil,
            capabilities: .unavailableSignedApp,
            providerIdentifier: nil
        )
        self.pathInput = defaultCanvasPath
    }

    deinit {
        lifecycleTask?.cancel()
        let store = self.store
        // The lease must outlive asynchronous store closure. Capturing the
        // token keeps its registry entry alive until the journal/scope close
        // has completed, so another workspace cannot enter during that gap.
        let lease = workspaceLease
#if DEBUG
        let beforeDeinitStoreClose = Self.beforeDeinitStoreClose
#endif
        Task { [store, lease] in
#if DEBUG
            if let beforeDeinitStoreClose {
                await beforeDeinitStoreClose()
            }
#endif
            await store.close()
            lease?.release()
            withExtendedLifetime(lease) {}
        }
    }

    internal init(
        store: PlanningVaultStore,
        localGrantOwnerID: UUID,
        defaultCanvasPath: String = "Projects/Personal.canvas"
    ) {
        self.localGrantOwnerID = localGrantOwnerID
        self.workspaceKey = store.applicationSupportDirectory.standardizedFileURL.path
        self.store = store
        self.accessSnapshot = PlanningVaultAccessSnapshot(
            state: .unselected,
            vaultID: nil,
            selectionGeneration: nil,
            rootIdentity: nil,
            lifeOSIdentity: nil,
            capabilities: .unavailableSignedApp,
            providerIdentifier: nil
        )
        self.pathInput = defaultCanvasPath
    }

    public var isBusy: Bool {
        switch phase {
        case .restoring, .attaching, .opening: true
        case .idle, .unselected, .ready, .showingCanvas, .needsReselection, .unavailable, .failed: false
        }
    }

    /// Marks the workspace as mounted and resumes persisted access after any
    /// prior unmount cleanup has completed. A remount always owns the same
    /// coordinator/store instance; it never creates a second store.
    public func mount() async {
        requestMount()
        let task = lifecycleTask
        if let task {
            await task.value
        }
    }

    /// Synchronous counterpart used by SwiftUI appearance callbacks. It
    /// records mount ownership before scheduling work, so an immediate
    /// disappear/reappear cannot be lost between two unstructured Tasks.
    public func requestMount() {
        isMounted = true
        guard phase == .idle else { return }
        retryIntent = .restore
        let token = beginPresentationOperation()
        _ = startRestore(ownedBy: token)
    }

    /// Invalidates presentation immediately, then performs non-supersedable
    /// store and lease cleanup. A subsequent mount is queued behind this
    /// cleanup and can therefore restore deterministically.
    public func unmount() async {
        requestUnmount()
        let task = cleanupTask
        if let task {
            await task.value
        }
    }

    /// Synchronous counterpart used by SwiftUI disappearance callbacks. The
    /// cleanup task itself remains serialized and non-supersedable.
    public func requestUnmount() {
        isMounted = false
        invalidatePresentation(markIdle: true)
        _ = scheduleCleanup()
    }

    public func restore() async {
        retryIntent = .restore
        let token = beginPresentationOperation()
        await restore(ownedBy: token)
    }

    private func restore(ownedBy token: PlanningWorkspacePresentationToken) async {
        let task = startRestore(ownedBy: token)
        await task.value
    }

    @discardableResult
    private func startRestore(
        ownedBy token: PlanningWorkspacePresentationToken
    ) -> Task<Void, Never> {
        schedule { [weak self] generation in
            guard let self else { return }
            guard self.ownsPresentation(token) else { return }
            self.project = nil
            self.openedPath = nil
            self.lastError = nil
            self.lastFailure = nil
            self.lastDiagnostic = nil
            self.phase = .restoring
            guard self.claimWorkspaceLease() else {
                self.lastError = "Another planning workspace is already active."
                self.lastFailure = .unavailable
                self.phase = .unavailable
                return
            }
            do {
                let snapshot = try await self.store.restore()
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                self.apply(snapshot: snapshot)
                self.phase = self.phase(for: snapshot.state)
                self.updateWorkspaceLease(for: snapshot.state)
            } catch {
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                let snapshot = await self.store.accessSnapshot()
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                self.apply(snapshot: snapshot)
                self.updateWorkspaceLease(for: snapshot.state)
                self.record(error: error)
            }
        }
    }

    public func attach(_ selection: PlanningUserSelectedDirectory) async {
        let token = beginPresentationOperation()
        retryIntent = .restore
        project = nil
        openedPath = nil
        await attach(selection, ownedBy: token)
    }

    private func attach(
        _ selection: PlanningUserSelectedDirectory,
        ownedBy token: PlanningWorkspacePresentationToken
    ) async {
        await enqueue { [weak self] generation in
            guard let self else { return }
            guard self.ownsPresentation(token) else { return }
            self.phase = .attaching
            self.lastError = nil
            self.lastFailure = nil
            self.lastDiagnostic = nil
            guard self.claimWorkspaceLease() else {
                self.lastError = "Another planning workspace is already active."
                self.lastFailure = .unavailable
                self.phase = .unavailable
                return
            }
            do {
                // attachExisting inspects and durably selects the candidate
                // before the store replaces its journal/cache configuration.
                // Keeping the old store intact makes a rejected candidate
                // immediately readable through the current workspace.
                let snapshot = try await self.store.attachExisting(selection: selection)
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                self.apply(snapshot: snapshot)
                self.phase = .ready
                self.updateWorkspaceLease(for: snapshot.state)
            } catch {
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                let snapshot = await self.store.accessSnapshot()
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                self.apply(snapshot: snapshot)
                self.updateWorkspaceLease(for: snapshot.state)
                self.record(error: error)
            }
        }
    }

    public func openCanvas(relativePath: String) async {
        let token = beginPresentationOperation()
        pathInput = relativePath
        retryIntent = .openPath(relativePath)
        project = nil
        openedPath = nil
        await openCanvas(relativePath: relativePath, ownedBy: token)
    }

    private func openCanvas(
        relativePath: String,
        ownedBy token: PlanningWorkspacePresentationToken
    ) async {
        await enqueue { [weak self] generation in
            guard let self else { return }
            guard self.ownsPresentation(token) else { return }
            self.phase = .opening
            self.lastError = nil
            self.lastFailure = nil
            self.lastDiagnostic = nil
            var session: PlanningCanvasSession?
            do {
                let path = try PlanningStoredPath(relativePath)
                guard path.isCanvas else {
                    throw PlanningFilesystemError.invalid("canvasPath")
                }
                let context = try await self.store.currentCanvasAccessContext()
                guard self.isCurrent(generation) else { return }
                let persistence = PlanningReadOnlyCanvasPersistence(store: self.store)
                let candidate = PlanningCanvasSession(
                    path: path,
                    context: context,
                    persistence: persistence
                )
                session = candidate
                let presentation = PlanningProjectCoordinator(
                    session: candidate,
                    accessContext: context,
                    allowsEditing: false
                )
#if DEBUG
                if let beforePresentationOpen {
                    await beforePresentationOpen()
                }
#endif
                try await presentation.open()
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                self.openedPath = path
                self.project = presentation
                let snapshot = await self.store.accessSnapshot()
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                self.apply(snapshot: snapshot)
                self.phase = .showingCanvas
            } catch {
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                self.lastDiagnostic = session?.lastDiagnostic ?? self.diagnostic(for: error)
                let snapshot = await self.store.accessSnapshot()
                guard self.isCurrent(generation), self.ownsPresentation(token) else { return }
                self.apply(snapshot: snapshot)
                self.updateWorkspaceLease(for: snapshot.state)
                self.record(error: error)
            }
        }
    }

    /// Unmounts the Canvas immediately, then serializes the final presentation
    /// reconciliation behind any in-flight store operation. Store authority
    /// remains available until the workspace is suspended or another vault is
    /// attached.
    public func closeDocument() {
        invalidatePresentation()
        phase = phase(for: accessSnapshot.state)
        _ = schedule { [weak self] generation in
            guard let self else { return }
            let snapshot = await self.store.accessSnapshot()
            guard self.isCurrent(generation) else { return }
            self.apply(snapshot: snapshot)
            self.phase = self.phase(for: snapshot.state)
        }
    }

    public func retry() async {
        let token = beginPresentationOperation()
        switch retryIntent {
        case .openPath(let failedPath):
            let requestedPath = pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? failedPath
                : pathInput
            guard !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await restore()
                return
            }
            if accessSnapshot.state != .ready {
                await restore(ownedBy: token)
                guard ownsPresentation(token), accessSnapshot.state == .ready else { return }
            }
#if DEBUG
            if let beforeRetryOpen {
                await beforeRetryOpen()
                guard ownsPresentation(token) else { return }
            }
#endif
            guard ownsPresentation(token) else { return }
            await openCanvas(relativePath: requestedPath, ownedBy: token)
        case .restore:
            await restore(ownedBy: token)
        }
    }

    public func suspend() async {
        requestUnmount()
        let task = cleanupTask
        guard let task else { return }
        await task.value
    }

    private func invalidatePresentation(markIdle: Bool = false) {
        presentationTokenID = UUID()
        operationGeneration &+= 1
        project = nil
        openedPath = nil
        lastError = nil
        lastFailure = nil
        lastDiagnostic = nil
        lifecycleTask?.cancel()
        if markIdle {
            phase = .idle
        }
    }

    private func enqueue(
        _ operation: @escaping @MainActor (UInt64) async -> Void
    ) async {
        let task = schedule(operation)
        await task.value
    }

    @discardableResult
    private func scheduleCleanup() -> Task<Void, Never> {
        if let cleanupTask {
            return cleanupTask
        }

        let generation = operationGeneration
        let id = UUID()
        cleanupID = id
        lifecycleTask?.cancel()
        let prior = lifecycleTask
        let task = Task { @MainActor [weak self] in
            if let prior {
                await prior.value
            }
            guard let self else { return }

            // This task is intentionally never cancelled or generation-gated
            // around cleanup. Even when a remount supersedes its presentation,
            // the store, security scope and process lease must be closed.
#if DEBUG
            if let beforeCleanupClose {
                await beforeCleanupClose()
            }
#endif
            await self.store.close()
            let snapshot = await self.store.accessSnapshot()
            self.releaseWorkspaceLease()

            guard self.isCurrent(generation) else {
                self.finishCleanup(id: id)
                return
            }
            self.apply(snapshot: snapshot)
            self.phase = .idle
            self.finishCleanup(id: id)
        }
        cleanupTask = task
        return task
    }

    @discardableResult
    private func schedule(
        _ operation: @escaping @MainActor (UInt64) async -> Void
    ) -> Task<Void, Never> {
        operationGeneration &+= 1
        let generation = operationGeneration
        lifecycleTask?.cancel()
        let prior = lifecycleTask
        let cleanup = cleanupTask
        let task = Task { @MainActor [weak self] in
            if let prior {
                await prior.value
            }
            if let cleanup {
                await cleanup.value
            }
            guard let self, self.isCurrent(generation) else { return }
            await operation(generation)
            guard self.isCurrent(generation) else { return }
            self.lifecycleTask = nil
        }
        lifecycleTask = task
        return task
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        operationGeneration == generation
    }

    private func beginPresentationOperation() -> PlanningWorkspacePresentationToken {
        let token = PlanningWorkspacePresentationToken(id: UUID())
        presentationTokenID = token.id
        return token
    }

    private func ownsPresentation(_ token: PlanningWorkspacePresentationToken) -> Bool {
        presentationTokenID == token.id
    }

    private func claimWorkspaceLease() -> Bool {
        if workspaceLease != nil {
            return true
        }
        guard PlanningWorkspaceLeaseRegistry.shared.acquire(
            key: workspaceKey,
            owner: coordinatorID
        ) else {
            return false
        }
        workspaceLease = PlanningWorkspaceLeaseToken(
            registry: .shared,
            key: workspaceKey,
            owner: coordinatorID
        )
        return true
    }

    private func releaseWorkspaceLease() {
        workspaceLease = nil
    }

    private func updateWorkspaceLease(for state: PlanningVaultAccessState) {
        if state == .ready {
            _ = claimWorkspaceLease()
        } else {
            releaseWorkspaceLease()
        }
    }

    private func finishCleanup(id: UUID) {
        guard cleanupID == id else { return }
        cleanupID = nil
        cleanupTask = nil
    }

    private func apply(snapshot: PlanningVaultAccessSnapshot) {
        accessSnapshot = snapshot
    }

    private func phase(for state: PlanningVaultAccessState) -> PlanningWorkspacePhase {
        switch state {
        case .unselected: return .unselected
        case .ready: return .ready
        case .needsReselection: return .needsReselection
        case .temporarilyUnavailable: return .unavailable
        case .failed: return .failed
        }
    }

    private func record(error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        lastFailure = failureCategory(for: error)
        switch error {
        case let error as PlanningFilesystemError:
            switch error {
            case .needsReselection, .identityChanged, .permissionDenied:
                phase = .needsReselection
            case .providerOffline, .notDownloaded, .unavailable:
                phase = .unavailable
            default:
                phase = .failed
            }
        case let error as PlanningStorageError:
            switch error {
            case .staleAccess:
                phase = .needsReselection
            case .unavailable, .closed, .writerBusy:
                phase = .unavailable
            default:
                phase = .failed
            }
        default:
            phase = .failed
        }
    }

    private func failureCategory(for error: Error) -> PlanningWorkspaceFailureCategory {
        if let error = error as? PlanningFilesystemError {
            switch error {
            case .invalid: return .invalidPath
            case .notFound: return .notFound
            case .needsReselection, .identityChanged, .permissionDenied: return .needsReselection
            case .providerOffline, .notDownloaded, .unavailable: return .unavailable
            case .readOnly: return .readOnly
            case .malformedDocument: return .decodeFailed
                default: return .readFailed
            }
        }
        if let error = error as? PlanningStorageError {
            switch error {
            case .invalid: return .invalidPath
            case .notFound: return .notFound
            case .staleAccess: return .needsReselection
            case .unavailable, .closed, .writerBusy: return .unavailable
                default: return .readFailed
            }
        }
        if error is PlanningValidationError {
            return .invalidPath
        }
        if let error = error as? PlanningCanvasSessionError {
            switch error {
            case .staleGeneration: return .contextMismatch
            case .persistence: return .readFailed
            default: return .unknown
            }
        }
        switch lastDiagnostic?.stage {
        case .sessionDecode: return .decodeFailed
        case .sessionContext: return .contextMismatch
        case .sessionRead, .storeRead: return .readFailed
        case .storeContext, .none: return .unknown
        }
    }

    private func diagnostic(for error: Error) -> PlanningDiagnostic? {
        switch error {
        case let error as PlanningFilesystemError:
            switch error {
            case .invalid, .notFound:
                return nil
            default:
                return PlanningDiagnostic(
                    stage: .storeContext,
                    code: PlanningDiagnostics.code(for: error)
                )
            }
        case let error as PlanningStorageError:
            switch error {
            case .invalid, .notFound:
                return nil
            default:
                return PlanningDiagnostic(
                    stage: .storeRead,
                    code: PlanningDiagnostics.code(for: error)
                )
            }
        default:
            return nil
        }
    }
}
