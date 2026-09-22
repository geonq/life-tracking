import Foundation
import SwiftUI
import XCTest
@testable import LifeOSMac

private enum P06TestError: Error {
    case injected
}

private actor P06PersistenceSpy: PlanningCanvasPersistence {
    private var bytes: Data?
    private let accessContext: PlanningCanvasAccessContext
    private var publicationStatus: PlanningFilesystemPublicationStatus = .published
    private var shouldFailStage = false
    private var shouldFailRead = false
    private var suspendNextStageRequest = false
    private var stageStarted = false
    private var stageRelease: CheckedContinuation<Void, Never>?
    private var releaseStageRequested = false
    private var stageStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stageCount = 0
    private(set) var publishCount = 0
    private(set) var operations: [PlanningMutationOperation] = []

    init(document: PlanningCanvasDocument?, context: PlanningCanvasAccessContext) throws {
        bytes = try document.map(PlanningCanvasCodec.encode)
        accessContext = context
    }

    func context() async throws -> PlanningCanvasAccessContext { accessContext }

    func read(_ path: PlanningStoredPath) async throws -> PlanningCanvasPersistenceRead {
        if shouldFailRead {
            shouldFailRead = false
            throw P06TestError.injected
        }
        return PlanningCanvasPersistenceRead(
            path: path,
            bytes: bytes ?? Data(),
            version: bytes.map(PlanningContentVersion.init(data:)) ?? .absent,
            isAbsent: bytes == nil,
            context: accessContext
        )
    }

    func stage(
        _ request: PlanningMutationRequest,
        expectedContext: PlanningCanvasAccessContext
    ) async throws -> PlanningMutationReceipt {
        stageCount += 1
        operations.append(request.operation)
        if suspendNextStageRequest {
            suspendNextStageRequest = false
            stageStarted = true
            let waiters = stageStartWaiters
            stageStartWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            if releaseStageRequested {
                releaseStageRequested = false
            } else {
                await withCheckedContinuation { continuation in
                    stageRelease = continuation
                }
            }
            stageRelease = nil
            stageStarted = false
        }
        if shouldFailStage {
            shouldFailStage = false
            throw P06TestError.injected
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
        switch publicationStatus {
        case .published, .reconciled:
            bytes = request.proposedBytes
            return PlanningFilesystemPublishResult(
                status: publicationStatus,
                version: request.proposedBytes.map(PlanningContentVersion.init(data:))
            )
        case .queued, .staged, .conflicted, .blocked:
            return PlanningFilesystemPublishResult(status: publicationStatus, errorCode: "test")
        }
    }

    func setPublicationStatus(_ status: PlanningFilesystemPublicationStatus) {
        publicationStatus = status
    }

    func failNextStage() {
        shouldFailStage = true
    }

    func failNextRead() {
        shouldFailRead = true
    }

    func suspendNextStage() {
        suspendNextStageRequest = true
        releaseStageRequested = false
    }

    func waitForStageStart() async {
        if stageStarted { return }
        await withCheckedContinuation { continuation in
            stageStartWaiters.append(continuation)
        }
    }

    func releaseStage() {
        if let stageRelease {
            self.stageRelease = nil
            stageRelease.resume()
        } else {
            releaseStageRequested = true
        }
    }

    func counts() -> (stage: Int, publish: Int, operations: [PlanningMutationOperation]) {
        (stageCount, publishCount, operations)
    }
}

@MainActor
final class PlanningInteractionTests: XCTestCase {
    func testViewportRoundTripFocalZoomFitAndInvalidInput() {
        var viewport = PlanningCanvasViewport(translation: CGSize(width: 24, height: -18), scale: 1.25)
        let world = CGPoint(x: 120, y: -40)
        let screen = viewport.screenPoint(world: world)
        XCTAssertEqual(viewport.worldPoint(screen: screen).x, world.x, accuracy: 0.0001)
        XCTAssertEqual(viewport.worldPoint(screen: screen).y, world.y, accuracy: 0.0001)

        let focal = CGPoint(x: 300, y: 180)
        let focalWorld = viewport.worldPoint(screen: focal)
        viewport.zoom(to: 2, around: focal)
        let preserved = viewport.worldPoint(screen: focal)
        XCTAssertEqual(preserved.x, focalWorld.x, accuracy: 0.0001)
        XCTAssertEqual(preserved.y, focalWorld.y, accuracy: 0.0001)
        XCTAssertEqual(viewport.scale, 2)

        viewport.zoom(to: 0.01, around: focal)
        XCTAssertEqual(viewport.scale, PlanningCanvasViewport.minimumScale)
        let beforeInvalid = viewport
        viewport.pan(by: CGSize(width: CGFloat.infinity, height: 0))
        viewport.zoom(to: CGFloat.nan, around: focal)
        viewport.fit(bounds: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100), in: CGSize(width: 800, height: 600))
        XCTAssertEqual(viewport, beforeInvalid)

        viewport.fit(bounds: .null, in: .zero)
        XCTAssertEqual(viewport, PlanningCanvasViewport())
        viewport.pan(by: CGSize(width: 10, height: 10))
        let beforeInvalidSize = viewport
        viewport.fit(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), in: CGSize(width: CGFloat.nan, height: 100))
        XCTAssertEqual(viewport, beforeInvalidSize)

        let visible = viewport.visibleWorldRect(in: CGSize(width: 800, height: 600), overscan: 64)
        XCTAssertFalse(visible.isNull)
        XCTAssertGreaterThan(visible.width, 0)
    }

    func testGestureBridgeKeepsExclusiveOwnersAcrossPlatforms() {
        var mac = PlanningGestureBridge(platform: .macOS)
        XCTAssertEqual(mac.beginPointer(at: .zero, nodeID: "node"), .nodeDrag)
        XCTAssertEqual(mac.beginZoom(at: CGPoint(x: 10, y: 10)), .nodeDrag)
        mac.escape()
        XCTAssertEqual(mac.owner, .cancelled)
        mac.end()
        XCTAssertEqual(mac.owner, .idle)

        var phone = PlanningGestureBridge(platform: .iOS)
        XCTAssertEqual(phone.beginPointer(at: .zero, nodeID: "node", timestamp: 10), .pendingNodeLongPress)
        XCTAssertEqual(phone.movePointer(to: CGPoint(x: 2, y: 2), timestamp: 10.1), .pendingNodeLongPress)
        XCTAssertEqual(phone.movePointer(to: CGPoint(x: 2, y: 2), timestamp: 10.2), .nodeDrag)
        phone.end()
        XCTAssertEqual(phone.beginPointer(at: .zero, nodeID: "locked", nodeLocked: true), .selection)
        phone.end()
        XCTAssertEqual(phone.beginPointer(at: .zero, nodeID: "node", timestamp: 20), .pendingNodeLongPress)
        XCTAssertEqual(phone.movePointer(to: CGPoint(x: 9, y: 0), timestamp: 20.01), .pan)
    }

    func testGestureBridgeRejectsStaleOwnerTerminationAndRecognizesStationaryLongPress() {
        var bridge = PlanningGestureBridge(platform: .iOS)
        XCTAssertEqual(
            bridge.beginPointer(at: .zero, nodeID: "node", timestamp: 10),
            .pendingNodeLongPress
        )
        let sequence = bridge.sequenceID
        XCTAssertEqual(
            bridge.movePointer(to: .zero, timestamp: 10 + PlanningGestureBridge.nodeLongPressDelay),
            .nodeDrag
        )
        XCTAssertTrue(bridge.owns(sequenceID: sequence, owner: .nodeDrag))
        XCTAssertFalse(bridge.finish(sequenceID: sequence + 1, owner: .nodeDrag))
        XCTAssertTrue(bridge.isActive)
        XCTAssertTrue(bridge.finish(sequenceID: sequence, owner: .nodeDrag))
        XCTAssertEqual(bridge.owner, .idle)

        XCTAssertEqual(bridge.beginPointer(at: .zero, nodeID: "node", timestamp: 20), .pendingNodeLongPress)
        XCTAssertTrue(bridge.finish(sequenceID: bridge.sequenceID, owner: .pendingNodeLongPress))
        XCTAssertEqual(bridge.owner, .idle)
    }

    func testMacSpacePanWinsOverNodeAndCancellationRejectsForeignFinish() {
        var bridge = PlanningGestureBridge(platform: .macOS)
        XCTAssertEqual(
            bridge.beginPointer(
                at: .zero,
                nodeID: "node",
                spacePressed: true,
                timestamp: 10
            ),
            .spacePan
        )
        let pointerSequence = bridge.sequenceID
        XCTAssertNil(bridge.activeNodeID)
        XCTAssertFalse(bridge.finish(sequenceID: pointerSequence, owner: .nodeDrag))
        bridge.cancel()
        XCTAssertFalse(bridge.finish(sequenceID: pointerSequence, owner: .spacePan))

        XCTAssertEqual(
            bridge.beginZoom(at: CGPoint(x: 300, y: 120), timestamp: 20),
            .zoom
        )
        let magnifySequence = bridge.sequenceID
        XCTAssertFalse(bridge.finish(sequenceID: magnifySequence, owner: .pan))
        XCTAssertTrue(bridge.finish(sequenceID: magnifySequence, owner: .zoom))
        XCTAssertEqual(bridge.owner, .idle)
    }

    func testSpacePanCanRestartAfterCancellationAndViewportEventsUseLatestTransform() {
        var bridge = PlanningGestureBridge(platform: .macOS)
        XCTAssertEqual(
            bridge.beginPointer(at: .zero, nodeID: "node", spacePressed: true),
            .spacePan
        )
        let cancelledSequence = bridge.sequenceID
        bridge.cancel()
        XCTAssertFalse(bridge.finish(sequenceID: cancelledSequence, owner: .spacePan))
        XCTAssertEqual(
            bridge.beginPointer(at: .zero, nodeID: "node", spacePressed: true),
            .spacePan
        )
        XCTAssertNotEqual(bridge.sequenceID, cancelledSequence)

        var viewport = PlanningCanvasViewport()
        viewport.pan(by: CGSize(width: 12, height: -4))
        viewport.pan(by: CGSize(width: 8, height: 6))
        XCTAssertEqual(viewport.translation, CGSize(width: 20, height: 2))
    }

    func testThirdTouchEndingFirstDoesNotStaleQuarantineAndAllowsFreshSequence() {
        final class TouchToken {}
        let aToken = TouchToken()
        let bToken = TouchToken()
        let cToken = TouchToken()
        let freshToken = TouchToken()
        let a = ObjectIdentifier(aToken)
        let b = ObjectIdentifier(bToken)
        let c = ObjectIdentifier(cToken)
        let fresh = ObjectIdentifier(freshToken)
        var lifecycle = PlanningCanvasTouchLifecycle()

        XCTAssertTrue(lifecycle.begin([a, b]))
        lifecycle.markSequence([a, b])
        XCTAssertTrue(lifecycle.begin([c]))
        lifecycle.cancelAndQuarantineLiveTouches()

        lifecycle.end([c])
        XCTAssertFalse(lifecycle.quarantinedTouchIDs.contains(c))
        XCTAssertTrue(lifecycle.quarantinedTouchIDs.contains(a))
        XCTAssertTrue(lifecycle.quarantinedTouchIDs.contains(b))

        lifecycle.end([a])
        XCTAssertTrue(lifecycle.quarantinedTouchIDs.contains(b))
        lifecycle.end([b])
        XCTAssertTrue(lifecycle.canStartNewSequence)
        XCTAssertTrue(lifecycle.begin([fresh]))
    }

    func testWindowLifecycleClearsInputAndSpaceOnDeactivation() {
        var lifecycle = PlanningCanvasInputLifecycle()
        lifecycle.beginInput()
        lifecycle.setSpacePressed(true)

        lifecycle.didResignKey()

        XCTAssertFalse(lifecycle.isInputActive)
        XCTAssertFalse(lifecycle.isSpacePressed)
    }

    func testPreviewUpdatesDoNotTouchPersistenceOrRebuildIndex() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(id: "node", x: 0, y: 0)
        let spy = try P06PersistenceSpy(document: try PlanningCanvasDocument(nodes: [node], edges: []), context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        let rebuilds = coordinator.presentationIndexRebuildCount
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: CGPoint(x: 10, y: 10), scale: 1))
        let viewport = CGRect(x: -100, y: -100, width: 400, height: 400)
        _ = coordinator.visibleNodes(in: viewport)
        _ = coordinator.visibleEdges(in: viewport)
        let queryRebuilds = coordinator.presentationQueryRebuildCount
        for index in 0..<500 {
            coordinator.updateNodeDrag(to: CGPoint(x: 10 + index, y: 10 + index))
            _ = coordinator.visibleNodes(in: viewport)
            _ = coordinator.visibleEdges(in: viewport)
        }
        let counts = await spy.counts()
        XCTAssertEqual(counts.stage, 0)
        XCTAssertEqual(counts.publish, 0)
        XCTAssertEqual(coordinator.presentationIndexRebuildCount, rebuilds)
        XCTAssertEqual(coordinator.presentationQueryRebuildCount, queryRebuilds)
        XCTAssertEqual(coordinator.transientDrag?.currentPosition, CGPoint(x: 499, y: 499))
    }

    func testCompletedDragPersistsOnceAndUndoRedoRestoreExactPositions() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(id: "node", x: 0, y: 0)
        let document = try PlanningCanvasDocument(nodes: [node], edges: [])
        let spy = try P06PersistenceSpy(document: document, context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: CGPoint(x: 10, y: 10)))
        coordinator.updateNodeDrag(to: CGPoint(x: 45, y: 60))
        let outcome = try await coordinator.commitNodeDrag()
        XCTAssertEqual(outcome?.state, .published)
        XCTAssertEqual(coordinator.nodesByID["node"]?.x, 35)
        XCTAssertEqual(coordinator.nodesByID["node"]?.y, 50)
        var counts = await spy.counts()
        XCTAssertEqual(counts.stage, 1)
        XCTAssertEqual(counts.publish, 1)
        XCTAssertEqual(counts.operations, [.replace])

        _ = try await coordinator.undo()
        XCTAssertEqual(coordinator.nodesByID["node"]?.x, 0)
        XCTAssertEqual(coordinator.nodesByID["node"]?.y, 0)
        _ = try await coordinator.redo()
        XCTAssertEqual(coordinator.nodesByID["node"]?.x, 35)
        XCTAssertEqual(coordinator.nodesByID["node"]?.y, 50)

        let reloadedSession = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let reloaded = PlanningProjectCoordinator(session: reloadedSession, accessContext: context)
        try await reloaded.open()
        XCTAssertEqual(reloaded.nodesByID["node"]?.x, 35)
        XCTAssertEqual(reloaded.nodesByID["node"]?.y, 50)
        counts = await spy.counts()
        XCTAssertEqual(counts.stage, 3)
        XCTAssertEqual(counts.publish, 3)
    }

    func testUndoRedoPublishSavingWhilePersistenceIsSuspended() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(id: "node", x: 0, y: 0)
        let spy = try P06PersistenceSpy(document: try PlanningCanvasDocument(nodes: [node], edges: []), context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06-suspended.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: .zero))
        coordinator.updateNodeDrag(to: CGPoint(x: 20, y: 20))
        _ = try await coordinator.commitNodeDrag()

        await spy.suspendNextStage()
        let undoTask = Task { try await coordinator.undo() }
        await spy.waitForStageStart()
        XCTAssertEqual(coordinator.status, .saving)
        await spy.releaseStage()
        _ = try await undoTask.value
        XCTAssertEqual(coordinator.status, .published)

        await spy.suspendNextStage()
        let redoTask = Task { try await coordinator.redo() }
        await spy.waitForStageStart()
        XCTAssertEqual(coordinator.status, .saving)
        await spy.releaseStage()
        _ = try await redoTask.value
        XCTAssertEqual(coordinator.status, .published)
    }

    func testCancellationLockedZeroDistanceAndContextInvalidationWriteNothing() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let unlocked = try makeNode(id: "node", x: 0, y: 0)
        let locked = try makeNode(id: "locked", x: 200, y: 0, locked: true)
        let spy = try P06PersistenceSpy(
            document: try PlanningCanvasDocument(nodes: [unlocked, locked], edges: []),
            context: context
        )
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        XCTAssertFalse(coordinator.beginNodeDrag(id: "locked", at: .zero))
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: CGPoint(x: 5, y: 5)))
        coordinator.cancelNodeDrag()
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: CGPoint(x: 5, y: 5)))
        let noOp = try await coordinator.commitNodeDrag()
        XCTAssertNil(noOp)
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: CGPoint(x: 5, y: 5)))
        coordinator.updateNodeDrag(to: CGPoint(x: 20, y: 20))
        coordinator.updateAccessContext(PlanningCanvasAccessContext(vaultID: context.vaultID, selectionGeneration: UUID()))
        XCTAssertNil(coordinator.transientDrag)
        let counts = await spy.counts()
        XCTAssertEqual(counts.stage, 0)
        XCTAssertEqual(counts.publish, 0)
    }

    func testFailedPreCommitValidationClearsPreviewAndDoesNotCreateRetryMutation() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(id: "node", x: 0, y: 0)
        let spy = try P06PersistenceSpy(document: try PlanningCanvasDocument(nodes: [node], edges: []), context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: .zero))
        coordinator.updateNodeDrag(to: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 0))

        do {
            _ = try await coordinator.commitNodeDrag()
            XCTFail("invalid pre-commit point should fail")
        } catch {
            XCTAssertNil(coordinator.transientDrag)
            XCTAssertEqual(coordinator.status, .failed)
            XCTAssertNotNil(coordinator.lastError)
            XCTAssertEqual(coordinator.retryMode, .none)
            let counts = await spy.counts()
            XCTAssertEqual(counts.stage, 0)
            XCTAssertEqual(counts.publish, 0)
        }
    }

    func testFailedOpenExposesOpenRetryAndRetryReopensSession() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(id: "node", x: 0, y: 0)
        let spy = try P06PersistenceSpy(document: try PlanningCanvasDocument(nodes: [node], edges: []), context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        await spy.failNextRead()
        do {
            try await coordinator.open()
            XCTFail("the injected read failure should surface")
        } catch {
            XCTAssertEqual(coordinator.retryMode, .open)
            XCTAssertEqual(coordinator.status, .failed)
        }
        _ = try await coordinator.retry()
        XCTAssertEqual(coordinator.retryMode, .none)
        XCTAssertEqual(coordinator.status, .ready)
        XCTAssertEqual(coordinator.document?.nodes.count, 1)
    }

    func testFailedStageNeverReportsPublishedAndQueuedBlocksUntilRetry() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(id: "node", x: 0, y: 0)
        let spy = try P06PersistenceSpy(document: try PlanningCanvasDocument(nodes: [node], edges: []), context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        await spy.failNextStage()
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: .zero))
        coordinator.updateNodeDrag(to: CGPoint(x: 20, y: 20))
        do {
            _ = try await coordinator.commitNodeDrag()
            XCTFail("stage should fail")
        } catch {
            XCTAssertNotEqual(coordinator.status, .published)
            XCTAssertEqual(coordinator.status, .failed)
            XCTAssertEqual(coordinator.retryMode, .pendingMutation)
        }

        await spy.setPublicationStatus(.queued)
        _ = try? await coordinator.retryPending()
        XCTAssertEqual(coordinator.status, .queued)
        XCTAssertFalse(coordinator.beginNodeDrag(id: "node", at: .zero))
        await spy.setPublicationStatus(.published)
        _ = try await coordinator.retryPending()
        XCTAssertEqual(coordinator.status, .published)
        XCTAssertEqual(coordinator.retryMode, .none)
    }

    func testUndoFailureRetainsActionableRetryUntilPublicationSucceeds() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(id: "node", x: 0, y: 0)
        let spy = try P06PersistenceSpy(document: try PlanningCanvasDocument(nodes: [node], edges: []), context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06-undo.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: .zero))
        coordinator.updateNodeDrag(to: CGPoint(x: 20, y: 20))
        _ = try await coordinator.commitNodeDrag()

        await spy.failNextStage()
        do {
            _ = try await coordinator.undo()
            XCTFail("undo staging should fail")
        } catch {
            XCTAssertEqual(coordinator.status, .failed)
            XCTAssertEqual(coordinator.retryMode, .pendingMutation)
        }

        await spy.setPublicationStatus(.published)
        let outcome = try await coordinator.retryPending()
        XCTAssertEqual(outcome?.state, .published)
        XCTAssertEqual(coordinator.retryMode, .none)
    }

    func testPresentationEdgesUseAnchorsAndDraggedIncidentEdgesStayMounted() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let first = try makeNode(id: "first", x: 0, y: 0, width: 100, height: 80)
        let second = try makeNode(id: "second", x: 300, y: 0, width: 100, height: 80)
        let edge = try PlanningCanvasEdge(
            id: "edge",
            fromNode: "first",
            fromSide: "right",
            toNode: "second",
            toSide: "left"
        )
        let document = try PlanningCanvasDocument(nodes: [first, second], edges: [edge])
        let spy = try P06PersistenceSpy(document: document, context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        let initial = coordinator.visibleEdges(in: CGRect(x: -10, y: -10, width: 80, height: 100))
        XCTAssertTrue(initial.isEmpty)
        let wide = coordinator.visibleEdges(in: CGRect(x: -10, y: -10, width: 500, height: 200))
        XCTAssertEqual(wide.first?.points.first, CGPoint(x: 100, y: 40))
        XCTAssertEqual(wide.first?.points.last, CGPoint(x: 300, y: 40))

        XCTAssertTrue(coordinator.beginNodeDrag(id: "first", at: CGPoint(x: 50, y: 40)))
        coordinator.updateNodeDrag(to: CGPoint(x: 1_050, y: 1_040))
        let incident = coordinator.visibleEdges(in: CGRect(x: 1_000, y: 1_000, width: 10, height: 10))
        XCTAssertEqual(incident.map(\.id), ["edge"])
        XCTAssertEqual(incident.first?.points.first, CGPoint(x: 1_100, y: 1_040))
    }

    func testImplicitRectangularAnchorsStayOnBoundaryAndRenderGeometryMatchesHitTesting() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let wide = try makeNode(id: "wide", x: 0, y: 0, width: 200, height: 40)
        let target = try makeNode(id: "target", x: 200, y: 100, width: 20, height: 20)
        let edge = try PlanningCanvasEdge(
            id: "edge",
            fromNode: "wide",
            toNode: "target"
        )
        let spy = try P06PersistenceSpy(
            document: try PlanningCanvasDocument(nodes: [wide, target], edges: [edge]),
            context: context
        )
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()

        let edgePresentation = try XCTUnwrap(
            coordinator.visibleEdges(in: CGRect(x: -100, y: -100, width: 500, height: 400)).first
        )
        let sourcePoint = try XCTUnwrap(edgePresentation.points.first)
        let effectiveSource = PlanningCanvasNodeGeometry.rect(for: wide)
        XCTAssertGreaterThanOrEqual(sourcePoint.x, effectiveSource.minX - 0.0001)
        XCTAssertLessThanOrEqual(sourcePoint.x, effectiveSource.maxX + 0.0001)
        XCTAssertGreaterThanOrEqual(sourcePoint.y, effectiveSource.minY - 0.0001)
        XCTAssertLessThanOrEqual(sourcePoint.y, effectiveSource.maxY + 0.0001)
        XCTAssertEqual(sourcePoint.y, effectiveSource.maxY, accuracy: 0.0001)

        let small = try makeNode(id: "small", x: 20, y: 10, width: 10, height: 10)
        let group = try PlanningCanvasNode(
            id: "group",
            type: .group,
            x: 0,
            y: 0,
            width: 10,
            height: 10,
            text: "Group"
        )
        let overlapSpy = try P06PersistenceSpy(
            document: try PlanningCanvasDocument(nodes: [group, small], edges: []),
            context: context
        )
        let overlapSession = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06-overlap.canvas"),
            context: context,
            persistence: overlapSpy
        )
        let overlapCoordinator = PlanningProjectCoordinator(session: overlapSession, accessContext: context)
        try await overlapCoordinator.open()
        XCTAssertEqual(overlapCoordinator.nodeID(at: CGPoint(x: 25, y: 20)), "small")
        XCTAssertEqual(
            PlanningCanvasNodePresentation(node: small, sourceIndex: 1).bounds,
            PlanningCanvasNodeGeometry.rect(for: small)
        )
    }

    func testCulledViewportIsDistinctFromEmptyDocument() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(id: "node", x: 0, y: 0)
        let spy = try P06PersistenceSpy(document: try PlanningCanvasDocument(nodes: [node], edges: []), context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        XCTAssertFalse(coordinator.document?.nodes.isEmpty ?? true)
        XCTAssertTrue(coordinator.visibleNodes(in: CGRect(x: 10_000, y: 10_000, width: 10, height: 10)).isEmpty)
        XCTAssertNotNil(PlanningCanvasView(coordinator: coordinator).body)
    }

    func testUnknownCanvasFieldsSurviveMoveAndNativeViewHasBoundedSurface() async throws {
        let context = PlanningCanvasAccessContext(vaultID: UUID(), selectionGeneration: UUID())
        let node = try makeNode(
            id: "node",
            x: 0,
            y: 0,
            unknownFields: ["future": .object(["value": .number("1.2300e+10")])]
        )
        let spy = try P06PersistenceSpy(document: try PlanningCanvasDocument(nodes: [node], edges: []), context: context)
        let session = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let coordinator = PlanningProjectCoordinator(session: session, accessContext: context)
        try await coordinator.open()
        XCTAssertTrue(coordinator.beginNodeDrag(id: "node", at: .zero))
        coordinator.updateNodeDrag(to: CGPoint(x: 25, y: 35))
        _ = try await coordinator.commitNodeDrag()
        let reloadedSession = PlanningCanvasSession(
            path: try PlanningStoredPath("Projects/P06.canvas"),
            context: context,
            persistence: spy
        )
        let reloaded = PlanningProjectCoordinator(session: reloadedSession, accessContext: context)
        try await reloaded.open()
        XCTAssertEqual(reloaded.nodesByID["node"]?.unknownFields, node.unknownFields)
        XCTAssertNotNil(PlanningCanvasView(coordinator: reloaded).body)
    }

    private func makeNode(
        id: String,
        x: Double,
        y: Double,
        width: Double = 100,
        height: Double = 80,
        locked: Bool? = nil,
        unknownFields: [String: PlanningJSONValue] = [:]
    ) throws -> PlanningCanvasNode {
        try PlanningCanvasNode(
            id: id,
            type: .text,
            x: x,
            y: y,
            width: width,
            height: height,
            text: "A bounded planning node with a long enough label to exercise clipping behavior.",
            locked: locked,
            unknownFields: unknownFields
        )
    }
}
