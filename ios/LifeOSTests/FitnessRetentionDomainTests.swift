import XCTest
@testable import LifeOS

final class FitnessRetentionDomainTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func ago(_ days: Int, from date: Date) -> Date {
        date.addingTimeInterval(-Double(days) * day)
    }

    private func storage(totalBytes: Int, measuredAt: Date) throws -> FitnessStorageBreakdown {
        try FitnessStorageBreakdown(
            measuredAt: measuredAt,
            revision: 2,
            measurements: [
                try FitnessStorageMeasurement(
                    id: "measurement-originals",
                    storageClass: .originals,
                    bytes: totalBytes - 1,
                    measuredAt: measuredAt,
                    revision: 2
                ),
                try FitnessStorageMeasurement(
                    id: "measurement-history",
                    storageClass: .detailedHistory,
                    bytes: 1,
                    measuredAt: measuredAt,
                    revision: 2
                ),
            ],
            totalBytes: totalBytes
        )
    }

    private func snapshot(
        observedAt: Date? = nil,
        totalBytes: Int = 30_000_000,
        allowOriginalCompaction: Bool = true,
        allowDetailedHistoryCompaction: Bool = true
    ) throws -> FitnessRetentionSnapshot {
        let asOf = observedAt ?? Date(timeIntervalSinceNow: -60)
        let records = try [
            FitnessPreservedRecord(
                id: "meal-1", kind: .confirmedMeal, revision: 2,
                updatedAt: asOf, auditRecordID: "audit-record-meal-1"
            ),
            FitnessPreservedRecord(
                id: "correction-1", kind: .correctionLineage, revision: 2,
                updatedAt: asOf, auditRecordID: "audit-record-correction-1"
            ),
            FitnessPreservedRecord(
                id: "provenance-1", kind: .inferenceProvenance, revision: 2,
                updatedAt: asOf, auditRecordID: "audit-record-provenance-1"
            ),
        ]
        let assets = try [
            FitnessRetentionAsset(
                id: "photo-old", kind: .originalPhoto, storageClass: .originals,
                bytes: 2_000_000, observedAt: ago(100, from: asOf), revision: 2,
                updatedAt: asOf, pinned: false, exported: false,
                structuredRecordID: "meal-1", correctionLineageID: "correction-1",
                provenanceID: "provenance-1", auditRecordID: "audit-asset-photo-old"
            ),
            FitnessRetentionAsset(
                id: "photo-pinned", kind: .originalPhoto, storageClass: .originals,
                bytes: 4_000_000, observedAt: ago(200, from: asOf), revision: 2,
                updatedAt: asOf, pinned: true, exported: false,
                structuredRecordID: "meal-1", correctionLineageID: "correction-1",
                provenanceID: "provenance-1", auditRecordID: "audit-asset-photo-pinned"
            ),
            FitnessRetentionAsset(
                id: "photo-new", kind: .originalPhoto, storageClass: .originals,
                bytes: 1_000_000, observedAt: ago(10, from: asOf), revision: 2,
                updatedAt: asOf, pinned: false, exported: false,
                structuredRecordID: "meal-1", correctionLineageID: "correction-1",
                provenanceID: "provenance-1", auditRecordID: "audit-asset-photo-new"
            ),
            FitnessRetentionAsset(
                id: "history-old", kind: .detailedHistory, storageClass: .detailedHistory,
                bytes: 3_000_000, observedAt: ago(400, from: asOf), revision: 2,
                updatedAt: asOf, pinned: false, exported: false,
                dailyRollupID: "rollup-day-1", weeklyRollupID: "rollup-week-1",
                auditRecordID: "audit-asset-history-old"
            ),
        ]
        let rollups = try [
            FitnessRollup(
                id: "rollup-day-1", granularity: .daily,
                periodStart: ago(401, from: asOf), periodEnd: ago(400, from: asOf),
                sourceAssetIDs: ["history-old"], min: 1, max: 10, mean: 5,
                sampleCount: 10, sourceCoverage: .complete, quality: .observed,
                pinnedRawIntervalIDs: [], auditRecordID: "audit-rollup-day-1",
                revision: 2, updatedAt: asOf
            ),
            FitnessRollup(
                id: "rollup-week-1", granularity: .weekly,
                periodStart: ago(407, from: asOf), periodEnd: ago(400, from: asOf),
                sourceAssetIDs: ["history-old"], min: 1, max: 10, mean: 5,
                sampleCount: 10, sourceCoverage: .complete, quality: .observed,
                pinnedRawIntervalIDs: [], auditRecordID: "audit-rollup-week-1",
                revision: 2, updatedAt: asOf
            ),
        ]
        let auditRecords = try [
            FitnessAuditRecord(id: "audit-record-meal-1", entityKind: .record,
                               entityID: "meal-1", state: .preserved, revision: 2, recordedAt: asOf),
            FitnessAuditRecord(id: "audit-record-correction-1", entityKind: .record,
                               entityID: "correction-1", state: .preserved, revision: 2, recordedAt: asOf),
            FitnessAuditRecord(id: "audit-record-provenance-1", entityKind: .record,
                               entityID: "provenance-1", state: .preserved, revision: 2, recordedAt: asOf),
            FitnessAuditRecord(id: "audit-asset-photo-old", entityKind: .asset,
                               entityID: "photo-old", state: .active, revision: 2, recordedAt: asOf),
            FitnessAuditRecord(id: "audit-asset-photo-pinned", entityKind: .asset,
                               entityID: "photo-pinned", state: .active, revision: 2, recordedAt: asOf),
            FitnessAuditRecord(id: "audit-asset-photo-new", entityKind: .asset,
                               entityID: "photo-new", state: .active, revision: 2, recordedAt: asOf),
            FitnessAuditRecord(id: "audit-asset-history-old", entityKind: .asset,
                               entityID: "history-old", state: .active, revision: 2, recordedAt: asOf),
            FitnessAuditRecord(id: "audit-rollup-day-1", entityKind: .rollup,
                               entityID: "rollup-day-1", state: .preserved, revision: 2, recordedAt: asOf),
            FitnessAuditRecord(id: "audit-rollup-week-1", entityKind: .rollup,
                               entityID: "rollup-week-1", state: .preserved, revision: 2, recordedAt: asOf),
        ]
        return try FitnessRetentionSnapshot(
            revision: 2,
            observedAt: asOf,
            storage: try storage(totalBytes: totalBytes, measuredAt: asOf),
            retentionPolicy: FitnessRetentionPolicy(
                allowOriginalCompaction: allowOriginalCompaction,
                allowDetailedHistoryCompaction: allowDetailedHistoryCompaction
            ),
            assets: assets,
            records: records,
            rollups: rollups,
            auditRecords: auditRecords
        )
    }

    private func request(
        observedAt: Date? = nil,
        totalBytes: Int = 30_000_000,
        requestedPhotoBytes: Int? = nil,
        allowOriginalCompaction: Bool = true,
        allowDetailedHistoryCompaction: Bool = true
    ) throws -> FitnessCompactionRequest {
        try FitnessCompactionRequest(
            snapshot: snapshot(
                observedAt: observedAt,
                totalBytes: totalBytes,
                allowOriginalCompaction: allowOriginalCompaction,
                allowDetailedHistoryCompaction: allowDetailedHistoryCompaction
            ),
            planID: "plan-1",
            requestedPhotoBytes: requestedPhotoBytes
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func decodeSnapshot(_ object: [String: Any], now: Date) throws -> FitnessRetentionSnapshot {
        try FitnessRetentionSnapshot.decode(try data(object), now: now)
    }

    func testAcceptsStrictLinkedSnapshotAndReportsExactTotals() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        let value = try snapshot(observedAt: asOf)

        XCTAssertEqual(value.storage.measurements[0].storageClass, .originals)
        XCTAssertEqual(value.storage.totalBytes, 30_000_000)
        XCTAssertEqual(value.assets.count, 4)
        XCTAssertNoThrow(try value.validate(now: asOf))
    }

    func testPlansNinetyAndThreeHundredSixtyFiveDayEligibilityWhileKeepingProtectedAndRecentAssets() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        let plan = try planFitnessCompaction(try request(observedAt: asOf), now: asOf)

        XCTAssertEqual(plan.storagePressure, .normal)
        XCTAssertEqual(plan.ingestionMode, .persistentPhotoAllowed)
        XCTAssertEqual(plan.operations.map(\.sourceAssetID), ["photo-old", "history-old"])
        XCTAssertEqual(plan.operations.map(\.eligibility), [.originalOlderThan90Days, .historyOlderThan365Days])
        XCTAssertEqual(plan.estimatedReclaimableBytes, 4_488_000)
        XCTAssertEqual(plan.protectedBytes, 4_000_000)
        XCTAssertEqual(plan.execution, "plan_only_no_deletion")
        XCTAssertEqual(plan.operations[0].sourceDisposition, "retain_until_commit")
        XCTAssertEqual(plan.operations[0].sourceRemoval.action, "remove_source_after_validated_commit")
        XCTAssertTrue(plan.operations.allSatisfy {
            $0.transactionSteps == [.writeReplacement, .validateReplacement,
                                    .verifyExportAndProvenance, .removeSourceAfterCommit]
        })
        XCTAssertEqual(plan.preserve.structuredRecordIDs, ["meal-1"])
        XCTAssertEqual(plan.preserve.dailyRollupIDs, ["rollup-day-1"])
        XCTAssertEqual(plan.preserve.weeklyRollupIDs, ["rollup-week-1"])
    }

    func testThresholdsIncludeProjectedPhotoBytes() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        func plan(totalBytes: Int, requestedPhotoBytes: Int? = nil) throws -> FitnessCompactionPlan {
            try planFitnessCompaction(
                try request(observedAt: asOf, totalBytes: totalBytes,
                            requestedPhotoBytes: requestedPhotoBytes), now: asOf
            )
        }

        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.warningBytes).storagePressure, .warning)
        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.warningBytes).ingestionMode, .persistentPhotoAllowed)
        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.aggressiveCompactionBytes).storagePressure, .aggressiveCompaction)
        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.aggressiveCompactionBytes).ingestionMode, .structuredOnlyTransientPhoto)
        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.hardCapBytes).storagePressure, .hardIngestionGate)
        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.hardCapBytes).ingestionMode, .manualOnlyNoPhotoRetention)
        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.aggressiveCompactionBytes - 1,
                                requestedPhotoBytes: 1).storagePressure, .aggressiveCompaction)
        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.hardCapBytes - 1,
                                requestedPhotoBytes: 1).storagePressure, .hardIngestionGate)
        XCTAssertEqual(try plan(totalBytes: FitnessStorageLimits.hardCapBytes - 1,
                                requestedPhotoBytes: 1).projectedTotalBytes,
                       FitnessStorageLimits.hardCapBytes)
    }

    func testUserPolicyCanDisallowEachCompactionClass() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        let originalsDisallowed = try planFitnessCompaction(
            try request(observedAt: asOf, allowOriginalCompaction: false), now: asOf
        )
        XCTAssertEqual(originalsDisallowed.operations.map(\.sourceAssetID), ["history-old"])

        let historyDisallowed = try planFitnessCompaction(
            try request(observedAt: asOf, allowDetailedHistoryCompaction: false), now: asOf
        )
        XCTAssertEqual(historyDisallowed.operations.map(\.sourceAssetID), ["photo-old"])
    }

    func testRejectsStrictUnknownFieldsDuplicatesDanglingLinksAndContradictoryRollups() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        let value = try snapshot(observedAt: asOf)

        var unknown = try jsonObject(value.storage.measurements[0])
        unknown["unexpected"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(
            FitnessStorageMeasurement.self, from: try data(unknown)
        ))

        var duplicateMeasurement = try jsonObject(value)
        var storageObject = try XCTUnwrap(duplicateMeasurement["storage"] as? [String: Any])
        let measurement = try XCTUnwrap((storageObject["measurements"] as? [[String: Any]])?.first)
        storageObject["measurements"] = [measurement, measurement]
        storageObject["totalBytes"] = (measurement["bytes"] as? Int ?? 0) * 2
        duplicateMeasurement["storage"] = storageObject
        XCTAssertThrowsError(try decodeSnapshot(duplicateMeasurement, now: asOf))

        var duplicateAsset = try jsonObject(value)
        var duplicateAssets = try XCTUnwrap(duplicateAsset["assets"] as? [[String: Any]])
        duplicateAssets.insert(try XCTUnwrap(duplicateAssets.first), at: 1)
        duplicateAsset["assets"] = duplicateAssets
        XCTAssertThrowsError(try decodeSnapshot(duplicateAsset, now: asOf))

        var danglingRollup = try jsonObject(value)
        var danglingAssets = try XCTUnwrap(danglingRollup["assets"] as? [[String: Any]])
        danglingAssets[3]["dailyRollupID"] = "missing-rollup"
        danglingRollup["assets"] = danglingAssets
        XCTAssertThrowsError(try decodeSnapshot(danglingRollup, now: asOf))

        var wrongRollupSource = try jsonObject(value)
        var wrongRollups = try XCTUnwrap(wrongRollupSource["rollups"] as? [[String: Any]])
        wrongRollups[0]["sourceAssetIDs"] = ["photo-old"]
        wrongRollupSource["rollups"] = wrongRollups
        XCTAssertThrowsError(try decodeSnapshot(wrongRollupSource, now: asOf))

        var unavailableComplete = try jsonObject(value)
        var unavailableRollups = try XCTUnwrap(unavailableComplete["rollups"] as? [[String: Any]])
        unavailableRollups[0]["quality"] = "unavailable"
        unavailableComplete["rollups"] = unavailableRollups
        XCTAssertThrowsError(try decodeSnapshot(unavailableComplete, now: asOf))
    }

    func testRejectsFutureTimestampsAndUnsafeBoundsIncludingTheOneTiBDiagnosticLimit() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        let value = try snapshot(observedAt: asOf)
        let later = iso8601(Date(timeIntervalSinceNow: 60))

        var futureSnapshot = try jsonObject(value)
        futureSnapshot["observedAt"] = later
        XCTAssertThrowsError(try decodeSnapshot(futureSnapshot, now: Date()))

        var futureMeasurement = try jsonObject(value)
        var futureStorage = try XCTUnwrap(futureMeasurement["storage"] as? [String: Any])
        var measurements = try XCTUnwrap(futureStorage["measurements"] as? [[String: Any]])
        measurements[0]["measuredAt"] = later
        futureStorage["measurements"] = measurements
        futureMeasurement["storage"] = futureStorage
        XCTAssertThrowsError(try decodeSnapshot(futureMeasurement, now: Date()))

        XCTAssertEqual(FitnessRetentionConstants.maximumStorageBytes,
                       1_024 * 1_024 * 1_024 * 1_024)
        var tooLargeMeasurement = try jsonObject(value.storage.measurements[0])
        tooLargeMeasurement["bytes"] = FitnessRetentionConstants.maximumStorageBytes + 1
        XCTAssertThrowsError(try JSONDecoder().decode(
            FitnessStorageMeasurement.self, from: try data(tooLargeMeasurement)
        ))

        var unsafeRevision = try jsonObject(value)
        unsafeRevision["revision"] = FitnessRetentionConstants.maximumRevision + 1
        XCTAssertThrowsError(try decodeSnapshot(unsafeRevision, now: asOf))

        var unsafeRequest = try jsonObject(try request(observedAt: asOf))
        unsafeRequest["requestedPhotoBytes"] = 20 * 1_024 * 1_024 + 1
        XCTAssertThrowsError(try FitnessCompactionRequest.decode(try data(unsafeRequest), now: asOf))
    }

    func testAllowsHistoricalAuditAndTombstoneRecordsButRejectsTombstonesForPresentEntities() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        let value = try snapshot(observedAt: asOf)
        var object = try jsonObject(value)
        var audits = try XCTUnwrap(object["auditRecords"] as? [[String: Any]])
        audits.append([
            "id": "audit-asset-photo-old-history", "entityKind": "asset",
            "entityID": "photo-old", "state": "preserved", "revision": 1,
            "recordedAt": iso8601(ago(99, from: asOf)),
        ])
        audits.append([
            "id": "audit-asset-removed", "entityKind": "asset",
            "entityID": "photo-removed", "state": "deleted_tombstone", "revision": 3,
            "recordedAt": iso8601(ago(1, from: asOf)),
        ])
        object["auditRecords"] = audits
        XCTAssertEqual(try decodeSnapshot(object, now: asOf).auditRecords.count, value.auditRecords.count + 2)

        var presentTombstone = try jsonObject(value)
        var presentAudits = try XCTUnwrap(presentTombstone["auditRecords"] as? [[String: Any]])
        presentAudits[3]["state"] = "deleted_tombstone"
        presentTombstone["auditRecords"] = presentAudits
        XCTAssertThrowsError(try decodeSnapshot(presentTombstone, now: asOf))
    }

    func testRejectsNestedTimestampsThatPostdateTheSnapshot() throws {
        let snapshotTime = Date(timeIntervalSinceNow: -120)
        let nestedTime = Date(timeIntervalSinceNow: -60)
        let value = try snapshot(observedAt: snapshotTime)

        var storageChronology = try jsonObject(value)
        var storageObject = try XCTUnwrap(storageChronology["storage"] as? [String: Any])
        storageObject["measuredAt"] = iso8601(nestedTime)
        storageChronology["storage"] = storageObject
        XCTAssertThrowsError(try decodeSnapshot(storageChronology, now: Date()))

        var assetChronology = try jsonObject(value)
        var assets = try XCTUnwrap(assetChronology["assets"] as? [[String: Any]])
        assets[0]["observedAt"] = iso8601(nestedTime)
        assetChronology["assets"] = assets
        XCTAssertThrowsError(try decodeSnapshot(assetChronology, now: Date()))
    }

    func testTransactionStateMachineRequiresBeginValidateCommitAndKeepsNoDeletionSemantics() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        let plan = try planFitnessCompaction(try request(observedAt: asOf), now: asOf)
        let staging = try advanceFitnessCompactionPlan(
            plan,
            try FitnessCompactionTransition(
                transitionID: "transition-begin", planID: plan.planID,
                expectedRevision: plan.revision, event: .begin, occurredAt: asOf
            ),
            now: asOf
        )
        XCTAssertEqual(staging.status, .staging)

        let operationIDs = staging.operations.map(\.operationID)
        let validated = try advanceFitnessCompactionPlan(
            staging,
            try FitnessCompactionTransition(
                transitionID: "transition-validate", planID: plan.planID,
                expectedRevision: staging.revision, event: .validate, occurredAt: asOf,
                validatedOperationIDs: operationIDs,
                exportVerifiedOperationIDs: operationIDs
            ),
            now: asOf
        )
        XCTAssertEqual(validated.status, .validated)

        let committed = try advanceFitnessCompactionPlan(
            validated,
            try FitnessCompactionTransition(
                transitionID: "transition-commit", planID: plan.planID,
                expectedRevision: validated.revision, event: .commit, occurredAt: asOf
            ),
            now: asOf
        )
        XCTAssertEqual(committed.status, .committed)
        XCTAssertEqual(committed.execution, "plan_only_no_deletion")
        XCTAssertTrue(committed.operations.allSatisfy {
            $0.sourceDisposition == "retain_until_commit"
        })
    }

    func testFailedTransactionCanRetryAndRejectsStaleDirectAndOutOfOrderTransitions() throws {
        let asOf = Date(timeIntervalSinceNow: -60)
        let plan = try planFitnessCompaction(try request(observedAt: asOf), now: asOf)
        let staging = try advanceFitnessCompactionPlan(
            plan,
            try FitnessCompactionTransition(
                transitionID: "transition-begin", planID: plan.planID,
                expectedRevision: plan.revision, event: .begin, occurredAt: asOf
            ),
            now: asOf
        )
        let failed = try advanceFitnessCompactionPlan(
            staging,
            try FitnessCompactionTransition(
                transitionID: "transition-fail", planID: plan.planID,
                expectedRevision: staging.revision, event: .fail, occurredAt: asOf,
                failureReason: "thumbnail validation failed"
            ),
            now: asOf
        )
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.operations.allSatisfy {
            $0.sourceDisposition == "retain_until_commit"
        })

        let retry = try advanceFitnessCompactionPlan(
            failed,
            try FitnessCompactionTransition(
                transitionID: "transition-retry", planID: plan.planID,
                expectedRevision: failed.revision, event: .retry, occurredAt: asOf
            ),
            now: asOf
        )
        XCTAssertEqual(retry.status, .staging)

        XCTAssertThrowsError(try advanceFitnessCompactionPlan(
            plan,
            try FitnessCompactionTransition(
                transitionID: "stale", planID: plan.planID,
                expectedRevision: plan.revision - 1, event: .begin, occurredAt: asOf
            ),
            now: asOf
        ))
        XCTAssertThrowsError(try advanceFitnessCompactionPlan(
            plan,
            try FitnessCompactionTransition(
                transitionID: "direct-commit", planID: plan.planID,
                expectedRevision: plan.revision, event: .commit, occurredAt: asOf
            ),
            now: asOf
        ))
        XCTAssertThrowsError(try FitnessCompactionTransition(
            transitionID: "bad-transition", planID: plan.planID,
            expectedRevision: plan.revision, event: .begin, occurredAt: asOf,
            failureReason: "contradictory"
        ))
        XCTAssertThrowsError(try FitnessCompactionPlan(
            schemaVersion: plan.schemaVersion, planID: plan.planID,
            baseRevision: plan.baseRevision, revision: plan.revision,
            createdAt: plan.createdAt, updatedAt: plan.updatedAt, asOf: plan.asOf,
            storagePressure: plan.storagePressure, ingestionMode: plan.ingestionMode,
            requestedPhotoBytes: plan.requestedPhotoBytes,
            measuredTotalBytes: plan.measuredTotalBytes,
            projectedTotalBytes: plan.projectedTotalBytes,
            operations: plan.operations,
            estimatedReclaimableBytes: plan.estimatedReclaimableBytes,
            protectedBytes: plan.protectedBytes, preserve: plan.preserve,
            execution: plan.execution, status: .committed,
            committedAt: asOf
        ))
        XCTAssertThrowsError(try advanceFitnessCompactionPlan(
            staging,
            try FitnessCompactionTransition(
                transitionID: "too-early", planID: plan.planID,
                expectedRevision: staging.revision, event: .fail,
                occurredAt: staging.updatedAt.addingTimeInterval(-1),
                failureReason: "out of order"
            ),
            now: asOf
        ))
    }
}
