import Foundation
import XCTest
@testable import LifeOS

final class FitnessTrainingDomainTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    func testTrainingSummaryMetricsUseMeasuredFourTwoAndOneColumnFallbacks() {
        XCTAssertEqual(
            FitnessTrainingMetricLayout.minimumWidth(for: .fourUp),
            96 * 4 + LifeOSTokens.Space.md * 3
        )
        XCTAssertEqual(
            FitnessTrainingMetricLayout.minimumWidth(for: .twoUp),
            128 * 2 + LifeOSTokens.Space.md
        )
        XCTAssertEqual(FitnessTrainingMetricLayout.minimumWidth(for: .oneUp), 0)
    }

    func testTrainingVisualRepairsKeepDiscardGuardLabelsAndProjectionCacheContracts() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homeSource = try String(
            contentsOf: iosRoot.appendingPathComponent("LifeOS/Modules/Fitness/FitnessTrainingView.swift"),
            encoding: .utf8
        )
        let editorSource = try String(
            contentsOf: iosRoot.appendingPathComponent("LifeOS/Modules/Fitness/FitnessTrainingSessionView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(homeSource.contains("pendingActiveDiscardSessionID"))
        XCTAssertTrue(homeSource.contains("Discard active session?"))
        XCTAssertTrue(homeSource.contains("Button(\"Discard session\", role: .destructive)"))
        XCTAssertTrue(homeSource.contains("Button(\"Keep session\", role: .cancel)"))
        XCTAssertTrue(homeSource.contains("historyProjectionCache"))
        XCTAssertTrue(homeSource.contains("historyProjectionBoundary"))
        XCTAssertTrue(homeSource.contains("localRevision"))
        XCTAssertTrue(homeSource.contains("currentHistoryProjectionRevision"))
        XCTAssertFalse(homeSource.contains("FitnessTrainingStatistics"))
        XCTAssertFalse(homeSource.contains("statisticsCache"))
        XCTAssertFalse(homeSource.contains("statisticsBoundary"))
        XCTAssertTrue(homeSource.contains("overviewCard(projection.statistics)"))
        XCTAssertTrue(homeSource.contains("fitnessTrainingOverviewVolumeSummary"))
        XCTAssertTrue(homeSource.contains("historySection(projection)"))
        XCTAssertTrue(homeSource.contains("importedBoundary(projection)"))
        XCTAssertTrue(homeSource.contains("historyProjectionBoundary != boundary"))
        XCTAssertTrue(homeSource.contains(".onChange(of: coordinator.historyProjectionRevision)"))
        XCTAssertTrue(homeSource.contains(".onChange(of: healthKitFitnessProjection)"))
        XCTAssertTrue(homeSource.contains("refreshHistoryProjection()"))
        XCTAssertTrue(homeSource.contains("@Environment(\\.scenePhase)"))
        XCTAssertTrue(homeSource.contains("calendarBoundaryTask"))
        XCTAssertTrue(homeSource.contains("startCalendarBoundaryTask()"))
        XCTAssertTrue(homeSource.contains("stopCalendarBoundaryTask()"))
        XCTAssertTrue(homeSource.contains("Task.sleep(nanoseconds:"))
        XCTAssertTrue(homeSource.contains("FitnessTrainingCalendarBoundaryScheduler.run"))
        XCTAssertTrue(homeSource.contains("initialBoundary:"))
        XCTAssertTrue(homeSource.contains("nextBoundary: { FitnessTrainingCalendarBoundary.nextBerlinMidnight(after: $0) }"))
        XCTAssertTrue(homeSource.contains("now >= boundary"))
        XCTAssertTrue(homeSource.contains("importedSourceRevision"))
        XCTAssertTrue(homeSource.contains("importedSnapshotSourceRevision"))
        XCTAssertTrue(homeSource.contains("refreshImportedSnapshotIfNeeded"))
        XCTAssertTrue(homeSource.contains(".onDisappear"))
        XCTAssertTrue(homeSource.contains("Discard template changes?"))
        XCTAssertTrue(homeSource.contains(".interactiveDismissDisabled(isDirty)"))
        XCTAssertTrue(homeSource.contains("hasSaveFailure ||"))
        XCTAssertTrue(editorSource.contains("Target load"))
        XCTAssertTrue(editorSource.contains(".submitLabel("))
        XCTAssertTrue(editorSource.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(editorSource.contains("terminalDraftPreview"))
        XCTAssertTrue(editorSource.contains("Draft preview · read-only"))
        XCTAssertTrue(editorSource.contains(".textSelection(.enabled)"))
        XCTAssertTrue(editorSource.contains("ToolbarItemGroup(placement: .keyboard)"))
        XCTAssertEqual(editorSource.components(separatedBy: "ToolbarItemGroup(placement: .keyboard)").count - 1, 1)
        XCTAssertTrue(editorSource.contains("numericFieldOrder"))
        XCTAssertTrue(editorSource.contains("Previous numeric field"))
        XCTAssertTrue(editorSource.contains("Next numeric field"))
        XCTAssertTrue(editorSource.contains("@FocusState private var focusedNumericField"))
        XCTAssertTrue(editorSource.contains("moveFocus(previous: true)"))
        XCTAssertTrue(editorSource.contains("moveFocus(previous: false)"))
        XCTAssertTrue(editorSource.contains("focusedNumericField = nil"))
        XCTAssertTrue(editorSource.contains("Button(\"Done\")"))
    }

    @MainActor
    func testBerlinBoundarySchedulerWaitsForOriginalTargetAcrossAutumnDST() async {
        let calendar = TrainingHistoryProjection.berlinCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 0))!
        let boundary = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 0, minute: 0))!
        var now = start
        var sleepDurations: [UInt64] = []
        var handledBoundaries: [Date] = []
        var shouldContinue = true

        await FitnessTrainingCalendarBoundaryScheduler.run(
            initialBoundary: boundary,
            clock: { now },
            sleeper: { nanoseconds in
                sleepDurations.append(nanoseconds)
                if sleepDurations.count == 1 {
                    // An early wake after 24 real hours is still 23:00 on the
                    // Berlin wall clock during the 25-hour autumn day.
                    now = start.addingTimeInterval(24 * 60 * 60)
                } else {
                    now = boundary
                }
            },
            nextBoundary: { FitnessTrainingCalendarBoundary.nextBerlinMidnight(after: $0) },
            shouldContinue: { shouldContinue },
            onBoundary: { reached in
                handledBoundaries.append(reached)
                shouldContinue = false
            }
        )

        XCTAssertEqual(sleepDurations.count, 2)
        XCTAssertEqual(sleepDurations[0], 25 * 60 * 60 * 1_000_000_000)
        XCTAssertEqual(sleepDurations[1], 60 * 60 * 1_000_000_000)
        XCTAssertEqual(handledBoundaries, [boundary])
    }

    func testTerminalConflictStatePreservesEvidenceForEachExternalTerminalOutcome() throws {
        let session = try TrainingSession(
            title: "Local draft",
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            notes: "Keep these notes",
            now: now
        )

        let completed = FitnessTrainingTerminalState.completed(session)
        let discarded = FitnessTrainingTerminalState.discarded(session)
        let deleted = FitnessTrainingTerminalState.deleted

        XCTAssertEqual(completed.latestSession, session)
        XCTAssertEqual(discarded.latestSession, session)
        XCTAssertNil(deleted.latestSession)
        XCTAssertTrue(completed.message.contains("preserved"))
        XCTAssertTrue(discarded.message.contains("preserved"))
        XCTAssertTrue(deleted.message.contains("preserved"))
    }

    func testLocalIDsEncodeCanonicalLowercaseAndStrictDecodingRejectsUnknownValues() throws {
        let uuid = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let id = TrainingRecordID(uuid: uuid)
        XCTAssertEqual(id.rawValue, "01234567-89ab-cdef-0123-456789abcdef")

        let encoder = JSONEncoder()
        XCTAssertEqual(String(data: try encoder.encode(id), encoding: .utf8), "\"01234567-89ab-cdef-0123-456789abcdef\"")
        XCTAssertThrowsError(try TrainingRecordID(rawValue: id.rawValue.uppercased()))

        let badKind = Data("""
        {"id":"01234567-89ab-cdef-0123-456789abcdef","kind":"working_set","isCompleted":false}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingSetLog.self, from: badKind))

        let unknownField = Data("""
        {"id":"01234567-89ab-cdef-0123-456789abcdef","kind":"working","isCompleted":false,"unexpected":true}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingSetLog.self, from: unknownField))
    }

    func testTextUsesUTF8BoundsAndRejectsBlankOrControlCharacters() throws {
        let exactlyFourHundredBytes = String(repeating: "é", count: 200)
        XCTAssertEqual(exactlyFourHundredBytes.utf8.count, 400)
        XCTAssertNoThrow(try TrainingExerciseLog(name: exactlyFourHundredBytes))

        let tooLarge = String(repeating: "é", count: 201)
        XCTAssertThrowsError(try TrainingExerciseLog(name: tooLarge))
        XCTAssertThrowsError(try TrainingExerciseLog(name: "   "))
        XCTAssertThrowsError(try TrainingExerciseLog(name: "Bench\n"))
        XCTAssertThrowsError(try TrainingExerciseLog(name: "Bench\nPress"))

        XCTAssertNoThrow(try TrainingSession(
            title: "  Push day  ",
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            notes: String(repeating: "é", count: 1_000),
            now: now
        ))
        XCTAssertThrowsError(try TrainingSession(
            title: "Push day",
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            notes: String(repeating: "é", count: 1_001),
            now: now
        ))
    }

    func testTargetsRemainSeparateFromActualsAndNilLoadIsNotZero() throws {
        let targetOnly = try TrainingSetLog(
            targetRepetitions: 8,
            targetLoadKilograms: 80,
            now: now
        )
        XCTAssertNil(targetOnly.externalVolumeKilograms(loadConvention: .externalTotal))

        let explicitZero = try TrainingSetLog(
            targetRepetitions: 8,
            targetLoadKilograms: 80,
            actualRepetitions: 1,
            actualLoadKilograms: 0,
            isCompleted: true,
            completedAt: now,
            now: now
        )
        XCTAssertEqual(explicitZero.externalVolumeKilograms(loadConvention: .externalTotal), 0)

        let unknownLoad = try TrainingSetLog(
            targetRepetitions: 8,
            actualRepetitions: 1,
            isCompleted: true,
            completedAt: now,
            now: now
        )
        XCTAssertNil(unknownLoad.externalVolumeKilograms(loadConvention: .externalTotal))

        let warmup = try TrainingSetLog(
            kind: .warmup,
            actualRepetitions: 5,
            actualLoadKilograms: 20,
            isCompleted: true,
            completedAt: now,
            now: now
        )
        let working = try TrainingSetLog(
            kind: .working,
            actualRepetitions: 10,
            actualLoadKilograms: 40,
            isCompleted: true,
            completedAt: now,
            now: now
        )
        let exercise = try TrainingExerciseLog(
            name: "Bench press",
            muscleGroup: .chest,
            loadConvention: .externalTotal,
            sets: [warmup, working, unknownLoad]
        )
        XCTAssertEqual(exercise.recordedExternalVolumeKilograms, 500)
        XCTAssertEqual(exercise.recordedWorkingVolumeKilograms, 400)
        XCTAssertEqual(exercise.bestRecordedExternalWorkingLoadKilograms, 40)
        XCTAssertEqual(exercise.completedSets.count, 3)

        let bodyweight = try TrainingExerciseLog(
            name: "Pull-up",
            muscleGroup: .back,
            loadConvention: .bodyweight,
            sets: [try TrainingSetLog(
                actualRepetitions: 8,
                actualLoadKilograms: 80,
                isCompleted: true,
                completedAt: now,
                now: now
            )]
        )
        XCTAssertNil(bodyweight.recordedExternalVolumeKilograms)
        XCTAssertNil(bodyweight.bestRecordedExternalWorkingLoadKilograms)
    }

    func testSetAndExerciseBoundsAndFiniteLoadsAreEnforced() throws {
        XCTAssertThrowsError(try TrainingSetLog(targetRepetitions: 0, now: now))
        XCTAssertThrowsError(try TrainingSetLog(actualRepetitions: 1_001, now: now))
        XCTAssertThrowsError(try TrainingSetLog(actualRepetitions: 1, actualLoadKilograms: .nan, now: now))
        XCTAssertThrowsError(try TrainingSetLog(actualRepetitions: 1, actualLoadKilograms: .infinity, now: now))

        let sets = try (0..<101).map { index in
            try TrainingSetLog(id: makeID(index), targetRepetitions: 8, now: now)
        }
        XCTAssertThrowsError(try TrainingExerciseLog(name: "Too many sets", sets: sets))

        let exercises = try (0..<101).map { index in
            try TrainingExerciseLog(id: makeID(index), name: "Exercise \(index)")
        }
        XCTAssertThrowsError(try TrainingSession(
            title: "Too many exercises",
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            exercises: exercises,
            now: now
        ))

        let pauses = try (0..<TrainingDomainLimits.maximumPausesPerSession).map { index in
            try TrainingPauseInterval(
                startedAt: now.addingTimeInterval(-Double(index + 2) * 2),
                endedAt: now.addingTimeInterval(-Double(index + 2) * 2 + 1),
                now: now
            )
        }
        XCTAssertNoThrow(try TrainingSession(
            title: "Pause limit",
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now,
            startedAt: now.addingTimeInterval(-600),
            pauses: pauses.sorted { $0.startedAt < $1.startedAt },
            now: now
        ))
        let tooManyPauses = pauses + [try TrainingPauseInterval(
            startedAt: now.addingTimeInterval(-1),
            endedAt: now.addingTimeInterval(-0.5),
            now: now
        )]
        XCTAssertThrowsError(try TrainingSession(
            title: "Too many pauses",
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now,
            startedAt: now.addingTimeInterval(-600),
            pauses: tooManyPauses.sorted { $0.startedAt < $1.startedAt },
            now: now
        )) { error in
            XCTAssertEqual(error as? TrainingValidationError, .tooManyPauses)
        }

        XCTAssertThrowsError(try TrainingSession(
            revision: Int.max,
            title: "Revision overflow",
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            now: now
        )) { error in
            XCTAssertEqual(error as? TrainingValidationError, .invalidRevision)
        }

        let overflowMutation = TrainingMutation(
            mutationID: makeID(91),
            operation: .discard,
            recordID: makeID(92),
            expectedRevision: Int.max
        )
        let overflowMutationData = try TrainingDateCoding.makeEncoder().encode(overflowMutation)
        XCTAssertThrowsError(try TrainingDateCoding.makeDecoder(now: now).decode(TrainingMutation.self, from: overflowMutationData))
        XCTAssertThrowsError(try TrainingCommitReceipt(
            mutationID: makeID(93),
            outcome: .saved,
            revision: Int.max
        )) { error in
            XCTAssertEqual(error as? TrainingValidationError, .invalidRevision)
        }
    }

    func testCompletionAndPauseStateInvariantsAreExplicit() throws {
        let unfinished = try TrainingSession(
            title: "Open session",
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            now: now
        )
        XCTAssertEqual(unfinished.status, .active)

        XCTAssertThrowsError(try TrainingSession(
            title: "No completed set",
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            status: .completed,
            now: now
        )) { error in
            XCTAssertEqual(error as? TrainingValidationError, .completedSessionRequiresSet)
        }

        let timedEnd = now.addingTimeInterval(90)
        let timed = try TrainingSession(
            activityKind: .cardio,
            title: "Timed cardio",
            createdAt: now,
            updatedAt: timedEnd,
            startedAt: now,
            endedAt: timedEnd,
            status: .completed,
            now: timedEnd
        )
        XCTAssertTrue(timed.completedSets.isEmpty)
        XCTAssertNil(timed.recordedExternalVolumeKilograms)
        XCTAssertEqual(timed.recordedDuration, 90)

        let openPause = try TrainingPauseInterval(startedAt: now.addingTimeInterval(-30), now: now)
        let paused = try TrainingSession(
            title: "Paused",
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now,
            startedAt: now.addingTimeInterval(-60),
            pauses: [openPause],
            status: .paused,
            now: now
        )
        XCTAssertEqual(paused.status, .paused)
        XCTAssertThrowsError(try TrainingSession(
            title: "Active with open pause",
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now,
            startedAt: now.addingTimeInterval(-60),
            pauses: [openPause],
            status: .active,
            now: now
        ))

        let first = try TrainingPauseInterval(
            startedAt: now.addingTimeInterval(-50),
            endedAt: now.addingTimeInterval(-30),
            now: now
        )
        let overlapping = try TrainingPauseInterval(
            startedAt: now.addingTimeInterval(-40),
            endedAt: now.addingTimeInterval(-20),
            now: now
        )
        XCTAssertThrowsError(try TrainingSession(
            title: "Overlapping pauses",
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now,
            startedAt: now.addingTimeInterval(-100),
            pauses: [first, overlapping],
            now: now
        ))

        XCTAssertThrowsError(try TrainingPauseInterval(
            startedAt: now.addingTimeInterval(TrainingDomainLimits.futureTolerance + 1),
            now: now
        ))
    }

    func testEveryValidatedNonStrengthSessionCanFinishWithoutSyntheticSetMetrics() throws {
        let start = now.addingTimeInterval(-120)
        let end = now.addingTimeInterval(-30)

        for activityKind in TrainingActivityKind.allCases where activityKind != .strength {
            let session = try TrainingSession(
                activityKind: activityKind,
                title: "Timed \(activityKind.rawValue)",
                createdAt: start,
                updatedAt: end,
                startedAt: start,
                endedAt: end,
                status: .completed,
                exercises: [],
                now: now
            )

            XCTAssertEqual(session.status, .completed)
            XCTAssertTrue(session.completedSets.isEmpty)
            XCTAssertNil(session.recordedExternalVolumeKilograms)
            XCTAssertEqual(session.recordedDuration, 90)
        }

        let repetitionsOnly = try TrainingSetLog(
            actualRepetitions: 8,
            actualLoadKilograms: nil,
            isCompleted: true,
            completedAt: start.addingTimeInterval(30),
            now: now
        )
        let strength = try TrainingSession(
            title: "Load not recorded",
            createdAt: start,
            updatedAt: end,
            startedAt: start,
            endedAt: end,
            status: .completed,
            exercises: [try TrainingExerciseLog(name: "Bench", sets: [repetitionsOnly])],
            now: now
        )
        XCTAssertEqual(strength.completedSets.count, 1)
        XCTAssertNil(strength.recordedExternalVolumeKilograms)
    }

    func testDSTSessionKeepsWallClockZoneAndInstantDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 0, minute: 30))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 3, minute: 30))!
        let validationNow = end.addingTimeInterval(3_600)

        let set = try TrainingSetLog(
            actualRepetitions: 5,
            actualLoadKilograms: 20,
            isCompleted: true,
            completedAt: start.addingTimeInterval(600),
            now: validationNow
        )
        let exercise = try TrainingExerciseLog(
            name: "Deadlift",
            muscleGroup: .legs,
            sets: [set]
        )
        let session = try TrainingSession(
            title: "DST session",
            createdAt: start,
            updatedAt: end,
            startedAt: start,
            endedAt: end,
            timeZoneIdentifier: "Europe/Berlin",
            status: .completed,
            exercises: [exercise],
            now: validationNow
        )
        XCTAssertEqual(session.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(session.recordedDuration, end.timeIntervalSince(start))
        XCTAssertEqual(session.recordedDuration, 2 * 60 * 60)
    }

    func testCodableRoundTripPreservesSnapshotAndStrictHistorySource() throws {
        let snapshotExercise = try TrainingTemplateExerciseSnapshot(
            id: "bench-press",
            name: "Bench press",
            muscleGroup: .chest,
            targetSets: 4,
            targetRepetitions: 6,
            targetLoadKilograms: 80
        )
        let snapshot = try TrainingTemplateSnapshot(
            templateID: "push-day",
            name: "Push day",
            exercises: [snapshotExercise]
        )
        let session = try TrainingSession(
            revision: 2,
            title: "Push day",
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now,
            startedAt: now.addingTimeInterval(-120),
            timeZoneIdentifier: "Europe/Berlin",
            templateID: "push-day",
            templateSnapshot: snapshot,
            now: now
        )

        let encoder = TrainingDateCoding.makeEncoder()
        let data = try encoder.encode(session)
        let decoder = TrainingDateCoding.makeDecoder(now: now)
        let decoded = try decoder.decode(TrainingSession.self, from: data)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.templateSnapshot?.exercises.first?.name, "Bench press")

        let coverage = try TrainingCoverage(
            kind: .partial,
            lowerBound: session.startedAt,
            upperBound: nil,
            now: now
        )
        XCTAssertEqual(coverage.kind, .partial)

        let history = try TrainingHistoryItem(session: session, now: now)
        XCTAssertEqual(history.sourceState, .local)
        XCTAssertEqual(history.coverage.kind, .partial)
    }

    func testLosslessFractionalDatesAndFingerprintsRemainDistinct() throws {
        let firstDate = now.addingTimeInterval(0.123456789)
        let secondDate = now.addingTimeInterval(0.923456789)
        let pause = try TrainingPauseInterval(
            startedAt: firstDate.addingTimeInterval(0.500123),
            endedAt: firstDate.addingTimeInterval(0.500579),
            now: secondDate.addingTimeInterval(10)
        )
        let first = try TrainingSession(
            id: makeID(88),
            title: "Precision",
            createdAt: firstDate,
            updatedAt: firstDate,
            startedAt: firstDate,
            pauses: [pause],
            now: secondDate.addingTimeInterval(10)
        )
        let second = try TrainingSession(
            id: first.id,
            title: "Precision",
            createdAt: secondDate,
            updatedAt: secondDate,
            startedAt: secondDate,
            now: secondDate.addingTimeInterval(10)
        )
        let encoded = try TrainingDateCoding.makeEncoder().encode(first)
        let decoded = try TrainingDateCoding.makeDecoder(now: secondDate.addingTimeInterval(10)).decode(TrainingSession.self, from: encoded)
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(decoded.pauses.first?.startedAt, pause.startedAt)
        XCTAssertEqual(decoded.pauses.first?.endedAt, pause.endedAt)

        let firstMutation = TrainingMutation(
            mutationID: makeID(90),
            operation: .update,
            recordID: first.id,
            expectedRevision: 0,
            session: first
        )
        let secondMutation = TrainingMutation(
            mutationID: makeID(90),
            operation: .update,
            recordID: second.id,
            expectedRevision: 0,
            session: second
        )
        XCTAssertNotEqual(
            try TrainingFingerprint.hex(for: firstMutation),
            try TrainingFingerprint.hex(for: secondMutation)
        )
    }

    func testImportedHistoryPreservesIdentityUnknownActivityEnergyAndSourceQualification() throws {
        let identity = try TrainingImportedWorkoutIdentity(
            uuid: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            syncIdentifier: "zepp-workout-001",
            revision: try TrainingImportedSampleRevision(syncVersion: 7)
        )
        let provenance = try TrainingImportedWorkoutProvenance(
            sourceBundleIdentifier: "com.zepp.health",
            sourceName: "Zepp",
            sourceVersion: "9.0",
            deviceManufacturer: "Amazfit",
            deviceModel: "Helio Strap",
            helioMatch: .confirmed
        )
        let started = now.addingTimeInterval(-600.125)
        let ended = now.addingTimeInterval(-300.125)
        let complete = try TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: 9_999,
            startedAt: started,
            endedAt: ended,
            durationSeconds: 300,
            activeEnergyKilocalories: 0,
            provenance: provenance,
            now: now
        )
        let missingEnergy = try TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: 9_999,
            startedAt: started,
            endedAt: ended,
            durationSeconds: 300,
            activeEnergyKilocalories: nil,
            now: now
        )
        XCTAssertEqual(complete.id, identity.stableKey)
        XCTAssertEqual(identity.revision, .syncVersion(7))
        XCTAssertTrue(complete.provenance?.hasEvidence == true)
        XCTAssertEqual(complete.provenance?.helioMatch, .confirmed)
        XCTAssertEqual(complete.activeEnergyKilocalories, 0)
        XCTAssertNil(missingEnergy.activeEnergyKilocalories)
        XCTAssertNotEqual(complete, missingEnergy)

        let partial = try TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: 9_999,
            startedAt: started,
            endedAt: ended,
            durationSeconds: 300,
            sourceState: .partial,
            now: now
        )
        let unavailable = try TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: 9_999,
            startedAt: started,
            endedAt: ended,
            durationSeconds: 300,
            sourceState: .unavailable,
            coverage: try TrainingCoverage(kind: .unavailable, now: now),
            provenance: provenance,
            now: now
        )
        XCTAssertEqual(partial.coverage.kind, .partial)
        XCTAssertEqual(unavailable.coverage.kind, .unavailable)
        XCTAssertEqual(unavailable.provenance?.deviceModel, "Helio Strap")

        let entry: TrainingHistoryEntry = .imported(complete)
        let data = try TrainingDateCoding.makeEncoder().encode(entry)
        let decoded = try TrainingDateCoding.makeDecoder(now: now).decode(TrainingHistoryEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
        XCTAssertThrowsError(try TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: -1,
            startedAt: started,
            endedAt: ended,
            durationSeconds: 300,
            now: now
        )) { error in
            XCTAssertEqual(error as? TrainingValidationError, .invalidImportedActivity)
        }
    }

    func testImportedRevisionBoundaryRejectsNegativeDirectValuesAndInvalidSyncSemantics() throws {
        let invalid = TrainingImportedSampleRevision.syncVersion(-1)
        XCTAssertThrowsError(try TrainingImportedWorkoutIdentity(
            uuid: makeID(122).uuid,
            revision: invalid
        )) { error in
            XCTAssertEqual(error as? TrainingValidationError, .invalidImportedIdentity)
        }
        XCTAssertThrowsError(try TrainingDateCoding.makeEncoder().encode(invalid))

        let decoder = TrainingDateCoding.makeDecoder(now: now)
        XCTAssertThrowsError(try decoder.decode(
            TrainingImportedSampleRevision.self,
            from: Data("{\"kind\":\"sync_version\",\"value\":-1}".utf8)
        ))
        XCTAssertThrowsError(try TrainingImportedWorkoutIdentity(
            uuid: makeID(123).uuid,
            syncIdentifier: "provider-workout",
            revision: .uuidFallback
        ))
        XCTAssertThrowsError(try TrainingImportedWorkoutIdentity(
            uuid: makeID(124).uuid,
            revision: .syncVersion(1)
        ))
    }

    func testImportedStableKeysMatchUUIDAliasExpansionAndRejectAmbiguousKeys() throws {
        let first = "uuid:00000000-0000-0000-0000-000000000001"
        let expanded = "uuid:00000000-0000-0000-0000-000000000001,00000000-0000-0000-0000-000000000002"
        XCTAssertNotEqual(first, expanded, "The regression is about identity equality, not string equality")
        XCTAssertTrue(TrainingImportedWorkoutIdentity.stableKeysRepresentSameIdentity(first, expanded))
        XCTAssertFalse(TrainingImportedWorkoutIdentity.stableKeysRepresentSameIdentity(
            first,
            "uuid:00000000-0000-0000-0000-000000000003"
        ))
        XCTAssertTrue(TrainingImportedWorkoutIdentity.isValidStableKey("sync_identifier:provider,workout"))
        XCTAssertFalse(TrainingImportedWorkoutIdentity.isValidStableKey("uuid:00000000-0000-0000-0000-000000000002,00000000-0000-0000-0000-000000000001"))
        XCTAssertFalse(TrainingImportedWorkoutIdentity.isValidStableKey("uuid:00000000-0000-0000-0000-000000000001,00000000-0000-0000-0000-000000000001"))
    }

    func testCanonicalStableKeyUnionEnforcesTheCompleteAliasBound() throws {
        let tokens = (0...(TrainingDomainLimits.maximumImportedAliases + 1)).map { index in
            "uuid:\(makeID(200 + index).rawValue)"
        }

        XCTAssertThrowsError(try TrainingImportedWorkoutIdentity.canonicalStableKey(from: tokens)) { error in
            XCTAssertEqual(error as? TrainingValidationError, .invalidImportedIdentity)
        }

        let identity = try TrainingImportedWorkoutIdentity(
            uuid: makeID(300).uuid,
            syncIdentifier: "canonical-source",
            aliases: [makeID(301).uuid],
            revision: .syncVersion(4)
        )
        XCTAssertEqual(
            try TrainingImportedWorkoutIdentity.validateStableKey(identity.stableKey),
            identity.stableKey
        )
    }

    func testCleanImportedQueryCannotContainPartialRecordEvidence() throws {
        let start = now.addingTimeInterval(-120)
        let end = now.addingTimeInterval(-60)
        let identity = try TrainingImportedWorkoutIdentity(uuid: makeID(302).uuid)
        let partial = try TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: 20,
            startedAt: start,
            endedAt: end,
            durationSeconds: 60,
            sourceState: .partial,
            now: now
        )
        let completeWindow = try TrainingCoverage(
            kind: .complete,
            lowerBound: now.addingTimeInterval(-300),
            upperBound: now,
            now: now
        )

        XCTAssertThrowsError(try TrainingImportedHistorySnapshot(
            records: [partial],
            queryState: .imported,
            queryCoverage: completeWindow,
            now: now
        )) { error in
            XCTAssertEqual(error as? TrainingValidationError, .invalidCoverage)
        }
    }

    func testCoverageRequiresCompleteBoundsAndRecordCoverageMatchesItsInterval() throws {
        XCTAssertThrowsError(try TrainingCoverage(kind: .complete, lowerBound: now, now: now)) { error in
            XCTAssertEqual(error as? TrainingValidationError, .invalidCoverage)
        }

        let identity = try TrainingImportedWorkoutIdentity(uuid: makeID(120).uuid)
        let outside = try TrainingCoverage(
            kind: .partial,
            lowerBound: now.addingTimeInterval(60),
            upperBound: now.addingTimeInterval(120),
            now: now.addingTimeInterval(180)
        )
        XCTAssertThrowsError(try TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: 1,
            startedAt: now,
            endedAt: now.addingTimeInterval(30),
            durationSeconds: 30,
            sourceState: .partial,
            coverage: outside,
            now: now.addingTimeInterval(180)
        )) { error in
            XCTAssertEqual(error as? TrainingValidationError, .invalidCoverage)
        }
    }

    func testImportedQueryAvailabilityDoesNotDeleteRetainedEvidence() throws {
        let identity = try TrainingImportedWorkoutIdentity(uuid: makeID(121).uuid)
        let provenance = try TrainingImportedWorkoutProvenance(
            sourceBundleIdentifier: "com.zepp.health",
            sourceName: "Zepp",
            helioMatch: .candidate
        )
        let record = try TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: 42,
            startedAt: now.addingTimeInterval(-120),
            endedAt: now.addingTimeInterval(-60),
            durationSeconds: 60,
            activeEnergyKilocalories: 0,
            sourceState: .error,
            coverage: try TrainingCoverage(kind: .partial, lowerBound: now.addingTimeInterval(-120), upperBound: now.addingTimeInterval(-60), now: now),
            provenance: provenance,
            now: now
        )
        let snapshot = try TrainingImportedHistorySnapshot(
            records: [record],
            queryState: .error,
            queryCoverage: try TrainingCoverage(kind: .unavailable, now: now),
            now: now
        )
        XCTAssertEqual(snapshot.records, [record])
        XCTAssertEqual(snapshot.queryCoverage.kind, .unavailable)
        XCTAssertEqual(snapshot.records.first?.provenance?.helioMatch, .candidate)
        XCTAssertEqual(snapshot.records.first?.activeEnergyKilocalories, 0)

        switch TrainingImportedHistoryRecord.ingest(
            identity: identity,
            activityTypeRawValue: -1,
            startedAt: now,
            endedAt: now.addingTimeInterval(1),
            durationSeconds: 1,
            now: now
        ) {
        case .accepted:
            XCTFail("Malformed rows must be explicit skips")
        case .skipped(let rejection):
            XCTAssertEqual(rejection.reason, .invalidImportedActivity)
            XCTAssertEqual(rejection.stableKey, identity.stableKey)
        }
    }

    private func makeID(_ value: Int) -> TrainingRecordID {
        let suffix = String(format: "%012x", value + 1)
        return TrainingRecordID(uuid: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!)
    }
}
