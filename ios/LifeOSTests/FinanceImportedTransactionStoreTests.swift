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

private final class FinanceImportedClearAllRaceURLProtocol: URLProtocol {
    enum Outcome: Equatable {
        case success
        case conflict
        case replayAtNewerRevision
    }

    private static let lock = NSLock()
    private static var outcome: Outcome = .success
    private static var putCount = 0
    private static var operationHistory: [[FinanceImportedSyncOperation]] = []
    private static var idempotencyKeyHistory: [String] = []
    private static var startingRecord: FinanceImportedSyncRecord?
    private static var firstPutStarted = DispatchSemaphore(value: 0)
    private static var releaseFirstPut = DispatchSemaphore(value: 0)

    static func configure(outcome: Outcome, startingRecord: FinanceImportedSyncRecord?) {
        lock.lock()
        Self.outcome = outcome
        Self.startingRecord = startingRecord
        putCount = 0
        operationHistory = []
        idempotencyKeyHistory = []
        firstPutStarted = DispatchSemaphore(value: 0)
        releaseFirstPut = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    static func waitForFirstPut() -> Bool {
        lock.lock()
        let semaphore = firstPutStarted
        lock.unlock()
        return semaphore.wait(timeout: .now() + 2) == .success
    }

    static func releasePut() {
        lock.lock()
        let semaphore = releaseFirstPut
        lock.unlock()
        semaphore.signal()
    }

    static func requests() -> [[FinanceImportedSyncOperation]] {
        lock.lock()
        defer { lock.unlock() }
        return operationHistory
    }

    static func idempotencyKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return idempotencyKeyHistory
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                return data
            } else {
                return nil
            }
        }
    }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        if request.httpMethod == "GET" {
            let snapshot = try! FinanceImportedSyncSnapshot(
                revision: Self.startingRecord == nil ? 0 : 1,
                records: Self.startingRecord.map { [$0] } ?? [],
                tombstones: []
            )
            send(snapshot: snapshot, statusCode: 200, client: client, url: url)
            return
        }

        guard request.httpMethod == "PUT",
              let body = Self.bodyData(from: request),
              let syncRequest = try? JSONDecoder.lifeOS.decode(FinanceImportedSyncRequest.self, from: body) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        Self.lock.lock()
        Self.putCount += 1
        let putNumber = Self.putCount
        Self.operationHistory.append(syncRequest.operations)
        Self.idempotencyKeyHistory.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
        let outcome = Self.outcome
        let firstPutSemaphore = Self.firstPutStarted
        let releaseSemaphore = Self.releaseFirstPut
        Self.lock.unlock()

        if putNumber == 1 {
            firstPutSemaphore.signal()
            _ = releaseSemaphore.wait(timeout: .now() + 5)
        }

        switch (putNumber, outcome) {
        case (1, .success), (1, .conflict):
            guard case .upsert(let record, _) = syncRequest.operations.first,
                  let remoteRecord = try? record.withSourceRevision(2),
                  let snapshot = try? FinanceImportedSyncSnapshot(revision: 2, records: [remoteRecord], tombstones: []) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            send(snapshot: snapshot, statusCode: outcome == .conflict ? 409 : 200, client: client, url: url)
        case (1, .replayAtNewerRevision):
            // The original request committed at r2; another writer advanced
            // this row to r3 before the idempotent replay returned the
            // gateway's current snapshot.
            guard case .upsert(let record, _) = syncRequest.operations.first,
                  let remoteRecord = try? record.withSourceRevision(3),
                  let snapshot = try? FinanceImportedSyncSnapshot(revision: 3, records: [remoteRecord], tombstones: []) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            send(snapshot: snapshot, statusCode: 200, client: client, url: url, wasReplay: true)
        default:
            guard case .delete(let recordID, _, let deletedAt) = syncRequest.operations.first,
                  let tombstone = try? FinanceImportedSyncTombstone(recordID: recordID, revision: 3, deletedAt: deletedAt),
                  let snapshot = try? FinanceImportedSyncSnapshot(revision: 3, records: [], tombstones: [tombstone]) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            send(snapshot: snapshot, statusCode: 200, client: client, url: url)
        }
    }

    private func send(
        snapshot: FinanceImportedSyncSnapshot,
        statusCode: Int,
        client: URLProtocolClient,
        url: URL,
        wasReplay: Bool = false
    ) {
        guard let body = try? JSONEncoder.lifeOS.encode(snapshot) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        var headers = [
            "Content-Type": "application/json",
            "Content-Length": String(body.count),
            "ETag": "\"finance-imported-v2-r\(snapshot.revision)-\(digest)\"",
            "X-LifeOS-Revision": String(snapshot.revision),
            "X-LifeOS-Schema-Version": "2",
        ]
        if wasReplay {
            headers["X-LifeOS-Idempotent-Replay"] = "true"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FinanceImportedReceiptRecoveryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var receiptKey = ""
    private static var receipt: FinanceImportedCommitReceipt?
    private static var ledgerSnapshot: FinanceImportedSyncSnapshot?
    private static var deleteExpectedRevision: Int?
    private static var requestPaths: [String] = []

    static func configure(receiptKey: String, record: FinanceImportedSyncRecord) {
        let snapshot = try! FinanceImportedSyncSnapshot(revision: 2, records: [record], tombstones: [])
        let receipt = try! FinanceImportedCommitReceipt(state: .committed, revision: 2)
        configure(receiptKey: receiptKey, receipt: receipt, ledgerSnapshot: snapshot)
    }

    static func configure(
        receiptKey: String,
        receipt: FinanceImportedCommitReceipt,
        ledgerSnapshot: FinanceImportedSyncSnapshot
    ) {
        lock.lock()
        Self.receiptKey = receiptKey
        Self.receipt = receipt
        Self.ledgerSnapshot = ledgerSnapshot
        Self.deleteExpectedRevision = nil
        Self.requestPaths = []
        lock.unlock()
    }

    static func deleteRevision() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return deleteExpectedRevision
    }

    static func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestPaths
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 { data.append(buffer, count: count) }
            else if count == 0 { return data }
            else { return nil }
        }
    }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        Self.lock.lock()
        Self.requestPaths.append(url.path)
        let configuredKey = Self.receiptKey
        let configuredReceipt = Self.receipt
        let configuredSnapshot = Self.ledgerSnapshot
        Self.lock.unlock()

        if url.path.contains("/receipt/") {
            guard url.lastPathComponent == configuredKey,
                  let configuredReceipt,
                  let body = try? JSONEncoder.lifeOS.encode(configuredReceipt) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            send(data: body, statusCode: 200, client: client, url: url)
            return
        }

        if request.httpMethod == "GET" {
            guard let configuredSnapshot else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            send(snapshot: configuredSnapshot, statusCode: 200, client: client, url: url)
            return
        }

        guard request.httpMethod == "PUT",
              let body = Self.bodyData(from: request),
              let syncRequest = try? JSONDecoder.lifeOS.decode(FinanceImportedSyncRequest.self, from: body),
              case .delete(_, let expectedRevision, let deletedAt) = syncRequest.operations.first,
              let recordID = syncRequest.operations.first?.recordID,
              let configuredSnapshot,
              let tombstone = try? FinanceImportedSyncTombstone(
                  recordID: recordID,
                  revision: configuredSnapshot.revision + 1,
                  deletedAt: deletedAt
              ),
              let snapshot = try? FinanceImportedSyncSnapshot(
                  revision: configuredSnapshot.revision + 1,
                  records: [],
                  tombstones: [tombstone]
              ) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lock.lock()
        Self.deleteExpectedRevision = expectedRevision
        Self.lock.unlock()
        send(snapshot: snapshot, statusCode: 200, client: client, url: url)
    }

    private func send(snapshot: FinanceImportedSyncSnapshot, statusCode: Int, client: URLProtocolClient, url: URL) {
        guard let body = try? JSONEncoder.lifeOS.encode(snapshot) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        send(data: body, statusCode: statusCode, client: client, url: url, snapshot: snapshot)
    }

    private func send(
        data: Data,
        statusCode: Int,
        client: URLProtocolClient,
        url: URL,
        snapshot: FinanceImportedSyncSnapshot? = nil
    ) {
        let headers: [String: String]
        if let snapshot {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            headers = [
                "Content-Type": "application/json",
                "Content-Length": String(data.count),
                "ETag": "\"finance-imported-v2-r\(snapshot.revision)-\(digest)\"",
                "X-LifeOS-Revision": String(snapshot.revision),
                "X-LifeOS-Schema-Version": "2",
            ]
        } else {
            headers = ["Content-Type": "application/json", "Content-Length": String(data.count)]
        }
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
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
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        XCTAssertNoThrow(
            try FileManager.default.removeItem(at: directory),
            "the temporary Finance store directory should be removable when it still exists"
        )
    }

    private func seedRelaunchReceiptState(at url: URL, row: FinanceImportedTransaction) throws -> String {
        let remoteRecord = try FinanceImportedSyncRecord(validating: row, sourceRevision: 1)
        let initialSnapshot = try FinanceImportedSyncSnapshot(revision: 1, records: [remoteRecord], tombstones: [])
        let initialBody = try JSONEncoder.lifeOS.encode(initialSnapshot)
        let initialDigest = SHA256.hash(data: initialBody).map { String(format: "%02x", $0) }.joined()
        let initialETag = "\"finance-imported-v2-r1-\(initialDigest)\""
        let delete = FinanceImportedSyncOperation.delete(recordID: row.id, expectedSourceRevision: 1, deletedAt: .now)
        let entry = try FinanceImportedPendingSyncEntry(
            idempotencyKey: "finance-import-delete-after-relaunch",
            operations: [delete]
        )
        let envelope = FinanceImportedTransactionStoreEnvelope(
            transactions: [],
            remoteRevision: 1,
            remoteETag: initialETag,
            remoteRecordRevisions: [row.id.uuidString.lowercased(): 1],
            outbox: [entry]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(envelope)) as? [String: Any])
        var outbox = try XCTUnwrap(object["outbox"] as? [[String: Any]])
        let receiptKey = "finance-import-lost-response"
        outbox[0]["supersededAttemptKeys"] = [[
            "idempotencyKey": receiptKey,
            "recordIDs": [row.id.uuidString.lowercased()],
        ]]
        object["outbox"] = outbox
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        return receiptKey
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

    func testClearAllCompactsPayloadEntriesAndRetainsUnrelatedOperations() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let cleared = transaction(description: "Private merchant payload")
        let unrelatedID = UUID()
        let clearedOperation = try FinanceImportedSyncOperation.upsert(
            record: try FinanceImportedSyncRecord(validating: cleared, sourceRevision: 0),
            expectedSourceRevision: 0
        )
        let unrelatedOperation = FinanceImportedSyncOperation.categorySet(
            recordID: unrelatedID,
            expectedSourceRevision: 0,
            categoryOverride: .groceries
        )
        let mixedEntry = try FinanceImportedPendingSyncEntry(
            idempotencyKey: "clear-all-compaction",
            operations: [clearedOperation, unrelatedOperation]
        )
        let envelope = FinanceImportedTransactionStoreEnvelope(
            transactions: [cleared],
            outbox: [mixedEntry]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder.lifeOS.encode(envelope).write(to: url)

        let store = try FinanceImportedTransactionStore(url: url)
        try store.clearAll()

        XCTAssertTrue(try store.all().isEmpty)
        let persisted = try persistedEnvelope(at: url)
        let operations = persisted.outbox.flatMap(\.operations)
        XCTAssertTrue(operations.contains { operation in
            if case .categorySet(let recordID, _, _) = operation { return recordID == unrelatedID }
            return false
        })
        XCTAssertTrue(operations.contains { operation in
            if case .delete(let recordID, _, _) = operation { return recordID == cleared.id }
            return false
        })
        XCTAssertFalse(operations.contains { operation in
            if case .upsert = operation { return true }
            return false
        })
        let raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("Private merchant payload"))
    }

    func testClearAllReconcilesSuspendedUploadSuccessAndEventuallyDeletesRemoteRow() async throws {
        try await runClearAllRace(outcome: .success)
    }

    func testClearAllConflictDoesNotDeleteANewerRemoteRow() async throws {
        try await runClearAllRace(outcome: .conflict)
    }

    func testClearAllReplayAtNewerRevisionBlocksDeleteOfNewerRemoteRow() async throws {
        try await runClearAllRace(outcome: .replayAtNewerRevision)
    }

    func testClearAllBeforeFirstSyncBlocksCompetingRemoteRowWithoutSendingDelete() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let local = transaction(description: "Created and cleared before first sync")
        let store = try FinanceImportedTransactionStore(url: url)
        try store.add([local])
        try store.clearAll()

        let competing = FinanceImportedTransaction(
            id: local.id,
            bookedAt: local.bookedAt,
            amountCents: -4_321,
            description: "Competing remote row",
            source: .genericCSV,
            importedAt: local.importedAt
        )
        try await assertInitialCompetingRowDoesNotReceiveClearAllDelete(
            store: store,
            url: url,
            competing: competing
        )
    }

    func testClearAllBeforeFirstSyncRemainsBlockedAcrossRelaunch() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let local = transaction(description: "Persisted clear before first sync")
        let store = try FinanceImportedTransactionStore(url: url)
        try store.add([local])
        try store.clearAll()

        let relaunched = try FinanceImportedTransactionStore(url: url)
        let competing = FinanceImportedTransaction(
            id: local.id,
            bookedAt: local.bookedAt,
            amountCents: -5_432,
            description: "Competing remote row after relaunch",
            source: .genericCSV,
            importedAt: local.importedAt
        )
        try await assertInitialCompetingRowDoesNotReceiveClearAllDelete(
            store: relaunched,
            url: url,
            competing: competing
        )
    }

    private func assertInitialCompetingRowDoesNotReceiveClearAllDelete(
        store: FinanceImportedTransactionStore,
        url: URL,
        competing: FinanceImportedTransaction
    ) async throws {
        let suiteName = "LifeOS.FinanceImportedInitialClearAll.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://lifeos.example-tailnet.ts.net:8420", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinanceImportedClearAllRaceURLProtocol.self]
        let client = TailscaleSyncClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            approvedHosts: ["lifeos.example-tailnet.ts.net"]
        )
        let remoteRecord = try FinanceImportedSyncRecord(validating: competing, sourceRevision: 1)
        FinanceImportedClearAllRaceURLProtocol.configure(outcome: .success, startingRecord: remoteRecord)

        let result = try await store.synchronize(using: client)
        XCTAssertEqual(result.snapshot.revision, 1)
        XCTAssertTrue(
            FinanceImportedClearAllRaceURLProtocol.requests().isEmpty,
            "initial adoption of a competing row must not transmit delete(0)"
        )
        XCTAssertTrue(try store.all().isEmpty, "the protected clear-all must not import the competing row locally")

        let persisted = try persistedEnvelope(at: url)
        XCTAssertEqual(persisted.outbox.count, 1)
        XCTAssertEqual(persisted.outbox.first?.state, .blocked)
        XCTAssertEqual(persisted.outbox.first?.blockedReason, .conflict)
        guard case .delete(let deletedID, let expectedRevision, _) = try XCTUnwrap(
            persisted.outbox.first?.operations.first
        ) else {
            return XCTFail("the blocked entry must retain the clear-all delete")
        }
        XCTAssertEqual(deletedID, competing.id)
        XCTAssertEqual(expectedRevision, 0, "initial adoption must not authorize a competing row revision")
        XCTAssertEqual(persisted.remoteRecordRevisions[competing.id.uuidString.lowercased()], 1)
        XCTAssertEqual(try store.syncStatus().pendingEntryCount, 0)
        XCTAssertEqual(try store.syncStatus().blockedEntryCount, 1)
    }

    private func runClearAllRace(
        outcome: FinanceImportedClearAllRaceURLProtocol.Outcome
    ) async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let row = transaction(description: "Cleared while upload is suspended")
        let remoteRecord = try FinanceImportedSyncRecord(validating: row, sourceRevision: 1)
        let envelope = FinanceImportedTransactionStoreEnvelope(
            transactions: [row],
            remoteRevision: 1,
            remoteRecordRevisions: [row.id.uuidString.lowercased(): 1],
            outbox: []
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder.lifeOS.encode(envelope).write(to: url)

        let store = try FinanceImportedTransactionStore(url: url)
        let correction = FinanceImportedTransaction(
            id: row.id,
            bookedAt: row.bookedAt,
            amountCents: row.amountCents,
            description: "Corrected while upload is suspended",
            category: row.category,
            source: row.source,
            importedAt: row.importedAt,
            sourceCategory: row.sourceCategory,
            providerCode: row.providerCode,
            kind: row.kind,
            investment: row.investment
        )
        try store.add([correction])

        let suiteName = "LifeOS.FinanceImportedClearAllRace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://lifeos.example-tailnet.ts.net:8420", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinanceImportedClearAllRaceURLProtocol.self]
        let client = TailscaleSyncClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            approvedHosts: ["lifeos.example-tailnet.ts.net"]
        )
        FinanceImportedClearAllRaceURLProtocol.configure(outcome: outcome, startingRecord: remoteRecord)
        defer { FinanceImportedClearAllRaceURLProtocol.releasePut() }

        let synchronization = Task { try await store.synchronize(using: client) }
        let firstPutStarted = FinanceImportedClearAllRaceURLProtocol.waitForFirstPut()
        XCTAssertTrue(firstPutStarted, "the URLProtocol must reach and suspend the first PUT")
        guard firstPutStarted else {
            FinanceImportedClearAllRaceURLProtocol.releasePut()
            _ = try? await synchronization.value
            return
        }

        let suspendedRaw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        let requestKeys = FinanceImportedClearAllRaceURLProtocol.idempotencyKeys()
        guard requestKeys.count == 1, let firstRequestKey = requestKeys.first, !firstRequestKey.isEmpty else {
            FinanceImportedClearAllRaceURLProtocol.releasePut()
            _ = try? await synchronization.value
            return XCTFail("the suspended correction must expose exactly one durable idempotency key")
        }
        XCTAssertTrue(suspendedRaw.contains(firstRequestKey), "the first PUT must be durably recorded before transmission")
        XCTAssertTrue(suspendedRaw.contains("\"attemptedRequest\""), "the first PUT must have a durable attempted envelope before transmission")

        try store.clearAll()
        XCTAssertTrue(try store.all().isEmpty)
        let clearedRaw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(clearedRaw.contains("Cleared while upload is suspended"))
        XCTAssertFalse(clearedRaw.contains("Corrected while upload is suspended"))
        let persistedAfterClear = try persistedEnvelope(at: url)
        XCTAssertEqual(persistedAfterClear.outbox.count, 1)
        guard case .delete(let clearedID, _, _) = try XCTUnwrap(persistedAfterClear.outbox.first?.operations.first) else {
            return XCTFail("clear-all must replace the suspended payload with a delete before releasing the response")
        }
        XCTAssertEqual(clearedID, row.id)
        XCTAssertTrue(
            clearedRaw.contains(firstRequestKey),
            "clear-all must durably retain a bounded receipt marker for the suspended request; \(durableOutboxMetadata(at: url))"
        )

        FinanceImportedClearAllRaceURLProtocol.releasePut()
        if outcome == .replayAtNewerRevision {
            do {
                _ = try await synchronization.value
                XCTFail("a replay at a newer authority revision must not authorize the clear-all delete")
            } catch let error as FinanceImportedTransactionStoreError {
                XCTAssertEqual(error, .syncReceiptUnresolved)
            }
            let requests = FinanceImportedClearAllRaceURLProtocol.requests()
            XCTAssertEqual(requests.count, 1, "an unproven replay must not transmit the delete")
            XCTAssertFalse(
                requests.flatMap { $0 }.contains { operation in
                    if case .delete = operation { return true }
                    return false
                }
            )
            XCTAssertTrue(try store.all().isEmpty)
            let persisted = try persistedEnvelope(at: url)
            XCTAssertEqual(persisted.remoteRevision, 3)
            XCTAssertEqual(persisted.remoteRecordRevisions[row.id.uuidString.lowercased()], 3)
            XCTAssertTrue(persisted.remoteTombstones.isEmpty)
            XCTAssertEqual(persisted.outbox.count, 1)
            XCTAssertEqual(persisted.outbox.first?.state, .blocked)
            XCTAssertEqual(persisted.outbox.first?.blockedReason, .conflict)
            guard case .delete(let deletedID, let expectedSourceRevision, _) = try XCTUnwrap(persisted.outbox.first?.operations.first) else {
                return XCTFail("the unresolved replay must retain the clear-all delete for recovery")
            }
            XCTAssertEqual(deletedID, row.id)
            XCTAssertEqual(expectedSourceRevision, 1, "the replay must not promote the delete to the newer row revision")
            let blockedRaw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
            XCTAssertTrue(blockedRaw.contains(firstRequestKey), "the blocked entry must retain its exact recovery marker")
            XCTAssertEqual(try store.syncStatus().pendingEntryCount, 0)
            XCTAssertEqual(try store.syncStatus().blockedEntryCount, 1)
            return
        }
        if outcome == .conflict {
            do {
                _ = try await synchronization.value
                XCTFail("a rejected correction must not authorize a delete of the newer remote row")
            } catch let error as FinanceImportedSyncError {
                guard case .conflict = error else {
                    XCTFail("expected the authoritative conflict to surface")
                    return
                }
            }
            XCTAssertEqual(FinanceImportedClearAllRaceURLProtocol.requests().count, 1)
            XCTAssertTrue(try store.all().isEmpty)
            XCTAssertEqual(try store.syncStatus().blockedReasons, [.conflict])
            XCTAssertEqual(try store.syncStatus().blockedEntryCount, 1)
            XCTAssertEqual(try persistedEnvelope(at: url).outbox.first?.state, .blocked)
            return
        }

        let result = try await synchronization.value
        XCTAssertEqual(result.snapshot.revision, 3)
        XCTAssertEqual(result.snapshot.tombstones.map(\.recordID), [row.id])
        XCTAssertTrue(try store.all().isEmpty, "a late upload response must not resurrect a cleared row")
        XCTAssertEqual(try store.pendingSyncEntryCount(), 0, "the delete must be durably completed")

        let requests = FinanceImportedClearAllRaceURLProtocol.requests()
        XCTAssertEqual(requests.count, 2, "the suspended upload and rebased delete must both be transmitted")
        guard case .upsert(let uploaded, _) = try XCTUnwrap(requests.first?.first) else {
            return XCTFail("the first PUT must be the original source upload")
        }
        XCTAssertEqual(uploaded.recordID, row.id)
        XCTAssertEqual(uploaded.sourceRevision, 1)
        guard case .delete(let deletedID, let expectedSourceRevision, _) = try XCTUnwrap(requests.last?.first) else {
            return XCTFail("clear-all must leave a delete operation after the suspended upload")
        }
        XCTAssertEqual(deletedID, row.id)
        XCTAssertEqual(expectedSourceRevision, 2, "the delete must rebase to the late correction's source revision")

        let relaunched = try FinanceImportedTransactionStore(url: url)
        XCTAssertTrue(try relaunched.all().isEmpty)
        XCTAssertEqual(try relaunched.pendingSyncEntryCount(), 0)
        let persisted = try persistedEnvelope(at: url)
        XCTAssertEqual(persisted.remoteTombstones.map(\.recordID), [row.id])
        XCTAssertEqual(persisted.remoteTombstones.first?.revision, 3)
    }

    func testCreateAtRevisionZeroConflictFollowedByClearAllBlocksWithoutTransmittingDelete() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let row = transaction(description: "Created locally at revision zero")
        let store = try FinanceImportedTransactionStore(url: url)
        try store.add([row])

        let suiteName = "LifeOS.FinanceImportedCreateZeroConflict.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://lifeos.example-tailnet.ts.net:8420", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinanceImportedClearAllRaceURLProtocol.self]
        let client = TailscaleSyncClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            approvedHosts: ["lifeos.example-tailnet.ts.net"]
        )
        FinanceImportedClearAllRaceURLProtocol.configure(outcome: .conflict, startingRecord: nil)
        defer { FinanceImportedClearAllRaceURLProtocol.releasePut() }

        let synchronization = Task { try await store.synchronize(using: client) }
        let firstPutStarted = FinanceImportedClearAllRaceURLProtocol.waitForFirstPut()
        XCTAssertTrue(firstPutStarted, "the URLProtocol must reach and suspend the create PUT")
        guard firstPutStarted else {
            FinanceImportedClearAllRaceURLProtocol.releasePut()
            _ = try? await synchronization.value
            return
        }

        try store.clearAll()
        XCTAssertTrue(try store.all().isEmpty)
        let clearedRaw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(clearedRaw.contains("Created locally at revision zero"))

        FinanceImportedClearAllRaceURLProtocol.releasePut()
        do {
            _ = try await synchronization.value
            XCTFail("a rejected create must not authorize the clear-all delete")
        } catch let error as FinanceImportedSyncError {
            guard case .conflict = error else {
                XCTFail("expected the authoritative conflict to surface")
                return
            }
        }

        let requests = FinanceImportedClearAllRaceURLProtocol.requests()
        XCTAssertEqual(requests.count, 1, "the rejected create must be the only transmitted request")
        guard case .upsert(let uploaded, let createExpectedRevision) = try XCTUnwrap(requests.first?.first) else {
            return XCTFail("the first PUT must be the create operation")
        }
        XCTAssertEqual(uploaded.recordID, row.id)
        XCTAssertEqual(uploaded.sourceRevision, 0)
        XCTAssertEqual(createExpectedRevision, 0)
        XCTAssertFalse(
            requests.flatMap { $0 }.contains { operation in
                if case .delete = operation { return true }
                return false
            },
            "a create-at-r0 conflict must not transmit a delete for the competing row"
        )

        let persisted = try persistedEnvelope(at: url)
        XCTAssertEqual(persisted.outbox.count, 1)
        XCTAssertEqual(persisted.outbox.first?.state, .blocked)
        XCTAssertEqual(persisted.outbox.first?.blockedReason, .conflict)
        guard case .delete(let deletedID, let deleteExpectedRevision, _) = try XCTUnwrap(persisted.outbox.first?.operations.first) else {
            return XCTFail("the blocked outbox must retain the clear-all delete for recovery")
        }
        XCTAssertEqual(deletedID, row.id)
        XCTAssertEqual(deleteExpectedRevision, 0, "the conflict must not promote delete(0) to the competing row")
        XCTAssertEqual(persisted.remoteRecordRevisions[row.id.uuidString.lowercased()], 2)
        XCTAssertEqual(try store.syncStatus().pendingEntryCount, 0)
        XCTAssertEqual(try store.syncStatus().blockedEntryCount, 1)
    }

    func testRelaunchUsesCommittedReceiptBeforeDeletingAgainstTheNewSourceRevision() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let row = transaction(description: "Lost response row")
        let receiptKey = try seedRelaunchReceiptState(at: url, row: row)

        let corrected = FinanceImportedTransaction(
            id: row.id,
            bookedAt: row.bookedAt,
            amountCents: row.amountCents,
            description: "Corrected after the lost response",
            category: row.category,
            source: row.source,
            importedAt: row.importedAt,
            sourceCategory: row.sourceCategory,
            providerCode: row.providerCode,
            kind: row.kind,
            investment: row.investment
        )
        let authoritativeRecord = try FinanceImportedSyncRecord(validating: corrected, sourceRevision: 2)
        FinanceImportedReceiptRecoveryURLProtocol.configure(
            receiptKey: receiptKey,
            record: authoritativeRecord
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinanceImportedReceiptRecoveryURLProtocol.self]
        let suiteName = "LifeOS.FinanceImportedReceiptRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://lifeos.example-tailnet.ts.net:8420", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = TailscaleSyncClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            approvedHosts: ["lifeos.example-tailnet.ts.net"]
        )

        let result = try await FinanceImportedTransactionStore(url: url).synchronize(using: client)
        XCTAssertEqual(result.snapshot.revision, 3)
        XCTAssertEqual(FinanceImportedReceiptRecoveryURLProtocol.deleteRevision(), 2)
        XCTAssertTrue(FinanceImportedReceiptRecoveryURLProtocol.paths().contains { $0.contains("/receipt/") })
        XCTAssertTrue(try FinanceImportedTransactionStore(url: url).all().isEmpty)
        XCTAssertEqual(try FinanceImportedTransactionStore(url: url).pendingSyncEntryCount(), 0)
    }

    func testUnknownReceiptBlocksBeforeAnyDeleteIsTransmitted() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let row = transaction(description: "Unknown receipt row")
        let receiptKey = try seedRelaunchReceiptState(at: url, row: row)
        let authoritativeRecord = try FinanceImportedSyncRecord(validating: row, sourceRevision: 2)
        let snapshot = try FinanceImportedSyncSnapshot(revision: 2, records: [authoritativeRecord], tombstones: [])
        FinanceImportedReceiptRecoveryURLProtocol.configure(
            receiptKey: receiptKey,
            receipt: try FinanceImportedCommitReceipt(state: .unknown, revision: nil),
            ledgerSnapshot: snapshot
        )
        let (client, suiteName) = try receiptRecoveryClient()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = try FinanceImportedTransactionStore(url: url)

        do {
            _ = try await store.synchronize(using: client)
            XCTFail("an unknown receipt must pause the delete")
        } catch let error as FinanceImportedTransactionStoreError {
            XCTAssertEqual(error, .syncReceiptUnresolved)
        }
        XCTAssertNil(FinanceImportedReceiptRecoveryURLProtocol.deleteRevision())
        XCTAssertEqual(try store.syncStatus().blockedReasons, [.conflict])
        XCTAssertEqual(try store.pendingSyncEntryCount(), 1)
    }

    func testReceiptWithAdvancedAuthorityBlocksWithoutDeletingNewerData() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let row = transaction(description: "Advanced authority row")
        let receiptKey = try seedRelaunchReceiptState(at: url, row: row)
        let source = try FinanceImportedSyncRecord(validating: row, sourceRevision: 3)
        let snapshot = try FinanceImportedSyncSnapshot(revision: 3, records: [source], tombstones: [])
        FinanceImportedReceiptRecoveryURLProtocol.configure(
            receiptKey: receiptKey,
            receipt: try FinanceImportedCommitReceipt(state: .committed, revision: 2),
            ledgerSnapshot: snapshot
        )
        let (client, suiteName) = try receiptRecoveryClient()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = try FinanceImportedTransactionStore(url: url)

        do {
            _ = try await store.synchronize(using: client)
            XCTFail("a newer authority snapshot must pause the delete")
        } catch let error as FinanceImportedTransactionStoreError {
            XCTAssertEqual(error, .syncReceiptUnresolved)
        }
        XCTAssertNil(FinanceImportedReceiptRecoveryURLProtocol.deleteRevision())
        XCTAssertEqual(try store.syncStatus().blockedReasons, [.conflict])
    }

    private func receiptRecoveryClient() throws -> (TailscaleSyncClient, String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinanceImportedReceiptRecoveryURLProtocol.self]
        let suiteName = "LifeOS.FinanceImportedReceiptRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://lifeos.example-tailnet.ts.net:8420", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        return (TailscaleSyncClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            approvedHosts: ["lifeos.example-tailnet.ts.net"]
        ), suiteName)
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
        let early = transaction(description: "Early", bookedAt: now.addingTimeInterval(-86_400 * 2))
        let mid = transaction(description: "Mid", bookedAt: now.addingTimeInterval(-86_400))
        let late = transaction(description: "Late", bookedAt: now)
        try store.add([late, early, mid])

        let midDate = now.addingTimeInterval(-86_400)
        let interval = DateInterval(start: midDate.addingTimeInterval(-3600), end: midDate.addingTimeInterval(3600))
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

    private func durableOutboxMetadata(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbox = root["outbox"] as? [[String: Any]] else {
            return "unreadable"
        }
        return outbox.map { entry in
            let key = entry["idempotencyKey"] as? String ?? "?"
            let superseded = (entry["supersededAttemptKeys"] as? [Any])?.count ?? 0
            let attempted = entry["attemptedRequest"] is [String: Any]
            return "\(key):superseded=\(superseded),attempted=\(attempted)"
        }.joined(separator: ",")
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
