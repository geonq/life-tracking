import Foundation

public enum PlanningConflictResolver {
    /// Resolves only the user's explicit choice. It never compares timestamps,
    /// rewrites Canvas or Markdown, touches the filesystem, or mutates OS file
    /// versions. The returned mutation requests always carry a fresh UUID.
    public static func resolve(
        evidence: PlanningConflictEvidence,
        resolution: PlanningConflictResolution
    ) throws -> PlanningConflictDecision {
        let conflict = evidence.conflict

        switch resolution {
        case .keepObserved:
            return .keepObserved(conflictID: conflict.conflictID)

        case .keepBoth:
            guard let localBytes = conflict.localBytes else {
                throw PlanningStorageError.invalid("conflictResolution.keepBoth")
            }
            try PlanningMutationRequest.validateConflictBytes(localBytes, for: conflict.path)
            return .keepBoth(conflictID: conflict.conflictID, bytes: localBytes)

        case .applyLocal(let expectedObservedVersion):
            let request = try PlanningMutationRequest.makeForResolution(
                mutationID: UUID(),
                conflict: conflict,
                expectedObservedVersion: expectedObservedVersion,
                bytes: conflict.localBytes
            )
            return .applyLocal(request)

        case .applyMerged(let bytes, let expectedObservedVersion):
            try PlanningMutationRequest.validateConflictBytes(bytes, for: conflict.path)
            let request = try PlanningMutationRequest.makeForResolution(
                mutationID: UUID(),
                conflict: conflict,
                expectedObservedVersion: expectedObservedVersion,
                bytes: bytes
            )
            return .applyMerged(request)
        }
    }
}
