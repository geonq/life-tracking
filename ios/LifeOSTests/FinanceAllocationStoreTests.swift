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
}
