import Foundation
import XCTest
@testable import LifeOS

final class FitnessSupplementSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func supplement(
        id: String = "magnesium",
        dose: String? = "2 capsules",
        stock: Int = 10,
        unitsPerDose: Int = 2,
        timing: String = "11:30",
        timeZone: String = "Europe/Berlin",
        days: Set<Int> = [3]
    ) -> FitnessSupplement {
        FitnessSupplement(
            id: id,
            name: "Magnesium",
            brand: "User-entered product",
            form: .capsule,
            strength: "200 mg",
            servingUnit: "capsule",
            userDose: dose,
            inventoryUnitsPerDose: unitsPerDose,
            timing: timing,
            timeZoneIdentifier: timeZone,
            scheduledDays: days,
            stockUnits: stock,
            reorderThreshold: 2,
            expectedLeadTimeDays: 7
        )
    }

    func testMappingUsesSelectedLocalDateTimezoneWeekdayAndKeepsBlankDoseBlank() throws {
        let selectedDate = Date(timeIntervalSince1970: 1_786_449_600)
        let session = try FitnessSupplementSession(
            supplements: [supplement(dose: "", timing: "Before lunch")],
            selectedDate: selectedDate,
            now: now
        )

        XCTAssertEqual(session.selectedLocalDate, "2026-08-11")
        XCTAssertEqual(session.selectedWeekday, 3) // Foundation: Sunday = 1.
        let plan = try XCTUnwrap(session.plan(for: "magnesium"))
        XCTAssertEqual(plan.schedule.localTime, "00:00")
        XCTAssertEqual(plan.schedule.timingNote, "Before lunch")
        XCTAssertEqual(plan.schedule.notificationPreference, .disabled)
        XCTAssertFalse(plan.reminderEnabled)
        XCTAssertEqual(plan.schedule.weekdays, [3])
        XCTAssertNil(plan.userDose)
        let occurrence = try XCTUnwrap(session.occurrence(for: "magnesium"))
        XCTAssertEqual(occurrence.state, .planned)
        XCTAssertTrue(occurrence.id.contains("2026-08-11"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(calendar.component(.hour, from: occurrence.scheduledFor), 12)
    }

    func testExplicitClockTimingSurvivesIntoOccurrenceAndIsActionable() throws {
        let session = try FitnessSupplementSession(
            supplements: [supplement(timing: "11:30")],
            selectedDate: now,
            now: now
        )
        let plan = try XCTUnwrap(session.plan(for: "magnesium"))
        XCTAssertEqual(plan.schedule.localTime, "11:30")
        XCTAssertEqual(plan.schedule.notificationPreference, .productAndTiming)
        XCTAssertTrue(plan.reminderEnabled)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let occurrence = try XCTUnwrap(session.occurrence(for: "magnesium"))
        XCTAssertEqual(calendar.component(.hour, from: occurrence.scheduledFor), 11)
        XCTAssertEqual(calendar.component(.minute, from: occurrence.scheduledFor), 30)
    }

    func testInvalidDoseIsRejectedInsteadOfInventingNumericDose() {
        XCTAssertThrowsError(
            try FitnessSupplementSession(
                supplements: [supplement(dose: "take two")],
                selectedDate: now,
                now: now
            )
        )
    }

    func testTakenIsIdempotentAndDecrementsExactlyOnce() throws {
        var session = try FitnessSupplementSession(
            supplements: [supplement(stock: 10)],
            selectedDate: now,
            now: now
        )
        let first = try session.apply(
            .taken,
            to: "magnesium",
            actionID: "taken-1",
            occurredAt: now,
            now: now
        )
        let afterFirst = session
        XCTAssertFalse(first.idempotent)
        XCTAssertEqual(first.inventoryDelta, -2)
        XCTAssertEqual(session.stock(for: "magnesium"), 8)
        XCTAssertEqual(session.snapshot.inventoryEvents.count, 1)

        let replay = try session.apply(
            .taken,
            to: "magnesium",
            actionID: "taken-1",
            occurredAt: now,
            now: now
        )
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(replay.inventoryDelta, 0)
        XCTAssertEqual(session, afterFirst)
    }

    func testSnoozeAndSkipDoNotChangeInventory() throws {
        var session = try FitnessSupplementSession(
            supplements: [supplement(stock: 10)],
            selectedDate: now,
            now: now
        )
        _ = try session.apply(
            .snooze,
            to: "magnesium",
            actionID: "snooze-1",
            occurredAt: now,
            snoozeUntil: now.addingTimeInterval(300),
            now: now
        )
        XCTAssertEqual(session.stock(for: "magnesium"), 10)
        _ = try session.apply(.skip, to: "magnesium", actionID: "skip-1", occurredAt: now, now: now)
        XCTAssertEqual(session.stock(for: "magnesium"), 10)
        XCTAssertEqual(session.snapshot.inventoryEvents.count, 0)
    }

    func testDefaultActionIDsAllowRepeatedSnoozesAtNewRevision() throws {
        var session = try FitnessSupplementSession(
            supplements: [supplement(stock: 10)],
            selectedDate: now,
            now: now
        )
        let first = try session.apply(.snooze, to: "magnesium", occurredAt: now, now: now)
        let second = try session.apply(.snooze, to: "magnesium", occurredAt: now, now: now)
        XCTAssertFalse(first.idempotent)
        XCTAssertFalse(second.idempotent)
        XCTAssertEqual(session.snapshot.revision, 2)
        XCTAssertEqual(session.stock(for: "magnesium"), 10)
    }

    func testIllegalTransitionSurfacesAndLeavesSessionUnchanged() throws {
        var session = try FitnessSupplementSession(
            supplements: [supplement(stock: 10)],
            selectedDate: now,
            now: now
        )
        _ = try session.apply(.taken, to: "magnesium", actionID: "taken-1", occurredAt: now, now: now)
        let before = session
        XCTAssertThrowsError(
            try session.apply(.skip, to: "magnesium", actionID: "skip-after-taken", occurredAt: now, now: now)
        )
        XCTAssertEqual(session, before)
    }

    func testInsufficientInventoryFloorsAtZeroWithoutNegativeStock() throws {
        var session = try FitnessSupplementSession(
            supplements: [supplement(stock: 1, unitsPerDose: 2)],
            selectedDate: now,
            now: now
        )
        let partial = try session.apply(.taken, to: "magnesium", actionID: "taken-partial", occurredAt: now, now: now)
        XCTAssertEqual(partial.inventoryDelta, -1)
        XCTAssertEqual(session.stock(for: "magnesium"), 0)

        var empty = try FitnessSupplementSession(
            supplements: [supplement(stock: 0, unitsPerDose: 2)],
            selectedDate: now,
            now: now
        )
        let noInventory = try empty.apply(.taken, to: "magnesium", actionID: "taken-empty", occurredAt: now, now: now)
        XCTAssertEqual(noInventory.inventoryDelta, 0)
        XCTAssertEqual(empty.stock(for: "magnesium"), 0)
        XCTAssertTrue(empty.snapshot.inventoryEvents.isEmpty)
    }

    func testSessionAddIsLocalAndFailedAddDoesNotMutateExistingState() throws {
        var session = try FitnessSupplementSession(supplements: [], selectedDate: now, now: now)
        try session.add(supplement(id: "first"), now: now)
        let before = session
        XCTAssertEqual(session.records.map(\.id), ["first"])

        XCTAssertThrowsError(try session.add(supplement(id: "first", dose: "invalid"), now: now))
        XCTAssertEqual(session, before)
    }
}
