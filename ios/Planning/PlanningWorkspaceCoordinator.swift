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

public enum PlanningInspectorNoteStatus: String, Equatable, Sendable {
    case idle
    case unsupported
    case loading
    case ready
    case stale
    case failed
    case unavailable
}

public enum PlanningInspectorFailureCategory: String, Equatable, Sendable {
    case unsupportedReference
    case notFound
    case unavailable
    case contextMismatch
    case readFailed
    case decodeFailed
    case unknown
}

private enum PlanningWorkspaceRetryIntent: Equatable {
    case restore
    case openPath(String)
    case openDocument(PlanningDocumentDestination, PlanningCanvasAccessContext)
}

private struct PlanningWorkspacePresentationToken: Equatable, Sendable {
    let id: UUID
}

public struct PlanningDocumentSelectionTicket: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let presentationTokenID: UUID
    fileprivate let accessContext: PlanningCanvasAccessContext
}

private enum PlanningInspectorOrigin: Equatable, Sendable {
    case canvasNode(nodeID: String, documentPath: PlanningStoredPath)
    case pickedDocument
}

private struct PlanningInspectorReadRequest: Equatable, Sendable {
    let id: UUID
    let documentTokenID: UUID
    let origin: PlanningInspectorOrigin
    let notePath: PlanningStoredPath
    let accessContext: PlanningCanvasAccessContext
}

private struct PlanningInspectorReferenceRoute: Equatable, Sendable {
    let path: PlanningStoredPath?
    let markdownPath: PlanningStoredPath?
    let fragment: String?
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
    @Published public private(set) var isInspectorPresented = false
    @Published public private(set) var isInspectorNotePresented = false
    @Published public private(set) var inspectorNode: PlanningCanvasNode?
    @Published public private(set) var inspectorReference: String?
    @Published public private(set) var inspectorReferencePath: PlanningStoredPath?
    @Published public private(set) var inspectorNotePath: PlanningStoredPath?
    @Published public private(set) var inspectorReferenceFragment: String?
    @Published public private(set) var inspectorNoteSource: String?
    @Published public private(set) var inspectorNoteStatus: PlanningInspectorNoteStatus = .idle
    @Published public private(set) var inspectorError: String?
    @Published public private(set) var inspectorFailure: PlanningInspectorFailureCategory?

    private let coordinatorID = UUID()
    private let workspaceKey: String
    private var workspaceLease: PlanningWorkspaceLeaseToken?
    private var operationGeneration: UInt64 = 0
    private var lifecycleTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupID: UUID?
    private var retryIntent: PlanningWorkspaceRetryIntent = .restore
    private var presentationTokenID = UUID()
    @Published public private(set) var canRetryDocumentSelection = false
    private var documentSelectionTicket: PlanningDocumentSelectionTicket?
    private var inspectorDocumentTokenID = UUID()
    private var inspectorRequest: PlanningInspectorReadRequest?
    private var inspectorProject: PlanningProjectCoordinator?
    private var inspectorOrigin: PlanningInspectorOrigin?
    private var inspectorTask: Task<Void, Never>?
    private var inspectorReadsBlocked = false
    private var inspectorSelection: AnyCancellable?
#if DEBUG
    /// Test-only suspension point for exercising generation and teardown races
    /// against the real store/session pipeline. It is absent from release code.
    nonisolated(unsafe) internal static var beforeDeinitStoreClose: (@Sendable () async -> Void)?
    internal var beforePresentationOpen: (@Sendable () async -> Void)?
    /// Test-only suspension point between retry restoration and Canvas opening.
    internal var beforeRetryOpen: (@Sendable () async -> Void)?
    /// Test-only suspension point before the non-supersedable store cleanup.
    internal var beforeCleanupClose: (@Sendable () async -> Void)?
    /// Test-only suspension point before a candidate inspector session reads.
    internal var beforeInspectorRead: (@Sendable () async -> Void)?
    internal var beforeDocumentSelectionResolution: (@Sendable () async -> Void)?
    internal var afterDocumentSelectionResolution: (@Sendable () async -> Void)?
    internal var afterInspectorRead: (@Sendable () async -> Void)?
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
        invalidateInspectorWork()
        return schedule { [weak self] generation in
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
        invalidateInspectorWork()
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
        invalidateInspectorWork()
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

    public func beginDocumentSelection() -> PlanningDocumentSelectionTicket? {
        guard isMounted,
              phase == .ready || phase == .showingCanvas,
              let vaultID = accessSnapshot.vaultID,
              let selectionGeneration = accessSnapshot.selectionGeneration,
              accessSnapshot.state == .ready else {
            return nil
        }
        if documentSelectionTicket != nil, inspectorOrigin == .pickedDocument {
            invalidateInspectorWork()
        }
        canRetryDocumentSelection = false
        let ticket = PlanningDocumentSelectionTicket(
            id: UUID(),
            presentationTokenID: presentationTokenID,
            accessContext: PlanningCanvasAccessContext(
                vaultID: vaultID,
                selectionGeneration: selectionGeneration
            )
        )
        documentSelectionTicket = ticket
        return ticket
    }

    public func cancelDocumentSelection(_ ticket: PlanningDocumentSelectionTicket) {
        guard documentSelectionTicket == ticket else { return }
        documentSelectionTicket = nil
        if inspectorOrigin == .pickedDocument, inspectorNoteStatus == .loading {
            invalidateInspectorWork()
        }
    }

    public func openSelectedDocument(
        _ selection: PlanningUserSelectedDocument,
        ticket: PlanningDocumentSelectionTicket
    ) async {
        guard isCurrentDocumentSelectionTicket(ticket) else { return }
        await withTaskCancellationHandler {
            await enqueue { [weak self] generation in
                guard let self,
                      self.isCurrentDocumentSelectionTicket(ticket) else { return }
                do {
#if DEBUG
                    if let hook = self.beforeDocumentSelectionResolution { await hook() }
#endif
                    guard self.isCurrentDocumentSelectionTicket(ticket) else { return }
                    let destination = try await self.store.resolveSelectedDocument(
                        selection,
                        expectedContext: ticket.accessContext
                    )
                    guard self.isCurrent(generation),
                          self.isCurrentDocumentSelectionTicket(ticket) else { return }
#if DEBUG
                    if let hook = self.afterDocumentSelectionResolution { await hook() }
#endif
                    guard self.isCurrentDocumentSelectionTicket(ticket) else { return }
                    self.lastError = nil
                    self.lastFailure = nil
                    self.lastDiagnostic = nil
                    self.retryIntent = .openDocument(destination, ticket.accessContext)
                    self.canRetryDocumentSelection = true
                    switch destination {
                    case .canvas(let path):
                        await self.openSelectedCanvas(
                            path: path,
                            expectedContext: ticket.accessContext,
                            ticket: ticket,
                            generation: generation
                        )
                    case .markdown(let path):
                        await self.openPickedMarkdown(
                            path: path,
                            expectedContext: ticket.accessContext,
                            ticket: ticket,
                            generation: generation
                        )
                    }
                } catch {
                    guard self.isCurrent(generation),
                          self.isCurrentDocumentSelectionTicket(ticket) else { return }
                    self.documentSelectionTicket = nil
                    self.lastDiagnostic = self.diagnostic(for: error)
                    self.lastError = error.localizedDescription
                    self.lastFailure = self.failureCategory(for: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDocumentSelection(ticket) }
        }
    }

    private func openSelectedCanvas(
        path: PlanningStoredPath,
        expectedContext: PlanningCanvasAccessContext,
        ticket: PlanningDocumentSelectionTicket,
        generation: UInt64
    ) async {
        guard isCurrent(generation), isCurrentDocumentSelectionTicket(ticket) else { return }

        var session: PlanningCanvasSession?
        do {
            let persistence = PlanningReadOnlyCanvasPersistence(store: store)
            let candidate = PlanningCanvasSession(
                path: path,
                context: expectedContext,
                persistence: persistence
            )
            session = candidate
            let presentation = PlanningProjectCoordinator(
                session: candidate,
                accessContext: expectedContext,
                allowsEditing: false
            )
            try await presentation.open()
            guard isCurrent(generation),
                  isCurrentDocumentSelectionTicket(ticket) else { return }

            let currentContext = try await store.currentCanvasAccessContext()
            guard isCurrent(generation),
                  isCurrentDocumentSelectionTicket(ticket) else { return }
            guard currentContext == expectedContext else {
                throw PlanningFilesystemError.needsReselection
            }

            let snapshot = await store.accessSnapshot()
            guard isCurrent(generation),
                  isCurrentDocumentSelectionTicket(ticket) else { return }
            guard snapshot.state == .ready,
                  snapshot.vaultID == expectedContext.vaultID,
                  snapshot.selectionGeneration == expectedContext.selectionGeneration else {
                throw PlanningFilesystemError.needsReselection
            }
            invalidateInspectorWork()
            openedPath = path
            pathInput = path.value
            project = presentation
            apply(snapshot: snapshot)
            phase = .showingCanvas
            documentSelectionTicket = nil
            lastError = nil
            lastFailure = nil
            lastDiagnostic = nil
            canRetryDocumentSelection = false
        } catch {
            guard isCurrent(generation),
                  isCurrentDocumentSelectionTicket(ticket) else { return }
            documentSelectionTicket = nil
            lastDiagnostic = session?.lastDiagnostic ?? diagnostic(for: error)
            lastError = error.localizedDescription
            lastFailure = failureCategory(for: error)
            // Keep the previous project, selection, viewport, inspector, path,
            // and phase mounted when the candidate document cannot open.
        }
    }

    private func openPickedMarkdown(
        path: PlanningStoredPath,
        expectedContext: PlanningCanvasAccessContext,
        ticket: PlanningDocumentSelectionTicket,
        generation: UInt64
    ) async {
        guard isCurrent(generation), isCurrentDocumentSelectionTicket(ticket) else { return }

        invalidateInspectorWork()
        inspectorProject = project
        inspectorOrigin = .pickedDocument
        if let project {
            let selectedID = project.selectedNodeID
            inspectorSelection = project.$selectedNodeID.sink { [weak self] newID in
                guard newID != selectedID else { return }
                self?.closeInspector()
            }
        }
        inspectorNode = nil
        inspectorReference = "LifeOS/\(path.value)"
        inspectorReferencePath = path
        inspectorNotePath = path
        inspectorReferenceFragment = nil
        inspectorNoteSource = nil
        inspectorNoteStatus = .loading
        inspectorError = nil
        inspectorFailure = nil
        isInspectorPresented = true
        isInspectorNotePresented = true
        await readInspectorNote(
            origin: .pickedDocument,
            notePath: path,
            accessContext: expectedContext
        )
        guard isCurrent(generation),
              isCurrentDocumentSelectionTicket(ticket) else { return }
        documentSelectionTicket = nil
        if inspectorNoteStatus == .ready {
            lastError = nil
            lastFailure = nil
            lastDiagnostic = nil
            canRetryDocumentSelection = false
        }
    }

    public func inspectNode(id: String) {
        guard let project,
              let node = project.nodesByID[id],
              let documentPath = openedPath else { return }

        documentSelectionTicket = nil
        invalidateInspectorWork()
        project.selectNode(id)
        let route = inspectorReferenceRoute(for: node.file)
        inspectorProject = project
        inspectorOrigin = .canvasNode(nodeID: id, documentPath: documentPath)
        inspectorNode = node
        inspectorReference = node.file
        inspectorReferencePath = route?.path
        inspectorNotePath = route?.markdownPath
        inspectorReferenceFragment = route?.fragment
        inspectorNoteSource = nil
        inspectorError = nil
        inspectorFailure = nil
        isInspectorPresented = true
        isInspectorNotePresented = false
        // Published delivers in willSet; use the emitted value, not the old
        // stored selection. Keep invalidation independent of SwiftUI mounting.
        inspectorSelection = project.$selectedNodeID.sink { [weak self] selectedID in
            guard selectedID != id else { return }
            self?.closeInspector()
        }

        if node.file == nil {
            inspectorNoteStatus = .idle
        } else if route?.markdownPath != nil {
            inspectorNoteStatus = .idle
        } else {
            inspectorNoteStatus = .unsupported
            inspectorFailure = .unsupportedReference
            inspectorError = "Open note is available only for a validated LifeOS Markdown reference."
        }
    }

    public func openSelectedNodeNote() async {
        guard isInspectorPresented,
              !inspectorReadsBlocked,
              let project,
              let node = project.selectedNode,
              node.id == inspectorNode?.id,
              let notePath = inspectorNotePath,
              notePath.isMarkdown else {
            return
        }
        guard let documentPath = openedPath,
              let accessContext = inspectorAccessContext() else {
            blockInspectorReads(
                error: PlanningFilesystemError.needsReselection
            )
            return
        }

        isInspectorNotePresented = true
        await readInspectorNote(
            origin: .canvasNode(nodeID: node.id, documentPath: documentPath),
            notePath: notePath,
            accessContext: accessContext
        )
    }

    public func refreshInspectorNote() async {
        guard isInspectorPresented,
              !inspectorReadsBlocked,
              isInspectorNotePresented,
              let origin = inspectorOrigin,
              let notePath = inspectorNotePath,
              notePath.isMarkdown else {
            return
        }

        switch origin {
        case .canvasNode(let nodeID, let documentPath):
            guard let project,
                  let node = project.selectedNode,
                  node.id == nodeID,
                  inspectorNode?.id == nodeID,
                  openedPath == documentPath else { return }
        case .pickedDocument:
            break
        }

        guard let accessContext = inspectorAccessContext() else {
            blockInspectorReads(error: PlanningFilesystemError.needsReselection)
            return
        }

        await readInspectorNote(
            origin: origin,
            notePath: notePath,
            accessContext: accessContext
        )
    }

    public func closeInspectorNote() {
        let origin = inspectorOrigin
        inspectorTask?.cancel()
        inspectorTask = nil
        inspectorRequest = nil
        isInspectorNotePresented = false
        inspectorNoteSource = nil
        inspectorError = nil
        inspectorFailure = nil
        inspectorNoteStatus = inspectorNotePath?.isMarkdown == true ? .idle : .unsupported
        if origin == .pickedDocument {
            invalidateInspectorWork()
        }
    }

    public func closeInspector() {
        invalidateInspectorWork()
    }

    private func readInspectorNote(
        origin: PlanningInspectorOrigin,
        notePath: PlanningStoredPath,
        accessContext: PlanningCanvasAccessContext
    ) async {
        inspectorTask?.cancel()
        inspectorTask = nil

        let priorPath = inspectorNotePath
        let priorSource = inspectorNoteSource
        if priorPath != notePath {
            inspectorNoteSource = nil
        }
        inspectorNoteStatus = .loading
        inspectorError = nil
        inspectorFailure = nil
        inspectorOrigin = origin

        let request = PlanningInspectorReadRequest(
            id: UUID(),
            documentTokenID: inspectorDocumentTokenID,
            origin: origin,
            notePath: notePath,
            accessContext: accessContext
        )
        inspectorRequest = request

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let persistence = PlanningReadOnlyCanvasPersistence(store: self.store)
            let candidate = PlanningCanvasSession(
                path: notePath,
                context: accessContext,
                persistence: persistence
            )
            do {
#if DEBUG
                if let beforeInspectorRead {
                    await beforeInspectorRead()
                }
#endif
                guard self.isCurrentInspectorRequest(request) else { return }
                try await candidate.load()
                guard self.isCurrentInspectorRequest(request) else { return }

#if DEBUG
                if let afterInspectorRead { await afterInspectorRead() }
#endif
                guard self.isCurrentInspectorRequest(request) else { return }
                let currentContext = try await persistence.context()
                guard self.isCurrentInspectorRequest(request) else { return }
                guard currentContext == accessContext else {
                    self.blockInspectorReads(
                        error: PlanningCanvasSessionError.staleGeneration
                    )
                    return
                }
                guard self.isCurrentInspectorRequest(request) else { return }

                guard candidate.path == notePath,
                      let state = candidate.currentState,
                      state.markdownPath?.value == notePath.value,
                      let source = state.markdownSource else {
                    throw PlanningFilesystemError.malformedDocument
                }

                if candidate.state == .ready {
                    self.inspectorNoteSource = source
                    self.inspectorNoteStatus = .ready
                    self.inspectorError = nil
                    self.inspectorFailure = nil
                } else if candidate.state == .unavailable {
                    // A bounded cache read is useful as a preview, but it is
                    // never promoted to a current note.
                    self.inspectorNoteSource = source
                    self.inspectorNoteStatus = .stale
                    self.inspectorError = "This note preview is stale and may be from the local cache."
                    self.inspectorFailure = .unavailable
                } else {
                    throw PlanningFilesystemError.unavailable("inspector")
                }
            } catch {
                guard self.isCurrentInspectorRequest(request) else { return }
                // Even a failed read must revalidate authority before retaining
                // a previous preview: the store can change while it is awaited.
                do {
                    let currentContext = try await persistence.context()
                    guard self.isCurrentInspectorRequest(request) else { return }
                    guard currentContext == accessContext else {
                        self.blockInspectorReads(error: PlanningCanvasSessionError.staleGeneration)
                        return
                    }
                } catch {
                    guard self.isCurrentInspectorRequest(request) else { return }
                    self.blockInspectorReads(error: error)
                    return
                }
                if self.isInspectorAuthorityLoss(error) {
                    self.blockInspectorReads(error: error)
                } else {
                    self.recordInspectorFailure(
                        error,
                        notePath: notePath,
                        priorPath: priorPath,
                        priorSource: priorSource
                    )
                }
            }
            if self.inspectorRequest == request {
                self.inspectorTask = nil
            }
        }
        inspectorTask = task
        await task.value
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
        let token: PlanningWorkspacePresentationToken
        if case .openDocument = retryIntent {
            documentSelectionTicket = nil
            presentationTokenID = UUID()
            token = PlanningWorkspacePresentationToken(id: presentationTokenID)
        } else {
            token = beginPresentationOperation()
        }
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
        case .openDocument(let destination, let expectedContext):
            do {
                let currentContext = try await store.currentCanvasAccessContext()
                guard ownsPresentation(token) else { return }
                guard currentContext == expectedContext else {
                    lastError = PlanningFilesystemError.needsReselection.localizedDescription
                    lastFailure = .needsReselection
                    blockInspectorReads(error: PlanningFilesystemError.needsReselection)
                    phase = .needsReselection
                    return
                }
            } catch {
                guard ownsPresentation(token) else { return }
                lastError = error.localizedDescription
                lastFailure = failureCategory(for: error)
                return
            }

            switch destination {
            case .canvas(let path):
                let retryTicket = PlanningDocumentSelectionTicket(
                    id: UUID(), presentationTokenID: token.id, accessContext: expectedContext
                )
                documentSelectionTicket = retryTicket
                await openSelectedCanvas(path: path, expectedContext: expectedContext,
                                         ticket: retryTicket, generation: operationGeneration)
            case .markdown(let path):
                let retryTicket = PlanningDocumentSelectionTicket(
                    id: UUID(),
                    presentationTokenID: token.id,
                    accessContext: expectedContext
                )
                documentSelectionTicket = retryTicket
                await openPickedMarkdown(
                    path: path,
                    expectedContext: expectedContext,
                    ticket: retryTicket,
                    generation: operationGeneration
                )
            }
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

    private func isCurrentDocumentSelectionTicket(
        _ ticket: PlanningDocumentSelectionTicket
    ) -> Bool {
        guard !Task.isCancelled,
              isMounted,
              documentSelectionTicket == ticket,
              presentationTokenID == ticket.presentationTokenID,
              accessSnapshot.state == .ready,
              accessSnapshot.vaultID == ticket.accessContext.vaultID,
              accessSnapshot.selectionGeneration == ticket.accessContext.selectionGeneration,
              phase == .ready || phase == .showingCanvas else {
            return false
        }
        return true
    }

    private func inspectorAccessContext() -> PlanningCanvasAccessContext? {
        guard accessSnapshot.state == .ready,
              let vaultID = accessSnapshot.vaultID,
              let selectionGeneration = accessSnapshot.selectionGeneration else {
            return nil
        }
        return PlanningCanvasAccessContext(
            vaultID: vaultID,
            selectionGeneration: selectionGeneration
        )
    }

    private func inspectorReferenceRoute(for reference: String?) -> PlanningInspectorReferenceRoute? {
        guard let reference else { return nil }
        guard reference.hasPrefix("LifeOS/") else {
            return PlanningInspectorReferenceRoute(
                path: nil,
                markdownPath: nil,
                fragment: nil
            )
        }

        let suffixWithFragment = String(reference.dropFirst("LifeOS/".count))
        let suffix: String
        let fragment: String?
        if let separator = suffixWithFragment.firstIndex(of: "#") {
            suffix = String(suffixWithFragment[..<separator])
            fragment = String(suffixWithFragment[suffixWithFragment.index(after: separator)...])
        } else {
            suffix = suffixWithFragment
            fragment = nil
        }

        guard let path = try? PlanningStoredPath(suffix) else {
            return PlanningInspectorReferenceRoute(
                path: nil,
                markdownPath: nil,
                fragment: fragment
            )
        }
        return PlanningInspectorReferenceRoute(
            path: path,
            markdownPath: path.isMarkdown ? path : nil,
            fragment: fragment
        )
    }

    private func isCurrentInspectorRequest(_ request: PlanningInspectorReadRequest) -> Bool {
        guard !Task.isCancelled,
              isInspectorPresented,
              isInspectorNotePresented,
              !inspectorReadsBlocked,
              inspectorDocumentTokenID == request.documentTokenID,
              inspectorRequest == request,
              inspectorOrigin == request.origin,
              accessSnapshot.vaultID == request.accessContext.vaultID,
              accessSnapshot.selectionGeneration == request.accessContext.selectionGeneration else {
            return false
        }
        switch request.origin {
        case .canvasNode(let nodeID, let documentPath):
            guard let project,
                  project === inspectorProject,
                  project.selectedNodeID == nodeID,
                  openedPath == documentPath else { return false }
        case .pickedDocument:
            break
        }
        return true
    }

    private func invalidateInspectorWork() {
        inspectorSelection?.cancel()
        inspectorSelection = nil
        inspectorDocumentTokenID = UUID()
        inspectorRequest = nil
        inspectorTask?.cancel()
        inspectorTask = nil
        inspectorProject = nil
        inspectorOrigin = nil
        inspectorReadsBlocked = false
        isInspectorPresented = false
        isInspectorNotePresented = false
        inspectorNode = nil
        inspectorReference = nil
        inspectorReferencePath = nil
        inspectorNotePath = nil
        inspectorReferenceFragment = nil
        inspectorNoteSource = nil
        inspectorNoteStatus = .idle
        inspectorError = nil
        inspectorFailure = nil
    }

    private func blockInspectorReads(error: Error) {
        inspectorRequest = nil
        inspectorTask = nil
        inspectorReadsBlocked = true
        inspectorNoteSource = nil
        inspectorNoteStatus = .unavailable
        inspectorError = inspectorErrorDescription(for: error)
        inspectorFailure = .contextMismatch
    }

    private func recordInspectorFailure(
        _ error: Error,
        notePath: PlanningStoredPath,
        priorPath: PlanningStoredPath?,
        priorSource: String?
    ) {
        let canRetainPriorPreview = priorPath == notePath && priorSource != nil
        if canRetainPriorPreview {
            inspectorNoteSource = priorSource
            inspectorNoteStatus = .stale
        } else {
            inspectorNoteSource = nil
            inspectorNoteStatus = .failed
        }
        inspectorError = inspectorErrorDescription(for: error)
        inspectorFailure = inspectorFailureCategory(for: error)
    }

    private func isInspectorAuthorityLoss(_ error: Error) -> Bool {
        if let error = error as? PlanningCanvasSessionError {
            if case .staleGeneration = error { return true }
        }
        if let error = error as? PlanningFilesystemError {
            switch error {
            case .unselected, .needsReselection, .permissionDenied, .identityChanged:
                return true
            default:
                return false
            }
        }
        if let error = error as? PlanningStorageError {
            switch error {
            case .staleAccess, .closed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func inspectorFailureCategory(for error: Error) -> PlanningInspectorFailureCategory {
        if let error = error as? PlanningFilesystemError {
            switch error {
            case .notFound: return .notFound
            case .unselected, .needsReselection, .permissionDenied, .identityChanged,
                 .providerOffline, .notDownloaded, .unavailable:
                return .unavailable
            case .malformedDocument: return .decodeFailed
            default: return .readFailed
            }
        }
        if error is PlanningValidationError {
            return .decodeFailed
        }
        if error is PlanningCanvasSessionError {
            return .readFailed
        }
        if error is PlanningStorageError {
            return .readFailed
        }
        return .unknown
    }

    private func inspectorErrorDescription(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return String(describing: error)
    }

    private func invalidatePresentation(markIdle: Bool = false) {
        invalidateInspectorWork()
        documentSelectionTicket = nil
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
        invalidateInspectorWork()
        documentSelectionTicket = nil
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
