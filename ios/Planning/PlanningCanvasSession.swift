import Foundation

public struct PlanningCanvasAccessContext: Codable, Equatable, Sendable {
    public let vaultID: UUID
    public let selectionGeneration: UUID

    public init(vaultID: UUID, selectionGeneration: UUID) {
        self.vaultID = vaultID
        self.selectionGeneration = selectionGeneration
    }
}

public struct PlanningCanvasPersistenceRead: Sendable, Equatable {
    public let path: PlanningStoredPath
    public let bytes: Data
    public let version: PlanningContentVersion
    public let isAbsent: Bool
    public let stale: Bool
    public let accessState: PlanningVaultAccessState
    public let context: PlanningCanvasAccessContext

    public init(
        path: PlanningStoredPath,
        bytes: Data,
        version: PlanningContentVersion,
        isAbsent: Bool,
        stale: Bool = false,
        accessState: PlanningVaultAccessState = .ready,
        context: PlanningCanvasAccessContext
    ) {
        self.path = path
        self.bytes = bytes
        self.version = version
        self.isAbsent = isAbsent
        self.stale = stale
        self.accessState = accessState
        self.context = context
    }
}

public protocol PlanningCanvasPersistence: Sendable {
    func context() async throws -> PlanningCanvasAccessContext
    func read(_ path: PlanningStoredPath) async throws -> PlanningCanvasPersistenceRead
    func stage(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext
    ) async throws -> PlanningMutationReceipt
    func publish(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext
    ) async throws -> PlanningFilesystemPublishResult
}

/// Thin adapter over Packet C. It deliberately uses only the existing
/// read/stage/publish methods; vault discovery and security-scoped selection
/// remain the responsibility of PlanningVaultAccess.
public actor PlanningVaultStorePersistence: PlanningCanvasPersistence {
    private let store: PlanningVaultStore

    public init(store: PlanningVaultStore, context _: PlanningCanvasAccessContext) {
        self.store = store
    }

    public func context() async throws -> PlanningCanvasAccessContext {
        try await store.currentCanvasAccessContext()
    }

    public func read(_ path: PlanningStoredPath) async throws -> PlanningCanvasPersistenceRead {
        let result = try await store.read(path)
        guard let vaultID = result.vaultID,
              let selectionGeneration = result.selectionGeneration else {
            throw PlanningFilesystemError.unselected
        }
        let context = PlanningCanvasAccessContext(
            vaultID: vaultID,
            selectionGeneration: selectionGeneration
        )
        return PlanningCanvasPersistenceRead(
            path: path,
            bytes: result.snapshot?.bytes ?? Data(),
            version: result.version,
            isAbsent: result.version == .absent,
            stale: result.stale,
            accessState: result.accessState,
            context: context
        )
    }

    public func stage(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext
    ) async throws -> PlanningMutationReceipt {
        do {
            return try await store.stage(request, expectedContext: expectedContext)
        } catch PlanningFilesystemError.needsReselection {
            throw PlanningCanvasSessionError.staleGeneration
        }
    }

    public func publish(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext
    ) async throws -> PlanningFilesystemPublishResult {
        do {
            return try await store.publish(request, expectedContext: expectedContext)
        } catch PlanningFilesystemError.needsReselection {
            throw PlanningCanvasSessionError.staleGeneration
        }
    }
}

public enum PlanningCanvasSessionState: String, Codable, Equatable, Sendable {
    case idle
    case loading
    case ready
    case saving
    case savedOnDevice
    case publishing
    case published
    case queued
    case conflicted
    case unavailable
    case failed
}

public enum PlanningCanvasSessionError: Error, Equatable, LocalizedError, Sendable {
    case notLoaded
    case staleGeneration
    case pendingCommit
    case interactionNotFound
    case conflictingEdit
    case persistence(String)
    case noOp

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "The planning document is not loaded."
        case .staleGeneration: return "The selected planning vault generation is stale."
        case .pendingCommit: return "A previous planning mutation is still unresolved."
        case .interactionNotFound: return "The planning interaction is no longer active."
        case .conflictingEdit: return "The planning edit conflicts with the current accepted revision."
        case .persistence(let reason): return "The planning mutation could not be persisted: " + reason + "."
        case .noOp: return "The planning edit did not change the document."
        }
    }
}

public enum PlanningCanvasCommitState: String, Codable, Equatable, Sendable {
    case published
    case queued
    case conflicted
    case blocked
}

public struct PlanningCanvasCommitOutcome: Equatable, Sendable {
    public let mutationID: UUID
    public let state: PlanningCanvasCommitState
    public let stageReceipt: PlanningMutationReceipt?
    public let publication: PlanningFilesystemPublishResult?
    public let version: PlanningContentVersion?

    public init(
        mutationID: UUID,
        state: PlanningCanvasCommitState,
        stageReceipt: PlanningMutationReceipt?,
        publication: PlanningFilesystemPublishResult?,
        version: PlanningContentVersion?
    ) {
        self.mutationID = mutationID
        self.state = state
        self.stageReceipt = stageReceipt
        self.publication = publication
        self.version = version
    }
}

public struct PlanningCanvasSessionSnapshot: Equatable, Sendable {
    public let path: PlanningStoredPath
    public let state: PlanningCanvasSessionState
    public let version: PlanningContentVersion?
    public let revision: String?
    public let historyCount: Int
    public let redoCount: Int
    public let historyByteCount: Int
    public let lastErrorCode: String?

    public init(
        path: PlanningStoredPath,
        state: PlanningCanvasSessionState,
        version: PlanningContentVersion?,
        revision: String?,
        historyCount: Int,
        redoCount: Int,
        historyByteCount: Int,
        lastErrorCode: String?
    ) {
        self.path = path
        self.state = state
        self.version = version
        self.revision = revision
        self.historyCount = historyCount
        self.redoCount = redoCount
        self.historyByteCount = historyByteCount
        self.lastErrorCode = lastErrorCode
    }
}

@MainActor
public final class PlanningCanvasSession {
    private enum InteractionKind: Equatable {
        case move(String)
        case resize(String)
        case insertNode(String)
        case deleteNode(String)
        case restoreNode(String)
        case insertEdge(String)
        case deleteEdge(String)
        case reconnectEdge(String)
        case setNodeLabel(String)
        case setNodeColor(String)
        case markdown
    }

    private struct Interaction {
        let id: UUID
        let base: PlanningCanvasEditState
        var current: PlanningCanvasEditState
        let firstEdit: PlanningCanvasEdit
        var lastEdit: PlanningCanvasEdit
        let kind: InteractionKind
    }

    private struct HistoryEntry: Equatable {
        let edit: PlanningCanvasEdit
        let inverse: PlanningCanvasEdit
        let byteCount: Int
    }

    private enum HistoryAction {
        case normal
        case undo(HistoryEntry)
        case redo(HistoryEntry)
    }

    private struct PendingCommit {
        let request: PlanningMutationRequest
        let targetState: PlanningCanvasEditState
        let targetSpatial: PlanningSpatialIndex
        let operationGeneration: UInt64
        let accessContext: PlanningCanvasAccessContext
        let edit: PlanningCanvasEdit
        let inverse: PlanningCanvasEdit
        let action: HistoryAction
        var stageReceipt: PlanningMutationReceipt?
        var terminalPublication: PlanningFilesystemPublishResult?
    }

    private let persistence: any PlanningCanvasPersistence
    public let path: PlanningStoredPath
    private var accessContext: PlanningCanvasAccessContext
    private var loadGeneration: UInt64 = 0
    private var acceptedState: PlanningCanvasEditState?
    private var draftState: PlanningCanvasEditState?
    private var acceptedVersion: PlanningContentVersion?
    private var interactions: [UUID: Interaction] = [:]
    private var pendingCommit: PendingCommit?
    private var commitInFlight = false
    private var loadInFlight = false
    private var history: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private var historyBytes = 0
    private var spatial = PlanningSpatialIndex()

    public private(set) var state: PlanningCanvasSessionState = .idle
    public private(set) var lastPublication: PlanningFilesystemPublishResult?
    public private(set) var lastErrorCode: String?

    public init(
        path: PlanningStoredPath,
        context: PlanningCanvasAccessContext,
        persistence: any PlanningCanvasPersistence
    ) {
        self.path = path
        self.accessContext = context
        self.persistence = persistence
    }

    public var currentState: PlanningCanvasEditState? { draftState }
    public var acceptedContentVersion: PlanningContentVersion? { acceptedVersion }
    public var historyCount: Int { history.count }
    public var redoCount: Int { redoStack.count }
    public var historyByteCount: Int { historyBytes }
    public var spatialIndex: PlanningSpatialIndex { spatial }

    public var snapshot: PlanningCanvasSessionSnapshot {
        PlanningCanvasSessionSnapshot(
            path: path,
            state: state,
            version: acceptedVersion,
            revision: revision(for: acceptedState),
            historyCount: history.count,
            redoCount: redoStack.count,
            historyByteCount: historyBytes,
            lastErrorCode: lastErrorCode
        )
    }

    public func load() async throws {
        guard pendingCommit == nil, !commitInFlight, !loadInFlight else {
            throw PlanningCanvasSessionError.pendingCommit
        }
        guard interactions.isEmpty else { throw PlanningCanvasSessionError.conflictingEdit }
        loadGeneration &+= 1
        let requestedLoad = loadGeneration
        let requestedContext = accessContext
        loadInFlight = true
        defer { loadInFlight = false }
        state = .loading
        do {
            let read = try await persistence.read(path)
            guard requestedLoad == loadGeneration,
                  requestedContext == accessContext,
                  read.path == path,
                  read.context == requestedContext else {
                throw PlanningCanvasSessionError.staleGeneration
            }
            let decoded = try await Task.detached(priority: .userInitiated) {
                try PlanningCanvasSessionDecoder.decode(read)
            }.value
            let currentContext = try await persistence.context()
            guard requestedLoad == loadGeneration,
                  requestedContext == accessContext,
                  currentContext == requestedContext else {
                throw PlanningCanvasSessionError.staleGeneration
            }
            acceptedState = decoded.state
            draftState = decoded.state
            acceptedVersion = read.version
            spatial = decoded.spatial
            interactions.removeAll(keepingCapacity: false)
            history.removeAll(keepingCapacity: false)
            redoStack.removeAll(keepingCapacity: false)
            historyBytes = 0
            lastPublication = nil
            lastErrorCode = nil
            state = read.stale || read.accessState != .ready ? .unavailable : .ready
        } catch {
            guard requestedLoad == loadGeneration,
                  requestedContext == accessContext else {
                throw PlanningCanvasSessionError.staleGeneration
            }
            if case PlanningCanvasSessionError.staleGeneration = error {
                state = .unavailable
            } else if !(error is PlanningCanvasSessionError) {
                state = .failed
            }
            throw error
        }
    }

    public func refresh() async throws {
        try await load()
    }

    /// Invalidates in-flight decodes and all transient gestures. The caller
    /// must later load the newly selected generation before editing again.
    public func updateAccessContext(_ context: PlanningCanvasAccessContext) {
        guard context != accessContext else { return }
        accessContext = context
        loadGeneration &+= 1
        interactions.removeAll(keepingCapacity: false)
        state = .unavailable
    }

    public func beginInteraction(_ edit: PlanningCanvasEdit) throws -> UUID {
        guard pendingCommit == nil, !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        guard let current = draftState, canEdit else { throw PlanningCanvasSessionError.notLoaded }
        guard interactions.isEmpty else { throw PlanningCanvasSessionError.conflictingEdit }
        try validateSessionEdit(edit, for: current)
        let applied = try PlanningCanvasReducer.apply(edit, to: current)
        let nextSpatial = try makeSpatialIndex(for: applied.state)
        let id = UUID()
        interactions[id] = Interaction(
            id: id,
            base: current,
            current: applied.state,
            firstEdit: edit,
            lastEdit: edit,
            kind: interactionKind(for: edit)
        )
        draftState = applied.state
        spatial = nextSpatial
        return id
    }

    public func updateInteraction(_ id: UUID, with edit: PlanningCanvasEdit) throws {
        guard pendingCommit == nil, !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        guard var interaction = interactions[id] else {
            throw PlanningCanvasSessionError.interactionNotFound
        }
        try validateSessionEdit(edit, for: interaction.current)
        guard interaction.kind == interactionKind(for: edit) else {
            throw PlanningCanvasSessionError.conflictingEdit
        }
        let applied = try PlanningCanvasReducer.apply(edit, to: interaction.current)
        let nextSpatial = try makeSpatialIndex(for: applied.state)
        interaction.current = applied.state
        interaction.lastEdit = edit
        interactions[id] = interaction
        draftState = applied.state
        spatial = nextSpatial
    }

    public func cancelInteraction(_ id: UUID) throws {
        guard pendingCommit == nil, !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        guard let interaction = interactions[id] else {
            throw PlanningCanvasSessionError.interactionNotFound
        }
        let nextSpatial = try makeSpatialIndex(for: interaction.base)
        interactions.removeValue(forKey: id)
        draftState = interaction.base
        spatial = nextSpatial
    }

    @discardableResult
    public func commitInteraction(_ id: UUID) async throws -> PlanningCanvasCommitOutcome? {
        guard pendingCommit == nil, !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        guard let interaction = interactions[id] else {
            throw PlanningCanvasSessionError.interactionNotFound
        }
        try validateSessionEdit(interaction.firstEdit, for: interaction.base)
        try validateSessionEdit(interaction.lastEdit, for: interaction.current)
        draftState = interaction.current
        guard interaction.current != interaction.base else {
            interactions.removeValue(forKey: id)
            return nil
        }
        let previousSpatial = spatial
        let preparedSpatial = spatial
        let edit = try coalescedEdit(
            first: interaction.firstEdit,
            last: interaction.lastEdit,
            base: interaction.base,
            current: interaction.current
        )
        let coalescedState = try PlanningCanvasReducer.apply(edit, to: interaction.base).state
        guard coalescedState == interaction.current else {
            throw PlanningCanvasEditError.unsupported("interaction.coalescing")
        }
        interactions.removeValue(forKey: id)
        do {
            return try await persist(
                target: interaction.current,
                edit: edit,
                action: .normal,
                preparedSpatial: preparedSpatial
            )
        } catch {
            if pendingCommit == nil, state != .unavailable {
                interactions[id] = interaction
                draftState = interaction.current
                spatial = previousSpatial
            }
            throw error
        }
    }

    @discardableResult
    public func commitInspectorEdit(_ edit: PlanningCanvasEdit) async throws -> PlanningCanvasCommitOutcome? {
        guard pendingCommit == nil, !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        guard let current = draftState, canEdit else { throw PlanningCanvasSessionError.notLoaded }
        guard interactions.isEmpty else { throw PlanningCanvasSessionError.conflictingEdit }
        try validateSessionEdit(edit, for: current)
        let applied = try PlanningCanvasReducer.apply(edit, to: current)
        guard applied.state != current else { return nil }
        return try await persist(target: applied.state, edit: edit, action: .normal)
    }

    @discardableResult
    public func undo() async throws -> PlanningCanvasCommitOutcome? {
        guard interactions.isEmpty else { throw PlanningCanvasSessionError.conflictingEdit }
        guard pendingCommit == nil, !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        guard canEdit else { throw PlanningCanvasSessionError.notLoaded }
        guard let current = acceptedState, let entry = history.last else { return nil }
        let applied = try PlanningCanvasReducer.apply(entry.inverse, to: current)
        return try await persist(target: applied.state, edit: entry.inverse, action: .undo(entry))
    }

    @discardableResult
    public func redo() async throws -> PlanningCanvasCommitOutcome? {
        guard interactions.isEmpty else { throw PlanningCanvasSessionError.conflictingEdit }
        guard pendingCommit == nil, !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        guard canEdit else { throw PlanningCanvasSessionError.notLoaded }
        guard let current = acceptedState, let entry = redoStack.last else { return nil }
        let applied = try PlanningCanvasReducer.apply(entry.edit, to: current)
        return try await persist(target: applied.state, edit: entry.edit, action: .redo(entry))
    }

    @discardableResult
    public func retryPending() async throws -> PlanningCanvasCommitOutcome? {
        guard var pending = pendingCommit else { return nil }
        guard !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        if let publication = pending.terminalPublication {
            return PlanningCanvasCommitOutcome(
                mutationID: pending.request.mutationID,
                state: .conflicted,
                stageReceipt: pending.stageReceipt,
                publication: publication,
                version: publication.version
            )
        }
        commitInFlight = true
        defer { commitInFlight = false }
        try await assertFresh(pending: pending)
        state = pending.stageReceipt == nil ? .saving : .publishing
        do {
            if pending.stageReceipt == nil {
                let receipt = try await persistence.stage(
                    pending.request,
                    expectedContext: pending.accessContext
                )
                try validate(receipt: receipt, for: pending.request)
                pending.stageReceipt = receipt
                pendingCommit = pending
                try await assertFresh(pending: pending)
                state = .savedOnDevice
            }
            try await assertFresh(pending: pending)
            let publication = try await persistence.publish(
                pending.request,
                expectedContext: pending.accessContext
            )
            return try await acceptPublication(
                pending: &pending,
                publication: publication
            )
        } catch {
            pendingCommit = pending
            guard pending.operationGeneration == loadGeneration,
                  pending.accessContext == accessContext else {
                throw PlanningCanvasSessionError.staleGeneration
            }
            if case PlanningCanvasSessionError.staleGeneration = error {
                state = .unavailable
            } else {
                state = .failed
                lastErrorCode = String(describing: error)
            }
            throw error
        }
    }

    private var canEdit: Bool {
        guard acceptedState != nil else { return false }
        return !commitInFlight && (state == .ready || state == .published || state == .savedOnDevice)
    }

    private func makeSpatialIndex(for state: PlanningCanvasEditState) throws -> PlanningSpatialIndex {
        guard path.isCanvas else { return PlanningSpatialIndex() }
        return try PlanningCanvasSpatialIndexBuilder.build(document: state.document)
    }

    private func validateSessionEdit(
        _ edit: PlanningCanvasEdit,
        for state: PlanningCanvasEditState
    ) throws {
        guard state.markdownPath != nil else { return }
        if case .replaceMarkdownSource = edit { return }
        throw PlanningCanvasEditError.unsupported("canvas edit on Markdown-backed session")
    }

    private func interactionKind(for edit: PlanningCanvasEdit) -> InteractionKind {
        switch edit {
        case .moveNode(let id, _, _): return .move(id)
        case .resizeNode(let id, _, _): return .resize(id)
        case .insertNode(let node, _): return .insertNode(node.id)
        case .deleteNode(let node, _, _): return .deleteNode(node.id)
        case .restoreNode(let node, _, _): return .restoreNode(node.id)
        case .insertEdge(let edge, _): return .insertEdge(edge.id)
        case .deleteEdge(let edge, _): return .deleteEdge(edge.id)
        case .reconnectEdge(let before, _): return .reconnectEdge(before.id)
        case .setNodeLabel(let id, _, _): return .setNodeLabel(id)
        case .setNodeColor(let id, _, _): return .setNodeColor(id)
        case .replaceMarkdownSource: return .markdown
        }
    }

    private func persist(
        target: PlanningCanvasEditState,
        edit: PlanningCanvasEdit,
        action: HistoryAction,
        preparedSpatial: PlanningSpatialIndex? = nil
    ) async throws -> PlanningCanvasCommitOutcome {
        try validateSessionEdit(edit, for: target)
        guard pendingCommit == nil, !commitInFlight else { throw PlanningCanvasSessionError.pendingCommit }
        commitInFlight = true
        defer { commitInFlight = false }
        let operationGeneration = loadGeneration
        let operationContext = accessContext
        try await assertFresh(
            operationGeneration: operationGeneration,
            operationContext: operationContext
        )
        guard let acceptedVersion else { throw PlanningCanvasSessionError.notLoaded }
        let bytes = try encode(target)
        let operation: PlanningMutationOperation = acceptedVersion == .absent ? .create : .replace
        let request = try PlanningMutationRequest(
            vaultID: operationContext.vaultID,
            path: path,
            operation: operation,
            expectedVersion: acceptedVersion,
            proposedBytes: bytes
        )
        let targetSpatial = try preparedSpatial ?? makeSpatialIndex(for: target)
        draftState = target
        spatial = targetSpatial
        var pending = PendingCommit(
            request: request,
            targetState: target,
            targetSpatial: targetSpatial,
            operationGeneration: operationGeneration,
            accessContext: operationContext,
            edit: edit,
            inverse: edit.inverse,
            action: action,
            stageReceipt: nil,
            terminalPublication: nil
        )
        pendingCommit = pending
        state = .saving
        do {
            let receipt = try await persistence.stage(
                request,
                expectedContext: operationContext
            )
            try validate(receipt: receipt, for: request)
            pending.stageReceipt = receipt
            pendingCommit = pending
            try await assertFresh(pending: pending)
            state = .savedOnDevice
            try await assertFresh(pending: pending)
            let publication = try await persistence.publish(
                request,
                expectedContext: operationContext
            )
            return try await acceptPublication(
                pending: &pending,
                publication: publication
            )
        } catch {
            pendingCommit = pending
            guard pending.operationGeneration == loadGeneration,
                  pending.accessContext == accessContext else {
                throw PlanningCanvasSessionError.staleGeneration
            }
            if case PlanningCanvasSessionError.staleGeneration = error {
                state = .unavailable
            } else {
                state = .failed
                lastErrorCode = String(describing: error)
            }
            throw error
        }
    }

    private func acceptPublication(
        pending: inout PendingCommit,
        publication: PlanningFilesystemPublishResult
    ) async throws -> PlanningCanvasCommitOutcome {
        pendingCommit = pending
        do {
            try await assertFresh(pending: pending)
        } catch {
            if publication.status == .conflicted {
                pending.terminalPublication = publication
                pendingCommit = pending
            }
            throw error
        }
        return try finish(pending: pending, publication: publication)
    }

    private func finish(
        pending: PendingCommit,
        publication: PlanningFilesystemPublishResult
    ) throws -> PlanningCanvasCommitOutcome {
        var pending = pending
        lastPublication = publication
        switch publication.status {
        case .published, .reconciled:
            let version = publication.version ?? PlanningContentVersion(data: pending.request.proposedBytes ?? Data())
            acceptedState = pending.targetState
            draftState = pending.targetState
            acceptedVersion = version
            spatial = pending.targetSpatial
            pendingCommit = nil
            state = .published
            lastErrorCode = publication.errorCode
            applyHistoryAction(pending.action, edit: pending.edit, inverse: pending.inverse)
            return PlanningCanvasCommitOutcome(
                mutationID: pending.request.mutationID,
                state: .published,
                stageReceipt: pending.stageReceipt,
                publication: publication,
                version: version
            )
        case .queued, .staged:
            state = .queued
            lastErrorCode = publication.errorCode
            return PlanningCanvasCommitOutcome(
                mutationID: pending.request.mutationID,
                state: .queued,
                stageReceipt: pending.stageReceipt,
                publication: publication,
                version: publication.version
            )
        case .conflicted:
            pending.terminalPublication = publication
            pendingCommit = pending
            state = .conflicted
            lastErrorCode = publication.errorCode ?? "conflict"
            return PlanningCanvasCommitOutcome(
                mutationID: pending.request.mutationID,
                state: .conflicted,
                stageReceipt: pending.stageReceipt,
                publication: publication,
                version: publication.version
            )
        case .blocked:
            state = .failed
            lastErrorCode = publication.errorCode ?? "blocked"
            return PlanningCanvasCommitOutcome(
                mutationID: pending.request.mutationID,
                state: .blocked,
                stageReceipt: pending.stageReceipt,
                publication: publication,
                version: publication.version
            )
        }
    }

    private func assertFresh(
        operationGeneration: UInt64,
        operationContext: PlanningCanvasAccessContext
    ) async throws {
        guard acceptedState != nil else { throw PlanningCanvasSessionError.notLoaded }
        guard operationGeneration == loadGeneration,
              operationContext == accessContext,
              state != .unavailable,
              state != .loading else {
            try throwStaleGeneration()
        }
        let current: PlanningCanvasAccessContext
        do {
            current = try await persistence.context()
        } catch {
            try throwStaleGeneration()
        }
        guard operationGeneration == loadGeneration,
              operationContext == accessContext,
              current == operationContext,
              state != .unavailable,
              state != .loading else {
            try throwStaleGeneration()
        }
    }

    private func assertFresh(pending: PendingCommit) async throws {
        try await assertFresh(
            operationGeneration: pending.operationGeneration,
            operationContext: pending.accessContext
        )
    }

    private func throwStaleGeneration() throws -> Never {
        guard state != .unavailable else {
            throw PlanningCanvasSessionError.staleGeneration
        }
        state = .unavailable
        loadGeneration &+= 1
        interactions.removeAll(keepingCapacity: false)
        throw PlanningCanvasSessionError.staleGeneration
    }

    private func validate(receipt: PlanningMutationReceipt, for request: PlanningMutationRequest) throws {
        guard receipt.mutationID == request.mutationID, receipt.fingerprint == request.fingerprint else {
            throw PlanningCanvasSessionError.persistence("mutationEvidenceMismatch")
        }
    }

    private func encode(_ state: PlanningCanvasEditState) throws -> Data {
        if path.isCanvas { return try PlanningCanvasCodec.encode(state.document) }
        guard let markdownPath = state.markdownPath, let source = state.markdownSource else {
            throw PlanningCanvasSessionError.persistence("markdownStateMissing")
        }
        return try PlanningMarkdownCodec.encode(
            PlanningMarkdownCodec.decode(relativePath: markdownPath.value, source: source)
        )
    }

    private func coalescedEdit(
        first: PlanningCanvasEdit,
        last: PlanningCanvasEdit,
        base: PlanningCanvasEditState,
        current: PlanningCanvasEditState
    ) throws -> PlanningCanvasEdit {
        switch (first, last) {
        case (.moveNode(let firstID, let from, _), .moveNode(let lastID, _, let to)) where firstID == lastID:
            return .moveNode(id: firstID, from: from, to: to)
        case (.resizeNode(let firstID, let from, _), .resizeNode(let lastID, _, let to)) where firstID == lastID:
            return .resizeNode(id: firstID, from: from, to: to)
        case (.setNodeLabel(let firstID, let from, _), .setNodeLabel(let lastID, _, let to)) where firstID == lastID:
            return .setNodeLabel(id: firstID, from: from, to: to)
        case (.setNodeColor(let firstID, let from, _), .setNodeColor(let lastID, _, let to)) where firstID == lastID:
            return .setNodeColor(id: firstID, from: from, to: to)
        default:
            if base.markdownSource != current.markdownSource,
               base.document == current.document,
               let from = base.markdownSource,
               let to = current.markdownSource {
                return .replaceMarkdownSource(from: from, to: to)
            }
            guard first == last else { throw PlanningCanvasEditError.unsupported("multi-command interaction") }
            return first
        }
    }

    private func applyHistoryAction(
        _ action: HistoryAction,
        edit: PlanningCanvasEdit,
        inverse: PlanningCanvasEdit
    ) {
        switch action {
        case .normal:
            let entry = HistoryEntry(edit: edit, inverse: inverse, byteCount: edit.estimatedByteCount + inverse.estimatedByteCount)
            history.append(entry)
            historyBytes += entry.byteCount
            redoStack.removeAll(keepingCapacity: false)
            trimHistory()
        case .undo(let entry):
            guard history.last == entry else { return }
            history.removeLast()
            historyBytes -= entry.byteCount
            redoStack.append(entry)
        case .redo(let entry):
            guard redoStack.last == entry else { return }
            redoStack.removeLast()
            history.append(entry)
            historyBytes += entry.byteCount
            trimHistory()
        }
    }

    private func trimHistory() {
        while history.count > 100 || historyBytes > 16 * 1024 * 1024 {
            guard let removed = history.first else { break }
            history.removeFirst()
            historyBytes -= removed.byteCount
        }
    }

    private func revision(for state: PlanningCanvasEditState?) -> String? {
        guard let state else { return nil }
        if path.isCanvas { return state.document.revision }
        guard let source = state.markdownSource else { return nil }
        return PlanningDigest.hex(Data(source.utf8))
    }
}

private struct PlanningCanvasDecodedPayload: Sendable {
    let state: PlanningCanvasEditState
    let spatial: PlanningSpatialIndex
}

fileprivate enum PlanningCanvasSpatialIndexBuilder {
    static func build(document: PlanningCanvasDocument) throws -> PlanningSpatialIndex {
        var index = PlanningSpatialIndex()
        let nodes = document.nodes.map {
            PlanningSpatialNode(
                id: $0.id,
                bounds: PlanningSpatialRect(
                    minX: $0.x,
                    minY: $0.y,
                    maxX: $0.x + $0.width,
                    maxY: $0.y + $0.height
                )
            )
        }
        let byID = Dictionary(document.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let edges = try document.edges.compactMap { edge -> PlanningSpatialEdge? in
            guard let from = byID[edge.fromNode], let to = byID[edge.toNode] else { return nil }
            return try PlanningSpatialEdge(id: edge.id, points: [
                PlanningSpatialPoint(x: from.x + from.width / 2, y: from.y + from.height / 2),
                PlanningSpatialPoint(x: to.x + to.width / 2, y: to.y + to.height / 2)
            ])
        }
        try index.rebuild(nodes: nodes, edges: edges)
        return index
    }
}

private enum PlanningCanvasSessionDecoder {
    static func decode(_ read: PlanningCanvasPersistenceRead) throws -> PlanningCanvasDecodedPayload {
        let document: PlanningCanvasDocument
        let state: PlanningCanvasEditState
        if read.path.isCanvas {
            document = read.isAbsent
                ? try PlanningCanvasDocument(nodes: [], edges: [])
                : try PlanningCanvasCodec.decode(read.bytes)
            state = try PlanningCanvasEditState(document: document)
        } else {
            document = try PlanningCanvasDocument(nodes: [], edges: [])
            if read.isAbsent {
                let path = try PlanningRelativePath(read.path.value)
                state = try PlanningCanvasEditState(
                    document: document,
                    markdownPath: path,
                    markdownSource: ""
                )
            } else {
                let note = try PlanningMarkdownCodec.decode(relativePath: read.path.value, data: read.bytes)
                let path = try PlanningRelativePath(read.path.value)
                state = try PlanningCanvasEditState(
                    document: document,
                    markdownPath: path,
                    markdownSource: note.source
                )
            }
        }

        let index = try PlanningCanvasSpatialIndexBuilder.build(document: document)
        return PlanningCanvasDecodedPayload(state: state, spatial: index)
    }
}
