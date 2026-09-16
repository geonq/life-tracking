import Foundation
import XCTest
@testable import LifeOS

final class FinanceStatementImporterTests: XCTestCase {
    private var bavarianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

#if DEBUG
    private func parseCSVWithLinearLexerWorkBound(_ csv: String) -> FinanceImportResult {
        let measured = FinanceStatementImporter.parseCSVForTesting(csv)
        let bound = csv.utf8.count * 256 + 100_000
        XCTAssertLessThanOrEqual(
            measured.scanUnits,
            bound,
            "scanUnits=\(measured.scanUnits), bound=\(bound), inputBytes=\(csv.utf8.count)"
        )
        return measured.result
    }
#else
    private func parseCSVWithLinearLexerWorkBound(_ csv: String) -> FinanceImportResult {
        FinanceStatementImporter.parseCSV(csv)
    }
#endif

    private func adversarialContinuationLines(count: Int, addExtraCandidateField: Bool = false) -> String {
        (0..<count)
            .map { index in
                if index.isMultiple(of: 2) {
                    let extraField = addExtraCandidateField ? ",unexpected" : ""
                    return "2026-08-02,Candidate \(index),-99.00\(extraField)"
                }
                return "continuation \(index) with \"\" escaped quote"
            }
            .joined(separator: "\n")
    }

    // MARK: 1. Valid CSV, European decimal-comma amounts + dd.MM.yyyy dates
    //
    // Real European bank exports that use comma as the decimal separator use
    // `;` as the field delimiter (comma inside an unquoted field would
    // otherwise be ambiguous CSV). This mirrors that real-world layout.

    func testParsesEuropeanDecimalCommaAmountsAndDayFirstDates() {
        let csv = """
        Datum;Beschreibung;Betrag
        14.08.2026;Supermarkt Rewe;-45,90
        01.08.2026;Gehalt;2.500,00
        """
        let result = FinanceStatementImporter.parseCSV(csv)

        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.dataRowCount, 2)
        XCTAssertTrue(result.headerRecognized)
        XCTAssertEqual(result.detectedSource, .genericCSV)
        XCTAssertEqual(result.institutionDetection.state, .unknown)
        XCTAssertNil(result.institutionDetection.institution)

        let spending = result.transactions.first { $0.description == "Supermarkt Rewe" }
        XCTAssertEqual(spending?.amountCents, -4590)
        XCTAssertTrue(spending?.isOutflow == true)

        let income = result.transactions.first { $0.description == "Gehalt" }
        XCTAssertEqual(income?.amountCents, 250_000)
        XCTAssertTrue(income?.isInflow == true)

        let components = bavarianCalendar.dateComponents([.year, .month, .day], from: spending!.bookedAt)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 14)
    }

    func testParsesRegularAndNarrowNoBreakSpaceThousandsSeparators() {
        let csv = """
        Datum;Beschreibung;Betrag
        14.08.2026;Regular grouped;1 234,56
        15.08.2026;Narrow grouped;1 234,57 EUR
        """
        let result = FinanceStatementImporter.parseCSV(csv)

        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.transactions.map(\.amountCents), [123_456, 123_457])
    }

    // MARK: 2. ISO date + plain decimal amount (English-style header)

    func testParsesISODatesAndPlainDecimalAmounts() {
        let csv = """
        date,description,amount
        2026-08-01,Coffee shop,-4.50
        2026-08-02,Refund,12.00
        """
        let result = FinanceStatementImporter.parseCSV(csv)

        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.transactions.first?.amountCents, -450)
        XCTAssertEqual(result.transactions.last?.amountCents, 1200)
    }

    func testParsesFullISO8601DatesWithFractionalSecondsAndTimezone() {
        let result = FinanceStatementImporter.parseCSV("""
        datetime,description,amount
        2026-08-01T10:15:30.123Z,UTC merchant,-4.50
        2026-08-02T11:00:00+02:00,Offset merchant,1.25
        """)

        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.transactions.map(\.amountCents), [-450, 125])
    }

    func testParsesBothEuropeanAndEnglishGroupedAmounts() {
        let european = FinanceStatementImporter.parseCSV("""
        date;description;amount
        2026-08-01;European;-1.234,56
        """)
        let english = FinanceStatementImporter.parseCSV("""
        date,description,amount
        2026-08-02,English,"1,234.56"
        """)

        XCTAssertEqual(european.transactions.first?.amountCents, -123_456)
        XCTAssertEqual(english.transactions.first?.amountCents, 123_456)
    }

    // MARK: 3. Trade Republic-style layout (semicolon delimiter, German headers)

    func testParsesTradeRepublicStyleLayout() {
        let csv = """
        Datum;Typ;Beschreibung;Betrag
        10.08.2026;Kauf;Trade Republic Order;-100,00
        11.08.2026;Zinsen;Trade Republic Zinsen;0,53
        """
        let result = FinanceStatementImporter.parseCSV(csv)

        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.detectedSource, .tradeRepublicCSV)
        XCTAssertEqual(result.transactions.first?.source, .tradeRepublicCSV)
        XCTAssertEqual(result.transactions.first?.amountCents, -10000)
        XCTAssertEqual(result.transactions.last?.amountCents, 53)
        XCTAssertEqual(result.institutionDetection.state, .known)
        XCTAssertEqual(result.institutionDetection.institution, .tradeRepublic)
        XCTAssertTrue(result.institutionDetection.provenance.legacyLayoutCompatibility)
    }

    func testTradeRepublicDividendAndInterestRemainCashIncomeEvenWithSecurityFields() {
        let result = FinanceStatementImporter.parseCSV("""
        Datum;Typ;Beschreibung;Betrag;Symbol;Anzahl;Kurs
        10.08.2026;Dividende;ETF dividend;5,00;VWCE;0,10;50,00
        11.08.2026;Zinsen;Cash interest;0,53;VWCE;1,00;0,53
        """)

        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertTrue(result.transactions.allSatisfy { !$0.isInvestmentOrder })
        XCTAssertEqual(result.investmentTransactionCount, 0)
        XCTAssertEqual(FinanceCategorizer.category(for: result.transactions[0]), .income)
        XCTAssertEqual(result.institutionDetection.state, .known)
        XCTAssertEqual(result.institutionDetection.institution, .tradeRepublic)
    }

    func testTradeRepublicInvestmentFieldsRemainOrdersAndDoNotBecomeHoldings() {
        let csv = """
        datetime,date,account_type,category,type,asset_class,name,symbol,shares,price,amount,fee,tax,currency,original_amount,original_currency,fx_rate,description,transaction_id,counterparty_name,counterparty_iban,payment_reference,mcc_code
        "2026-08-10T10:00:00","2026-08-10","checking","investment","buy","ETF","Vanguard","VWCE","1.25","100.50","-125.62","0.00","0.00","EUR","","","","Buy order","investment-1","","","","5411"
        """
        let result = FinanceStatementImporter.parseCSV(csv)

        XCTAssertEqual(result.transactions.count, 1)
        let order = try! XCTUnwrap(result.transactions.first)
        XCTAssertEqual(order.kind, .investmentOrder)
        XCTAssertEqual(order.investment?.symbol, "VWCE")
        XCTAssertEqual(order.investment?.assetClass, "ETF")
        XCTAssertEqual(order.investment?.quantity, "1.25")
        XCTAssertEqual(order.investment?.unitPriceCents, 10_050)
        XCTAssertEqual(order.providerCode, "5411")
        XCTAssertEqual(result.investmentTransactionCount, 1)
        XCTAssertEqual(result.institutionDetection.state, .known)
        XCTAssertEqual(result.institutionDetection.institution, .tradeRepublic)
    }

    // MARK: 4. Malformed/short rows are skipped and counted, not fabricated

    func testMalformedAndShortRowsAreSkippedAndCounted() {
        let csv = """
        date,description,amount
        2026-08-01,Valid row,-10.00
        not-a-date,Bad date,-5.00
        2026-08-03,Bad amount,not-a-number
        2026-08-04,Too few columns
        """
        let result = FinanceStatementImporter.parseCSV(csv)

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Valid row")
        // Two malformed rows (bad date, bad amount) plus one short row.
        XCTAssertEqual(result.skippedRowCount, 3)
        XCTAssertEqual(result.diagnostics.map(\.rowNumber), [3, 4, 5])
        XCTAssertEqual(result.diagnostics.map(\.reason), [.invalidDateOrAmount, .invalidDateOrAmount, .malformedRow])
    }

    func testMalformedGroupingAndNonEURRowsAreSkipped() {
        let csv = """
        date,description,amount,currency
        2026-08-01,Valid,"1,234.56",EUR
        2026-08-02,Bad grouping,"1,2,3.45",EUR
        2026-08-03,Foreign,-10.00,USD
        """
        let result = FinanceStatementImporter.parseCSV(csv)

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.amountCents, 123_456)
        XCTAssertEqual(result.skippedRowCount, 2)
        XCTAssertEqual(result.diagnostics.map(\.rowNumber), [3, 4])
        XCTAssertEqual(result.diagnostics.map(\.reason), [.invalidDateOrAmount, .unsupportedCurrency])
    }

    // MARK: 5. Empty input yields an empty result, not a crash

    func testEmptyInputYieldsEmptyResult() {
        let result = FinanceStatementImporter.parseCSV("")
        XCTAssertEqual(result, FinanceImportResult.empty)
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertFalse(result.headerRecognized)
    }

    func testWhitespaceOnlyInputYieldsEmptyResult() {
        let result = FinanceStatementImporter.parseCSV("   \n\n  \n")
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertEqual(result.skippedRowCount, 0)
    }

    // MARK: 6. No recognizable header: every data-shaped row is honestly skipped, none fabricated

    func testUnrecognizableHeaderSkipsAllRowsWithoutFabricating() {
        let csv = """
        foo,bar,baz
        1,2,3
        4,5,6
        """
        let result = FinanceStatementImporter.parseCSV(csv)
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertEqual(result.skippedRowCount, 3)
        XCTAssertEqual(result.dataRowCount, 3)
        XCTAssertFalse(result.headerRecognized)
        XCTAssertEqual(result.diagnostics.map(\.rowNumber), [1, 2, 3])
        XCTAssertTrue(result.diagnostics.allSatisfy { $0.reason == .unrecognizedHeader })
    }

    // MARK: 7. Missing description falls back to an honest placeholder, not fabricated merchant data

    func testMissingDescriptionColumnStillParsesAmountAndDate() {
        let csv = """
        date,amount
        2026-08-01,-10.00
        """
        let result = FinanceStatementImporter.parseCSV(csv)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Imported transaction")
    }

    // MARK: 8. Category column is honestly optional

    func testCategoryColumnIsParsedWhenPresentAndNilWhenAbsent() {
        let withCategory = FinanceStatementImporter.parseCSV("""
        date,description,amount,category
        2026-08-01,Groceries,-20.00,Food
        """)
        XCTAssertNil(withCategory.transactions.first?.category)
        XCTAssertEqual(withCategory.transactions.first?.sourceCategory, "Food")

        let withoutCategory = FinanceStatementImporter.parseCSV("""
        date,description,amount
        2026-08-01,Groceries,-20.00
        """)
        XCTAssertNil(withoutCategory.transactions.first?.category)
    }

    func testUTF16BOMAndUTF8BOMExportsAreAccepted() throws {
        let text = "date,description,amount\n2026-08-01,Apotheke,-12.50\n"
        let utf16 = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        let utf16WithBOM = Data([0xFF, 0xFE]) + utf16
        let utf16Result = try FinanceStatementImporter.parseCSV(data: utf16WithBOM)
        XCTAssertEqual(utf16Result.transactions.count, 1)
        XCTAssertEqual(utf16Result.transactions.first?.amountCents, -1250)

        let utf8WithBOM = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        let utf8Result = try FinanceStatementImporter.parseCSV(data: utf8WithBOM)
        XCTAssertEqual(utf8Result.transactions.count, 1)
    }

    func testCRLFAndQuotedFirstHeaderWithUTF8BOMAreAccepted() {
        let csv = "\u{FEFF}\"date\",\"description\",\"amount\"\r\n2026-08-01,Apotheke,-12.50\r\n"
        let result = FinanceStatementImporter.parseCSV(csv)

        XCTAssertTrue(result.headerRecognized)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Apotheke")
        XCTAssertEqual(result.transactions.first?.amountCents, -1250)
    }

    func testUTF16BOMWithQuotedHeadersIsAccepted() throws {
        let text = "\"date\",\"description\",\"amount\"\r\n2026-08-01,UTF16 merchant,-8.75\r\n"
        let utf16 = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        let result = try FinanceStatementImporter.parseCSV(data: Data([0xFF, 0xFE]) + utf16)

        XCTAssertTrue(result.headerRecognized)
        XCTAssertEqual(result.transactions.map(\.amountCents), [-875])
    }

    func testLegacyCarriageReturnLineEndingsAreAccepted() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\r2026-08-01,Legacy CR,-4.00\r"
        )

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.amountCents, -400)
    }

    func testQuotedMultilineDescriptionRemainsOneCSVRecord() {
        let result = FinanceStatementImporter.parseCSV("""
        date,description,amount
        2026-08-01,"Merchant, note\nsecond line",-12.50
        """)
        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Merchant, note\nsecond line")
    }

    func testImmediateClosingQuoteDelimiterAndNewlineRemainRecordBoundaries() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\n"
                + "2026-08-01,\"Notes\n"
                + "2026-08-02,Candidate,-99.00\n"
                + "continued\",-10.00\n"
                + "2026-08-03,Final,\"-2.50\"\n"
        )

        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.transactions.map(\.amountCents), [-1_000, -250])
        XCTAssertEqual(result.transactions.first?.description, "Notes\n2026-08-02,Candidate,-99.00\ncontinued")
        XCTAssertEqual(result.skippedRowCount, 0)
    }

    func testMalformedMiddleRecordDoesNotSwallowLaterValidRecord() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\n"
                + "2026-08-01,\"unterminated,-10.00\n"
                + "2026-08-02,Recovered,-11.00\n"
        )

        XCTAssertEqual(result.transactions.map(\.description), ["Recovered"])
        XCTAssertEqual(result.skippedRowCount, 1)
        XCTAssertEqual(result.diagnostics.map(\.rowNumber), [2])
        XCTAssertEqual(result.diagnostics.map(\.reason), [.malformedRow])
    }

    func testMalformedMiddleRecordDoesNotSwallowQuotedLaterRecord() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\n"
                + "2026-08-01,\"unterminated,-10.00\n"
                + "2026-08-02,\"Recovered\",-11.00\n"
        )

        XCTAssertEqual(result.transactions.map(\.description), ["Recovered"])
        XCTAssertEqual(result.transactions.map(\.amountCents), [-1_100])
        XCTAssertEqual(result.skippedRowCount, 1)
        XCTAssertEqual(result.diagnostics, [FinanceImportDiagnostic(rowNumber: 2, reason: .malformedRow)])
    }

    func testMalformedQuotedRecordRecoversBeforeLaterUnquotedAndQuotedRows() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\n"
                + "2026-08-01,\"unterminated,-10.00\n"
                + "2026-08-02,Recovered plain,-11.00\n"
                + "2026-08-03,\"Recovered quoted\",-12.00\n"
        )

        XCTAssertEqual(result.transactions.map(\.description), ["Recovered plain", "Recovered quoted"])
        XCTAssertEqual(result.transactions.map(\.amountCents), [-1_100, -1_200])
        XCTAssertEqual(result.dataRowCount, 3)
        XCTAssertEqual(result.skippedRowCount, 1)
        XCTAssertEqual(result.diagnostics, [FinanceImportDiagnostic(rowNumber: 2, reason: .malformedRow)])
    }

    func testMalformedRecoveryAlsoHandlesReorderedDateAndAmountColumns() {
        let result = FinanceStatementImporter.parseCSV(
            "description,amount,date\n"
                + "Broken,\"unterminated,-10.00,2026-08-01\n"
                + "Recovered,-11.00,2026-08-02\n"
        )

        XCTAssertEqual(result.transactions.map(\.description), ["Recovered"])
        XCTAssertEqual(result.skippedRowCount, 1)
        XCTAssertEqual(result.diagnostics.map(\.rowNumber), [2])
    }

    func testDateShapedMultilineDescriptionIsPreservedWhenTheQuoteCloses() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\n"
                + "2026-08-01,\"Notes\n"
                + "2026-08-02,Invented,-99.00\n"
                + "continued\",-10.00\n"
        )

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Notes\n2026-08-02,Invented,-99.00\ncontinued")
        XCTAssertEqual(result.transactions.first?.amountCents, -1000)
        XCTAssertEqual(result.skippedRowCount, 0)
    }

    func testTabDelimitedMultilineDescriptionWithClosingQuoteDelimiterRemainsOneRecord() {
        let result = FinanceStatementImporter.parseCSV(
            "date\tdescription\tamount\n"
                + "2026-08-01\t\"Notes\n"
                + "2026-08-02\tInvented\t-99.00\n"
                + "continued\"\t-10.00\n"
        )

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(
            result.transactions.first?.description,
            "Notes\n2026-08-02\tInvented\t-99.00\ncontinued"
        )
        XCTAssertEqual(result.transactions.first?.amountCents, -1_000)
        XCTAssertEqual(result.skippedRowCount, 0)
    }

    func testTabDelimitedMultilineDescriptionWithSpaceBeforeClosingDelimiterRemainsOneRecord() {
        let result = FinanceStatementImporter.parseCSV(
            "date\tdescription\tamount\n"
                + "2026-08-01\t\"Notes\n"
                + "2026-08-02\tInvented\t-99.00\n"
                + "continued\" \t-10.00\n"
        )

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(
            result.transactions.first?.description,
            "Notes\n2026-08-02\tInvented\t-99.00\ncontinued"
        )
        XCTAssertEqual(result.transactions.first?.amountCents, -1_000)
        XCTAssertEqual(result.skippedRowCount, 0)
    }

    func testUnicodeWhitespaceAfterClosingQuotePreservesMultilineRecord() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\n"
                + "2026-08-01,\"Notes\n"
                + "2026-08-02,Invented,-99.00\n"
                + "continued\"\u{2003},-10.00\n"
        )

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(
            result.transactions.first?.description,
            "Notes\n2026-08-02,Invented,-99.00\ncontinued"
        )
        XCTAssertEqual(result.transactions.first?.amountCents, -1_000)
        XCTAssertEqual(result.skippedRowCount, 0)
    }

    func testEscapedQuoteInValidMultilineDescriptionRemainsOneCSVRecord() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\n"
                + "2026-08-01,\"Notes\n"
                + "2026-08-02,\"\",-99.00\n"
                + "continued\",-10.00\n"
        )

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Notes\n2026-08-02,\",-99.00\ncontinued")
        XCTAssertEqual(result.transactions.first?.amountCents, -1_000)
        XCTAssertEqual(result.skippedRowCount, 0)
    }

    func testLargeQuotedMultilineDescriptionRemainsOneRecord() {
        // Deterministic scaling regression for the cached linear lexer.
        for continuationCount in [256, 1_024, 3_000] {
            let continuationLines = (0..<continuationCount)
                .map { "continuation \($0)" }
                .joined(separator: "\n")
            let result = parseCSVWithLinearLexerWorkBound(
                "date,description,amount\n"
                    + "2026-08-01,\"Opening\n"
                    + continuationLines
                    + "\",-10.00"
            )

            XCTAssertEqual(result.transactions.count, 1, "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.skippedRowCount, 0, "continuationCount=\(continuationCount)")
            XCTAssertEqual(
                result.transactions.first?.description.components(separatedBy: "\n").count,
                continuationCount + 1,
                "continuationCount=\(continuationCount)"
            )
            XCTAssertEqual(result.transactions.first?.amountCents, -1_000, "continuationCount=\(continuationCount)")
        }
    }

    func testLargeCandidateLikeMultilineDescriptionRemainsOneRecord() {
        // These continuation lines are valid rows at the header-derived date
        // and amount positions. The quoted empty field in alternating lines
        // is escaped for the surrounding description and remains valid to
        // the candidate row parser.
        for continuationCount in [256, 1_024, 3_000] {
            let continuationLines = (0..<continuationCount)
                .map { index -> String in
                    let day = (index % 28) + 2
                    let date = "2026-08-" + (day < 10 ? "0" : "") + String(day)
                    if index.isMultiple(of: 2) {
                        return "\(date),ordinary \(index),-99.00"
                    }
                    let escapedQuotedField = String(repeating: "\"", count: 2)
                    return "\(date),\(escapedQuotedField),-99.00"
                }
                .joined(separator: "\n")
            let expectedDescription = (0..<continuationCount)
                .map { index -> String in
                    let day = (index % 28) + 2
                    let date = "2026-08-" + (day < 10 ? "0" : "") + String(day)
                    if index.isMultiple(of: 2) {
                        return "\(date),ordinary \(index),-99.00"
                    }
                    return "\(date),\",-99.00"
                }
                .joined(separator: "\n")
            let result = parseCSVWithLinearLexerWorkBound(
                "date,description,amount\n"
                    + "2026-08-01,\"Opening\n"
                    + continuationLines
                    + "\",-10.00"
            )

            XCTAssertEqual(result.transactions.count, 1, "continuationCount=\(continuationCount)")
            XCTAssertEqual(
                result.transactions.first?.description,
                "Opening\n" + expectedDescription,
                "continuationCount=\(continuationCount)"
            )
            XCTAssertEqual(result.transactions.first?.amountCents, -1_000, "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.skippedRowCount, 0, "continuationCount=\(continuationCount)")
        }
    }

    func testUnmatchedQuoteAtEOFIsRejectedWithoutFabricatingATransaction() {
        let result = FinanceStatementImporter.parseCSV(
            "date,description,amount\n2026-08-01,\"unterminated,-10.00"
        )

        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertEqual(result.skippedRowCount, 1)
        XCTAssertEqual(result.diagnostics, [FinanceImportDiagnostic(rowNumber: 2, reason: .malformedRow)])
    }

    func testMalformedQuotedRecordRecoversValidRowBeforeEOFMalformedContinuation() {
        for suffix in ["", "\n"] {
            let result = FinanceStatementImporter.parseCSV(
                "date,description,amount\n"
                    + "2026-08-01,\"unterminated,-10.00\n"
                    + "2026-08-02,Recovered plain,-11.00\n"
                    + ",\"unterminated"
                    + suffix
            )

            XCTAssertEqual(result.transactions.map(\.description), ["Recovered plain"], "suffix=\(suffix.debugDescription)")
            XCTAssertEqual(result.transactions.map(\.amountCents), [-1_100], "suffix=\(suffix.debugDescription)")
            XCTAssertEqual(result.dataRowCount, 3, "suffix=\(suffix.debugDescription)")
            XCTAssertEqual(result.skippedRowCount, 2, "suffix=\(suffix.debugDescription)")
            XCTAssertEqual(
                result.diagnostics,
                [
                    FinanceImportDiagnostic(rowNumber: 2, reason: .malformedRow),
                    FinanceImportDiagnostic(rowNumber: 4, reason: .malformedRow)
                ],
                "suffix=\(suffix.debugDescription)"
            )
        }
    }

    func testMeteredEOFRecoveryRetainsValidMiddleRowsAtExpectedLinearBound() {
        for middleRowCount in [256, 1_024, 3_000] {
            let middleRows = (0..<middleRowCount)
                .map { index in
                    "2026-08-02,Recovered \(index),-11.00"
                }
                .joined(separator: "\n")
            let result = parseCSVWithLinearLexerWorkBound(
                "date,description,amount\n"
                    + "2026-08-01,\"unterminated,-10.00\n"
                    + middleRows
                    + "\n,\"unterminated"
            )

            XCTAssertEqual(result.transactions.count, middleRowCount, "middleRowCount=\(middleRowCount)")
            XCTAssertEqual(
                result.transactions.map(\.description),
                (0..<middleRowCount).map { "Recovered \($0)" },
                "middleRowCount=\(middleRowCount)"
            )
            XCTAssertEqual(
                result.transactions.map(\.amountCents),
                Array(repeating: -1_100, count: middleRowCount),
                "middleRowCount=\(middleRowCount)"
            )
            XCTAssertEqual(result.dataRowCount, middleRowCount + 2, "middleRowCount=\(middleRowCount)")
            XCTAssertEqual(result.skippedRowCount, 2, "middleRowCount=\(middleRowCount)")
            XCTAssertEqual(
                result.diagnostics,
                [
                    FinanceImportDiagnostic(rowNumber: 2, reason: .malformedRow),
                    FinanceImportDiagnostic(rowNumber: middleRowCount + 3, reason: .malformedRow)
                ],
                "middleRowCount=\(middleRowCount)"
            )
        }
    }

    func testLargeUnterminatedQuotedInputIsOneMalformedRow() {
        // Deterministic scaling regression for the cached linear lexer.
        for continuationCount in [256, 1_024, 3_000] {
            let continuationLines = adversarialContinuationLines(
                count: continuationCount,
                addExtraCandidateField: true
            )
            let result = parseCSVWithLinearLexerWorkBound(
                "date,description,amount\n"
                    + "2026-08-01,\"unterminated,-10.00\n"
                    + continuationLines
            )

            XCTAssertTrue(result.transactions.isEmpty, "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.dataRowCount, 1, "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.skippedRowCount, 1, "continuationCount=\(continuationCount)")
            XCTAssertEqual(
                result.diagnostics,
                [FinanceImportDiagnostic(rowNumber: 2, reason: .malformedRow)],
                "continuationCount=\(continuationCount)"
            )
        }
    }

    func testMalformedQuotedRecordRetainsManyUnquotedRowsBeforeFinalQuotedRow() {
        for continuationCount in [256, 1_024, 3_000] {
            let middleRows = (0..<continuationCount)
                .map { index in
                    "2026-08-02,Recovered \(index),-11.00"
                }
                .joined(separator: "\n")
            let result = parseCSVWithLinearLexerWorkBound(
                "date,description,amount\n"
                    + "2026-08-01,\"unterminated,-10.00\n"
                    + middleRows
                    + "\n2026-08-03,\"Recovered quoted\",-12.00\n"
            )

            XCTAssertEqual(result.transactions.count, continuationCount + 1, "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.transactions.first?.description, "Recovered 0", "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.transactions.last?.description, "Recovered quoted", "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.transactions.first?.amountCents, -1_100, "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.transactions.last?.amountCents, -1_200, "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.dataRowCount, continuationCount + 2, "continuationCount=\(continuationCount)")
            XCTAssertEqual(result.skippedRowCount, 1, "continuationCount=\(continuationCount)")
            XCTAssertEqual(
                result.diagnostics,
                [FinanceImportDiagnostic(rowNumber: 2, reason: .malformedRow)],
                "continuationCount=\(continuationCount)"
            )
        }
    }

    func testQuotedFinalAmountWithUnicodeWhitespaceBeforeNewlineOrEOFIsImported() {
        for suffix in ["\u{2003}\n", "\u{2003}"] {
            let result = FinanceStatementImporter.parseCSV(
                "date,description,amount\n2026-08-01,Final amount,\"-10.00\"\(suffix)"
            )

            XCTAssertEqual(result.transactions.count, 1, "suffix=\(suffix.debugDescription)")
            XCTAssertEqual(result.transactions.first?.description, "Final amount", "suffix=\(suffix.debugDescription)")
            XCTAssertEqual(result.transactions.first?.amountCents, -1_000, "suffix=\(suffix.debugDescription)")
            XCTAssertEqual(result.skippedRowCount, 0, "suffix=\(suffix.debugDescription)")
        }
    }

    func testUnsupportedTradeRepublicNearMatchesAreBlockedBeforeGenericParsing() {
        let fullHeaders = [
            "datetime", "date", "account_type", "category", "type", "asset_class",
            "name", "symbol", "shares", "price", "amount", "fee", "tax", "currency",
            "original_amount", "original_currency", "fx_rate", "description", "transaction_id",
            "counterparty_name", "counterparty_iban", "payment_reference", "mcc_code"
        ]
        let missingCurrency = fullHeaders.filter { $0 != "currency" }
        let extraHeader = fullHeaders + ["unexpected"]
        let cases: [(headers: [String], delimiter: String)] = [
            (missingCurrency, ","),
            (extraHeader, ","),
            (fullHeaders, ";")
        ]

        for item in cases {
            let header = item.headers.joined(separator: item.delimiter)
            let row = Array(repeating: "", count: item.headers.count)
                .enumerated()
                .map { index, _ in
                    switch item.headers[index] {
                    case "datetime": return "2026-08-01T10:00:00"
                    case "date": return "2026-08-01"
                    case "amount": return "-10.00"
                    default: return ""
                    }
                }
                .joined(separator: item.delimiter)
            let result = FinanceStatementImporter.parseCSV(header + "\n" + row)

            XCTAssertTrue(result.transactions.isEmpty, "case should be blocked: \(item.headers.count)/\(item.delimiter)")
            XCTAssertEqual(result.institutionDetection.state, .unknown)
            XCTAssertTrue(result.institutionDetection.provenance.reasonCodes.contains(.unsupportedNearMatch))
        }

        let securityHeaders = ["Datum", "Typ", "Beschreibung", "Betrag", "Symbol", "Anzahl", "Kurs", "Gebühr"]
        let securityRow = ["14.08.2026", "Kauf", "ETF order", "-100,00", "VWCE", "1", "100,00", "0,00"]
        let securityResult = FinanceStatementImporter.parseCSV(
            securityHeaders.joined(separator: ";") + "\n" + securityRow.joined(separator: ";")
        )
        XCTAssertTrue(securityResult.transactions.isEmpty)
        XCTAssertTrue(securityResult.institutionDetection.provenance.reasonCodes.contains(.unsupportedNearMatch))
    }

    func testDisabledBrokerageMarkerProfilesNeverFallThroughToGenericCashParsing() {
        let cases: [(headers: [String], institution: FinanceInstitution, profileID: String)] = [
            (["Activity Date", "Trans Code", "Net Amount", "date", "description", "netto"], .robinhood, "robinhood-disabled-v1"),
            (["Buchungstag", "Umsatz", "date", "description", "netto"], .sparkasse, "sparkasse-disabled-v1")
        ]

        for item in cases {
            let row = item.headers.map { header in
                switch header {
                case "date": "2026-08-01"
                case "description": "Payment"
                case "netto": "-10.00"
                default: ""
                }
            }
            let result = FinanceStatementImporter.parseCSV(
                item.headers.joined(separator: ",") + "\n" + row.joined(separator: ",")
            )

            XCTAssertTrue(result.transactions.isEmpty, "case should be blocked: \(item.institution)")
            XCTAssertEqual(result.institutionDetection.institution, nil)
            XCTAssertEqual(result.institutionDetection.profileID, item.profileID)
            XCTAssertEqual(result.institutionDetection.provenance.reasonCodes, [.disabledProfile])
        }

        let revolutHeaders = ["Completed Date", "Amount", "Currency", "State", "date", "description", "netto"]
        let revolutRow = revolutHeaders.map { header in
            switch header {
            case "Completed Date", "date": "2026-08-01"
            case "Amount", "netto": "-10.00"
            case "Currency": "EUR"
            case "State": "COMPLETED"
            case "description": "Payment"
            default: ""
            }
        }
        let revolutResult = FinanceStatementImporter.parseCSV(
            revolutHeaders.joined(separator: ",") + "\n" + revolutRow.joined(separator: ",")
        )
        XCTAssertTrue(revolutResult.transactions.isEmpty)
        XCTAssertEqual(revolutResult.skippedRowCount, 1)
        XCTAssertEqual(revolutResult.institutionDetection.institution, nil)
        XCTAssertEqual(revolutResult.institutionDetection.profileID, "revolut-disabled-v1")
        XCTAssertEqual(revolutResult.institutionDetection.provenance.reasonCodes, [.disabledProfile])

        let controlResult = FinanceStatementImporter.parseCSV(
            "date,description,amount\n2026-08-01,Payment,-10.00"
        )
        XCTAssertEqual(controlResult.transactions.count, 1)
        XCTAssertEqual(controlResult.transactions.first?.description, "Payment")
        XCTAssertEqual(controlResult.transactions.first?.amountCents, -1_000)
    }

    func testParsingSameCSVProducesStableIDs() {
        let csv = "date,description,amount\n2026-08-01,Rewe,-12.50\n"
        let first = FinanceStatementImporter.parseCSV(csv)
        let second = FinanceStatementImporter.parseCSV(csv)
        XCTAssertEqual(first.transactions.map(\.id), second.transactions.map(\.id))
    }

    func testHistoricalUUIDGoldensRemainStableAcrossDetectorChanges() {
        let germanMinimal = FinanceStatementImporter.parseCSV("""
        Datum;Beschreibung;Betrag
        14.08.2026;Supermarkt Rewe;-45,90
        """)
        let tradeRepublicGermanLegacy = FinanceStatementImporter.parseCSV("""
        Datum;Typ;Beschreibung;Betrag
        14.08.2026;Karte;Supermarkt Rewe;-45,90
        """)
        let tradeRepublicGermanSecurity = FinanceStatementImporter.parseCSV("""
        Datum;Typ;Beschreibung;Betrag;Symbol;Anzahl;Kurs
        14.08.2026;Kauf;Supermarkt Rewe;-45,90;VWCE;1;45,90
        """)
        let duplicateGerman = FinanceStatementImporter.parseCSV("""
        Datum;Beschreibung;Betrag
        14.08.2026;Supermarkt Rewe;-45,90
        14.08.2026;Supermarkt Rewe;-45,90
        """)
        let genericEnglishWithProviderID = FinanceStatementImporter.parseCSV("""
        date,description,amount,transaction_id
        2026-08-01,Rewe,-12.50,provider-1
        """)
        let genericReordered = FinanceStatementImporter.parseCSV("""
        account,amount,category,description,date
        Main,-12.50,Groceries,Rewe,2026-08-01
        Main,-12.50,Groceries,Rewe,2026-08-01
        """)
        let tradeRepublicEnglish = FinanceStatementImporter.parseCSV("""
        datetime,date,account_type,category,type,asset_class,name,symbol,shares,price,amount,fee,tax,currency,original_amount,original_currency,fx_rate,description,transaction_id,counterparty_name,counterparty_iban,payment_reference,mcc_code
        "2025-06-07T10:15:00","2025-06-07","checking","card","payment_outbound","","REWE SAGT DANKE FIL.1234","","","","-23.450000","0.000000","0.000000","EUR","","","","TR Card Transaction","tid-1","","","",""
        """)

        // These are literal UUIDs from the pre-detector importer algorithm for
        // synthetic rows. Candidate-vs-itself equality would not catch a
        // source, field, or ordinal change that breaks re-import reconciliation.
        // The old importer intentionally treated any Datum+Betrag header as
        // Trade Republic, even when the detector now reports a minimal
        // three-column German file as unknown.
        XCTAssertEqual(germanMinimal.transactions.first?.id, UUID(uuidString: "5cf6697f-8641-63c6-50a0-88830e744e42"))
        XCTAssertEqual(tradeRepublicGermanLegacy.transactions.first?.id, UUID(uuidString: "5cf6697f-8641-63c6-50a0-88830e744e42"))
        XCTAssertEqual(tradeRepublicGermanSecurity.transactions.first?.id, UUID(uuidString: "5cf6697f-8641-63c6-50a0-88830e744e42"))
        XCTAssertEqual(duplicateGerman.transactions.map(\.id), [
            UUID(uuidString: "5cf6697f-8641-63c6-50a0-88830e744e42"),
            UUID(uuidString: "51bde504-a3f1-0d6a-5ea0-5a1710420e21")
        ])
        XCTAssertEqual(genericEnglishWithProviderID.transactions.first?.id, UUID(uuidString: "59cf0e29-82b7-1a88-2f16-b85f3ee93109"))
        XCTAssertEqual(genericReordered.transactions.map(\.id), [
            UUID(uuidString: "5d5aac04-8458-e309-e318-7c1e21f4771f"),
            UUID(uuidString: "571006d6-96a0-2055-25f5-c24541e5b669")
        ])
        XCTAssertEqual(tradeRepublicEnglish.transactions.first?.id, UUID(uuidString: "5a8d56c0-8d28-2f8a-ad19-15972027a4df"))
    }

    func testHistoricalDateAliasKeepsPreDetectorColumnPrecedence() {
        let result = FinanceStatementImporter.parseCSV("""
        Booking-Date,date,description,amount
        not-a-date,2026-08-01,Preferred,-10.00
        """)

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Preferred")
        XCTAssertEqual(result.transactions.first?.id, UUID(uuidString: "519adff0-af7d-53de-bd8d-d6785b3595da"))
    }

    func testEnglishTradeRepublicRequiresNonemptyEURCurrency() {
        let headers = tradeRepublicRealExportHeader.split(separator: ",").map(String.init)
        func row(currency: String, description: String) -> String {
            headers.map { header in
                switch header {
                case "datetime": return "2026-08-01T10:00:00"
                case "date": return "2026-08-01"
                case "amount": return "-10.00"
                case "currency": return currency
                case "description": return description
                default: return ""
                }
            }.joined(separator: ",")
        }

        let result = FinanceStatementImporter.parseCSV([
            tradeRepublicRealExportHeader,
            row(currency: "", description: "Missing currency"),
            row(currency: "USD", description: "Unsupported currency"),
            row(currency: "EUR", description: "Accepted currency")
        ].joined(separator: "\n"))

        XCTAssertEqual(result.transactions.map(\.description), ["Accepted currency"])
        XCTAssertEqual(result.skippedRowCount, 2)
        XCTAssertEqual(result.diagnostics.map(\.reason), [.unsupportedCurrency, .unsupportedCurrency])
        XCTAssertEqual(result.institutionDetection.state, .known)
        XCTAssertEqual(result.institutionDetection.institution, .tradeRepublic)
    }

    func testParenthesizedAmountIsNegative() {
        let result = FinanceStatementImporter.parseCSV("""
        date,description,amount
        2026-08-01,Refund adjustment,(12.50)
        """)
        XCTAssertEqual(result.transactions.first?.amountCents, -1250)
    }

    func testPreambleDoesNotStealDelimiterFromSemicolonHeader() {
        let result = FinanceStatementImporter.parseCSV("""
        Export generated, account metadata
        Datum;Beschreibung;Betrag
        14.08.2026;Preamble-safe merchant;12,50
        """)

        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Preamble-safe merchant")
        XCTAssertEqual(result.transactions.first?.amountCents, 1250)
    }

    func testTabDelimitedAndTrailingNegativeAmountAreAccepted() {
        let result = FinanceStatementImporter.parseCSV("""
        date\tdescription\tamount
        2026-08-01\tTab merchant\t12,50-
        """)

        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.amountCents, -1250)
    }

    func testFractionalCentIsRejectedInsteadOfRounded() {
        let result = FinanceStatementImporter.parseCSV("""
        date,description,amount
        2026-08-01,Precise,-12.345
        2026-08-02,Trailing zero,-12.340
        """)

        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.skippedRowCount, 1)
        XCTAssertEqual(result.transactions.first?.amountCents, -1234)
    }

    func testStableIDsIgnoreHeaderOrderAndPreserveDuplicateMultiset() {
        let first = FinanceStatementImporter.parseCSV("""
        date,description,amount,category,account
        2026-08-01,Rewe,-12.50,Groceries,Main
        2026-08-01,Rewe,-12.50,Groceries,Main
        """)
        let reordered = FinanceStatementImporter.parseCSV("""
        account,amount,category,description,date
        Main,-12.50,Groceries,Rewe,2026-08-01
        Main,-12.50,Groceries,Rewe,2026-08-01
        """)

        XCTAssertEqual(Set(first.transactions.map(\.id)), Set(reordered.transactions.map(\.id)))
    }

    func testProviderTransactionIDWinsOverRowPosition() {
        let first = FinanceStatementImporter.parseCSV("""
        date,description,amount,transaction_id
        2026-08-01,Rewe,-12.50,provider-1
        """)
        let reordered = FinanceStatementImporter.parseCSV("""
        transaction_id,amount,description,date
        provider-1,-12.50,Rewe,2026-08-01
        """)

        XCTAssertEqual(first.transactions.map(\.id), reordered.transactions.map(\.id))
    }

    // MARK: 9. Real Trade Republic 23-column export: merchant (`name`) wins
    // over the generic `description` column for card purchases; transfers
    // (empty `name`) fall back to the meaningful `description`. All values
    // below are synthetic/fabricated for this test — not real statement data.

    private let tradeRepublicRealExportHeader =
        "datetime,date,account_type,category,type,asset_class,name,symbol,shares,price,amount,fee,tax,currency,original_amount,original_currency,fx_rate,description,transaction_id,counterparty_name,counterparty_iban,payment_reference,mcc_code"

    private func tradeRepublicRealExportCSV() -> String {
        let cardPurchase = """
        "2025-06-07T10:15:00","2025-06-07","checking","card","payment_outbound","","REWE SAGT DANKE FIL.1234","","","","-23.450000","0.000000","0.000000","EUR","","","","TR Card Transaction","tid-1","","","",""
        """
        let subscription = """
        "2025-06-08T09:00:00","2025-06-08","checking","card","payment_outbound","","Spotify","","","","-9.990000","0.000000","0.000000","EUR","","","","TR Card Transaction","tid-2","","","",""
        """
        let inboundTransfer = """
        "2025-06-09T12:00:00","2025-06-09","checking","transfer","transfer_inbound","","","","","","500.000000","0.000000","0.000000","EUR","","","","Incoming transfer from A B","tid-3","","","",""
        """
        let internationalCard = """
        "2025-06-10T18:30:00","2025-06-10","checking","card","payment_outbound","","ALLCHINABUY.COM","","","","-59.280000","0.000000","0.000000","EUR","-67.40","USD","","TR Card Transaction","tid-4","","","",""
        """
        return ([tradeRepublicRealExportHeader, cardPurchase, subscription, inboundTransfer, internationalCard])
            .joined(separator: "\n")
    }

    func testTradeRepublicRealExportUsesNameColumnAsMerchantForCardPurchases() {
        let result = FinanceStatementImporter.parseCSV(tradeRepublicRealExportCSV())

        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.transactions.count, 4)

        let grocery = result.transactions.first { $0.description == "REWE SAGT DANKE FIL.1234" }
        XCTAssertEqual(grocery?.amountCents, -2345)
        XCTAssertEqual(
            FinanceCategorizer.category(for: grocery?.description ?? "", amountCents: grocery?.amountCents ?? 0),
            .groceries
        )

        let subscription = result.transactions.first { $0.description == "Spotify" }
        XCTAssertEqual(subscription?.amountCents, -999)
        XCTAssertEqual(
            FinanceCategorizer.category(for: subscription?.description ?? "", amountCents: subscription?.amountCents ?? 0),
            .subscriptions
        )
    }

    func testTradeRepublicRealExportFallsBackToDescriptionForTransfersWithEmptyName() {
        let result = FinanceStatementImporter.parseCSV(tradeRepublicRealExportCSV())

        let transfer = result.transactions.first { $0.amountCents == 50_000 }
        XCTAssertEqual(transfer?.description, "Incoming transfer from A B")
    }

    func testTradeRepublicRealExportUsesEURAmountNotOriginalCurrencyForInternationalCardTxn() {
        let result = FinanceStatementImporter.parseCSV(tradeRepublicRealExportCSV())

        let international = result.transactions.first { $0.description == "ALLCHINABUY.COM" }
        XCTAssertEqual(international?.amountCents, -5928)
    }
}
