import Foundation
import XCTest
@testable import LifeOS

@MainActor
final class FitnessTrainingCoordinatorTests: XCTestCase {
    func testStarterCatalogContainsStrengthAndCardioQuickStarts() async {
        let coordinator = makeCoordinator()

        await coordinator.refresh()

        XCTAssertEqual(
            Set(coordinator.state.templates.map(\.id)),
            Set(["starter-curls", "starter-bench-press", "starter-cardio"])
        )
        XCTAssertEqual(coordinator.state.templates.first(where: { $0.id == "starter-curls" })?.activityKind, .strength)
        XCTAssertEqual(coordinator.state.templates.first(where: { $0.id == "starter-cardio" })?.activityKind, .cardio)
    }

    func testVisualFixtureCoordinatorUsesTemporaryFilesForBothStores() async throws {
        let systemFileManager = FileManager.default
        let personalRoot = systemFileManager.temporaryDirectory
            .appendingPathComponent("lifeos-personal-sentinel-\(UUID().uuidString)", isDirectory: true)
        try systemFileManager.createDirectory(at: personalRoot, withIntermediateDirectories: true)
        defer { try? systemFileManager.removeItem(at: personalRoot) }

        let personalLedgerURL = personalRoot.appendingPathComponent("fitness-training-ledger.json")
        let personalTemplateURL = personalRoot.appendingPathComponent("fitness-strength-templates.json")
        let personalSentinel = Data("personal-sentinel".utf8)
        try personalSentinel.write(to: personalLedgerURL)
        try personalSentinel.write(to: personalTemplateURL)

        let fileManager = ApplicationSupportSentinelFileManager(sentinelURL: personalRoot)
        let persistence = FitnessTrainingPersistenceConfiguration.visualFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: persistence.directoryURL) }
        XCTAssertTrue(persistence.trainingLedgerURL.path.hasPrefix(fileManager.temporaryDirectory.path))
        XCTAssertTrue(persistence.strengthTemplateURL.path.hasPrefix(fileManager.temporaryDirectory.path))
        XCTAssertNotEqual(persistence.trainingLedgerURL, personalLedgerURL)
        XCTAssertNotEqual(persistence.strengthTemplateURL, personalTemplateURL)

        let clock = FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_300_000))
        let coordinator = FitnessTrainingCoordinator(
            clock: { clock.now() },
            persistenceConfiguration: persistence
        )
        await coordinator.refresh()

        let exercise = try FitnessStrengthExercise(
            id: "fixture-row",
            name: "Fixture row",
            muscleGroup: .back,
            sets: 3,
            repetitions: 8,
            loadKilograms: 40
        )
        let template = try FitnessStrengthTemplate(
            id: "fixture-template",
            name: "Fixture template",
            exercises: [exercise],
            createdAt: clock.now(),
            updatedAt: clock.now()
        )
        XCTAssertTrue(coordinator.saveTemplate(template))
        let option = try XCTUnwrap(coordinator.state.templates.first(where: { $0.id == template.id }))
        let receipt = await coordinator.start(template: option)
        XCTAssertEqual(receipt?.outcome, .saved)

        XCTAssertTrue(fileManager.fileExists(atPath: persistence.trainingLedgerURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: persistence.strengthTemplateURL.path))
        XCTAssertEqual(fileManager.applicationSupportLookupCount, 0)
        XCTAssertEqual(try Data(contentsOf: personalLedgerURL), personalSentinel)
        XCTAssertEqual(try Data(contentsOf: personalTemplateURL), personalSentinel)
    }

    func testConcurrentStartRequestsAllowOnlyOneDurableMutation() async {
        let coordinator = makeCoordinator()
        await coordinator.refresh()
        let template = try? XCTUnwrap(coordinator.state.templates.first(where: { $0.id == "starter-curls" }))

        guard let template else {
            XCTFail("The starter catalog did not contain curls")
            return
        }

        async let first = coordinator.start(template: template)
        async let second = coordinator.start(template: template)
        let results = await (first, second)
        let receipts = [results.0, results.1].compactMap { $0 }

        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.outcome, .saved)
        XCTAssertEqual(coordinator.state.sessions.filter { $0.status == .active }.count, 1)
    }

    func testFailedStartLeavesCoordinatorEmptyAndRetryPersistsRequestedTitle() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("lifeos-training-start-retry-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let faults = FitnessTrainingPersistenceFaults(failBeforeReplace: true)
        let clock = FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_050_000))
        let store = FitnessTrainingStore(
            persistenceURL: root.appendingPathComponent("training.json"),
            clock: { clock.now() },
            beforeReplace: {
                if faults.failBeforeReplace {
                    faults.failBeforeReplace = false
                    throw TrainingStoreError.persistenceFailed
                }
            }
        )
        let coordinator = FitnessTrainingCoordinator(
            trainingStore: store,
            templateStore: FitnessStrengthTemplateStore(
                persistenceURL: root.appendingPathComponent("templates.json")
            ),
            clock: { clock.now() }
        )

        await coordinator.refresh()
        let template = try XCTUnwrap(coordinator.state.templates.first(where: { $0.id == "starter-curls" }))

        let failed = await coordinator.start(template: template, title: "  Morning push  ")
        XCTAssertNil(failed)
        XCTAssertTrue(coordinator.state.sessions.isEmpty)
        XCTAssertNil(coordinator.state.activeSession)
        XCTAssertEqual(coordinator.state.notice, .error(TrainingStoreError.persistenceFailed.localizedDescription))
        XCTAssertFalse(coordinator.isBusy)

        let retry = await coordinator.start(template: template, title: "  Morning push  ")
        XCTAssertEqual(retry?.outcome, .saved)
        XCTAssertEqual(coordinator.state.activeSession?.title, "Morning push")
    }

    func testPauseResumeAndFinishPreserveLocalSetValues() async throws {
        let clock = FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = makeCoordinator(clock: clock)
        await coordinator.refresh()
        let template = try XCTUnwrap(coordinator.state.templates.first(where: { $0.id == "starter-bench-press" }))

        let startReceipt = await coordinator.start(template: template)
        XCTAssertEqual(startReceipt?.outcome, .saved)
        let active = try XCTUnwrap(coordinator.state.activeSession)

        clock.advance(by: 10)
        let pausedReceipt = await coordinator.pause(draft: active)
        XCTAssertEqual(pausedReceipt?.outcome, .saved)
        let paused = try XCTUnwrap(coordinator.state.activeSession)
        XCTAssertEqual(paused.status, .paused)

        let duplicatePause = await coordinator.pause(draft: paused)
        XCTAssertNil(duplicatePause)

        clock.advance(by: 5)
        let resumedReceipt = await coordinator.resume(draft: paused)
        XCTAssertEqual(resumedReceipt?.outcome, .saved)
        let resumed = try XCTUnwrap(coordinator.state.activeSession)
        XCTAssertEqual(resumed.status, .active)

        clock.advance(by: 60)
        var exercises = resumed.exercises
        let firstExercise = try XCTUnwrap(exercises.first)
        var sets = firstExercise.sets
        let firstSet = try XCTUnwrap(sets.first)
        sets[0] = try TrainingSetLog(
            id: firstSet.id,
            kind: firstSet.kind,
            targetRepetitions: firstSet.targetRepetitions,
            targetLoadKilograms: firstSet.targetLoadKilograms,
            actualRepetitions: 8,
            actualLoadKilograms: 80,
            isCompleted: true,
            completedAt: clock.now(),
            now: clock.now()
        )
        exercises[0] = try TrainingExerciseLog(
            id: firstExercise.id,
            templateExerciseID: firstExercise.templateExerciseID,
            name: firstExercise.name,
            muscleGroup: firstExercise.muscleGroup,
            loadConvention: firstExercise.loadConvention,
            sets: sets,
            notes: firstExercise.notes
        )
        let draft = try TrainingSession(
            id: resumed.id,
            revision: resumed.revision,
            activityKind: resumed.activityKind,
            title: resumed.title,
            createdAt: resumed.createdAt,
            updatedAt: resumed.updatedAt,
            startedAt: resumed.startedAt,
            endedAt: resumed.endedAt,
            timeZoneIdentifier: resumed.timeZoneIdentifier,
            templateID: resumed.templateID,
            templateSnapshot: resumed.templateSnapshot,
            pauses: resumed.pauses,
            status: resumed.status,
            exercises: exercises,
            notes: resumed.notes,
            importedRecordKey: resumed.importedRecordKey,
            now: clock.now()
        )

        let finishReceipt = await coordinator.finish(draft: draft)
        XCTAssertEqual(finishReceipt?.outcome, .saved)
        XCTAssertNil(coordinator.state.activeSession)
        let completed = try XCTUnwrap(coordinator.state.latestCompletedSession)
        XCTAssertEqual(completed.completedSets.count, 1)
        let recordedVolume = try XCTUnwrap(completed.recordedExternalVolumeKilograms)
        XCTAssertEqual(recordedVolume, 640, accuracy: 0.001)
        XCTAssertEqual(completed.status, .completed)
    }

    func testTimedNonStrengthCanFinishWithoutInventedRepetitionsOrLoad() async throws {
        let clock = FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = makeCoordinator(clock: clock)
        await coordinator.refresh()
        let template = try XCTUnwrap(coordinator.state.templates.first(where: { $0.id == "starter-cardio" }))

        let startReceipt = await coordinator.start(template: template)
        XCTAssertEqual(startReceipt?.outcome, .saved)
        let active = try XCTUnwrap(coordinator.state.activeSession)

        clock.advance(by: 90)
        let finishReceipt = await coordinator.finish(draft: active)
        XCTAssertEqual(finishReceipt?.outcome, .saved)

        let completed = try XCTUnwrap(coordinator.state.latestCompletedSession)
        XCTAssertEqual(completed.activityKind, .cardio)
        XCTAssertTrue(completed.completedSets.isEmpty)
        XCTAssertNil(completed.recordedExternalVolumeKilograms)
        XCTAssertTrue(completed.exercises.flatMap(\.sets).allSatisfy {
            $0.actualRepetitions == nil && $0.actualLoadKilograms == nil && !$0.isCompleted
        })
        XCTAssertEqual(completed.recordedDuration, 90)
    }

    func testSavedTemplateUsesExistingTemplatePersistenceBoundary() throws {
        let coordinator = makeCoordinator()
        let exercise = try FitnessStrengthExercise(
            id: "custom-deadlift",
            name: "Custom deadlift",
            muscleGroup: .back,
            sets: 3,
            repetitions: 5,
            loadKilograms: 100
        )
        let template = try FitnessStrengthTemplate(
            id: "custom-template",
            name: "Custom pull day",
            exercises: [exercise]
        )

        coordinator.saveTemplate(template)

        let saved = try XCTUnwrap(coordinator.state.templates.first(where: { $0.id == "custom-template" }))
        XCTAssertEqual(saved.source, .saved)
        XCTAssertEqual(saved.editableTemplate?.id, template.id)
        XCTAssertEqual(saved.snapshot.exercises.first?.name, "Custom deadlift")
    }

    func testTemplatePersistenceFailureReturnsFalseAndRetryCanUseSameDraft() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("lifeos-template-retry-\(UUID().uuidString)", isDirectory: true)
        let persistenceURL = root.appendingPathComponent("templates.json", isDirectory: false)
        try fileManager.createDirectory(at: persistenceURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let coordinator = FitnessTrainingCoordinator(
            trainingStore: FitnessTrainingStore(persistenceURL: nil),
            templateStore: FitnessStrengthTemplateStore(persistenceURL: persistenceURL)
        )
        let exercise = try FitnessStrengthExercise(
            id: "retry-exercise",
            name: "Bench press",
            muscleGroup: .chest,
            sets: 3,
            repetitions: 8,
            loadKilograms: 80
        )
        let template = try FitnessStrengthTemplate(
            id: "retry-template",
            name: "Retry template",
            exercises: [exercise]
        )

        XCTAssertFalse(coordinator.saveTemplate(template))
        XCTAssertNil(coordinator.state.templates.first(where: { $0.id == template.id }))

        try fileManager.removeItem(at: persistenceURL)
        XCTAssertTrue(coordinator.saveTemplate(template))
        XCTAssertEqual(coordinator.state.templates.first(where: { $0.id == template.id })?.source, .saved)
    }

    func testEditorLoadTextHasNoGroupingAndParsesLegacyLocaleGrouping() throws {
        let german = Locale(identifier: "de_DE")
        let english = Locale(identifier: "en_US_POSIX")

        XCTAssertEqual(FitnessTrainingLoadText.string(1_000, locale: german), "1000")
        XCTAssertEqual(FitnessTrainingLoadText.string(12.345, locale: german), "12,345")
        XCTAssertEqual(FitnessTrainingLoadText.string(12_345, locale: german), "12345")
        XCTAssertEqual(try XCTUnwrap(FitnessTrainingLoadText.parse("12,345", locale: german)), 12.345, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(FitnessTrainingLoadText.parse("1.000", locale: german)), 1_000, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(FitnessTrainingLoadText.parse("12.345", locale: german)), 12_345, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(FitnessTrainingLoadText.parse("1.000", locale: english)), 1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(FitnessTrainingLoadText.parse("12.345", locale: english)), 12.345, accuracy: 0.000_001)
        XCTAssertThrowsError(try FitnessTrainingLoadText.parse("1,00", locale: english))
        XCTAssertThrowsError(try FitnessTrainingLoadText.parse("1.", locale: english))
        XCTAssertThrowsError(try FitnessTrainingLoadText.parse("1.00", locale: german))
    }

    func testEditorLoadTextRoundTripsGermanTinyAndHighPrecisionValues() throws {
        let german = Locale(identifier: "de_DE")
        for value in [1e-16, 1.2345678901234567] {
            let text = FitnessTrainingLoadText.string(value, locale: german)
            XCTAssertFalse(text.contains("e"), "Editable load text must stay in the locale decimal grammar")
            XCTAssertFalse(text.contains("E"), "Editable load text must stay in the locale decimal grammar")
            XCTAssertTrue(text.contains(","), "German load text must use its decimal separator")
            XCTAssertEqual(try XCTUnwrap(FitnessTrainingLoadText.parse(text, locale: german)), value)
        }
    }

    func testProjectionRevisionTracksLedgerStateAndBerlinCalendarBoundary() {
        let snapshot = TrainingStoreSnapshot(
            sessions: [],
            generation: "generation-a",
            integrity: .verified,
            freshness: .current,
            capturedAt: Date(timeIntervalSinceReferenceDate: 2_000_000)
        )
        let staleSnapshot = TrainingStoreSnapshot(
            sessions: snapshot.sessions,
            generation: snapshot.generation,
            integrity: snapshot.integrity,
            freshness: .stale,
            capturedAt: snapshot.capturedAt
        )
        let unavailableSnapshot = TrainingStoreSnapshot(
            sessions: snapshot.sessions,
            generation: snapshot.generation,
            integrity: .unavailable,
            freshness: .stale,
            capturedAt: snapshot.capturedAt
        )
        let calendar = TrainingHistoryProjection.berlinCalendar()
        let beforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 23, minute: 59))!
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 0, minute: 1))!

        let current = FitnessTrainingProjectionRevision(snapshot: snapshot, now: beforeMidnight, calendar: calendar)
        let stale = FitnessTrainingProjectionRevision(snapshot: staleSnapshot, now: beforeMidnight, calendar: calendar)
        let unavailable = FitnessTrainingProjectionRevision(snapshot: unavailableSnapshot, now: beforeMidnight, calendar: calendar)
        let nextDay = FitnessTrainingProjectionRevision(snapshot: snapshot, now: afterMidnight, calendar: calendar)

        XCTAssertNotEqual(current, stale)
        XCTAssertNotEqual(current, unavailable)
        XCTAssertNotEqual(current, nextDay)
        XCTAssertEqual(current.generation, "generation-a")
        XCTAssertEqual(current.calendarDay, "1-2026-9-9")
    }

    func testBerlinBoundaryUsesInjectedClockAndCalendarDaysAcrossDST() {
        let calendar = TrainingHistoryProjection.berlinCalendar()
        let beforeDSTChange = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 0, minute: 30))!
        let expected = calendar.date(from: DateComponents(year: 2026, month: 3, day: 30, hour: 0, minute: 0))!
        let clock = FitnessTrainingTestClock(start: beforeDSTChange)
        let coordinator = makeCoordinator(clock: clock)

        XCTAssertEqual(coordinator.nextHistoryProjectionBoundary(), expected)
        XCTAssertEqual(
            coordinator.nextHistoryProjectionBoundary(after: expected),
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 31))!
        )
    }

    func testRefreshPublishesStaleBoundaryUntilDurableReadbackRecovers() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("lifeos-training-coordinator-recovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let clock = FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_200_000))
        let ledgerURL = root.appendingPathComponent("training.json")
        let store = FitnessTrainingStore(persistenceURL: ledgerURL, clock: { clock.now() })
        let coordinator = FitnessTrainingCoordinator(
            trainingStore: store,
            templateStore: FitnessStrengthTemplateStore(persistenceURL: root.appendingPathComponent("templates.json")),
            clock: { clock.now() }
        )

        await coordinator.refresh()
        let template = try XCTUnwrap(coordinator.state.templates.first(where: { $0.id == "starter-curls" }))
        let startReceipt = await coordinator.start(template: template)
        XCTAssertEqual(startReceipt?.outcome, .saved)
        let currentSessions = coordinator.state.sessions
        let currentRevision = coordinator.historyProjectionRevision
        let durable = try await store.export()

        try Data("{\"schemaVersion\":2,\"sessions\":".utf8).write(to: ledgerURL, options: .atomic)
        await coordinator.refresh()

        XCTAssertEqual(coordinator.state.sessions, currentSessions)
        XCTAssertEqual(coordinator.historyProjectionRevision.integrity, .unavailable)
        XCTAssertEqual(coordinator.historyProjectionRevision.freshness, .stale)
        XCTAssertNotEqual(coordinator.historyProjectionRevision, currentRevision)

        try durable.write(to: ledgerURL, options: .atomic)
        _ = try await store.load()
        await coordinator.refresh()

        XCTAssertEqual(coordinator.state.sessions, currentSessions)
        XCTAssertEqual(coordinator.historyProjectionRevision.integrity, .verified)
        XCTAssertEqual(coordinator.historyProjectionRevision.freshness, .current)
    }

    func testStaleDraftCannotReplaceExternallyFinishedSession() async throws {
        let clock = FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_100_000))
        let (editor, external) = makeSharedCoordinatorPair(clock: clock)
        await editor.refresh()
        let template = try XCTUnwrap(editor.state.templates.first(where: { $0.id == "starter-cardio" }))
        let startReceipt = await editor.start(template: template)
        XCTAssertEqual(startReceipt?.outcome, .saved)
        let staleDraft = try XCTUnwrap(editor.state.activeSession)
        await external.refresh()

        clock.advance(by: 90)
        let finishReceipt = await external.finish(draft: staleDraft)
        XCTAssertEqual(finishReceipt?.outcome, .saved)

        let result = await editor.save(draft: staleDraft)
        XCTAssertEqual(result?.outcome, .conflict)
        XCTAssertEqual(result?.currentSession?.status, .completed)
        XCTAssertEqual(editor.state.latestCompletedSession?.status, .completed)
    }

    func testStaleDraftCannotReplaceExternallyDiscardedSession() async throws {
        let clock = FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_100_000))
        let (editor, external) = makeSharedCoordinatorPair(clock: clock)
        await editor.refresh()
        let template = try XCTUnwrap(editor.state.templates.first(where: { $0.id == "starter-curls" }))
        let startReceipt = await editor.start(template: template)
        XCTAssertEqual(startReceipt?.outcome, .saved)
        let staleDraft = try XCTUnwrap(editor.state.activeSession)
        await external.refresh()

        clock.advance(by: 1)
        let discardReceipt = await external.discard(sessionID: staleDraft.id)
        XCTAssertEqual(discardReceipt?.outcome, .saved)

        let result = await editor.save(draft: staleDraft)
        XCTAssertEqual(result?.outcome, .conflict)
        XCTAssertEqual(result?.currentSession?.status, .discarded)
    }

    func testStaleDraftCannotResurrectExternallyDeletedSession() async throws {
        let clock = FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_100_000))
        let (editor, external) = makeSharedCoordinatorPair(clock: clock)
        await editor.refresh()
        let template = try XCTUnwrap(editor.state.templates.first(where: { $0.id == "starter-curls" }))
        let startReceipt = await editor.start(template: template)
        XCTAssertEqual(startReceipt?.outcome, .saved)
        let staleDraft = try XCTUnwrap(editor.state.activeSession)
        await external.refresh()

        clock.advance(by: 1)
        let deleteReceipt = await external.delete(sessionID: staleDraft.id)
        XCTAssertEqual(deleteReceipt?.outcome, .saved)

        let saveResult = await editor.save(draft: staleDraft)
        XCTAssertNil(saveResult)
        await editor.refresh()
        XCTAssertFalse(editor.state.sessions.contains(where: { $0.id == staleDraft.id }))
    }

    private func makeSharedCoordinatorPair(clock: FitnessTrainingTestClock) -> (FitnessTrainingCoordinator, FitnessTrainingCoordinator) {
        let store = FitnessTrainingStore(persistenceURL: nil, clock: { clock.now() })
        let editor = FitnessTrainingCoordinator(
            trainingStore: store,
            templateStore: FitnessStrengthTemplateStore(persistenceURL: nil),
            clock: { clock.now() }
        )
        let external = FitnessTrainingCoordinator(
            trainingStore: store,
            templateStore: FitnessStrengthTemplateStore(persistenceURL: nil),
            clock: { clock.now() }
        )
        return (editor, external)
    }

    private func makeCoordinator(clock: FitnessTrainingTestClock? = nil) -> FitnessTrainingCoordinator {
        let selectedClock = clock ?? FitnessTrainingTestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-training-coordinator-\(UUID().uuidString)", isDirectory: true)
        return FitnessTrainingCoordinator(
            trainingStore: FitnessTrainingStore(
                persistenceURL: persistenceRoot.appendingPathComponent("training.json"),
                clock: { selectedClock.now() }
            ),
            templateStore: FitnessStrengthTemplateStore(
                persistenceURL: persistenceRoot.appendingPathComponent("templates.json")
            ),
            clock: { selectedClock.now() }
        )
    }
}

private final class FitnessTrainingTestClock: @unchecked Sendable {
    private var value: Date

    init(start: Date) {
        value = start
    }

    func now() -> Date { value }

    func advance(by interval: TimeInterval) {
        value = value.addingTimeInterval(interval)
    }
}

private final class FitnessTrainingPersistenceFaults: @unchecked Sendable {
    var failBeforeReplace: Bool

    init(failBeforeReplace: Bool) {
        self.failBeforeReplace = failBeforeReplace
    }
}

private final class ApplicationSupportSentinelFileManager: FileManager {
    private let sentinelURL: URL
    private(set) var applicationSupportLookupCount = 0

    init(sentinelURL: URL) {
        self.sentinelURL = sentinelURL
        super.init()
    }

    override func urls(
        for directory: SearchPathDirectory,
        in domainMask: SearchPathDomainMask
    ) -> [URL] {
        guard directory == .applicationSupportDirectory else {
            return super.urls(for: directory, in: domainMask)
        }
        applicationSupportLookupCount += 1
        return [sentinelURL]
    }
}
