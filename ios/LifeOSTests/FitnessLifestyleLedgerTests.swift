import Foundation
import XCTest
@testable import LifeOS

final class FitnessLifestyleLedgerTests: XCTestCase {
    private let timeZone = "Europe/Berlin"

    func testCanonicalKindsAndAlcoholNeverUsesMilliliters() throws {
        XCTAssertEqual(FitnessLifestyleKind.alcohol.allowedUnits, [.standardDrinks])
        let store = FitnessLifestyleLedgerStore(persistenceURL: nil)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertNoThrow(try store.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                               occurredAt: now, timeZoneIdentifier: timeZone, now: now))
        XCTAssertNoThrow(try store.addQuantity(kind: .caffeine, amount: 50, unit: .milligrams,
                                               occurredAt: now, timeZoneIdentifier: timeZone, now: now))
        XCTAssertNoThrow(try store.addQuantity(kind: .alcohol, amount: 1, unit: .standardDrinks,
                                               occurredAt: now, timeZoneIdentifier: timeZone, now: now))

        XCTAssertThrowsError(try store.addQuantity(kind: .alcohol, amount: 330, unit: .milliliters,
                                                   occurredAt: now.addingTimeInterval(60), timeZoneIdentifier: timeZone, now: now)) { error in
            guard case FitnessLifestyleStoreError.invalidEvent = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try store.addQuantity(kind: .caffeine, amount: -1, unit: .milligrams,
                                                   occurredAt: now.addingTimeInterval(120), timeZoneIdentifier: timeZone, now: now))
    }

    func testHealthKitSourceIdentityIsRetainedAndImportedRowsAreReadOnly() throws {
        let store = FitnessLifestyleLedgerStore(persistenceURL: nil)
        let occurredAt = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let sampleID = try XCTUnwrap(UUID(uuidString: "A4BD2D1E-2DC6-4CB0-BB6A-3110C2C63210"))
        let imported = try store.insertObservedQuantity(
            kind: .alcohol,
            amount: 1,
            unit: .standardDrinks,
            occurredAt: occurredAt,
            timeZoneIdentifier: timeZone,
            sourceSampleUUID: sampleID,
            sourceSampleRevision: "healthkit-revision-7",
            now: occurredAt
        )
        let input = try store.correlationInput(on: "2026-08-13", kind: .alcohol, timeZoneIdentifier: timeZone)
        XCTAssertEqual(input.provenance, [.healthKit])
        XCTAssertEqual(input.sourceSamples.count, 1)
        XCTAssertEqual(input.sourceSamples[0].eventID, imported.id)
        XCTAssertEqual(input.sourceSamples[0].sampleUUID, sampleID)
        XCTAssertEqual(input.sourceSamples[0].sampleRevision, "healthkit-revision-7")
        XCTAssertEqual(input.sourceSamples[0].lineageRootEventID, imported.lineage.rootEventID)
        XCTAssertEqual(input.sourceSamples[0].lineageRevision, imported.lineage.revision)
        XCTAssertThrowsError(try store.delete(eventID: imported.id)) { error in
            XCTAssertEqual(error as? FitnessLifestyleStoreError, .eventNotEditable(imported.id))
        }
        XCTAssertThrowsError(try store.editQuantity(eventID: imported.id, amount: 2, unit: .standardDrinks)) { error in
            XCTAssertEqual(error as? FitnessLifestyleStoreError, .eventNotEditable(imported.id))
        }
        XCTAssertThrowsError(try store.insertObservedQuantity(kind: .alcohol, amount: 1, unit: .standardDrinks,
                                                              occurredAt: occurredAt.addingTimeInterval(60), timeZoneIdentifier: timeZone,
                                                              sourceSampleUUID: sampleID, sourceSampleRevision: "healthkit-none"))
        XCTAssertThrowsError(try store.addQuantity(kind: .alcohol, amount: 1, unit: .standardDrinks,
                                                   occurredAt: occurredAt.addingTimeInterval(120), timeZoneIdentifier: timeZone)) { error in
            XCTAssertEqual(error as? FitnessLifestyleStoreError, .conflictWithMixedProvenance(.alcohol, "2026-08-13"))
        }
    }

    func testDecodedPersistedLineageGraphFailureQuarantinesQueries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-lineage-corrupt-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let occurredAt = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let writer = FitnessLifestyleLedgerStore(persistenceURL: url)
        _ = try writer.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                   occurredAt: occurredAt, timeZoneIdentifier: timeZone, now: occurredAt)
        let valid = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: valid) as? [String: Any],
              var events = object["events"] as? [[String: Any]],
              let event = events.first,
              let eventID = event["id"] as? String else {
            return XCTFail("expected persisted event envelope")
        }
        let missingParent = UUID().uuidString
        var corrupt = event
        corrupt["lineage"] = [
            "rootEventID": eventID,
            "parentEventID": missingParent,
            "revision": 2
        ]
        corrupt["supersededAt"] = NSNull()
        corrupt["supersededBy"] = NSNull()
        events[0] = corrupt
        object["events"] = events
        let corruptedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try corruptedData.write(to: url, options: .atomic)

        let reader = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertTrue(reader.hasLoadFailure)
        XCTAssertTrue(reader.activeEvents().isEmpty)
        XCTAssertThrowsError(try reader.history(on: "2026-08-13", kind: .hydration, timeZoneIdentifier: timeZone))
        XCTAssertThrowsError(try reader.daySummary(on: "2026-08-13", kind: .hydration, timeZoneIdentifier: timeZone))
        XCTAssertEqual(try Data(contentsOf: url), corruptedData)
    }

    func testSelectedHistoricalDayPreservesLocalClockAndRejectsDSTGap() throws {
        let berlin = try XCTUnwrap(TimeZone(identifier: timeZone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let selectedDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 13)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 14, minute: 37, second: 12)))
        let occurrence = try FitnessLifestyleTime.datePreservingLocalDay(selectedDay, now: now, timeZoneIdentifier: timeZone)
        XCTAssertEqual(FitnessLifestyleTime.localDay(for: occurrence, timeZoneIdentifier: timeZone), "2026-08-13")
        XCTAssertEqual(calendar.component(.hour, from: occurrence), 14)
        XCTAssertEqual(calendar.component(.minute, from: occurrence), 37)

        let springDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29)))
        let gapClock = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 2, minute: 30)))
        XCTAssertThrowsError(try FitnessLifestyleTime.datePreservingLocalDay(springDay, now: gapClock, timeZoneIdentifier: timeZone))
    }

    func testExplicitNoneIsDistinctFromMissingAndConflictsWithQuantity() throws {
        let store = FitnessLifestyleLedgerStore(persistenceURL: nil)
        let day = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let none = try store.addNone(kind: .hydration, occurredAt: day, timeZoneIdentifier: timeZone, now: day)
        XCTAssertTrue(none.isExplicitNone)
        let explicitNone = try store.daySummary(on: "2026-08-13", kind: .hydration, timeZoneIdentifier: timeZone)
        XCTAssertNil(explicitNone.total)
        XCTAssertTrue(explicitNone.explicitNone)
        XCTAssertEqual(explicitNone.missingness, .explicitNone)
        XCTAssertThrowsError(try store.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                                   occurredAt: day.addingTimeInterval(60), timeZoneIdentifier: timeZone, now: day)) { error in
            guard case FitnessLifestyleStoreError.conflictWithExplicitNone = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let missing = try FitnessLifestyleLedgerStore(persistenceURL: nil)
            .daySummary(on: "2026-08-13", kind: .hydration, timeZoneIdentifier: timeZone)
        XCTAssertNil(missing.total)
        XCTAssertFalse(missing.explicitNone)
        XCTAssertEqual(missing.missingness, .missing)
    }

    func testAlcoholFreeIsDistinctAndJournalNoteRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-free-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        let note = FitnessLifestyleJournalNote(text: "Team dinner · chose alcohol-free", createdAt: day)
        let event = try store.addAlcoholFree(occurredAt: day, timeZoneIdentifier: timeZone, journalNote: note, now: day)
        let summary = try store.daySummary(on: "2026-08-13", kind: .alcohol, timeZoneIdentifier: timeZone)
        XCTAssertTrue(summary.alcoholFree)
        XCTAssertFalse(summary.explicitNone)
        XCTAssertEqual(summary.missingness, .alcoholFree)
        XCTAssertNil(summary.total)
        XCTAssertEqual(store.history(kind: .alcohol).first?.journalNote, note)
        XCTAssertEqual(store.history(kind: .alcohol).first?.journalNote?.displayLinkage, "Journal linkage unavailable")
        let reloaded = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertEqual(reloaded.history(kind: .alcohol).first?.id, event.id)
        XCTAssertEqual(reloaded.history(kind: .alcohol).first?.journalNote, note)
        XCTAssertThrowsError(try reloaded.addQuantity(kind: .alcohol, amount: 1, unit: .standardDrinks,
                                                      occurredAt: day.addingTimeInterval(60), timeZoneIdentifier: timeZone))
        let noneStore = FitnessLifestyleLedgerStore(persistenceURL: nil)
        _ = try noneStore.addNone(kind: .alcohol, occurredAt: day, timeZoneIdentifier: timeZone, now: day)
        XCTAssertThrowsError(try noneStore.addAlcoholFree(occurredAt: day.addingTimeInterval(60), timeZoneIdentifier: timeZone)) { error in
            XCTAssertEqual(error as? FitnessLifestyleStoreError, .conflictWithExplicitNone(.alcohol, "2026-08-13"))
        }
        let cleared = try reloaded.editToAlcoholFree(eventID: event.id, clearJournalNote: true)
        XCTAssertNil(cleared.journalNote)
    }

    func testEditCreatesCorrectionLineageAndDeleteLeavesTombstone() throws {
        let store = FitnessLifestyleLedgerStore(persistenceURL: nil)
        let timestamp = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let created = try store.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                            occurredAt: timestamp, timeZoneIdentifier: timeZone, now: timestamp)
        let edited = try store.editQuantity(eventID: created.id, amount: 500, unit: .milliliters,
                                            now: timestamp.addingTimeInterval(30))
        XCTAssertNotEqual(created.id, edited.id)
        XCTAssertEqual(edited.lineage.rootEventID, created.id)
        XCTAssertEqual(edited.lineage.parentEventID, created.id)
        XCTAssertEqual(edited.lineage.revision, 2)
        XCTAssertTrue(store.history(kind: .hydration).contains { $0.id == created.id && $0.supersededBy == edited.id })
        XCTAssertEqual(try store.events(on: "2026-08-13", kind: .hydration, timeZoneIdentifier: timeZone).map(\.id), [edited.id])

        let tombstone = try store.delete(eventID: edited.id, now: timestamp.addingTimeInterval(60))
        XCTAssertTrue(tombstone.isDeleted)
        XCTAssertTrue(tombstone.deletedAt != nil)
        XCTAssertTrue(try store.events(on: "2026-08-13", kind: .hydration, timeZoneIdentifier: timeZone).isEmpty)
        XCTAssertEqual(try store.daySummary(on: "2026-08-13", kind: .hydration, timeZoneIdentifier: timeZone).missingness, .missing)
        XCTAssertEqual(store.history(kind: .hydration).count, 3)
        XCTAssertEqual(tombstone.lineage.parentEventID, edited.id)
        XCTAssertEqual(tombstone.lineage.rootEventID, created.id)
        XCTAssertEqual(tombstone.lineage.revision, 3)
        XCTAssertTrue(store.history(kind: .hydration).contains { $0.id == edited.id && $0.supersededBy == tombstone.id })
    }

    func testPublicRootBoundaryRejectsForgedChildCrossKindAndCrossSource() throws {
        let store = FitnessLifestyleLedgerStore(persistenceURL: nil)
        let timestamp = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let root = try store.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                          occurredAt: timestamp, timeZoneIdentifier: timeZone, now: timestamp)
        let forged = FitnessLifestyleEvent(
            kind: .caffeine, state: .quantity, value: 50, unit: .milligrams,
            occurredAt: timestamp, timeZoneIdentifier: timeZone, createdAt: timestamp,
            provenance: .manual,
            lineage: FitnessLifestyleLineage(rootEventID: root.lineage.rootEventID, parentEventID: root.id, revision: 2)
        )
        XCTAssertThrowsError(try store.insertRoot(forged))
        let source = try XCTUnwrap(UUID(uuidString: "A4BD2D1E-2DC6-4CB0-BB6A-3110C2C63210"))
        _ = try store.insertObservedQuantity(kind: .alcohol, amount: 1, unit: .standardDrinks,
                                              occurredAt: timestamp, timeZoneIdentifier: timeZone,
                                              sourceSampleUUID: source, sourceSampleRevision: "source-1")
        XCTAssertThrowsError(try store.insertObservedQuantity(kind: .hydration, amount: 1, unit: .milliliters,
                                                               occurredAt: timestamp.addingTimeInterval(1), timeZoneIdentifier: timeZone,
                                                               sourceSampleUUID: source, sourceSampleRevision: "source-1"))
    }

    func testTimestampAndLocalDayRemainCorrectAcrossDSTAndTimezoneQueries() throws {
        let store = FitnessLifestyleLedgerStore(persistenceURL: nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeJump = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 55)))
        let afterJump = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 5)))
        _ = try store.addQuantity(kind: .caffeine, amount: 40, unit: .milligrams, occurredAt: beforeJump,
                                  timeZoneIdentifier: "America/New_York", now: beforeJump)
        _ = try store.addQuantity(kind: .caffeine, amount: 60, unit: .milligrams, occurredAt: afterJump,
                                  timeZoneIdentifier: "America/New_York", now: afterJump)
        let summary = try store.daySummary(on: "2026-03-08", kind: .caffeine, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(summary.total, 100)
        XCTAssertEqual(summary.sampleCount, 2)
        XCTAssertEqual(store.activeEvents(kind: .caffeine).map(\.localDay), ["2026-03-08", "2026-03-08"])

        // The source timezone is part of the bucket identity. A UTC viewer
        // must not silently re-bucket these events into a different day.
        let utcDay = try store.daySummary(on: "2026-03-08", kind: .caffeine, timeZoneIdentifier: "UTC")
        XCTAssertNil(utcDay.total)
        XCTAssertEqual(utcDay.missingness, .missing)
    }

    func testSettingsPersistAndReminderValidationIsStateOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-settings-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        let settings = FitnessLifestyleSettings(kind: .hydration, goal: 1_892.7, quickAmount: 250,
                                                quickUnit: .milliliters, reminderTimeMinutes: 22 * 60 + 15,
                                                reminderEnabled: true, reminderContext: .nightly,
                                                reminderFoldPolicy: .laterOffset,
                                                updatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        try store.saveSettings(settings)
        let reloaded = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertEqual(reloaded.savedSettings(for: .hydration), settings)
        XCTAssertEqual(reloaded.settings(for: .hydration).reminderTimeLabel, "22:15")
        XCTAssertThrowsError(try reloaded.saveSettings(FitnessLifestyleSettings(kind: .caffeine, reminderEnabled: true)))
        XCTAssertThrowsError(try reloaded.saveSettings(FitnessLifestyleSettings(kind: .alcohol, quickAmount: 1, quickUnit: .milliliters)))
    }

    func testReminderRequestHasDescriptiveContextAndExplicitDSTFoldPolicy() throws {
        let settings = FitnessLifestyleSettings(
            kind: .hydration,
            reminderTimeMinutes: 7 * 60 + 15,
            reminderEnabled: true,
            reminderContext: .wake,
            reminderFoldPolicy: .laterOffset
        )
        let fixedNow = try FitnessLifestyleTime.date(
            forLocalDay: "2026-10-31", timeMinutes: 12 * 60,
            timeZoneIdentifier: "America/New_York", foldPolicy: .earlierOffset
        )
        let request = try XCTUnwrap(try FitnessLifestyleReminderReconciler.requests(
            for: settings, timeZoneIdentifier: "America/New_York", now: fixedNow, lookAheadDays: 4
        ).first)
        XCTAssertTrue(request.identifier.hasPrefix("\(FitnessLifestyleReminderReconciler.identifierPrefix)hydration."))
        XCTAssertEqual(request.hour, 7)
        XCTAssertEqual(request.minute, 15)
        XCTAssertEqual(request.context, .wake)
        XCTAssertEqual(request.foldPolicy, .laterOffset)
        XCTAssertFalse(request.repeats)
        XCTAssertNotNil(request.fireDate)
        XCTAssertTrue(request.body.lowercased().contains("descriptive"))
        XCTAssertTrue(request.body.lowercased().contains("after waking"))

        let nightly = FitnessLifestyleSettings(
            kind: .caffeine,
            reminderTimeMinutes: 23 * 60,
            reminderEnabled: true,
            reminderContext: .nightly
        )
        let nightlyRequest = try XCTUnwrap(try FitnessLifestyleReminderReconciler.requests(
            for: nightly, timeZoneIdentifier: "Europe/Berlin", now: fixedNow, lookAheadDays: 2
        ).first)
        XCTAssertTrue(nightlyRequest.body.lowercased().contains("nightly"))
        XCTAssertThrowsError(try FitnessLifestyleReminderReconciler.requests(for: settings, timeZoneIdentifier: "Not/AZone", now: fixedNow))
    }

    func testEphemeralNotificationAuthorizationRemainsVisibleAndSchedulable() {
        XCTAssertTrue(FitnessLifestyleNotificationAuthorization.ephemeral.canSchedule)
        XCTAssertFalse(FitnessLifestyleNotificationAuthorization.unknown.canSchedule)
    }

    func testReminderReconciliationReplacesChangedFullRequestAndPreservesUnmanaged() throws {
        let settings = FitnessLifestyleSettings(
            kind: .hydration,
            reminderTimeMinutes: 22 * 60,
            reminderEnabled: true,
            reminderContext: .beforeLunch
        )
        let client = FitnessLifestyleReminderFakeClient()
        let reconciler = FitnessLifestyleReminderReconciler(client: client)
        let fixedNow = try FitnessLifestyleTime.date(
            forLocalDay: "2026-08-13", timeMinutes: 12 * 60,
            timeZoneIdentifier: timeZone, foldPolicy: .earlierOffset
        )

        let first = expectation(description: "first reconciliation")
        reconciler.reconcile(settings: [settings], timeZoneIdentifier: timeZone, now: fixedNow) { result in
            guard case .success(let identifiers) = result else { return XCTFail("expected first reconciliation") }
            XCTAssertEqual(identifiers.count, FitnessLifestyleReminderReconciler.defaultLookAheadDays)
            first.fulfill()
        }
        wait(for: [first], timeout: 1)
        XCTAssertEqual(client.added.count, FitnessLifestyleReminderReconciler.defaultLookAheadDays)

        // A fresh reconciler/store sees the full pending payload and does not
        // duplicate equal requests. Unmanaged requests remain untouched.
        client.pending.append(.init(identifier: "unrelated.request", request: nil))
        let second = expectation(description: "relaunch reconciliation")
        FitnessLifestyleReminderReconciler(client: client).reconcile(settings: [settings], timeZoneIdentifier: timeZone, now: fixedNow) { result in
            guard case .success(let identifiers) = result else { return XCTFail("expected idempotent reconciliation") }
            XCTAssertEqual(identifiers.count, FitnessLifestyleReminderReconciler.defaultLookAheadDays)
            second.fulfill()
        }
        wait(for: [second], timeout: 1)
        XCTAssertEqual(client.added.count, FitnessLifestyleReminderReconciler.defaultLookAheadDays)
        XCTAssertTrue(client.removed.isEmpty)

        // Changing time/context/fold retains the same identifiers for the
        // local days but must replace every stale request by full equality.
        let changed = FitnessLifestyleSettings(
            kind: .hydration,
            reminderTimeMinutes: 23 * 60,
            reminderEnabled: true,
            reminderContext: .nightly,
            reminderFoldPolicy: .laterOffset
        )
        let changedExpectation = expectation(description: "changed reconciliation")
        FitnessLifestyleReminderReconciler(client: client).reconcile(settings: [changed], timeZoneIdentifier: "America/New_York", now: fixedNow) { result in
            guard case .success(let identifiers) = result else { return XCTFail("expected changed reconciliation") }
            XCTAssertEqual(identifiers.count, FitnessLifestyleReminderReconciler.defaultLookAheadDays)
            changedExpectation.fulfill()
        }
        wait(for: [changedExpectation], timeout: 1)
        XCTAssertEqual(client.removed.count, FitnessLifestyleReminderReconciler.defaultLookAheadDays)
        XCTAssertEqual(client.added.count, FitnessLifestyleReminderReconciler.defaultLookAheadDays * 2)
        XCTAssertTrue(client.pending.contains { $0.identifier == "unrelated.request" })

        client.authorization = .denied
        let denied = expectation(description: "denied reconciliation")
        FitnessLifestyleReminderReconciler(client: client).reconcile(settings: [changed], timeZoneIdentifier: timeZone, now: fixedNow) { result in
            XCTAssertEqual(result, .failure(.authorizationDenied))
            denied.fulfill()
        }
        wait(for: [denied], timeout: 1)
        XCTAssertEqual(client.added.count, FitnessLifestyleReminderReconciler.defaultLookAheadDays * 2)
    }

    func testReminderBudgetPreservesUnmanagedAndRotatesAllEnabledKindsFairly() throws {
        let settings = [
            FitnessLifestyleSettings(
                kind: .hydration,
                reminderTimeMinutes: 8 * 60,
                reminderEnabled: true,
                reminderContext: .wake
            ),
            FitnessLifestyleSettings(
                kind: .caffeine,
                reminderTimeMinutes: 9 * 60,
                reminderEnabled: true,
                reminderContext: .beforeLunch
            ),
            FitnessLifestyleSettings(
                kind: .alcohol,
                reminderTimeMinutes: 10 * 60,
                reminderEnabled: true,
                reminderContext: .nightly
            )
        ]
        let client = FitnessLifestyleReminderFakeClient()
        let unmanagedIDs = (0..<5).map { "calendar.unmanaged.\($0)" }
        client.pending = unmanagedIDs.map { .init(identifier: $0, request: nil) }
        let now = try FitnessLifestyleTime.date(
            forLocalDay: "2026-08-13", timeMinutes: 0,
            timeZoneIdentifier: timeZone, foldPolicy: .earlierOffset
        )

        let first = expectation(description: "budgeted reconciliation")
        FitnessLifestyleReminderReconciler(client: client).reconcile(
            settings: settings, timeZoneIdentifier: timeZone, now: now
        ) { result in
            guard case .success(let identifiers) = result else {
                return XCTFail("expected budgeted reconciliation to succeed")
            }
            XCTAssertEqual(identifiers.count, FitnessLifestyleReminderReconciler.maximumPendingRequestCount - unmanagedIDs.count)
            first.fulfill()
        }
        wait(for: [first], timeout: 1)

        XCTAssertEqual(client.pending.count, FitnessLifestyleReminderReconciler.maximumPendingRequestCount)
        XCTAssertEqual(
            Set(client.pending.filter { !$0.identifier.hasPrefix(FitnessLifestyleReminderReconciler.identifierPrefix) }.map(\.identifier)),
            Set(unmanagedIDs)
        )
        let managed = client.pending.compactMap(\.request)
        XCTAssertEqual(managed.count, 59)
        let counts = FitnessLifestyleKind.allCases.map { kind in
            managed.filter { $0.kind == kind }.count
        }
        XCTAssertTrue(counts.allSatisfy { $0 >= 19 }, "each enabled kind must receive a fair share: \(counts)")
        XCTAssertLessThanOrEqual((counts.max() ?? 0) - (counts.min() ?? 0), 1)
        let firstSelection = Set(managed.map(\.identifier))
        XCTAssertEqual(managed.compactMap(\.fireDate), managed.compactMap(\.fireDate).sorted())

        // A relaunch with the same horizon must make the same selection and
        // must not add another request or touch any unmanaged identifier.
        let second = expectation(description: "deterministic budgeted reconciliation")
        FitnessLifestyleReminderReconciler(client: client).reconcile(
            settings: settings, timeZoneIdentifier: timeZone, now: now
        ) { result in
            guard case .success(let identifiers) = result else {
                return XCTFail("expected deterministic reconciliation to succeed")
            }
            XCTAssertEqual(Set(identifiers), firstSelection)
            second.fulfill()
        }
        wait(for: [second], timeout: 1)
        XCTAssertEqual(client.added.count, 59)
        XCTAssertEqual(
            Set(client.pending.compactMap(\.request).map(\.identifier)),
            firstSelection
        )
        XCTAssertEqual(
            Set(client.pending.filter { !$0.identifier.hasPrefix(FitnessLifestyleReminderReconciler.identifierPrefix) }.map(\.identifier)),
            Set(unmanagedIDs)
        )
    }

    func testDeniedReminderReconciliationRemovesStaleManagedRequestsWithoutAdding() throws {
        let client = FitnessLifestyleReminderFakeClient()
        client.authorization = .denied
        let staleID = "\(FitnessLifestyleReminderReconciler.identifierPrefix)hydration.2026-08-13"
        client.pending = [
            .init(identifier: staleID, request: nil),
            .init(identifier: "unmanaged.request", request: nil)
        ]
        let disabled = FitnessLifestyleSettings(kind: .hydration)
        let finished = expectation(description: "denied cleanup")
        FitnessLifestyleReminderReconciler(client: client).reconcile(
            settings: [disabled], timeZoneIdentifier: timeZone,
            now: Date(timeIntervalSince1970: 1_750_000_000)
        ) { result in
            XCTAssertEqual(result, .success([]))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(client.removed, [staleID])
        XCTAssertTrue(client.added.isEmpty)
        XCTAssertTrue(client.pending.contains { $0.identifier == "unmanaged.request" })
    }

    func testReminderReconciliationIgnoresLateAndDuplicateCallbacks() throws {
        let client = FitnessLifestyleReminderCallbackClient()
        let reconciler = FitnessLifestyleReminderReconciler(client: client)
        let settings = FitnessLifestyleSettings(kind: .hydration)
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let firstAuthorizationRequested = expectation(description: "first authorization read")
        client.onAuthorizationRequested = { firstAuthorizationRequested.fulfill() }
        let staleCompletion = expectation(description: "stale completion must not fire")
        staleCompletion.isInverted = true
        reconciler.reconcile(settings: [settings], timeZoneIdentifier: timeZone, now: now, timeout: 1) { _ in
            staleCompletion.fulfill()
        }
        wait(for: [firstAuthorizationRequested], timeout: 1)
        reconciler.cancel()

        let secondAuthorizationRequested = expectation(description: "second authorization read")
        client.onAuthorizationRequested = { secondAuthorizationRequested.fulfill() }
        let completion = expectation(description: "current reconciliation")
        var completionCount = 0
        reconciler.reconcile(settings: [settings], timeZoneIdentifier: timeZone, now: now, timeout: 1) { result in
            completionCount += 1
            XCTAssertEqual(result, .success([]))
            completion.fulfill()
        }
        wait(for: [secondAuthorizationRequested], timeout: 1)

        let pendingRequested = expectation(description: "pending read")
        client.onPendingRequested = { pendingRequested.fulfill() }
        // The first callback is now stale. The second callback is delivered
        // twice to verify the generation and one-shot callback guards.
        client.authorizationCompletions[0](.authorized)
        client.authorizationCompletions[1](.authorized)
        client.authorizationCompletions[1](.authorized)
        wait(for: [pendingRequested], timeout: 1)
        client.pendingCompletions[0](.success([]))
        client.pendingCompletions[0](.success([]))

        wait(for: [completion], timeout: 1)
        wait(for: [staleCompletion], timeout: 0.05)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(client.pendingRequestCallCount, 1)
        XCTAssertTrue(client.added.isEmpty)
        XCTAssertTrue(client.removed.isEmpty)
    }

    func testReminderReconciliationTimesOutWhenCallbackIsLost() throws {
        let client = FitnessLifestyleReminderLostCallbackClient()
        let finished = expectation(description: "lost callback timeout")
        FitnessLifestyleReminderReconciler(client: client).reconcile(
            settings: [FitnessLifestyleSettings(kind: .hydration, reminderTimeMinutes: 8 * 60, reminderEnabled: true)],
            timeZoneIdentifier: timeZone,
            now: Date(timeIntervalSince1970: 1_750_000_000),
            timeout: 0.02
        ) { result in
            XCTAssertEqual(result, .failure(.timedOut))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
    }

    func testReminderHorizonResolvesEarlierAndLaterDSTFoldToDifferentAbsoluteInstants() throws {
        let now = try FitnessLifestyleTime.date(
            forLocalDay: "2026-10-31", timeMinutes: 12 * 60,
            timeZoneIdentifier: "America/New_York", foldPolicy: .earlierOffset
        )
        let earlier = FitnessLifestyleSettings(
            kind: .hydration, reminderTimeMinutes: 90, reminderEnabled: true,
            reminderFoldPolicy: .earlierOffset
        )
        let later = FitnessLifestyleSettings(
            kind: .hydration, reminderTimeMinutes: 90, reminderEnabled: true,
            reminderFoldPolicy: .laterOffset
        )
        let earlierRequest = try XCTUnwrap(try FitnessLifestyleReminderReconciler.requests(
            for: earlier, timeZoneIdentifier: "America/New_York", now: now, lookAheadDays: 3
        ).first(where: { $0.identifier.hasSuffix("2026-11-01") }))
        let laterRequest = try XCTUnwrap(try FitnessLifestyleReminderReconciler.requests(
            for: later, timeZoneIdentifier: "America/New_York", now: now, lookAheadDays: 3
        ).first(where: { $0.identifier.hasSuffix("2026-11-01") }))
        XCTAssertNotEqual(earlierRequest.fireDate, laterRequest.fireDate)
        let earlierFireDate = try XCTUnwrap(earlierRequest.fireDate)
        let laterFireDate = try XCTUnwrap(laterRequest.fireDate)
        let foldDelta = laterFireDate.timeIntervalSince(earlierFireDate)
        XCTAssertEqual(foldDelta, 3_600, accuracy: 0.1)
    }

    func testAmbiguousHistoricalClockHonorsStoredFoldPolicy() throws {
        let timeZone = "America/New_York"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
        let selectedDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let clock = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 1, minute: 30)))
        let earlier = try FitnessLifestyleTime.datePreservingLocalDay(selectedDay, now: clock, timeZoneIdentifier: timeZone, foldPolicy: .earlierOffset)
        let later = try FitnessLifestyleTime.datePreservingLocalDay(selectedDay, now: clock, timeZoneIdentifier: timeZone, foldPolicy: .laterOffset)
        XCTAssertNotEqual(earlier, later)
        XCTAssertEqual(FitnessLifestyleTime.localDay(for: earlier, timeZoneIdentifier: timeZone), "2026-11-01")
        XCTAssertEqual(FitnessLifestyleTime.localDay(for: later, timeZoneIdentifier: timeZone), "2026-11-01")
        XCTAssertEqual(calendar.component(.hour, from: earlier), 1)
        XCTAssertEqual(calendar.component(.minute, from: later), 30)
    }

    func testEditPersistsFoldChoiceWithoutLosingAbsoluteOccurrence() throws {
        let zone = "America/New_York"
        let earlier = try FitnessLifestyleTime.date(
            forLocalDay: "2026-11-01", timeMinutes: 90,
            timeZoneIdentifier: zone, foldPolicy: .earlierOffset
        )
        let later = try FitnessLifestyleTime.date(
            forLocalDay: "2026-11-01", timeMinutes: 90,
            timeZoneIdentifier: zone, foldPolicy: .laterOffset
        )
        let store = FitnessLifestyleLedgerStore(persistenceURL: nil)
        let original = try store.addQuantity(
            kind: .caffeine, amount: 50, unit: .milligrams,
            occurredAt: later, timeZoneIdentifier: zone,
            localTimeFoldPolicy: .laterOffset, now: later
        )
        let unchanged = try store.editQuantity(
            eventID: original.id, amount: 60, unit: .milligrams,
            now: later.addingTimeInterval(1)
        )
        XCTAssertEqual(unchanged.occurredAt, later)
        XCTAssertEqual(unchanged.localTimeFoldPolicy, .laterOffset)

        let moved = try store.editQuantity(
            eventID: unchanged.id, amount: 70, unit: .milligrams,
            occurredAt: earlier, timeZoneIdentifier: zone,
            localTimeFoldPolicy: .earlierOffset, now: later.addingTimeInterval(2)
        )
        XCTAssertEqual(moved.occurredAt, earlier)
        XCTAssertEqual(moved.localTimeFoldPolicy, .earlierOffset)
        XCTAssertEqual(moved.occurredAt.timeIntervalSince(unchanged.occurredAt), -3_600, accuracy: 0.1)
    }

    func testPersistenceRelaunchAndCorrelationInputPreserveMissingnessAndProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-relaunch-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        _ = try store.addQuantity(kind: .caffeine, amount: 120, unit: .milligrams, occurredAt: day,
                                  timeZoneIdentifier: timeZone, now: day)
        let reloaded = FitnessLifestyleLedgerStore(persistenceURL: url)
        let input = try reloaded.correlationInput(on: "2026-08-13", kind: .caffeine, timeZoneIdentifier: timeZone)
        XCTAssertEqual(input.value, 120)
        XCTAssertEqual(input.missingness, .observed)
        XCTAssertFalse(input.explicitNone)
        XCTAssertEqual(input.provenance, [.manual])
        XCTAssertEqual(input.sampleCount, 1)
        XCTAssertTrue(input.interpretation.lowercased().contains("descriptive"))
        let missing = try reloaded.correlationInput(on: "2026-08-14", kind: .caffeine, timeZoneIdentifier: timeZone)
        XCTAssertNil(missing.value)
        XCTAssertEqual(missing.missingness, .missing)
        XCTAssertEqual(missing.sampleCount, 0)
    }

    func testProductionRepositoryFailsClosedWhenPersistenceURLIsUnavailable() {
        let repository = FitnessLifestyleRepository(usesVisualFixtures: false, persistenceURL: nil)
        XCTAssertEqual(repository.snapshot.error, .persistenceUnavailable)
        XCTAssertTrue(repository.store.hasLoadFailure)
        XCTAssertEqual(repository.store.loadStatus, .failed(FitnessLifestyleStoreError.persistenceUnavailable.localizedDescription))
        XCTAssertThrowsError(try repository.store.reload()) { error in
            XCTAssertEqual(error as? FitnessLifestyleStoreError, .persistenceUnavailable)
        }
        XCTAssertThrowsError(try repository.store.addNone(kind: .hydration, occurredAt: Date(), timeZoneIdentifier: timeZone)) { error in
            XCTAssertEqual(error as? FitnessLifestyleStoreError, .persistenceUnavailable)
        }
    }

    func testDailyInputSnapshotIncludesMissingNoneAndObservedWithoutCausalInference() throws {
        let store = FitnessLifestyleLedgerStore(persistenceURL: nil)
        let day = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        _ = try store.addQuantity(kind: .hydration, amount: 500, unit: .milliliters,
                                  occurredAt: day, timeZoneIdentifier: timeZone, now: day)
        _ = try store.addNone(kind: .caffeine, occurredAt: day, timeZoneIdentifier: timeZone, now: day)
        let snapshot = try store.dailyInputSnapshot(on: "2026-08-13", timeZoneIdentifier: timeZone)
        XCTAssertEqual(snapshot.summaries.count, FitnessLifestyleKind.allCases.count)
        XCTAssertEqual(snapshot.summaries.first(where: { $0.kind == .hydration })?.missingness, .observed)
        XCTAssertEqual(snapshot.summaries.first(where: { $0.kind == .caffeine })?.missingness, .explicitNone)
        XCTAssertEqual(snapshot.summaries.first(where: { $0.kind == .alcohol })?.missingness, .missing)
        XCTAssertTrue(snapshot.interpretation.lowercased().contains("descriptive"))
        XCTAssertTrue(snapshot.interpretation.lowercased().contains("no causal"))
    }

    func testCorruptLoadFailsClosedAndDoesNotReplaceFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-corrupt-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("{ definitely not json".utf8)
        try corrupt.write(to: url)
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertTrue(store.hasLoadFailure)
        XCTAssertThrowsError(try store.addNone(kind: .hydration, occurredAt: Date(), timeZoneIdentifier: timeZone))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try? FileManager.default.removeItem(at: root)
    }

    func testAtomicWriteFailureRollsBackInMemoryState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-blocked-\(UUID().uuidString)", isDirectory: true)
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("block".utf8).write(to: blockingFile)
        let url = blockingFile.appendingPathComponent("ledger.json")
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertThrowsError(try store.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                                   occurredAt: timestamp, timeZoneIdentifier: timeZone, now: timestamp))
        XCTAssertTrue(store.activeEvents().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testConcurrentStoresSerializeReadModifyWriteWithoutLostEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-concurrent-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let queue = DispatchQueue(label: "lifeos.lifestyle.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        for index in 0..<16 {
            group.enter()
            queue.async {
                defer { group.leave() }
                let store = FitnessLifestyleLedgerStore(persistenceURL: url)
                _ = try? store.addQuantity(kind: .hydration, amount: Double(index + 1), unit: .milliliters,
                                            occurredAt: timestamp.addingTimeInterval(Double(index)),
                                            timeZoneIdentifier: self.timeZone, now: timestamp)
            }
        }
        group.wait()
        let reloaded = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertFalse(reloaded.hasLoadFailure)
        XCTAssertEqual(reloaded.activeEvents(kind: .hydration).count, 16)
        XCTAssertEqual(reloaded.activeEvents(kind: .hydration).compactMap(\.value).reduce(0, +), 136)
    }

    func testStrictEnvelopeRejectsUnknownFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-unknown-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("{\"schemaVersion\":1,\"events\":[],\"settings\":[],\"unexpected\":true}".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: url)
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertTrue(store.hasLoadFailure)
        XCTAssertEqual(store.loadStatus, .failed(store.lastLoadError?.localizedDescription ?? ""))
    }

    func testFilteredInvalidLoadIsReadOnlyAndPreservesOriginalFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-filtered-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let occurredAt = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let writer = FitnessLifestyleLedgerStore(persistenceURL: url)
        _ = try writer.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                   occurredAt: occurredAt, timeZoneIdentifier: timeZone, now: occurredAt)
        let valid = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: valid) as? [String: Any],
              var events = object["events"] as? [[String: Any]],
              !events.isEmpty else { return XCTFail("expected encoded event") }
        events[0]["localDay"] = "2026-08-14"
        object["events"] = events
        let invalid = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try invalid.write(to: url, options: .atomic)

        let reader = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertTrue(reader.hasLoadFailure)
        if case .filteredInvalidRecords = reader.loadStatus {
            // Expected: valid records may be inspected, but the store is
            // quarantined and cannot rewrite the source file.
        } else {
            XCTFail("invalid record should be surfaced as filtered/read-only")
        }
        XCTAssertThrowsError(try reader.addNone(kind: .hydration, occurredAt: occurredAt,
                                                timeZoneIdentifier: timeZone))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testPersistedNoneQuantityConflictFailsClosedWithoutChoosingLatest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-conflict-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let occurredAt = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let writer = FitnessLifestyleLedgerStore(persistenceURL: url)
        _ = try writer.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                   occurredAt: occurredAt, timeZoneIdentifier: timeZone, now: occurredAt)
        let valid = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: valid) as? [String: Any],
              var events = object["events"] as? [[String: Any]],
              let original = events.first,
              let originalID = original["id"] as? String else { return XCTFail("expected encoded event") }
        var none = original
        none["id"] = UUID().uuidString
        none["state"] = FitnessLifestyleEventState.explicitNone.rawValue
        none["value"] = NSNull()
        none["unit"] = NSNull()
        // The duplicate marker must be a distinct root revision so the only
        // conflict is the explicit-none/quantity state itself.
        none["lineage"] = ["rootEventID": none["id"] as! String, "parentEventID": NSNull(), "revision": 1]
        none["supersededAt"] = NSNull()
        none["supersededBy"] = NSNull()
        events.append(none)
        object["events"] = events
        let conflict = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try conflict.write(to: url, options: .atomic)

        let reader = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertTrue(reader.hasLoadFailure)
        XCTAssertThrowsError(try reader.addQuantity(kind: .hydration, amount: 500, unit: .milliliters,
                                                    occurredAt: occurredAt.addingTimeInterval(60), timeZoneIdentifier: timeZone))
        XCTAssertEqual(try Data(contentsOf: url), conflict)
        XCTAssertFalse(originalID.isEmpty)
    }

    func testPersistedMixedProvenanceConflictIsQuarantinedWithoutChoosingLatest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-mixed-source-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let occurredAt = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let writer = FitnessLifestyleLedgerStore(persistenceURL: url)
        _ = try writer.addQuantity(kind: .hydration, amount: 250, unit: .milliliters,
                                   occurredAt: occurredAt, timeZoneIdentifier: timeZone, now: occurredAt)
        let valid = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: valid) as? [String: Any],
              var events = object["events"] as? [[String: Any]],
              let original = events.first,
              let originalID = original["id"] as? String else { return XCTFail("expected encoded event") }
        var imported = original
        let importedID = UUID().uuidString
        imported["id"] = importedID
        imported["provenance"] = FitnessLifestyleProvenance.healthKit.rawValue
        imported["sourceSampleUUID"] = UUID().uuidString
        imported["sourceSampleRevision"] = "mixed-source-1"
        imported["lineage"] = ["rootEventID": importedID, "parentEventID": NSNull(), "revision": 1]
        events.append(imported)
        object["events"] = events
        let conflict = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try conflict.write(to: url, options: .atomic)

        let reader = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertTrue(reader.hasLoadFailure)
        XCTAssertTrue(reader.activeEvents().isEmpty)
        XCTAssertThrowsError(try reader.addQuantity(kind: .hydration, amount: 500, unit: .milliliters,
                                                    occurredAt: occurredAt.addingTimeInterval(60), timeZoneIdentifier: timeZone))
        XCTAssertEqual(try Data(contentsOf: url), conflict)
        XCTAssertFalse(originalID.isEmpty)
    }

    func testLegacyAlcoholCountUnitIsQuarantinedRatherThanMerged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-lifestyle-legacy-count-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let occurredAt = try XCTUnwrap(FitnessLifestyleTime.date(fromLocalDay: "2026-08-13", timeZoneIdentifier: timeZone))
        let writer = FitnessLifestyleLedgerStore(persistenceURL: url)
        _ = try writer.addQuantity(kind: .alcohol, amount: 1, unit: .standardDrinks,
                                   occurredAt: occurredAt, timeZoneIdentifier: timeZone, now: occurredAt)
        let valid = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: valid) as? [String: Any],
              var events = object["events"] as? [[String: Any]],
              !events.isEmpty else { return XCTFail("expected encoded alcohol event") }
        events[0]["unit"] = "count"
        object["events"] = events
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacy.write(to: url, options: .atomic)

        let reader = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertTrue(reader.hasLoadFailure)
        XCTAssertTrue(reader.activeEvents(kind: .alcohol).isEmpty)
        XCTAssertThrowsError(try reader.addQuantity(kind: .alcohol, amount: 1,
                                                    unit: .standardDrinks, occurredAt: occurredAt,
                                                    timeZoneIdentifier: timeZone))
        XCTAssertEqual(try Data(contentsOf: url), legacy)
    }
}

private final class FitnessLifestyleReminderFakeClient: FitnessLifestyleNotificationClient {
    var authorization: FitnessLifestyleNotificationAuthorization = .authorized
    var pending: [FitnessLifestylePendingReminder] = []
    var added: [FitnessLifestyleReminderRequest] = []
    var removed: [String] = []

    func authorizationStatus(completion: @escaping (FitnessLifestyleNotificationAuthorization) -> Void) {
        completion(authorization)
    }

    func requestAuthorization(completion: @escaping (Result<Bool, Error>) -> Void) {
        authorization = .authorized
        completion(.success(true))
    }

    func pendingIdentifiers(completion: @escaping (Result<[String], Error>) -> Void) {
        completion(.success(pending.map(\.identifier)))
    }

    func pendingRequests(completion: @escaping (Result<[FitnessLifestylePendingReminder], Error>) -> Void) {
        completion(.success(pending))
    }

    func removePending(identifiers: [String]) {
        removed.append(contentsOf: identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func add(_ request: FitnessLifestyleReminderRequest, completion: @escaping (Error?) -> Void) {
        added.append(request)
        pending.append(.init(identifier: request.identifier, request: request))
        completion(nil)
    }
}

private final class FitnessLifestyleReminderCallbackClient: FitnessLifestyleNotificationClient {
    var authorizationCompletions: [(FitnessLifestyleNotificationAuthorization) -> Void] = []
    var pendingCompletions: [(Result<[FitnessLifestylePendingReminder], Error>) -> Void] = []
    var onAuthorizationRequested: (() -> Void)?
    var onPendingRequested: (() -> Void)?
    var pendingRequestCallCount = 0
    var added: [FitnessLifestyleReminderRequest] = []
    var removed: [String] = []

    func authorizationStatus(completion: @escaping (FitnessLifestyleNotificationAuthorization) -> Void) {
        authorizationCompletions.append(completion)
        onAuthorizationRequested?()
    }

    func requestAuthorization(completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    func pendingIdentifiers(completion: @escaping (Result<[String], Error>) -> Void) {
        completion(.success([]))
    }

    func pendingRequests(completion: @escaping (Result<[FitnessLifestylePendingReminder], Error>) -> Void) {
        pendingRequestCallCount += 1
        pendingCompletions.append(completion)
        onPendingRequested?()
    }

    func removePending(identifiers: [String]) {
        removed.append(contentsOf: identifiers)
    }

    func add(_ request: FitnessLifestyleReminderRequest, completion: @escaping (Error?) -> Void) {
        added.append(request)
        completion(nil)
    }
}

private final class FitnessLifestyleReminderLostCallbackClient: FitnessLifestyleNotificationClient {
    func authorizationStatus(completion: @escaping (FitnessLifestyleNotificationAuthorization) -> Void) {}

    func requestAuthorization(completion: @escaping (Result<Bool, Error>) -> Void) {}

    func pendingIdentifiers(completion: @escaping (Result<[String], Error>) -> Void) {}

    func pendingRequests(completion: @escaping (Result<[FitnessLifestylePendingReminder], Error>) -> Void) {}

    func removePending(identifiers: [String]) {}

    func add(_ request: FitnessLifestyleReminderRequest, completion: @escaping (Error?) -> Void) {}
}
