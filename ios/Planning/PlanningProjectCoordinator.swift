import Combine
import CoreGraphics
import Foundation
import SwiftUI

public enum PlanningCanvasPresentationStatus: String, Equatable, Sendable {
    case idle
    case loading
    case ready
    case saving
    case savedLocally
    case publishing
    case published
    case queued
    case conflicted
    case unavailable
    case failed

    public var title: String {
        switch self {
        case .idle: return "Not open"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .saving: return "Saving locally"
        case .savedLocally: return "Saved locally"
        case .publishing: return "Publishing"
        case .published: return "Published to vault"
        case .queued: return "Queued for publication"
        case .conflicted: return "Conflict needs review"
        case .unavailable: return "Unavailable"
        case .failed: return "Needs attention"
        }
    }
}

/// The single geometry contract shared by rendering, hit testing, fitting, and
/// edge anchors. Canvas files can contain very small nodes, but the native
/// surface keeps a readable interaction target for those nodes.
public enum PlanningCanvasNodeGeometry {
    public static let minimumWidth: CGFloat = 80
    public static let minimumHeight: CGFloat = 44

    public static func effectiveSize(for node: PlanningCanvasNode) -> CGSize {
        let width = CGFloat(node.width)
        let height = CGFloat(node.height)
        guard width.isFinite, height.isFinite else {
            return CGSize(width: minimumWidth, height: minimumHeight)
        }
        return CGSize(
            width: max(width, minimumWidth),
            height: max(height, minimumHeight)
        )
    }

    public static func rect(
        for node: PlanningCanvasNode,
        at position: CGPoint? = nil
    ) -> CGRect {
        let origin = position ?? CGPoint(x: node.x, y: node.y)
        return CGRect(origin: origin, size: effectiveSize(for: node))
    }

    public static func drawPriority(for node: PlanningCanvasNode, sourceIndex: Int) -> Double {
        let source = Double(sourceIndex)
        return node.type == .group ? -1_000_000 + source : source
    }
}

public struct PlanningCanvasNodePresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let node: PlanningCanvasNode
    public let sourceIndex: Int
    public let position: CGPoint
    public let isDragged: Bool

    public var bounds: CGRect {
        PlanningCanvasNodeGeometry.rect(for: node, at: position)
    }

    public init(
        node: PlanningCanvasNode,
        sourceIndex: Int,
        position: CGPoint? = nil,
        isDragged: Bool = false
    ) {
        self.id = node.id
        self.node = node
        self.sourceIndex = sourceIndex
        self.position = position ?? CGPoint(x: node.x, y: node.y)
        self.isDragged = isDragged
    }
}

public struct PlanningCanvasEdgePresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let edge: PlanningCanvasEdge
    public let sourceIndex: Int
    public let points: [CGPoint]
    public let isIncidentToDraggedNode: Bool

    public init(
        edge: PlanningCanvasEdge,
        sourceIndex: Int,
        points: [CGPoint],
        isIncidentToDraggedNode: Bool = false
    ) {
        self.id = edge.id
        self.edge = edge
        self.sourceIndex = sourceIndex
        self.points = points
        self.isIncidentToDraggedNode = isIncidentToDraggedNode
    }
}

public struct PlanningCanvasTransientDrag: Equatable, Sendable {
    public let nodeID: String
    public let originalPosition: CGPoint
    public let currentPosition: CGPoint
    public let capturedRevision: String?
    public let capturedAccessGeneration: UUID?
    public let startingScale: CGFloat

    public init(
        nodeID: String,
        originalPosition: CGPoint,
        currentPosition: CGPoint,
        capturedRevision: String?,
        capturedAccessGeneration: UUID?,
        startingScale: CGFloat
    ) {
        self.nodeID = nodeID
        self.originalPosition = originalPosition
        self.currentPosition = currentPosition
        self.capturedRevision = capturedRevision
        self.capturedAccessGeneration = capturedAccessGeneration
        self.startingScale = startingScale
    }
}

public enum PlanningCanvasRetryMode: String, Equatable, Sendable {
    case none
    case open
    case pendingMutation
}

/// Main-actor presentation boundary for the native Canvas interaction.
/// The injected session remains the only persistence owner. This object caches
/// projection data and keeps drag preview state out of the session until the
/// pointer is released.
@MainActor
public final class PlanningProjectCoordinator: ObservableObject {
    public let session: PlanningCanvasSession
    public let allowsEditing: Bool

    @Published public private(set) var document: PlanningCanvasDocument?
    @Published public private(set) var status: PlanningCanvasPresentationStatus = .idle
    @Published public private(set) var selectedNodeID: String?
    @Published public private(set) var transientDrag: PlanningCanvasTransientDrag?
    @Published public private(set) var lastError: String?
    @Published public private(set) var retryMode: PlanningCanvasRetryMode = .none

    public private(set) var nodesByID: [String: PlanningCanvasNode] = [:]
    public private(set) var edgesByID: [String: PlanningCanvasEdge] = [:]
    public private(set) var nodeSourceOrdinals: [String: Int] = [:]
    public private(set) var edgeSourceOrdinals: [String: Int] = [:]
    public private(set) var incidentEdgeIDsByNodeID: [String: [String]] = [:]
    public private(set) var presentationIndexRebuildCount = 0
    public private(set) var presentationQueryRebuildCount = 0

    private var expectedAccessContext: PlanningCanvasAccessContext?
    private var cachedRevision: String?
    private var nodeBoundsByID: [String: CGRect] = [:]
    private var presentationIndex = PlanningSpatialIndex()
    private var cacheDocument: PlanningCanvasDocument?
    private var dragStartWorldPoint: CGPoint?

    private struct PresentationQueryKey: Equatable {
        let revision: String?
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
        let draggedNodeID: String?

        init(revision: String?, rect: PlanningSpatialRect, draggedNodeID: String?) {
            self.revision = revision
            minX = rect.minX
            minY = rect.minY
            maxX = rect.maxX
            maxY = rect.maxY
            self.draggedNodeID = draggedNodeID
        }
    }

    private struct PresentationQueryCache {
        let key: PresentationQueryKey
        let nodes: [PlanningCanvasNodePresentation]
        let nodeIndexByID: [String: Int]
        let edges: [PlanningCanvasEdgePresentation]
        let edgeIndexByID: [String: Int]
    }

    private var presentationQueryCache: PresentationQueryCache?

    public init(
        session: PlanningCanvasSession,
        accessContext: PlanningCanvasAccessContext? = nil,
        allowsEditing: Bool = true
    ) {
        self.session = session
        self.expectedAccessContext = accessContext
        self.allowsEditing = allowsEditing
    }

    public var canEdit: Bool {
        guard allowsEditing, session.currentState != nil else { return false }
        switch session.state {
        case .ready, .published, .savedOnDevice:
            return true
        case .idle, .loading, .saving, .publishing, .queued, .conflicted, .unavailable, .failed:
            return false
        }
    }

    /// Loads through the injected session and builds one O(V+E) presentation
    /// cache for the current document.
    public func open() async throws {
        status = .loading
        lastError = nil
        retryMode = .none
        do {
            try await session.load()
            rebuildCacheIfNeeded()
            status = status(for: session.state)
        } catch {
            lastError = String(describing: error)
            status = .failed
            retryMode = .open
            throw error
        }
    }

    public func retry() async throws -> PlanningCanvasCommitOutcome? {
        switch retryMode {
        case .none:
            return nil
        case .open:
            try await open()
            return nil
        case .pendingMutation:
            return try await retryPending()
        }
    }

    public func updateAccessContext(_ context: PlanningCanvasAccessContext) {
        expectedAccessContext = context
        cancelNodeDrag()
        session.updateAccessContext(context)
        clearCache()
        status = .unavailable
    }

    public func selectNode(_ id: String?) {
        guard let id else {
            selectedNodeID = nil
            return
        }
        guard nodesByID[id] != nil else { return }
        selectedNodeID = id
    }

    /// Starts a drag preview. No session interaction, index rebuild, or write
    /// occurs here; all document work is deferred to commitNodeDrag().
    @discardableResult
    public func beginNodeDrag(
        id: String,
        at worldPoint: CGPoint? = nil,
        scale: CGFloat = 1
    ) -> Bool {
        guard let node = nodesByID[id], canEdit,
              scale.isFinite, scale > 0 else { return false }
        selectedNodeID = id
        guard node.locked != true else { return false }

        let original = CGPoint(x: node.x, y: node.y)
        let start = worldPoint ?? CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)
        guard Self.isFinite(start), Self.isFinite(original) else { return false }

        let snapshot = session.snapshot
        transientDrag = PlanningCanvasTransientDrag(
            nodeID: id,
            originalPosition: original,
            currentPosition: original,
            capturedRevision: snapshot.revision,
            capturedAccessGeneration: expectedAccessContext?.selectionGeneration,
            startingScale: scale
        )
        dragStartWorldPoint = start
        presentationQueryCache = nil
        lastError = nil
        retryMode = .none
        return true
    }

    /// Updates only the transient presentation offset. The cached index and
    /// persistence layer remain untouched for the entire preview.
    public func updateNodeDrag(to worldPoint: CGPoint) {
        guard let drag = transientDrag,
              let dragStartWorldPoint,
              Self.isFinite(worldPoint) else { return }
        let x = (drag.originalPosition.x + worldPoint.x - dragStartWorldPoint.x).rounded()
        let y = (drag.originalPosition.y + worldPoint.y - dragStartWorldPoint.y).rounded()
        guard x.isFinite, y.isFinite else { return }
        transientDrag = PlanningCanvasTransientDrag(
            nodeID: drag.nodeID,
            originalPosition: drag.originalPosition,
            currentPosition: CGPoint(x: x, y: y),
            capturedRevision: drag.capturedRevision,
            capturedAccessGeneration: drag.capturedAccessGeneration,
            startingScale: drag.startingScale
        )
    }

    public func updateNodeDrag(by worldDelta: CGSize) {
        guard let drag = transientDrag,
              Self.isFinite(worldDelta) else { return }
        updateNodeDrag(to: CGPoint(
            x: (dragStartWorldPoint?.x ?? drag.originalPosition.x) + worldDelta.width,
            y: (dragStartWorldPoint?.y ?? drag.originalPosition.y) + worldDelta.height
        ))
    }

    public func cancelNodeDrag() {
        transientDrag = nil
        dragStartWorldPoint = nil
        presentationQueryCache = nil
    }

    /// Converts the single completed drag into exactly one move command and
    /// lets the existing session own staging, publication, undo, and recovery.
    @discardableResult
    public func commitNodeDrag() async throws -> PlanningCanvasCommitOutcome? {
        guard let drag = transientDrag else { return nil }
        var interactionID: UUID?
        do {
            guard drag.capturedRevision == session.snapshot.revision,
                  drag.capturedAccessGeneration == expectedAccessContext?.selectionGeneration,
                  canEdit else {
                cancelNodeDrag()
                status = .conflicted
                retryMode = .none
                throw PlanningCanvasSessionError.staleGeneration
            }
            guard drag.currentPosition != drag.originalPosition else {
                cancelNodeDrag()
                retryMode = .none
                return nil
            }

            let from = try PlanningCanvasPoint(
                x: drag.originalPosition.x,
                y: drag.originalPosition.y
            )
            let to = try PlanningCanvasPoint(
                x: drag.currentPosition.x,
                y: drag.currentPosition.y
            )
            let edit = PlanningCanvasEdit.moveNode(id: drag.nodeID, from: from, to: to)
            status = .saving
            let startedInteractionID = try session.beginInteraction(edit)
            interactionID = startedInteractionID
            cancelNodeDrag()
            let outcome = try await session.commitInteraction(startedInteractionID)
            rebuildCacheIfNeeded()
            apply(outcome: outcome)
            return outcome
        } catch {
            if let interactionID {
                try? session.cancelInteraction(interactionID)
            }
            cancelNodeDrag()
            rebuildCacheIfNeeded()
            recordOperationFailure(error)
            throw error
        }
    }

    @discardableResult
    public func undo() async throws -> PlanningCanvasCommitOutcome? {
        guard transientDrag == nil, canEdit else { return nil }
        status = .saving
        lastError = nil
        retryMode = .none
        do {
            let outcome = try await session.undo()
            rebuildCacheIfNeeded()
            apply(outcome: outcome)
            return outcome
        } catch {
            rebuildCacheIfNeeded()
            recordOperationFailure(error)
            throw error
        }
    }

    @discardableResult
    public func redo() async throws -> PlanningCanvasCommitOutcome? {
        guard transientDrag == nil, canEdit else { return nil }
        status = .saving
        lastError = nil
        retryMode = .none
        do {
            let outcome = try await session.redo()
            rebuildCacheIfNeeded()
            apply(outcome: outcome)
            return outcome
        } catch {
            rebuildCacheIfNeeded()
            recordOperationFailure(error)
            throw error
        }
    }

    @discardableResult
    public func retryPending() async throws -> PlanningCanvasCommitOutcome? {
        guard allowsEditing, transientDrag == nil else { return nil }
        retryMode = .pendingMutation
        status = .saving
        do {
            let outcome = try await session.retryPending()
            rebuildCacheIfNeeded()
            if let outcome {
                apply(outcome: outcome)
            } else {
                lastError = nil
                status = status(for: session.state)
                retryMode = .none
            }
            return outcome
        } catch {
            recordOperationFailure(error, forcePendingMutationRetry: true)
            throw error
        }
    }

    public func visibleNodes(
        in viewport: PlanningCanvasViewport,
        size: CGSize,
        overscan: CGFloat = 64
    ) -> [PlanningCanvasNodePresentation] {
        visibleNodes(in: viewport.visibleWorldRect(in: size, overscan: overscan))
    }

    public func visibleNodes(in worldRect: CGRect) -> [PlanningCanvasNodePresentation] {
        guard let query = planningRect(worldRect) else { return [] }
        let cache = presentationCache(for: query)
        guard let drag = transientDrag,
              let index = cache.nodeIndexByID[drag.nodeID],
              let node = nodesByID[drag.nodeID],
              let sourceIndex = nodeSourceOrdinals[drag.nodeID] else {
            return cache.nodes
        }
        var presentations = cache.nodes
        presentations[index] = PlanningCanvasNodePresentation(
            node: node,
            sourceIndex: sourceIndex,
            position: drag.currentPosition,
            isDragged: true
        )
        return presentations
    }

    public func visibleEdges(
        in viewport: PlanningCanvasViewport,
        size: CGSize,
        overscan: CGFloat = 64
    ) -> [PlanningCanvasEdgePresentation] {
        visibleEdges(in: viewport.visibleWorldRect(in: size, overscan: overscan))
    }

    public func visibleEdges(in worldRect: CGRect) -> [PlanningCanvasEdgePresentation] {
        guard let query = planningRect(worldRect) else { return [] }
        let cache = presentationCache(for: query)
        guard let drag = transientDrag else { return cache.edges }

        var presentations = cache.edges
        for edgeID in incidentEdgeIDsByNodeID[drag.nodeID] ?? [] {
            guard let index = cache.edgeIndexByID[edgeID],
                  let edge = edgesByID[edgeID],
                  let sourceIndex = edgeSourceOrdinals[edgeID],
                  let presentation = edgePresentation(
                    edge: edge,
                    sourceIndex: sourceIndex,
                    draggedNodeID: drag.nodeID
                  ) else { continue }
            presentations[index] = presentation
        }
        return presentations
    }

    /// Builds the ordered static presentation once for a document/revision and
    /// viewport rectangle. During a drag, the cache key changes only when the
    /// dragged node enters or leaves the sequence; its position does not
    /// invalidate the broad-phase query or the non-incident presentations.
    /// Each frame copies the visible node/edge arrays to replace one node and
    /// refresh the dragged node's incident edges. Frame preparation is
    /// O(visible nodes + visible edges + degree(dragged node)); persistence and
    /// the broad-phase index remain untouched during the preview.
    private func presentationCache(for query: PlanningSpatialRect) -> PresentationQueryCache {
        let key = PresentationQueryKey(
            revision: cachedRevision,
            rect: query,
            draggedNodeID: transientDrag?.nodeID
        )
        if let presentationQueryCache, presentationQueryCache.key == key {
            return presentationQueryCache
        }

        var nodeIDs = presentationIndex.queryNodes(in: query)
        if let draggedNodeID = transientDrag?.nodeID {
            nodeIDs.append(draggedNodeID)
        }
        nodeIDs = Array(Set(nodeIDs)).sorted {
            nodeSourceOrdinals[$0, default: .max] < nodeSourceOrdinals[$1, default: .max]
        }

        let nodes = nodeIDs.compactMap { id -> PlanningCanvasNodePresentation? in
            guard let node = nodesByID[id], let sourceIndex = nodeSourceOrdinals[id] else { return nil }
            return PlanningCanvasNodePresentation(
                node: node,
                sourceIndex: sourceIndex,
                position: CGPoint(x: node.x, y: node.y)
            )
        }
        var nodeIndexByID: [String: Int] = [:]
        nodeIndexByID.reserveCapacity(nodes.count)
        for (index, node) in nodes.enumerated() {
            nodeIndexByID[node.id] = index
        }

        var edgeIDs = presentationIndex.queryEdges(in: query)
        if let draggedNodeID = transientDrag?.nodeID {
            edgeIDs.append(contentsOf: incidentEdgeIDsByNodeID[draggedNodeID] ?? [])
        }
        edgeIDs = Array(Set(edgeIDs)).sorted {
            edgeSourceOrdinals[$0, default: .max] < edgeSourceOrdinals[$1, default: .max]
        }
        let edges = edgeIDs.compactMap { id -> PlanningCanvasEdgePresentation? in
            guard let edge = edgesByID[id], let sourceIndex = edgeSourceOrdinals[id] else { return nil }
            return edgePresentation(edge: edge, sourceIndex: sourceIndex, draggedNodeID: nil)
        }
        var edgeIndexByID: [String: Int] = [:]
        edgeIndexByID.reserveCapacity(edges.count)
        for (index, edge) in edges.enumerated() {
            edgeIndexByID[edge.id] = index
        }

        let cache = PresentationQueryCache(
            key: key,
            nodes: nodes,
            nodeIndexByID: nodeIndexByID,
            edges: edges,
            edgeIndexByID: edgeIndexByID
        )
        presentationQueryCache = cache
        presentationQueryRebuildCount += 1
        return cache
    }

    /// Topmost draw-order node under a world-space point.
    public func nodeID(at worldPoint: CGPoint) -> String? {
        guard Self.isFinite(worldPoint) else { return nil }
        let hits = presentationIndex.hitTest(
            PlanningSpatialPoint(x: worldPoint.x, y: worldPoint.y),
            tolerance: 0
        )
        return hits
            .filter { $0.kind == .node }
            .filter { nodesByID[$0.id] != nil && nodeSourceOrdinals[$0.id] != nil }
            .max { lhs, rhs in
                let lhsIsGroup = nodesByID[lhs.id]?.type == .group
                let rhsIsGroup = nodesByID[rhs.id]?.type == .group
                if lhsIsGroup != rhsIsGroup { return lhsIsGroup && !rhsIsGroup }
                return nodeSourceOrdinals[lhs.id, default: -1]
                    < nodeSourceOrdinals[rhs.id, default: -1]
            }?
            .id
    }

    public func fitBounds() -> CGRect {
        guard !nodeBoundsByID.isEmpty else { return .null }
        return nodeBoundsByID.values.reduce(.null) { $0.union($1) }
    }

    private func rebuildCacheIfNeeded() {
        guard let state = session.currentState else {
            clearCache()
            status = status(for: session.state)
            return
        }
        let nextDocument = state.document
        let nextRevision = session.snapshot.revision
        guard cacheDocument != nextDocument || cachedRevision != nextRevision else {
            status = status(for: session.state)
            return
        }

        var nextNodes: [String: PlanningCanvasNode] = [:]
        var nextEdges: [String: PlanningCanvasEdge] = [:]
        var nextNodeOrdinals: [String: Int] = [:]
        var nextEdgeOrdinals: [String: Int] = [:]
        var nextBounds: [String: CGRect] = [:]
        var nextIncident: [String: [String]] = [:]
        nextNodes.reserveCapacity(nextDocument.nodes.count)
        nextNodeOrdinals.reserveCapacity(nextDocument.nodes.count)
        nextBounds.reserveCapacity(nextDocument.nodes.count)
        nextEdges.reserveCapacity(nextDocument.edges.count)
        nextEdgeOrdinals.reserveCapacity(nextDocument.edges.count)
        nextIncident.reserveCapacity(nextDocument.nodes.count)

        for (index, node) in nextDocument.nodes.enumerated() {
            nextNodes[node.id] = node
            nextNodeOrdinals[node.id] = index
            nextBounds[node.id] = PlanningCanvasNodeGeometry.rect(for: node)
        }
        for (index, edge) in nextDocument.edges.enumerated() {
            nextEdges[edge.id] = edge
            nextEdgeOrdinals[edge.id] = index
            nextIncident[edge.fromNode, default: []].append(edge.id)
            nextIncident[edge.toNode, default: []].append(edge.id)
        }

        var nextIndex = PlanningSpatialIndex()
        var spatialEdges: [PlanningSpatialEdge] = []
        spatialEdges.reserveCapacity(nextDocument.edges.count)
        for edge in nextDocument.edges {
            guard let source = nextNodes[edge.fromNode], let target = nextNodes[edge.toNode] else { continue }
            let points = Self.edgePoints(edge, source: source, target: target)
            if let spatialEdge = try? PlanningSpatialEdge(
                id: edge.id,
                points: points.map { PlanningSpatialPoint(x: $0.x, y: $0.y) }
            ) {
                spatialEdges.append(spatialEdge)
            }
        }
        do {
            try nextIndex.rebuild(
                nodes: nextDocument.nodes.map { node in
                    PlanningSpatialNode(
                        id: node.id,
                        bounds: Self.planningSpatialRect(for: PlanningCanvasNodeGeometry.rect(for: node))
                    )
                },
                edges: spatialEdges
            )
        } catch {
            lastError = String(describing: error)
            status = .failed
            return
        }

        document = nextDocument
        cacheDocument = nextDocument
        cachedRevision = nextRevision
        nodesByID = nextNodes
        edgesByID = nextEdges
        nodeSourceOrdinals = nextNodeOrdinals
        edgeSourceOrdinals = nextEdgeOrdinals
        nodeBoundsByID = nextBounds
        incidentEdgeIDsByNodeID = nextIncident
        presentationIndex = nextIndex
        presentationQueryCache = nil
        presentationIndexRebuildCount += 1
        if let selectedNodeID, nodesByID[selectedNodeID] == nil {
            self.selectedNodeID = nil
        }
        status = status(for: session.state)
    }

    private func clearCache() {
        document = nil
        cacheDocument = nil
        cachedRevision = nil
        nodesByID.removeAll(keepingCapacity: false)
        edgesByID.removeAll(keepingCapacity: false)
        nodeSourceOrdinals.removeAll(keepingCapacity: false)
        edgeSourceOrdinals.removeAll(keepingCapacity: false)
        incidentEdgeIDsByNodeID.removeAll(keepingCapacity: false)
        nodeBoundsByID.removeAll(keepingCapacity: false)
        presentationIndex = PlanningSpatialIndex()
        presentationQueryCache = nil
        cancelNodeDrag()
    }

    private var hasPendingMutationForRetry: Bool {
        switch session.state {
        case .saving, .savedOnDevice, .publishing, .queued, .conflicted, .failed:
            return true
        case .idle, .loading, .ready, .published, .unavailable:
            return false
        }
    }

    private func recordOperationFailure(
        _ error: Error,
        forcePendingMutationRetry: Bool = false
    ) {
        lastError = String(describing: error)
        if case PlanningCanvasSessionError.staleGeneration = error {
            status = .unavailable
            retryMode = .none
            return
        }

        status = .failed
        retryMode = forcePendingMutationRetry || hasPendingMutationForRetry
            ? .pendingMutation
            : .none
    }

    private func apply(outcome: PlanningCanvasCommitOutcome?) {
        guard let outcome else {
            status = status(for: session.state)
            return
        }
        switch outcome.state {
        case .published:
            status = .published
            retryMode = .none
            lastError = nil
        case .queued:
            status = .queued
            retryMode = .pendingMutation
            lastError = outcome.publication?.errorCode
        case .conflicted:
            status = .conflicted
            retryMode = .pendingMutation
            lastError = outcome.publication?.errorCode
        case .blocked:
            status = .unavailable
            retryMode = .pendingMutation
            lastError = outcome.publication?.errorCode
        }
    }

    private func status(for state: PlanningCanvasSessionState) -> PlanningCanvasPresentationStatus {
        switch state {
        case .idle: return .idle
        case .loading: return .loading
        case .ready: return .ready
        case .saving: return .saving
        case .savedOnDevice: return .savedLocally
        case .publishing: return .publishing
        case .published: return .published
        case .queued: return .queued
        case .conflicted: return .conflicted
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }

    private func edgePresentation(
        edge: PlanningCanvasEdge,
        sourceIndex: Int,
        draggedNodeID: String?
    ) -> PlanningCanvasEdgePresentation? {
        guard let source = nodesByID[edge.fromNode], let target = nodesByID[edge.toNode] else { return nil }
        let points = Self.edgePoints(
            edge,
            source: source,
            target: target,
            draggedNodeID: draggedNodeID,
            dragPosition: transientDrag?.currentPosition
        )
        return PlanningCanvasEdgePresentation(
            edge: edge,
            sourceIndex: sourceIndex,
            points: points,
            isIncidentToDraggedNode: draggedNodeID.map { edge.fromNode == $0 || edge.toNode == $0 } ?? false
        )
    }

    private static func edgePoints(
        _ edge: PlanningCanvasEdge,
        source: PlanningCanvasNode,
        target: PlanningCanvasNode,
        draggedNodeID: String? = nil,
        dragPosition: CGPoint? = nil
    ) -> [CGPoint] {
        let sourceRect = CGRect(
            x: draggedNodeID == source.id ? (dragPosition?.x ?? CGFloat(source.x)) : CGFloat(source.x),
            y: draggedNodeID == source.id ? (dragPosition?.y ?? CGFloat(source.y)) : CGFloat(source.y),
            width: PlanningCanvasNodeGeometry.effectiveSize(for: source).width,
            height: PlanningCanvasNodeGeometry.effectiveSize(for: source).height
        )
        let targetRect = CGRect(
            x: draggedNodeID == target.id ? (dragPosition?.x ?? CGFloat(target.x)) : CGFloat(target.x),
            y: draggedNodeID == target.id ? (dragPosition?.y ?? CGFloat(target.y)) : CGFloat(target.y),
            width: PlanningCanvasNodeGeometry.effectiveSize(for: target).width,
            height: PlanningCanvasNodeGeometry.effectiveSize(for: target).height
        )
        let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        return [
            sidePoint(named: edge.fromSide, on: sourceRect, toward: targetCenter),
            sidePoint(named: edge.toSide, on: targetRect, toward: sourceCenter)
        ]
    }

    private static func sidePoint(named side: String?, on rect: CGRect, toward point: CGPoint) -> CGPoint {
        switch side {
        case "top": return CGPoint(x: rect.midX, y: rect.minY)
        case "right": return CGPoint(x: rect.maxX, y: rect.midY)
        case "bottom": return CGPoint(x: rect.midX, y: rect.maxY)
        case "left": return CGPoint(x: rect.minX, y: rect.midY)
        default: break
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let horizontalFactor = abs(dx) > 0 ? rect.width / 2 / abs(dx) : .infinity
        let verticalFactor = abs(dy) > 0 ? rect.height / 2 / abs(dy) : .infinity
        let factor = min(horizontalFactor, verticalFactor)
        guard factor.isFinite else { return center }
        let point = CGPoint(x: center.x + dx * factor, y: center.y + dy * factor)
        return CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private static func planningSpatialRect(for rect: CGRect) -> PlanningSpatialRect {
        PlanningSpatialRect(
            minX: rect.minX,
            minY: rect.minY,
            maxX: rect.maxX,
            maxY: rect.maxY
        )
    }

    private func planningRect(_ rect: CGRect) -> PlanningSpatialRect? {
        guard Self.isFinite(rect), !rect.isNull, rect.width >= 0, rect.height >= 0 else { return nil }
        return PlanningSpatialRect(
            minX: rect.minX,
            minY: rect.minY,
            maxX: rect.maxX,
            maxY: rect.maxY
        )
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFinite(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
