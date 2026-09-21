import XCTest
@testable import LifeOSMac

private enum PlanningTestPersistenceError: Error, Equatable {
    case injected
}

private actor PlanningSessionPersistenceDouble: PlanningCanvasPersistence {
    private var storage: Data?
    private var accessContext: PlanningCanvasAccessContext
    private var accessState: PlanningVaultAccessState = .ready
    private var publicationStatus: PlanningFilesystemPublicationStatus = .published
    private var nextReadError: PlanningTestPersistenceError?
    private var nextStageError: PlanningTestPersistenceError?
    private var nextPublishError: PlanningTestPersistenceError?
    private(set) var readCount = 0
    private(set) var stageCount = 0
    private(set) var publishCount = 0
    private var operations: [PlanningMutationOperation] = []
    private var stagedRequests: [PlanningMutationRequest] = []
    private var publishedRequests: [PlanningMutationRequest] = []
    private var stageBlocked = false
    private var publishBlocked = false
    private var readBlocked = false
    private var stageEntered = false
    private var publishEntered = false
    private var readEntered = false
    private var stageEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var publishEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var readEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var stageReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var publishReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var readReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(document: PlanningCanvasDocument?, context: PlanningCanvasAccessContext) throws {
        if let document {
            storage = try PlanningCanvasCodec.encode(document)
        }
        accessContext = context
    }

    init(markdownSource: String, context: PlanningCanvasAccessContext) {
        storage = Data(markdownSource.utf8)
        accessContext = context
    }

    func context() async throws -> PlanningCanvasAccessContext { accessContext }

    func read(_ path: PlanningStoredPath) async throws -> PlanningCanvasPersistenceRead {
        readCount += 1
        readEntered = true
        let entryWaiters = readEntryWaiters
        readEntryWaiters.removeAll(keepingCapacity: false)
        entryWaiters.forEach { $0.resume() }
        if readBlocked {
            await withCheckedContinuation { continuation in
                readReleaseWaiters.append(continuation)
            }
        }
        if let nextReadError {
            self.nextReadError = nil
            throw nextReadError
        }
        let bytes = storage ?? Data()
        return PlanningCanvasPersistenceRead(
            path: path,
            bytes: bytes,
            version: storage.map(PlanningContentVersion.init(data:)) ?? .absent,
            isAbsent: storage == nil,
            accessState: accessState,
            context: accessContext
        )
    }

    func stage(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext
    ) async throws -> PlanningMutationReceipt {
        stageCount += 1
        operations.append(request.operation)
        stagedRequests.append(request)
        stageEntered = true
        let entryWaiters = stageEntryWaiters
        stageEntryWaiters.removeAll(keepingCapacity: false)
        entryWaiters.forEach { $0.resume() }
        if stageBlocked {
            await withCheckedContinuation { continuation in
                stageReleaseWaiters.append(continuation)
            }
        }
        if let nextStageError {
            self.nextStageError = nil
            throw nextStageError
        }
        return try PlanningMutationReceipt(
            mutationID: request.mutationID,
            fingerprint: request.fingerprint,
            state: .staged
        )
    }

    func publish(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext
    ) async throws -> PlanningFilesystemPublishResult {
        publishCount += 1
        publishedRequests.append(request)
        publishEntered = true
        let entryWaiters = publishEntryWaiters
        publishEntryWaiters.removeAll(keepingCapacity: false)
        entryWaiters.forEach { $0.resume() }
        if publishBlocked {
            await withCheckedContinuation { continuation in
                publishReleaseWaiters.append(continuation)
            }
        }
        if let nextPublishError {
            self.nextPublishError = nil
            throw nextPublishError
        }
        switch publicationStatus {
        case .published, .reconciled:
            storage = request.proposedBytes
            return PlanningFilesystemPublishResult(
                status: publicationStatus,
                version: request.proposedBytes.map(PlanningContentVersion.init(data:))
            )
        case .conflicted:
            return PlanningFilesystemPublishResult(status: .conflicted, errorCode: "conflict")
        case .blocked:
            return PlanningFilesystemPublishResult(status: .blocked, errorCode: "blocked")
        case .queued, .staged:
            return PlanningFilesystemPublishResult(status: publicationStatus)
        }
    }

    func setPublicationStatus(_ status: PlanningFilesystemPublicationStatus) {
        publicationStatus = status
    }

    func failNextPublish() {
        nextPublishError = .injected
    }

    func failNextRead() {
        nextReadError = .injected
    }

    func failNextStage() {
        nextStageError = .injected
    }

    func setContext(_ context: PlanningCanvasAccessContext) {
        accessContext = context
    }

    func counts() -> (read: Int, stage: Int, publish: Int) {
        (readCount, stageCount, publishCount)
    }

    func operationSnapshot() -> [PlanningMutationOperation] { operations }

    func stagedRequestSnapshot() -> [PlanningMutationRequest] { stagedRequests }

    func publishedRequestSnapshot() -> [PlanningMutationRequest] { publishedRequests }

    func blockStage() { stageBlocked = true; stageEntered = false }

    func blockPublish() { publishBlocked = true; publishEntered = false }

    func blockRead() { readBlocked = true; readEntered = false }

    func waitForStageEntry() async {
        if stageEntered { return }
        await withCheckedContinuation { continuation in
            stageEntryWaiters.append(continuation)
        }
    }

    func waitForPublishEntry() async {
        if publishEntered { return }
        await withCheckedContinuation { continuation in
            publishEntryWaiters.append(continuation)
        }
    }

    func waitForReadEntry() async {
        if readEntered { return }
        await withCheckedContinuation { continuation in
            readEntryWaiters.append(continuation)
        }
    }

    func releaseStage() {
        stageBlocked = false
        let waiters = stageReleaseWaiters
        stageReleaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func releasePublish() {
        publishBlocked = false
        let waiters = publishReleaseWaiters
        publishReleaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func releaseRead() {
        readBlocked = false
        let waiters = readReleaseWaiters
        readReleaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}

@MainActor
final class PlanningCanvasSessionTests: XCTestCase {
    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-planning-session-\(UUID().uuidString)-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func document() throws -> PlanningCanvasDocument {
        let node = try PlanningCanvasNode(
            id: "node",
            type: .text,
            x: 0,
            y: 0,
            width: 100,
            height: 60,
            text: "Plan"
        )
        return try PlanningCanvasDocument(nodes: [node], edges: [])
    }

    private func makeSession(
        persistence: PlanningSessionPersistenceDouble,
        context: PlanningCanvasAccessContext
    ) throws -> PlanningCanvasSession {
        try PlanningCanvasSession(
            path: PlanningStoredPath("Boards/Plan.canvas"),
            context: context,
            persistence: persistence
        )
    }

    private func makeMarkdownSession(
        persistence: PlanningSessionPersistenceDouble,
        context: PlanningCanvasAccessContext
    ) throws -> PlanningCanvasSession {
        try PlanningCanvasSession(
            path: PlanningStoredPath("Notes/Plan.md"),
            context: context,
            persistence: persistence
        )
    }

    func testOneThousandTransientUpdatesPerformNoPersistenceAndCommitOnce() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()

        let interaction = try session.beginInteraction(.moveNode(
            id: "node",
            from: try PlanningCanvasPoint(x: 0, y: 0),
            to: try PlanningCanvasPoint(x: 1, y: 0)
        ))
        var currentX = 1.0
        for _ in 0..<1_000 {
            let nextX = currentX + 1
            try session.updateInteraction(interaction, with: .moveNode(
                id: "node",
                from: try PlanningCanvasPoint(x: currentX, y: 0),
                to: try PlanningCanvasPoint(x: nextX, y: 0)
            ))
            currentX = nextX
        }
        var counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 0)
        XCTAssertEqual(counts.publish, 0)
        XCTAssertEqual(session.currentState?.document.nodes.first?.x, 1_001)

        let outcome = try await session.commitInteraction(interaction)
        XCTAssertEqual(outcome?.state, .published)
        counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 1)
        XCTAssertEqual(counts.publish, 1)
    }

    func testCancelAndNoOpCreateNoMutation() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()

        let cancelled = try session.beginInteraction(.moveNode(
            id: "node",
            from: try PlanningCanvasPoint(x: 0, y: 0),
            to: try PlanningCanvasPoint(x: 20, y: 20)
        ))
        try session.cancelInteraction(cancelled)
        XCTAssertEqual(session.currentState?.document.nodes.first?.x, 0)

        let noOp = try session.beginInteraction(.moveNode(
            id: "node",
            from: try PlanningCanvasPoint(x: 0, y: 0),
            to: try PlanningCanvasPoint(x: 0, y: 0)
        ))
        let noOpOutcome = try await session.commitInteraction(noOp)
        XCTAssertNil(noOpOutcome)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 0)
        XCTAssertEqual(counts.publish, 0)
    }

    func testUndoRedoUseNewMutationsAndRestoreAcceptedState() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()

        let edit = PlanningCanvasEdit.setNodeLabel(id: "node", from: nil, to: "Updated")
        let editOutcome = try await session.commitInspectorEdit(edit)
        XCTAssertEqual(editOutcome?.state, .published)
        XCTAssertEqual(session.historyCount, 1)
        let undoOutcome = try await session.undo()
        XCTAssertEqual(undoOutcome?.state, .published)
        XCTAssertEqual(session.historyCount, 0)
        XCTAssertEqual(session.redoCount, 1)
        XCTAssertNil(session.currentState?.document.nodes.first?.label)
        let redoOutcome = try await session.redo()
        XCTAssertEqual(redoOutcome?.state, .published)
        XCTAssertEqual(session.historyCount, 1)
        XCTAssertEqual(session.redoCount, 0)
        XCTAssertEqual(session.currentState?.document.nodes.first?.label, "Updated")
        let counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 3)
        XCTAssertEqual(counts.publish, 3)
    }

    func testConflictPreservesDraftAndRetryDoesNotRepublishTerminalMutation() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.setPublicationStatus(.conflicted)

        let outcome = try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "Local"))
        XCTAssertEqual(outcome?.state, .conflicted)
        XCTAssertEqual(session.state, .conflicted)
        XCTAssertEqual(session.currentState?.document.nodes.first?.label, "Local")
        var counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 1)
        XCTAssertEqual(counts.publish, 1)

        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        let retryOutcome = try await session.retryPending()
        XCTAssertEqual(retryOutcome?.state, .conflicted)
        counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 1)
        XCTAssertEqual(counts.publish, 1)
    }

    func testPublishErrorRetainsEvidenceAndRetryDoesNotChangeMutationIDOrRestage() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.failNextPublish()

        do {
            _ = try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "Retry"))
            XCTFail("Expected injected publication error")
        } catch PlanningTestPersistenceError.injected {
        }
        var counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 1)
        XCTAssertEqual(counts.publish, 1)
        XCTAssertEqual(session.state, .failed)

        let initialRequests = await persistence.stagedRequestSnapshot()
        let firstRequest = try XCTUnwrap(initialRequests.first)
        let retryOutcome = try await session.retryPending()
        XCTAssertEqual(retryOutcome?.state, .published)
        counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 1)
        XCTAssertEqual(counts.publish, 2)
        let requests = await persistence.publishedRequestSnapshot()
        guard requests.count == 2 else {
            XCTFail("Expected two publication attempts")
            return
        }
        XCTAssertEqual(requests[0], firstRequest)
        XCTAssertEqual(requests[1], firstRequest)
    }

    func testStaleGenerationRejectsCommitBeforeAnyWrite() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.setContext(PlanningCanvasAccessContext(vaultID: context.vaultID, selectionGeneration: UUID()))

        do {
            _ = try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "Stale"))
            XCTFail("Expected stale generation")
        } catch PlanningCanvasSessionError.staleGeneration {
        }
        let counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 0)
        XCTAssertEqual(counts.publish, 0)
        XCTAssertEqual(session.state, .unavailable)
    }

    func testHistoryIsBoundedToOneHundredCommands() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()

        var previous: String?
        for index in 0..<105 {
            let next = "Label-" + String(index)
            let edit = PlanningCanvasEdit.setNodeLabel(id: "node", from: previous, to: next)
            let outcome = try await session.commitInspectorEdit(edit)
            XCTAssertEqual(outcome?.state, .published)
            previous = next
        }
        XCTAssertEqual(session.historyCount, 100)
        XCTAssertLessThanOrEqual(session.historyByteCount, 16 * 1024 * 1024)
        XCTAssertEqual(session.currentState?.document.nodes.first?.label, "Label-104")
    }

    func testAbsentCanvasUsesCreateOperation() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: nil, context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()

        let node = try PlanningCanvasNode(
            id: "new-node",
            type: .text,
            x: 0,
            y: 0,
            width: 100,
            height: 60,
            text: "New"
        )
        let outcome = try await session.commitInspectorEdit(.insertNode(node: node, index: 0))
        XCTAssertEqual(outcome?.state, .published)
        let operations = await persistence.operationSnapshot()
        XCTAssertEqual(operations, [.create])
    }

    func testRealVaultAdapterTreatsAbsentSnapshotAsAbsent() async throws {
        let root = try temporaryDirectory("vault")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryDirectory("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let selected = try await store.select(selection: selection, intent: .initialize)
        let context = PlanningCanvasAccessContext(
            vaultID: try XCTUnwrap(selected.vaultID),
            selectionGeneration: try XCTUnwrap(selected.selectionGeneration)
        )
        let persistence = PlanningVaultStorePersistence(store: store, context: context)
        let read = try await persistence.read(PlanningStoredPath("Boards/Absent.canvas"))
        XCTAssertTrue(read.isAbsent)
        XCTAssertEqual(read.version, .absent)
    }

    func testMarkdownSessionRejectsCanvasEditsWithoutMutatingDraftOrWriting() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let source = "# Plan\n\nKeep the project focused.\n"
        let persistence = PlanningSessionPersistenceDouble(markdownSource: source, context: context)
        let session = try makeMarkdownSession(persistence: persistence, context: context)
        try await session.load()

        let initialState = try XCTUnwrap(session.currentState)
        let initialSpatialMetrics = session.spatialIndex.metrics
        let node = try XCTUnwrap(try document().nodes.first)
        let canvasEdit = PlanningCanvasEdit.insertNode(node: node, index: 0)

        do {
            _ = try await session.commitInspectorEdit(canvasEdit)
            XCTFail("Expected Canvas edits to be rejected for Markdown-backed state")
        } catch let error as PlanningCanvasEditError {
            XCTAssertEqual(error, .unsupported("canvas edit on Markdown-backed session"))
        }

        do {
            _ = try session.beginInteraction(canvasEdit)
            XCTFail("Expected Canvas interactions to be rejected for Markdown-backed state")
        } catch let error as PlanningCanvasEditError {
            XCTAssertEqual(error, .unsupported("canvas edit on Markdown-backed session"))
        }

        XCTAssertEqual(session.currentState, initialState)
        XCTAssertEqual(session.currentState?.markdownSource, source)
        XCTAssertEqual(session.spatialIndex.metrics, initialSpatialMetrics)
        XCTAssertEqual(session.historyCount, 0)
        XCTAssertEqual(session.redoCount, 0)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 0)
        XCTAssertEqual(counts.publish, 0)
    }

    func testTransientSpatialIndexTracksMoveAndCancel() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()

        let interaction = try session.beginInteraction(.moveNode(
            id: "node",
            from: try PlanningCanvasPoint(x: 0, y: 0),
            to: try PlanningCanvasPoint(x: 120, y: 0)
        ))
        var spatial = session.spatialIndex
        XCTAssertEqual(spatial.hitTest(PlanningSpatialPoint(x: 130, y: 30)).first?.id, "node")
        XCTAssertTrue(spatial.hitTest(PlanningSpatialPoint(x: 10, y: 30)).isEmpty)

        try session.cancelInteraction(interaction)
        spatial = session.spatialIndex
        XCTAssertEqual(spatial.hitTest(PlanningSpatialPoint(x: 10, y: 30)).first?.id, "node")
        XCTAssertTrue(spatial.hitTest(PlanningSpatialPoint(x: 130, y: 30)).isEmpty)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 0)
        XCTAssertEqual(counts.publish, 0)
    }

    func testOnlyOneTransientInteractionCanOwnTheCanvas() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()

        let interaction = try session.beginInteraction(.moveNode(
            id: "node",
            from: try PlanningCanvasPoint(x: 0, y: 0),
            to: try PlanningCanvasPoint(x: 10, y: 0)
        ))
        XCTAssertThrowsError(try session.beginInteraction(.setNodeLabel(id: "node", from: nil, to: "blocked"))) { error in
            XCTAssertEqual(error as? PlanningCanvasSessionError, .conflictingEdit)
        }
        do {
            _ = try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "blocked"))
            XCTFail("Expected the inspector edit to be rejected during a gesture")
        } catch PlanningCanvasSessionError.conflictingEdit {
        }
        try session.cancelInteraction(interaction)
    }

    func testMixedInteractionCommandsAreRejectedBeforeUndoCanLoseState() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()

        let interaction = try session.beginInteraction(.moveNode(
            id: "node",
            from: try PlanningCanvasPoint(x: 0, y: 0),
            to: try PlanningCanvasPoint(x: 10, y: 0)
        ))
        XCTAssertThrowsError(try session.updateInteraction(
            interaction,
            with: .setNodeLabel(id: "node", from: nil, to: "mixed")
        )) { error in
            XCTAssertEqual(error as? PlanningCanvasSessionError, .conflictingEdit)
        }
        XCTAssertEqual(session.currentState?.document.nodes.first?.x, 10)
        XCTAssertNil(session.currentState?.document.nodes.first?.label)
        try session.cancelInteraction(interaction)
    }

    func testStageInvalidationRejectsStaleCompletionAndBlocksUndoReload() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.blockStage()

        let commitTask = Task { @MainActor in
            try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "stale"))
        }
        await persistence.waitForStageEntry()
        do {
            _ = try await session.load()
            XCTFail("Expected reload to be rejected during a commit")
        } catch PlanningCanvasSessionError.pendingCommit {
        }
        do {
            _ = try await session.undo()
            XCTFail("Expected undo to be rejected during a commit")
        } catch PlanningCanvasSessionError.pendingCommit {
        }
        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        await persistence.releaseStage()
        do {
            _ = try await commitTask.value
            XCTFail("Expected stale commit completion")
        } catch PlanningCanvasSessionError.staleGeneration {
        }
        XCTAssertEqual(session.state, .unavailable)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.publish, 0)
    }

    func testPublishInvalidationRejectsStaleCompletionAfterWrite() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.blockPublish()

        let commitTask = Task { @MainActor in
            try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "stale"))
        }
        await persistence.waitForPublishEntry()
        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        await persistence.releasePublish()
        do {
            _ = try await commitTask.value
            XCTFail("Expected stale commit completion")
        } catch PlanningCanvasSessionError.staleGeneration {
        }
        let counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 1)
        XCTAssertEqual(counts.publish, 1)
        XCTAssertEqual(session.state, .unavailable)
    }

    func testConflictArrivingDuringInvalidationRemainsTerminalAndIsNotRepublished() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.setPublicationStatus(.conflicted)
        await persistence.blockPublish()

        let commitTask = Task { @MainActor in
            try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "local"))
        }
        await persistence.waitForPublishEntry()
        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        await persistence.releasePublish()
        do {
            _ = try await commitTask.value
            XCTFail("Expected stale conflict completion")
        } catch PlanningCanvasSessionError.staleGeneration {
        }

        let retryOutcome = try await session.retryPending()
        XCTAssertEqual(retryOutcome?.state, .conflicted)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.publish, 1)
    }

    func testReloadAndUndoAreSerializedWhileReadIsSuspended() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.blockRead()

        let reloadTask = Task { @MainActor in
            try await session.load()
        }
        await persistence.waitForReadEntry()
        do {
            _ = try await session.undo()
            XCTFail("Expected undo to be rejected while loading")
        } catch PlanningCanvasSessionError.notLoaded {
        }
        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        await persistence.releaseRead()
        do {
            _ = try await reloadTask.value
            XCTFail("Expected superseded reload")
        } catch PlanningCanvasSessionError.staleGeneration {
        }
        XCTAssertEqual(session.state, .unavailable)
    }

    func testOverlappingRetriesSerializeWithoutRestaging() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.failNextPublish()
        do {
            _ = try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "retry"))
            XCTFail("Expected injected publication error")
        } catch PlanningTestPersistenceError.injected {
        }

        await persistence.blockPublish()
        let firstRetry = Task { @MainActor in try await session.retryPending() }
        await persistence.waitForPublishEntry()
        let secondRetry = Task { @MainActor in try await session.retryPending() }
        do {
            _ = try await secondRetry.value
            XCTFail("Expected overlapping retry to be rejected")
        } catch PlanningCanvasSessionError.pendingCommit {
        }
        await persistence.releasePublish()
        let firstOutcome = try await firstRetry.value
        XCTAssertEqual(firstOutcome?.state, .published)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 1)
        XCTAssertEqual(counts.publish, 2)
    }

    func testStageErrorAfterInvalidationCannotOverwriteUnavailableState() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.blockStage()

        let commitTask = Task { @MainActor in
            try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "stale"))
        }
        await persistence.waitForStageEntry()
        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        await persistence.failNextStage()
        await persistence.releaseStage()
        do {
            _ = try await commitTask.value
            XCTFail("Expected stale stage error")
        } catch PlanningCanvasSessionError.staleGeneration {
        }
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertNil(session.snapshot.lastErrorCode)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.publish, 0)
    }

    func testPublishErrorAfterInvalidationCannotOverwriteUnavailableState() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.blockPublish()

        let commitTask = Task { @MainActor in
            try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "stale"))
        }
        await persistence.waitForPublishEntry()
        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        await persistence.failNextPublish()
        await persistence.releasePublish()
        do {
            _ = try await commitTask.value
            XCTFail("Expected stale publication error")
        } catch PlanningCanvasSessionError.staleGeneration {
        }
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertNil(session.snapshot.lastErrorCode)
    }

    func testReadErrorFromSupersededReloadCannotChangeCurrentState() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.blockRead()

        let reloadTask = Task { @MainActor in
            try await session.load()
        }
        await persistence.waitForReadEntry()
        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        await persistence.failNextRead()
        await persistence.releaseRead()
        do {
            _ = try await reloadTask.value
            XCTFail("Expected stale read error")
        } catch PlanningCanvasSessionError.staleGeneration {
        }
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertNil(session.snapshot.lastErrorCode)
    }

    func testRetryPublicationErrorAfterInvalidationKeepsMutationEvidence() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: document(), context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        await persistence.failNextPublish()
        do {
            _ = try await session.commitInspectorEdit(.setNodeLabel(id: "node", from: nil, to: "retry"))
            XCTFail("Expected injected publication error")
        } catch PlanningTestPersistenceError.injected {
        }
        let retainedErrorCode = session.snapshot.lastErrorCode
        XCTAssertEqual(retainedErrorCode, "injected")
        let staged = await persistence.stagedRequestSnapshot()
        let originalRequest = try XCTUnwrap(staged.first)

        await persistence.blockPublish()
        let retryTask = Task { @MainActor in
            try await session.retryPending()
        }
        await persistence.waitForPublishEntry()
        session.updateAccessContext(PlanningCanvasAccessContext(
            vaultID: context.vaultID,
            selectionGeneration: UUID()
        ))
        await persistence.failNextPublish()
        await persistence.releasePublish()
        do {
            _ = try await retryTask.value
            XCTFail("Expected stale retry publication error")
        } catch PlanningCanvasSessionError.staleGeneration {
        }
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertEqual(session.snapshot.lastErrorCode, retainedErrorCode)
        let published = await persistence.publishedRequestSnapshot()
        guard published.count == 2 else {
            XCTFail("Expected initial and retry publication attempts")
            return
        }
        XCTAssertEqual(published[0], originalRequest)
        XCTAssertEqual(published[1], originalRequest)
    }

    func testPreparationFailureLeavesDraftSpatialIndexHistoryAndWritesUntouched() async throws {
        let label = String(repeating: "a", count: 400_000)
        var nodes: [PlanningCanvasNode] = []
        nodes.reserveCapacity(5)
        for index in 0..<5 {
            nodes.append(try PlanningCanvasNode(
                id: "large-" + String(index),
                type: .text,
                x: Double(index * 120),
                y: 0,
                width: 100,
                height: 60,
                text: "Large",
                label: label
            ))
        }
        let largeDocument = try PlanningCanvasDocument(nodes: nodes, edges: [])
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let persistence = try PlanningSessionPersistenceDouble(document: largeDocument, context: context)
        let session = try makeSession(persistence: persistence, context: context)
        try await session.load()
        let originalLabel = session.currentState?.document.nodes.first?.label
        let acceptedVersion = session.acceptedContentVersion
        var originalSpatial = session.spatialIndex
        XCTAssertEqual(originalSpatial.hitTest(PlanningSpatialPoint(x: 10, y: 30)).first?.id, "large-0")

        let oversizedLabel = String(repeating: "b", count: 512_000)
        do {
            _ = try await session.commitInspectorEdit(
                .setNodeLabel(id: "large-0", from: originalLabel, to: oversizedLabel)
            )
            XCTFail("Expected preparation backpressure")
        } catch {
        }
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.currentState?.document.nodes.first?.label, originalLabel)
        XCTAssertEqual(session.acceptedContentVersion, acceptedVersion)
        originalSpatial = session.spatialIndex
        XCTAssertEqual(originalSpatial.hitTest(PlanningSpatialPoint(x: 10, y: 30)).first?.id, "large-0")
        XCTAssertEqual(session.historyCount, 0)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.stage, 0)
        XCTAssertEqual(counts.publish, 0)

        let interaction = try session.beginInteraction(.moveNode(
            id: "large-0",
            from: try PlanningCanvasPoint(x: 0, y: 0),
            to: try PlanningCanvasPoint(x: 20, y: 0)
        ))
        try session.cancelInteraction(interaction)
        XCTAssertEqual(session.currentState?.document.nodes.first?.x, 0)
        originalSpatial = session.spatialIndex
        XCTAssertEqual(originalSpatial.hitTest(PlanningSpatialPoint(x: 10, y: 30)).first?.id, "large-0")
    }
}
