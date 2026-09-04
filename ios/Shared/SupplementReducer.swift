import Foundation

/// The action IDs that have already been applied to a local reducer instance.
///
/// This is deliberately an in-memory type.  The durable supplement snapshot is
/// the source of truth; the ledger only makes retries of an action safe while a
/// client is processing a request.
public struct SupplementActionLedger: Equatable, Sendable {
    private struct Fingerprint: Equatable, Sendable {
        let planID: String
        let occurrenceID: String
        let action: String
        let occurredAt: Date
        let snoozeUntil: Date?
        let sourceDeviceID: String

        init(_ request: SupplementOccurrenceActionRequest) {
            planID = request.planID
            occurrenceID = request.occurrenceID
            action = request.action.rawValue
            occurredAt = request.occurredAt
            snoozeUntil = request.snoozeUntil
            sourceDeviceID = request.sourceDeviceID
        }
    }

    private var fingerprints: [String: Fingerprint]

    /// The stable action IDs recorded by this in-memory ledger.
    public var processedActionIDs: Set<String> {
        Set(fingerprints.keys)
    }

    public init() {
        self.fingerprints = [:]
    }

    /// Returns `nil` for an unseen action ID, `true` for an exact retry, and
    /// `false` when a caller reuses an action ID with another payload.
    fileprivate func retryMatch(for request: SupplementOccurrenceActionRequest) -> Bool? {
        guard processedActionIDs.contains(request.actionID) else { return nil }
        guard let fingerprint = fingerprints[request.actionID] else { return false }
        return fingerprint == Fingerprint(request)
    }

    fileprivate mutating func markProcessed(_ request: SupplementOccurrenceActionRequest) {
        fingerprints[request.actionID] = Fingerprint(request)
    }
}

public enum SupplementReducer {
    private static let maxRevision = 9_007_199_254_740_991

    /// Applies one occurrence action to a snapshot.
    ///
    /// Every failure occurs before the snapshot or ledger is changed.  A
    /// processed action ID is the one intentional exception to normal
    /// revision checking: a retry returns the current occurrence unchanged,
    /// with an idempotent response and zero inventory delta.
    public static func reduce(
        _ request: SupplementOccurrenceActionRequest,
        in snapshot: inout SupplementSnapshot,
        ledger: inout SupplementActionLedger,
        now: Date = .now
    ) throws -> SupplementOccurrenceActionResponse {
        // Domain validation owns the strict wire contract (bounds,
        // timestamps, correction links, and inventory event invariants).
        try request.validate(now: now)
        try snapshot.validate(now: now)

        guard let occurrenceIndex = snapshot.occurrences.firstIndex(where: { $0.id == request.occurrenceID }) else {
            throw SupplementValidationError.danglingPlanReference(request.occurrenceID)
        }
        guard let planIndex = snapshot.plans.firstIndex(where: { $0.id == request.planID }) else {
            throw SupplementValidationError.danglingPlanReference(request.planID)
        }

        let occurrence = snapshot.occurrences[occurrenceIndex]
        let plan = snapshot.plans[planIndex]
        guard occurrence.planID == request.planID else {
            throw SupplementValidationError.contradictoryState("occurrence and request plan links differ")
        }

        // A retry may carry the old base revision.  Once the action ID is in
        // the ledger it is safe to return the current state without touching
        // either value.
        if let retryMatch = ledger.retryMatch(for: request) {
            guard retryMatch else {
                throw SupplementValidationError.invalidAction("actionID was reused with a different payload")
            }
            return try makeResponse(
                occurrence: occurrence,
                inventoryDelta: 0,
                idempotent: true,
                serverRevision: snapshot.revision,
                now: now
            )
        }

        guard request.baseRevision == snapshot.revision else {
            throw SupplementValidationError.revisionConflict
        }

        try validateTransition(request.action, from: occurrence.state)

        let nextRevision = try increment(snapshot.revision)
        let nextOccurrenceState: SupplementOccurrenceState
        let nextSnoozedUntil: Date?
        let inventoryDelta: Int

        switch request.action {
        case .taken:
            nextOccurrenceState = .taken
            nextSnoozedUntil = nil
            // Taken is allowed when stock is already empty: adherence is still
            // recorded, but inventory never becomes negative.
            let consumed = min(plan.inventoryUnitsPerDose, plan.stockUnits)
            inventoryDelta = -consumed
        case .snooze:
            nextOccurrenceState = .snoozed
            nextSnoozedUntil = request.snoozeUntil
            inventoryDelta = 0
        case .skip:
            nextOccurrenceState = .skipped
            nextSnoozedUntil = nil
            inventoryDelta = 0
        }

        var nextOccurrence = occurrence
        nextOccurrence.state = nextOccurrenceState
        nextOccurrence.actedAt = request.occurredAt
        nextOccurrence.snoozedUntil = nextSnoozedUntil
        nextOccurrence.revision = nextRevision
        nextOccurrence.updatedAt = now

        var nextPlan = plan
        if inventoryDelta < 0 {
            nextPlan.stockUnits = max(0, plan.stockUnits + inventoryDelta)
            nextPlan.revision = nextRevision
            nextPlan.updatedAt = now
        }
        // Snooze and Skip only change the occurrence. The plan's revision and
        // timestamp therefore remain stable unless inventory actually moved.

        // Event IDs are derived solely from the stable action ID.  No event is
        // written for an empty-stock Taken action because there was no change.
        var nextInventoryEvents = snapshot.inventoryEvents
        if inventoryDelta < 0 {
            let eventID = deterministicTakenEventID(for: request.actionID)
            guard !nextInventoryEvents.contains(where: { $0.id == eventID }) else {
                throw SupplementValidationError.contradictoryState("duplicate Taken inventory event")
            }
            let event = try InventoryEvent(
                id: eventID,
                planID: plan.id,
                kind: .takenDecrement,
                delta: inventoryDelta,
                stockAfter: nextPlan.stockUnits,
                occurredAt: request.occurredAt,
                occurrenceID: occurrence.id,
                now: now
            )
            nextInventoryEvents.append(event)
        }

        let response = try makeResponse(
            occurrence: nextOccurrence,
            inventoryDelta: inventoryDelta,
            idempotent: false,
            serverRevision: nextRevision,
            now: now
        )

        snapshot.occurrences[occurrenceIndex] = nextOccurrence
        snapshot.plans[planIndex] = nextPlan
        snapshot.inventoryEvents = nextInventoryEvents
        snapshot.revision = nextRevision
        snapshot.generatedAt = now
        ledger.markProcessed(request)
        return response
    }

    private static func makeResponse(
        occurrence: SupplementOccurrence,
        inventoryDelta: Int,
        idempotent: Bool,
        serverRevision: Int,
        now: Date
    ) throws -> SupplementOccurrenceActionResponse {
        try SupplementOccurrenceActionResponse(
            occurrence: occurrence,
            inventoryDelta: inventoryDelta,
            idempotent: idempotent,
            serverRevision: serverRevision,
            now: now
        )
    }

    private static func validateTransition(
        _ action: SupplementAction,
        from state: SupplementOccurrenceState
    ) throws {
        switch (action, state) {
        case (.taken, .planned), (.taken, .snoozed),
             (.snooze, .planned), (.snooze, .snoozed),
             (.skip, .planned), (.skip, .snoozed):
            return
        case (.taken, .taken), (.taken, .skipped), (.taken, .missed),
             (.snooze, .taken), (.snooze, .skipped), (.snooze, .missed),
             (.skip, .taken), (.skip, .skipped), (.skip, .missed):
            throw SupplementValidationError.contradictoryState(
                "cannot apply \(action.rawValue) to \(state.rawValue) occurrence"
            )
        }
    }

    private static func increment(_ revision: Int) throws -> Int {
        guard revision < maxRevision else { throw SupplementValidationError.invalidBounds("revision") }
        return revision + 1
    }

    private static func deterministicTakenEventID(for actionID: String) -> String {
        let prefix = "taken-"
        // Supplement IDs are ASCII and capped at 128 characters by the
        // contract. Keep the readable form whenever it fits the event bound.
        if actionID.utf8.count <= 122 { return prefix + actionID }

        // FNV-1a is small, deterministic across processes, and avoids Swift's
        // intentionally randomized Hashable.hashValue.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in actionID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return prefix + String(hash, radix: 16)
    }

}
