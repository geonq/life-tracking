import Foundation
import XCTest
@testable import LifeOS

final class FitnessJournalStoreTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_754_000_000)

    func testDemoSourceAutomaticallyUsesNonpersistentFixtureMode() {
        XCTAssertTrue(FitnessJournalFixturePolicy.isFixtureMode(usesVisualFixtures: false, sourceIsDemo: true))
        XCTAssertTrue(FitnessJournalFixturePolicy.isFixtureMode(usesVisualFixtures: true, sourceIsDemo: false))
        XCTAssertFalse(FitnessJournalFixturePolicy.isFixtureMode(usesVisualFixtures: false, sourceIsDemo: false))
    }

    func testManualQuantityAndTriStateRoundTripThroughDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FitnessJournalStore(persistenceURL: url)
        let hydration = FitnessJournalRecord(
            id: "hydration",
            title: "Hydration",
            emoji: "💧",
            section: .day,
            date: day,
            quantity: 750,
            unit: "ml"
        )
        store.upsert(hydration)
        store.upsert(FitnessJournalRecord(
            id: "ketogenic",
            title: "Ketogenic",
            emoji: "🥑",
            section: .day,
            date: day,
            tagState: .unknown
        ))
        store.setTagState(.yes, for: "ketogenic")

        let reloaded = FitnessJournalStore(persistenceURL: url)
        XCTAssertEqual(reloaded.record(id: "hydration")?.quantity, 750)
        XCTAssertEqual(reloaded.record(id: "hydration")?.unit, "ml")
        XCTAssertEqual(reloaded.record(id: "ketogenic")?.tagState, .yes)
        XCTAssertTrue(reloaded.hasEntries(on: day))
    }

    func testAutomaticUnavailableObservationIsRepresentableButNeverPersisted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-unavailable-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FitnessJournalStore(persistenceURL: url)
        let unavailable = FitnessJournalRecord(
            id: "daylight",
            title: "Morning daylight",
            emoji: "☀️",
            section: .automatic,
            date: day,
            source: .unavailable,
            provenance: "HealthKit permission required",
            window: "Selected day",
            editable: false
        )
        store.upsert(unavailable)
        XCTAssertNil(store.record(id: "daylight"))
    }

    func testFixtureOnlyInMemoryStoreDisplaysUnavailableAutomaticRow() {
        let unavailable = FitnessJournalRecord(
            id: "fixture-daylight",
            title: "Morning daylight",
            emoji: "☀️",
            section: .automatic,
            date: day,
            source: .unavailable,
            provenance: "Fixture source unavailable",
            window: "Selected day",
            editable: false
        )
        let store = FitnessJournalStore(initialRecords: [unavailable], persistenceURL: nil, fixtureOnly: true)
        XCTAssertEqual(store.record(id: "fixture-daylight"), unavailable)
        XCTAssertNil(store.integrityWarning)
    }

    func testFixtureUnavailableAutomaticCannotClaimCompletionWithoutObservation() {
        let invalid = FitnessJournalRecord(
            id: "fixture-false-completion", title: "Morning daylight", emoji: "☀️",
            section: .automatic, date: day, source: .unavailable,
            provenance: "Fixture source unavailable", tagState: .yes,
            window: "Selected day", editable: false
        )
        let store = FitnessJournalStore(
            initialRecords: [invalid], persistenceURL: nil, fixtureOnly: true
        )

        XCTAssertNil(store.record(id: invalid.id))
        XCTAssertNotNil(store.integrityWarning)
        XCTAssertFalse(store.upsert(invalid))
    }

    func testFixtureBoundaryKeepsUnavailableAutomaticButRejectsDemoAndManualRows() {
        let automaticUnavailable = FitnessJournalRecord(
            id: "fixture-unavailable", title: "Daylight", emoji: "☀️", section: .automatic,
            date: day, source: .unavailable, provenance: "Fixture only",
            window: "Selected day", editable: false
        )
        let automaticDemo = FitnessJournalRecord(
            id: "fixture-demo", title: "Demo steps", emoji: "👟", section: .automatic,
            date: day, source: .demo, provenance: "Fixture only",
            observedValue: "10,000 steps", window: "Selected day", editable: false
        )
        let manualDemo = FitnessJournalRecord(
            id: "fixture-demo-manual", title: "Demo mood", emoji: "😊", section: .day,
            date: day, source: .demo, provenance: "Fixture only",
            observedValue: "happy", window: "Selected day", editable: true
        )
        let store = FitnessJournalStore(
            initialRecords: [automaticUnavailable, automaticDemo, manualDemo], persistenceURL: nil, fixtureOnly: true
        )

        XCTAssertEqual(store.record(id: "fixture-unavailable"), automaticUnavailable)
        XCTAssertNil(store.record(id: "fixture-demo"))
        XCTAssertNil(store.record(id: "fixture-demo-manual"))
        XCTAssertNotNil(store.integrityWarning)
    }

    func testFixtureRelaxationCannotBeCombinedWithDurableFileStorage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-fixture-boundary-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FitnessJournalStore(persistenceURL: url, fixtureOnly: true)
        let unavailable = FitnessJournalRecord(
            id: "fixture-unavailable",
            title: "Morning sunlight",
            emoji: "☀️",
            section: .automatic,
            date: day,
            source: .unavailable,
            provenance: "Fixture only",
            window: "Selected day",
            editable: false
        )
        let demo = FitnessJournalRecord(
            id: "fixture-demo",
            title: "Demo steps",
            emoji: "👟",
            section: .automatic,
            date: day,
            source: .demo,
            provenance: "Fixture only",
            observedValue: "10,000 steps",
            window: "Selected day",
            editable: false
        )
        XCTAssertFalse(store.upsert(unavailable))
        XCTAssertFalse(store.upsert(demo))
        XCTAssertNil(store.record(id: "fixture-unavailable"))
        XCTAssertNil(store.record(id: "fixture-demo"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedDiskWriteRetainsLastDurableTruth() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A directory at the file URL makes the atomic write fail without
        // requiring permissions or touching any user data.
        let store = FitnessJournalStore(persistenceURL: root)
        store.upsert(FitnessJournalRecord(
            id: "caffeine",
            title: "Caffeine",
            emoji: "☕️",
            section: .day,
            date: day,
            quantity: 100,
            unit: "mg"
        ))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastSaveError)
    }

    func testQuantityParserRejectsUnsafeFormsAndAcceptsCommaDecimal() {
        XCTAssertEqual(FitnessJournalQuantity.parse("1,5"), 1.5)
        XCTAssertEqual(FitnessJournalQuantity.parse(".25"), 0.25)
        XCTAssertNil(FitnessJournalQuantity.parse("1e3"))
        XCTAssertNil(FitnessJournalQuantity.parse("1,5.2"))
        XCTAssertNil(FitnessJournalQuantity.parse("1,"))
        XCTAssertNil(FitnessJournalQuantity.parse("-1"))
        XCTAssertNil(FitnessJournalQuantity.parse("100000.01"))
        XCTAssertNil(FitnessJournalQuantity.parse("NaN"))
    }

    func testManualObservedImporterFieldsAreRejectedButManualProvenanceIsAllowed() {
        let store = FitnessJournalStore(persistenceURL: nil)
        let valid = FitnessJournalRecord(id: "mood", title: "Daily mood", emoji: "😊", section: .pinned, date: day, source: .manual, provenance: "Local journal · user entered", tagState: .yes)
        XCTAssertTrue(store.upsert(valid))
        let invalid = FitnessJournalRecord(id: "bad-manual", title: "Manual", emoji: "🏷️", section: .day, date: day, source: .manual, provenance: "Local journal", tagState: .yes, observedValue: "imported", window: "Selected day")
        XCTAssertFalse(store.upsert(invalid))
        XCTAssertNil(store.record(id: "bad-manual"))
    }

    func testNonManualSourcesAreRejectedOutsideAutomaticSectionWithoutMutation() {
        let store = FitnessJournalStore(persistenceURL: nil)
        let valid = FitnessJournalRecord(
            id: "source-boundary", title: "Daily mood", emoji: "😊", section: .day,
            date: day, source: .manual, tagState: .yes
        )
        XCTAssertTrue(store.upsert(valid))

        for section in [FitnessJournalRecord.Section.day, .pinned] {
            for source in [FitnessJournalRecord.Source.derived, .healthKit, .inferred] {
                let invalid = FitnessJournalRecord(
                    id: "source-boundary", title: "Imported mood", emoji: "⚠️", section: section,
                    date: day, source: source, provenance: "Importer",
                    observedValue: "42", window: "Selected day", editable: false
                )
                XCTAssertFalse(store.upsert(invalid), "\(source) must not enter \(section)")
                XCTAssertEqual(store.record(id: "source-boundary"), valid)
            }
        }

        let lockedManual = FitnessJournalRecord(
            id: "locked-manual", title: "Daily mood", emoji: "😊", section: .pinned,
            date: day, source: .manual, editable: false
        )
        XCTAssertFalse(store.upsert(lockedManual))

        let invalidAutomaticInference = FitnessJournalRecord(
            id: "automatic-inference", title: "Inferred stress", emoji: "⚠️", section: .automatic,
            date: day, source: .inferred, provenance: "Inference", observedValue: "42",
            window: "Selected day", editable: false
        )
        XCTAssertFalse(store.upsert(invalidAutomaticInference))
    }

    func testInvalidQuantityDoesNotMutateOrReplaceDurableManualValue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-quantity-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FitnessJournalStore(persistenceURL: url)
        let valid = FitnessJournalRecord(id: "water", title: "Hydration", emoji: "💧", section: .day, date: day, quantity: 1.5, unit: "ml", quantityInput: "1,5")
        XCTAssertTrue(store.upsert(valid))
        let negative = FitnessJournalRecord(id: "water", title: "Hydration", emoji: "💧", section: .day, date: day, quantity: -1, unit: "ml", quantityInput: "-1")
        XCTAssertFalse(store.upsert(negative))
        XCTAssertEqual(store.record(id: "water")?.quantity, 1.5)
        let exponent = FitnessJournalRecord(id: "water", title: "Hydration", emoji: "💧", section: .day, date: day, quantity: 1_000, unit: "ml", quantityInput: "1e3")
        XCTAssertFalse(store.upsert(exponent))
        XCTAssertEqual(FitnessJournalStore(persistenceURL: url).record(id: "water")?.quantity, 1.5)
    }

    func testProductionLoadFiltersInvalidAutomaticRecordsAndPreservesManualRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-integrity-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let validManual = FitnessJournalRecord(id: "mood", title: "Daily mood", emoji: "😊", section: .pinned, date: day, source: .manual, tagState: .yes)
        let validAutomatic = FitnessJournalRecord(id: "steps", title: "Steps", emoji: "👟", section: .automatic, date: day, source: .derived, provenance: "HealthKit-derived importer", observedValue: "10,482 steps", window: "Selected day", editable: false)
        let missingValue = FitnessJournalRecord(id: "stress", title: "Stress", emoji: "🔴", section: .automatic, date: day, source: .derived, provenance: "HealthKit-derived importer", window: "Selected day", editable: false)
        let wrongSource = FitnessJournalRecord(id: "bad-source", title: "Bad source", emoji: "⚠️", section: .automatic, date: day, source: .manual, provenance: "Manual", observedValue: "42", window: "Selected day", editable: false)
        let derivedManualSection = FitnessJournalRecord(id: "derived-day", title: "Imported stress", emoji: "⚠️", section: .day, date: day, source: .derived, provenance: "HealthKit-derived importer", observedValue: "42", window: "Selected day", editable: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([validManual, validAutomatic, missingValue, wrongSource, derivedManualSection]).write(to: url, options: .atomic)

        let store = FitnessJournalStore(persistenceURL: url)
        XCTAssertNotNil(store.record(id: "mood"))
        XCTAssertNotNil(store.record(id: "steps"))
        XCTAssertNil(store.record(id: "stress"))
        XCTAssertNil(store.record(id: "bad-source"))
        XCTAssertNil(store.record(id: "derived-day"))
        XCTAssertNotNil(store.integrityWarning)
    }

    func testReloadFiltersInvalidPersistedManualSectionRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-reload-integrity-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let validManual = FitnessJournalRecord(
            id: "mood", title: "Daily mood", emoji: "😊", section: .pinned,
            date: day, source: .manual, tagState: .yes
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([validManual]).write(to: url, options: .atomic)
        let store = FitnessJournalStore(persistenceURL: url)

        let invalidDerived = FitnessJournalRecord(
            id: "derived-pinned", title: "Imported mood", emoji: "⚠️", section: .pinned,
            date: day, source: .derived, provenance: "Importer",
            observedValue: "42", window: "Selected day", editable: false
        )
        try JSONEncoder().encode([validManual, invalidDerived]).write(to: url, options: .atomic)
        store.reload()

        XCTAssertEqual(store.record(id: "mood"), validManual)
        XCTAssertNil(store.record(id: "derived-pinned"))
        XCTAssertNotNil(store.integrityWarning)
    }

    func testWeeklyCompletionRequiresExplicitManualInput() {
        let store = FitnessJournalStore(persistenceURL: nil)
        let automatic = FitnessJournalRecord(id: "steps", title: "Steps", emoji: "👟", section: .automatic, date: day, source: .derived, provenance: "Importer", observedValue: "10,482 steps", window: "Selected day", editable: false)
        XCTAssertTrue(store.upsert(automatic))
        XCTAssertFalse(store.hasEntries(on: day))

        let unknownManual = FitnessJournalRecord(id: "mood", title: "Daily mood", emoji: "😊", section: .pinned, date: day, source: .manual, tagState: .unknown)
        XCTAssertTrue(store.upsert(unknownManual))
        XCTAssertFalse(store.hasEntries(on: day))
        store.setTagState(.yes, for: "mood")
        XCTAssertTrue(store.hasEntries(on: day))
    }

    func testJournalMonthModelUsesMondayGridAndCapsFutureNavigation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let model = FitnessJournalCalendarModel(calendar: calendar, today: today)
        let august = model.monthStart(for: today)
        let cells = model.cells(in: august)

        XCTAssertEqual(cells.count, 42)
        XCTAssertEqual(cells.compactMap { $0 }.count, 31)
        XCTAssertNil(cells[4])
        XCTAssertEqual(cells[5], calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        XCTAssertTrue(model.canMoveMonth(from: august, by: -1))
        XCTAssertFalse(model.canMoveMonth(from: august, by: 1))
        XCTAssertTrue(model.isSelectable(today))
        XCTAssertFalse(model.isSelectable(calendar.date(byAdding: .day, value: 1, to: today)!))
    }

    func testJournalMonthCompletionIgnoresImporterOnlyObservations() {
        let store = FitnessJournalStore(persistenceURL: nil)
        let automatic = FitnessJournalRecord(
            id: "imported",
            title: "Steps",
            emoji: "👟",
            section: .automatic,
            date: day,
            source: .derived,
            provenance: "HealthKit importer",
            observedValue: "10,482 steps",
            window: "Selected day",
            editable: false
        )
        XCTAssertTrue(store.upsert(automatic))
        XCTAssertFalse(store.hasEntries(on: day), "Month completion must be manual-entry only")

        let manual = FitnessJournalRecord(
            id: "mood",
            title: "Daily mood",
            emoji: "😊",
            section: .pinned,
            date: day,
            source: .manual,
            tagState: .yes
        )
        XCTAssertTrue(store.upsert(manual))
        XCTAssertTrue(store.hasEntries(on: day))
    }

    func testCorruptJSONSetsGenericIntegrityWarning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-corrupt-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url, options: .atomic)

        let store = FitnessJournalStore(persistenceURL: url)
        XCTAssertEqual(store.records, [])
        XCTAssertEqual(store.integrityWarning, "Journal storage could not be read; showing the last valid local records.")
    }

    func testJournalStorageProtectionIsPlatformScoped() {
#if os(iOS)
        XCTAssertTrue(FitnessJournalStorageProtection.writeOptions.contains(.completeFileProtection))
        XCTAssertEqual(FitnessJournalStorageProtection.label, "Complete file protection")
#else
        XCTAssertEqual(FitnessJournalStorageProtection.writeOptions, [.atomic])
        XCTAssertEqual(FitnessJournalStorageProtection.label, "Atomic local file")
#endif
    }
}
