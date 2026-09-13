import Foundation
import XCTest
@testable import LifeOS

final class FinanceAllocationStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-allocation-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("finance-allocation-rules.json", isDirectory: false)
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: 1. Create/read round-trip survives relaunch

    func testCreateRoundTripSurvivesRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        let created = try store.create(label: "Rent", bucket: "Rent", share: .percentage(40))

        let relaunched = try FinanceAllocationStore(url: url)
        let loaded = try relaunched.list()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, created.id)
        XCTAssertEqual(loaded.first?.label, "Rent")
        XCTAssertEqual(loaded.first?.share, .percentage(40))
    }

    // MARK: 2. Create preserves append order (rule order)

    func testCreateAppendsPreservingRuleOrder() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        try store.create(label: "Rent", bucket: "Rent", share: .percentage(40))
        try store.create(label: "Savings", bucket: "Savings", share: .percentage(20))
        try store.create(label: "Free", bucket: "Free", share: .percentage(40))

        let loaded = try store.list()
        XCTAssertEqual(loaded.map(\.label), ["Rent", "Savings", "Free"])
    }

    // MARK: 3. Update replaces in place without reordering

    func testUpdateReplacesRuleInPlace() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        try store.create(label: "Rent", bucket: "Rent", share: .percentage(40))
        let savings = try store.create(label: "Savings", bucket: "Savings", share: .percentage(20))
        try store.create(label: "Free", bucket: "Free", share: .percentage(40))

        try store.update(id: savings.id, label: "Investing", bucket: "Investing", share: .percentage(15))

        let loaded = try store.list()
        XCTAssertEqual(loaded.map(\.label), ["Rent", "Investing", "Free"])
        XCTAssertEqual(loaded[1].id, savings.id)
        XCTAssertEqual(loaded[1].share, .percentage(15))
    }

    func testUpdateUnknownRuleThrowsRuleNotFound() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        XCTAssertThrowsError(try store.update(id: UUID(), label: "X", bucket: "X", share: .percentage(10))) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .ruleNotFound)
        }
    }

    // MARK: 4. Delete

    func testRemoveDeletesRule() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        let rent = try store.create(label: "Rent", bucket: "Rent", share: .percentage(40))
        try store.create(label: "Savings", bucket: "Savings", share: .percentage(20))

        try store.remove(id: rent.id)

        let loaded = try store.list()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.label, "Savings")
    }

    func testRemoveUnknownRuleThrowsRuleNotFound() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        XCTAssertThrowsError(try store.remove(id: UUID())) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .ruleNotFound)
        }
    }

    // MARK: 5. Honest empty when absent

    func testMissingFileDecodesToHonestEmptyState() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try store.list().isEmpty)
    }

    // MARK: 6. Create rejects a rule set that would exceed 100% and persists nothing

    func testCreateRejectsPercentageTotalOver100AndPersistsNothing() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        try store.create(label: "Rent", bucket: "Rent", share: .percentage(70))

        XCTAssertThrowsError(try store.create(label: "Savings", bucket: "Savings", share: .percentage(40))) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .percentageTotalExceeds100)
        }
        let loaded = try store.list()
        XCTAssertEqual(loaded.count, 1)
    }

    func testUpdateRejectsPercentageTotalOver100AndLeavesOriginalUnchanged() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        try store.create(label: "Rent", bucket: "Rent", share: .percentage(70))
        let savings = try store.create(label: "Savings", bucket: "Savings", share: .percentage(20))

        XCTAssertThrowsError(try store.update(id: savings.id, label: "Savings", bucket: "Savings", share: .percentage(40))) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .percentageTotalExceeds100)
        }
        let loaded = try store.list()
        XCTAssertEqual(loaded.first { $0.id == savings.id }?.share, .percentage(20))
    }

    func testCreateRejectsInvalidShareAndEmptyText() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)

        XCTAssertThrowsError(try store.create(label: "Rent", bucket: "Rent", share: .percentage(0))) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .invalidShare)
        }
        XCTAssertThrowsError(try store.create(label: "  ", bucket: "Rent", share: .percentage(10))) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .invalidLabel)
        }
        XCTAssertThrowsError(try store.create(label: "Rent", bucket: "  ", share: .percentage(10))) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .invalidBucket)
        }
        XCTAssertTrue(try store.list().isEmpty)
    }

    // MARK: 7. Preview end-to-end through the store delegates to the deterministic engine

    func testPreviewEndToEndMatchesEngineAndConservesCents() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        try store.create(label: "Rent", bucket: "Rent", share: .percentage(40))
        try store.create(label: "Savings", bucket: "Savings", share: .percentage(20))
        try store.create(label: "Free", bucket: "Free", share: .percentage(40))

        guard case .allocated(let preview) = try store.preview(incomeCents: 333_333) else {
            return XCTFail("expected an allocated preview")
        }
        let total = preview.lineItems.reduce(0) { $0 + $1.amountCents } + preview.unallocatedCents
        XCTAssertEqual(total, 333_333)
    }

    func testPreviewWithNoRulesIsNoAllocationConfigured() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        let result = try store.preview(incomeCents: 100_000)
        XCTAssertEqual(result, .noAllocationConfigured)
    }

    // MARK: 8. Backward-compatible decode of a minimal envelope

    func testMinimalEnvelopeJSONDecodesWithoutThrowing() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"rules":[]}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try FinanceAllocationStore(url: url)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testEnvelopeMissingRulesFieldDecodesToEmptyList() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try FinanceAllocationStore(url: url)
        XCTAssertTrue(try store.list().isEmpty)
    }

    // MARK: 9. Regression -- F5 test gap: corrupt bytes are refused, not decoded into garbage

    func testCorruptFileBytesThrowInvalidEnvelope() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]).write(to: url)

        let store = try FinanceAllocationStore(url: url)
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .invalidEnvelope)
        }
    }

    // MARK: 10. Regression -- F5 test gap: a schema version this store does not understand is refused

    func testSchemaVersionMismatchThrowsInvalidEnvelope() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":2,"rules":[]}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try FinanceAllocationStore(url: url)
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .invalidEnvelope)
        }
    }

    // MARK: 11. Regression -- F4: a persisted rule set with duplicate ids fails validation on load

    func testPersistedDuplicateRuleIDsFailValidationOnLoad() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let sharedID = UUID()
        let rules = [
            FinanceAllocationRule(id: sharedID, label: "A", bucket: "A", share: .fixedCents(500)),
            FinanceAllocationRule(id: sharedID, label: "B", bucket: "B", share: .percentage(50))
        ]
        let envelope = FinanceAllocationStoreEnvelope(rules: rules)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let store = try FinanceAllocationStore(url: url)
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .invalidEnvelope)
        }
    }

    // MARK: 12. Regression -- F5 test gap: update preserves createdAt

    func testUpdatePreservesCreatedAt() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceAllocationStore(url: url)
        _ = try store.create(label: "Rent", bucket: "Rent", share: .percentage(40))
        // Read back through the store (rather than trusting `create`'s
        // in-memory return value) so `originalCreatedAt` is the same
        // ISO8601-round-tripped value `update` will itself load from disk
        // and compare against -- ISO8601 truncates sub-second precision, so
        // comparing against the pre-persistence in-memory `Date` would be
        // an apples-to-oranges precision mismatch, not a real regression.
        let created = try store.list()[0]
        let originalCreatedAt = created.createdAt

        let updated = try store.update(id: created.id, label: "Rent2", bucket: "Rent2", share: .percentage(50))
        XCTAssertEqual(updated.createdAt, originalCreatedAt)

        let loaded = try store.list()
        XCTAssertEqual(loaded.first?.createdAt, originalCreatedAt)
    }
}
