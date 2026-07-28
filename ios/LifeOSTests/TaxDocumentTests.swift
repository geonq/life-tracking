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
        XCTAssertEqual(result.taxYear, 2024)
        XCTAssertEqual(result.amounts.first?.value, "1234.56")
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.dates.first?.value, "01.02.2024")
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
}
