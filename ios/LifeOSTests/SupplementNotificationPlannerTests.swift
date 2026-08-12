import Foundation
import XCTest
@testable import LifeOS

final class SupplementNotificationPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)

    private func berlinCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func plan(
        id: String = "magnesium-200",
        weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7],
        localTime: String = "09:00",
        timeZone: String = "Europe/Berlin",
        startDate: String = "2026-03-01",
        endDate: String? = nil,
        pauseRanges: [(String, String)] = [],
        timingNote: String? = "before lunch",
        preference: SupplementNotificationPreference = .productAndTiming,
        reminderEnabled: Bool = true,
        lockScreenRedacted: Bool = false,
        name: String = "Magnesium"
    ) throws -> SupplementPlan {
        let pauses = try pauseRanges.map {
            try SupplementSchedulePauseRange(startDate: $0.0, endDate: $0.1)
        }
        let schedule = try SupplementSchedule(
            weekdays: weekdays,
            localTime: localTime,
            timeZoneIdentifier: timeZone,
            timingNote: timingNote,
            startDate: startDate,
            endDate: endDate,
            pauseRanges: pauses,
            notificationPreference: preference,
            calendarOverlayEnabled: false
        )
        return try SupplementPlan(
            id: id,
            name: name,
            brand: "User-entered product",
            form: .capsule,
            strength: "200 mg",
            servingUnit: "capsule",
            userDose: try SupplementDose(amount: 2, unit: "capsule"),
            inventoryUnitsPerDose: 2,
            schedule: schedule,
            source: .manual,
            stockUnits: 20,
            reorderThreshold: 5,
            reminderEnabled: reminderEnabled,
            lockScreenRedacted: lockScreenRedacted,
            revision: 1,
            updatedAt: now.addingTimeInterval(-60)
        )
    }

    private func localDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: String = "Europe/Berlin"
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func localDateStrings(
        _ intents: [SupplementNotificationIntent],
        timeZone: String = "Europe/Berlin"
    ) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = "yyyy-MM-dd"
        return intents.map { formatter.string(from: $0.fireDate) }
    }

    func testEnabledSchedulesAreDedupedAndBounded() throws {
        let enabled = try plan()
        let disabled = try plan(id: "disabled", reminderEnabled: false)
        let preferenceDisabled = try plan(id: "preference-disabled", preference: .disabled, reminderEnabled: false)
        let planner = SupplementNotificationPlanner(
            now: localDate(2026, 8, 9, 08, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 30,
            maxPendingIntents: 3
        )

        let result = try planner.plan(plans: [enabled, enabled, disabled, preferenceDisabled])
        XCTAssertEqual(result.intents.count, 3)
        XCTAssertEqual(result.intents.count, result.identifiers.count)
        XCTAssertTrue(result.intents.allSatisfy { $0.planID == enabled.id })
        XCTAssertTrue(result.intents.allSatisfy { SupplementNotificationPlanner.isLifeOSIdentifier($0.identifier) })
    }

    func testConfiguredMaxPendingIntentsIsClampedToAppleLimit() throws {
        let scheduled = try plan()
        let planner = SupplementNotificationPlanner(
            now: localDate(2026, 8, 9, 08, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 366,
            maxPendingIntents: 999
        )

        let result = try planner.plan(plans: [scheduled])

        XCTAssertEqual(result.maxPendingIntents, 64)
        XCTAssertEqual(result.intents.count, 64)
    }

    func testStableIDsAndScheduleTimezoneSurviveRebootAndDeviceTimezoneChange() throws {
        let scheduled = try plan(
            weekdays: [1, 2, 3],
            localTime: "11:30",
            timeZone: "Europe/Berlin",
            startDate: "2026-08-01"
        )
        let fixedNow = localDate(2026, 8, 9, 08, 00)
        var deviceBerlin = Calendar(identifier: .gregorian)
        deviceBerlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var deviceLosAngeles = Calendar(identifier: .gregorian)
        deviceLosAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let first = try SupplementNotificationPlanner(
            now: fixedNow,
            calendar: deviceBerlin,
            lookAheadDays: 10
        ).plan(plans: [scheduled])
        let afterReboot = try SupplementNotificationPlanner(
            now: fixedNow,
            calendar: deviceBerlin,
            lookAheadDays: 10
        ).plan(plans: [scheduled])
        let afterDeviceTimezoneChange = try SupplementNotificationPlanner(
            now: fixedNow,
            calendar: deviceLosAngeles,
            lookAheadDays: 10
        ).plan(plans: [scheduled])

        XCTAssertEqual(first.intents, afterReboot.intents)
        XCTAssertEqual(first.intents.map(\.identifier), afterDeviceTimezoneChange.intents.map(\.identifier))
        XCTAssertEqual(first.intents.map(\.fireDate), afterDeviceTimezoneChange.intents.map(\.fireDate))
        XCTAssertEqual(
            SupplementNotificationPlanner.scheduleIdentifier(planID: scheduled.id),
            "lifeos.supplement.schedule.magnesium-200"
        )
        XCTAssertEqual(
            first.intents.first?.scheduleIdentifier,
            "lifeos.supplement.schedule.magnesium-200"
        )
    }

    func testMaxLengthPlanUsesSafeStableDomainIDAndNamespacedRequestID() throws {
        let maxLengthPlanID = "p" + String(repeating: "x", count: 127)
        let domainID = SupplementNotificationPlanner.occurrenceIdentifier(
            planID: maxLengthPlanID,
            localDate: "2026-08-09",
            localTime: "09:00"
        )
        let repeatedDomainID = SupplementNotificationPlanner.occurrenceIdentifier(
            planID: maxLengthPlanID,
            localDate: "2026-08-09",
            localTime: "09:00"
        )
        let requestID = SupplementNotificationPlanner.occurrenceRequestIdentifier(
            occurrenceID: domainID
        )

        XCTAssertEqual(domainID, repeatedDomainID)
        XCTAssertLessThanOrEqual(domainID.utf8.count, 128)
        XCTAssertNotNil(domainID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression))
        XCTAssertTrue(requestID.hasPrefix("lifeos.supplement.occurrence."))
        XCTAssertEqual(requestID, "lifeos.supplement.occurrence.\(domainID)")

        let longPlan = try plan(id: maxLengthPlanID)
        let result = try SupplementNotificationPlanner(
            now: localDate(2026, 8, 9, 08, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 0
        ).plan(plans: [longPlan])

        XCTAssertEqual(result.intents.count, 1)
        let intent = try XCTUnwrap(result.intents.first)
        XCTAssertEqual(intent.occurrenceIdentifier, domainID)
        XCTAssertEqual(intent.identifier, requestID)
    }

    func testStartEndAndInclusivePauseRangesAreHonored() throws {
        let bounded = try plan(
            weekdays: [1, 2, 3, 4, 5, 6, 7],
            localTime: "09:00",
            startDate: "2026-08-10",
            endDate: "2026-08-15",
            pauseRanges: [("2026-08-12", "2026-08-13")]
        )
        let planner = SupplementNotificationPlanner(
            now: localDate(2026, 8, 10, 08, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 30
        )
        let result = try planner.plan(plans: [bounded])
        XCTAssertEqual(localDateStrings(result.intents), ["2026-08-10", "2026-08-11", "2026-08-14", "2026-08-15"])
        XCTAssertFalse(localDateStrings(result.intents).contains("2026-08-12"))
        XCTAssertFalse(localDateStrings(result.intents).contains("2026-08-13"))
    }

    func testDSTNonexistentTimeUsesNextValidTimeAndRepeatedTimeUsesFirstOnly() throws {
        let spring = try plan(
            weekdays: [1],
            localTime: "02:30",
            startDate: "2026-03-29",
            endDate: "2026-03-29"
        )
        let springResult = try SupplementNotificationPlanner(
            now: localDate(2026, 3, 29, 00, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 1
        ).plan(plans: [spring])
        XCTAssertEqual(springResult.intents.count, 1)
        let springIntent = try XCTUnwrap(springResult.intents.first)
        XCTAssertEqual(springIntent.resolution, .nextValidTime)
        XCTAssertEqual(springIntent.localTime, "03:00")
        XCTAssertEqual(springIntent.localDate, "2026-03-29")

        let autumn = try plan(
            weekdays: [1],
            localTime: "02:30",
            startDate: "2026-10-25",
            endDate: "2026-10-25"
        )
        let autumnResult = try SupplementNotificationPlanner(
            now: localDate(2026, 10, 25, 00, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 1
        ).plan(plans: [autumn])
        XCTAssertEqual(autumnResult.intents.count, 1)
        let autumnIntent = try XCTUnwrap(autumnResult.intents.first)
        XCTAssertEqual(autumnIntent.resolution, .firstRepeatedTime)
        XCTAssertEqual(autumnIntent.localTime, "02:30")
        XCTAssertEqual(
            autumnResult.intents.map(\.occurrenceIdentifier),
            [SupplementNotificationPlanner.occurrenceIdentifier(
                planID: autumn.id,
                localDate: "2026-10-25",
                localTime: "02:30"
            )]
        )
    }

    func testCopyRespectsPrivatePreferenceAndNeverIncludesDoseFacts() throws {
        let product = try plan(preference: .productAndTiming, lockScreenRedacted: false)
        let productCopy = SupplementNotificationCopy.make(for: product)
        XCTAssertFalse(productCopy.isPrivate)
        XCTAssertTrue(productCopy.body.contains("Magnesium"))
        XCTAssertTrue(productCopy.body.contains("before lunch"))
        XCTAssertFalse(productCopy.body.contains("200 mg"))
        XCTAssertFalse(productCopy.body.contains("2 capsule"))

        let generic = try plan(preference: .genericPrivate, lockScreenRedacted: false)
        let genericCopy = SupplementNotificationCopy.make(for: generic)
        XCTAssertTrue(genericCopy.isPrivate)
        XCTAssertFalse(genericCopy.body.contains("Magnesium"))
        XCTAssertFalse(genericCopy.body.contains("200 mg"))
        XCTAssertFalse(genericCopy.body.contains("2 capsule"))

        let locked = try plan(preference: .productAndTiming, lockScreenRedacted: true)
        XCTAssertTrue(SupplementNotificationCopy.make(for: locked).isPrivate)
    }

    func testMissedOccurrenceIsNotRescheduledAndSnoozeReusesOneStableOccurrence() throws {
        let scheduled = try plan(
            weekdays: [1],
            localTime: "09:00",
            startDate: "2026-08-09",
            endDate: "2026-08-09"
        )
        let occurrenceID = SupplementNotificationPlanner.occurrenceIdentifier(
            planID: scheduled.id,
            localDate: "2026-08-09",
            localTime: "09:00"
        )
        let missed = try SupplementOccurrence(
            id: occurrenceID,
            planID: scheduled.id,
            scheduledFor: localDate(2026, 8, 9, 09, 00),
            state: .missed,
            revision: 1,
            updatedAt: now.addingTimeInterval(-120)
        )
        let missedResult = try SupplementNotificationPlanner(
            now: localDate(2026, 8, 9, 10, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 1
        ).plan(plans: [scheduled], occurrences: [missed])
        XCTAssertTrue(missedResult.intents.isEmpty)

        let snoozeUntil = localDate(2026, 8, 9, 10, 30)
        let snoozed = try SupplementOccurrence(
            id: occurrenceID,
            planID: scheduled.id,
            scheduledFor: localDate(2026, 8, 9, 09, 00),
            state: .snoozed,
            actedAt: localDate(2026, 8, 9, 09, 15),
            snoozedUntil: snoozeUntil,
            revision: 1,
            updatedAt: now.addingTimeInterval(-120)
        )
        let snoozeResult = try SupplementNotificationPlanner(
            now: localDate(2026, 8, 9, 09, 30),
            calendar: berlinCalendar(),
            lookAheadDays: 1
        ).plan(plans: [scheduled], occurrences: [snoozed])
        XCTAssertEqual(snoozeResult.intents.count, 1)
        XCTAssertEqual(snoozeResult.intents[0].occurrenceIdentifier, occurrenceID)
        XCTAssertEqual(snoozeResult.intents[0].fireDate, snoozeUntil)
        XCTAssertEqual(snoozeResult.intents[0].resolution, .snoozed)
    }

    func testPriorLocalDateSnoozeProducesOneNamespacedRequestForItsDomainID() throws {
        let scheduled = try plan(
            weekdays: [1],
            localTime: "09:00",
            startDate: "2026-08-09",
            endDate: "2026-08-09"
        )
        let occurrenceID = SupplementNotificationPlanner.occurrenceIdentifier(
            planID: scheduled.id,
            localDate: "2026-08-09",
            localTime: "09:00"
        )
        let snoozedUntil = localDate(2026, 8, 10, 10, 30)
        let snoozed = try SupplementOccurrence(
            id: occurrenceID,
            planID: scheduled.id,
            scheduledFor: localDate(2026, 8, 9, 09, 00),
            state: .snoozed,
            actedAt: localDate(2026, 8, 9, 09, 15),
            snoozedUntil: snoozedUntil,
            revision: 1,
            updatedAt: now.addingTimeInterval(-120)
        )

        let result = try SupplementNotificationPlanner(
            now: localDate(2026, 8, 10, 09, 30),
            calendar: berlinCalendar(),
            lookAheadDays: 1
        ).plan(plans: [scheduled], occurrences: [snoozed])

        XCTAssertEqual(result.intents.count, 1)
        XCTAssertEqual(result.intents[0].occurrenceIdentifier, occurrenceID)
        XCTAssertEqual(
            result.intents[0].identifier,
            SupplementNotificationPlanner.occurrenceRequestIdentifier(occurrenceID: occurrenceID)
        )
        XCTAssertEqual(result.intents[0].fireDate, snoozedUntil)
        XCTAssertEqual(result.intents[0].resolution, .snoozed)
    }

    func testPlannerRejectsPlansAndOccurrencesMutatedAfterInitialization() throws {
        let validPlan = try plan()
        var invalidPlan = validPlan
        invalidPlan.stockUnits = -1

        let planner = SupplementNotificationPlanner(
            now: localDate(2026, 8, 9, 08, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 1
        )
        XCTAssertThrowsError(try planner.plan(plans: [invalidPlan]))

        let validOccurrence = try SupplementOccurrence(
            id: "magnesium-occurrence",
            planID: validPlan.id,
            scheduledFor: localDate(2026, 8, 9, 09, 00),
            revision: 1,
            updatedAt: now.addingTimeInterval(-120)
        )
        var invalidOccurrence = validOccurrence
        invalidOccurrence.state = .snoozed

        XCTAssertThrowsError(
            try planner.plan(plans: [validPlan], occurrences: [invalidOccurrence])
        )
    }

    func testGenericPrivateCopyDoesNotLeakAdversarialTimingNoteFacts() throws {
        let generic = try plan(
            timingNote: "Magnesium 200 mg 2 capsule",
            preference: .genericPrivate
        )
        let result = try SupplementNotificationPlanner(
            now: localDate(2026, 8, 9, 08, 00),
            calendar: berlinCalendar(),
            lookAheadDays: 0
        ).plan(plans: [generic])

        XCTAssertEqual(result.intents.count, 1)
        let copy = try XCTUnwrap(result.intents.first)
        XCTAssertTrue(copy.isPrivate)
        let notificationText = "\(copy.title) \(copy.body)"
        for sensitiveFact in ["Magnesium", "200 mg", "2 capsule"] {
            XCTAssertFalse(notificationText.contains(sensitiveFact), sensitiveFact)
        }
    }

    func testTypedActionsHaveStableIdentifiersAndRejectUnrelatedResponses() throws {
        let userInfo = [
            SupplementNotificationActionIdentifier.planIDKey: "magnesium-200",
            SupplementNotificationActionIdentifier.occurrenceIDKey: "occurrence-1",
        ]
        XCTAssertEqual(
            try SupplementNotificationActionDecoder.decode(
                actionIdentifier: SupplementNotificationActionIdentifier.taken,
                userInfo: userInfo
            ),
            .taken(try SupplementNotificationActionContext(planID: "magnesium-200", occurrenceID: "occurrence-1"))
        )
        XCTAssertEqual(
            try SupplementNotificationActionDecoder.decode(
                actionIdentifier: SupplementNotificationActionIdentifier.snooze,
                userInfo: userInfo,
                categoryIdentifier: SupplementNotificationActionIdentifier.category
            ),
            .snooze(try SupplementNotificationActionContext(planID: "magnesium-200", occurrenceID: "occurrence-1"))
        )
        XCTAssertEqual(
            try SupplementNotificationActionDecoder.decode(
                actionIdentifier: SupplementNotificationActionIdentifier.skip,
                userInfo: userInfo
            ),
            .skip(try SupplementNotificationActionContext(planID: "magnesium-200", occurrenceID: "occurrence-1"))
        )
        XCTAssertThrowsError(try SupplementNotificationActionDecoder.decode(
            actionIdentifier: "com.other.app.action",
            userInfo: userInfo
        ))
        XCTAssertThrowsError(try SupplementNotificationActionDecoder.decode(
            actionIdentifier: SupplementNotificationActionIdentifier.taken,
            userInfo: userInfo,
            categoryIdentifier: "com.other.app.category"
        ))
        XCTAssertThrowsError(try SupplementNotificationActionDecoder.decode(
            actionIdentifier: SupplementNotificationActionIdentifier.taken,
            userInfo: [:]
        ))
    }
}
