import Foundation
import XCTest
@testable import LifeOS

final class FinanceStatementImporterTests: XCTestCase {
    private var bavarianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
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

    func testQuotedMultilineDescriptionRemainsOneCSVRecord() {
        let result = FinanceStatementImporter.parseCSV("""
        date,description,amount
        2026-08-01,"Merchant, note\nsecond line",-12.50
        """)
        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions.first?.description, "Merchant, note\nsecond line")
    }

    func testParsingSameCSVProducesStableIDs() {
        let csv = "date,description,amount\n2026-08-01,Rewe,-12.50\n"
        let first = FinanceStatementImporter.parseCSV(csv)
        let second = FinanceStatementImporter.parseCSV(csv)
        XCTAssertEqual(first.transactions.map(\.id), second.transactions.map(\.id))
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
