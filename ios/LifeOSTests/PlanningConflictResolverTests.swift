import Foundation
import XCTest
@testable import LifeOS

final class PlanningConflictResolverTests: XCTestCase {
    private func makeCreateEvidence() throws -> PlanningConflictEvidence {
        let path = try PlanningStoredPath("Notes/topic.md")
        let conflict = try PlanningConflict(
            mutationID: UUID(),
            vaultID: UUID(),
            path: path,
            operation: .create,
            reason: "observed changed",
            baseVersion: .absent,
            localBytes: Data(),
            observedVersion: .absent,
            observedBytes: nil
        )
        return PlanningConflictEvidence(conflict: conflict, attemptedPublication: false)
    }

    func testAllFourExplicitResolutionChoices() throws {
        let evidence = try makeCreateEvidence()

        let keepObserved = try PlanningConflictResolver.resolve(
            evidence: evidence,
            resolution: .keepObserved
        )
        XCTAssertEqual(
            keepObserved,
            .keepObserved(conflictID: evidence.conflict.conflictID)
        )

        let applyLocal = try PlanningConflictResolver.resolve(
            evidence: evidence,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        guard case .applyLocal(let localRequest) = applyLocal else {
            return XCTFail("applyLocal did not produce a new mutation")
        }
        XCTAssertNotEqual(localRequest.mutationID, evidence.conflict.mutationID)
        XCTAssertEqual(localRequest.operation, .create)
        XCTAssertEqual(localRequest.proposedBytes, Data())

        let keepBoth = try PlanningConflictResolver.resolve(
            evidence: evidence,
            resolution: .keepBoth
        )
        XCTAssertEqual(
            keepBoth,
            .keepBoth(conflictID: evidence.conflict.conflictID, bytes: Data())
        )

        let applyMerged = try PlanningConflictResolver.resolve(
            evidence: evidence,
            resolution: .applyMerged(bytes: Data(), expectedObservedVersion: .absent)
        )
        guard case .applyMerged(let mergedRequest) = applyMerged else {
            return XCTFail("applyMerged did not produce a new mutation")
        }
        XCTAssertNotEqual(mergedRequest.mutationID, evidence.conflict.mutationID)
        XCTAssertEqual(mergedRequest.operation, .create)
        XCTAssertEqual(mergedRequest.proposedBytes, Data())
    }

    func testStaleResolutionPreconditionsAndMissingKeepBothPayloadReject() throws {
        let evidence = try makeCreateEvidence()
        let observedBytes = Data("observed".utf8)
        let staleVersion = PlanningContentVersion(data: observedBytes)

        XCTAssertThrowsError(
            try PlanningConflictResolver.resolve(
                evidence: evidence,
                resolution: .applyLocal(expectedObservedVersion: staleVersion)
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .conflict)
        }

        XCTAssertThrowsError(
            try PlanningConflictResolver.resolve(
                evidence: evidence,
                resolution: .applyMerged(bytes: Data(), expectedObservedVersion: staleVersion)
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .conflict)
        }

        let deleteConflict = try PlanningConflict(
            mutationID: UUID(),
            vaultID: UUID(),
            path: try PlanningStoredPath("Notes/delete.md"),
            operation: .delete,
            reason: "observed changed",
            baseVersion: staleVersion,
            localBytes: nil,
            observedVersion: staleVersion,
            observedBytes: observedBytes
        )
        let deleteEvidence = PlanningConflictEvidence(
            conflict: deleteConflict,
            attemptedPublication: true,
            displacedVersion: staleVersion
        )
        XCTAssertThrowsError(
            try PlanningConflictResolver.resolve(
                evidence: deleteEvidence,
                resolution: .keepBoth
            )
        )
    }
}
