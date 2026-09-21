import Foundation

public struct PlanningSpatialPoint: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct PlanningSpatialRect: Codable, Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static let empty = PlanningSpatialRect(
        minX: .infinity,
        minY: .infinity,
        maxX: -.infinity,
        maxY: -.infinity
    )

    public var isFinite: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
    }

    public var isEmpty: Bool { minX > maxX || minY > maxY }

    public var width: Double { isEmpty ? 0 : maxX - minX }
    public var height: Double { isEmpty ? 0 : maxY - minY }

    public var center: PlanningSpatialPoint {
        PlanningSpatialPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    public func contains(_ point: PlanningSpatialPoint) -> Bool {
        !isEmpty && point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersects(_ other: PlanningSpatialRect) -> Bool {
        !isEmpty && !other.isEmpty
            && minX <= other.maxX && maxX >= other.minX
            && minY <= other.maxY && maxY >= other.minY
    }

    public func expanded(by amount: Double) -> PlanningSpatialRect {
        guard amount.isFinite, !isEmpty else { return self }
        let distance = max(0, amount)
        return PlanningSpatialRect(
            minX: minX - distance,
            minY: minY - distance,
            maxX: maxX + distance,
            maxY: maxY + distance
        )
    }

    public func union(_ other: PlanningSpatialRect) -> PlanningSpatialRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return PlanningSpatialRect(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY)
        )
    }
}

public struct PlanningSpatialNode: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let bounds: PlanningSpatialRect

    public init(id: String, bounds: PlanningSpatialRect) {
        self.id = id
        self.bounds = bounds
    }
}

public struct PlanningSpatialEdge: Codable, Equatable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id
        case points
        case bounds
    }

    public let id: String
    public let points: [PlanningSpatialPoint]
    public let bounds: PlanningSpatialRect

    public init(id: String, points: [PlanningSpatialPoint]) throws {
        guard points.count >= 2, points.allSatisfy(\.isFinite) else {
            throw PlanningGraphError.invalidInput("spatial.edge.points")
        }
        var bounds = PlanningSpatialRect.empty
        for point in points {
            bounds = bounds.union(PlanningSpatialRect(
                minX: point.x,
                minY: point.y,
                maxX: point.x,
                maxY: point.y
            ))
        }
        self.id = id
        self.points = points
        self.bounds = bounds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let points = try container.decode([PlanningSpatialPoint].self, forKey: .points)
        let encodedBounds = try container.decode(PlanningSpatialRect.self, forKey: .bounds)
        try self.init(id: id, points: points)
        guard bounds == encodedBounds else {
            throw PlanningSpatialIndexError.invalidGeometry("edge.bounds")
        }
    }
}

public enum PlanningSpatialIndexError: Error, Equatable, LocalizedError, Sendable {
    case capacityExceeded(String)
    case invalidGeometry(String)
    case duplicateID(String)

    public var errorDescription: String? {
        switch self {
        case .capacityExceeded(let field): return "The spatial index exceeds its bounded capacity: " + field + "."
        case .invalidGeometry(let field): return "The spatial index received invalid geometry: " + field + "."
        case .duplicateID(let field): return "The spatial index contains a duplicate identifier: " + field + "."
        }
    }
}

public struct PlanningSpatialIndexMetrics: Codable, Equatable, Sendable {
    public let visitedNodes: Int
    public let candidateCount: Int
    public let resultCount: Int
    public let rebuiltElementCount: Int
    public let rebuildPasses: Int

    public init(
        visitedNodes: Int = 0,
        candidateCount: Int = 0,
        resultCount: Int = 0,
        rebuiltElementCount: Int = 0,
        rebuildPasses: Int = 0
    ) {
        self.visitedNodes = visitedNodes
        self.candidateCount = candidateCount
        self.resultCount = resultCount
        self.rebuiltElementCount = rebuiltElementCount
        self.rebuildPasses = rebuildPasses
    }
}

public enum PlanningSpatialHitKind: String, Codable, Equatable, Sendable {
    case node
    case edge
}

public struct PlanningSpatialHit: Codable, Equatable, Sendable {
    public let id: String
    public let kind: PlanningSpatialHitKind
    public let distance: Double

    public init(id: String, kind: PlanningSpatialHitKind, distance: Double) {
        self.id = id
        self.kind = kind
        self.distance = distance
    }
}

/// A packed broad-phase BVH built from fixed-width Morton keys. The radix
/// passes and bottom-up tree construction are O(V+E); queries are
/// O(log(V)+k) for well-separated geometry. With pathological overlapping or
/// very large rectangles the conservative BVH can visit O(V) nodes. The
/// counters expose that actual behavior instead of hiding candidates in k.
public struct PlanningSpatialIndex: Sendable {
    public static let maximumNodes = 10_000
    public static let maximumEdges = 40_000

    private struct Entry: Sendable {
        let id: String
        let bounds: PlanningSpatialRect
        let ordinal: Int
        let mortonKey: UInt32
    }

    private struct BVHNode: Sendable {
        let bounds: PlanningSpatialRect
        let left: Int
        let right: Int
        let start: Int
        let count: Int

        var isLeaf: Bool { left < 0 && right < 0 }
    }

    private struct Tree: Sendable {
        let entries: [Entry]
        let nodes: [BVHNode]
        let root: Int?
    }

    private var nodeTree = Tree(entries: [], nodes: [], root: nil)
    private var edgeTree = Tree(entries: [], nodes: [], root: nil)
    private var nodeBounds: [String: PlanningSpatialRect] = [:]
    private var edgeGeometry: [String: PlanningSpatialEdge] = [:]
    public private(set) var metrics = PlanningSpatialIndexMetrics()

    public init() {}

    public mutating func rebuild(
        nodes: [PlanningSpatialNode],
        edges: [PlanningSpatialEdge]
    ) throws {
        guard nodes.count <= Self.maximumNodes else { throw PlanningSpatialIndexError.capacityExceeded("nodes") }
        guard edges.count <= Self.maximumEdges else { throw PlanningSpatialIndexError.capacityExceeded("edges") }
        guard Set(nodes.map(\.id)).count == nodes.count else {
            throw PlanningSpatialIndexError.duplicateID("nodes")
        }
        guard Set(edges.map(\.id)).count == edges.count else {
            throw PlanningSpatialIndexError.duplicateID("edges")
        }
        guard nodes.allSatisfy({ !$0.id.isEmpty }) else {
            throw PlanningSpatialIndexError.invalidGeometry("nodes.id")
        }
        guard edges.allSatisfy({ !$0.id.isEmpty }) else {
            throw PlanningSpatialIndexError.invalidGeometry("edges.id")
        }
        guard edges.allSatisfy({ edge in
            guard let validated = try? PlanningSpatialEdge(id: edge.id, points: edge.points) else {
                return false
            }
            return validated.bounds == edge.bounds
        }) else {
            throw PlanningSpatialIndexError.invalidGeometry("edges.points")
        }
        guard nodes.allSatisfy({ $0.bounds.isFinite && !$0.bounds.isEmpty }) else {
            throw PlanningSpatialIndexError.invalidGeometry("nodes")
        }
        guard edges.allSatisfy({ $0.bounds.isFinite && !$0.bounds.isEmpty }) else {
            throw PlanningSpatialIndexError.invalidGeometry("edges")
        }

        let newNodeTree = makeTree(entries: makeEntries(nodes.map {
            ($0.id, $0.bounds)
        }))
        let newEdgeTree = makeTree(entries: makeEntries(edges.map {
            ($0.id, $0.bounds)
        }))
        var geometry: [String: PlanningSpatialEdge] = [:]
        geometry.reserveCapacity(edges.count)
        for edge in edges { geometry[edge.id] = edge }
        var bounds: [String: PlanningSpatialRect] = [:]
        bounds.reserveCapacity(nodes.count)
        for node in nodes { bounds[node.id] = node.bounds }

        nodeTree = newNodeTree
        edgeTree = newEdgeTree
        nodeBounds = bounds
        edgeGeometry = geometry
        metrics = PlanningSpatialIndexMetrics(
            rebuiltElementCount: nodes.count + edges.count,
            rebuildPasses: nodes.isEmpty && edges.isEmpty ? 0 : 8
        )
    }

    public mutating func queryNodes(in rectangle: PlanningSpatialRect) -> [String] {
        query(tree: nodeTree, rectangle: rectangle)
    }

    public mutating func queryEdges(in rectangle: PlanningSpatialRect) -> [String] {
        query(tree: edgeTree, rectangle: rectangle)
    }

    /// Returns exact node containment and exact point-to-polyline edge hits
    /// after the BVH broad phase. Edge bounds alone are never presented as an
    /// exact hit.
    public mutating func hitTest(
        _ point: PlanningSpatialPoint,
        tolerance: Double = 0
    ) -> [PlanningSpatialHit] {
        guard point.isFinite, tolerance.isFinite, tolerance >= 0 else { return [] }
        let queryRect = PlanningSpatialRect(
            minX: point.x - tolerance,
            minY: point.y - tolerance,
            maxX: point.x + tolerance,
            maxY: point.y + tolerance
        )
        let nodeIDs = queryNodes(in: queryRect)
        let edgeIDs = queryEdges(in: queryRect)
        var hits: [PlanningSpatialHit] = []
        for id in nodeIDs {
            guard let bounds = nodeBounds[id] else { continue }
            let distance = distance(from: point, to: bounds)
            if distance <= tolerance { hits.append(PlanningSpatialHit(id: id, kind: .node, distance: distance)) }
        }
        for id in edgeIDs {
            guard let edge = edgeGeometry[id] else { continue }
            let distance = polylineDistance(point: point, points: edge.points)
            if distance <= tolerance {
                hits.append(PlanningSpatialHit(id: id, kind: .edge, distance: distance))
            }
        }
        hits.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.kind != $1.kind { return $0.kind == .node }
            return $0.id < $1.id
        }
        return hits
    }

    public mutating func resetMetrics() {
        metrics = PlanningSpatialIndexMetrics(
            rebuiltElementCount: nodeTree.entries.count + edgeTree.entries.count,
            rebuildPasses: nodeTree.entries.isEmpty && edgeTree.entries.isEmpty ? 0 : 8
        )
    }

    private mutating func query(
        tree: Tree,
        rectangle: PlanningSpatialRect
    ) -> [String] {
        guard !rectangle.isEmpty, rectangle.isFinite, let root = tree.root else { return [] }
        var stack = [root]
        var results: [String] = []
        while let index = stack.popLast() {
            guard tree.nodes.indices.contains(index) else { continue }
            let node = tree.nodes[index]
            metrics = PlanningSpatialIndexMetrics(
                visitedNodes: metrics.visitedNodes + 1,
                candidateCount: metrics.candidateCount,
                resultCount: metrics.resultCount,
                rebuiltElementCount: metrics.rebuiltElementCount,
                rebuildPasses: metrics.rebuildPasses
            )
            guard node.bounds.intersects(rectangle) else { continue }
            if node.isLeaf {
                let end = node.start + node.count
                guard node.start >= 0, end <= tree.entries.count else { continue }
                for entry in tree.entries[node.start..<end] {
                    metrics = PlanningSpatialIndexMetrics(
                        visitedNodes: metrics.visitedNodes,
                        candidateCount: metrics.candidateCount + 1,
                        resultCount: metrics.resultCount,
                        rebuiltElementCount: metrics.rebuiltElementCount,
                        rebuildPasses: metrics.rebuildPasses
                    )
                    if entry.bounds.intersects(rectangle) { results.append(entry.id) }
                }
            } else {
                if node.left >= 0 { stack.append(node.left) }
                if node.right >= 0 { stack.append(node.right) }
            }
        }
        metrics = PlanningSpatialIndexMetrics(
            visitedNodes: metrics.visitedNodes,
            candidateCount: metrics.candidateCount,
            resultCount: metrics.resultCount + results.count,
            rebuiltElementCount: metrics.rebuiltElementCount,
            rebuildPasses: metrics.rebuildPasses
        )
        return results
    }

    private func makeEntries(_ values: [(String, PlanningSpatialRect)]) -> [Entry] {
        guard !values.isEmpty else { return [] }
        var envelope = PlanningSpatialRect.empty
        for (_, bounds) in values { envelope = envelope.union(bounds) }
        return values.enumerated().map { ordinal, value in
            Entry(
                id: value.0,
                bounds: value.1,
                ordinal: ordinal,
                mortonKey: mortonKey(for: value.1.center, in: envelope)
            )
        }
    }

    private func makeTree(entries: [Entry]) -> Tree {
        guard !entries.isEmpty else { return Tree(entries: [], nodes: [], root: nil) }
        let sorted = radixSort(entries)
        var nodes: [BVHNode] = []
        nodes.reserveCapacity(sorted.count * 2)

        func build(start: Int, end: Int) -> Int {
            let count = end - start
            if count <= 8 {
                var bounds = PlanningSpatialRect.empty
                for entry in sorted[start..<end] { bounds = bounds.union(entry.bounds) }
                let index = nodes.count
                nodes.append(BVHNode(bounds: bounds, left: -1, right: -1, start: start, count: count))
                return index
            }
            let middle = start + count / 2
            let left = build(start: start, end: middle)
            let right = build(start: middle, end: end)
            let index = nodes.count
            nodes.append(BVHNode(
                bounds: nodes[left].bounds.union(nodes[right].bounds),
                left: left,
                right: right,
                start: -1,
                count: 0
            ))
            return index
        }

        let root = build(start: 0, end: sorted.count)
        return Tree(entries: sorted, nodes: nodes, root: root)
    }

    private func radixSort(_ input: [Entry]) -> [Entry] {
        var current = input
        var output = input
        for shift in stride(from: 0, through: 24, by: 8) {
            var counts = [Int](repeating: 0, count: 256)
            for entry in current { counts[Int((entry.mortonKey >> UInt32(shift)) & 0xFF)] += 1 }
            var offsets = [Int](repeating: 0, count: 256)
            var running = 0
            for index in counts.indices {
                offsets[index] = running
                running += counts[index]
            }
            for entry in current {
                let bucket = Int((entry.mortonKey >> UInt32(shift)) & 0xFF)
                output[offsets[bucket]] = entry
                offsets[bucket] += 1
            }
            swap(&current, &output)
        }
        return current
    }

    private func mortonKey(for point: PlanningSpatialPoint, in envelope: PlanningSpatialRect) -> UInt32 {
        let x = quantise(point.x, lower: envelope.minX, upper: envelope.maxX)
        let y = quantise(point.y, lower: envelope.minY, upper: envelope.maxY)
        return interleave(x) | (interleave(y) << 1)
    }

    private func quantise(_ value: Double, lower: Double, upper: Double) -> UInt32 {
        guard upper > lower, value.isFinite else { return 0 }
        let ratio = min(1, max(0, (value - lower) / (upper - lower)))
        return UInt32((ratio * 65_535).rounded())
    }

    private func interleave(_ value: UInt32) -> UInt32 {
        var result: UInt32 = 0
        for bit in 0..<16 { result |= ((value >> UInt32(bit)) & 1) << UInt32(bit * 2) }
        return result
    }

    private func distance(from point: PlanningSpatialPoint, to rectangle: PlanningSpatialRect) -> Double {
        let dx = max(max(rectangle.minX - point.x, 0), point.x - rectangle.maxX)
        let dy = max(max(rectangle.minY - point.y, 0), point.y - rectangle.maxY)
        return hypot(dx, dy)
    }

    private func polylineDistance(point: PlanningSpatialPoint, points: [PlanningSpatialPoint]) -> Double {
        var best = Double.infinity
        for index in 1..<points.count {
            best = min(best, segmentDistance(point, points[index - 1], points[index]))
        }
        return best
    }

    private func segmentDistance(
        _ point: PlanningSpatialPoint,
        _ first: PlanningSpatialPoint,
        _ second: PlanningSpatialPoint
    ) -> Double {
        let dx = second.x - first.x
        let dy = second.y - first.y
        let denominator = dx * dx + dy * dy
        if denominator == 0 { return hypot(point.x - first.x, point.y - first.y) }
        let projection = ((point.x - first.x) * dx + (point.y - first.y) * dy) / denominator
        let t = min(1, max(0, projection))
        let closest = PlanningSpatialPoint(x: first.x + t * dx, y: first.y + t * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}
