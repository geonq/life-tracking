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
}
