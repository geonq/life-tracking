import Foundation

// MARK: - Durable local supplement state

/// Stable, user-visible failures for the local supplement store.  The store
/// intentionally does not expose filesystem paths or decoder details in its
/// public errors.
public enum SupplementStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    case writeFailed
}

extension SupplementStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local supplement storage is unavailable."
        case .readFailed:
            return "Local supplement storage could not be read."
        case .invalidEnvelope:
            return "Local supplement storage is invalid and was not loaded."
        case .writeFailed:
            return "Local supplement changes could not be saved."
        }
    }
}

/// The complete payload identity of one applied occurrence action.
///
/// This is deliberately wider than an action ID.  A caller may retry the
/// exact request after a crash, but reusing its ID for another occurrence,
/// action, timestamp, snooze target, revision, or device is rejected.
public struct SupplementActionReceipt: Codable, Equatable, Identifiable, Sendable {
    public let actionID: String
    public let occurrenceID: String
    public let planID: String
    public let action: SupplementAction
    public let occurredAt: Date
    public let snoozeUntil: Date?
    public let baseRevision: Int
    public let sourceDeviceID: String

    public var id: String { actionID }

    private enum CodingKeys: String, CodingKey {
        case actionID, occurrenceID, planID, action, occurredAt, snoozeUntil,
             baseRevision, sourceDeviceID
    }

    public init(request: SupplementOccurrenceActionRequest, now: Date = .now) throws {
        let canonical = try Self.canonicalizedRequest(request)
        actionID = canonical.actionID
        occurrenceID = canonical.occurrenceID
        planID = canonical.planID
        action = canonical.action
        occurredAt = canonical.occurredAt
        snoozeUntil = canonical.snoozeUntil
        baseRevision = canonical.baseRevision
        sourceDeviceID = canonical.sourceDeviceID
        try validate(now: now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "actionID", "occurrenceID", "planID", "action", "occurredAt",
            "snoozeUntil", "baseRevision", "sourceDeviceID"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actionID = try container.decode(String.self, forKey: .actionID)
        let occurrenceID = try container.decode(String.self, forKey: .occurrenceID)
        let planID = try container.decode(String.self, forKey: .planID)
        let action = try container.decode(SupplementAction.self, forKey: .action)
        let occurredAt = try decodeSupplementISO8601Date(
            forKey: .occurredAt, from: container, field: "actionReceipt.occurredAt"
        )
        let snoozeUntil = try decodeSupplementOptionalISO8601Date(
            forKey: .snoozeUntil, from: container, field: "actionReceipt.snoozeUntil"
        )
        let baseRevision = try container.decode(Int.self, forKey: .baseRevision)
        let sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
        let rawRequest = try SupplementOccurrenceActionRequest(
            actionID: actionID,
            occurrenceID: occurrenceID,
            planID: planID,
            action: action,
            occurredAt: occurredAt,
            snoozeUntil: snoozeUntil,
            baseRevision: baseRevision,
            sourceDeviceID: sourceDeviceID
        )
        let canonical = try Self.canonicalizedRequest(rawRequest)
        self.actionID = canonical.actionID
        self.occurrenceID = canonical.occurrenceID
        self.planID = canonical.planID
        self.action = canonical.action
        self.occurredAt = canonical.occurredAt
        self.snoozeUntil = canonical.snoozeUntil
        self.baseRevision = canonical.baseRevision
        self.sourceDeviceID = canonical.sourceDeviceID
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    /// The store encodes dates with `JSONEncoder.supplement`, whose ISO-8601
    /// fractional representation has millisecond precision.  Normalize an
    /// action before both reduction and receipt comparison so a retry carrying
    /// more in-memory precision is still the exact persisted action.
    public static func canonicalizedRequest(
        _ request: SupplementOccurrenceActionRequest
    ) throws -> SupplementOccurrenceActionRequest {
        try SupplementOccurrenceActionRequest(
            actionID: request.actionID,
            occurrenceID: request.occurrenceID,
            planID: request.planID,
            action: request.action,
            occurredAt: canonicalPersistedDate(request.occurredAt, field: "occurredAt"),
            snoozeUntil: request.snoozeUntil.map {
                try canonicalPersistedDate($0, field: "snoozeUntil")
            },
            baseRevision: request.baseRevision,
            sourceDeviceID: request.sourceDeviceID
        )
    }

    public func request() throws -> SupplementOccurrenceActionRequest {
        try SupplementOccurrenceActionRequest(
            actionID: actionID,
            occurrenceID: occurrenceID,
            planID: planID,
            action: action,
            occurredAt: occurredAt,
            snoozeUntil: snoozeUntil,
            baseRevision: baseRevision,
            sourceDeviceID: sourceDeviceID
        )
    }

    public func matches(_ request: SupplementOccurrenceActionRequest) -> Bool {
        guard let canonical = try? Self.canonicalizedRequest(request) else { return false }
        return actionID == canonical.actionID &&
            occurrenceID == canonical.occurrenceID &&
            planID == canonical.planID &&
            action == canonical.action &&
            occurredAt == canonical.occurredAt &&
            snoozeUntil == canonical.snoozeUntil &&
            baseRevision == canonical.baseRevision &&
            sourceDeviceID == canonical.sourceDeviceID
    }

    public func validate(now: Date = .now) throws {
        try request().validate(now: now)
    }

    private static func canonicalPersistedDate(_ date: Date, field: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wire = formatter.string(from: date)
        guard let canonical = formatter.date(from: wire),
              canonical.timeIntervalSinceReferenceDate.isFinite else {
            throw SupplementValidationError.invalidTimestamp(field)
        }
        return canonical
    }
}

/// Versioned on-disk envelope.  The nested snapshot has its own domain schema
/// version; this version governs the durable store format and receipt ledger.
public struct SupplementStoreEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let snapshot: SupplementSnapshot
    public let actionReceipts: [SupplementActionReceipt]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshot, actionReceipts
    }

    public init(
        snapshot: SupplementSnapshot,
        actionReceipts: [SupplementActionReceipt] = [],
        now: Date = .now
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.snapshot = snapshot
        self.actionReceipts = actionReceipts
        try validate(now: now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "schemaVersion", "snapshot", "actionReceipts"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        snapshot = try container.decode(SupplementSnapshot.self, forKey: .snapshot)
        actionReceipts = try container.decode([SupplementActionReceipt].self, forKey: .actionReceipts)
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public func validate(now: Date = .now) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SupplementValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try snapshot.validate(now: now)
        guard actionReceipts.count <= 100_000 else {
            throw SupplementValidationError.invalidBounds("actionReceipts")
        }

        var actionIDs = Set<String>()
        var occurrenceRevisionKeys = Set<String>()
        var baseRevisions = Set<Int>()
        var receiptsByOccurrence: [String: [SupplementActionReceipt]] = [:]
        for receipt in actionReceipts {
            try receipt.validate(now: now)
            guard actionIDs.insert(receipt.actionID).inserted else {
                throw SupplementValidationError.duplicateIdentifier(receipt.actionID)
            }
            guard baseRevisions.insert(receipt.baseRevision).inserted else {
                throw SupplementValidationError.contradictoryState(
                    "multiple action receipts target the same snapshot revision"
                )
            }
            guard snapshot.plans.contains(where: { $0.id == receipt.planID }),
                  let occurrence = snapshot.occurrences.first(where: { $0.id == receipt.occurrenceID }) else {
                throw SupplementValidationError.danglingPlanReference(receipt.occurrenceID)
            }
            guard occurrence.planID == receipt.planID else {
                throw SupplementValidationError.contradictoryState(
                    "action receipt occurrence and plan links differ"
                )
            }
            guard occurrenceRevisionKeys.insert(
                "\(receipt.occurrenceID)#\(receipt.baseRevision)"
            ).inserted else {
                throw SupplementValidationError.contradictoryState(
                    "multiple action receipts target the same occurrence revision"
                )
            }
            guard receipt.baseRevision < snapshot.revision,
                  receipt.baseRevision < occurrence.revision else {
                throw SupplementValidationError.invalidAction(
                    "action receipt did not advance its occurrence"
                )
            }
            receiptsByOccurrence[receipt.occurrenceID, default: []].append(receipt)
        }

        // Validate the complete per-occurrence history, not only whichever
        // receipt happens to have a base revision immediately before the
        // current occurrence revision.  A valid chain starts from Planned (or
        // an untouched Missed occurrence), advances only through the reducer's
        // legal transitions, and ends exactly at the persisted state.
        for occurrence in snapshot.occurrences {
            let chain = (receiptsByOccurrence[occurrence.id] ?? []).sorted {
                if $0.baseRevision != $1.baseRevision {
                    return $0.baseRevision < $1.baseRevision
                }
                return $0.occurredAt < $1.occurredAt
            }

            guard !chain.isEmpty || occurrence.revision == 0 else {
                throw SupplementValidationError.invalidAction(
                    "occurrence revision has no complete receipt chain"
                )
            }

            var state = SupplementOccurrenceState.planned
            var actedAt: Date?
            var snoozedUntil: Date?
            var previousBaseRevision: Int?
            var previousOccurredAt: Date?

            for receipt in chain {
                if let previousBaseRevision {
                    guard receipt.baseRevision > previousBaseRevision else {
                        throw SupplementValidationError.contradictoryState(
                            "receipt chain is not strictly chronological"
                        )
                    }
                }
                if let previousOccurredAt {
                    guard receipt.occurredAt >= previousOccurredAt else {
                        throw SupplementValidationError.contradictoryState(
                            "receipt timestamps are not chronological"
                        )
                    }
                }
                guard let nextState = Self.nextState(for: receipt.action, from: state) else {
                    throw SupplementValidationError.invalidAction(
                        "receipt chain contains a terminal-state transition"
                    )
                }
                state = nextState
                actedAt = receipt.occurredAt
                snoozedUntil = receipt.action == .snooze ? receipt.snoozeUntil : nil
                previousBaseRevision = receipt.baseRevision
                previousOccurredAt = receipt.occurredAt
            }

            if let last = chain.last {
                guard occurrence.revision == last.baseRevision + 1 else {
                    throw SupplementValidationError.invalidAction(
                        "occurrence revision does not close its receipt chain"
                    )
                }
                guard occurrence.state == state,
                      occurrence.actedAt == actedAt,
                      occurrence.snoozedUntil == snoozedUntil else {
                    throw SupplementValidationError.contradictoryState(
                        "receipt chain does not match occurrence state"
                    )
                }
            } else {
                // A materialized occurrence is allowed to be explicitly
                // Missed without an action receipt.  Planned is the only
                // other untouched state.
                guard occurrence.state == .planned || occurrence.state == .missed,
                      occurrence.actedAt == nil,
                      occurrence.snoozedUntil == nil else {
                    throw SupplementValidationError.contradictoryState(
                        "untouched occurrence has action state"
                    )
                }
            }
        }
    }

    private static func nextState(
        for action: SupplementAction,
        from state: SupplementOccurrenceState
    ) -> SupplementOccurrenceState? {
        switch (action, state) {
        case (.taken, .planned), (.taken, .snoozed): return .taken
        case (.snooze, .planned), (.snooze, .snoozed): return .snoozed
        case (.skip, .planned), (.skip, .snoozed): return .skipped
        default: return nil
        }
    }
}

/// The in-memory value returned by `SupplementStore.load` and accepted by a
/// session during rehydration.  It intentionally has no network or widget
/// publishing behavior.
public struct SupplementStoreState: Equatable, Sendable {
    public var snapshot: SupplementSnapshot
    public var actionReceipts: [SupplementActionReceipt]

    public init(
        snapshot: SupplementSnapshot,
        actionReceipts: [SupplementActionReceipt] = [],
        now: Date = .now
    ) throws {
        let envelope = try SupplementStoreEnvelope(
            snapshot: snapshot,
            actionReceipts: actionReceipts,
            now: now
        )
        self.snapshot = envelope.snapshot
        self.actionReceipts = envelope.actionReceipts
    }
}

/// Atomic, Application-Support-backed local supplement storage.
///
/// The URL is injectable only for deterministic tests.  The default path has
/// no temporary-directory or home-directory fallback: if Application Support
/// cannot be resolved, initialization fails closed.
public final class SupplementStore: @unchecked Sendable {
    public static let fileName = "supplements-v1.json"
    private static let processTransactionLock = NSLock()

    public let fileURL: URL
    private let fileManager: FileManager
    private let beforeReplace: (() throws -> Void)?

    public init(
        url: URL? = nil,
        fileManager: FileManager = .default,
        beforeReplace: (() throws -> Void)? = nil
    ) throws {
        self.fileManager = fileManager
        self.beforeReplace = beforeReplace
        if let url {
            self.fileURL = url
        } else {
            self.fileURL = try Self.defaultURL(fileManager: fileManager)
        }
    }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SupplementStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public func load(now: Date = .now) throws -> SupplementStoreState? {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked(now: now)
    }

    /// Loads the latest state or atomically creates and saves the supplied
    /// initial state.  The read, decision, and first write share the same
    /// in-process transaction lock, so two sessions created concurrently
    /// cannot both observe an empty store and overwrite one another.  This is
    /// deliberately an in-process guarantee; no cross-process locking claim
    /// is made for the injectable test URL.
    public func loadOrCreate(
        now: Date = .now,
        create: () throws -> SupplementStoreState
    ) throws -> SupplementStoreState {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        if let existing = try loadUnlocked(now: now) {
            return existing
        }
        let initial = try create()
        do {
            try saveUnlocked(
                snapshot: initial.snapshot,
                actionReceipts: initial.actionReceipts,
                now: now
            )
        } catch {
            throw error
        }
        return initial
    }

    /// Runs one read/modify/write transaction against the latest durable
    /// state.  The lock covers the reread and atomic replacement, preventing
    /// two in-process sessions from clobbering one another with stale
    /// snapshots.
    @discardableResult
    public func mutate<T>(
        now: Date = .now,
        _ mutation: (inout SupplementStoreState) throws -> T
    ) throws -> T {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        guard var state = try loadUnlocked(now: now) else {
            throw SupplementStoreError.readFailed
        }
        let original = state
        let result = try mutation(&state)
        if state != original {
            try saveUnlocked(
                snapshot: state.snapshot,
                actionReceipts: state.actionReceipts,
                now: now
            )
        }
        return result
    }

    private func loadUnlocked(now: Date) throws -> SupplementStoreState? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SupplementStoreError.readFailed
        }

        do {
            let decoder = JSONDecoder.supplement
            decoder.userInfo[.lifeOSNow] = now
            let envelope = try decoder.decode(SupplementStoreEnvelope.self, from: data)
            return try SupplementStoreState(
                snapshot: envelope.snapshot,
                actionReceipts: envelope.actionReceipts,
                now: now
            )
        } catch {
            throw SupplementStoreError.invalidEnvelope
        }
    }

    public func save(
        snapshot: SupplementSnapshot,
        actionReceipts: [SupplementActionReceipt] = [],
        now: Date = .now
    ) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        try saveUnlocked(snapshot: snapshot, actionReceipts: actionReceipts, now: now)
    }

    private func saveUnlocked(
        snapshot: SupplementSnapshot,
        actionReceipts: [SupplementActionReceipt],
        now: Date
    ) throws {
        let envelope: SupplementStoreEnvelope
        let data: Data
        do {
            envelope = try SupplementStoreEnvelope(
                snapshot: snapshot,
                actionReceipts: actionReceipts,
                now: now
            )
            data = try JSONEncoder.supplement.encode(envelope)
        } catch {
            throw SupplementStoreError.invalidEnvelope
        }

        do {
            try atomicReplace(data)
        } catch {
            throw SupplementStoreError.writeFailed
        }
    }

    public func save(_ state: SupplementStoreState, now: Date = .now) throws {
        try save(
            snapshot: state.snapshot,
            actionReceipts: state.actionReceipts,
            now: now
        )
    }

    private func atomicReplace(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

#if os(iOS)
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: temporary, options: [.atomic])
#endif
        try beforeReplace?()

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: fileURL)
        }
    }
}
