import XCTest
@testable import LifeOS

final class FinanceInstitutionDetectorTests: XCTestCase {
    private let tradeRepublicEnglishHeaders = [
        "datetime", "date", "account_type", "category", "type", "asset_class",
        "name", "symbol", "shares", "price", "amount", "fee", "tax", "currency",
        "original_amount", "original_currency", "fx_rate", "description", "transaction_id",
        "counterparty_name", "counterparty_iban", "payment_reference", "mcc_code"
    ]

    func testNormalizeHeaderHandlesCaseDiacriticsPunctuationAndIsIdempotent() {
        let cases = [
            ("  CÔunter-party Name! ", "counterpartyname"),
            ("BÜCHUNGSTAG", "buchungstag"),
            ("Stück-ID", "stuckid"),
            ("Transaktions-ID", "transactionid")
        ]

        for (raw, expected) in cases {
            let normalized = FinanceInstitutionDetector.normalizeHeader(raw)
            XCTAssertEqual(normalized, expected, "unexpected normalization for \(raw)")
            XCTAssertEqual(
                FinanceInstitutionDetector.normalizeHeader(normalized),
                normalized,
                "normalization must be idempotent for \(raw)"
            )
        }
    }

    func testExactTradeRepublicEnglishProfileIncludesVersionedExactMetadata() {
        let detection = FinanceInstitutionDetector.detect(
            headers: tradeRepublicEnglishHeaders,
            delimiter: .comma,
            validEURRowCount: 1
        )

        XCTAssertEqual(detection.state, .known)
        XCTAssertEqual(detection.institution, .tradeRepublic)
        XCTAssertEqual(detection.profileID, "trade-republic-english-v1")
        XCTAssertEqual(detection.provenance.profileID, "trade-republic-english-v1")
        XCTAssertEqual(detection.provenance.profileVersion, 1)
        XCTAssertEqual(detection.provenance.delimiter, .comma)
        XCTAssertEqual(
            detection.provenance.registryVersion,
            FinanceInstitutionDetectionProvenance.currentRegistryVersion
        )
        XCTAssertEqual(
            detection.provenance.detectorVersion,
            FinanceInstitutionDetectionProvenance.currentDetectorVersion
        )
        XCTAssertEqual(
            detection.provenance.normalizationVersion,
            FinanceInstitutionDetectionProvenance.currentNormalizationVersion
        )
        XCTAssertEqual(
            Set(detection.provenance.evidenceCodes),
            Set([
                FinanceInstitutionDetectionEvidenceCode.requiredHeadersPresent,
                .exactHeaderSet,
                .delimiterMatched,
                .columnCountMatched,
                .noForbiddenHeaders,
                .validEURRow
            ])
        )
        XCTAssertTrue(detection.provenance.reasonCodes.isEmpty)
    }

    func testExactGermanTradeRepublicLegacyProfileRetainsCompatibilityMetadata() {
        let detection = FinanceInstitutionDetector.detect(
            headers: ["Datum", "Typ", "Beschreibung", "Betrag"],
            delimiter: .semicolon,
            validEURRowCount: 1
        )

        XCTAssertEqual(detection.state, .known)
        XCTAssertEqual(detection.institution, .tradeRepublic)
        XCTAssertEqual(detection.profileID, "trade-republic-german-legacy-v1")
        XCTAssertEqual(detection.provenance.profileID, "trade-republic-german-legacy-v1")
        XCTAssertEqual(detection.provenance.profileVersion, 1)
        XCTAssertEqual(detection.provenance.delimiter, .semicolon)
        XCTAssertTrue(detection.provenance.legacyLayoutCompatibility)
        XCTAssertTrue(detection.provenance.evidenceCodes.contains(.legacyLayoutCompatibility))
        XCTAssertTrue(detection.provenance.evidenceCodes.contains(.exactHeaderSet))
        XCTAssertTrue(detection.provenance.evidenceCodes.contains(.validEURRow))
    }

    func testGenericGermanDateDescriptionAmountRemainsUnknown() {
        let detection = FinanceInstitutionDetector.detect(
            headers: ["Datum", "Beschreibung", "Betrag"],
            delimiter: .semicolon
        )

        XCTAssertEqual(detection.state, .unknown)
        XCTAssertNil(detection.institution)
        XCTAssertNil(detection.profileID)
        XCTAssertEqual(detection.provenance.reasonCodes, [.noEligibleProfile])
    }

    func testDisabledInstitutionMarkersRemainUnknown() {
        let cases: [([String], FinanceInstitution, String)] = [
            (["Activity Date", "Trans Code", "Net Amount"], .robinhood, "robinhood-disabled-v1"),
            (["Buchungstag", "Umsatz"], .sparkasse, "sparkasse-disabled-v1"),
            (["Completed Date", "Amount", "Currency", "State"], .revolut, "revolut-disabled-v1")
        ]

        for (headers, institution, profileID) in cases {
            let detection = FinanceInstitutionDetector.detect(
                headers: headers,
                delimiter: .comma,
                validEURRowCount: 1
            )

            XCTAssertEqual(detection.state, .unknown, profileID)
            XCTAssertNil(detection.institution, profileID)
            XCTAssertEqual(detection.profileID, profileID, profileID)
            XCTAssertEqual(detection.provenance.reasonCodes, [.disabledProfile], profileID)
            XCTAssertTrue(detection.provenance.evidenceCodes.contains(.requiredHeadersPresent), profileID)
            XCTAssertEqual(detection.candidates.first { $0.profileID == profileID }?.institution, institution)
        }
    }

    func testTradeRepublicNearMatchesAreUnsupported() {
        let missingHeader = tradeRepublicEnglishHeaders.dropLast()
        let extraHeader = tradeRepublicEnglishHeaders + ["synthetic_extra"]
        let cases: [([String], FinanceCSVDelimiter)] = [
            (Array(missingHeader), .comma),
            (extraHeader, .comma),
            (tradeRepublicEnglishHeaders, .semicolon)
        ]

        for (headers, delimiter) in cases {
            let detection = FinanceInstitutionDetector.detect(headers: headers, delimiter: delimiter)

            XCTAssertEqual(detection.state, .unknown)
            XCTAssertNil(detection.institution)
            XCTAssertEqual(detection.profileID, "trade-republic-english-v1")
            XCTAssertEqual(detection.provenance.reasonCodes, [.unsupportedNearMatch])
        }
    }

    func testExactKnownProfileWithNoValidRowsIsUnknown() {
        let detection = FinanceInstitutionDetector.detect(
            headers: tradeRepublicEnglishHeaders,
            delimiter: .comma,
            validEURRowCount: 0
        )

        XCTAssertEqual(detection.state, .unknown)
        XCTAssertNil(detection.institution)
        XCTAssertEqual(detection.profileID, "trade-republic-english-v1")
        XCTAssertEqual(detection.provenance.reasonCodes, [.noValidEURRows])
        XCTAssertTrue(detection.provenance.evidenceCodes.contains(.exactHeaderSet))
    }

    func testDuplicateNormalizedHeadersAreRejected() {
        let detection = FinanceInstitutionDetector.detect(
            headers: ["Dáté", "date"],
            delimiter: .comma
        )

        XCTAssertEqual(detection.state, .unknown)
        XCTAssertNil(detection.institution)
        XCTAssertNil(detection.profileID)
        XCTAssertEqual(detection.provenance.reasonCodes, [.duplicateNormalizedHeader])
    }

    func testDetectionCandidatesReasonsAndEvidenceAreDeterministic() {
        let first = FinanceInstitutionDetector.detect(
            headers: tradeRepublicEnglishHeaders,
            delimiter: .comma,
            validEURRowCount: 2
        )

        for _ in 0..<20 {
            XCTAssertEqual(
                FinanceInstitutionDetector.detect(
                    headers: tradeRepublicEnglishHeaders,
                    delimiter: .comma,
                    validEURRowCount: 2
                ),
                first
            )
        }
    }

    func testMissingOnlyProfileCandidateDoesNotClaimAnExtraHeader() throws {
        let headers = Array(tradeRepublicEnglishHeaders.dropLast())
        let detection = FinanceInstitutionDetector.detect(headers: headers, delimiter: .comma)
        let candidate = try XCTUnwrap(
            detection.candidates.first { $0.profileID == "trade-republic-english-v1" }
        )

        XCTAssertTrue(candidate.reasonCodes.contains(.missingRequiredHeader))
        XCTAssertFalse(candidate.reasonCodes.contains(.extraHeader))
    }
}
