import Foundation

public struct PlanningCanvasPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else { throw PlanningCanvasEditError.invalidValue("point") }
        self.x = x
        self.y = y
    }
}

public struct PlanningCanvasSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw PlanningCanvasEditError.invalidValue("size")
        }
        self.width = width
        self.height = height
    }
}

public struct PlanningIndexedCanvasEdge: Codable, Equatable, Sendable {
    public let edge: PlanningCanvasEdge
    public let index: Int

    public init(edge: PlanningCanvasEdge, index: Int) throws {
        guard index >= 0 else { throw PlanningCanvasEditError.invalidValue("edge.index") }
        self.edge = edge
        self.index = index
    }
}

public enum PlanningCanvasEditError: Error, Equatable, LocalizedError, Sendable {
    case invalidValue(String)
    case staleObject(String)
    case lockedNode(String)
    case unsupported(String)
    case invalidMarkdown

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let field): return "Invalid Canvas edit value: " + field + "."
        case .staleObject(let id): return "The Canvas object is no longer at the expected revision: " + id + "."
        case .lockedNode(let id): return "The Canvas node is locked: " + id + "."
        case .unsupported(let operation): return "The Canvas edit is unsupported: " + operation + "."
        case .invalidMarkdown: return "The Markdown edit is invalid."
        }
    }
}

public enum PlanningCanvasEdit: Equatable, Sendable {
    case moveNode(id: String, from: PlanningCanvasPoint, to: PlanningCanvasPoint)
    case resizeNode(id: String, from: PlanningCanvasSize, to: PlanningCanvasSize)
    case insertNode(node: PlanningCanvasNode, index: Int)
    case deleteNode(node: PlanningCanvasNode, index: Int, incidentEdges: [PlanningIndexedCanvasEdge])
    /// Internal inverse for a node deletion. Keeping the incident edge list in
    /// one command makes delete and undo atomic from the user's perspective.
    case restoreNode(node: PlanningCanvasNode, index: Int, incidentEdges: [PlanningIndexedCanvasEdge])
    case insertEdge(edge: PlanningCanvasEdge, index: Int)
    case deleteEdge(edge: PlanningCanvasEdge, index: Int)
    case reconnectEdge(before: PlanningCanvasEdge, after: PlanningCanvasEdge)
    case setNodeLabel(id: String, from: String?, to: String?)
    case setNodeColor(id: String, from: String?, to: String?)
    case replaceMarkdownSource(from: String, to: String)

    public var inverse: PlanningCanvasEdit {
        switch self {
        case .moveNode(let id, let from, let to):
            return .moveNode(id: id, from: to, to: from)
        case .resizeNode(let id, let from, let to):
            return .resizeNode(id: id, from: to, to: from)
        case .insertNode(let node, let index):
            return .deleteNode(node: node, index: index, incidentEdges: [])
        case .deleteNode(let node, let index, let incidentEdges):
            return .restoreNode(node: node, index: index, incidentEdges: incidentEdges)
        case .restoreNode(let node, let index, let incidentEdges):
            return .deleteNode(node: node, index: index, incidentEdges: incidentEdges)
        case .insertEdge(let edge, let index):
            return .deleteEdge(edge: edge, index: index)
        case .deleteEdge(let edge, let index):
            return .insertEdge(edge: edge, index: index)
        case .reconnectEdge(let before, let after):
            return .reconnectEdge(before: after, after: before)
        case .setNodeLabel(let id, let from, let to):
            return .setNodeLabel(id: id, from: to, to: from)
        case .setNodeColor(let id, let from, let to):
            return .setNodeColor(id: id, from: to, to: from)
        case .replaceMarkdownSource(let from, let to):
            return .replaceMarkdownSource(from: to, to: from)
        }
    }

    /// A conservative accounting size for the bounded undo history. Unknown
    /// JSON values are encoded for the estimate, so a large extension cannot
    /// be admitted as a deceptively small command.
    public var estimatedByteCount: Int {
        switch self {
        case .moveNode: return 128
        case .resizeNode: return 128
        case .insertNode(let node, _):
            return nodeMemory(node) + 128
        case .deleteNode(let node, _, let incidentEdges), .restoreNode(let node, _, let incidentEdges):
            return nodeMemory(node) + incidentEdges.reduce(128) { total, indexedEdge in
                total + edgeMemory(indexedEdge.edge)
            }
        case .insertEdge(let edge, _), .deleteEdge(let edge, _):
            return edgeMemory(edge) + 128
        case .reconnectEdge(let before, let after):
            return edgeMemory(before) + edgeMemory(after) + 128
        case .setNodeLabel(_, let from, let to):
            return stringMemory(from) + stringMemory(to) + 128
        case .setNodeColor(_, let from, let to):
            return stringMemory(from) + stringMemory(to) + 128
        case .replaceMarkdownSource(let from, let to):
            return from.utf8.count + to.utf8.count + 128
        }
    }

    private func nodeMemory(_ node: PlanningCanvasNode) -> Int {
        var value = node.id.utf8.count + (node.text?.utf8.count ?? 0)
            + (node.file?.utf8.count ?? 0) + (node.url?.utf8.count ?? 0)
            + (node.label?.utf8.count ?? 0) + (node.background?.utf8.count ?? 0)
            + (node.backgroundStyle?.utf8.count ?? 0) + (node.borderStyle?.utf8.count ?? 0)
        for (key, raw) in node.unknownFields.merging(node.extensionFields, uniquingKeysWith: { first, _ in first }) {
            value += key.utf8.count + ((try? JSONEncoder().encode(raw).count) ?? 0)
        }
        return value
    }

    private func edgeMemory(_ edge: PlanningCanvasEdge) -> Int {
        var value = edge.id.utf8.count + edge.fromNode.utf8.count + edge.toNode.utf8.count
            + (edge.fromSide?.utf8.count ?? 0) + (edge.toSide?.utf8.count ?? 0)
            + (edge.fromEnd?.utf8.count ?? 0) + (edge.toEnd?.utf8.count ?? 0)
            + (edge.color?.utf8.count ?? 0) + (edge.label?.utf8.count ?? 0)
        for (key, raw) in edge.unknownFields {
            value += key.utf8.count + ((try? JSONEncoder().encode(raw).count) ?? 0)
        }
        return value
    }

    private func stringMemory(_ value: String?) -> Int { value?.utf8.count ?? 0 }
}

public struct PlanningCanvasEditState: Equatable, Sendable {
    public let document: PlanningCanvasDocument
    public let markdownPath: PlanningRelativePath?
    public let markdownSource: String?

    public init(
        document: PlanningCanvasDocument,
        markdownPath: PlanningRelativePath? = nil,
        markdownSource: String? = nil
    ) throws {
        guard (markdownPath == nil) == (markdownSource == nil) else {
            throw PlanningCanvasEditError.invalidValue("markdown.state")
        }
        self.document = document
        self.markdownPath = markdownPath
        self.markdownSource = markdownSource
    }
}

public struct PlanningCanvasEditApplication: Equatable, Sendable {
    public let state: PlanningCanvasEditState
    public let inverse: PlanningCanvasEdit

    public init(state: PlanningCanvasEditState, inverse: PlanningCanvasEdit) {
        self.state = state
        self.inverse = inverse
    }
}

public enum PlanningCanvasReducer {
    public static func apply(
        _ edit: PlanningCanvasEdit,
        to state: PlanningCanvasEditState
    ) throws -> PlanningCanvasEditApplication {
        switch edit {
        case .replaceMarkdownSource(let from, let to):
            guard state.markdownSource == from,
                  let path = state.markdownPath,
                  (try? PlanningMarkdownCodec.decode(relativePath: path.value, source: to)) != nil else {
                throw PlanningCanvasEditError.invalidMarkdown
            }
            let next = try PlanningCanvasEditState(
                document: state.document,
                markdownPath: path,
                markdownSource: to
            )
            return PlanningCanvasEditApplication(state: next, inverse: edit.inverse)
        default:
            let document = try apply(edit, to: state.document)
            let next = try PlanningCanvasEditState(
                document: document,
                markdownPath: state.markdownPath,
                markdownSource: state.markdownSource
            )
            return PlanningCanvasEditApplication(state: next, inverse: edit.inverse)
        }
    }

    public static func apply(
        _ edit: PlanningCanvasEdit,
        to document: PlanningCanvasDocument
    ) throws -> PlanningCanvasDocument {
        var nodes = document.nodes
        var edges = document.edges

        switch edit {
        case .moveNode(let id, let from, let to):
            guard let index = nodes.firstIndex(where: { $0.id == id }) else {
                throw PlanningCanvasEditError.staleObject(id)
            }
            let node = nodes[index]
            guard node.x == from.x, node.y == from.y else {
                throw PlanningCanvasEditError.staleObject(id)
            }
            guard node.locked != true else { throw PlanningCanvasEditError.lockedNode(id) }
            nodes[index] = try makeNode(
                node,
                x: to.x,
                y: to.y,
                width: node.width,
                height: node.height
            )
        case .resizeNode(let id, let from, let to):
            guard let index = nodes.firstIndex(where: { $0.id == id }) else {
                throw PlanningCanvasEditError.staleObject(id)
            }
            let node = nodes[index]
            guard node.width == from.width, node.height == from.height else {
                throw PlanningCanvasEditError.staleObject(id)
            }
            guard node.locked != true else { throw PlanningCanvasEditError.lockedNode(id) }
            nodes[index] = try makeNode(
                node,
                x: node.x,
                y: node.y,
                width: to.width,
                height: to.height
            )
        case .insertNode(let node, let index):
            guard index >= 0, index <= nodes.count else {
                throw PlanningCanvasEditError.invalidValue("node.index")
            }
            guard !nodes.contains(where: { $0.id == node.id }),
                  !edges.contains(where: { $0.id == node.id }) else {
                throw PlanningCanvasEditError.invalidValue("node.id")
            }
            nodes.insert(node, at: index)
        case .deleteNode(let node, let index, let incidentEdges):
            try removeNode(
                node,
                index: index,
                incidentEdges: incidentEdges,
                nodes: &nodes,
                edges: &edges
            )
        case .restoreNode(let node, let index, let incidentEdges):
            guard index >= 0, index <= nodes.count,
                  !nodes.contains(where: { $0.id == node.id }) else {
                throw PlanningCanvasEditError.staleObject(node.id)
            }
            let restoredEdgeCount = edges.count + incidentEdges.count
            var indexedByIndex: [Int: PlanningCanvasEdge] = [:]
            indexedByIndex.reserveCapacity(incidentEdges.count)
            var incidentIDs = Set<String>()
            incidentIDs.reserveCapacity(incidentEdges.count)
            let existingIDs = Set(edges.map(\.id))
            for indexed in incidentEdges {
                guard indexed.index >= 0, indexed.index < restoredEdgeCount,
                      indexed.edge.fromNode == node.id || indexed.edge.toNode == node.id,
                      incidentIDs.insert(indexed.edge.id).inserted,
                      indexedByIndex[indexed.index] == nil,
                      !existingIDs.contains(indexed.edge.id) else {
                    throw PlanningCanvasEditError.invalidValue("edge.restore")
                }
                indexedByIndex[indexed.index] = indexed.edge
            }
            var restored: [PlanningCanvasEdge] = []
            restored.reserveCapacity(restoredEdgeCount)
            var existingOffset = 0
            for originalIndex in 0..<restoredEdgeCount {
                if let edge = indexedByIndex[originalIndex] {
                    restored.append(edge)
                } else {
                    guard existingOffset < edges.count else {
                        throw PlanningCanvasEditError.invalidValue("edge.restore")
                    }
                    restored.append(edges[existingOffset])
                    existingOffset += 1
                }
            }
            guard existingOffset == edges.count else {
                throw PlanningCanvasEditError.invalidValue("edge.restore")
            }
            nodes.insert(node, at: index)
            edges = restored
        case .insertEdge(let edge, let index):
            guard index >= 0, index <= edges.count,
                  nodes.contains(where: { $0.id == edge.fromNode }),
                  nodes.contains(where: { $0.id == edge.toNode }),
                  !nodes.contains(where: { $0.id == edge.id }),
                  !edges.contains(where: { $0.id == edge.id }) else {
                throw PlanningCanvasEditError.invalidValue("edge.insert")
            }
            edges.insert(edge, at: index)
        case .deleteEdge(let edge, let index):
            guard edges.indices.contains(index), edges[index] == edge else {
                throw PlanningCanvasEditError.staleObject(edge.id)
            }
            edges.remove(at: index)
        case .reconnectEdge(let before, let after):
            guard before.id == after.id,
                  let index = edges.firstIndex(where: { $0.id == before.id }),
                  edges[index] == before else {
                throw PlanningCanvasEditError.staleObject(before.id)
            }
            edges[index] = after
        case .setNodeLabel(let id, let from, let to):
            guard let index = nodes.firstIndex(where: { $0.id == id }) else {
                throw PlanningCanvasEditError.staleObject(id)
            }
            guard nodes[index].label == from else { throw PlanningCanvasEditError.staleObject(id) }
            nodes[index] = try makeNode(nodes[index], labelOverride: .some(to))
        case .setNodeColor(let id, let from, let to):
            guard let index = nodes.firstIndex(where: { $0.id == id }) else {
                throw PlanningCanvasEditError.staleObject(id)
            }
            guard nodes[index].color == from else { throw PlanningCanvasEditError.staleObject(id) }
            nodes[index] = try makeNode(nodes[index], colorOverride: .some(to))
        case .replaceMarkdownSource:
            throw PlanningCanvasEditError.unsupported("markdown edit requires PlanningCanvasEditState")
        }

        return try PlanningCanvasDocument(
            nodes: nodes,
            edges: edges,
            unknownFields: document.unknownFields
        )
    }

    private static func removeNode(
        _ node: PlanningCanvasNode,
        index: Int,
        incidentEdges: [PlanningIndexedCanvasEdge],
        nodes: inout [PlanningCanvasNode],
        edges: inout [PlanningCanvasEdge]
    ) throws {
        guard nodes.indices.contains(index), nodes[index] == node else {
            throw PlanningCanvasEditError.staleObject(node.id)
        }
        let expected = edges.enumerated().filter {
            $0.element.fromNode == node.id || $0.element.toNode == node.id
        }.map { $0.offset }
        let providedIndices = incidentEdges.map(\.index)
        guard Set(providedIndices).count == providedIndices.count,
              Set(providedIndices) == Set(expected),
              incidentEdges.count == expected.count else {
            throw PlanningCanvasEditError.staleObject(node.id)
        }
        var incidentIDs = Set<String>()
        incidentIDs.reserveCapacity(incidentEdges.count)
        for indexed in incidentEdges {
            guard edges.indices.contains(indexed.index),
                  edges[indexed.index] == indexed.edge,
                  incidentIDs.insert(indexed.edge.id).inserted else {
                throw PlanningCanvasEditError.staleObject(indexed.edge.id)
            }
        }
        edges = edges.filter { !incidentIDs.contains($0.id) }
        nodes.remove(at: index)
    }

    private static func makeNode(
        _ node: PlanningCanvasNode,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        colorOverride: String?? = nil,
        labelOverride: String?? = nil
    ) throws -> PlanningCanvasNode {
        try PlanningCanvasNode(
            id: node.id,
            type: node.type,
            x: x ?? node.x,
            y: y ?? node.y,
            width: width ?? node.width,
            height: height ?? node.height,
            color: colorOverride ?? node.color,
            text: node.text,
            file: node.file,
            subpath: node.subpath,
            url: node.url,
            label: labelOverride ?? node.label,
            locked: node.locked,
            background: node.background,
            backgroundStyle: node.backgroundStyle,
            borderWidth: node.borderWidth,
            borderStyle: node.borderStyle,
            unknownFields: node.unknownFields,
            extensionFields: node.extensionFields
        )
    }
}
