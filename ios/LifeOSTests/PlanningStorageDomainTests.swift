import Foundation
import XCTest
@testable import LifeOS

final class PlanningStorageDomainTests: XCTestCase {
    private let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testEmptyMarkdownIsPresentAndAbsenceIsExplicit() throws {
        let markdownPath = try PlanningStoredPath("Notes/empty.md")
        let present = try PlanningDocumentSnapshot(path: markdownPath, bytes: Data())
        XCTAssertEqual(present.version, .bytes(sha256: emptyDigest, byteCount: 0))
        XCTAssertEqual(present.observation.version, present.version)

        let absent = try PlanningDocumentSnapshot(
            path: markdownPath,
            bytes: Data(),
            version: .absent
        )
        XCTAssertEqual(absent.version, .absent)

        let canvasPath = try PlanningStoredPath("Boards/empty.canvas")
        XCTAssertThrowsError(try PlanningDocumentSnapshot(path: canvasPath, bytes: Data()))
        XCTAssertNoThrow(try PlanningDocumentSnapshot(path: canvasPath, bytes: Data(), version: .absent))
    }

    func testContentVersionConstructorsAndCodableRejectInvalidValues() throws {
        XCTAssertThrowsError(try PlanningContentVersion(sha256: "bad", byteCount: 0))
        XCTAssertThrowsError(
            try PlanningContentVersion(
                sha256: String(repeating: "A", count: 64),
                byteCount: 0
            )
        )
        XCTAssertThrowsError(
            try PlanningContentVersion(
                sha256: emptyDigest,
                byteCount: -1
            )
        )

        let decoder = JSONDecoder()
        let invalidJSON: [String] = [
            #"{"kind":"bytes","sha256":"bad","byteCount":0}"#,
            #"{"kind":"bytes","sha256":""# + emptyDigest + #"","byteCount":-1}"#,
            #"{"kind":"absent","sha256":""# + emptyDigest + #""}"#,
            #"{"kind":"bytes","sha256":""# + emptyDigest + #"" ,"byteCount":0,"unexpected":true}"#
        ]
        for payload in invalidJSON {
            XCTAssertThrowsError(
                try decoder.decode(PlanningContentVersion.self, from: Data(payload.utf8)),
                payload
            )
        }

        let identityJSON = #"{"device":1,"inode":2,"fileType":1,"unexpected":true}"#
        XCTAssertThrowsError(
            try decoder.decode(PlanningFileIdentity.self, from: Data(identityJSON.utf8))
        )
    }

    func testOptionalCodableFieldsRoundTripAtMinimumAndMaximumPresence() throws {
        let vaultID = UUID()
        let deviceID = UUID()
        let generation = UUID()
        let identity = try PlanningFileIdentity(device: 1, inode: 2, fileType: 1)
        let emptyVersion = try PlanningContentVersion(sha256: emptyDigest, byteCount: 0)
        let path = try PlanningStoredPath("Notes/empty.md")
        let createRequest = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        let deleteRequest = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: vaultID,
            path: path,
            operation: .delete,
            expectedVersion: emptyVersion,
            proposedBytes: nil
        )
        let fullGrant = try PlanningDeviceVaultGrant(
            deviceID: deviceID,
            vaultID: vaultID,
            bookmarkData: Data([1, 2]),
            selectionGeneration: generation,
            lastValidatedRootIdentity: identity
        )
        let minimalGrant = try PlanningDeviceVaultGrant(
            deviceID: deviceID,
            vaultID: vaultID,
            bookmarkData: Data(),
            selectionGeneration: generation
        )
        let fullObservation = try PlanningFileObservation(
            path: path,
            version: emptyVersion,
            identity: identity,
            byteCount: 0,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        let minimalObservation = try PlanningFileObservation(
            path: path,
            version: emptyVersion,
            identity: nil,
            byteCount: 0,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        let fullReceipt = try PlanningMutationReceipt(
            mutationID: createRequest.mutationID,
            fingerprint: createRequest.fingerprint,
            state: .published,
            resultVersion: emptyVersion,
            errorCode: "ok",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let minimalReceipt = try PlanningMutationReceipt(
            mutationID: deleteRequest.mutationID,
            fingerprint: deleteRequest.fingerprint,
            state: .staged,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let fullConflict = try PlanningConflict(
            mutationID: createRequest.mutationID,
            vaultID: vaultID,
            path: path,
            operation: .create,
            reason: "observed",
            baseVersion: .absent,
            localBytes: Data(),
            observedVersion: emptyVersion,
            observedBytes: Data()
        )
        let minimalConflict = try PlanningConflict(
            mutationID: deleteRequest.mutationID,
            vaultID: vaultID,
            path: path,
            operation: .delete,
            reason: "observed",
            baseVersion: emptyVersion,
            localBytes: nil,
            observedVersion: .absent,
            observedBytes: nil
        )
        let fullStatus = try PlanningStoreStatus(
            accessState: .ready,
            pendingMutationCount: 1,
            openConflictCount: 2,
            retainedPayloadBytes: 3,
            databaseBytes: 4,
            lastErrorCode: "temporary"
        )
        let minimalStatus = try PlanningStoreStatus(
            accessState: .unselected,
            pendingMutationCount: 0,
            openConflictCount: 0,
            retainedPayloadBytes: 0,
            databaseBytes: 0
        )

        XCTAssertEqual(try roundTrip(fullGrant), fullGrant)
        XCTAssertEqual(try roundTrip(minimalGrant), minimalGrant)
        XCTAssertEqual(try roundTrip(fullObservation), fullObservation)
        XCTAssertEqual(try roundTrip(minimalObservation), minimalObservation)
        XCTAssertEqual(try roundTrip(createRequest), createRequest)
        XCTAssertEqual(try roundTrip(deleteRequest), deleteRequest)
        XCTAssertEqual(try roundTrip(fullReceipt), fullReceipt)
        XCTAssertEqual(try roundTrip(minimalReceipt), minimalReceipt)
        XCTAssertEqual(try roundTrip(fullConflict), fullConflict)
        XCTAssertEqual(try roundTrip(minimalConflict), minimalConflict)
        XCTAssertEqual(try roundTrip(fullStatus), fullStatus)
        XCTAssertEqual(try roundTrip(minimalStatus), minimalStatus)
    }

    func testContentVersionValidationRunsAtConsumerBoundaries() throws {
        let markdownPath = try PlanningStoredPath("Notes/empty.md")
        let canvasPath = try PlanningStoredPath("Boards/empty.canvas")
        let malformed = PlanningContentVersion.bytes(sha256: "bad", byteCount: -1)
        let oversizedMarkdown = PlanningContentVersion.bytes(
            sha256: emptyDigest,
            byteCount: PlanningStorageLimits.markdownBytes + 1
        )
        let oversizedCanvas = PlanningContentVersion.bytes(
            sha256: emptyDigest,
            byteCount: PlanningStorageLimits.canvasBytes + 1
        )

        XCTAssertThrowsError(
            try PlanningFileObservation(
                path: markdownPath,
                version: malformed,
                identity: nil,
                byteCount: 0
            )
        )
        XCTAssertThrowsError(
            try PlanningDocumentSnapshot(path: markdownPath, bytes: Data(), version: malformed)
        )
        XCTAssertThrowsError(
            try PlanningMutationRequest(
                vaultID: UUID(),
                path: markdownPath,
                operation: .delete,
                expectedVersion: malformed,
                proposedBytes: nil
            )
        )
        XCTAssertThrowsError(
            try PlanningMutationRequest(
                vaultID: UUID(),
                path: markdownPath,
                operation: .replace,
                expectedVersion: oversizedMarkdown,
                proposedBytes: Data()
            )
        )
        XCTAssertThrowsError(
            try PlanningDocumentSnapshot(path: canvasPath, bytes: Data(), version: oversizedCanvas)
        )

        let oversizedBytes = Data(repeating: 0x20, count: PlanningStorageLimits.markdownBytes + 1)
        XCTAssertThrowsError(
            try PlanningConflict(
                mutationID: UUID(),
                vaultID: UUID(),
                path: markdownPath,
                operation: .create,
                reason: "oversized",
                baseVersion: .absent,
                localBytes: oversizedBytes,
                observedVersion: .absent,
                observedBytes: nil
            )
        )
        let validConflict = try PlanningConflict(
            mutationID: UUID(),
            vaultID: UUID(),
            path: markdownPath,
            operation: .create,
            reason: "evidence",
            baseVersion: .absent,
            localBytes: Data(),
            observedVersion: .absent,
            observedBytes: nil
        )
        XCTAssertThrowsError(
            try PlanningConflictEvidence(
                validating: validConflict,
                attemptedPublication: false,
                displacedVersion: malformed
            )
        )
        XCTAssertThrowsError(try JSONEncoder().encode(malformed))
    }

    func testPersistedDecodersRevalidateInitializers() throws {
        let decoder = JSONDecoder()
        let observation = """
        {
          "path":"Notes/a.md",
          "version":{"kind":"absent"},
          "byteCount":1,
          "observedAt":0
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(PlanningFileObservation.self, from: Data(observation.utf8))
        )

        let receipt = """
        {
          "mutationID":"00000000-0000-0000-0000-000000000001",
          "fingerprint":"bad",
          "state":"staged",
          "updatedAt":0
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(PlanningMutationReceipt.self, from: Data(receipt.utf8))
        )

        let status = """
        {
          "accessState":"ready",
          "pendingMutationCount":-1,
          "openConflictCount":0,
          "retainedPayloadBytes":0,
          "databaseBytes":0
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(PlanningStoreStatus.self, from: Data(status.utf8))
        )

        let path = try PlanningStoredPath("Notes/a.md")
        let request = try PlanningMutationRequest(
            vaultID: UUID(),
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        let encoded = try JSONEncoder().encode(request)
        var requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        requestObject["unexpected"] = true
        let requestWithUnknownKey = try JSONSerialization.data(withJSONObject: requestObject)
        XCTAssertEqual(
            try decoder.decode(PlanningMutationRequest.self, from: requestWithUnknownKey),
            request
        )
    }

    func testOptionalKeyDecoderAcceptsAdditiveFieldsAndRequiresKnownTypedFields() throws {
        let mutationID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000101")
        )
        let vaultID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000102")
        )
        let requiredFields: [String: Any] = [
            "mutationID": mutationID.uuidString,
            "vaultID": vaultID.uuidString,
            "path": "Notes/empty.md",
            "operation": "delete",
            "expectedVersion": [
                "kind": "bytes",
                "sha256": emptyDigest,
                "byteCount": 0
            ]
        ]
        let decoder = JSONDecoder()
        let requiredOnlyData = try JSONSerialization.data(withJSONObject: requiredFields)
        let requiredOnly = try decoder.decode(
            PlanningMutationRequest.self,
            from: requiredOnlyData
        )
        XCTAssertEqual(requiredOnly.mutationID, mutationID)
        XCTAssertEqual(requiredOnly.vaultID, vaultID)
        XCTAssertEqual(requiredOnly.operation, .delete)
        XCTAssertNil(requiredOnly.proposedBytes)

        var additiveFields = requiredFields
        additiveFields["futureField"] = ["enabled": true]
        let additiveData = try JSONSerialization.data(withJSONObject: additiveFields)
        XCTAssertEqual(
            try decoder.decode(PlanningMutationRequest.self, from: additiveData),
            requiredOnly
        )

        var missingRequiredField = requiredFields
        missingRequiredField.removeValue(forKey: "expectedVersion")
        let missingData = try JSONSerialization.data(withJSONObject: missingRequiredField)
        XCTAssertThrowsError(
            try decoder.decode(PlanningMutationRequest.self, from: missingData)
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("mutationRequest.keys"))
        }

        var wrongType = requiredFields
        wrongType["operation"] = 7
        let wrongTypeData = try JSONSerialization.data(withJSONObject: wrongType)
        XCTAssertThrowsError(
            try decoder.decode(PlanningMutationRequest.self, from: wrongTypeData)
        )
    }

    func testMutationOperationVersionAndPayloadMatrix() throws {
        let markdownPath = try PlanningStoredPath("Notes/empty.md")
        let emptyVersion = PlanningContentVersion(data: Data())
        let vaultID = UUID()

        XCTAssertNoThrow(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: markdownPath,
                operation: .create,
                expectedVersion: .absent,
                proposedBytes: Data()
            )
        )
        XCTAssertNoThrow(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: markdownPath,
                operation: .replace,
                expectedVersion: emptyVersion,
                proposedBytes: Data()
            )
        )
        XCTAssertNoThrow(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: markdownPath,
                operation: .delete,
                expectedVersion: emptyVersion,
                proposedBytes: nil
            )
        )

        XCTAssertThrowsError(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: markdownPath,
                operation: .create,
                expectedVersion: emptyVersion,
                proposedBytes: Data()
            )
        )
        XCTAssertThrowsError(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: markdownPath,
                operation: .replace,
                expectedVersion: .absent,
                proposedBytes: Data()
            )
        )
        XCTAssertThrowsError(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: markdownPath,
                operation: .delete,
                expectedVersion: .absent,
                proposedBytes: nil
            )
        )
        XCTAssertThrowsError(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: markdownPath,
                operation: .delete,
                expectedVersion: emptyVersion,
                proposedBytes: Data()
            )
        )

        let oversized = Data(repeating: 0x20, count: PlanningStorageLimits.markdownBytes + 1)
        XCTAssertThrowsError(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: markdownPath,
                operation: .create,
                expectedVersion: .absent,
                proposedBytes: oversized
            )
        )

        let canvasPath = try PlanningStoredPath("Boards/board.canvas")
        let validCanvas = Data(#"{"nodes":[],"edges":[]}"#.utf8)
        XCTAssertNoThrow(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: canvasPath,
                operation: .create,
                expectedVersion: .absent,
                proposedBytes: validCanvas
            )
        )
        XCTAssertThrowsError(
            try PlanningMutationRequest(
                vaultID: vaultID,
                path: canvasPath,
                operation: .create,
                expectedVersion: .absent,
                proposedBytes: Data()
            )
        )
    }

    func testStoredPathRejectsUnsafeFormsAndExposesCanonicalCollisionKey() throws {
        let invalid = [
            "../note.md",
            "/note.md",
            "~/note.md",
            "C:/note.md",
            "C:\note.md",
            "folder\note.md",
            "folder//note.md",
            "Conflicts/note.md",
            ".lifeos-stage-abc/note.md",
            "CON.md",
            "folder/file?.md",
            "folder/name. md"
        ]
        for raw in invalid {
            XCTAssertThrowsError(try PlanningStoredPath(raw), raw)
        }

        let upper = try PlanningStoredPath("Notes/Plan.md")
        let lower = try PlanningStoredPath("notes/plan.md")
        XCTAssertEqual(upper.collisionKey, lower.collisionKey)
        XCTAssertNotEqual(upper, lower)

        let composed = try PlanningStoredPath("Notes/café.md")
        let decomposed = try PlanningStoredPath("Notes/café.md")
        XCTAssertEqual(composed.collisionKey, decomposed.collisionKey)
    }

    func testFingerprintIsStableForTheSameImmutableRequestAndDiffersByPath() throws {
        let vaultID = UUID()
        let first = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: vaultID,
            path: try PlanningStoredPath("Notes/a.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        let same = try PlanningMutationRequest(
            mutationID: first.mutationID,
            vaultID: vaultID,
            path: try PlanningStoredPath("Notes/a.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        let differentPath = try PlanningMutationRequest(
            mutationID: first.mutationID,
            vaultID: vaultID,
            path: try PlanningStoredPath("Notes/b.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        XCTAssertEqual(first.fingerprint, same.fingerprint)
        XCTAssertNotEqual(first.fingerprint, differentPath.fingerprint)
        XCTAssertNil(PlanningContentVersion.absent.digest)
    }

    func testPublicationContextRoundTripAndAdditiveDecoding() throws {
        let context = try PlanningPublicationContext(
            selectionGeneration: UUID(),
            rootIdentity: try PlanningFileIdentity(device: 10, inode: 20, fileType: 2),
            observedVersion: .absent,
            observedIdentity: nil
        )
        XCTAssertEqual(try roundTrip(context), context)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any]
        )
        object["future"] = ["version": 3]
        let additive = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(
            try JSONDecoder().decode(PlanningPublicationContext.self, from: additive),
            context
        )
        XCTAssertThrowsError(
            try PlanningPublicationContext(
                selectionGeneration: UUID(),
                rootIdentity: try PlanningFileIdentity(device: 10, inode: 20, fileType: 1),
                observedVersion: .absent,
                observedIdentity: nil
            )
        )
        XCTAssertThrowsError(
            try PlanningPublicationContext(
                selectionGeneration: UUID(),
                rootIdentity: try PlanningFileIdentity(device: 10, inode: 20, fileType: 2),
                observedVersion: .absent,
                observedIdentity: try PlanningFileIdentity(device: 11, inode: 21, fileType: 1)
            )
        )
    }

    func testPublicationOutcomeTaggedVariantsRemainStrictAndBounded() throws {
        let published = PlanningPublicationOutcomeRecord.published(.absent)
        XCTAssertEqual(try roundTrip(published), published)
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(published)
        ) as! [String: Any]
        var unknown = encoded
        unknown["future"] = true
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PlanningPublicationOutcomeRecord.self,
                from: JSONSerialization.data(withJSONObject: unknown)
            )
        )
        let oversized = PlanningPublicationOutcomeRecord.failed(
            code: String(repeating: "x", count: PlanningPublicationLimits.maximumErrorCodeBytes + 1),
            retryable: true
        )
        XCTAssertThrowsError(try JSONEncoder().encode(oversized))
        let nul = PlanningPublicationOutcomeRecord.failed(code: "bad\0code", retryable: false)
        XCTAssertThrowsError(try JSONEncoder().encode(nul))
    }

    func testPublicationAttemptSnapshotRejectsInvalidPhaseAndNonfiniteRetry() throws {
        let attemptID = UUID()
        let mutationID = UUID()
        let prepared = try PlanningPublicationAttemptSnapshot(
            attemptID: attemptID,
            mutationID: mutationID,
            ordinal: 1,
            phase: .prepared
        )
        XCTAssertEqual(try roundTrip(prepared), prepared)
        XCTAssertThrowsError(
            try PlanningPublicationAttemptSnapshot(
                attemptID: attemptID,
                mutationID: mutationID,
                ordinal: 1,
                phase: .stageReady
            )
        )
        XCTAssertThrowsError(
            try PlanningPublicationAttemptSnapshot(
                attemptID: attemptID,
                mutationID: mutationID,
                ordinal: 1,
                phase: .prepared,
                retryAfter: Date(timeIntervalSince1970: .infinity)
            )
        )
        let legacy = try PlanningPublicationAttemptSnapshot(
            attemptID: attemptID,
            mutationID: mutationID,
            ordinal: 1,
            phase: .prepared,
            witnessName: "legacy",
            legacyUnverified: true
        )
        XCTAssertEqual(try roundTrip(legacy), legacy)
    }

    func testRecoveryAndDurableResolutionRecordsValidateBoundsAndRoundTrip() throws {
        let vaultID = UUID()
        let cursor = try PlanningPublicationRecoveryCursor(
            vaultID: vaultID,
            maximumSequence: 10,
            lastExaminedSequence: 4
        )
        XCTAssertEqual(try roundTrip(cursor), cursor)
        XCTAssertThrowsError(
            try PlanningPublicationRecoveryCursor(
                vaultID: vaultID,
                maximumSequence: 3,
                lastExaminedSequence: 4
            )
        )
        let conflictID = UUID()
        let fingerprint = planningPublicationDecisionFingerprint(
            conflictID: conflictID,
            resolution: .keepObserved
        )
        let record = try PlanningDurableResolutionRecord(
            conflictID: conflictID,
            decisionFingerprint: fingerprint,
            resolution: .keepObserved,
            childMutationID: nil
        )
        XCTAssertEqual(try roundTrip(record), record)
        XCTAssertThrowsError(
            try PlanningDurableResolutionRecord(
                conflictID: conflictID,
                decisionFingerprint: String(repeating: "0", count: 64),
                resolution: .keepObserved,
                childMutationID: nil
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("durableResolution.decisionFingerprint"))
        }
    }

    func testLegacyConflictInspectionIsExplicitAndCannotBecomeDecisionEvidence() throws {
        let value = try PlanningLegacyConflictInspection(conflictID: UUID())
        XCTAssertEqual(try roundTrip(value), value)
        XCTAssertThrowsError(
            try PlanningLegacyConflictInspection(
                conflictID: value.conflictID,
                sourceSchemaVersion: 2
            )
        )
        XCTAssertThrowsError(
            try PlanningLegacyConflictInspection(
                conflictID: value.conflictID,
                reason: "fabricated"
            )
        )
    }

}
