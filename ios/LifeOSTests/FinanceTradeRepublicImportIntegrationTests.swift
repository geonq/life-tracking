import Foundation
import XCTest
@testable import LifeOS

/// Integration coverage for acceptance row PC-04: Trade Republic manual CSV
/// import end to end — parser -> durable store -> readback. Unlike the
/// parser-only unit tests in `FinanceStatementImporterTests`, every test here
/// drives `FinanceStatementImporter.parseCSV` output through a real
/// `FinanceImportedTransactionStore` backed by a temp file and reads it back,
/// proving the full pipeline rather than just the parser in isolation.
final class FinanceTradeRepublicImportIntegrationTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-tr-import-integration-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("finance-imported-transactions.json", isDirectory: false)
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Fixtures — German Trade Republic layout, newest-row-first (as TR
    // actually exports). All values are synthetic, not real statement data.

    /// Rows 07/06/05 June, newest first — the state of the account the first
    /// time the statement was downloaded.
    private let germanStatementInitial = """
    Datum;Typ;Beschreibung;Betrag
    07.06.2026;Dividende;ETF Ausschüttung VWCE;5,32
    06.06.2026;Zahlung;Restaurant Zur Post;-18,90
    05.06.2026;Zahlung;REWE SAGT DANKE FIL.1234;-23,45
    """

    /// The same account re-downloaded later: two genuinely new, newer rows
    /// (09/08 June) prepended ahead of the unchanged 07/06/05 rows — the
    /// ordinary real-world reimport case.
    private let germanStatementExtended = """
    Datum;Typ;Beschreibung;Betrag
    09.06.2026;Zahlung;Gehalt Eingang;2500,00
    08.06.2026;Zahlung;Apotheke Muster;-12,00
    07.06.2026;Dividende;ETF Ausschüttung VWCE;5,32
    06.06.2026;Zahlung;Restaurant Zur Post;-18,90
    05.06.2026;Zahlung;REWE SAGT DANKE FIL.1234;-23,45
    """

    private let englishHeader =
        "datetime,date,account_type,category,type,asset_class,name,symbol,shares,price,amount,fee,tax,currency,original_amount,original_currency,fx_rate,description,transaction_id,counterparty_name,counterparty_iban,payment_reference,mcc_code"

    // MARK: 1. Parser — both layouts, end to end

    func testGermanLayoutEndToEndImportPersistsWithCorrectShapeAndCategories() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        let parsed = FinanceStatementImporter.parseCSV(germanStatementInitial)
        XCTAssertEqual(parsed.skippedRowCount, 0)
        XCTAssertEqual(parsed.transactions.count, 3)
        XCTAssertEqual(parsed.detectedSource, .tradeRepublicCSV)

        try store.add(parsed.transactions)
        let stored = try store.all()
        XCTAssertEqual(stored.count, 3)

        let grocery = try XCTUnwrap(stored.first { $0.description == "REWE SAGT DANKE FIL.1234" })
        XCTAssertEqual(grocery.amountCents, -2345)
        XCTAssertEqual(FinanceCategorizer.category(for: grocery), .groceries)

        let dividend = try XCTUnwrap(stored.first { $0.description == "ETF Ausschüttung VWCE" })
        XCTAssertEqual(dividend.amountCents, 532)
        XCTAssertFalse(dividend.isInvestmentOrder)
        XCTAssertEqual(FinanceCategorizer.category(for: dividend), .income)
    }

    func testEnglishLayoutEndToEndImportPersistsWithProvenanceAndInvestmentKind() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        let csv = """
        \(englishHeader)
        "2026-06-10T10:00:00","2026-06-10","checking","investment","buy","ETF","Vanguard","VWCE","1.25","100.50","-125.62","0.00","0.00","EUR","","","","Buy order","order-1","","","","5411"
        "2026-06-11T09:00:00","2026-06-11","checking","card","payment_outbound","","Spotify","","","","-9.990000","0.000000","0.000000","EUR","","","","TR Card Transaction","tid-2","","","",""
        """
        let parsed = FinanceStatementImporter.parseCSV(csv)
        XCTAssertEqual(parsed.skippedRowCount, 0)
        XCTAssertEqual(parsed.transactions.count, 2)
        XCTAssertEqual(parsed.detectedSource, .tradeRepublicCSV)

        try store.add(parsed.transactions)
        let stored = try store.all()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.source == .tradeRepublicCSV })

        let order = try XCTUnwrap(stored.first { $0.description == "Vanguard" })
        XCTAssertTrue(order.isInvestmentOrder)
        XCTAssertEqual(order.investment?.symbol, "VWCE")
        XCTAssertEqual(FinanceCategorizer.category(for: order), .investments)

        let subscription = try XCTUnwrap(stored.first { $0.description == "Spotify" })
        XCTAssertFalse(subscription.isInvestmentOrder)
        XCTAssertEqual(FinanceCategorizer.category(for: subscription), .subscriptions)
    }

    // MARK: 2. Provenance — a manual import can never be presented as
    // connected-account or as Trade Republic data it did not come from.

    func testGenericCSVNeverCarriesTradeRepublicProvenanceEvenWhenContentMentionsIt() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        // Plain generic-bank layout. The description names "Trade Republic"
        // as a merchant, which must not leak into layout-based provenance
        // detection — provenance is about the CSV's column layout, not its
        // row content.
        let csv = """
        date,description,amount
        2026-06-01,Transfer to Trade Republic,-500.00
        """
        let parsed = FinanceStatementImporter.parseCSV(csv)
        XCTAssertEqual(parsed.detectedSource, .genericCSV)
        XCTAssertEqual(parsed.transactions.first?.source, .genericCSV)

        try store.add(parsed.transactions)
        let stored = try store.all()
        XCTAssertEqual(stored.first?.source, .genericCSV)
        XCTAssertNotEqual(stored.first?.source, .tradeRepublicCSV)
    }

    func testTradeRepublicProvenanceSurvivesStoreRoundTrip() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        let parsed = FinanceStatementImporter.parseCSV(germanStatementInitial)
        try store.add(parsed.transactions)

        // A fresh store instance over the same file simulates the next app
        // launch — provenance must be read back from disk, not re-derived.
        let relaunched = try FinanceImportedTransactionStore(url: url)
        let stored = try relaunched.all()
        XCTAssertEqual(stored.count, 3)
        XCTAssertTrue(stored.allSatisfy { $0.source == .tradeRepublicCSV })
    }

    // MARK: 3. Duplicates — reimporting the same statement must not double-count.

    func testReimportingIdenticalGermanStatementDoesNotDoubleCount() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        let parsed = FinanceStatementImporter.parseCSV(germanStatementInitial)
        let firstResult = try store.add(parsed.transactions)
        XCTAssertEqual(firstResult.insertedCount, 3)
        XCTAssertEqual(firstResult.duplicateCount, 0)

        // Re-import the exact same statement (the user re-uploads the file
        // they already imported).
        let reparsed = FinanceStatementImporter.parseCSV(germanStatementInitial)
        let secondResult = try store.add(reparsed.transactions)
        XCTAssertEqual(secondResult.insertedCount, 0)
        XCTAssertEqual(secondResult.updatedCount, 0)
        XCTAssertEqual(secondResult.duplicateCount, 3)

        let stored = try store.all()
        XCTAssertEqual(stored.count, 3)
    }

    // MARK: 4. Reimport — an overlapping-but-extended statement adds only
    // the genuinely new rows.

    func testReimportingExtendedStatementAddsOnlyGenuinelyNewRows() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        let initial = FinanceStatementImporter.parseCSV(germanStatementInitial)
        let firstResult = try store.add(initial.transactions)
        XCTAssertEqual(firstResult.insertedCount, 3)
        XCTAssertEqual(try store.all().count, 3)

        // Re-download later: the account now shows two newer rows ahead of
        // the three already-imported ones.
        let extended = FinanceStatementImporter.parseCSV(germanStatementExtended)
        XCTAssertEqual(extended.transactions.count, 5)
        let secondResult = try store.add(extended.transactions)

        XCTAssertEqual(secondResult.insertedCount, 2, "only the two genuinely new rows should be inserted")
        XCTAssertEqual(secondResult.duplicateCount, 3, "the three already-imported rows must be recognized as duplicates")
        XCTAssertEqual(secondResult.updatedCount, 0)

        let stored = try store.all()
        XCTAssertEqual(stored.count, 5)
        XCTAssertTrue(stored.contains { $0.description == "Gehalt Eingang" })
        XCTAssertTrue(stored.contains { $0.description == "Apotheke Muster" })
        XCTAssertEqual(stored.filter { $0.description == "REWE SAGT DANKE FIL.1234" }.count, 1)
    }

    // MARK: 5. Reconciliation — a corrected re-import (same provider
    // transaction id, corrected fields) updates in place; an unchanged row
    // reconciles to exactly one stored row; totals never drift.

    func testReconciliationUpdatesCorrectedRowByProviderTransactionIDWithoutDuplicating() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        let original = FinanceStatementImporter.parseCSV("""
        \(englishHeader)
        "2026-06-12T08:00:00","2026-06-12","checking","card","payment_outbound","","Some Merchant","","","","-20.500000","0.000000","0.000000","EUR","","","","TR Card Transaction","tid-100","","","",""
        """)
        try store.add(original.transactions)
        let afterOriginal = try store.all()
        XCTAssertEqual(afterOriginal.count, 1)
        XCTAssertEqual(afterOriginal.first?.amountCents, -2050)

        // Provider issues a corrected export for the same transaction id:
        // amount was mis-posted and is now corrected.
        let corrected = FinanceStatementImporter.parseCSV("""
        \(englishHeader)
        "2026-06-12T08:00:00","2026-06-12","checking","card","payment_outbound","","Some Merchant","","","","-25.750000","0.000000","0.000000","EUR","","","","TR Card Transaction","tid-100","","","",""
        """)
        let result = try store.add(corrected.transactions)
        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.duplicateCount, 0)

        let stored = try store.all()
        XCTAssertEqual(stored.count, 1, "a source correction must reconcile in place, not add a second row")
        XCTAssertEqual(stored.first?.amountCents, -2575)
    }

    func testCentTotalsNeverDriftAcrossReimportOfUnchangedStatement() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        let parsed = FinanceStatementImporter.parseCSV(germanStatementInitial)
        try store.add(parsed.transactions)
        let totalsBefore = FinanceCategorizer.totals(for: try store.all())

        // Reimporting the identical statement twice more must never move the
        // stored cent totals.
        try store.add(FinanceStatementImporter.parseCSV(germanStatementInitial).transactions)
        try store.add(FinanceStatementImporter.parseCSV(germanStatementInitial).transactions)
        let totalsAfter = FinanceCategorizer.totals(for: try store.all())

        XCTAssertEqual(totalsAfter.outflowCents, totalsBefore.outflowCents)
        XCTAssertEqual(totalsAfter.inflowCents, totalsBefore.inflowCents)
        XCTAssertEqual(totalsAfter.transactionCount, totalsBefore.transactionCount)
        XCTAssertEqual(totalsAfter.transactionCount, 3)
    }

    func testUnchangedRowAcrossReimportStaysExactlyOneStoredRow() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        let parsed = FinanceStatementImporter.parseCSV(germanStatementInitial)
        try store.add(parsed.transactions)
        try store.add(FinanceStatementImporter.parseCSV(germanStatementInitial).transactions)

        let stored = try store.all()
        XCTAssertEqual(stored.filter { $0.description == "Restaurant Zur Post" }.count, 1)
    }

    // MARK: 6. Fallback identity path — no provider id at all (German layout
    // has none), duplicate-content rows within one file must still dedup
    // correctly and independently of each other.

    func testFallbackIdentityDistinguishesGenuineDuplicateContentRowsOnReimport() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)

        // Two identical-looking rows (same date, type, description, amount)
        // on the same statement — e.g. two identical ATM withdrawals.
        let csv = """
        Datum;Typ;Beschreibung;Betrag
        05.06.2026;Zahlung;Geldautomat Auszahlung;-50,00
        05.06.2026;Zahlung;Geldautomat Auszahlung;-50,00
        """
        let firstImport = FinanceStatementImporter.parseCSV(csv)
        XCTAssertEqual(firstImport.transactions.count, 2)
        XCTAssertEqual(Set(firstImport.transactions.map(\.id)).count, 2, "duplicate-content rows must still get distinct stable ids")
        try store.add(firstImport.transactions)
        XCTAssertEqual(try store.all().count, 2)

        // Reimporting the identical file must recognize both as duplicates,
        // not just one.
        let secondImport = FinanceStatementImporter.parseCSV(csv)
        let result = try store.add(secondImport.transactions)
        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.duplicateCount, 2)
        XCTAssertEqual(try store.all().count, 2)
    }

    // MARK: 7. Local-first sync handoff

    func testTradeRepublicImportPersistsBeforeNetworkAndLeavesDurableSyncWork() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let parsed = FinanceStatementImporter.parseCSV(germanStatementInitial)

        let result = try store.add(parsed.transactions)

        XCTAssertEqual(result.insertedCount, 3)
        XCTAssertEqual(try store.all().count, 3)
        XCTAssertEqual(try store.pendingSyncEntryCount(), 1)
        let relaunched = try FinanceImportedTransactionStore(url: url)
        XCTAssertEqual(try relaunched.all().count, 3)
        XCTAssertEqual(try relaunched.pendingSyncEntryCount(), 1)
        XCTAssertNil(try relaunched.pendingSyncRequest(), "a push must wait until a gateway ETag has been fetched")
    }

    func testDisplayedEURAmountsKeepCentsWithoutBinaryFloatingPointRounding() {
        let maximumSafeCents = 9_007_199_254_740_991
        XCTAssertEqual(
            FinanceImportCurrencyFormatter.editableEuro(cents: maximumSafeCents),
            "90071992547409.91"
        )

        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        XCTAssertTrue(
            FinanceImportCurrencyFormatter.magnitudeEuro(cents: 1_234)
                .contains("12\(decimalSeparator)34")
        )
        XCTAssertTrue(
            FinanceImportCurrencyFormatter.signedEuro(cents: -1_234)
                .contains("12\(decimalSeparator)34")
        )
    }
}
