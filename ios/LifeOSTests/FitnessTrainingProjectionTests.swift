import Foundation
import XCTest
@testable import LifeOS

final class FitnessTrainingProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    func testHealthKitAdapterPreservesIdentityRevisionDatesEnergyAndProvenance() throws {
#if os(iOS)
        let uuid = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let alias = UUID(uuidString: "11234567-89ab-cdef-0123-456789abcdef")!
        let source = try HealthKitSourceMetadata(
            bundleIdentifier: "com.zepp.health",
            name: "Zepp",
            version: "4.2",
            productType: "watch",
            operatingSystemVersion: "18.6"
        )
        let device = try HealthKitDeviceMetadata(
            name: "Workout watch",
            manufacturer: "Amazfit",
            model: "Helio Strap",
            hardwareVersion: "1",
            firmwareVersion: "2",
            softwareVersion: "3",
            localIdentifier: "device-1"
        )
        let provenance = try HealthKitProvenance.from(
            source: source,
            device: device,
            registry: .canonical
        )
        let start = now.addingTimeInterval(-3_600)
        let duration = 1_845.25
        let observation = try HealthKitObservation(
            metric: .workout,
            identity: HealthKitSampleIdentity(
                uuid: uuid,
                syncIdentifier: "workout-42",
                aliases: [alias],
                revision: try HealthKitSampleRevision(syncVersion: 42)
            ),
            value: .workout(try HealthKitWorkoutValue(
                activityTypeRawValue: 20,
                durationSeconds: duration,
                activeEnergyKilocalories: 0
            )),
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            provenance: provenance,
            now: now
        )
        let state = try HealthKitMetricProjection(
            metric: .workout,
            observations: [observation],
            lastCommittedAt: now,
            syncState: .synced
        )
        let healthKitProjection = HealthKitFitnessProjection(
            states: [HealthKitStoredMetricState(projection: state)],
            window: DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        )
        let workout = try XCTUnwrap(healthKitProjection.workouts.first)

        let bridgedSnapshot = try XCTUnwrap(healthKitProjection.trainingImportedSnapshot(now: now))
        XCTAssertEqual(bridgedSnapshot.queryState, .imported)
        XCTAssertEqual(bridgedSnapshot.queryCoverage.kind, .complete)
        let combined = TrainingHistoryProjection(
            localSnapshot: TrainingStoreSnapshot(
                sessions: [],
                generation: nil,
                integrity: .verified,
                freshness: .current,
                capturedAt: now
            ),
            importedSnapshot: bridgedSnapshot,
            now: now
        )
        XCTAssertEqual(combined.importedEntries.count, 1)
        XCTAssertTrue(combined.entries.contains {
            if case .imported = $0 { return true }
            return false
        })

        let input = try TrainingImportedWorkoutInput(workout: workout)
        let imported = try TrainingHistoryProjection.makeImportedSnapshot(
            from: [input],
            queryState: .imported,
            queryCoverage: try XCTUnwrap(TrainingCoverage(
                kind: .complete,
                lowerBound: start.addingTimeInterval(-1),
                upperBound: workout.endDate.addingTimeInterval(1),
                now: now
            )),
            now: now
        )
        let projected = try XCTUnwrap(imported.records.first)
        XCTAssertEqual(projected.healthState, .observed)
        XCTAssertEqual(projected.record.identity.uuid, uuid)
        XCTAssertEqual(projected.record.identity.syncIdentifier, "workout-42")
        XCTAssertEqual(projected.record.identity.aliases, [alias])
        XCTAssertEqual(projected.record.identity.revision, .syncVersion(42))
        XCTAssertEqual(projected.record.activityTypeRawValue, 20)
        XCTAssertEqual(projected.record.startedAt, start)
        XCTAssertEqual(projected.record.endedAt, workout.endDate)
        XCTAssertEqual(projected.record.durationSeconds, duration)
        XCTAssertEqual(projected.record.activeEnergyKilocalories, 0)
        XCTAssertEqual(projected.record.provenance?.sourceBundleIdentifier, source.bundleIdentifier)
        XCTAssertEqual(projected.record.provenance?.deviceModel, device.model)
        XCTAssertEqual(projected.record.provenance?.helioMatch, .confirmed)
        XCTAssertTrue(provenance.matchesCanonicalRegistry)
        XCTAssertTrue(projected.identityKeys.contains(projected.record.id))
        XCTAssertTrue(projected.identityKeys.contains("uuid:\(alias.uuidString.lowercased())"))
#else
        throw XCTSkip("HealthKit adapter coverage runs in the iOS test target.")
#endif
    }

    func testSourceQualificationIsPreservedForEveryExplicitValue() throws {
        let qualifications = TrainingSourceQualification.allCases
        let inputs = try qualifications.enumerated().map { index, qualification in
            let provenance = try TrainingImportedWorkoutProvenance(
                sourceBundleIdentifier: "com.example.source.\(index)",
                sourceName: "Source \(index)",
                helioMatch: qualification
            )
            let identity = try TrainingImportedWorkoutIdentity(
                uuid: try XCTUnwrap(UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index + 1))),
                syncIdentifier: "qualification-\(index)",
                revision: .syncVersion(1)
            )
            return TrainingImportedWorkoutInput(
                identity: identity,
                activityTypeRawValue: 20,
                startedAt: now.addingTimeInterval(-10_000 + Double(index * 600)),
                endedAt: now.addingTimeInterval(-9_700 + Double(index * 600)),
                durationSeconds: 300,
                activeEnergyKilocalories: 10,
                provenance: provenance
            )
        }

        let result = try makeImportedSnapshotResult(inputs, queryState: .partial)
        let observed = result.records.compactMap { $0.record.provenance?.qualification }
        XCTAssertEqual(Set(observed), Set(qualifications))
    }

    func testBridgeAliasesHaveOneDeterministicImportedOwnerAcrossPermutations() throws {
        let uuidA = try XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000001"))
        let uuidB = try XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000002"))
        let uuidC = try XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000003"))
        let start = now.addingTimeInterval(-3_600)
        let firstIdentity = try TrainingImportedWorkoutIdentity(
            uuid: uuidA,
            aliases: [uuidB],
            revision: .uuidFallback
        )
        let bridgeIdentity = try TrainingImportedWorkoutIdentity(
            uuid: uuidB,
            syncIdentifier: "bridge-workout",
            aliases: [uuidC],
            revision: .syncVersion(2)
        )
        let first = TrainingImportedWorkoutInput(
            identity: firstIdentity,
            activityTypeRawValue: 20,
            startedAt: start,
            endedAt: start.addingTimeInterval(900),
            durationSeconds: 900,
            activeEnergyKilocalories: 100
        )
        let bridge = TrainingImportedWorkoutInput(
            identity: bridgeIdentity,
            activityTypeRawValue: 20,
            startedAt: start,
            endedAt: start.addingTimeInterval(900),
            durationSeconds: 900,
            activeEnergyKilocalories: 100
        )

        let forward = try makeImportedSnapshotResult([first, bridge], queryState: .imported)
        let reverse = try makeImportedSnapshotResult([bridge, first], queryState: .imported)
        let forwardProjection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([]),
            importedSnapshot: forward.snapshot,
            now: now
        )
        let reverseProjection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([]),
            importedSnapshot: reverse.snapshot,
            now: now
        )

        XCTAssertEqual(forwardProjection.importedEntries, reverseProjection.importedEntries)
        let imported = try XCTUnwrap(forwardProjection.importedEntries.first)
        XCTAssertEqual(imported.record.identity.syncIdentifier, "bridge-workout")
        XCTAssertEqual(Set(imported.identityKeys), Set(imported.record.identity.aliasKeys))

        let firstOwner = try makeLocalSession(
            id: id(11), start: start, duration: 900, importedRecordKey: "uuid:\(uuidA.uuidString.lowercased())"
        )
        let secondOwner = try makeLocalSession(
            id: id(12), start: start, duration: 900, importedRecordKey: "sync_identifier:bridge-workout"
        )
        let ownership = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([firstOwner, secondOwner]),
            importedSnapshot: forward.snapshot,
            now: now
        )
        XCTAssertEqual(ownership.linkStates.map(\.status), [.conflict, .conflict])
        XCTAssertTrue(ownership.duplicateCandidates.isEmpty)
    }

    func testLongAliasChainUnionsUUIDSyncAndCompositeIdentityTokensDeterministically() throws {
        let uuidValues = try (0..<48).map { index in
            try XCTUnwrap(UUID(uuidString: String(format: "31000000-0000-0000-0000-%012d", index + 1)))
        }
        let start = now.addingTimeInterval(-5_000)
        let inputs = try uuidValues.enumerated().map { index, uuid in
            let identity = try TrainingImportedWorkoutIdentity(
                uuid: uuid,
                syncIdentifier: index == uuidValues.count - 1 ? "chain-workout" : nil,
                aliases: index + 1 < uuidValues.count ? [uuidValues[index + 1]] : [],
                revision: index == uuidValues.count - 1 ? .syncVersion(9) : .uuidFallback
            )
            return TrainingImportedWorkoutInput(
                identity: identity,
                activityTypeRawValue: 20,
                startedAt: start,
                endedAt: start.addingTimeInterval(900),
                durationSeconds: 900,
                activeEnergyKilocalories: 100
            )
        }

        let forward = try makeImportedSnapshotResult(inputs, queryState: .imported)
        let reverse = try makeImportedSnapshotResult(Array(inputs.reversed()), queryState: .imported)
        let forwardProjection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([]), importedSnapshot: forward.snapshot, now: now
        )
        let reverseProjection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([]), importedSnapshot: reverse.snapshot, now: now
        )

        XCTAssertEqual(forwardProjection.importedEntries, reverseProjection.importedEntries)
        let imported = try XCTUnwrap(forwardProjection.importedEntries.first)
        XCTAssertEqual(forwardProjection.importedEntries.count, 1)
        XCTAssertEqual(imported.record.identity.syncIdentifier, "chain-workout")
        XCTAssertEqual(imported.record.identity.aliases.count, uuidValues.count - 1)
        XCTAssertTrue(imported.identityKeys.contains("sync_identifier:chain-workout"))
        for uuid in uuidValues {
            XCTAssertTrue(imported.identityKeys.contains("uuid:\(uuid.uuidString.lowercased())"))
        }

        let firstOwner = try makeLocalSession(
            id: id(13), start: start, duration: 900,
            importedRecordKey: "uuid:\(uuidValues[0].uuidString.lowercased())"
        )
        let secondOwner = try makeLocalSession(
            id: id(14), start: start, duration: 900,
            importedRecordKey: "sync_identifier:chain-workout"
        )
        let ownership = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([firstOwner, secondOwner]),
            importedSnapshot: forward.snapshot,
            now: now
        )
        XCTAssertEqual(ownership.linkStates.map(\.status), [.conflict, .conflict])
        XCTAssertTrue(ownership.duplicateCandidates.isEmpty)
    }

    func testSameRevisionPayloadConflictsArePermutationInvariant() throws {
        let uuid = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let identity = try TrainingImportedWorkoutIdentity(
            uuid: uuid,
            syncIdentifier: "same-revision",
            revision: .syncVersion(7)
        )
        let start = now.addingTimeInterval(-4_000)
        let baseProvenance = try TrainingImportedWorkoutProvenance(
            sourceBundleIdentifier: "com.example.zepp",
            sourceName: "Zepp",
            helioMatch: .candidate
        )
        let alternateProvenance = try TrainingImportedWorkoutProvenance(
            sourceBundleIdentifier: "com.example.zepp",
            sourceName: "Zepp",
            sourceVersion: "different",
            helioMatch: .confirmed
        )
        let variants = [
            TrainingImportedWorkoutInput(
                identity: identity,
                activityTypeRawValue: 20,
                startedAt: start,
                endedAt: start.addingTimeInterval(900),
                durationSeconds: 900,
                activeEnergyKilocalories: 100,
                provenance: baseProvenance
            ),
            TrainingImportedWorkoutInput(
                identity: identity,
                activityTypeRawValue: 20,
                startedAt: start.addingTimeInterval(1),
                endedAt: start.addingTimeInterval(901),
                durationSeconds: 901,
                activeEnergyKilocalories: 101,
                provenance: alternateProvenance
            )
        ]

        let forward = try makeImportedSnapshotResult(variants, queryState: .imported)
        let reverse = try makeImportedSnapshotResult(Array(variants.reversed()), queryState: .imported)
        let forwardProjection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([]), importedSnapshot: forward.snapshot, now: now
        )
        let reverseProjection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([]), importedSnapshot: reverse.snapshot, now: now
        )

        XCTAssertEqual(forwardProjection.importedEntries, reverseProjection.importedEntries)
        XCTAssertEqual(forwardProjection.importedEntries.first?.healthState, .conflict)
        XCTAssertEqual(forwardProjection.importedQueryState, .conflict)
        XCTAssertEqual(forwardProjection.importedConflictEvidence.count, 1)
        XCTAssertEqual(forwardProjection.importedConflictEvidence.first?.conflictingRecordCount, 2)
        XCTAssertEqual(forwardProjection.importedConflictEvidence.first?.payloadFingerprints.count, 2)
    }

    func testSameRevisionSourceStateCoverageAndQualificationConflictsAreFullPayloadConflicts() throws {
        let uuid = UUID(uuidString: "41000000-0000-0000-0000-000000000001")!
        let identity = try TrainingImportedWorkoutIdentity(
            uuid: uuid,
            syncIdentifier: "same-state-revision",
            revision: .syncVersion(8)
        )
        let start = now.addingTimeInterval(-3_000)
        let candidate = try TrainingImportedWorkoutProvenance(
            sourceBundleIdentifier: "com.zepp.health",
            sourceName: "Zepp",
            helioMatch: .candidate
        )
        let confirmed = try TrainingImportedWorkoutProvenance(
            sourceBundleIdentifier: "com.zepp.health",
            sourceName: "Zepp",
            deviceManufacturer: "Amazfit",
            deviceModel: "Helio Strap",
            helioMatch: .confirmed
        )
        let variants = [
            TrainingImportedWorkoutInput(
                identity: identity,
                activityTypeRawValue: 20,
                startedAt: start,
                endedAt: start.addingTimeInterval(900),
                durationSeconds: 900,
                activeEnergyKilocalories: 100,
                healthState: .observed,
                provenance: candidate
            ),
            TrainingImportedWorkoutInput(
                identity: identity,
                activityTypeRawValue: 20,
                startedAt: start,
                endedAt: start.addingTimeInterval(900),
                durationSeconds: 900,
                activeEnergyKilocalories: 100,
                healthState: .partial,
                provenance: confirmed
            )
        ]

        let result = try makeImportedSnapshotResult(variants, queryState: .imported)
        let projection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([]), importedSnapshot: result.snapshot, now: now
        )

        XCTAssertEqual(projection.importedEntries.count, 1)
        XCTAssertEqual(projection.importedEntries.first?.healthState, .conflict)
        XCTAssertEqual(projection.importedQueryState, .conflict)
        XCTAssertEqual(projection.importedConflictEvidence.first?.conflictingRecordCount, 2)
        XCTAssertEqual(projection.importedConflictEvidence.first?.payloadFingerprints.count, 2)
        XCTAssertEqual(result.snapshot.queryCoverage.kind, .partial)
    }

    func testUnavailableImportedQueryRetainsImportedAndLocalHistory() throws {
        let local = try makeLocalSession(start: now.addingTimeInterval(-7_200), duration: 1_200)
        let input = makeInput(start: now.addingTimeInterval(-3_600), duration: 1_800, energy: 125)
        let available = try makeImportedSnapshot([input], queryState: .imported)
        let unavailable = try TrainingImportedHistorySnapshot(
            records: available.records,
            queryState: .error,
            queryCoverage: try TrainingCoverage(kind: .unavailable, now: now),
            now: now
        )

        let projection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([local]),
            importedSnapshot: unavailable,
            now: now
        )

        XCTAssertEqual(projection.localSessions.map(\.id), [local.id])
        XCTAssertEqual(projection.localEntries.count, 1)
        XCTAssertEqual(projection.importedEntries.count, 1)
        XCTAssertEqual(projection.importedQueryState, .error)
        XCTAssertEqual(projection.importedEntries.first?.record.id, input.identity.stableKey)
        XCTAssertEqual(projection.importedEntries.first?.healthState, .observed)
        XCTAssertEqual(projection.statistics.completedSessionCount, 1)
        XCTAssertEqual(projection.linkStates.first?.status, .unlinked)
    }

    func testDuplicateCandidateUsesIdentityAndLinkStateWithoutMergingRecords() throws {
        let importedInput = makeInput(
            start: now.addingTimeInterval(-3_000),
            duration: 1_850,
            activityTypeRawValue: 20,
            energy: nil
        )
        let local = try makeLocalSession(
            id: id(1),
            start: now.addingTimeInterval(-3_030),
            duration: 1_800,
            activityKind: .strength
        )
        let imported = try makeImportedSnapshot([importedInput], queryState: .imported)
        let unlinked = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([local]),
            importedSnapshot: imported,
            now: now
        )

        let candidate = try XCTUnwrap(unlinked.duplicateCandidates.first)
        XCTAssertEqual(candidate.localID, local.id)
        XCTAssertEqual(candidate.localIdentityKey, "local:\(local.id.rawValue)")
        XCTAssertEqual(candidate.importedRecordKey, importedInput.identity.stableKey)
        XCTAssertEqual(candidate.startDifferenceSeconds, 30, accuracy: 0.000_1)
        XCTAssertEqual(candidate.durationDifferenceSeconds, 50, accuracy: 0.000_1)
        XCTAssertEqual(unlinked.linkStates.first?.status, .unlinked)
        XCTAssertEqual(unlinked.importedEntries.count, 1)
        XCTAssertEqual(unlinked.localEntries.count, 1)

        let linkedLocal = try makeLocalSession(
            id: local.id,
            start: local.startedAt,
            duration: 1_800,
            activityKind: .strength,
            importedRecordKey: importedInput.identity.stableKey
        )
        let linked = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([linkedLocal]),
            importedSnapshot: imported,
            now: now
        )
        XCTAssertEqual(linked.linkStates.first?.status, .linked)
        XCTAssertTrue(linked.duplicateCandidates.isEmpty)
        XCTAssertTrue(linked.unlinkedImportedRecordKeys.isEmpty)
        XCTAssertEqual(linked.entries.filter { $0.sourceState == .local }.count, 1)
        XCTAssertEqual(linked.entries.filter { $0.sourceState == .imported }.count, 1)

        let uuidAliasKey = "uuid:\(importedInput.identity.uuid.uuidString.lowercased())"
        let linkedByAliasLocal = try makeLocalSession(
            id: local.id,
            start: local.startedAt,
            duration: 1_800,
            activityKind: .strength,
            importedRecordKey: uuidAliasKey
        )
        let linkedByAlias = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([linkedByAliasLocal]),
            importedSnapshot: imported,
            now: now
        )
        XCTAssertEqual(linkedByAlias.linkStates.first?.status, .linked)
        XCTAssertEqual(linkedByAlias.linkStates.first?.importedRecordKey, uuidAliasKey)
        XCTAssertTrue(linkedByAlias.unlinkedImportedRecordKeys.isEmpty)
    }

    func testStableNewestFirstOrderingAndExplicitLocalBeforeImportedTieBreak() throws {
        let newestLocal = try makeLocalSession(id: id(1), start: now.addingTimeInterval(-1_000), duration: 600)
        let olderLocal = try makeLocalSession(id: id(2), start: now.addingTimeInterval(-2_000), duration: 600)
        let sameStartImported = makeInput(
            start: newestLocal.startedAt,
            duration: 600,
            activityTypeRawValue: 20,
            energy: 0,
            uuid: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let projection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([olderLocal, newestLocal]),
            importedSnapshot: try makeImportedSnapshot([sameStartImported], queryState: .imported),
            now: now
        )

        XCTAssertEqual(projection.localSessions.map(\.id), [newestLocal.id, olderLocal.id])
        XCTAssertEqual(projection.entries.map(\.id), [
            "local:\(newestLocal.id.rawValue)",
            "imported:\(sameStartImported.identity.stableKey)",
            "local:\(olderLocal.id.rawValue)",
        ])
    }

    func testDSTCalendarCountsTwoBerlinStartDaysAsTwoDayStreak() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let march30 = calendar.date(from: DateComponents(year: 2024, month: 3, day: 30, hour: 12))!
        let march31 = calendar.date(from: DateComponents(year: 2024, month: 3, day: 31, hour: 12))!
        let april1 = calendar.date(from: DateComponents(year: 2024, month: 4, day: 1, hour: 12))!
        let first = try makeLocalSession(id: id(1), start: march30, duration: 3_600, validationNow: april1)
        let second = try makeLocalSession(id: id(2), start: march31, duration: 3_600, validationNow: april1)
        let projection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([first, second], capturedAt: april1),
            calendar: calendar,
            now: april1
        )

        XCTAssertEqual(projection.statistics.currentStreakDays, 2)
        XCTAssertEqual(projection.statistics.calendarTimeZoneIdentifier, "Europe/Berlin")
    }

    func testNilEnergyZeroEnergyUnknownActivityAndPerRecordStateStayDistinct() throws {
        let unknown = makeInput(
            start: now.addingTimeInterval(-2_000),
            duration: 300,
            activityTypeRawValue: 999_999,
            energy: nil,
            healthState: .error,
            uuid: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        let zero = makeInput(
            start: now.addingTimeInterval(-1_000),
            duration: 300,
            activityTypeRawValue: 20,
            energy: 0,
            uuid: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        )
        let sport = makeInput(
            start: now.addingTimeInterval(-900),
            duration: 300,
            activityTypeRawValue: 27,
            uuid: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let flexibility = makeInput(
            start: now.addingTimeInterval(-800),
            duration: 300,
            activityTypeRawValue: 62,
            uuid: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
        let result = try makeImportedSnapshot([unknown, zero, sport, flexibility], queryState: .partial)
        let projection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([]),
            importedSnapshot: result,
            now: now
        )

        let unknownEntry = try XCTUnwrap(projection.importedEntries.first { $0.record.activityTypeRawValue == 999_999 })
        let zeroEntry = try XCTUnwrap(projection.importedEntries.first { $0.record.activityTypeRawValue == 20 })
        XCTAssertNil(unknownEntry.record.activeEnergyKilocalories)
        XCTAssertEqual(unknownEntry.healthState, .error)
        XCTAssertNil(unknownEntry.activityKind)
        XCTAssertEqual(zeroEntry.record.activeEnergyKilocalories, 0)
        XCTAssertEqual(zeroEntry.healthState, .observed)
        XCTAssertEqual(projection.importedEntries.first { $0.record.activityTypeRawValue == 27 }?.activityKind, .sport)
        XCTAssertEqual(projection.importedEntries.first { $0.record.activityTypeRawValue == 62 }?.activityKind, .flexibility)
        XCTAssertEqual(projection.importedQueryState, .partial)
        XCTAssertEqual(projection.importedQueryCoverage?.kind, .partial)
    }

    func testMalformedRowsAreRejectedAndImportedHistoryIsCapped() throws {
        let invalid = makeInput(
            start: now,
            duration: .nan,
            uuid: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        )
        let invalidResult = try makeImportedSnapshotResult([invalid], queryState: .imported)
        XCTAssertTrue(invalidResult.snapshot.records.isEmpty)
        XCTAssertEqual(invalidResult.rejectedRows.count, 1)
        XCTAssertEqual(invalidResult.rejectedRows.first?.reason, .invalidDate(field: "imported workout end"))

        let outsideCoverage = makeInput(
            start: now.addingTimeInterval(-86_500),
            duration: 100,
            uuid: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddb")!
        )
        let outsideResult = try makeImportedSnapshotResult([outsideCoverage], queryState: .imported)
        XCTAssertTrue(outsideResult.snapshot.records.isEmpty)
        XCTAssertEqual(outsideResult.rejectedRows.first?.reason, .invalidCoverage)
        XCTAssertEqual(outsideResult.snapshot.queryState, .partial)

        let boundedInput = makeInput(
            start: now.addingTimeInterval(-100),
            duration: 100,
            uuid: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        )
        let inputs = Array(repeating: boundedInput, count: TrainingDomainLimits.maximumImportedHistoryRecords + 1)
        let bounded = try makeImportedSnapshotResult(inputs, queryState: .imported)
        XCTAssertEqual(bounded.snapshot.records.count, TrainingDomainLimits.maximumImportedHistoryRecords)
        XCTAssertEqual(bounded.rejectedRows.count, 1)

        let excessCount = 100
        let oversizedInputs = Array(
            repeating: boundedInput,
            count: TrainingDomainLimits.maximumImportedHistoryRecords +
                TrainingDomainLimits.maximumImportedDiagnostics + excessCount
        )
        let boundedTail = try makeImportedSnapshotResult(oversizedInputs, queryState: .imported)
        let expectedRejected = oversizedInputs.count - TrainingDomainLimits.maximumImportedHistoryRecords
        XCTAssertEqual(boundedTail.snapshot.rejectedRowCount, expectedRejected)
        XCTAssertEqual(boundedTail.snapshot.truncatedRowCount, expectedRejected)
        XCTAssertLessThanOrEqual(boundedTail.rejectedRows.count, TrainingDomainLimits.maximumImportedDiagnostics)
        XCTAssertEqual(boundedTail.snapshot.queryState, .partial)

        let inspectedLimitInputs = Array(
            repeating: boundedInput,
            count: TrainingDomainLimits.maximumImportedInputInspectionRows + 128
        )
        let boundedInspection = try makeImportedSnapshotResult(inspectedLimitInputs, queryState: .imported)
        let expectedInspectedOverflow = TrainingDomainLimits.maximumImportedInputInspectionRows -
            TrainingDomainLimits.maximumImportedHistoryRecords
        XCTAssertEqual(boundedInspection.snapshot.records.count, TrainingDomainLimits.maximumImportedHistoryRecords)
        XCTAssertEqual(
            boundedInspection.snapshot.rejectedRowCount,
            inspectedLimitInputs.count - TrainingDomainLimits.maximumImportedHistoryRecords
        )
        XCTAssertEqual(
            boundedInspection.snapshot.truncatedRowCount,
            expectedInspectedOverflow + 128
        )
        XCTAssertEqual(boundedInspection.snapshot.queryState, .partial)
    }

    func testDuplicateIndexBoundsComparisonsAndOutputForCrowdedWindow() throws {
        let local = try makeLocalSession(id: id(1), start: now.addingTimeInterval(-4_000), duration: 600)
        let inputs = (0..<300).map { index in
            makeInput(
                start: local.startedAt,
                duration: 600,
                activityTypeRawValue: 20,
                uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            )
        }
        let projection = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([local]),
            importedSnapshot: try makeImportedSnapshot(inputs, queryState: .imported),
            now: now
        )

        XCTAssertLessThanOrEqual(projection.duplicateComparisonCount, TrainingHistoryProjection.maximumDuplicateComparisonsPerLocal)
        XCTAssertLessThanOrEqual(projection.duplicateCandidates.count, TrainingHistoryProjection.maximumDuplicateCandidatesPerLocal)
        XCTAssertTrue(projection.duplicateMatchingWasBounded)
    }

    func testLocalStatisticsUseOnlyRecordedSetsAndPreserveZeroLoad() throws {
        let start = now.addingTimeInterval(-5_000)
        let zero = try TrainingSetLog(
            kind: .working,
            actualRepetitions: 5,
            actualLoadKilograms: 0,
            isCompleted: true,
            completedAt: start.addingTimeInterval(100),
            now: now
        )
        let loaded = try TrainingSetLog(
            kind: .working,
            actualRepetitions: 10,
            actualLoadKilograms: 20,
            isCompleted: true,
            completedAt: start.addingTimeInterval(200),
            now: now
        )
        let exercise = try TrainingExerciseLog(
            templateExerciseID: "bench",
            name: "Bench press",
            loadConvention: .externalTotal,
            sets: [zero, loaded]
        )
        let session = try TrainingSession(
            id: id(1),
            title: "Push",
            createdAt: start.addingTimeInterval(-60),
            updatedAt: start.addingTimeInterval(600),
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            status: .completed,
            exercises: [exercise],
            now: now
        )
        let stats = TrainingHistoryProjection(localSnapshot: makeStoreSnapshot([session]), now: now).statistics

        XCTAssertEqual(stats.completedSessionCount, 1)
        XCTAssertEqual(stats.completedSetCount, 2)
        XCTAssertEqual(stats.knownExternalVolumeKilograms, 200)
        XCTAssertEqual(stats.volumeCoverage, .complete)
        XCTAssertEqual(stats.incompleteVolumeSetCount, 0)
        let pr = try XCTUnwrap(stats.personalRecords.first)
        XCTAssertEqual(pr.exerciseIdentityKey, "template:bench")
        XCTAssertEqual(pr.maximumExternalLoadKilograms, 20)
        XCTAssertEqual(pr.bestWorkingSetVolumeKilograms, 200)
        XCTAssertFalse(stats.durationOverflowed)
    }

    func testLocalStatisticsExposePartialVolumeForMixedKnownAndMissingLoads() throws {
        let start = now.addingTimeInterval(-5_000)
        let known = try TrainingSetLog(
            kind: .working,
            actualRepetitions: 10,
            actualLoadKilograms: 20,
            isCompleted: true,
            completedAt: start.addingTimeInterval(100),
            now: now
        )
        let missing = try TrainingSetLog(
            kind: .working,
            actualRepetitions: 8,
            actualLoadKilograms: nil,
            isCompleted: true,
            completedAt: start.addingTimeInterval(200),
            now: now
        )
        let exercise = try TrainingExerciseLog(
            templateExerciseID: "bench",
            name: "Bench press",
            loadConvention: .externalTotal,
            sets: [known, missing]
        )
        let session = try TrainingSession(
            id: id(2),
            title: "Push",
            createdAt: start.addingTimeInterval(-60),
            updatedAt: start.addingTimeInterval(600),
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            status: .completed,
            exercises: [exercise],
            now: now
        )

        let statistics = TrainingHistoryProjection(
            localSnapshot: makeStoreSnapshot([session]),
            now: now
        ).statistics
        let summary = fitnessTrainingOverviewVolumeSummary(statistics)

        XCTAssertEqual(statistics.knownExternalVolumeKilograms, 200)
        XCTAssertEqual(statistics.volumeCoverage, .partial)
        XCTAssertEqual(statistics.incompleteVolumeSetCount, 1)
        XCTAssertTrue(summary.value.hasPrefix("≥ "))
        XCTAssertTrue(summary.value.contains("200"))
        XCTAssertEqual(summary.label, "External volume · partial")
        XCTAssertEqual(summary.detail, "1 completed set is missing a qualified external load.")

        let completionSummary = fitnessTrainingCompletionVolumeSummary(session)
        XCTAssertEqual(completionSummary.value, "≥ 200 kg")
        XCTAssertEqual(completionSummary.label, "External volume · partial")
        XCTAssertTrue(completionSummary.detail.contains("lower bound"))
    }

    // MARK: Fixtures

    private func id(_ number: Int) -> TrainingRecordID {
        TrainingRecordID(uuid: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!)
    }

    private func makeInput(
        start: Date,
        duration: Double,
        activityTypeRawValue: Int = 20,
        energy: Double? = 100,
        healthState: TrainingImportedHealthState = .observed,
        uuid: UUID = UUID()
    ) -> TrainingImportedWorkoutInput {
        let identity = try! TrainingImportedWorkoutIdentity(
            uuid: uuid,
            syncIdentifier: "source-\(uuid.uuidString.lowercased())",
            revision: .syncVersion(1)
        )
        return TrainingImportedWorkoutInput(
            identity: identity,
            activityTypeRawValue: activityTypeRawValue,
            startedAt: start,
            endedAt: start.addingTimeInterval(duration),
            durationSeconds: duration,
            activeEnergyKilocalories: energy,
            healthState: healthState
        )
    }

    private func makeImportedSnapshot(
        _ inputs: [TrainingImportedWorkoutInput],
        queryState: TrainingSourceState
    ) throws -> TrainingImportedHistorySnapshot {
        try makeImportedSnapshotResult(inputs, queryState: queryState).snapshot
    }

    private func makeImportedSnapshotResult(
        _ inputs: [TrainingImportedWorkoutInput],
        queryState: TrainingSourceState
    ) throws -> TrainingImportedProjectionResult {
        let coverage: TrainingCoverage
        switch queryState {
        case .imported:
            coverage = try TrainingCoverage(
                kind: .complete,
                lowerBound: now.addingTimeInterval(-86_400),
                upperBound: now,
                now: now
            )
        case .partial, .stale, .conflict:
            coverage = try TrainingCoverage(
                kind: .partial,
                lowerBound: now.addingTimeInterval(-86_400),
                upperBound: now,
                now: now
            )
        case .unavailable, .readIndeterminate, .error:
            coverage = try TrainingCoverage(kind: .unavailable, now: now)
        case .local, .mixed:
            XCTFail("Fixture cannot build an imported snapshot from \(queryState)")
            coverage = try TrainingCoverage(kind: .unavailable, now: now)
        }
        return try TrainingHistoryProjection.makeImportedSnapshot(
            from: inputs,
            queryState: queryState,
            queryCoverage: coverage,
            now: now
        )
    }

    private func makeLocalSession(
        id: TrainingRecordID = TrainingRecordID(uuid: UUID()),
        start: Date,
        duration: TimeInterval,
        activityKind: TrainingActivityKind = .strength,
        importedRecordKey: String? = nil,
        validationNow: Date? = nil
    ) throws -> TrainingSession {
        let end = start.addingTimeInterval(duration)
        let set = try TrainingSetLog(
            actualRepetitions: 5,
            actualLoadKilograms: 10,
            isCompleted: true,
            completedAt: start.addingTimeInterval(min(60, duration / 2)),
            now: validationNow ?? now
        )
        let exercise = try TrainingExerciseLog(name: "Exercise", sets: [set])
        return try TrainingSession(
            id: id,
            activityKind: activityKind,
            title: "Session",
            createdAt: start.addingTimeInterval(-60),
            updatedAt: end,
            startedAt: start,
            endedAt: end,
            status: .completed,
            exercises: [exercise],
            importedRecordKey: importedRecordKey,
            now: validationNow ?? now
        )
    }

    private func makeStoreSnapshot(
        _ sessions: [TrainingSession],
        capturedAt: Date? = nil
    ) -> TrainingStoreSnapshot {
        TrainingStoreSnapshot(
            sessions: sessions,
            generation: "test-generation",
            integrity: .verified,
            freshness: .current,
            capturedAt: capturedAt ?? now
        )
    }
}
