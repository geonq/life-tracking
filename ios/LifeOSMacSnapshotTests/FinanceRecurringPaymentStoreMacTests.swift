import Foundation
import XCTest
@testable import LifeOSMac

final class FinanceRecurringPaymentStoreMacTests: XCTestCase {
    func testOverridesAndRebuildableEvidenceCacheSurviveRestartWithRevisionConflicts() throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("store")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try FinanceRecurringPaymentStore(url: url)
        let key = try FinanceRecurringPaymentKey(
            sourceNamespace: "genericCSV",
            accountID: FinanceRecurringTestFixtures.accountID,
            currency: "EUR",
            normalizedMerchantKey: "streaming provider"
        )
        let initial = try store.load()
        XCTAssertEqual(initial.revision, 0)

        let paused = try FinanceRecurringPaymentOverride(key: key, status: .paused)
        let saved = try store.saveOverride(paused, expectedRevision: initial.revision)
        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(saved.overrides.first?.status, .paused)

        XCTAssertThrowsError(try store.saveOverride(paused, expectedRevision: 0)) { error in
            XCTAssertEqual(error as? FinanceRecurringPaymentStoreError, .revisionConflict)
        }

        let reopened = try FinanceRecurringPaymentStore(url: url)
        let reloaded = try reopened.load()
        XCTAssertEqual(reloaded, saved)

        let assessment = try FinanceRecurringPaymentAssessment(
            candidates: [],
            exclusions: [],
            coverage: .noValidatedMappedImports,
            timeZoneIdentifier: "Europe/Berlin",
            generatedAt: try FinanceRecurringTestFixtures.date(2026, 5, 1)
        )
        let cached = try reopened.saveAssessment(
            assessment,
            inputDigest: String(repeating: "d", count: 64),
            expectedRevision: reloaded.revision
        )
        XCTAssertEqual(cached.revision, 2)
        XCTAssertEqual(try reopened.load().evidenceCache?.assessment, assessment)

        let cleared = try reopened.clearOverride(for: key, expectedRevision: cached.revision)
        XCTAssertEqual(cleared.revision, 3)
        XCTAssertTrue(cleared.overrides.isEmpty)
        XCTAssertNotNil(cleared.evidenceCache, "clearing a decision must not erase rebuildable evidence")
    }

    func testOversizedAndCorruptStateFailsClosed() throws {
        let oversizedURL = FinanceRecurringTestFixtures.temporaryURL("oversized")
        defer { try? FileManager.default.removeItem(at: oversizedURL) }
        try Data(repeating: 0, count: FinanceRecurringPaymentStore.maximumStateBytes + 1).write(to: oversizedURL)
        XCTAssertThrowsError(try FinanceRecurringPaymentStore(url: oversizedURL).load()) { error in
            XCTAssertEqual(error as? FinanceRecurringPaymentStoreError, .stateTooLarge)
        }

        let corruptURL = FinanceRecurringTestFixtures.temporaryURL("corrupt")
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        try Data("not-json".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try FinanceRecurringPaymentStore(url: corruptURL).load()) { error in
            XCTAssertEqual(error as? FinanceRecurringPaymentStoreError, .invalidEnvelope)
        }
    }

    func testFixturePathsAreInterpolatedAndUnique() {
        let first = FinanceRecurringTestFixtures.temporaryURL("fixture")
        let second = FinanceRecurringTestFixtures.temporaryURL("fixture")

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("lifeos-recurring-fixture-"))
        XCTAssertFalse(first.lastPathComponent.contains("(label)"))
        XCTAssertFalse(first.lastPathComponent.contains("(UUID"))
    }
}
