import Foundation
import CryptoKit
import XCTest
@testable import LifeOS

private final class FinanceImportedSingleFlightURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static let firstGetStarted = DispatchSemaphore(value: 0)
    private static let releaseFirstGet = DispatchSemaphore(value: 0)
    private static var getCount = 0
    private static var holdFirstGet = false

    private static let emptySnapshotBody: Data = {
        let snapshot = try! FinanceImportedSyncSnapshot(revision: 0, records: [], tombstones: [])
        return try! JSONEncoder.lifeOS.encode(snapshot)
    }()

    static func configureHoldingFirstGet() {
        lock.lock()
        getCount = 0
        holdFirstGet = true
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return getCount
    }

    static func waitForFirstGet() -> Bool {
        firstGetStarted.wait(timeout: .now() + 2) == .success
    }

    static func releaseHeldGet() {
        releaseFirstGet.signal()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        let isFirstGet: Bool
        Self.lock.lock()
        if request.httpMethod == "GET" {
            Self.getCount += 1
            isFirstGet = Self.holdFirstGet && Self.getCount == 1
        } else {
            isFirstGet = false
        }
        Self.lock.unlock()

        if isFirstGet {
            Self.firstGetStarted.signal()
            _ = Self.releaseFirstGet.wait(timeout: .now() + 5)
        }

        let digest = SHA256.hash(data: Self.emptySnapshotBody).map { String(format: "%02x", $0) }.joined()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": String(Self.emptySnapshotBody.count),
                "ETag": "\"finance-imported-v2-r0-\(digest)\"",
                "X-LifeOS-Revision": "0",
                "X-LifeOS-Schema-Version": "2",
            ]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Self.emptySnapshotBody)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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

    // MARK: 7. Gateway cursor, durable outbox, and deletion propagation

    private func remoteResult(
        revision: Int,
        records: [FinanceImportedSyncRecord] = [],
        tombstones: [FinanceImportedSyncTombstone] = []
    ) throws -> FinanceImportedSyncResult {
        let authoritativeRecords = try records.map { record in
            record.sourceRevision == 0 ? try record.withSourceRevision(revision) : record
        }
        let snapshot = try FinanceImportedSyncSnapshot(
            revision: revision,
            records: authoritativeRecords,
            tombstones: tombstones
        )
        let digest = String(repeating: "0", count: 64)
        return FinanceImportedSyncResult(
            snapshot: snapshot,
            etag: "\"finance-imported-v2-r\(revision)-\(digest)\""
        )
    }

    private func persistedEnvelope(at url: URL) throws -> FinanceImportedTransactionStoreEnvelope {
        try JSONDecoder.lifeOS.decode(
            FinanceImportedTransactionStoreEnvelope.self,
            from: Data(contentsOf: url)
        )
    }

    func testLegacyEnvelopeMigratesToV3AndQueuesImmutableSourceOperation() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let original = FinanceImportedTransaction(
            id: UUID(),
            bookedAt: now,
            amountCents: -2_500,
            description: "Legacy row",
            category: FinanceTransactionCategory.groceries.rawValue,
            source: .genericCSV,
            importedAt: now
        )
        let transactionObject = try JSONSerialization.jsonObject(
            with: JSONEncoder.lifeOS.encode(original)
        )
        let legacyObject: [String: Any] = [
            "schemaVersion": FinanceImportedTransactionStoreEnvelope.legacySchemaVersion,
            "transactions": [transactionObject],
        ]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys]).write(to: url)

        let store = try FinanceImportedTransactionStore(url: url)
        XCTAssertEqual(try store.all(), [original])
        let migrated = try persistedEnvelope(at: url)
        XCTAssertEqual(migrated.schemaVersion, FinanceImportedTransactionStoreEnvelope.currentSchemaVersion)
        XCTAssertEqual(migrated.remoteRevision, 0)
        XCTAssertEqual(migrated.outbox.count, 1)
        guard case .upsert(let record, let expected) = try XCTUnwrap(migrated.outbox.first?.operations.first) else {
            return XCTFail("legacy migration must create an upsert operation")
        }
        XCTAssertEqual(record.recordID, original.id)
        XCTAssertEqual(record.sourceRevision, 0)
        XCTAssertEqual(expected, 0)
    }

    func testLegacyEnvelopeWithUnknownSchemaFailsClosed() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"schemaVersion":99,"transactions":[]}"#.utf8).write(to: url)

        let store = try FinanceImportedTransactionStore(url: url)
        XCTAssertThrowsError(try store.all()) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .invalidEnvelope)
        }
    }

    func testLocalImportQueuesOneStableBatchAndSurvivesRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        try store.adoptRemote(try remoteResult(revision: 0))
        let imported = transaction(description: "Queued import")

        try store.add([imported])
        let pending = try XCTUnwrap(store.pendingSyncRequest())
        XCTAssertEqual(pending.request.baseRevision, 0)
        XCTAssertEqual(pending.request.operations.count, 1)
        XCTAssertEqual(pending.request.operations.first?.recordID, imported.id)
        XCTAssertEqual(pending.ifMatch, try remoteResult(revision: 0).etag)

        let relaunched = try FinanceImportedTransactionStore(url: url)
        let retried = try XCTUnwrap(relaunched.pendingSyncRequest())
        XCTAssertEqual(retried.idempotencyKey, pending.idempotencyKey)
        XCTAssertEqual(retried.request, pending.request)
    }

    func testRemoteSnapshotReadbackAndTombstoneRemoveRowsOnAnotherStore() throws {
        let urlA = temporaryURL()
        let urlB = temporaryURL()
        defer {
            removeStore(at: urlA)
            removeStore(at: urlB)
        }
        let row = transaction(description: "Shared row")
        let remoteRow = try FinanceImportedSyncRecord(validating: row)
        let storeA = try FinanceImportedTransactionStore(url: urlA)
        let storeB = try FinanceImportedTransactionStore(url: urlB)

        try storeA.adoptRemote(try remoteResult(revision: 1, records: [remoteRow]))
        try storeB.adoptRemote(try remoteResult(revision: 1, records: [remoteRow]))
        XCTAssertEqual(try storeB.all(), [row])

        let tombstone = try FinanceImportedSyncTombstone(
            recordID: row.id,
            revision: 2,
            deletedAt: Date(timeIntervalSinceNow: -60)
        )
        try storeB.adoptRemote(try remoteResult(revision: 2, tombstones: [tombstone]))
        XCTAssertTrue(try storeB.all().isEmpty)
    }

    func testSourceCorrectionRetainsOverrideAndExplicitCategoryEditsAreQueued() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let id = UUID()
        let original = FinanceImportedTransaction(
            id: id,
            bookedAt: now,
            amountCents: -1_000,
            description: "Original",
            source: .tradeRepublicCSV,
            importedAt: now,
            sourceCategory: "Food"
        )
        try store.adoptRemote(try remoteResult(revision: 1, records: [try FinanceImportedSyncRecord(validating: original)]))
        try store.setCategory(.groceries, for: id)
        let categoryEnvelope = try persistedEnvelope(at: url)
        guard case .categorySet(let categoryID, let categoryExpected, let category) = try XCTUnwrap(categoryEnvelope.outbox.first?.operations.first) else {
            return XCTFail("category edit must use a category-only operation")
        }
        XCTAssertEqual(categoryID, id)
        XCTAssertEqual(categoryExpected, 1)
        XCTAssertEqual(category, .groceries)

        let corrected = FinanceImportedTransaction(
            id: id,
            bookedAt: now,
            amountCents: -1_250,
            description: "Corrected",
            source: .tradeRepublicCSV,
            importedAt: now.addingTimeInterval(60),
            sourceCategory: "Food"
        )
        try store.add([corrected])
        let locallyCorrected = try XCTUnwrap(try store.all().first)
        XCTAssertEqual(locallyCorrected.amountCents, -1_250)
        XCTAssertEqual(locallyCorrected.category, FinanceTransactionCategory.groceries.rawValue)
        XCTAssertEqual(locallyCorrected.importedAt, original.importedAt)

        let envelope = try persistedEnvelope(at: url)
        guard case .upsert(let correction, let expected) = try XCTUnwrap(envelope.outbox.last?.operations.first) else {
            return XCTFail("source correction must be queued")
        }
        XCTAssertEqual(correction.recordID, id)
        XCTAssertEqual(correction.amountCents, -1_250)
        XCTAssertEqual(correction.sourceRevision, 1)
        XCTAssertEqual(expected, 1)

        try store.clearCategoryOverride(for: id)
        let finalEnvelope = try persistedEnvelope(at: url)
        guard case .categoryClear(let clearedID, let clearExpected) = try XCTUnwrap(finalEnvelope.outbox.last?.operations.first) else {
            return XCTFail("category clear must be queued")
        }
        XCTAssertEqual(clearedID, id)
        XCTAssertEqual(clearExpected, 1)
    }

    func testLocalDeleteQueuesTombstoneOperationAndDoesNotResurrectOnRemoteTombstone() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let row = transaction(description: "To clear")
        try store.adoptRemote(try remoteResult(revision: 1, records: [try FinanceImportedSyncRecord(validating: row)]))

        try store.remove(id: row.id)
        XCTAssertTrue(try store.all().isEmpty)
        let envelope = try persistedEnvelope(at: url)
        guard case .delete(let deletedID, let expected, _) = try XCTUnwrap(envelope.outbox.last?.operations.first) else {
            return XCTFail("local deletion must be queued as a tombstone operation")
        }
        XCTAssertEqual(deletedID, row.id)
        XCTAssertEqual(expected, 1)

        let tombstone = try FinanceImportedSyncTombstone(
            recordID: row.id,
            revision: 2,
            deletedAt: Date(timeIntervalSinceNow: -60)
        )
        try store.adoptRemote(try remoteResult(revision: 2, tombstones: [tombstone]))
        XCTAssertTrue(try store.all().isEmpty)
    }

    func testPendingSourceUpsertStaysLocalWhenRemoteSnapshotCarriesTombstone() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let row = transaction(description: "Offline row")
        try store.add([row])

        let tombstone = try FinanceImportedSyncTombstone(
            recordID: row.id,
            revision: 1,
            deletedAt: Date(timeIntervalSinceNow: -60)
        )
        try store.adoptRemote(try remoteResult(revision: 1, tombstones: [tombstone]))

        XCTAssertEqual(try store.all(), [row], "remote adoption must not silently erase a protected local edit")
        let pending = try XCTUnwrap(store.pendingSyncRequest())
        guard case .upsert(let record, let expected) = try XCTUnwrap(pending.request.operations.first) else {
            return XCTFail("the pending source write must remain an immutable upsert")
        }
        XCTAssertEqual(record.recordID, row.id)
        XCTAssertEqual(record.sourceRevision, 0)
        XCTAssertEqual(expected, 0)
    }

    func testExactAttemptedBodyHeadersAndKeySurviveAuthorityAdvanceAndRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        try store.adoptRemote(try remoteResult(revision: 0))
        let row = transaction(description: "Persist exact bytes")
        try store.add([row])

        let first = try XCTUnwrap(store.pendingSyncRequest())
        let persisted = try persistedEnvelope(at: url)
        let attempted = try XCTUnwrap(persisted.outbox.first?.attemptedRequest)
        XCTAssertEqual(attempted.baseRevision, first.request.baseRevision)
        XCTAssertEqual(attempted.ifMatch, first.ifMatch)
        XCTAssertEqual(attempted.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(attempted.body, first.body)
        XCTAssertEqual(attempted.body, try first.request.canonicalData())

        let unrelated = transaction(description: "Another device")
        try store.adoptRemote(try remoteResult(
            revision: 1,
            records: [try FinanceImportedSyncRecord(validating: unrelated)]
        ))
        let relaunched = try FinanceImportedTransactionStore(url: url)
        let retry = try XCTUnwrap(relaunched.pendingSyncRequest())
        XCTAssertEqual(retry.body, first.body)
        XCTAssertEqual(retry.ifMatch, first.ifMatch)
        XCTAssertEqual(retry.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(retry.request, first.request)
    }

    func testExpiredAndExhaustedOutboxRemainReadableAndExposeBlockedStatus() throws {
        for attemptCase in [
            ("expired", 0, Date().addingTimeInterval(-FinanceImportedTransactionStore.maximumRetryAge - 1)),
            ("exhausted", FinanceImportedPendingSyncEntry.maximumAttempts, Date()),
        ] {
            let url = temporaryURL()
            defer { removeStore(at: url) }
            let row = transaction(description: "Readable \(attemptCase.0)")
            let operation = try FinanceImportedSyncOperation.upsert(
                record: try FinanceImportedSyncRecord(validating: row, sourceRevision: 0),
                expectedSourceRevision: 0
            )
            let entry = try FinanceImportedPendingSyncEntry(
                idempotencyKey: "blocked-\(attemptCase.0)",
                operations: [operation],
                createdAt: attemptCase.2,
                attemptCount: attemptCase.1
            )
            let envelope = FinanceImportedTransactionStoreEnvelope(
                transactions: [row],
                outbox: [entry]
            )
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.lifeOS.encode(envelope).write(to: url)

            let store = try FinanceImportedTransactionStore(url: url)
            XCTAssertEqual(try store.all(), [row])
            let status = try store.syncStatus()
            XCTAssertEqual(status.pendingEntryCount, 0)
            XCTAssertEqual(status.blockedEntryCount, 1)
            XCTAssertEqual(status.blockedOperationCount, 1)
            XCTAssertEqual(status.blockedReasons, [attemptCase.0 == "expired" ? .retryExpired : .attemptsExhausted])

            let second = transaction(description: "Still writable \(attemptCase.0)")
            try store.add([second])
            XCTAssertEqual(try store.all().count, 2)
        }
    }

    func testOlderAndEqualMismatchedRemoteSnapshotsAreRejected() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        try store.adoptRemote(try remoteResult(revision: 2))

        XCTAssertThrowsError(try store.adoptRemote(try remoteResult(revision: 1))) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .syncSnapshotRewound)
        }
        let differentETag = FinanceImportedSyncResult(
            snapshot: try FinanceImportedSyncSnapshot(revision: 2, records: [], tombstones: []),
            etag: "\"finance-imported-v2-r2-\(String(repeating: "1", count: 64))\""
        )
        XCTAssertThrowsError(try store.adoptRemote(differentETag)) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .syncSnapshotETagMismatch)
        }
    }

    func testConcurrentSynchronizeCallsShareOneSingleFlight() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let suiteName = "LifeOS.FinanceImportedSingleFlight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://lifeos.example-tailnet.ts.net:8420", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinanceImportedSingleFlightURLProtocol.self]
        let client = TailscaleSyncClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            approvedHosts: ["lifeos.example-tailnet.ts.net"]
        )
        let store = try FinanceImportedTransactionStore(url: url)
        FinanceImportedSingleFlightURLProtocol.configureHoldingFirstGet()

        let first = Task { try await store.synchronize(using: client) }
        XCTAssertTrue(FinanceImportedSingleFlightURLProtocol.waitForFirstGet())
        let second = Task { try await store.synchronize(using: client) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(FinanceImportedSingleFlightURLProtocol.requestCount(), 1)

        FinanceImportedSingleFlightURLProtocol.releaseHeldGet()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(FinanceImportedSingleFlightURLProtocol.requestCount(), 2)
    }

    func testWorstCaseEscapedPayloadSplitsBeforeAttemptAndEveryEntryFitsByteCap() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        try store.adoptRemote(try remoteResult(revision: 0))
        let rows = (0..<600).map { index in
            transaction(description: String(repeating: "\"", count: 512), amountCents: -index - 1)
        }
        try store.add(rows)

        XCTAssertGreaterThan(try store.pendingSyncEntryCount(), 1)
        _ = try store.pendingSyncRequest()
        let envelope = try persistedEnvelope(at: url)
        XCTAssertTrue(envelope.outbox.allSatisfy { $0.operations.count <= FinanceImportedPendingSyncEntry.maximumOperations })
        for entry in envelope.outbox {
            let request = try FinanceImportedSyncRequest(baseRevision: 0, operations: entry.operations)
            XCTAssertLessThanOrEqual(try request.canonicalData().count, FinanceImportedSyncRequest.maximumRequestBytes)
        }
    }
}
