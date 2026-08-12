import Foundation
import XCTest
@testable import LifeOS

final class SupplementDomainTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func decode<T: Decodable>(_ object: Any, as type: T.Type, now: Date? = nil) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = now ?? self.now
        return try decoder.decode(type, from: data)
    }

    private func planObject(stockUnits: Int = 18, inventoryUnitsPerDose: Int = 2) -> [String: Any] {
        [
            "id": "magnesium-200",
            "name": "Magnesium",
            "brand": "User-entered product",
            "productIdentifier": "batch-a",
            "form": "capsule",
            "strength": "200 mg",
            "servingUnit": "capsule",
            "userDose": ["amount": 1.234, "unit": "capsule"],
            "inventoryUnitsPerDose": inventoryUnitsPerDose,
            "schedule": [
                "weekdays": [1, 3, 5],
                "localTime": "11:30",
                "timeZoneIdentifier": "Europe/Berlin",
                "timingNote": "Before lunch",
                "startDate": "2026-08-01",
                "endDate": "2026-12-31",
                "pauseRanges": [["startDate": "2026-09-01", "endDate": "2026-09-03"]],
                "notificationPreference": "product_and_timing",
                "calendarOverlayEnabled": true,
            ],
            "source": "manual",
            "productLabelNote": ["text": "Take with food.", "sourceDate": "2026-07-30"],
            "notes": "User-entered plan",
            "stockUnits": stockUnits,
            "reorderThreshold": 5,
            "expectedLeadTimeDays": 7,
            "expiryDate": iso(now.addingTimeInterval(60 * 86_400)),
            "supplier": "Local pharmacy",
            "reminderEnabled": true,
            "lockScreenRedacted": true,
            "revision": 3,
            "updatedAt": iso(now),
        ]
    }

    private func occurrenceObject(
        state: String = "planned",
        actedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        revision: Int = 3,
        id: String = "magnesium-200-20260811-1130",
        planID: String = "magnesium-200"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "planID": planID,
            "scheduledFor": iso(now),
            "state": state,
            "revision": revision,
            "updatedAt": iso(now),
        ]
        if let actedAt { object["actedAt"] = iso(actedAt) }
        if let snoozedUntil { object["snoozedUntil"] = iso(snoozedUntil) }
        return object
    }

    private func inventoryEventObject(
        id: String = "magnesium-taken-1",
        planID: String = "magnesium-200",
        kind: String = "taken_decrement",
        delta: Int = -2,
        stockAfter: Int = 16,
        occurrenceID: String? = "magnesium-200-20260811-1130"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "planID": planID,
            "kind": kind,
            "delta": delta,
            "stockAfter": stockAfter,
            "occurredAt": iso(now),
        ]
        if let occurrenceID { object["occurrenceID"] = occurrenceID }
        return object
    }

    private func correctionObject(
        id: String = "correction-1",
        entityKind: String = "plan",
        entityID: String = "magnesium-200"
    ) -> [String: Any] {
        [
            "id": id,
            "entityKind": entityKind,
            "entityID": entityID,
            "field": "stockUnits",
            "oldValue": 18,
            "newValue": 20,
            "actorID": "iphone-17",
            "correctedAt": iso(now),
            "reason": "Counted the opened bottle again",
        ]
    }

    private func snapshotObject(
        state: String = "planned",
        stockUnits: Int = 18,
        inventoryUnitsPerDose: Int = 2,
        revision: Int = 3,
        corrections: [[String: Any]] = [],
        inventoryEvents: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "generatedAt": iso(now),
            "revision": revision,
            "plans": [planObject(stockUnits: stockUnits, inventoryUnitsPerDose: inventoryUnitsPerDose)],
            "occurrences": [
                occurrenceObject(
                    state: state,
                    actedAt: state == "taken" || state == "skipped" || state == "snoozed" ? now : nil,
                    snoozedUntil: state == "snoozed" ? now.addingTimeInterval(300) : nil,
                    revision: revision
                ),
            ],
            "corrections": corrections,
            "inventoryEvents": inventoryEvents,
        ]
    }

    private func snapshot(
        state: String = "planned",
        stockUnits: Int = 18,
        inventoryUnitsPerDose: Int = 2,
        revision: Int = 3,
        corrections: [[String: Any]] = [],
        inventoryEvents: [[String: Any]] = []
    ) throws -> SupplementSnapshot {
        try decode(
            snapshotObject(
                state: state,
                stockUnits: stockUnits,
                inventoryUnitsPerDose: inventoryUnitsPerDose,
                revision: revision,
                corrections: corrections,
                inventoryEvents: inventoryEvents
            ),
            as: SupplementSnapshot.self
        )
    }

    private func request(
        action: String,
        actionID: String = "action-1",
        occurrenceID: String = "magnesium-200-20260811-1130",
        planID: String = "magnesium-200",
        occurredAt: Date = Date(timeIntervalSince1970: 1_786_449_600),
        snoozeUntil: Date? = nil,
        baseRevision: Int = 3,
        sourceDeviceID: String = "iphone-17"
    ) throws -> SupplementOccurrenceActionRequest {
        var object: [String: Any] = [
            "actionID": actionID,
            "occurrenceID": occurrenceID,
            "planID": planID,
            "action": action,
            "occurredAt": iso(occurredAt),
            "baseRevision": baseRevision,
            "sourceDeviceID": sourceDeviceID,
        ]
        if let snoozeUntil { object["snoozeUntil"] = iso(snoozeUntil) }
        return try decode(object, as: SupplementOccurrenceActionRequest.self)
    }

    func testSnapshotRoundTripsWithExactWireKeysAndStrictUnknownFields() throws {
        let original = try snapshot()
        let data = try JSONEncoder.lifeOS.encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            Set(["schemaVersion", "generatedAt", "revision", "plans", "occurrences", "corrections", "inventoryEvents"])
        )
        XCTAssertNotNil(object["generatedAt"])
        XCTAssertNotNil(object["inventoryEvents"])
        XCTAssertNil(object["generated_at"])

        let plans = try XCTUnwrap(object["plans"] as? [[String: Any]])
        let encodedPlan = try XCTUnwrap(plans.first)
        XCTAssertNotNil(encodedPlan["inventoryUnitsPerDose"])
        XCTAssertNotNil(encodedPlan["updatedAt"])
        XCTAssertNil(encodedPlan["inventory_units_per_dose"])
        let schedule = try XCTUnwrap(encodedPlan["schedule"] as? [String: Any])
        XCTAssertNotNil(schedule["timeZoneIdentifier"])
        XCTAssertNil(schedule["time_zone_identifier"])

        let occurrences = try XCTUnwrap(object["occurrences"] as? [[String: Any]])
        let encodedOccurrence = try XCTUnwrap(occurrences.first)
        XCTAssertNotNil(encodedOccurrence["planID"])
        XCTAssertNil(encodedOccurrence["plan_id"])

        var unknown = snapshotObject()
        unknown["unexpected"] = true
        XCTAssertThrowsError(try decode(unknown, as: SupplementSnapshot.self))

        var unknownPlan = planObject()
        unknownPlan["unexpected"] = true
        XCTAssertThrowsError(try decode(unknownPlan, as: SupplementPlan.self))
    }

    func testSchedulePauseTimezoneDosePrecisionAndFutureTimestamps() throws {
        let parsed = try decode(planObject(), as: SupplementPlan.self)
        let encoded = try JSONEncoder.lifeOS.encode(parsed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let dose = try XCTUnwrap(object["userDose"] as? [String: Any])
        let amount = try XCTUnwrap(dose["amount"] as? Double)
        XCTAssertEqual(amount, 1.234, accuracy: 0.000_001)
        let schedule = try XCTUnwrap(object["schedule"] as? [String: Any])
        XCTAssertEqual(schedule["localTime"] as? String, "11:30")
        XCTAssertEqual(schedule["timeZoneIdentifier"] as? String, "Europe/Berlin")
        XCTAssertEqual((schedule["pauseRanges"] as? [[String: Any]])?.count, 1)

        var duplicateWeekdays = planObject()
        duplicateWeekdays["schedule"] = [
            "weekdays": [1, 1], "localTime": "11:30", "timeZoneIdentifier": "Europe/Berlin",
            "startDate": "2026-08-01", "pauseRanges": [],
            "notificationPreference": "product_and_timing", "calendarOverlayEnabled": true,
        ]
        XCTAssertThrowsError(try decode(duplicateWeekdays, as: SupplementPlan.self))

        var invalidTime = planObject()
        invalidTime["schedule"] = [
            "weekdays": [1, 3, 5], "localTime": "9:30", "timeZoneIdentifier": "Europe/Berlin",
            "startDate": "2026-08-01", "pauseRanges": [],
            "notificationPreference": "product_and_timing", "calendarOverlayEnabled": true,
        ]
        XCTAssertThrowsError(try decode(invalidTime, as: SupplementPlan.self))

        var pathLikeTimezone = planObject()
        pathLikeTimezone["schedule"] = [
            "weekdays": [1, 3, 5], "localTime": "11:30", "timeZoneIdentifier": "Europe/../Berlin",
            "startDate": "2026-08-01", "pauseRanges": [],
            "notificationPreference": "product_and_timing", "calendarOverlayEnabled": true,
        ]
        XCTAssertThrowsError(try decode(pathLikeTimezone, as: SupplementPlan.self))

        var overlappingPause = planObject()
        overlappingPause["schedule"] = [
            "weekdays": [1, 3, 5], "localTime": "11:30", "timeZoneIdentifier": "Europe/Berlin",
            "startDate": "2026-08-01", "endDate": "2026-12-31",
            "pauseRanges": [
                ["startDate": "2026-09-01", "endDate": "2026-09-04"],
                ["startDate": "2026-09-04", "endDate": "2026-09-05"],
            ],
            "notificationPreference": "product_and_timing", "calendarOverlayEnabled": true,
        ]
        XCTAssertThrowsError(try decode(overlappingPause, as: SupplementPlan.self))

        var invalidDate = planObject()
        invalidDate["schedule"] = [
            "weekdays": [1, 3, 5], "localTime": "11:30", "timeZoneIdentifier": "Europe/Berlin",
            "startDate": "2026-02-30", "pauseRanges": [],
            "notificationPreference": "product_and_timing", "calendarOverlayEnabled": true,
        ]
        XCTAssertThrowsError(try decode(invalidDate, as: SupplementPlan.self))

        var futurePlan = planObject()
        futurePlan["updatedAt"] = iso(now.addingTimeInterval(6))
        XCTAssertThrowsError(try decode(futurePlan, as: SupplementPlan.self))

        var fractionalDose = planObject()
        fractionalDose["userDose"] = ["amount": 1.2345, "unit": "capsule"]
        XCTAssertThrowsError(try decode(fractionalDose, as: SupplementPlan.self))
        fractionalDose["userDose"] = ["amount": 0, "unit": "capsule"]
        XCTAssertThrowsError(try decode(fractionalDose, as: SupplementPlan.self))
        fractionalDose["userDose"] = ["amount": 1.234, "unit": "capsule"]
        XCTAssertNoThrow(try decode(fractionalDose, as: SupplementPlan.self))
    }

    func testOccurrenceStateTimestampsAndActionValidation() throws {
        XCTAssertEqual(try decode(occurrenceObject(), as: SupplementOccurrence.self).state, .planned)
        XCTAssertThrowsError(try decode(occurrenceObject(state: "planned", actedAt: now), as: SupplementOccurrence.self))
        XCTAssertThrowsError(try decode(occurrenceObject(state: "taken"), as: SupplementOccurrence.self))
        XCTAssertThrowsError(try decode(occurrenceObject(state: "missed", actedAt: now), as: SupplementOccurrence.self))
        XCTAssertEqual(
            try decode(occurrenceObject(state: "snoozed", actedAt: now, snoozedUntil: now.addingTimeInterval(300)), as: SupplementOccurrence.self).state,
            .snoozed
        )
        XCTAssertThrowsError(
            try decode(occurrenceObject(state: "snoozed", actedAt: now, snoozedUntil: now), as: SupplementOccurrence.self)
        )

        XCTAssertEqual(try request(action: "taken").action, .taken)
        XCTAssertEqual(
            try request(action: "snooze", snoozeUntil: now.addingTimeInterval(300)).snoozeUntil,
            now.addingTimeInterval(300)
        )
        XCTAssertThrowsError(try request(action: "snooze"))
        XCTAssertThrowsError(try request(action: "skip", snoozeUntil: now.addingTimeInterval(300)))
        XCTAssertThrowsError(try request(action: "snooze", snoozeUntil: now))
        XCTAssertThrowsError(try request(action: "skip", occurrenceID: "../occurrence"))
        XCTAssertThrowsError(try request(action: "skip", occurredAt: now.addingTimeInterval(6)))
    }

    func testSnapshotRejectsDuplicateAndDanglingRecords() throws {
        let base = snapshotObject()

        var duplicatePlans = base
        duplicatePlans["plans"] = [planObject(), planObject()]
        XCTAssertThrowsError(try decode(duplicatePlans, as: SupplementSnapshot.self))

        var duplicateOccurrences = base
        duplicateOccurrences["occurrences"] = [occurrenceObject(), occurrenceObject()]
        XCTAssertThrowsError(try decode(duplicateOccurrences, as: SupplementSnapshot.self))

        var danglingOccurrence = base
        danglingOccurrence["occurrences"] = [occurrenceObject(planID: "missing-plan")]
        XCTAssertThrowsError(try decode(danglingOccurrence, as: SupplementSnapshot.self))
    }

    func testInventoryAndCorrectionsRejectDuplicateAndDanglingLinks() throws {
        let taken = occurrenceObject(state: "taken", actedAt: now)
        let event = inventoryEventObject()
        let correction = correctionObject()
        var unknownCorrection = correction
        unknownCorrection["unexpected"] = true
        XCTAssertThrowsError(try decode(unknownCorrection, as: SupplementCorrection.self))

        var valid = snapshotObject(state: "taken", corrections: [correction], inventoryEvents: [event])
        valid["occurrences"] = [taken]
        XCTAssertEqual(try decode(valid, as: SupplementSnapshot.self).inventoryEvents.count, 1)

        var duplicateEvents = valid
        duplicateEvents["inventoryEvents"] = [event, event]
        XCTAssertThrowsError(try decode(duplicateEvents, as: SupplementSnapshot.self))

        var duplicateCorrections = valid
        duplicateCorrections["corrections"] = [correction, correction]
        XCTAssertThrowsError(try decode(duplicateCorrections, as: SupplementSnapshot.self))

        var danglingEventPlan = valid
        danglingEventPlan["inventoryEvents"] = [inventoryEventObject(planID: "missing-plan")]
        XCTAssertThrowsError(try decode(danglingEventPlan, as: SupplementSnapshot.self))

        var danglingEventOccurrence = valid
        danglingEventOccurrence["inventoryEvents"] = [inventoryEventObject(occurrenceID: "missing-occurrence")]
        XCTAssertThrowsError(try decode(danglingEventOccurrence, as: SupplementSnapshot.self))

        var danglingCorrection = valid
        danglingCorrection["corrections"] = [correctionObject(entityID: "missing-plan")]
        XCTAssertThrowsError(try decode(danglingCorrection, as: SupplementSnapshot.self))

        var equalCorrection = valid
        equalCorrection["corrections"] = [
            [
                "id": "correction-equal", "entityKind": "plan", "entityID": "magnesium-200",
                "field": "stockUnits", "oldValue": 18, "newValue": 18, "actorID": "iphone-17",
                "correctedAt": iso(now), "reason": "No actual change",
            ],
        ]
        XCTAssertThrowsError(try decode(equalCorrection, as: SupplementSnapshot.self))
    }

    func testInventoryEventAndResponseWireInvariants() throws {
        let taken = occurrenceObject(state: "taken", actedAt: now)
        let event = inventoryEventObject()
        let parsedEvent = try decode(event, as: InventoryEvent.self)
        XCTAssertEqual(parsedEvent.kind.rawValue, "taken_decrement")
        let encodedEvent = try JSONEncoder.lifeOS.encode(parsedEvent)
        let encodedEventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedEvent) as? [String: Any])
        XCTAssertEqual(encodedEventObject["kind"] as? String, "taken_decrement")
        XCTAssertNotNil(encodedEventObject["occurrenceID"])
        XCTAssertNil(encodedEventObject["occurrence_id"])
        var unknownEvent = event
        unknownEvent["unexpected"] = true
        XCTAssertThrowsError(try decode(unknownEvent, as: InventoryEvent.self))

        let refill = inventoryEventObject(kind: "refill", delta: 30, stockAfter: 48, occurrenceID: nil)
        XCTAssertEqual(try decode(refill, as: InventoryEvent.self).kind.rawValue, "refill")

        var positiveTaken = event
        positiveTaken["delta"] = 1
        XCTAssertThrowsError(try decode(positiveTaken, as: InventoryEvent.self))

        var zeroEvent = event
        zeroEvent["delta"] = 0
        XCTAssertThrowsError(try decode(zeroEvent, as: InventoryEvent.self))

        var refillWithOccurrence = refill
        refillWithOccurrence["occurrenceID"] = "magnesium-200-20260811-1130"
        XCTAssertThrowsError(try decode(refillWithOccurrence, as: InventoryEvent.self))

        var refillWithNegativeDelta = refill
        refillWithNegativeDelta["delta"] = -1
        XCTAssertThrowsError(try decode(refillWithNegativeDelta, as: InventoryEvent.self))

        var takenWithoutOccurrence = event
        takenWithoutOccurrence["occurrenceID"] = NSNull()
        XCTAssertThrowsError(try decode(takenWithoutOccurrence, as: InventoryEvent.self))

        var refillWithCostOnTaken = event
        refillWithCostOnTaken["costCents"] = 100
        XCTAssertThrowsError(try decode(refillWithCostOnTaken, as: InventoryEvent.self))

        let validResponse: [String: Any] = [
            "occurrence": taken,
            "inventoryDelta": -2,
            "idempotent": false,
            "serverRevision": 4,
        ]
        XCTAssertEqual(
            try decode(validResponse, as: SupplementOccurrenceActionResponse.self).inventoryDelta,
            -2
        )

        var idempotentWithDelta = validResponse
        idempotentWithDelta["idempotent"] = true
        XCTAssertThrowsError(try decode(idempotentWithDelta, as: SupplementOccurrenceActionResponse.self))

        var skippedWithDelta = validResponse
        skippedWithDelta["occurrence"] = occurrenceObject(state: "skipped", actedAt: now)
        XCTAssertThrowsError(try decode(skippedWithDelta, as: SupplementOccurrenceActionResponse.self))
    }

    func testReducerTakenReplayFingerprintAndDeterministicEvent() throws {
        var value = try snapshot()
        var ledger = SupplementActionLedger()
        let taken = try request(action: "taken", actionID: "action-1")

        let first = try SupplementReducer.reduce(taken, in: &value, ledger: &ledger, now: now)
        XCTAssertFalse(first.idempotent)
        XCTAssertEqual(first.inventoryDelta, -2)
        XCTAssertEqual(first.occurrence.state, .taken)
        XCTAssertEqual(value.plans[0].stockUnits, 16)
        XCTAssertEqual(value.revision, 4)
        XCTAssertEqual(value.occurrences[0].revision, 4)
        XCTAssertEqual(value.inventoryEvents.count, 1)
        XCTAssertEqual(value.inventoryEvents[0].delta, -2)
        XCTAssertEqual(value.inventoryEvents[0].occurrenceID, value.occurrences[0].id)
        XCTAssertEqual(value.inventoryEvents[0].kind.rawValue, "taken_decrement")
        XCTAssertEqual(ledger.processedActionIDs, Set(["action-1"]))

        let beforeReplay = value
        let replay = try SupplementReducer.reduce(taken, in: &value, ledger: &ledger, now: now)
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(replay.inventoryDelta, 0)
        XCTAssertEqual(replay.serverRevision, 4)
        XCTAssertEqual(value, beforeReplay)

        let changedPayload = try request(action: "skip", actionID: "action-1", baseRevision: 4)
        XCTAssertThrowsError(try SupplementReducer.reduce(changedPayload, in: &value, ledger: &ledger, now: now))
        XCTAssertEqual(value, beforeReplay)
    }

    func testReducerClampsZeroStockAndKeepsSnoozeSkipAtZeroDelta() throws {
        var empty = try snapshot(stockUnits: 0)
        var ledger = SupplementActionLedger()
        let taken = try request(action: "taken", actionID: "empty-taken")
        let result = try SupplementReducer.reduce(taken, in: &empty, ledger: &ledger, now: now)
        XCTAssertEqual(result.inventoryDelta, 0)
        XCTAssertEqual(empty.plans[0].stockUnits, 0)
        XCTAssertTrue(empty.inventoryEvents.isEmpty)
        XCTAssertEqual(empty.occurrences[0].state, .taken)

        var snoozed = try snapshot()
        ledger = SupplementActionLedger()
        let snooze = try request(action: "snooze", actionID: "snooze-1", snoozeUntil: now.addingTimeInterval(300))
        let snoozeResult = try SupplementReducer.reduce(snooze, in: &snoozed, ledger: &ledger, now: now)
        XCTAssertEqual(snoozeResult.inventoryDelta, 0)
        XCTAssertEqual(snoozed.plans[0].stockUnits, 18)
        XCTAssertEqual(snoozed.occurrences[0].state, .snoozed)
        XCTAssertEqual(snoozed.occurrences[0].snoozedUntil, now.addingTimeInterval(300) as Date?)

        let skip = try request(action: "skip", actionID: "skip-1", baseRevision: snoozed.revision)
        let skipResult = try SupplementReducer.reduce(skip, in: &snoozed, ledger: &ledger, now: now)
        XCTAssertEqual(skipResult.inventoryDelta, 0)
        XCTAssertEqual(snoozed.plans[0].stockUnits, 18)
        XCTAssertEqual(snoozed.occurrences[0].state, .skipped)
    }

    func testReducerRejectsMissedOccurrencesAndRevisionConflictsWithoutMutation() throws {
        var missed = try snapshot(state: "missed")
        let beforeMissed = missed
        var ledger = SupplementActionLedger()
        let taken = try request(action: "taken", actionID: "missed-taken")
        XCTAssertThrowsError(try SupplementReducer.reduce(taken, in: &missed, ledger: &ledger, now: now))
        XCTAssertEqual(missed, beforeMissed)
        XCTAssertTrue(ledger.processedActionIDs.isEmpty)

        var conflicted = try snapshot()
        let beforeConflict = conflicted
        let stale = try request(action: "taken", actionID: "stale", baseRevision: 2)
        XCTAssertThrowsError(try SupplementReducer.reduce(stale, in: &conflicted, ledger: &ledger, now: now))
        XCTAssertEqual(conflicted, beforeConflict)
        XCTAssertTrue(ledger.processedActionIDs.isEmpty)
    }

    func testReducerBoundsLongActionIDEventID() throws {
        let longActionID = "a" + String(repeating: "x", count: 127)
        var value = try snapshot()
        var ledger = SupplementActionLedger()
        let action = try request(action: "taken", actionID: longActionID)
        _ = try SupplementReducer.reduce(action, in: &value, ledger: &ledger, now: now)
        XCTAssertEqual(value.inventoryEvents.count, 1)
        XCTAssertLessThanOrEqual(value.inventoryEvents[0].id.count, 128)
        XCTAssertTrue(value.inventoryEvents[0].id.hasPrefix("taken-"))
    }
}
