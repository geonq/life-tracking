import XCTest
@testable import LifeOS

final class PlanningGraphTests: XCTestCase {
    func testScannerAndReferenceResolutionAreBoundedAndExplicit() throws {
        let source = "# Plan\n[[Notes/Today.md#Morning|Today]] [web](https://example.com) `[[ignored]]`"
        let scan = PlanningMarkdownLinkScanner.scan(source: source)
        XCTAssertEqual(scan.occurrences.count, 2)
        XCTAssertEqual(scan.occurrences.first?.anchor, "Morning")
        XCTAssertEqual(scan.occurrences.last?.rawTarget, "https://example.com")

        let sourcePath = try PlanningRelativePath("Boards/Plan.canvas")
        let catalogue = try PlanningReferenceCatalogue(paths: ["Notes/Today.md"], isComplete: true)
        XCTAssertEqual(
            PlanningReferenceResolver.resolve("Notes/Today", from: sourcePath, catalogue: catalogue).path?.value,
            "Notes/Today.md"
        )
        if case .outsideBoundary = PlanningReferenceResolver.resolve("../secret.md", from: sourcePath, catalogue: catalogue) {
        } else {
            XCTFail("Expected outside-boundary status")
        }
    }

    func testProjectionKeepsRepeatedInstancesAndAuthoredEdgesSeparateFromMarkdownLinks() throws {
        let first = try PlanningCanvasNode(
            id: "a",
            type: .file,
            x: 0,
            y: 0,
            width: 100,
            height: 60,
            file: "Notes/Today.md"
        )
        let second = try PlanningCanvasNode(
            id: "b",
            type: .file,
            x: 200,
            y: 0,
            width: 100,
            height: 60,
            file: "Notes/Today.md"
        )
        let edge = try PlanningCanvasEdge(id: "edge", fromNode: "a", toNode: "b")
        let document = try PlanningCanvasDocument(nodes: [first, second], edges: [edge])
        let path = try PlanningStoredPath("Boards/Plan.canvas")
        let input = try PlanningProjectInput(
            canvasPath: path,
            canvasDocument: document,
            canvasBytes: try PlanningCanvasCodec.encode(document),
            noteSnapshots: [try PlanningGraphNoteSnapshot(path: "Notes/Today.md", source: "# Today\n[[Notes/Other.md]]")],
            vaultID: UUID(),
            accessGeneration: UUID()
        )
        let graph = try PlanningGraphProjector.project(input)
        XCTAssertEqual(graph.canvasInstances.count, 2)
        XCTAssertEqual(graph.authoredEdges.count, 1)
        XCTAssertEqual(graph.derivedLinks.count, 1)
        XCTAssertEqual(graph.canvasInstances[0].reference?.path?.value, "Notes/Today.md")
        XCTAssertEqual(graph.canvasInstances[1].reference?.path?.value, "Notes/Today.md")
    }

    func testReducerPreservesUnknownValuesAndSpatialQueriesMatchBruteForce() throws {
        let node = try PlanningCanvasNode(
            id: "node",
            type: .text,
            x: -10,
            y: -20,
            width: 10,
            height: 10,
            text: "text",
            unknownFields: ["future": .number("18446744073709551615")],
            extensionFields: ["borderWidth": .number("1.2300")]
        )
        let document = try PlanningCanvasDocument(nodes: [node], edges: [])
        let moved = try PlanningCanvasReducer.apply(
            .moveNode(
                id: "node",
                from: try PlanningCanvasPoint(x: -10, y: -20),
                to: try PlanningCanvasPoint(x: 50, y: 60)
            ),
            to: document
        )
        XCTAssertEqual(moved.nodes.first?.unknownFields, node.unknownFields)
        XCTAssertTrue(String(decoding: try PlanningCanvasCodec.encode(moved), as: UTF8.self).contains("1.2300"))

        let spatialNodes = (0..<100).map { index in
            PlanningSpatialNode(
                id: String(index),
                bounds: PlanningSpatialRect(
                    minX: Double(index),
                    minY: -Double(index),
                    maxX: Double(index) + 1,
                    maxY: -Double(index) + 1
                )
            )
        }
        var index = PlanningSpatialIndex()
        try index.rebuild(nodes: spatialNodes, edges: [])
        let query = PlanningSpatialRect(minX: 10, minY: -11, maxX: 20, maxY: -9)
        XCTAssertEqual(
            Set(index.queryNodes(in: query)),
            Set(spatialNodes.filter { $0.bounds.intersects(query) }.map(\.id))
        )
        XCTAssertGreaterThan(index.metrics.visitedNodes, 0)
    }
}
