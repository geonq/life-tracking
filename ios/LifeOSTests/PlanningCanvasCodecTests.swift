import XCTest
@testable import LifeOS

final class PlanningCanvasCodecTests: XCTestCase {
    func testLosslessRoundTripPreservesUnknownFieldsAndHasStableOutput() throws {
        let input = Data(
            #"""
            {
              "edges": [
                {
                  "fromNode": "text-1",
                  "toNode": "file-1",
                  "id": "edge-1",
                  "fromSide": "right",
                  "toSide": "left",
                  "futureEdgeValue": {"z": 2, "a": true, "large": 18446744073709551615, "exponent": 1.2300e+10, "text": "line\n\tvalue"}
                }
              ],
              "nodes": [
                {
                  "type": "text",
                  "id": "text-1",
                  "height": 80,
                  "width": 300,
                  "x": 10,
                  "y": -20,
                  "text": "Plan",
                  "futureNodeValue": {"nested": ["one", 2, null]}
                },
                {
                  "id": "file-1",
                  "type": "file",
                  "x": 400,
                  "y": 0,
                  "width": 250,
                  "height": 80,
                  "file": "Projects/Plan.md",
                  "label": "Project note"
                }
              ],
              "futureDocumentValue": {"beta": false, "alpha": 1}
            }
            """#.utf8
        )

        let document = try PlanningCanvasCodec.decode(input)
        XCTAssertEqual(document.nodes.count, 2)
        XCTAssertEqual(document.edges.first?.fromNode, "text-1")
        XCTAssertEqual(document.unknownFields["futureDocumentValue"], .object([
            "alpha": .integer(1),
            "beta": .bool(false)
        ]))
        XCTAssertEqual(document.edges.first?.unknownFields["futureEdgeValue"], .object([
            "a": .bool(true),
            "exponent": .number("1.2300e+10"),
            "large": .number("18446744073709551615"),
            "text": .string("line\n\tvalue"),
            "z": .integer(2)
        ]))

        let encoded = try PlanningCanvasCodec.encode(document)
        XCTAssertEqual(encoded, try PlanningCanvasCodec.encode(document))
        let decoded = try PlanningCanvasCodec.decode(encoded)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.contentDigest, document.contentDigest)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("futureNodeValue"))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("18446744073709551615"))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("1.2300e+10"))
    }

    func testOptionalTopLevelArraysDecodeAsEmptyAndNodesOnlyIsValid() throws {
        let empty = try PlanningCanvasCodec.decode(Data(#"{}"#.utf8))
        XCTAssertTrue(empty.nodes.isEmpty)
        XCTAssertTrue(empty.edges.isEmpty)
        XCTAssertEqual(String(decoding: try PlanningCanvasCodec.encode(empty), as: UTF8.self), #"{"edges":[],"nodes":[]}"#)

        let nodesOnly = Data(
            #"{"nodes":[{"id":"note","type":"text","x":0,"y":0,"width":100,"height":50,"text":"hello"}]}"#.utf8
        )
        let document = try PlanningCanvasCodec.decode(nodesOnly)
        XCTAssertEqual(document.nodes.count, 1)
        XCTAssertTrue(document.edges.isEmpty)
    }

    func testSupportsStandardTextLinkGroupAndFileNodes() throws {
        let nodes = [
            try PlanningCanvasNode(id: "text", type: .text, x: 0, y: 0, width: 100, height: 50, text: ""),
            try PlanningCanvasNode(id: "link", type: .link, x: 1, y: 1, width: 100, height: 50, url: "https://obsidian.md"),
            try PlanningCanvasNode(id: "group", type: .group, x: 2, y: 2, width: 100, height: 50, label: "Group"),
            try PlanningCanvasNode(id: "file", type: .file, x: 3, y: 3, width: 100, height: 50, file: "Notes/Today.md")
        ]
        let document = try PlanningCanvasDocument(nodes: nodes, edges: [])
        XCTAssertEqual(try PlanningCanvasCodec.decode(try PlanningCanvasCodec.encode(document)), document)
    }

    func testRejectsDuplicateIDsAndMalformedReferences() throws {
        let duplicate = Data(
            #"{"nodes":[{"id":"same","type":"text","x":0,"y":0,"width":10,"height":10,"text":"a"},{"id":"same","type":"text","x":1,"y":1,"width":10,"height":10,"text":"b"}],"edges":[]}"#.utf8
        )
        XCTAssertThrowsError(try PlanningCanvasCodec.decode(duplicate))

        let missingReference = Data(
            #"{"nodes":[{"id":"only","type":"text","x":0,"y":0,"width":10,"height":10,"text":"a"}],"edges":[{"id":"edge","fromNode":"only","toNode":"missing"}]}"#.utf8
        )
        XCTAssertThrowsError(try PlanningCanvasCodec.decode(missingReference))
    }

    func testRejectsInvalidIDsPathsCoordinatesDimensionsAndURLs() throws {
        XCTAssertThrowsError(
            try PlanningCanvasNode(id: " ", type: .text, x: 0, y: 0, width: 10, height: 10, text: "a")
        )
        XCTAssertThrowsError(
            try PlanningCanvasNode(id: "node", type: .file, x: .infinity, y: 0, width: 10, height: 10, file: "../secret.md")
        )
        XCTAssertThrowsError(
            try PlanningCanvasNode(id: "node", type: .link, x: 0, y: 0, width: 0, height: 10, url: "javascript:alert(1)")
        )
        XCTAssertThrowsError(
            try PlanningVaultBinding(vaultRelativePath: "Uni")
        )
        XCTAssertNoThrow(
            try PlanningVaultBinding(vaultRelativePath: "Projects/projects")
        )
    }

    func testCrossReferenceCollisionIsDocumentLevelOnly() throws {
        let validPath = try PlanningCanvasNode(
            id: "valid",
            type: .file,
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            file: "Projects/projects/plan.md"
        )
        XCTAssertNoThrow(try PlanningCanvasDocument(nodes: [validPath], edges: []))

        let first = try PlanningCanvasNode(
            id: "first",
            type: .file,
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            file: "Notes/Plan.md"
        )
        let second = try PlanningCanvasNode(
            id: "second",
            type: .file,
            x: 100,
            y: 0,
            width: 100,
            height: 100,
            file: "notes/plan.md"
        )
        XCTAssertThrowsError(try PlanningCanvasDocument(nodes: [first, second], edges: []))
    }

    func testRejectsWindowsUnsafeReferencesAndGroupBackgroundTraversal() {
        let unsafePaths = [
            "folder/name. ",
            "CON.txt",
            "COM¹.txt",
            "LPT².log",
            "folder:stream.png",
            "folder/name*.png",
            "folder/name?.png",
            "folder/name\".png",
            "folder/name<.png",
            "folder/name>.png",
            "folder/name|.png",
            "folder\\name.png",
            "C:relative.png",
            "folder/../secret.png",
            "/absolute.png"
        ]
        for path in unsafePaths {
            XCTAssertThrowsError(
                try PlanningCanvasNode(
                    id: "node",
                    type: .file,
                    x: 0,
                    y: 0,
                    width: 100,
                    height: 100,
                    file: path
                ),
                "expected invalid path: \(path)"
            )
            XCTAssertThrowsError(
                try PlanningCanvasNode(
                    id: "group",
                    type: .group,
                    x: 0,
                    y: 0,
                    width: 100,
                    height: 100,
                    background: path
                ),
                "expected invalid background: \(path)"
            )
            XCTAssertThrowsError(
                try PlanningVaultBinding(vaultRelativePath: path),
                "expected invalid vault binding: \(path)"
            )
        }
        XCTAssertThrowsError(
            try PlanningCanvasNode(
                id: "group",
                type: .group,
                x: 0,
                y: 0,
                width: 100,
                height: 100,
                background: "../../secret.png"
            )
        )
    }

    func testAcceptsStandardCanvasFieldsAndRejectsInvalidValues() throws {
        let node = try PlanningCanvasNode(
            id: "group",
            type: .group,
            x: -10,
            y: 20,
            width: 300,
            height: 200,
            color: "#AABBCCDD",
            label: "Roadmap",
            background: "Assets/background.png",
            backgroundStyle: "cover"
        )
        let edge = try PlanningCanvasEdge(
            id: "edge",
            fromNode: "group",
            fromSide: "right",
            fromEnd: "none",
            toNode: "group",
            toSide: "left",
            toEnd: "arrow",
            color: "6"
        )
        XCTAssertEqual(try PlanningCanvasCodec.decode(try PlanningCanvasCodec.encode(try PlanningCanvasDocument(nodes: [node], edges: [edge]))).edges.first?.toEnd, "arrow")

        XCTAssertThrowsError(try PlanningCanvasNode(id: "fraction", type: .text, x: 0.5, y: 0, width: 100, height: 50, text: "x"))
        XCTAssertThrowsError(try PlanningCanvasNode(id: "color", type: .text, x: 0, y: 0, width: 100, height: 50, color: "7", text: "x"))
        XCTAssertThrowsError(try PlanningCanvasNode(id: "hex", type: .text, x: 0, y: 0, width: 100, height: 50, color: "#GGGGGG", text: "x"))
        XCTAssertThrowsError(try PlanningCanvasNode(id: "subpath", type: .file, x: 0, y: 0, width: 100, height: 50, file: "note.md", subpath: "heading"))
        XCTAssertThrowsError(try PlanningCanvasNode(id: "style", type: .group, x: 0, y: 0, width: 100, height: 50, background: "image.png", backgroundStyle: "stretch"))
        XCTAssertThrowsError(try PlanningCanvasEdge(id: "side", fromNode: "a", fromSide: "diagonal", toNode: "b"))
        XCTAssertThrowsError(try PlanningCanvasEdge(id: "end", fromNode: "a", fromEnd: "circle", toNode: "b"))
    }

    func testRejectsOversizedCanvasInputBeforeJSONParsing() {
        let oversized = Data(repeating: 0x20, count: PlanningLimits.maximumCanvasBytes + 1)
        XCTAssertEqual(
            try? PlanningCanvasCodec.decode(oversized),
            nil
        )
    }

    func testRejectsNonFiniteOrUnsafeUnknownValues() throws {
        XCTAssertThrowsError(
            try PlanningCanvasNode(
                id: "node",
                type: .text,
                x: 0,
                y: 0,
                width: 10,
                height: 10,
                text: "ok",
                unknownFields: ["unsafe": .number("NaN")]
            )
        )
        XCTAssertThrowsError(
            try PlanningCanvasNode(
                id: "node",
                type: .text,
                x: 0,
                y: 0,
                width: 10,
                height: 10,
                text: "ok",
                unknownFields: ["id": .string("collision")]
            )
        )
    }

    func testProgrammaticallyConstructedOversizedDocumentFailsBeforeEncoding() throws {
        let largeText = String(repeating: "x", count: 500_000)
        let nodes = try (0..<5).map { index in
            try PlanningCanvasNode(
                id: "node-\(index)",
                type: .text,
                x: Double(index * 100),
                y: 0,
                width: 100,
                height: 100,
                text: largeText
            )
        }
        let document = try PlanningCanvasDocument(nodes: nodes, edges: [])
        XCTAssertThrowsError(try PlanningCanvasCodec.encode(document)) { error in
            XCTAssertEqual(error as? PlanningValidationError, .inputTooLarge)
        }
    }

    func testEscapeHeavyTextRoundTripsWithinCanvasBound() throws {
        let text = String(repeating: "\n\t\"", count: 100_000)
        let node = try PlanningCanvasNode(
            id: "escape-heavy",
            type: .text,
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            text: text
        )
        let document = try PlanningCanvasDocument(nodes: [node], edges: [])

        let encoded = try PlanningCanvasCodec.encode(document)
        XCTAssertLessThan(encoded.count, PlanningLimits.maximumCanvasBytes)
        XCTAssertEqual(try PlanningCanvasCodec.decode(encoded), document)
    }

    func testDedicatedCodecRetainsRawExtensionsAndExplicitNulls() throws {
        let source = Data(
            #"{"nodes":[{"id":"group","type":"group","x":0,"y":0,"width":100,"height":100,"locked":null,"borderWidth":1.234567890123456789,"borderStyle":null,"extension":{"":{"line\nbreak":1}}}],"edges":[]}"#.utf8
        )

        let document = try PlanningCanvasCodec.decode(source)
        let node = try XCTUnwrap(document.nodes.first)
        XCTAssertEqual(node.extensionFields["locked"], .null)
        XCTAssertEqual(node.extensionFields["borderWidth"], .number("1.234567890123456789"))
        XCTAssertEqual(node.extensionFields["borderStyle"], .null)
        XCTAssertEqual(
            node.unknownFields["extension"],
            .object(["": .object(["line\nbreak": .integer(1)])])
        )

        let encoded = try PlanningCanvasCodec.encode(document)
        let encodedString = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(encodedString.contains(#""locked":null"#))
        XCTAssertTrue(encodedString.contains(#""borderStyle":null"#))
        XCTAssertTrue(encodedString.contains("1.234567890123456789"))
        XCTAssertEqual(try PlanningCanvasCodec.decode(encoded), document)
    }

    func testPublicCodableRejectsNumbersThatCannotBeLexicallyPreserved() {
        let source = Data(#"{"extension":{"large":18446744073709551615}}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(PlanningJSONValue.self, from: source)
        )
    }

    func testJSONKeysAllowEmptyAndEscapedControlsButRejectMalformedAndDuplicateKeys() throws {
        let source = Data(#"{"nodes":[],"edges":[],"future":{"":{"line\nbreak":true}}}"#.utf8)
        let document = try PlanningCanvasCodec.decode(source)
        XCTAssertEqual(
            document.unknownFields["future"],
            .object(["": .object(["line\nbreak": .bool(true)])])
        )
        XCTAssertEqual(try PlanningCanvasCodec.decode(try PlanningCanvasCodec.encode(document)), document)

        let duplicate = Data(#"{"nodes":[],"nodes":[]}"#.utf8)
        XCTAssertThrowsError(try PlanningCanvasCodec.decode(duplicate))

        let malformedEscape = Data(#"{"nodes":[],"future":{"bad\q":1}}"#.utf8)
        XCTAssertThrowsError(try PlanningCanvasCodec.decode(malformedEscape))
    }
}
