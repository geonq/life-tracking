import Foundation
import XCTest
@testable import LifeOS

final class NutritionGoalStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-nutrition-goal-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nutrition-goals.json", isDirectory: false)
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func goal(
        effectiveFrom: Date? = nil,
        calorieTarget: Int? = 2_200,
        protein: Int? = 160,
        carb: Int? = 220,
        fat: Int? = 70
    ) -> NutritionGoal {
        NutritionGoal(
            effectiveFrom: effectiveFrom ?? now,
            calorieTarget: calorieTarget,
            proteinGramsTarget: protein,
            carbGramsTarget: carb,
            fatGramsTarget: fat,
            createdAt: now
        )
    }

    // MARK: 1. Persistence round-trip + reload-after-relaunch

    func testPersistenceRoundTripSurvivesRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionGoalStore(url: url)
        let original = goal(calorieTarget: 2_400)
        try store.setGoal(original)

        let relaunched = try NutritionGoalStore(url: url)
        let loaded = try relaunched.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, original.id)
        XCTAssertEqual(loaded.first?.calorieTarget, 2_400)
        XCTAssertEqual(loaded.first?.proteinGramsTarget, 160)
    }

    // MARK: 2. Current-goal-by-date resolution (latest effective)

    func testCurrentGoalResolvesLatestEffectiveOnOrBeforeDate() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionGoalStore(url: url)

        let earlier = goal(effectiveFrom: now.addingTimeInterval(-86_400 * 10), calorieTarget: 2_000)
        let later = goal(effectiveFrom: now.addingTimeInterval(-86_400 * 2), calorieTarget: 2_300)
        let future = goal(effectiveFrom: now.addingTimeInterval(86_400 * 30), calorieTarget: 2_600)
        try store.setGoal(earlier)
        try store.setGoal(later)
        try store.setGoal(future)

        let current = try store.currentGoal(on: now, calendar: utcCalendar)
        XCTAssertEqual(current?.id, later.id)
        XCTAssertEqual(current?.calorieTarget, 2_300)

        // The future-dated goal is not yet in effect.
        XCTAssertNotEqual(current?.id, future.id)
    }

    func testCurrentGoalResolvesExactDayBoundary() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionGoalStore(url: url)
        let today = goal(effectiveFrom: now, calorieTarget: 2_100)
        try store.setGoal(today)

        let current = try store.currentGoal(on: now, calendar: utcCalendar)
        XCTAssertEqual(current?.id, today.id)
    }

    // MARK: 3. Honest-empty when absent

    func testMissingFileDecodesToHonestEmptyState() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionGoalStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testCurrentGoalIsNilWhenNoGoalEverSet() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionGoalStore(url: url)
        let current = try store.currentGoal(on: now, calendar: utcCalendar)
        XCTAssertNil(current)
    }

    func testCurrentGoalIsNilWhenAllGoalsAreInTheFuture() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionGoalStore(url: url)
        try store.setGoal(goal(effectiveFrom: now.addingTimeInterval(86_400 * 5)))

        let current = try store.currentGoal(on: now, calendar: utcCalendar)
        XCTAssertNil(current)
    }

    // MARK: 4. Nil-vs-zero targets preserved

    func testNilAndExplicitZeroTargetsAreDistinctAfterRoundTrip() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionGoalStore(url: url)
        let partial = NutritionGoal(
            effectiveFrom: now,
            calorieTarget: 1_800,
            proteinGramsTarget: 0,
            carbGramsTarget: nil,
            fatGramsTarget: nil,
            createdAt: now
        )
        try store.setGoal(partial)

        let loaded = try store.load()
        XCTAssertEqual(loaded.first?.proteinGramsTarget, 0)
        XCTAssertNil(loaded.first?.carbGramsTarget)
        XCTAssertNil(loaded.first?.fatGramsTarget)
        XCTAssertFalse(loaded.first?.isEmpty ?? true)
    }

    func testGoalWithAllTargetsUnsetIsEmpty() throws {
        let unset = NutritionGoal(effectiveFrom: now)
        XCTAssertTrue(unset.isEmpty)
        XCTAssertNil(unset.calorieTarget)
        XCTAssertNil(unset.proteinGramsTarget)
        XCTAssertNil(unset.carbGramsTarget)
        XCTAssertNil(unset.fatGramsTarget)
    }

    // MARK: 5. History ordering

    func testHistoryIsSortedByEffectiveFromAscending() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionGoalStore(url: url)
        let third = goal(effectiveFrom: now.addingTimeInterval(86_400 * 2), calorieTarget: 2_500)
        let first = goal(effectiveFrom: now.addingTimeInterval(-86_400 * 2), calorieTarget: 2_000)
        let second = goal(effectiveFrom: now, calorieTarget: 2_200)
        try store.setGoal(third)
        try store.setGoal(first)
        try store.setGoal(second)

        let history = try store.history()
        XCTAssertEqual(history.map(\.calorieTarget), [2_000, 2_200, 2_500])
    }

    // MARK: 6. Backward-compatible decode of a pre-field/minimal file

    func testMinimalEnvelopeJSONDecodesWithoutThrowing() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"goals":[]}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try NutritionGoalStore(url: url)
        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testEnvelopeMissingGoalsFieldDecodesToEmptyList() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try NutritionGoalStore(url: url)
        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Helpers

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
