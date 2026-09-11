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

    func testParsesPlainAndGroupedMoneyFormatsWithoutGuessing() {
        let cases = [
            ("Einkommensteuer 1234.56 EUR", "1234.56"),
            ("Einkommensteuer 1.234,56 EUR", "1234.56"),
            ("Einkommensteuer 1 234,56 EUR", "1234.56")
        ]

        for (text, expected) in cases {
            let result = TaxDocumentParser.parse(text: text, documentName: "Bescheid.pdf")
            XCTAssertEqual(result.amounts.first?.value, expected, text)
        }
    }

    func testRejectsAmbiguousGroupedOrDecimalTokenInsteadOfTruncatingIt() {
        let result = TaxDocumentParser.parse(
            text: "Einkommensteuer 1.234 EUR",
            documentName: "Bescheid.pdf"
        )

        XCTAssertTrue(result.amounts.isEmpty)
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

    func testIdentifierMaskingRequiresBoundedMaskAndTwoDigitSuffix() {
        let valuesAndExpected = [
            ("********90", "********90"),
            ("*90", "********90"),
            ("**90", "********90"),
            ("***90", "********90"),
            ("****1234", "********34"),
            ("12/345/67890", "********90"),
            ("12 345 678 901", "********01"),
            ("123-456-789-01", "********01"),
            ("12345678901*", "********01"),
            ("*2345678901", "********01"),
            ("12345*78901", "********01"),
            ("1", "********"),
            ("*9", "********"),
            ("abc", "********")
        ]

        for (value, expected) in valuesAndExpected {
            let document = TaxDocument(
                title: "Identifier test",
                documentType: "Tax",
                taxYear: nil,
                issuer: nil as String?,
                taxpayerIdentifier: value,
                referenceIdentifier: value,
                dates: [],
                amounts: [],
                pages: []
            )

            XCTAssertEqual(document.taxpayerIdentifier?.value, expected, value)
            XCTAssertEqual(document.referenceIdentifier?.value, expected, value)
        }
    }

    func testConstructionSanitizesAllFreeTextFieldsAndPreservesDatesAndAmounts() throws {
        let rawIdentifier = "12345678901"
        let groupedIdentifier = "12 345 678 901"
        let document = TaxDocument(
            title: "\(rawIdentifier).pdf",
            documentType: "\(groupedIdentifier)",
            taxYear: 2026,
            issuer: TaxCandidate(
                value: "Finanzamt \(rawIdentifier)",
                evidence: TaxEvidence(page: 1, snippet: "Issuer \(groupedIdentifier)")),
            taxpayerIdentifier: TaxCandidate(
                value: "*01",
                evidence: TaxEvidence(page: 1, snippet: "Tax ID \(rawIdentifier)")),
            referenceIdentifier: TaxCandidate(
                value: "12/345/67890",
                evidence: TaxEvidence(page: 1, snippet: "Reference \(groupedIdentifier)")),
            dates: [TaxDate(
                value: "08.09.2026",
                evidence: TaxEvidence(page: 1, snippet: "Date 08.09.2026 \(rawIdentifier)"))],
            amounts: [TaxAmount(
                value: "1234.56",
                label: "Einkommensteuer",
                evidence: TaxEvidence(page: 1, snippet: "Amount 1.234,56 EUR \(rawIdentifier)"))],
            pages: ["Page \(rawIdentifier)", "Grouped \(groupedIdentifier)"],
            warnings: ["Warning \(rawIdentifier)"]
        )

        XCTAssertEqual(document.title, "********01.pdf")
        XCTAssertEqual(document.documentType, "********01")
        XCTAssertEqual(document.issuer?.value, "Finanzamt ********01")
        XCTAssertEqual(document.issuer?.evidence.snippet, "Issuer ********01")
        XCTAssertEqual(document.taxpayerIdentifier?.value, "********01")
        XCTAssertEqual(document.referenceIdentifier?.value, "********90")
        XCTAssertEqual(document.dates.first?.value, "08.09.2026")
        XCTAssertEqual(document.amounts.first?.value, "1234.56")
        XCTAssertEqual(document.amounts.first?.label, "Einkommensteuer")
        XCTAssertEqual(document.warnings, ["Warning ********01"])
        XCTAssertTrue(document.pages.allSatisfy { !$0.contains(rawIdentifier) && !$0.contains(groupedIdentifier) })

        let encoded = try JSONEncoder().encode(document)
        let persisted = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(persisted.contains(rawIdentifier))
        XCTAssertFalse(persisted.contains(groupedIdentifier))
        XCTAssertFalse(persisted.contains("\"pages\""))

        let decoded = try JSONDecoder().decode(TaxDocument.self, from: encoded)
        XCTAssertEqual(decoded.title, document.title)
        XCTAssertEqual(decoded.documentType, document.documentType)
        XCTAssertEqual(decoded.dates.first?.value, "08.09.2026")
        XCTAssertEqual(decoded.amounts.first?.value, "1234.56")
    }

    func testEvidenceCanonicalizesMaskedGroupedRawAndMixedIdentifierForms() {
        let formsAndExpected = [
            ("*90", "********90"),
            ("**90", "********90"),
            ("***90", "********90"),
            ("12345678901", "********01"),
            ("12/345/67890", "********90"),
            ("123-456-789-01", "********01"),
            ("12345*78901", "********01")
        ]
        for (form, expected) in formsAndExpected {
            let evidence = TaxEvidence(page: 1, snippet: "ID \(form)")
            XCTAssertEqual(evidence.snippet, "ID \(expected)", form)
        }
    }

    func testLongNumericAmountRemainsEvidenceAndAmountTextButIdentifierCandidatesMask() {
        let amount = "12345678901.00"
        let evidence = TaxEvidence(page: 1, snippet: "Amount \(amount)")
        XCTAssertEqual(evidence.snippet, "Amount \(amount)")

        let taxAmount = TaxAmount(value: amount, label: "Amount", evidence: evidence)
        XCTAssertEqual(taxAmount.value, amount)

        let parsed = TaxDocumentParser.parse(
            text: "Einkommensteuer \(amount) EUR",
            documentName: "Amount.pdf"
        )
        XCTAssertEqual(parsed.amounts.first?.value, amount)

        let document = TaxDocument(
            title: "Amount context",
            documentType: "Tax",
            taxYear: nil,
            issuer: nil as String?,
            taxpayerIdentifier: amount,
            referenceIdentifier: nil,
            dates: [],
            amounts: [taxAmount],
            pages: []
        )
        XCTAssertEqual(document.taxpayerIdentifier?.value, "********00")
        XCTAssertEqual(document.amounts.first?.value, amount)
    }

    func testFilenameDerivedFieldsAreSanitizedWithoutChangingFinancialValues() throws {
        let rawIdentifier = "12345678901"
        let result = TaxDocumentParser.parse(
            text: "08.09.2026\nEinkommensteuer 1.234,56 EUR",
            documentName: "\(rawIdentifier).pdf"
        )

        XCTAssertEqual(result.title, "********01.pdf")
        XCTAssertEqual(result.documentType, "********01")
        XCTAssertEqual(result.dates.first?.value, "08.09.2026")
        XCTAssertEqual(result.amounts.first?.value, "1234.56")
        let encoded = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(rawIdentifier))
    }

    func testRawMaskedIdentifierIsSanitizedAcrossConstructionDecodeEvidencePagesAndPersistence() throws {
        let rawIdentifier = "12345678901*"
        let mixedIdentifier = "*2345678901"
        let taxpayerEvidence = TaxEvidence(page: 1, snippet: "Tax ID: \(rawIdentifier)")
        let referenceEvidence = TaxEvidence(page: 1, snippet: "Reference \(mixedIdentifier)")
        let constructed = TaxDocument(
            title: "Privacy test",
            documentType: "Tax",
            taxYear: 2026,
            issuer: nil as TaxCandidate?,
            taxpayerIdentifier: TaxCandidate(value: rawIdentifier, evidence: taxpayerEvidence),
            referenceIdentifier: TaxCandidate(value: mixedIdentifier, evidence: referenceEvidence),
            dates: [],
            amounts: [],
            pages: ["Page text: \(rawIdentifier)", "Other text: \(mixedIdentifier)"]
        )

        let inMemoryValues = [
            constructed.taxpayerIdentifier?.value,
            constructed.referenceIdentifier?.value,
            constructed.taxpayerIdentifier?.evidence.snippet,
            constructed.referenceIdentifier?.evidence.snippet
        ].compactMap { $0 } + constructed.pages
        XCTAssertEqual(constructed.taxpayerIdentifier?.value, "********01")
        XCTAssertEqual(constructed.referenceIdentifier?.value, "********01")
        XCTAssertTrue(inMemoryValues.allSatisfy {
            !$0.contains(rawIdentifier) && !$0.contains(mixedIdentifier) && !$0.contains("12345678901")
        })

        let identifier = UUID()
        let wireJSON = """
        {
          "id": "\(identifier.uuidString)",
          "title": "Privacy test",
          "documentType": "Tax",
          "taxYear": 2026,
          "issuer": null,
          "taxpayerIdentifier": {
            "value": "\(rawIdentifier)",
            "evidence": {"page": 1, "snippet": "Tax ID: \(rawIdentifier)"}
          },
          "referenceIdentifier": {
            "value": "\(mixedIdentifier)",
            "evidence": {"page": 1, "snippet": "Reference \(mixedIdentifier)"}
          },
          "dates": [],
          "amounts": [],
          "warnings": [],
          "confidence": "low"
        }
        """
        let decoded = try JSONDecoder().decode(TaxDocument.self, from: Data(wireJSON.utf8))
        let decodedValues = [
            decoded.taxpayerIdentifier?.value,
            decoded.referenceIdentifier?.value,
            decoded.taxpayerIdentifier?.evidence.snippet,
            decoded.referenceIdentifier?.evidence.snippet
        ].compactMap { $0 } + decoded.pages
        XCTAssertTrue(decodedValues.allSatisfy {
            !$0.contains(rawIdentifier) && !$0.contains(mixedIdentifier) && !$0.contains("12345678901")
        })

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaxDocumentStore(directory: directory)
        try store.save([constructed])
        let persisted = String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("documents.json")),
            as: UTF8.self
        )
        XCTAssertFalse(persisted.contains(rawIdentifier))
        XCTAssertFalse(persisted.contains(mixedIdentifier))
        XCTAssertFalse(persisted.contains("12345678901"))
        XCTAssertFalse(persisted.contains("\"pages\""))
    }

    func testKnownIdentifierMappingCoversEveryPublicationField() throws {
        let rawIdentifier = "AZ123456"
        let evidence = { (label: String) in
            TaxEvidence(page: 1, snippet: "\(label) \(rawIdentifier)")
        }
        let document = TaxDocument(
            title: "Assessment \(rawIdentifier)",
            documentType: "tax_assessment \(rawIdentifier)",
            taxYear: 2026,
            issuer: TaxCandidate(value: "Finanzamt \(rawIdentifier)", evidence: evidence("Issuer")),
            taxpayerIdentifier: TaxCandidate(value: rawIdentifier, evidence: evidence("Taxpayer")),
            referenceIdentifier: TaxCandidate(value: rawIdentifier, evidence: evidence("Reference")),
            dates: [TaxDate(
                value: "31.12.2025 \(rawIdentifier)",
                evidence: evidence("Date")
            )],
            amounts: [TaxAmount(
                value: "1.234,56 EUR \(rawIdentifier)",
                label: "Amount \(rawIdentifier)",
                evidence: evidence("Amount")
            )],
            pages: ["Page \(rawIdentifier)"],
            warnings: ["Review \(rawIdentifier)"],
            confidence: .high
        )

        let inMemoryValues = [
            document.title,
            document.documentType,
            document.issuer?.value,
            document.issuer?.evidence.snippet,
            document.taxpayerIdentifier?.value,
            document.taxpayerIdentifier?.evidence.snippet,
            document.referenceIdentifier?.value,
            document.referenceIdentifier?.evidence.snippet,
            document.dates.first?.value,
            document.dates.first?.evidence.snippet,
            document.amounts.first?.value,
            document.amounts.first?.label,
            document.amounts.first?.evidence.snippet,
            document.warnings.first ?? "",
            document.pages.first ?? ""
        ].compactMap { $0 }
        XCTAssertTrue(inMemoryValues.allSatisfy { !$0.contains(rawIdentifier) })
        XCTAssertTrue(inMemoryValues.contains { $0.contains("********56") })

        let encoded = try JSONEncoder().encode(document)
        let persisted = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(persisted.contains(rawIdentifier))
        XCTAssertTrue(persisted.contains("********56"))
        XCTAssertFalse(persisted.contains("\"pages\""))

        let decoded = try JSONDecoder().decode(TaxDocument.self, from: encoded)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains(rawIdentifier))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaxDocumentStore(directory: directory)
        try store.save([document])
        let stored = String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("documents.json")),
            as: UTF8.self
        )
        XCTAssertFalse(stored.contains(rawIdentifier))
        XCTAssertTrue(stored.contains("********56"))
        XCTAssertFalse(stored.contains("\"pages\""))
        let loaded = try store.load()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(loaded.first!), as: UTF8.self).contains(rawIdentifier))
    }

    func testMaskedIdentifierEvidenceWithholdsUnknownLegacyTextDuringStoreMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let identifier = UUID().uuidString
        let legacyJSON = """
        [{
          "id": "\(identifier)",
          "title": "Tax year 2026",
          "documentType": "tax_return",
          "taxYear": 2026,
          "issuer": null,
          "taxpayerIdentifier": {
            "value": "********56",
            "evidence": {"page": 1, "snippet": "Legacy evidence AZ123456"}
          },
          "referenceIdentifier": {
            "value": "********42",
            "evidence": {"page": 1, "snippet": "Page 1 · 31.12.2025 · 1.234,56 EUR"}
          },
          "dates": [],
          "amounts": [],
          "warnings": [],
          "confidence": "low"
        }]
        """
        let fileURL = directory.appendingPathComponent("documents.json")
        try Data(legacyJSON.utf8).write(to: fileURL)

        let store = TaxDocumentStore(directory: directory)
        let loaded = try store.load()
        XCTAssertEqual(loaded.first?.taxpayerIdentifier?.evidence.snippet,
                       "Evidence withheld for privacy.")
        XCTAssertEqual(loaded.first?.referenceIdentifier?.evidence.snippet,
                       "Page 1 · 31.12.2025 · 1.234,56 EUR")

        let migrated = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(migrated.contains("AZ123456"))
        XCTAssertTrue(migrated.contains("Evidence withheld for privacy."))
        XCTAssertFalse(migrated.contains("\"pages\""))
    }

    func testIdentifierPrivacyKeepsOrdinaryContextAndMasksShortUnknownTokens() {
        let ordinary = TaxDocument(
            title: "Tax year 2026",
            documentType: "tax_return",
            taxYear: 2026,
            issuer: nil as TaxCandidate?,
            taxpayerIdentifier: TaxCandidate(
                value: "********26",
                evidence: TaxEvidence(page: 1, snippet: "Page 1 · 31.12.2025 · 1.234,56 EUR")
            ),
            referenceIdentifier: nil,
            dates: [],
            amounts: [],
            pages: []
        )
        XCTAssertEqual(ordinary.title, "Tax year 2026")
        XCTAssertEqual(ordinary.taxpayerIdentifier?.evidence.snippet,
                       "Page 1 · 31.12.2025 · 1.234,56 EUR")

        let shortToken = TaxDocument(
            title: "Assessment A7",
            documentType: "tax_return",
            taxYear: nil,
            issuer: nil as TaxCandidate?,
            taxpayerIdentifier: TaxCandidate(
                value: "********",
                evidence: TaxEvidence(page: 1, snippet: "Legacy A7")
            ),
            referenceIdentifier: nil,
            dates: [],
            amounts: [],
            pages: []
        )
        XCTAssertFalse(shortToken.title.contains("A7"))
        XCTAssertEqual(shortToken.taxpayerIdentifier?.evidence.snippet,
                       "Evidence withheld for privacy.")

        let commonLabels = TaxDocument(
            title: "Form W2",
            documentType: "Schedule K1",
            taxYear: nil,
            issuer: nil as TaxCandidate?,
            taxpayerIdentifier: nil,
            referenceIdentifier: nil,
            dates: [],
            amounts: [],
            pages: []
        )
        XCTAssertEqual(commonLabels.title, "Form W2")
        XCTAssertEqual(commonLabels.documentType, "Schedule K1")

        let arbitraryLabel = TaxDocument(
            title: "Form AZ123456",
            documentType: "Schedule AZ123456",
            taxYear: nil,
            issuer: nil as TaxCandidate?,
            taxpayerIdentifier: nil,
            referenceIdentifier: nil,
            dates: [],
            amounts: [],
            pages: []
        )
        XCTAssertFalse(arbitraryLabel.title.contains("AZ123456"))
        XCTAssertFalse(arbitraryLabel.documentType.contains("AZ123456"))
    }

    func testMaskedIdentifierEvidenceWithholdsUntrustedNumericAndOpaqueText() throws {
        for snippet in ["Page 8642", "8642 EUR", "SECRETREF", "secretref", "Amount 8642"] {
            let document = TaxDocument(
                title: "Tax year 2026",
                documentType: "tax_return",
                taxYear: 2026,
                issuer: nil,
                taxpayerIdentifier: TaxCandidate(
                    value: "********42",
                    evidence: TaxEvidence(page: 1, snippet: snippet)
                ),
                referenceIdentifier: nil,
                dates: [],
                amounts: [],
                pages: []
            )
            XCTAssertEqual(
                document.taxpayerIdentifier?.evidence.snippet,
                "Evidence withheld for privacy.",
                "masked candidate must not publish unverifiable evidence: \(snippet)"
            )

            let encoded = try JSONEncoder().encode(document)
            let encodedText = String(decoding: encoded, as: UTF8.self)
            XCTAssertTrue(encodedText.contains("Evidence withheld for privacy."))
            XCTAssertFalse(encodedText.contains(snippet))

            let decoded = try JSONDecoder().decode(TaxDocument.self, from: encoded)
            XCTAssertEqual(
                decoded.taxpayerIdentifier?.evidence.snippet,
                "Evidence withheld for privacy."
            )

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = TaxDocumentStore(directory: directory)
            try store.save([document])
            let stored = String(
                decoding: try Data(contentsOf: directory.appendingPathComponent("documents.json")),
                as: UTF8.self
            )
            XCTAssertTrue(stored.contains("Evidence withheld for privacy."))
            XCTAssertFalse(stored.contains(snippet))
            XCTAssertEqual(
                try store.load().first?.taxpayerIdentifier?.evidence.snippet,
                "Evidence withheld for privacy."
            )
        }
    }

    func testPrivacyBoundsOversizedFieldsBeforeContextSanitization() {
        let sentinel = "SECRET_AFTER_SAFE_BOUND"
        let oversizedTitle = String(repeating: "A7 ", count: TaxDocumentLimits.maximumFieldCharacters) + sentinel
        let document = TaxDocument(
            title: oversizedTitle,
            documentType: "tax_return",
            taxYear: nil,
            issuer: nil as TaxCandidate?,
            taxpayerIdentifier: nil,
            referenceIdentifier: nil,
            dates: [],
            amounts: [],
            pages: []
        )

        XCTAssertLessThanOrEqual(document.title.count, TaxDocumentLimits.maximumFieldCharacters)
        XCTAssertFalse(document.title.contains(sentinel))

        let oversizedEvidence = String(
            repeating: "A7 ",
            count: TaxDocumentLimits.maximumEvidenceCharacters
        ) + sentinel
        let candidate = TaxCandidate(
            value: "********42",
            evidence: TaxEvidence(page: 1, snippet: oversizedEvidence)
        )
        XCTAssertLessThanOrEqual(
            candidate.evidence.snippet.count,
            TaxDocumentLimits.maximumEvidenceCharacters
        )
        XCTAssertFalse(candidate.evidence.snippet.contains(sentinel))

        let oversizedPage = String(repeating: "x", count: TaxDocumentLimits.maximumPageCharacters) + sentinel
        let bounded = TaxDocument.boundedPagesForParsing([oversizedPage])
        XCTAssertLessThanOrEqual(
            bounded.pages.first?.count ?? 0,
            TaxDocumentLimits.maximumPageCharacters
        )
        XCTAssertFalse(bounded.pages.first?.contains(sentinel) == true)
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

    func testTaxDocumentStoreUsesPlatformAppropriateDurableWriteOptions() {
#if os(iOS)
        XCTAssertTrue(TaxDocumentStore.durableWriteOptions.contains(.atomic))
        XCTAssertTrue(TaxDocumentStore.durableWriteOptions.contains(.completeFileProtection))
#elseif os(macOS)
        XCTAssertEqual(TaxDocumentStore.durableWriteOptions, [.atomic])
#endif
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

    func testStoreMigrationSanitizesLegacyFreeTextAndKeepsDatesAndAmounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawIdentifier = "12345678901"
        let groupedIdentifier = "12 345 678 901"
        let evidence = ["page": 1, "snippet": "Evidence \(groupedIdentifier)"] as [String: Any]
        let legacyDocument: [String: Any] = [
            "id": UUID().uuidString,
            "title": "\(rawIdentifier).pdf",
            "documentType": groupedIdentifier,
            "taxYear": 2026,
            "issuer": [
                "value": "Finanzamt \(rawIdentifier)",
                "evidence": evidence
            ],
            "taxpayerIdentifier": [
                "value": "*90",
                "evidence": ["page": 1, "snippet": "Tax ID \(rawIdentifier)"]
            ],
            "referenceIdentifier": [
                "value": "12345*78901",
                "evidence": ["page": 1, "snippet": "Reference \(groupedIdentifier)"]
            ],
            "dates": [[
                "value": "08.09.2026",
                "evidence": ["page": 1, "snippet": "Date \(rawIdentifier) 08.09.2026"]
            ]],
            "amounts": [[
                "value": "1234.56",
                "label": "Einkommensteuer",
                "evidence": ["page": 1, "snippet": "Amount 1.234,56 EUR \(rawIdentifier)"]
            ]],
            "pages": ["Legacy raw page \(rawIdentifier)"],
            "warnings": ["Warning \(rawIdentifier)"],
            "confidence": "high"
        ]
        let fileURL = directory.appendingPathComponent("documents.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [legacyDocument]).write(to: fileURL)

        let loaded = try TaxDocumentStore(directory: directory).load()
        let document = try XCTUnwrap(loaded.first)
        XCTAssertEqual(document.title, "********01.pdf")
        XCTAssertEqual(document.documentType, "********01")
        XCTAssertEqual(document.issuer?.value, "Finanzamt ********01")
        XCTAssertEqual(document.taxpayerIdentifier?.value, "********90")
        XCTAssertEqual(document.referenceIdentifier?.value, "********01")
        XCTAssertEqual(document.dates.first?.value, "08.09.2026")
        XCTAssertEqual(document.amounts.first?.value, "1234.56")
        XCTAssertEqual(document.warnings, ["Warning ********01"])
        XCTAssertTrue(document.pages.isEmpty)

        let migrated = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(migrated.contains(rawIdentifier))
        XCTAssertFalse(migrated.contains(groupedIdentifier))
        XCTAssertFalse(migrated.contains("\"pages\""))
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

    func testParserBoundsUntrustedPageText() {
        let page = String(repeating: "x", count: TaxDocumentLimits.maximumPageCharacters + 1)
        let result = TaxDocumentParser.parse(pages: [page], documentName: "large.pdf")

        XCTAssertLessThanOrEqual(result.pages.first?.utf8.count ?? 0, TaxDocumentLimits.maximumTotalPageBytes)
        XCTAssertTrue(result.warnings.contains("Document text was truncated to a safe limit."))
    }

    func testStoreRejectsOversizedFileBeforeDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("documents.json")
        try Data(repeating: 0x20, count: TaxDocumentLimits.maximumStoredBytes + 1).write(to: fileURL)

        var thrown: Error?
        XCTAssertThrowsError(try TaxDocumentStore(directory: directory).load()) { thrown = $0 }
        XCTAssertEqual(thrown as? TaxDocumentStoreError, .fileTooLarge)
    }

    func testStoreRejectsTooManyDocumentsBeforePublish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = (0...TaxDocumentLimits.maximumStoredDocuments).map { index in
            TaxDocument(title: "Document \(index)", documentType: "Tax", taxYear: nil,
                        issuer: nil as String?, taxpayerIdentifier: nil as String?,
                        referenceIdentifier: nil as String?, dates: [], amounts: [], pages: [])
        }

        var thrown: Error?
        XCTAssertThrowsError(try TaxDocumentStore(directory: directory).save(documents)) { thrown = $0 }
        XCTAssertEqual(thrown as? TaxDocumentStoreError, .tooManyDocuments)
    }

    @MainActor
    func testViewModelBlocksWritesAfterLoadFailure() {
        let preserved = TaxDocument(title: "Preserved", documentType: "Tax", taxYear: 2024,
                                    issuer: nil as String?, taxpayerIdentifier: nil as String?, referenceIdentifier: nil as String?,
                                    dates: [], amounts: [], pages: [])
        var persisted = [preserved]
        var saveCallCount = 0
        let model = TaxDocumentsViewModel(
            load: { throw TaxDocumentStoreError.fileTooLarge },
            save: { candidate in
                saveCallCount += 1
                persisted = candidate
            }
        )

        XCTAssertTrue(model.isWriteBlocked)
        XCTAssertTrue(model.documents.isEmpty)
        model.saveReview(preserved)
        model.delete(at: IndexSet(integer: 0))

        XCTAssertEqual(saveCallCount, 0)
        XCTAssertEqual(persisted, [preserved])
        XCTAssertTrue(model.errorMessage?.contains("disabled") == true)
    }

    @MainActor
    func testViewModelRetainsStateAfterFailedSave() {
        struct SaveFailure: Error {}
        let original = TaxDocument(title: "Original", documentType: "Tax", taxYear: 2024,
                                   issuer: nil as String?, taxpayerIdentifier: nil as String?, referenceIdentifier: nil as String?,
                                   dates: [], amounts: [], pages: [])
        let replacement = TaxDocument(id: original.id, title: "Replacement", documentType: "Tax", taxYear: 2024,
                                      issuer: nil as String?, taxpayerIdentifier: nil as String?, referenceIdentifier: nil as String?,
                                      dates: [], amounts: [], pages: [])
        var saveCallCount = 0
        let model = TaxDocumentsViewModel(
            load: { [original] in [original] },
            save: { _ in
                saveCallCount += 1
                throw SaveFailure()
            }
        )
        model.reviewDocument = replacement

        model.saveReview(replacement)

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(model.documents, [original])
        XCTAssertEqual(model.reviewDocument, replacement)
        XCTAssertEqual(model.errorMessage, "Tax documents could not be saved. Your current documents were kept.")
    }

    @MainActor
    func testViewModelRetainsStateAfterFailedDelete() {
        struct DeleteFailure: Error {}
        let original = TaxDocument(title: "Original", documentType: "Tax", taxYear: 2024,
                                   issuer: nil as String?, taxpayerIdentifier: nil as String?, referenceIdentifier: nil as String?,
                                   dates: [], amounts: [], pages: [])
        let model = TaxDocumentsViewModel(
            load: { [original] in [original] },
            save: { _ in throw DeleteFailure() }
        )

        model.delete(at: IndexSet(integer: 0))

        XCTAssertEqual(model.documents, [original])
        XCTAssertEqual(model.errorMessage, "Tax documents could not be saved. Your current documents were kept.")
    }

    @MainActor
    func testViewModelAdmitsOneImportAndClearsBusyAfterCancellation() async {
        let model = TaxDocumentsViewModel(load: { [] }, save: { _ in })
        let url = URL(fileURLWithPath: "/definitely-missing-tax-document.pdf")

        model.importPDF(url: url)
        XCTAssertTrue(model.isImporting)

        model.importPDF(url: url)
        XCTAssertEqual(model.errorMessage, "A PDF import is already in progress.")

        model.cancelImport()
        for _ in 0..<8 { await Task.yield() }

        XCTAssertFalse(model.isImporting)
        XCTAssertNil(model.errorMessage)
    }

    func testExtractorRejectsOversizedPageAndAggregateWithoutTruncating() {
        var pages: [String] = []
        var totalBytes = 0
        let oversizedPage = String(repeating: "x", count: TaxDocumentLimits.maximumPageCharacters + 1)

        XCTAssertFalse(TaxPDFExtractor.appendBounded(oversizedPage, to: &pages, totalBytes: &totalBytes))
        XCTAssertTrue(pages.isEmpty)
        XCTAssertEqual(totalBytes, 0)

        let boundedPage = String(repeating: "x", count: TaxDocumentLimits.maximumPageCharacters)
        while TaxPDFExtractor.appendBounded(boundedPage, to: &pages, totalBytes: &totalBytes) {}
        let pageCountBeforeRejectedAppend = pages.count
        let bytesBeforeRejectedAppend = totalBytes

        XCTAssertFalse(TaxPDFExtractor.appendBounded(boundedPage, to: &pages, totalBytes: &totalBytes))
        XCTAssertEqual(pages.count, pageCountBeforeRejectedAppend)
        XCTAssertEqual(totalBytes, bytesBeforeRejectedAppend)
        XCTAssertLessThanOrEqual(totalBytes, TaxDocumentLimits.maximumTotalPageBytes)
    }

    func testCancelledExtractionReturnsCancellationBeforeReading() async {
        let result = await Task { () -> Result<[String], TaxPDFExtractor.ExtractError> in
            withUnsafeCurrentTask { $0?.cancel() }
            return await TaxPDFExtractor.extract(url: URL(fileURLWithPath: "/definitely-missing-tax-document.pdf"))
        }.value

        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testParserStopsAtDateAndAmountBounds() {
        let datesText = Array(repeating: "01.01.2024", count: TaxDocumentLimits.maximumDates + 25)
            .joined(separator: " ")
        let dateResult = TaxDocumentParser.parse(text: datesText, documentName: "dates.pdf")
        XCTAssertEqual(dateResult.dates.count, TaxDocumentLimits.maximumDates)

        let amountsText = Array(repeating: "Einkommensteuer 1,00 EUR", count: TaxDocumentLimits.maximumAmounts + 25)
            .joined(separator: " ")
        let amountResult = TaxDocumentParser.parse(text: amountsText, documentName: "amounts.pdf")
        XCTAssertEqual(amountResult.amounts.count, TaxDocumentLimits.maximumAmounts)
    }

    func testParserHonorsCancellationCheck() {
        let text = Array(repeating: "01.01.2024 Einkommensteuer 1,00 EUR", count: 100)
            .joined(separator: " ")
        let result = TaxDocumentParser.parse(
            text: text,
            documentName: "cancelled.pdf",
            cancellationCheck: { true }
        )

        XCTAssertTrue(result.dates.isEmpty)
        XCTAssertTrue(result.amounts.isEmpty)
    }
}
