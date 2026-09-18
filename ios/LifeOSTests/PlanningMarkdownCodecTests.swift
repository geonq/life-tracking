import XCTest
@testable import LifeOS

final class PlanningMarkdownCodecTests: XCTestCase {
    func testFrontmatterAndBodyRoundTripWithoutRewritingUnknownContent() throws {
        let source = """
        ---
        title: Weekly plan
        tags: [life, planning]
        custom: preserve this exactly
        ---
        # This is the body

        Keep spacing and line endings.
        """
        let note = try PlanningMarkdownCodec.decode(
            relativePath: "Projects/Weekly plan.md",
            source: source
        )

        XCTAssertEqual(note.title, "Weekly plan")
        XCTAssertEqual(note.frontmatter.status, .unsupported)
        XCTAssertEqual(note.frontmatter.value(forKey: "title"), "Weekly plan")
        XCTAssertEqual(note.frontmatter.value(forKey: "custom"), "preserve this exactly")
        XCTAssertEqual(note.body, "# This is the body\n\nKeep spacing and line endings.")
        XCTAssertEqual(try note.encodedData(), Data(source.utf8))
        XCTAssertEqual(note, try PlanningMarkdownCodec.decode(relativePath: "Projects/Weekly plan.md", data: Data(source.utf8)))
    }

    func testAbsentFrontmatterUsesSafeFileTitleAndPreservesBody() throws {
        let source = "# Daily note\n\n- one\n"
        let note = try PlanningMarkdownCodec.decode(relativePath: "Daily.md", source: source)

        XCTAssertEqual(note.title, "Daily")
        XCTAssertEqual(note.frontmatter.status, .absent)
        XCTAssertEqual(note.frontmatter.raw, "")
        XCTAssertEqual(note.body, source)
        XCTAssertEqual(note.contentDigest.count, 64)
        XCTAssertEqual(try note.encodedData(), Data(source.utf8))
    }

    func testRejectsTraversalAndAbsolutePathsButAllowsIntraPathCaseDifferences() throws {
        XCTAssertThrowsError(
            try PlanningMarkdownCodec.decode(relativePath: "../escape.md", source: "body")
        )
        XCTAssertThrowsError(
            try PlanningMarkdownCodec.decode(relativePath: "/absolute.md", source: "body")
        )
        XCTAssertNoThrow(
            try PlanningMarkdownCodec.decode(relativePath: "Projects/PROJECTS/plan.md", source: "body")
        )
        XCTAssertThrowsError(
            try PlanningMarkdownCodec.decode(relativePath: "note.txt", source: "body")
        )
    }

    func testDuplicateTitleKeysUseFilenameFallbackAndHideAmbiguousMetadata() throws {
        let duplicate = "---\ntitle: one\ntitle: two\ncustom: one\ncustom: two\n---\nbody"
        let duplicateNote = try PlanningMarkdownCodec.decode(relativePath: "note.md", source: duplicate)
        XCTAssertEqual(duplicateNote.title, "note")
        XCTAssertNil(duplicateNote.frontmatter.value(forKey: "title"))
        XCTAssertNil(duplicateNote.frontmatter.value(forKey: "custom"))
        XCTAssertEqual(duplicateNote.frontmatter.status, .unsupported)
    }

    func testCaseCollidingTitleKeysUseFilenameFallback() throws {
        let duplicate = "---\ntitle: one\nTitle: two\n---\nbody"
        let duplicateNote = try PlanningMarkdownCodec.decode(relativePath: "case-collision.md", source: duplicate)
        XCTAssertEqual(duplicateNote.title, "case-collision")
        XCTAssertNil(duplicateNote.frontmatter.value(forKey: "title"))
        XCTAssertEqual(duplicateNote.frontmatter.status, .unsupported)
    }

    func testQuotedTitleKeysInvalidateCollisionsInEitherOrderAndPreserveSource() throws {
        let sources = [
            "---\ntitle: First\n\"title\": Second\n---\nbody",
            "---\n\"title\": First\ntitle: Second\n---\nbody",
            "---\ntitle: First\n'Title': Second\n---\nbody",
            "---\n'Title': First\ntitle: Second\n---\nbody",
            "---\ntitle: First\n\"TITLE\": Second\n---\nbody",
            "---\n\"TITLE\": First\ntitle: Second\n---\nbody",
            "---\ntitle: First\n'TITLE': Second\n---\nbody",
            "---\n'TITLE': First\ntitle: Second\n---\nbody"
        ]

        for (index, source) in sources.enumerated() {
            let note = try PlanningMarkdownCodec.decode(
                relativePath: "quoted-collision-\(index).md",
                source: source
            )
            XCTAssertEqual(note.title, "quoted-collision-\(index)", "case \(index)")
            XCTAssertNil(note.frontmatter.value(forKey: "title"), "case \(index)")
            XCTAssertEqual(note.frontmatter.status, .unsupported, "case \(index)")
            XCTAssertEqual(try note.encodedData(), Data(source.utf8), "case \(index)")
        }
    }

    func testUnclosedFrontmatterFails() throws {
        let unclosed = "---\ntitle: one\nbody"
        XCTAssertThrowsError(
            try PlanningMarkdownCodec.decode(relativePath: "note.md", source: unclosed)
        )
    }

    func testNestedQuotedAndCommentedFrontmatterIsConservative() throws {
        let source = """
        ---
        metadata:
          title: Hidden nested title
        "title": Quoted key
        title: Visible title # inline comment
        custom: C# is not a comment
        list: [one, two]
        ---
        body
        """
        let note = try PlanningMarkdownCodec.decode(relativePath: "fallback.md", source: source)
        XCTAssertEqual(note.title, "fallback")
        XCTAssertEqual(note.frontmatter.status, .unsupported)
        XCTAssertEqual(note.frontmatter.value(forKey: "custom"), "C# is not a comment")
        XCTAssertNil(note.frontmatter.value(forKey: "title"))
        XCTAssertEqual(note.frontmatter.value(forKey: "metadata"), nil)
        XCTAssertEqual(try note.encodedData(), Data(source.utf8))
    }

    func testUnsafeQuotedKeyInvalidatesAllMetadataConservatively() throws {
        let source = "---\ntitle: Visible title\n\"title with spaces\": Ambiguous\ncustom: hidden\n---\nbody"
        let note = try PlanningMarkdownCodec.decode(relativePath: "unsafe-key.md", source: source)

        XCTAssertEqual(note.title, "unsafe-key")
        XCTAssertNil(note.frontmatter.value(forKey: "title"))
        XCTAssertNil(note.frontmatter.value(forKey: "custom"))
        XCTAssertEqual(note.frontmatter.status, .unsupported)
        XCTAssertEqual(try note.encodedData(), Data(source.utf8))
    }

    func testCRLFSourceIsRetainedExactly() throws {
        let source = "---\r\ntitle: Morning plan\r\ncustom: keep this scalar\r\n---\r\n# Body\r\n"
        let note = try PlanningMarkdownCodec.decode(relativePath: "Morning.md", source: source)
        XCTAssertEqual(note.title, "Morning plan")
        XCTAssertEqual(note.frontmatter.value(forKey: "custom"), "keep this scalar")
        XCTAssertEqual(note.body, "# Body\r\n")
        XCTAssertEqual(try note.encodedData(), Data(source.utf8))
        XCTAssertEqual(note.frontmatter.raw, "title: Morning plan\r\ncustom: keep this scalar\r\n")
    }

    func testMissingMappingSeparatorUsesFilenameFallback() throws {
        let source = "---\ntitle:Hello\ncustom: retained\n---\nbody"
        let note = try PlanningMarkdownCodec.decode(relativePath: "Fallback.md", source: source)
        XCTAssertEqual(note.title, "Fallback")
        XCTAssertNil(note.frontmatter.value(forKey: "title"))
        XCTAssertEqual(note.frontmatter.value(forKey: "custom"), "retained")
        XCTAssertEqual(note.frontmatter.status, .unsupported)
        XCTAssertEqual(try note.encodedData(), Data(source.utf8))
    }

    func testBlockScalarIndicatorUsesFilenameFallbackWithoutPartialTitle() throws {
        let source = "---\ntitle: |-\n  first line\n  second line\n---\nbody"
        let note = try PlanningMarkdownCodec.decode(relativePath: "Block.md", source: source)
        XCTAssertEqual(note.title, "Block")
        XCTAssertNil(note.frontmatter.value(forKey: "title"))
        XCTAssertEqual(note.frontmatter.status, .unsupported)
        XCTAssertEqual(try note.encodedData(), Data(source.utf8))
    }

    func testAnchorValueUsesFilenameFallbackWithoutPartialTitle() throws {
        let source = "---\ntitle: &morning Morning plan\n---\nbody"
        let note = try PlanningMarkdownCodec.decode(relativePath: "Anchor.md", source: source)
        XCTAssertEqual(note.title, "Anchor")
        XCTAssertNil(note.frontmatter.value(forKey: "title"))
        XCTAssertEqual(note.frontmatter.status, .unsupported)
    }

    func testAliasValueUsesFilenameFallbackWithoutPartialTitle() throws {
        let source = "---\ntitle: *morning\n---\nbody"
        let note = try PlanningMarkdownCodec.decode(relativePath: "Alias.md", source: source)
        XCTAssertEqual(note.title, "Alias")
        XCTAssertNil(note.frontmatter.value(forKey: "title"))
        XCTAssertEqual(note.frontmatter.status, .unsupported)
    }

    func testTagValueUsesFilenameFallbackWithoutPartialTitle() throws {
        let source = "---\ntitle: !!str Morning plan\n---\nbody"
        let note = try PlanningMarkdownCodec.decode(relativePath: "Tag.md", source: source)
        XCTAssertEqual(note.title, "Tag")
        XCTAssertNil(note.frontmatter.value(forKey: "title"))
        XCTAssertEqual(note.frontmatter.status, .unsupported)
    }

    func testContinuedScalarRemovesPartialTitleAndPreservesSource() throws {
        let source = "---\ntitle: First line\n  second line\ncustom: retained\n---\nbody"
        let note = try PlanningMarkdownCodec.decode(relativePath: "Continued.md", source: source)
        XCTAssertEqual(note.title, "Continued")
        XCTAssertNil(note.frontmatter.value(forKey: "title"))
        XCTAssertEqual(note.frontmatter.value(forKey: "custom"), "retained")
        XCTAssertEqual(note.frontmatter.status, .unsupported)
        XCTAssertEqual(try note.encodedData(), Data(source.utf8))
    }

    func testRejectsOversizedAndInvalidUTF8Input() {
        let oversized = Data(repeating: 0x61, count: PlanningLimits.maximumMarkdownBytes + 1)
        XCTAssertThrowsError(
            try PlanningMarkdownCodec.decode(relativePath: "note.md", data: oversized)
        )
        XCTAssertThrowsError(
            try PlanningMarkdownCodec.decode(relativePath: "note.md", data: Data([0xFF, 0xFE, 0xFD]))
        )
    }

    func testVaultBindingIsValueOnlyAndCanonical() throws {
        let binding = try PlanningVaultBinding(
            vaultRelativePath: "Personal/Knowledge",
            lifeOSSubfolder: "LifeOS"
        )
        XCTAssertEqual(binding.canonicalLifeOSRelativePath, "Personal/Knowledge/LifeOS")
        XCTAssertEqual(binding.symlinkPolicy, .rejectUnknown)

        let encoded = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(PlanningVaultBinding.self, from: encoded)
        XCTAssertEqual(decoded, binding)
    }
}
