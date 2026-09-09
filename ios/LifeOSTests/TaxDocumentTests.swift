import XCTest
@testable import LifeOS

final class TaxDocumentTests: XCTestCase {
    func testParsesGermanDateAndEuroAmountWithEvidence() {
        let result = TaxDocumentParser.parse(text: "Rechnung vom 31.12.2024\nEinkommensteuer 1.234,56 €", documentName: "Bescheid.pdf")
        XCTAssertEqual(result.taxYear, 2024)
        XCTAssertEqual(result.dates.first?.value, "31.12.2024")
        XCTAssertEqual(result.amounts.first?.value, "1234.56")
        XCTAssertEqual(result.amounts.first?.label, "Einkommensteuer")
        XCTAssertEqual(result.amounts.first?.evidence.page, 1)
        XCTAssertTrue(result.amounts.first?.evidence.snippet.contains("Einkommensteuer") == true)
    }

    func testEvidencePreservesPageAndSnippet() {
        let result = TaxDocumentParser.parse(pages: ["Seite eins", "Steuerjahr 2023\nUSt 10,00 EUR"], documentName: "x.pdf")
        XCTAssertEqual(result.taxYear, 2023)
        XCTAssertEqual(result.amounts.first?.evidence.page, 2)
        XCTAssertTrue(result.amounts.first?.evidence.snippet.contains("USt") == true)
    }

    func testParsesISODateYearWithoutTreatingDayAsYear() {
        let result = TaxDocumentParser.parse(text: "Tax year document dated 2024-03-17", documentName: "notice.pdf")
        XCTAssertEqual(result.taxYear, 2024)
        XCTAssertEqual(result.dates.first?.value, "2024-03-17")
    }

    func testMalformedOrNoTextIsConservative() {
        let result = TaxDocumentParser.parse(text: "\u{FFFD}\n", documentName: "bad.pdf")
        XCTAssertNil(result.taxYear)
        XCTAssertTrue(result.amounts.isEmpty)
        XCTAssertTrue(result.warnings.contains("No embedded text was found."))
        XCTAssertEqual(result.confidence, .low)
    }

    func testRulesExtractIssuerMaskedIdentifierAndConfidence() {
        let result = TaxDocumentParser.parse(text: "Finanzamt Berlin\nSteuerjahr: 2024\nSteuernummer: 12/345/67890\nEinkommensteuer 1.234,56 EUR\nDatum 01.02.2024", documentName: "bescheid.pdf")
        XCTAssertEqual(result.issuer?.value, "Finanzamt Berlin")
        XCTAssertEqual(result.taxpayerIdentifier?.value, "********90")
        XCTAssertEqual(result.referenceIdentifier?.value, "Steuernummer: ********90")
        XCTAssertEqual(result.taxYear, 2024)
        XCTAssertEqual(result.amounts.first?.value, "1234.56")
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.dates.first?.value, "01.02.2024")
    }

    func testIdentifierRedactionDoesNotConsumeSameLineAmountOrDate() {
        let taxNumber = "12/345/67890"
        let result = TaxDocumentParser.parse(
            text: "Steuernummer: \(taxNumber) Betrag 123,45 EUR Datum 08.09.2026",
            documentName: "bescheid.pdf"
        )

        XCTAssertFalse(result.pages.joined().contains(taxNumber))
        XCTAssertEqual(result.amounts.first?.value, "123.45")
        XCTAssertEqual(result.dates.first?.value, "08.09.2026")
    }

    func testIdentifiersAreMaskedInReferenceEvidenceAndTransientPages() throws {
        let taxNumber = "12/345/67890"
        let reference = "AZ 987654"
        let result = TaxDocumentParser.parse(
            pages: [
                "Finanzamt Berlin\nSteuernummer: \(taxNumber)\nAktenzeichen: \(reference)\nDatum 01.02.2024\nEinkommensteuer 1.234,56 EUR"
            ],
            documentName: "bescheid.pdf"
        )

        XCTAssertEqual(result.referenceIdentifier?.value, "Steuernummer: ********90")
        XCTAssertTrue(result.referenceIdentifier?.value.contains("Steuernummer") == true)
        XCTAssertFalse(result.referenceIdentifier?.value.contains(taxNumber) == true)
        XCTAssertFalse(result.pages.joined(separator: "\n").contains(taxNumber))
        XCTAssertFalse(result.pages.joined(separator: "\n").contains(reference))

        let evidence = [
            result.issuer?.evidence.snippet,
            result.taxpayerIdentifier?.evidence.snippet,
            result.referenceIdentifier?.evidence.snippet
        ].compactMap { $0 }
            + result.dates.map { $0.evidence.snippet }
            + result.amounts.map { $0.evidence.snippet }
        XCTAssertTrue(evidence.allSatisfy { !$0.contains(taxNumber) && !$0.contains(reference) })

        let encoded = try JSONEncoder().encode(result)
        let persisted = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(persisted.contains(taxNumber))
        XCTAssertFalse(persisted.contains(reference))
        XCTAssertFalse(persisted.contains("\"pages\""))
    }

    func testGermanTaxIdentifierLabelsAreSanitizedBeforeAllParserEvidence() throws {
        let rawIdentifier = "12345678901"
        let labels = [
            "Identifikationsnummer",
            "steuerliche Identifikationsnummer",
            "Steuer-ID",
            "Id-Nr.",
            "Steueridentifikationsnummer"
        ]

        for label in labels {
            let result = TaxDocumentParser.parse(
                text: "\(label): \(rawIdentifier) 08.09.2026\nEinkommensteuer 1.234,56 EUR",
                documentName: "bescheid.pdf"
            )
            let encoded = try JSONEncoder().encode(result)
            let persisted = String(decoding: encoded, as: UTF8.self)
            let evidence = [
                result.taxpayerIdentifier?.evidence.snippet,
                result.referenceIdentifier?.evidence.snippet
            ].compactMap { $0 }
                + result.dates.map { $0.evidence.snippet }
                + result.amounts.map { $0.evidence.snippet }

            XCTAssertEqual(result.dates.first?.value, "08.09.2026", label)
            XCTAssertFalse(result.dates.first?.evidence.snippet.contains(rawIdentifier) == true, label)
            XCTAssertFalse(result.amounts.first?.evidence.snippet.contains(rawIdentifier) == true, label)
            XCTAssertFalse(result.pages.joined(separator: "\n").contains(rawIdentifier), label)
            XCTAssertFalse(evidence.contains { $0.contains(rawIdentifier) }, label)
            XCTAssertFalse(persisted.contains(rawIdentifier), label)
            XCTAssertFalse(persisted.contains("\"pages\""), label)
        }
    }

    func testEmptyPagesWarnAndRemainLowConfidence() {
        let result = TaxDocumentParser.parse(pages: ["", "   "], documentName: "scan.pdf")
        XCTAssertTrue(result.warnings.contains("No embedded text was found."))
        XCTAssertEqual(result.confidence, .low)
        XCTAssertTrue(result.amounts.isEmpty)
    }

    func testPersistenceDeletionAndCSVEscaping() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = TaxDocument(title: "A, \"quoted\"", documentType: "Tax", taxYear: 2024, issuer: "Issuer", taxpayerIdentifier: "****1234", referenceIdentifier: nil, dates: [], amounts: [], pages: [])
        let store = TaxDocumentStore(directory: directory)
        try store.save([doc])
        XCTAssertEqual(try store.load(), [doc])
        XCTAssertTrue(TaxCSVExporter.export([doc]).contains("\"A, \"\"quoted\"\"\""))
        try store.delete(doc)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testCanonicalPersistenceExcludesPageTextAndMigratesLegacyPageField() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaxDocumentStore(directory: directory)
        let rawPageText = "RAW_PAGE_TEXT_SENTINEL_12/345/67890"
        let document = TaxDocument(
            title: "Bescheid",
            documentType: "Tax",
            taxYear: 2024,
            issuer: "Finanzamt Berlin",
            taxpayerIdentifier: "12/345/67890",
            referenceIdentifier: "Reference: REF-123456",
            dates: [],
            amounts: [],
            pages: [rawPageText]
        )

        try store.save([document])
        let fileURL = directory.appendingPathComponent("documents.json")
        var persisted = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(persisted.contains(rawPageText))
        XCTAssertFalse(persisted.contains("\"pages\""))
        XCTAssertTrue(try store.load().first?.pages.isEmpty == true)

        let legacyID = UUID()
        let legacyRawPageText = "LEGACY_RAW_PAGE_TEXT_SENTINEL"
        let legacyJSON = """
        [{"id":"\(legacyID.uuidString)","title":"Legacy","documentType":"Tax","taxYear":2024,"issuer":null,"taxpayerIdentifier":null,"referenceIdentifier":null,"dates":[],"amounts":[],"pages":["\(legacyRawPageText)"],"warnings":[],"confidence":"low"}]
        """
        try Data(legacyJSON.utf8).write(to: fileURL)

        let loadedLegacy = try store.load()
        XCTAssertEqual(loadedLegacy.first?.id, legacyID)
        XCTAssertTrue(loadedLegacy.first?.pages.isEmpty == true)
        persisted = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(persisted.contains(legacyRawPageText))
        XCTAssertFalse(persisted.contains("\"pages\""))
    }

    func testLegacyRawIdentifierEvidenceIsSanitizedDuringDecodeAndRewrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaxDocumentStore(directory: directory)
        let rawIdentifier = "12345678901"
        let rawLine = "Identifikationsnummer: \(rawIdentifier) 08.09.2026"
        let evidence: [String: Any] = ["page": 1, "snippet": rawLine]
        let legacyDocument: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Legacy",
            "documentType": "Tax",
            "taxYear": 2026,
            "issuer": NSNull(),
            "taxpayerIdentifier": ["value": rawLine, "evidence": evidence],
            "referenceIdentifier": ["value": rawLine, "evidence": evidence],
            "dates": [["value": rawLine, "evidence": evidence]],
            "amounts": [["value": rawLine, "label": rawLine, "evidence": evidence]],
            "pages": [rawLine],
            "warnings": [],
            "confidence": "low"
        ]
        let fileURL = directory.appendingPathComponent("documents.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [legacyDocument]).write(to: fileURL)

        let loaded = try store.load()
        let document = try XCTUnwrap(loaded.first)
        let persisted = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        let observed = [
            document.taxpayerIdentifier?.value,
            document.referenceIdentifier?.value,
            document.dates.first?.value,
            document.amounts.first?.value,
            document.amounts.first?.label,
            document.dates.first?.evidence.snippet,
            document.amounts.first?.evidence.snippet,
            document.referenceIdentifier?.evidence.snippet
        ].compactMap { $0 }

        XCTAssertFalse(observed.contains { $0.contains(rawIdentifier) })
        XCTAssertFalse(persisted.contains(rawIdentifier))
        XCTAssertFalse(persisted.contains("\"pages\""))
    }

    func testFailedCanonicalWritePreservesPreviousFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }
        let store = TaxDocumentStore(directory: directory)
        let original = TaxDocument(title: "Original", documentType: "Tax", taxYear: 2024, issuer: nil as String?, taxpayerIdentifier: nil as String?, referenceIdentifier: nil as String?, dates: [], amounts: [], pages: [])
        let replacement = TaxDocument(id: original.id, title: "Replacement", documentType: "Tax", taxYear: 2024, issuer: nil as String?, taxpayerIdentifier: nil as String?, referenceIdentifier: nil as String?, dates: [], amounts: [], pages: [])
        try store.save([original])
        let fileURL = directory.appendingPathComponent("documents.json")
        let originalBytes = try Data(contentsOf: fileURL)

        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.save([replacement]))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        XCTAssertEqual(try store.load(), [original])
        let temporaryFiles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("documents.json.tmp-") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testCSVNeutralizesFormulaPrefixesAndLeadingControlWhitespace() {
        let values = ["=SUM(1,1)", "+1", "-1", "@cmd", "  =1", "\t=1", "\r+1", "\u{0001}@cmd", "\tplain"]
        for value in values {
            let document = TaxDocument(title: value, documentType: "Tax", taxYear: nil, issuer: nil as String?, taxpayerIdentifier: nil as String?, referenceIdentifier: nil as String?, dates: [], amounts: [], pages: [])
            let csv = TaxCSVExporter.export([document])
            XCTAssertTrue(csv.contains("\"'\(value)\""), "CSV value should be prefixed before quoting: \(value.debugDescription)")
        }
    }
}
