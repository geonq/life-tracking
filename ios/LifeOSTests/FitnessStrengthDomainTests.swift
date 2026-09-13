import XCTest
@testable import LifeOS

final class FitnessStrengthDomainTests: XCTestCase {
    func testEveryGroupIsRepresentedAndUnavailableIsNotZero() {
        let snapshot = FitnessStrengthSnapshot()

        XCTAssertEqual(snapshot.groups.map(\.group), FitnessStrengthMuscleGroup.allCases)
        XCTAssertNil(snapshot.metric(for: .arms).kilograms)

        let observed = FitnessStrengthMetric(
            group: .arms,
            state: .observed(kilograms: 0, window: "Last 30 days", provenance: "HealthKit · reviewed importer")
        )
        XCTAssertEqual(observed.kilograms, 0)
        XCTAssertNotEqual(observed.state, .unavailable(reason: "No source strength observation is available."))
    }

    func testInvalidStrengthValueLosesObservedStateInsteadOfBecomingZero() {
        let invalid = FitnessStrengthMetric(
            group: .legs,
            state: .observed(kilograms: .nan, window: "Last 30 days", provenance: "HealthKit")
        )

        guard case .unavailable(let reason) = invalid.state else {
            return XCTFail("Invalid source values must be unavailable")
        }
        XCTAssertTrue(reason.contains("valid kilogram"))
        XCTAssertNil(invalid.kilograms)
    }

    func testStrengthSourceStateStaysIndependentFromKilogramValue() {
        let stale = FitnessStrengthMetric(
            group: .chest,
            state: .observed(
                kilograms: 80,
                window: "Last 30 days",
                provenance: "HealthKit source"
            ),
            sourceState: .stale
        )
        XCTAssertEqual(stale.sourceState, .stale)
        XCTAssertEqual(stale.kilograms, 80)
        XCTAssertTrue(stale.sourceDetail?.hasPrefix("Stale") == true)

        let conflict = FitnessStrengthMetric(
            group: .back,
            state: .unavailable(reason: "Two source revisions disagree."),
            sourceState: .conflict
        )
        XCTAssertEqual(conflict.sourceState, .conflict)
        XCTAssertNil(conflict.kilograms)

        let aggregate = FitnessStrengthAggregate(
            state: .unavailable(reason: "HealthKit read access is indeterminate."),
            sourceState: .readIndeterminate
        )
        XCTAssertEqual(aggregate.sourceState, .readIndeterminate)
        XCTAssertNil(aggregate.kilograms)
    }

    func testProgressRequiresSourceAndPreservesEmptyState() {
        let point = FitnessStrengthProgressPoint(date: Date(timeIntervalSinceReferenceDate: 10), kilograms: 120)
        XCTAssertNotNil(point)

        let missingSource = FitnessStrengthSnapshot(
            progress: .observed(points: [point!], window: "", provenance: "HealthKit")
        )
        guard case .empty = missingSource.progress else {
            return XCTFail("Progress without a named window must remain empty")
        }

        let observed = FitnessStrengthSnapshot(
            progress: .observed(points: [point!], window: "Last 30 days", provenance: "Helio → Zepp → HealthKit")
        )
        XCTAssertEqual(observed.progress.points.count, 1)
        XCTAssertFalse(observed.progress.isDemo)

        let duplicateDate = FitnessStrengthProgressPoint(date: point!.date, kilograms: 150)!
        let duplicateDates = FitnessStrengthSnapshot(
            progress: .observed(points: [point!, duplicateDate], window: "Last 30 days", provenance: "HealthKit")
        )
        guard case .empty = duplicateDates.progress else {
            return XCTFail("Duplicate progress dates must be rejected")
        }
    }

    func testTemplateUpsertReplacesSameIDWithoutDuplicatesAndRoundTrips() throws {
        let url = temporaryURL("strength-roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let exercise = try FitnessStrengthExercise(
            id: "bench-press",
            name: "Bench press",
            muscleGroup: .chest,
            sets: 4,
            repetitions: 6,
            loadKilograms: 80
        )
        let first = try FitnessStrengthTemplate(id: "push-day", name: "Push day", exercises: [exercise], createdAt: now, updatedAt: now)
        let store = FitnessStrengthTemplateStore(persistenceURL: url)
        try store.upsert(first)

        let replacementExercise = try FitnessStrengthExercise(id: "bench-press", name: "Bench press pause", muscleGroup: .chest, sets: 5, repetitions: 5, loadKilograms: 82.5)
        let replacement = try FitnessStrengthTemplate(id: "push-day", name: "Push day v2", exercises: [replacementExercise], createdAt: now, updatedAt: now.addingTimeInterval(1))
        try store.upsert(replacement)

        XCTAssertEqual(store.templates.count, 1)
        XCTAssertEqual(store.templates.first?.name, "Push day v2")
        XCTAssertEqual(store.templates.first?.exercises.first?.loadKilograms, 82.5)

        let reloaded = FitnessStrengthTemplateStore(persistenceURL: url)
        XCTAssertEqual(reloaded.templates, [replacement])
    }

    func testTemplateValidationRejectsUnsafeAndDuplicateExercises() throws {
        XCTAssertThrowsError(try FitnessStrengthExercise(id: "../unsafe", name: "Curl", muscleGroup: .arms))

        let first = try FitnessStrengthExercise(id: "curl", name: "Curl", muscleGroup: .arms)
        let duplicate = try FitnessStrengthExercise(id: "curl", name: "Curl again", muscleGroup: .arms)
        XCTAssertThrowsError(try FitnessStrengthTemplate(id: "arms", name: "Arms", exercises: [first, duplicate])) { error in
            XCTAssertEqual(error as? FitnessStrengthTemplateValidationError, .duplicateExerciseIdentifier("curl"))
        }
    }

    func testFailedWriteRollsBackUpsertAndDelete() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-strength-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let initial = try FitnessStrengthTemplate(id: "full-body", name: "Full body", createdAt: Date(timeIntervalSinceReferenceDate: 100), updatedAt: Date(timeIntervalSinceReferenceDate: 100))
        let store = FitnessStrengthTemplateStore(initialTemplates: [initial], persistenceURL: directoryURL)
        let replacement = try FitnessStrengthTemplate(id: "full-body", name: "Should not publish", createdAt: initial.createdAt, updatedAt: initial.updatedAt.addingTimeInterval(1))

        XCTAssertThrowsError(try store.upsert(replacement))
        XCTAssertEqual(store.templates, [initial])
        XCTAssertEqual(store.lastSaveError, FitnessStrengthTemplateValidationError.persistenceFailed.localizedDescription)

        XCTAssertThrowsError(try store.delete(id: initial.id))
        XCTAssertEqual(store.templates, [initial])
    }

    func testExplicitNilPersistenceCannotClaimLocalSave() throws {
        let store = FitnessStrengthTemplateStore(persistenceURL: nil)
        let template = try FitnessStrengthTemplate(
            id: "ephemeral",
            name: "Ephemeral",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        XCTAssertThrowsError(try store.upsert(template)) { error in
            XCTAssertEqual(error as? FitnessStrengthTemplateValidationError, .persistenceFailed)
        }
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertEqual(store.lastSaveError, FitnessStrengthTemplateValidationError.persistenceFailed.localizedDescription)
    }

    func testPersistenceRejectsEncodedPayloadOverTwoMegabytesBeforeWriting() throws {
        let url = temporaryURL("strength-size-limit")
        defer { try? FileManager.default.removeItem(at: url) }
        let longName = String(repeating: "n", count: 100)
        var templates: [FitnessStrengthTemplate] = []
        for templateIndex in 0..<100 {
            var exercises: [FitnessStrengthExercise] = []
            for exerciseIndex in 0..<100 {
                let identifier = "e\(String(repeating: "a", count: 112))\(templateIndex)-\(exerciseIndex)"
                exercises.append(try FitnessStrengthExercise(id: identifier, name: longName, muscleGroup: .legs, sets: 100, repetitions: 1_000, loadKilograms: 1_000_000))
            }
            templates.append(try FitnessStrengthTemplate(id: "t\(String(repeating: "b", count: 110))\(templateIndex)", name: longName, exercises: exercises, createdAt: Date(timeIntervalSinceReferenceDate: 100), updatedAt: Date(timeIntervalSinceReferenceDate: 100)))
        }

        let store = FitnessStrengthTemplateStore(initialTemplates: templates, persistenceURL: url)
        XCTAssertThrowsError(try store.upsert(templates[0])) { error in
            XCTAssertEqual(error as? FitnessStrengthTemplateValidationError, .persistenceFailed)
        }
        XCTAssertEqual(store.templates.count, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Oversized payload must be rejected before creating the file")
    }

    func testPersistedUnknownTemplateFieldsAreRejected() throws {
        let url = temporaryURL("strength-unknown-field")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = "[{\"id\":\"template\",\"name\":\"Template\",\"exercises\":[],\"createdAt\":\"1970-01-01T00:01:40Z\",\"updatedAt\":\"1970-01-01T00:01:40Z\",\"secret\":true}]"
        try Data(payload.utf8).write(to: url)

        let store = FitnessStrengthTemplateStore(persistenceURL: url)
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertNotNil(store.integrityWarning)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lifeos-\(name)-\(UUID().uuidString).json")
    }
}
