import Foundation
import XCTest
@testable import LifeOS

final class FinanceTrackingPreferencesStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-tracking-prefs-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("finance-tracking-preferences.json", isDirectory: false)
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func preferences(
        frequency: FinanceTrackingFrequency = .monthly,
        anchor: Date? = nil,
        income: Bool = true,
        expense: Bool = true
    ) -> FinanceTrackingPreferences {
        FinanceTrackingPreferences(
            frequency: frequency,
            cycleAnchorDate: anchor ?? now,
            incomeTrackingEnabled: income,
            expenseTrackingEnabled: expense,
            updatedAt: now
        )
    }

    // MARK: 1. Honest empty when never configured

    func testCurrentIsNilWhenNeverConfigured() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        XCTAssertNil(try store.current())
        XCTAssertNil(try store.draft())
    }

    // MARK: 2. Direct commit round-trip survives relaunch

    func testCommitRoundTripSurvivesRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(preferences(frequency: .weekly))

        let relaunched = try FinanceTrackingPreferencesStore(url: url)
        let current = try relaunched.current()
        XCTAssertEqual(current?.frequency, .weekly)
    }

    // MARK: 3. Save/cancel: draft does not affect committed until commitDraft

    func testSaveDraftDoesNotChangeCommittedValue() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(preferences(frequency: .monthly))

        try store.saveDraft(preferences(frequency: .weekly))

        XCTAssertEqual(try store.current()?.frequency, .monthly)
        XCTAssertEqual(try store.draft()?.frequency, .weekly)
    }

    func testCommitDraftPromotesDraftToCommittedAndClearsDraft() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(preferences(frequency: .monthly))
        try store.saveDraft(preferences(frequency: .biweekly))

        let committed = try store.commitDraft()

        XCTAssertEqual(committed.frequency, .biweekly)
        XCTAssertEqual(try store.current()?.frequency, .biweekly)
        XCTAssertNil(try store.draft())
    }

    func testDiscardDraftLeavesCommittedUntouched() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(preferences(frequency: .monthly))
        try store.saveDraft(preferences(frequency: .weekly))

        try store.discardDraft()

        XCTAssertEqual(try store.current()?.frequency, .monthly)
        XCTAssertNil(try store.draft())
    }

    func testCommitDraftWithNoDraftThrows() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        XCTAssertThrowsError(try store.commitDraft()) { error in
            XCTAssertEqual(error as? FinanceTrackingPreferencesStoreError, .noDraftToCommit)
        }
    }

    func testDiscardDraftWithNoDraftIsANoOp() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(preferences(frequency: .monthly))
        XCTAssertNoThrow(try store.discardDraft())
        XCTAssertEqual(try store.current()?.frequency, .monthly)
    }

    // MARK: 4. Custom day-of-month validation

    func testCustomFrequencyRequiresAValidDayOfMonth() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)

        XCTAssertThrowsError(try store.commit(preferences(frequency: .customDayOfMonth(0)))) { error in
            XCTAssertEqual(error as? FinanceTrackingPreferencesStoreError, .invalidCustomDayOfMonth)
        }
        XCTAssertThrowsError(try store.commit(preferences(frequency: .customDayOfMonth(32)))) { error in
            XCTAssertEqual(error as? FinanceTrackingPreferencesStoreError, .invalidCustomDayOfMonth)
        }
        XCTAssertNoThrow(try store.commit(preferences(frequency: .customDayOfMonth(1))))
        XCTAssertNoThrow(try store.commit(preferences(frequency: .customDayOfMonth(31))))
        XCTAssertEqual(try store.current()?.frequency, .customDayOfMonth(31))
    }

    func testInvalidCustomDayIsRejectedForDraftToo() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        XCTAssertThrowsError(try store.saveDraft(preferences(frequency: .customDayOfMonth(0)))) { error in
            XCTAssertEqual(error as? FinanceTrackingPreferencesStoreError, .invalidCustomDayOfMonth)
        }
        XCTAssertNil(try store.draft())
    }

    // MARK: 5. Invalid anchor date rejected

    func testInvalidAnchorDateIsRejected() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        let invalid = preferences(anchor: Date(timeIntervalSinceReferenceDate: .nan))
        XCTAssertThrowsError(try store.commit(invalid)) { error in
            XCTAssertEqual(error as? FinanceTrackingPreferencesStoreError, .invalidAnchorDate)
        }
    }

    // MARK: 6. Income/expense toggles preserved through persistence

    func testIncomeAndExpenseTogglesArePreserved() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(preferences(income: true, expense: false))

        let relaunched = try FinanceTrackingPreferencesStore(url: url)
        let current = try relaunched.current()
        XCTAssertEqual(current?.incomeTrackingEnabled, true)
        XCTAssertEqual(current?.expenseTrackingEnabled, false)
    }

    // MARK: 7. Backward-compatible decode of a minimal envelope

    func testMinimalEnvelopeJSONDecodesWithoutThrowing() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try FinanceTrackingPreferencesStore(url: url)
        XCTAssertNil(try store.current())
        XCTAssertNil(try store.draft())
    }
}
