import XCTest
@testable import LifeOSMac

final class PlanningGraphTests: XCTestCase {
    private func canvasNode(
        id: String,
        type: PlanningCanvasNodeType = .text,
        x: Double = 0,
        y: Double = 0,
        text: String? = "node",
        file: String? = nil,
        subpath: String? = nil,
        extensionFields: [String: PlanningJSONValue] = [:],
        unknownFields: [String: PlanningJSONValue] = [:]
    ) throws -> PlanningCanvasNode {
        try PlanningCanvasNode(
            id: id,
            type: type,
            x: x,
            y: y,
            width: 100,
            height: 60,
            text: type == .text ? text : nil,
            file: type == .file ? file : nil,
            subpath: subpath,
            unknownFields: unknownFields,
            extensionFields: extensionFields
        )
    }

    private func note(_ path: String, _ source: String) throws -> PlanningGraphNoteSnapshot {
        try PlanningGraphNoteSnapshot(path: path, source: source)
    }

    func testScannerRecognizesSupportedLinksAndIgnoresCodeAndComments() {
        let source = #"""
        [plan]: Notes/Plan.md#Overview
        [[Notes/Plan.md#Today|Today]] ![[Images/plan.png]]
        [inline](Notes/Inline.md#Section)
        [reference][plan] [missing][unknown]
        `[[Ignored.md]]` <!-- [[Comment.md]] -->
        ```markdown
        [[Fenced.md]] [fenced](Fenced.md)
        ```
        [[AfterFence.md]]
        """#

        let scan = PlanningMarkdownLinkScanner.scan(source: source)
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.occurrences.count, 6)
        XCTAssertEqual(scan.occurrences.filter { $0.kind == .wikilink }.count, 3)
        XCTAssertEqual(scan.occurrences.filter { $0.isEmbed }.count, 1)
        XCTAssertEqual(scan.occurrences.first?.rawTarget, "Notes/Plan.md")
        XCTAssertEqual(scan.occurrences.first?.anchor, "Today")
        XCTAssertEqual(scan.occurrences.first?.subpath, "#Today")
        XCTAssertTrue(scan.occurrences.contains { $0.referenceLabel == "plan" && $0.rawTarget == "Notes/Plan.md" })
        XCTAssertTrue(scan.diagnostics.contains { $0.code == .unresolvedReferenceDefinition })
        XCTAssertFalse(scan.occurrences.contains { $0.rawTarget == "Ignored.md" })
        XCTAssertFalse(scan.occurrences.contains { $0.rawTarget == "Fenced.md" })
        XCTAssertTrue(scan.occurrences.contains { $0.rawTarget == "AfterFence.md" })
    }

    func testScannerReportsBoundsAndMalformedSyntaxWithoutRewritingSource() {
        let malformed = "[[missing [target](file.md"
        let scan = PlanningMarkdownLinkScanner.scan(source: malformed)
        XCTAssertTrue(scan.diagnostics.contains { $0.code == .malformedLink })
        XCTAssertEqual(String(decoding: Data(malformed.utf8), as: UTF8.self), malformed)

        let oversized = String(repeating: "x", count: PlanningMarkdownLinkScanner.maximumSourceBytes + 1)
        let bounded = PlanningMarkdownLinkScanner.scan(source: oversized)
        XCTAssertFalse(bounded.isComplete)
        XCTAssertEqual(bounded.sourceByteCount, PlanningMarkdownLinkScanner.maximumSourceBytes + 1)
        XCTAssertTrue(bounded.occurrences.isEmpty)
        XCTAssertEqual(bounded.diagnostics.first?.code, .inputTooLarge)
    }

    func testScannerRecognizesLinkImmediatelyAfterClosedFence() {
        let source = "```\n[[inside.md]]\n```\n[after](After.md)"
        let scan = PlanningMarkdownLinkScanner.scan(source: source)

        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.occurrences.map(\.rawTarget), ["After.md"])
    }

    func testScannerAcceptsLongerClosingFence() {
        let source = "```\n[[inside.md]]\n````\n[after](After.md)"
        let scan = PlanningMarkdownLinkScanner.scan(source: source)

        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.occurrences.map(\.rawTarget), ["After.md"])
    }

    func testScannerConsumesUnmatchedDelimitersWithoutRescanningSuffixes() {
        let single = PlanningMarkdownLinkScanner.scan(source: "[first [second [third")
        XCTAssertTrue(single.occurrences.isEmpty)
        XCTAssertEqual(single.diagnostics.map(\.code), [.malformedLink])

        let wiki = PlanningMarkdownLinkScanner.scan(source: "[[first [[second")
        XCTAssertTrue(wiki.occurrences.isEmpty)
        XCTAssertEqual(wiki.diagnostics.map(\.code), [.malformedLink])
    }

    func testScannerStopsInlineDestinationAtTitleBoundary() {
        let scan = PlanningMarkdownLinkScanner.scan(source: "[x](Note.md \"title\")")

        XCTAssertEqual(scan.occurrences.count, 1)
        XCTAssertEqual(scan.occurrences.first?.rawTarget, "Note.md")
        XCTAssertTrue(scan.diagnostics.isEmpty)
    }

    func testScannerAcceptsAngleDelimitedDestinationWithOptionalTitle() {
        let scan = PlanningMarkdownLinkScanner.scan(source: #"[x]( <Note(1.md)> "title (draft)")"#)

        XCTAssertEqual(scan.occurrences.count, 1)
        XCTAssertEqual(scan.occurrences.first?.rawTarget, "Note(1.md)")
        XCTAssertTrue(scan.diagnostics.isEmpty)
    }

    func testScannerConsumesMalformedInlineDestinationSuffixOnce() {
        let source = "[first](unterminated [second](also-unclosed"
        let scan = PlanningMarkdownLinkScanner.scan(source: source)

        XCTAssertTrue(scan.occurrences.isEmpty)
        XCTAssertEqual(scan.diagnostics.map(\.code), [.malformedLink])
    }

    func testScannerResolvesForwardReferencesAndDoesNotRescanUnterminatedCode() {
        let source = #"""
        [first][later] [inline](Note.md "title")
        [later]: Notes/Later.md
        ``code` [[ignored.md]]
        """#
        let scan = PlanningMarkdownLinkScanner.scan(source: source)

        XCTAssertEqual(scan.occurrences.count, 2)
        XCTAssertEqual(scan.occurrences[0].rawTarget, "Notes/Later.md")
        XCTAssertEqual(scan.occurrences[0].referenceLabel, "later")
        XCTAssertEqual(scan.occurrences[1].rawTarget, "Note.md")
        XCTAssertFalse(scan.occurrences.contains { $0.rawTarget == "ignored.md" })
        XCTAssertTrue(scan.diagnostics.contains { $0.code == .unterminatedInlineCode })
    }

    func testScannerResolvesShortcutReferenceDefinedLater() {
        let source = "[before]\n[before]: Notes/Before.md#Anchor"
        let scan = PlanningMarkdownLinkScanner.scan(source: source)

        XCTAssertEqual(scan.occurrences.count, 1)
        XCTAssertEqual(scan.occurrences.first?.kind, .referenceMarkdown)
        XCTAssertEqual(scan.occurrences.first?.referenceLabel, "before")
        XCTAssertEqual(scan.occurrences.first?.rawTarget, "Notes/Before.md")
        XCTAssertEqual(scan.occurrences.first?.anchor, "Anchor")
        XCTAssertFalse(scan.diagnostics.contains { $0.code == .unresolvedReferenceDefinition })
    }

    func testScannerRequiresEqualLengthInlineCodeClosingRun() {
        let source = "`code`` [ignored](Ignored.md) `"
        let scan = PlanningMarkdownLinkScanner.scan(source: source)

        XCTAssertTrue(scan.isComplete)
        XCTAssertTrue(scan.occurrences.isEmpty)
        XCTAssertFalse(scan.diagnostics.contains { $0.code == .unterminatedInlineCode })
    }

    func testGraphPreservesCanvasOrderRepeatedInstancesEdgesAndDerivedLinks() throws {
        let first = try canvasNode(
            id: "file-a",
            type: .file,
            x: -20,
            file: "Notes/Plan.md",
            subpath: "#Overview"
        )
        let second = try canvasNode(id: "file-b", type: .file, x: 200, file: "Notes/Plan.md")
        let text = try canvasNode(id: "text", x: 400)
        let edge = try PlanningCanvasEdge(id: "edge", fromNode: "file-a", toNode: "file-b", label: "kept")
        let document = try PlanningCanvasDocument(nodes: [first, second, text], edges: [edge])
        let bytes = try PlanningCanvasCodec.encode(document)
        let path = try PlanningStoredPath("Boards/Plan.canvas")
        let input = try PlanningProjectInput(
            canvasPath: path,
            canvasDocument: document,
            canvasBytes: bytes,
            noteSnapshots: [
                try note("Notes/Plan.md", "# Plan\n[[Notes/Other.md#Next]]"),
                try note("Notes/Other.md", "# Other\n[back](Notes/Plan.md)")
            ],
            catalogue: try PlanningReferenceCatalogue(
                paths: ["notes/plan.md", "notes/other.md"],
                isComplete: true
            ),
            vaultID: UUID(),
            accessGeneration: UUID()
        )

        let graph = try PlanningGraphProjector.project(input)
        XCTAssertEqual(graph.canvasInstances.map(\.node.id), ["file-a", "file-b", "text"])
        XCTAssertEqual(
            graph.canvasInstances.map(\.id),
            ["Boards/Plan.canvas#file-a", "Boards/Plan.canvas#file-b", "Boards/Plan.canvas#text"]
        )
        XCTAssertEqual(graph.canvasInstances[0].reference?.path?.value, "Notes/Plan.md")
        XCTAssertEqual(graph.canvasInstances[0].reference?.subpath, "#Overview")
        XCTAssertEqual(graph.canvasInstances[0].reference?.anchor, "Overview")
        XCTAssertEqual(graph.canvasInstances[1].reference?.path?.value, "Notes/Plan.md")
        XCTAssertEqual(graph.authoredEdges.map(\.id), ["edge"])
        XCTAssertEqual(graph.authoredEdges.first?.edge.label, "kept")
        XCTAssertEqual(graph.authoredEdges.first?.fromInstanceID, "Boards/Plan.canvas#file-a")
        XCTAssertEqual(graph.authoredEdges.first?.toInstanceID, "Boards/Plan.canvas#file-b")
        XCTAssertEqual(graph.derivedLinks.count, 2)
        XCTAssertTrue(graph.adjacency["Notes/Plan.md"]?.contains("Notes/Other.md") == true)
        XCTAssertEqual(graph.bounds.minX, -20)
        XCTAssertEqual(graph.bounds.maxX, 500)
    }

    func testReferenceResolverResolvesFragmentOnlyLinksToSourceAndUsesCanonicalLookup() throws {
        let source = try PlanningRelativePath("Notes/Plan.md")
        let catalogue = try PlanningReferenceCatalogue(
            paths: ["Notes/Plan.md", "Notes/Child.md"],
            isComplete: true
        )

        let resolution = PlanningReferenceResolver.resolve(
            "",
            from: source,
            catalogue: catalogue,
            anchor: "Overview",
            subpath: "#Overview"
        )
        XCTAssertEqual(resolution.path?.value, "Notes/Plan.md")
        XCTAssertEqual(resolution.target, nil)

        XCTAssertEqual(
            PlanningReferenceResolver.resolve("notes/child", from: source, catalogue: catalogue).path?.value,
            "Notes/Child.md"
        )

        let qualifiedMissing = try PlanningReferenceCatalogue(
            paths: ["Archive/Plan.md"],
            isComplete: true
        )
        if case .missing = PlanningReferenceResolver.resolve(
            "Notes/Plan.md",
            from: source,
            catalogue: qualifiedMissing
        ) {
        } else {
            XCTFail("A qualified path must not fall back to an unrelated basename")
        }
        if case .missing = PlanningReferenceResolver.resolve(
            "LifeOS/Plan.md",
            from: source,
            catalogue: qualifiedMissing
        ) {
        } else {
            XCTFail("A LifeOS-qualified path must not fall back to an unrelated basename")
        }
    }

    func testGraphProjectionRejectsIncompleteMarkdownScan() throws {
        let document = try PlanningCanvasDocument(nodes: [], edges: [])
        let canvasPath = try PlanningStoredPath("Boards/Plan.canvas")
        let input = try PlanningProjectInput(
            canvasPath: canvasPath,
            canvasDocument: document,
            canvasBytes: try PlanningCanvasCodec.encode(document),
            noteSnapshots: [try note("Notes/Bad.md", "`unterminated")],
            vaultID: UUID(),
            accessGeneration: UUID()
        )

        XCTAssertThrowsError(try PlanningGraphProjector.project(input)) { error in
            XCTAssertEqual(error as? PlanningGraphError, .invalidInput("markdown.scan"))
        }
    }

    func testReferenceResolutionDistinguishesExactAmbiguousMissingNotLoadedOutsideAndExternal() throws {
        let source = try PlanningRelativePath("Boards/Plan.canvas")
        let complete = try PlanningReferenceCatalogue(
            paths: ["Notes/Plan.md", "Archive/Plan.md", "Notes/Unique.md"],
            isComplete: true
        )
        let partial = try PlanningReferenceCatalogue(paths: ["Notes/Unique.md"], isComplete: false)

        XCTAssertEqual(
            PlanningReferenceResolver.resolve("Notes/Unique", from: source, catalogue: complete).path?.value,
            "Notes/Unique.md"
        )
        if case .ambiguous(_, let candidates, _, _) = PlanningReferenceResolver.resolve(
            "Plan",
            from: source,
            catalogue: complete
        ) {
            XCTAssertEqual(candidates.count, 2)
        } else {
            XCTFail("Expected an explicit ambiguous result")
        }
        if case .missing = PlanningReferenceResolver.resolve("Unknown", from: source, catalogue: complete) {
        } else {
            XCTFail("Expected missing")
        }
        if case .notLoaded = PlanningReferenceResolver.resolve("Unknown", from: source, catalogue: partial) {
        } else {
            XCTFail("Expected notLoaded")
        }
        if case .outsideBoundary = PlanningReferenceResolver.resolve("../secret.md", from: source, catalogue: complete) {
        } else {
            XCTFail("Expected outsideBoundary")
        }
        if case .external = PlanningReferenceResolver.resolve("https://example.com", from: source, catalogue: complete) {
        } else {
            XCTFail("Expected external")
        }
    }

    func testReducerRoundTripPreservesExtensionsAndDeletesIncidentEdgesAtomically() throws {
        let node = try canvasNode(
            id: "node",
            extensionFields: ["borderWidth": .number("1.2300")],
            unknownFields: ["future": .object(["large": .number("18446744073709551615")])]
        )
        let other = try canvasNode(id: "other", x: 200)
        let edge = try PlanningCanvasEdge(id: "edge", fromNode: "node", toNode: "other")
        let document = try PlanningCanvasDocument(nodes: [node, other], edges: [edge])
        let edit = try PlanningCanvasEdit.moveNode(
            id: "node",
            from: PlanningCanvasPoint(x: 0, y: 0),
            to: PlanningCanvasPoint(x: 20, y: 30)
        )
        let initialState = try PlanningCanvasEditState(document: document)
        let movedApplication = try PlanningCanvasReducer.apply(edit, to: initialState)
        let moved = movedApplication.state.document
        XCTAssertEqual(moved.nodes.first?.unknownFields, node.unknownFields)
        XCTAssertEqual(moved.nodes.first?.extensionFields["borderWidth"], .number("1.2300"))
        let restoredState = try PlanningCanvasEditState(document: moved)
        let restored = try PlanningCanvasReducer.apply(movedApplication.inverse, to: restoredState)
        XCTAssertEqual(restored.state.document, document)
        let deletion = PlanningCanvasEdit.deleteNode(
            node: node,
            index: 0,
            incidentEdges: [try PlanningIndexedCanvasEdge(edge: edge, index: 0)]
        )
        XCTAssertGreaterThan(
            deletion.estimatedByteCount,
            PlanningCanvasEdit.insertNode(node: node, index: 0).estimatedByteCount
        )
        let deletedApplication = try PlanningCanvasReducer.apply(deletion, to: initialState)
        let deleted = deletedApplication.state.document
        XCTAssertEqual(deleted.nodes.map(\.id), ["other"])
        XCTAssertTrue(deleted.edges.isEmpty)
        let deletedState = try PlanningCanvasEditState(document: deleted)
        let restoredDelete = try PlanningCanvasReducer.apply(deletedApplication.inverse, to: deletedState)
        XCTAssertEqual(restoredDelete.state.document, document)
        let encoded = try PlanningCanvasCodec.encode(moved)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("1.2300"))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("18446744073709551615"))
    }

    func testIncidentEdgeRestoreUsesOriginalOrderAndRejectsDuplicatePositions() throws {
        let node = try canvasNode(id: "node")
        let other = try canvasNode(id: "other", x: 200)
        let third = try canvasNode(id: "third", x: 400)
        let first = try PlanningCanvasEdge(id: "first", fromNode: "node", toNode: "other")
        let middle = try PlanningCanvasEdge(id: "middle", fromNode: "other", toNode: "third")
        let last = try PlanningCanvasEdge(id: "last", fromNode: "node", toNode: "third")
        let document = try PlanningCanvasDocument(
            nodes: [node, other, third],
            edges: [first, middle, last]
        )
        let state = try PlanningCanvasEditState(document: document)
        let deletion = PlanningCanvasEdit.deleteNode(
            node: node,
            index: 0,
            incidentEdges: [
                try PlanningIndexedCanvasEdge(edge: first, index: 0),
                try PlanningIndexedCanvasEdge(edge: last, index: 2)
            ]
        )
        let deleted = try PlanningCanvasReducer.apply(deletion, to: state)
        XCTAssertEqual(deleted.state.document.edges.map(\.id), ["middle"])
        let restored = try PlanningCanvasReducer.apply(deletion.inverse, to: deleted.state)
        XCTAssertEqual(restored.state.document, document)

        let duplicatePositions = PlanningCanvasEdit.restoreNode(
            node: node,
            index: 0,
            incidentEdges: [
                try PlanningIndexedCanvasEdge(edge: first, index: 0),
                try PlanningIndexedCanvasEdge(edge: last, index: 0)
            ]
        )
        XCTAssertThrowsError(try PlanningCanvasReducer.apply(duplicatePositions, to: deleted.state))
    }

    func testSpatialIndexMatchesBruteForceForExtremeGeometryAndReportsInstrumentation() throws {
        var nodes: [PlanningSpatialNode] = []
        nodes.reserveCapacity(500)
        for index in 0..<500 {
            nodes.append(PlanningSpatialNode(
                id: "node-" + String(index),
                bounds: PlanningSpatialRect(
                    minX: Double(index % 25) * 40 - 1_000_000,
                    minY: Double(index / 25) * 30 - 500_000,
                    maxX: Double(index % 25) * 40 - 999_999,
                    maxY: Double(index / 25) * 30 - 499_999
                )
            ))
        }
        var edges: [PlanningSpatialEdge] = []
        edges.reserveCapacity(100)
        for index in 0..<100 {
            edges.append(try PlanningSpatialEdge(id: "edge-" + String(index), points: [
                PlanningSpatialPoint(x: -1_000_000 + Double(index), y: -500_000),
                PlanningSpatialPoint(x: -999_000 + Double(index), y: -499_000)
            ]))
        }
        var index = PlanningSpatialIndex()
        try index.rebuild(nodes: nodes, edges: edges)
        let query = PlanningSpatialRect(minX: -999_950, minY: -499_990, maxX: -999_500, maxY: -499_500)
        let expected = Set(nodes.filter { $0.bounds.intersects(query) }.map { $0.id })
        XCTAssertEqual(Set(index.queryNodes(in: query)), expected)
        XCTAssertGreaterThan(index.metrics.visitedNodes, 0)
        XCTAssertGreaterThan(index.metrics.candidateCount, 0)
        let hits = index.hitTest(PlanningSpatialPoint(x: -999_999.5, y: -499_999.5), tolerance: 1)
        XCTAssertTrue(hits.contains { $0.kind == .node })
    }

    func testSpatialIndexBuildScalesToBoundedD1Input() throws {
        var nodes: [PlanningSpatialNode] = []
        nodes.reserveCapacity(10_000)
        for index in 0..<10_000 {
            nodes.append(PlanningSpatialNode(
                id: "n" + String(index),
                bounds: PlanningSpatialRect(
                    minX: Double(index % 100),
                    minY: Double(index / 100),
                    maxX: Double(index % 100) + 1,
                    maxY: Double(index / 100) + 1
                )
            ))
        }
        var edges: [PlanningSpatialEdge] = []
        edges.reserveCapacity(20_000)
        for index in 0..<20_000 {
            edges.append(try PlanningSpatialEdge(id: "e" + String(index), points: [
                PlanningSpatialPoint(x: Double(index % 100), y: Double(index / 100)),
                PlanningSpatialPoint(x: Double(index % 100) + 0.5, y: Double(index / 100) + 0.5)
            ]))
        }
        var index = PlanningSpatialIndex()
        try index.rebuild(nodes: nodes, edges: edges)
        XCTAssertEqual(index.metrics.rebuiltElementCount, 30_000)
        XCTAssertEqual(index.metrics.rebuildPasses, 8)
    }

    func testSpatialIndexRejectsDuplicateAndInvalidIdentifiers() throws {
        let bounds = PlanningSpatialRect(minX: 0, minY: 0, maxX: 1, maxY: 1)
        let duplicateNodes = [
            PlanningSpatialNode(id: "same", bounds: bounds),
            PlanningSpatialNode(id: "same", bounds: bounds)
        ]
        var index = PlanningSpatialIndex()
        XCTAssertThrowsError(try index.rebuild(nodes: duplicateNodes, edges: [])) { error in
            XCTAssertEqual(error as? PlanningSpatialIndexError, .duplicateID("nodes"))
        }

        let edge = try PlanningSpatialEdge(id: "same", points: [
            PlanningSpatialPoint(x: 0, y: 0),
            PlanningSpatialPoint(x: 1, y: 1)
        ])
        let duplicateEdges = try [edge, PlanningSpatialEdge(id: "same", points: edge.points)]
        XCTAssertThrowsError(try index.rebuild(nodes: [], edges: duplicateEdges)) { error in
            XCTAssertEqual(error as? PlanningSpatialIndexError, .duplicateID("edges"))
        }

        XCTAssertThrowsError(try index.rebuild(
            nodes: [PlanningSpatialNode(id: "", bounds: bounds)],
            edges: []
        )) { error in
            XCTAssertEqual(error as? PlanningSpatialIndexError, .invalidGeometry("nodes.id"))
        }

        let invalidEdgeJSON = #"{"id":"edge","points":[],"bounds":{"minX":0,"minY":0,"maxX":1,"maxY":1}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            PlanningSpatialEdge.self,
            from: Data(invalidEdgeJSON.utf8)
        ))
    }
}
