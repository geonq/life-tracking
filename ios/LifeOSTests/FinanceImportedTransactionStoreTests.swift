import Foundation
import XCTest
@testable import LifeOS

final class FinanceImportedTransactionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-import-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("finance-imported-transactions.json", isDirectory: false)
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func transaction(
        description: String = "Supermarkt",
        bookedAt: Date? = nil,
        amountCents: Int = -1234,
        source: FinanceImportSource = .genericCSV
    ) -> FinanceImportedTransaction {
        FinanceImportedTransaction(
            bookedAt: bookedAt ?? now,
            amountCents: amountCents,
            description: description,
            source: source,
            importedAt: now
        )
    }

    // MARK: 1. Persistence round-trip / reload after relaunch

    func testPersistenceRoundTripSurvivesRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let original = transaction(description: "Rewe", amountCents: -4590)
        try store.add([original])

        let relaunched = try FinanceImportedTransactionStore(url: url)
        let loaded = try relaunched.all()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, original.id)
        XCTAssertEqual(loaded.first?.description, "Rewe")
        XCTAssertEqual(loaded.first?.amountCents, -4590)
    }

    func testAddingSameStableIDTwiceIsIdempotent() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let id = UUID()
        let first = FinanceImportedTransaction(id: id, bookedAt: now, amountCents: -100, description: "Rewe", source: .genericCSV, importedAt: now)
        let retry = FinanceImportedTransaction(id: id, bookedAt: now, amountCents: -100, description: "Rewe", source: .genericCSV, importedAt: now.addingTimeInterval(60))
        let firstResult = try store.add([first, first])
        let retryResult = try store.add([retry])
        XCTAssertEqual(firstResult, FinanceImportSaveResult(requestedCount: 2, insertedCount: 1, duplicateCount: 1, storedCount: 1))
        XCTAssertEqual(retryResult, FinanceImportSaveResult(requestedCount: 1, insertedCount: 0, duplicateCount: 1, storedCount: 1))
        XCTAssertEqual(try store.all(), [first])
    }

    func testReimportReconcilesSourceCorrectionAndPreservesUserOverride() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let id = UUID()
        let original = FinanceImportedTransaction(
            id: id,
            bookedAt: now,
            amountCents: -100,
            description: "Unknown merchant",
            source: .genericCSV,
            importedAt: now,
            sourceCategory: "Shopping"
        )
        try store.add([original])
        try store.setCategory(.groceries, for: id)

        let corrected = FinanceImportedTransaction(
            id: id,
            bookedAt: now,
            amountCents: -1_250,
            description: "Corrected merchant",
            source: .genericCSV,
            importedAt: now.addingTimeInterval(60),
            sourceCategory: "Food"
        )
        let result = try store.add([corrected])
        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.duplicateCount, 0)

        let restored = try XCTUnwrap(try store.all().first)
        XCTAssertEqual(restored.amountCents, -1_250)
        XCTAssertEqual(restored.description, "Corrected merchant")
        XCTAssertEqual(restored.category, FinanceTransactionCategory.groceries.rawValue)
        XCTAssertEqual(try store.add([corrected]).duplicateCount, 1)
    }

    // MARK: 2. Honest empty when absent

    func testMissingFileDecodesToHonestEmptyState() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let loaded = try store.all()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testMinimalEnvelopeJSONDecodesWithoutThrowing() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"transactions":[]}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try FinanceImportedTransactionStore(url: url)
        let loaded = try store.all()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: 3. Add / remove / clear

    func testAddPersistsMultipleTransactions() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let a = transaction(description: "A", amountCents: -100)
        let b = transaction(description: "B", amountCents: 5000, source: .tradeRepublicCSV)
        try store.add([a, b])

        let loaded = try store.all()
        XCTAssertEqual(Set(loaded.map(\.id)), Set([a.id, b.id]))
    }

    func testRemoveDeletesOnlyMatchingTransaction() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let keep = transaction(description: "Keep")
        let drop = transaction(description: "Drop")
        try store.add([keep, drop])

        try store.remove(id: drop.id)

        let loaded = try store.all()
        XCTAssertEqual(loaded.map(\.id), [keep.id])
    }

    func testRemoveMissingIDThrowsTransactionNotFound() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        try store.add([transaction()])

        XCTAssertThrowsError(try store.remove(id: UUID())) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .transactionNotFound)
        }
    }

    func testCategoryOverridePersistsAndCanReturnToAutomatic() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let imported = transaction(description: "Unknown merchant")
        try store.add([imported])

        try store.setCategory(.groceries, for: imported.id)
        XCTAssertEqual(try store.all().first?.category, FinanceTransactionCategory.groceries.rawValue)

        try store.setCategory(nil, for: imported.id)
        XCTAssertNil(try store.all().first?.category)
    }

    func testClearingOverrideRestoresProviderCategory() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let imported = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -2_000,
            description: "Unknown merchant",
            source: .tradeRepublicCSV,
            importedAt: now,
            sourceCategory: "Food"
        )
        try store.add([imported])

        try store.setCategory(.dining, for: imported.id)
        let overridden = try XCTUnwrap(store.all().first)
        XCTAssertEqual(FinanceCategorizer.category(for: overridden), .dining)

        try store.clearCategoryOverride(for: imported.id)
        let restored = try XCTUnwrap(store.all().first)
        XCTAssertNil(restored.category)
        XCTAssertEqual(restored.sourceCategory, "Food")
        XCTAssertEqual(FinanceCategorizer.category(for: restored), .groceries)
    }

    func testInvestmentDetailsSurvivePersistenceWithoutBecomingAValuation() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let order = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -10_050,
            description: "Vanguard",
            source: .tradeRepublicCSV,
            importedAt: now,
            kind: .investmentOrder,
            investment: FinanceImportedInvestmentDetails(
                symbol: "VWCE",
                assetClass: "ETF",
                quantity: "1.25",
                unitPriceCents: 10_050,
                tradeType: "buy"
            )
        )
        try store.add([order])

        let restored = try XCTUnwrap(try FinanceImportedTransactionStore(url: url).all().first)
        XCTAssertEqual(restored.kind, .investmentOrder)
        XCTAssertEqual(restored.investment?.symbol, "VWCE")
        XCTAssertEqual(FinanceCategorizer.category(for: restored), .investments)
    }

    func testClearAllRemovesEveryTransaction() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        try store.add([transaction(description: "A"), transaction(description: "B")])

        try store.clearAll()

        let loaded = try store.all()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: 4. EUR cents preserved exactly (integer, no float drift)

    func testAmountCentsArePreservedExactlyAcrossPersistence() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let precise = transaction(description: "Precise", amountCents: -999_999)
        try store.add([precise])

        let relaunched = try FinanceImportedTransactionStore(url: url)
        let loaded = try relaunched.all()
        XCTAssertEqual(loaded.first?.amountCents, -999_999)
    }

    // MARK: 5. Date-range filtering

    func testTransactionsInIntervalFiltersAndSorts() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let early = transaction(description: "Early", bookedAt: now.addingTimeInterval(-86_400))
        let mid = transaction(description: "Mid", bookedAt: now)
        let late = transaction(description: "Late", bookedAt: now.addingTimeInterval(86_400 * 30))
        try store.add([late, early, mid])

        let interval = DateInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        let filtered = try store.transactions(in: interval)
        XCTAssertEqual(filtered.map(\.description), ["Mid"])

        let all = try store.transactions(in: nil)
        XCTAssertEqual(all.map(\.description), ["Early", "Mid", "Late"])
    }

    // MARK: 6. Adding an empty array is a safe no-op

    func testAddingEmptyArrayIsNoOp() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        try store.add([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try store.all().isEmpty)
    }
}
