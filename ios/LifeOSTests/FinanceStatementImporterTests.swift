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
    }

    // MARK: 5. Empty input yields an empty result, not a crash

    func testEmptyInputYieldsEmptyResult() {
        let result = FinanceStatementImporter.parseCSV("")
        XCTAssertEqual(result, FinanceImportResult.empty)
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertEqual(result.skippedRowCount, 0)
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
        XCTAssertEqual(withCategory.transactions.first?.category, "Food")

        let withoutCategory = FinanceStatementImporter.parseCSV("""
        date,description,amount
        2026-08-01,Groceries,-20.00
        """)
        XCTAssertNil(withoutCategory.transactions.first?.category)
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
