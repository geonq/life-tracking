import Foundation
import XCTest
@testable import LifeOS

/// Evidence for BF-0388 ("Journal night/day tags plus automatic goals with
/// provenance") and the unit+integration half of BF-0389 ("Automatic goal
/// completed/failed/neutral truth states").
///
/// Investigation finding (see HANDOFF/PR notes): there is no separate
/// "automatic goal" feature or type in this codebase. The thing the
/// acceptance rows describe is `FitnessJournalRecord` with `section ==
/// .automatic`: an importer-attributed observation whose `TagState`
/// (`.yes` / `.no` / `.unknown`) is the completed/failed/neutral truth
/// state, and whose `provenance`/`source`/`window` fields are the
/// provenance requirement. `FitnessJournalVisualFixtures` in
/// `FitnessView.swift` is explicitly commented as visual-review-only ("The
/// production path has no automatic rows until a connector supplies these
/// fields with provenance") — so today, no real connector ever creates an
/// automatic row in production; only the durable type/validation boundary
/// and the fixture path exist. These tests prove that boundary holds.
final class FitnessJournalGoalTruthTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_754_000_000)

    // MARK: - BF-0388.1: night/day tags persist durably, survive reload, and
    // are attributable to the event (id + section) they belong to.

    func testNightAndDayTagsAreDistinctAndAttributableAfterReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-night-day-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FitnessJournalStore(persistenceURL: url)
        let dayTag = FitnessJournalRecord(
            id: "device-day", title: "Device in bed", emoji: "📱", section: .day, date: day, tagState: .no
        )
        let nightTag = FitnessJournalRecord(
            id: "device-night", title: "Device in bed", emoji: "📱", section: .night, date: day, tagState: .yes
        )
        XCTAssertTrue(store.upsert(dayTag))
        XCTAssertTrue(store.upsert(nightTag))

        let reloaded = FitnessJournalStore(persistenceURL: url)
        // Same title, two different events (day vs night) — each keeps its
        // own id, section and tag state rather than colliding.
        XCTAssertEqual(reloaded.record(id: "device-day")?.section, .day)
        XCTAssertEqual(reloaded.record(id: "device-day")?.tagState, .no)
        XCTAssertEqual(reloaded.record(id: "device-night")?.section, .night)
        XCTAssertEqual(reloaded.record(id: "device-night")?.tagState, .yes)
    }

    // MARK: - BF-0388.2: every automatic goal/observation carries provenance
    // (source + a non-empty provenance string + a named window). None of
    // this can be blank.

    func testAutomaticRecordWithBlankProvenanceIsRejected() {
        let store = FitnessJournalStore(persistenceURL: nil)
        let blankProvenance = FitnessJournalRecord(
            id: "steps-blank-provenance", title: "Steps", emoji: "👟", section: .automatic,
            date: day, source: .derived, provenance: "   ",
            observedValue: "10,482 steps", window: "Selected day", editable: false
        )
        XCTAssertFalse(store.upsert(blankProvenance), "An automatic row must never persist without stated provenance")
        XCTAssertNil(store.record(id: "steps-blank-provenance"))
    }

    func testAutomaticRecordWithBlankWindowIsRejected() {
        let store = FitnessJournalStore(persistenceURL: nil)
        let blankWindow = FitnessJournalRecord(
            id: "steps-blank-window", title: "Steps", emoji: "👟", section: .automatic,
            date: day, source: .derived, provenance: "HealthKit-derived importer",
            observedValue: "10,482 steps", window: "  ", editable: false
        )
        XCTAssertFalse(store.upsert(blankWindow), "An automatic row must never persist without a named source window")
        XCTAssertNil(store.record(id: "steps-blank-window"))
    }

    func testValidAutomaticRecordCarriesFullProvenanceAfterReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-provenance-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FitnessJournalStore(persistenceURL: url)
        let steps = FitnessJournalRecord(
            id: "steps", title: "Steps", emoji: "👟", section: .automatic, date: day,
            source: .derived, provenance: "HealthKit-derived importer",
            observedValue: "10,482 steps", window: "Selected day", editable: false
        )
        XCTAssertTrue(store.upsert(steps))

        let reloaded = FitnessJournalStore(persistenceURL: url).record(id: "steps")
        XCTAssertEqual(reloaded?.source, .derived)
        XCTAssertEqual(reloaded?.provenance, "HealthKit-derived importer")
        XCTAssertEqual(reloaded?.window, "Selected day")
        XCTAssertEqual(reloaded?.observedValue, "10,482 steps")
    }

    // MARK: - BF-0388.3: a goal derived from unavailable/partial data must
    // say so (source == .unavailable, tagState == .unknown) rather than
    // presenting as fully derived.

    func testUnavailableSourceAutomaticRecordStaysUnknownNeverPresentsAsDerived() {
        let store = FitnessJournalStore(initialRecords: [], persistenceURL: nil, fixtureOnly: true)
        let unavailable = FitnessJournalRecord(
            id: "daylight", title: "Morning daylight", emoji: "☀️", section: .automatic,
            date: day, source: .unavailable, provenance: "HealthKit permission required",
            tagState: .unknown, window: "Selected day", editable: false
        )
        XCTAssertTrue(store.upsert(unavailable))
        XCTAssertEqual(store.record(id: "daylight")?.source, .unavailable)
        XCTAssertEqual(store.record(id: "daylight")?.tagState, .unknown)
        XCTAssertNil(store.record(id: "daylight")?.observedValue)
    }

    // MARK: - BF-0389: completed (.yes) / failed (.no) / neutral (.unknown)
    // stay distinct and none can be fabricated. The specific hunt: a goal
    // with NO data must be .unknown, never .no ("failed"). Failing to meet
    // a goal and having no data about it are different facts.

    func testNoDataAutomaticRecordCannotBeStoredAsFailed() {
        // This is the collapse to hunt for: an unavailable/no-data source
        // must never be persisted with tagState == .no ("failed"). Only the
        // earlier .yes ("completed") case was covered by the existing
        // suite; this proves the symmetric, more dangerous case (a
        // fabricated "failed" reading from a data source that never ran).
        let store = FitnessJournalStore(initialRecords: [], persistenceURL: nil, fixtureOnly: true)
        let fabricatedFailure = FitnessJournalRecord(
            id: "fixture-fabricated-failure", title: "Morning daylight", emoji: "☀️",
            section: .automatic, date: day, source: .unavailable,
            provenance: "Fixture source unavailable", tagState: .no,
            window: "Selected day", editable: false
        )
        XCTAssertFalse(
            store.upsert(fabricatedFailure),
            "No-data automatic rows must never be stored as .no (failed); absence of data is not failure"
        )
        XCTAssertNil(store.record(id: fabricatedFailure.id))
    }

    func testNoDataAutomaticRecordCannotBeStoredAsFailedInDurableProductionStore() throws {
        // Same hunt, but against the real durable (non-fixture) store that
        // ships to users, not just the in-memory fixture path.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-no-fabricated-failure-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FitnessJournalStore(persistenceURL: url)
        let fabricatedFailure = FitnessJournalRecord(
            id: "daylight", title: "Morning daylight", emoji: "☀️", section: .automatic,
            date: day, source: .unavailable, provenance: "HealthKit permission required",
            tagState: .no, window: "Selected day", editable: false
        )
        XCTAssertFalse(store.upsert(fabricatedFailure))
        XCTAssertNil(store.record(id: "daylight"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCompletedFailedNeutralAreThreeDistinctPersistedStates() throws {
        // Completed and failed are both real observations (source
        // .healthKit/.derived) and round-trip through the same durable
        // production store the app ships with.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-tristate-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FitnessJournalStore(persistenceURL: url)
        let completed = FitnessJournalRecord(
            id: "steps-completed", title: "10,000+ steps", emoji: "👟", section: .automatic,
            date: day, source: .derived, provenance: "HealthKit-derived importer",
            tagState: .yes, observedValue: "10,482 steps", window: "Selected day", editable: false
        )
        let failed = FitnessJournalRecord(
            id: "cardio-failed", title: "20+ minutes cardio", emoji: "🏃", section: .automatic,
            date: day, source: .derived, provenance: "HealthKit-derived importer",
            tagState: .no, observedValue: "12 min", window: "Selected day", editable: false
        )
        XCTAssertTrue(store.upsert(completed))
        XCTAssertTrue(store.upsert(failed))

        let reloaded = FitnessJournalStore(persistenceURL: url)
        XCTAssertEqual(reloaded.record(id: "steps-completed")?.tagState, .yes)
        XCTAssertEqual(reloaded.record(id: "cardio-failed")?.tagState, .no)
        XCTAssertNotEqual(reloaded.record(id: "steps-completed")?.tagState, reloaded.record(id: "cardio-failed")?.tagState)

        // Neutral ("no data") is the .unavailable-source case, which — as
        // proven elsewhere in this file and in FitnessJournalStoreTests —
        // the durable production store refuses to persist at all rather
        // than ever coercing it into completed/failed. The neutral state is
        // only representable through the explicit fixture-review boundary,
        // where it stays .unknown and never collapses into .yes or .no.
        let fixtureStore = FitnessJournalStore(initialRecords: [], persistenceURL: nil, fixtureOnly: true)
        let neutral = FitnessJournalRecord(
            id: "daylight-neutral", title: "Morning daylight", emoji: "☀️", section: .automatic,
            date: day, source: .unavailable, provenance: "HealthKit permission required",
            tagState: .unknown, window: "Selected day", editable: false
        )
        XCTAssertTrue(fixtureStore.upsert(neutral))
        XCTAssertEqual(fixtureStore.record(id: "daylight-neutral")?.tagState, .unknown)

        // All three states are genuinely distinct raw values, not a
        // collapsed boolean.
        let states = Set([
            reloaded.record(id: "steps-completed")?.tagState,
            reloaded.record(id: "cardio-failed")?.tagState,
            fixtureStore.record(id: "daylight-neutral")?.tagState
        ])
        XCTAssertEqual(states.count, 3)
    }

    // MARK: - BF-0389: a "failed" (.no) automatic reading still requires a
    // real observed value — it cannot be a bare truth state substituted for
    // a missing measurement (a zero fabricated in place of no data).

    func testFailedAutomaticStateStillRequiresARealObservedValue() {
        let store = FitnessJournalStore(persistenceURL: nil)
        let noObservation = FitnessJournalRecord(
            id: "cardio-no-observation", title: "20+ minutes cardio", emoji: "🏃", section: .automatic,
            date: day, source: .derived, provenance: "HealthKit-derived importer",
            tagState: .no, window: "Selected day", editable: false
        )
        XCTAssertFalse(
            store.upsert(noObservation),
            "A .no (failed) automatic row must still carry the observed value that produced it"
        )
    }

    // MARK: - State transitions are derived from observations only: a
    // manual edit cannot promote an automatic/importer-sourced row, and an
    // automatic row can never enter a manual-only section.

    func testAutomaticProvenanceCannotBeReassignedToAManualSection() {
        let store = FitnessJournalStore(persistenceURL: nil)
        let leaked = FitnessJournalRecord(
            id: "leaked-derived", title: "Imported stress", emoji: "⚠️", section: .day,
            date: day, source: .derived, provenance: "HealthKit-derived importer",
            observedValue: "42", window: "Selected day", editable: false
        )
        XCTAssertFalse(store.upsert(leaked), "A derived/observed reading must stay confined to the automatic section")
        XCTAssertNil(store.record(id: "leaked-derived"))
    }
}
