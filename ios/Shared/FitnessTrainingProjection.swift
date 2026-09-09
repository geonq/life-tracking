import Foundation

// MARK: - Imported source boundary

/// A HealthKit-free mirror of the source state carried by a workout value.
/// The iOS adapter maps `HealthKitMetricState` to this enum; shared consumers
/// never need to import HealthKit or infer a missing value.
public enum TrainingImportedHealthState: String, CaseIterable, Hashable, Sendable {
    case unavailable
    case permissionRequired = "permission_required"
    case readIndeterminate = "read_indeterminate"
    case observed
    case partial
    case stale
    case conflict
    case error

    fileprivate var recordState: TrainingSourceState {
        switch self {
        case .unavailable, .permissionRequired: .unavailable
        case .readIndeterminate: .readIndeterminate
        case .observed: .imported
        case .partial: .partial
        case .stale: .stale
        case .conflict: .conflict
        case .error: .error
        }
    }
}

/// Query state is separate from record state. A failed refresh may retain a
/// previously observed record, so it must not rewrite that record as empty.
public enum TrainingImportQueryState: String, CaseIterable, Hashable, Sendable {
    case noSource = "no_source"
    case imported
    case partial
    case stale
    case conflict
    case unavailable
    case readIndeterminate = "read_indeterminate"
    case error

    fileprivate init(_ state: TrainingSourceState) {
        switch state {
        case .imported: self = .imported
        case .partial: self = .partial
        case .stale: self = .stale
        case .conflict: self = .conflict
        case .unavailable: self = .unavailable
        case .readIndeterminate: self = .readIndeterminate
        case .error: self = .error
        case .local, .mixed: self = .noSource
        }
    }

}

/// One untrusted imported value before it enters the validated shared record.
/// This is deliberately value-only and can be built by an iOS adapter without
/// giving the projection any query, persistence, or HealthKit ownership.
public struct TrainingImportedWorkoutInput: Equatable, Hashable, Sendable {
    public let identity: TrainingImportedWorkoutIdentity
    public let activityTypeRawValue: Int
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: TimeInterval
    public let activeEnergyKilocalories: Double?
    public let healthState: TrainingImportedHealthState
    public let provenance: TrainingImportedWorkoutProvenance?

    public init(
        identity: TrainingImportedWorkoutIdentity,
        activityTypeRawValue: Int,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        activeEnergyKilocalories: Double? = nil,
        healthState: TrainingImportedHealthState = .observed,
        provenance: TrainingImportedWorkoutProvenance? = nil
    ) {
        self.identity = identity
        self.activityTypeRawValue = activityTypeRawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.healthState = healthState
        self.provenance = provenance
    }
}

/// A validated imported row plus the source truth and indexed identity keys
/// needed by a read-only UI. No display label or HealthKit value is guessed.
public struct TrainingImportedWorkoutProjection: Equatable, Hashable, Identifiable, Sendable {
    public let record: TrainingImportedHistoryRecord
    public let healthState: TrainingImportedHealthState
    public let identityKeys: [String]
    /// A broad matching bucket used only for duplicate candidates. `nil` means
    /// the raw provider activity value is unknown and cannot match locally.
    public let activityKind: TrainingActivityKind?

    public var id: String { record.id }

    fileprivate init(record: TrainingImportedHistoryRecord, healthState: TrainingImportedHealthState) {
        self.record = record
        self.healthState = healthState
        self.identityKeys = Array(Set([record.identity.stableKey] + Array(record.identity.aliasKeys))).sorted()
        self.activityKind = Self.activityKind(for: record.activityTypeRawValue)
    }

    fileprivate static func activityKind(for rawValue: Int) -> TrainingActivityKind? {
        // These are the stable HKWorkoutActivityType raw values used only for
        // conservative duplicate matching. Ambiguous or unknown values remain
        // unmatched; the raw provider value is always preserved separately.
        switch rawValue {
        case 20, 50, 59: // functional/traditional strength, core training
            return .strength
        case 13, 16, 24, 30, 35, 37, 44, 46, 52, 53, 63, 64, 68, 69, 70, 71, 73, 74, 77, 82:
            return .cardio
        case 33, 57, 72, 80: // preparation/recovery, yoga, tai chi, cooldown
            return .mobility
        case 58, 62, 66: // barre, flexibility, pilates
            return .flexibility
        case 1...10, 12, 17...19, 21...23, 25...28, 31...32, 34, 36, 38...43, 45,
             47...49, 51, 54...56, 60...61, 65, 67, 75...76, 79:
            return .sport
        case 3000:
            return .other
        default:
            return nil
        }
    }
}

/// The result of converting raw imported values. Invalid rows are reported
/// individually and do not turn the complete source into an empty history.
public struct TrainingImportedProjectionResult: Equatable, Sendable {
    public let snapshot: TrainingImportedHistorySnapshot
    public let records: [TrainingImportedWorkoutProjection]
    public let rejectedRows: [TrainingImportedRecordRejection]

    public var rejectedRowCount: Int { snapshot.rejectedRowCount }
    public var truncatedRowCount: Int { snapshot.truncatedRowCount }
    public var conflictEvidence: [TrainingImportedConflictEvidence] { snapshot.conflictEvidence }

    fileprivate init(
        snapshot: TrainingImportedHistorySnapshot,
        records: [TrainingImportedWorkoutProjection],
        rejectedRows: [TrainingImportedRecordRejection]
    ) {
        self.snapshot = snapshot
        self.records = records
        self.rejectedRows = rejectedRows
    }
}

// MARK: - Combined read model

public enum TrainingLinkStatus: String, CaseIterable, Hashable, Sendable {
    case unlinked
    case linked
    case conflict
    case missingImported = "missing_imported"
    case ambiguousImported = "ambiguous_imported"
    case invalidImportedKey = "invalid_imported_key"
    case noImportedSource = "no_imported_source"
    case unavailable
}

/// Link state is presentation metadata. A link never merges or mutates either
/// the local session or the imported source record.
public struct TrainingLinkState: Equatable, Hashable, Identifiable, Sendable {
    public let localID: TrainingRecordID
    public let localIdentityKey: String
    public let importedRecordKey: String?
    public let importedIdentityKeys: [String]
    public let status: TrainingLinkStatus

    public var id: String {
        "local:\(localID.rawValue)|imported:\(importedRecordKey ?? "")"
    }
}

/// A conservative duplicate suggestion. It is never an automatic merge and
/// is omitted once either endpoint already has a confirmed link.
public struct TrainingDuplicateCandidate: Equatable, Hashable, Identifiable, Sendable {
    public let localID: TrainingRecordID
    public let localIdentityKey: String
    public let importedRecordKey: String
    public let importedIdentityKeys: [String]
    public let importedActivityTypeRawValue: Int
    public let startDifferenceSeconds: TimeInterval
    public let durationDifferenceSeconds: TimeInterval

    public var id: String { "\(localIdentityKey)|\(importedRecordKey)" }
}

public struct TrainingPersonalRecord: Equatable, Hashable, Identifiable, Sendable {
    public let exerciseIdentityKey: String
    public let exerciseName: String
    public let loadConvention: TrainingLoadConvention
    public let maximumExternalLoadKilograms: Double?
    public let maximumLoadSessionID: TrainingRecordID?
    public let maximumLoadRecordedAt: Date?
    public let bestWorkingSetVolumeKilograms: Double?
    public let bestVolumeSessionID: TrainingRecordID?
    public let bestVolumeRecordedAt: Date?

    public var id: String { exerciseIdentityKey }
}

/// Transparent local-only arithmetic. Imported HealthKit rows never
/// contribute sets, repetitions, load, or proprietary Training Effect values.
public struct TrainingStrengthStatistics: Equatable, Sendable {
    public let completedSessionCount: Int
    public let completedSetCount: Int
    public let totalDurationSeconds: TimeInterval?
    public let durationOverflowed: Bool
    public let knownExternalVolumeKilograms: Double?
    public let volumeCoverage: TrainingCoverageKind
    public let incompleteVolumeSetCount: Int
    public let personalRecords: [TrainingPersonalRecord]
    public let currentStreakDays: Int
    public let calendarTimeZoneIdentifier: String
}

/// Pure composition of one immutable local ledger snapshot and one optional
/// retained imported snapshot. It performs no query, write, formatting, or
/// persistence and keeps editable local sessions separate from read-only rows.
public struct TrainingHistoryProjection: Equatable, Sendable {
    public static let maximumDuplicateCandidates = 512
    public static let maximumDuplicateCandidatesPerLocal = 8
    public static let maximumDuplicateComparisonsPerLocal = 256
    public static let duplicateStartToleranceSeconds: TimeInterval = 120

    public let localSnapshot: TrainingStoreSnapshot
    public let localSessions: [TrainingSession]
    public let localEntries: [TrainingHistoryItem]
    public let importedSnapshot: TrainingImportedHistorySnapshot?
    public let importedEntries: [TrainingImportedWorkoutProjection]
    public let importedQueryState: TrainingImportQueryState
    public let importedQueryCoverage: TrainingCoverage?
    public let entries: [TrainingHistoryEntry]
    public let linkStates: [TrainingLinkState]
    public let duplicateCandidates: [TrainingDuplicateCandidate]
    public let duplicateComparisonCount: Int
    public let duplicateMatchingWasBounded: Bool
    public let unlinkedImportedRecordKeys: [String]
    public let rejectedImportedRows: [TrainingImportedRecordRejection]
    public let rejectedImportedRowCount: Int
    public let truncatedImportedRowCount: Int
    public let importedConflictEvidence: [TrainingImportedConflictEvidence]
    public let statistics: TrainingStrengthStatistics
    public let calendarTimeZoneIdentifier: String

    /// A Gregorian calendar in the user's product timezone. Date arithmetic
    /// uses instants and this calendar, so the spring/fall DST day remains one
    /// calendar day rather than a fixed 24-hour bucket.
    public static func berlinCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }

    public init(
        localSnapshot: TrainingStoreSnapshot,
        importedSnapshot: TrainingImportedHistorySnapshot? = nil,
        calendar: Calendar = TrainingHistoryProjection.berlinCalendar(),
        now: Date = .now
    ) {
        self.localSnapshot = localSnapshot
        self.importedSnapshot = importedSnapshot
        self.calendarTimeZoneIdentifier = calendar.timeZone.identifier

        let orderedSessions = localSnapshot.sessions.sorted(by: Self.localSessionOrder)
        self.localSessions = orderedSessions
        self.localEntries = orderedSessions
            .filter { $0.status != .discarded }
            .compactMap { try? TrainingHistoryItem(session: $0, now: now) }

        let importedBuild = Self.projectImported(importedSnapshot)
        self.importedEntries = importedBuild.records
        self.rejectedImportedRows = importedBuild.rejectedRows
        let sourceQueryState = importedSnapshot.map { TrainingImportQueryState($0.queryState) } ?? .noSource
        // A source query cannot remain qualified as clean when the projection
        // found contradictory records for one identity/revision. Retained rows
        // remain available, but consumers must see the conflict before
        // treating absence as evidence, even when another input already made
        // the query partial.
        self.importedQueryState = importedBuild.conflictEvidence.isEmpty
            ? sourceQueryState
            : .conflict
        self.importedQueryCoverage = importedSnapshot?.queryCoverage
        self.rejectedImportedRowCount = importedBuild.rejectedRowCount
        self.truncatedImportedRowCount = importedBuild.truncatedRowCount
        self.importedConflictEvidence = importedBuild.conflictEvidence

        self.entries = Self.combinedEntries(local: localEntries, imported: importedEntries)

        let linkBuild = Self.buildLinks(
            sessions: orderedSessions.filter { $0.status != .discarded },
            imported: importedEntries,
            queryState: importedQueryState,
            queryCoverage: importedQueryCoverage
        )
        self.linkStates = linkBuild.states
        self.unlinkedImportedRecordKeys = importedEntries
            .map(\.record.id)
            .filter { !linkBuild.linkedImportedKeys.contains($0) }
            .sorted()

        let duplicateBuild = Self.buildDuplicateCandidates(
            sessions: orderedSessions,
            imported: importedEntries,
            linkedLocalIDs: linkBuild.linkedLocalIDs,
            linkedImportedKeys: linkBuild.linkedImportedKeys
        )
        self.duplicateCandidates = duplicateBuild.candidates
        self.duplicateComparisonCount = duplicateBuild.comparisonCount
        self.duplicateMatchingWasBounded = duplicateBuild.wasBounded
        self.statistics = Self.makeStatistics(
            sessions: orderedSessions,
            calendar: calendar,
            now: now
        )
    }

    /// Converts HealthKit-free inputs into the existing validated imported
    /// snapshot contract. The iOS adapter only supplies inputs; it does not
    /// perform persistence or query work here.
    public static func makeImportedSnapshot(
        from inputs: [TrainingImportedWorkoutInput],
        queryState: TrainingSourceState,
        queryCoverage: TrainingCoverage,
        now: Date = .now
    ) throws -> TrainingImportedProjectionResult {
        var records: [TrainingImportedHistoryRecord] = []
        let capacity = min(inputs.count, TrainingDomainLimits.maximumImportedHistoryRecords)
        records.reserveCapacity(capacity)
        var projections: [TrainingImportedWorkoutProjection] = []
        projections.reserveCapacity(capacity)
        var rejected: [TrainingImportedRecordRejection] = []
        var rejectedRowCount = 0
        var truncatedRowCount = 0

        let inspectedRowCount = min(
            inputs.count,
            TrainingDomainLimits.maximumImportedInputInspectionRows
        )
        var inputEvidenceIsIncomplete = inspectedRowCount < inputs.count

        for input in inputs.prefix(inspectedRowCount) {
            inputEvidenceIsIncomplete = inputEvidenceIsIncomplete || input.healthState != .observed
            guard records.count < TrainingDomainLimits.maximumImportedHistoryRecords else {
                rejectedRowCount += 1
                truncatedRowCount += 1
                if rejected.count < TrainingDomainLimits.maximumImportedDiagnostics {
                    rejected.append(TrainingImportedRecordRejection(
                        reason: .invalidImportedSource,
                        stableKey: input.identity.stableKey
                    ))
                }
                continue
            }

            let result = TrainingImportedHistoryRecord.ingest(
                identity: input.identity,
                activityTypeRawValue: input.activityTypeRawValue,
                startedAt: input.startedAt,
                endedAt: input.endedAt,
                durationSeconds: input.durationSeconds,
                activeEnergyKilocalories: input.activeEnergyKilocalories,
                sourceState: input.healthState.recordState,
                coverage: Self.recordCoverage(for: input),
                provenance: input.provenance,
                now: now
            )
            switch result {
            case .accepted(let record):
                // Validate the input row first so malformed dates retain their
                // precise diagnostic. Only a validated record is then checked
                // against the provider's declared query interval.
                if queryCoverage.kind != .unavailable,
                   !queryCoverage.contains(startedAt: record.startedAt, endedAt: record.endedAt) {
                    rejectedRowCount += 1
                    inputEvidenceIsIncomplete = true
                    if rejected.count < TrainingDomainLimits.maximumImportedDiagnostics {
                        rejected.append(TrainingImportedRecordRejection(
                            reason: .invalidCoverage,
                            stableKey: record.identity.stableKey
                        ))
                    }
                    continue
                }
                records.append(record)
                projections.append(TrainingImportedWorkoutProjection(
                    record: record,
                    healthState: input.healthState
                ))
            case .skipped(let rejection):
                rejectedRowCount += 1
                if rejected.count < TrainingDomainLimits.maximumImportedDiagnostics {
                    rejected.append(rejection)
                }
            }
        }

        // Do not walk an attacker-controlled tail merely to count it. The
        // bounded input contract reports the omitted suffix as truncated
        // evidence and keeps one aggregate diagnostic at most.
        let uninspectedRowCount = inputs.count - inspectedRowCount
        if uninspectedRowCount > 0 {
            rejectedRowCount += uninspectedRowCount
            truncatedRowCount += uninspectedRowCount
            if rejected.count < TrainingDomainLimits.maximumImportedDiagnostics {
                rejected.append(TrainingImportedRecordRejection(
                    reason: .invalidImportedSource,
                    stableKey: nil
                ))
            }
        }

        let mustDowngradeCompleteQuery = queryState == .imported &&
            (queryCoverage.kind != .complete || rejectedRowCount > 0 || inputEvidenceIsIncomplete)
        let effectiveQueryState: TrainingSourceState
        if mustDowngradeCompleteQuery {
            effectiveQueryState = queryCoverage.kind == .unavailable ? .unavailable : .partial
        } else {
            effectiveQueryState = queryState
        }
        let effectiveQueryCoverage: TrainingCoverage
        if mustDowngradeCompleteQuery && queryCoverage.kind == .complete {
            effectiveQueryCoverage = try TrainingCoverage(
                kind: .partial,
                lowerBound: queryCoverage.lowerBound,
                upperBound: queryCoverage.upperBound,
                now: now
            )
        } else {
            effectiveQueryCoverage = queryCoverage
        }

        let snapshot = try TrainingImportedHistorySnapshot(
            records: records,
            queryState: effectiveQueryState,
            queryCoverage: effectiveQueryCoverage,
            rejectedRowCount: rejectedRowCount,
            truncatedRowCount: truncatedRowCount,
            rejectedRows: rejected,
            now: now
        )
        return TrainingImportedProjectionResult(
            snapshot: snapshot,
            records: projections,
            rejectedRows: rejected
        )
    }

    private static func recordCoverage(for input: TrainingImportedWorkoutInput) -> TrainingCoverage? {
        switch input.healthState {
        case .observed:
            return try? TrainingCoverage(kind: .complete, lowerBound: input.startedAt, upperBound: input.endedAt, now: input.endedAt)
        case .unavailable, .permissionRequired, .readIndeterminate:
            return try? TrainingCoverage(kind: .unavailable, now: input.endedAt)
        case .partial, .stale, .conflict, .error:
            return try? TrainingCoverage(kind: .partial, lowerBound: input.startedAt, upperBound: input.endedAt, now: input.endedAt)
        }
    }

    private struct ImportedBuild {
        let records: [TrainingImportedWorkoutProjection]
        let rejectedRows: [TrainingImportedRecordRejection]
        let rejectedRowCount: Int
        let truncatedRowCount: Int
        let conflictEvidence: [TrainingImportedConflictEvidence]
    }

    private static func projectImported(_ snapshot: TrainingImportedHistorySnapshot?) -> ImportedBuild {
        guard let snapshot else {
            return ImportedBuild(
                records: [],
                rejectedRows: [],
                rejectedRowCount: 0,
                truncatedRowCount: 0,
                conflictEvidence: []
            )
        }

        // Build connected identity components so an old UUID-only observation,
        // an expanded UUID observation, and a UUID+sync-ID observation are one
        // source row. Every component is processed in deterministic order.
        let indexed = snapshot.records.sorted(by: importedRecordOrder)
        var parents: [Int] = []
        var tokenOwners: [String: Int] = [:]
        var grouped: [Int: [TrainingImportedHistoryRecord]] = [:]
        func root(_ index: Int) -> Int {
            guard parents[index] != index else { return index }
            let compressed = root(parents[index])
            parents[index] = compressed
            return compressed
        }
        func union(_ lhs: Int, _ rhs: Int) -> Int {
            let left = root(lhs)
            let right = root(rhs)
            guard left != right else { return left }
            let winner = min(left, right)
            let loser = max(left, right)
            parents[loser] = winner
            return winner
        }
        for record in indexed {
            // A stable key can contain a composite identity, so a row may
            // bridge more than one previously seen component. Sort both the
            // tokens and their owners before unioning; Set iteration order
            // must never decide which component survives or which rows are
            // later emitted.
            let tokens = ((try? TrainingImportedWorkoutIdentity.stableKeyTokens(record.id)) ?? []).sorted()
            let existingOwners = tokens.compactMap { tokenOwners[$0] }.map(root)
            let group: Int
            if let firstOwner = existingOwners.min() {
                group = firstOwner
                for owner in existingOwners where owner != group {
                    _ = union(group, owner)
                }
            } else {
                group = parents.count
                parents.append(group)
            }
            let resolvedGroup = root(group)
            grouped[resolvedGroup, default: []].append(record)
            for token in tokens {
                tokenOwners[token] = resolvedGroup
            }
        }
        var resolvedGroups: [Int: [TrainingImportedHistoryRecord]] = [:]
        for (group, records) in grouped {
            resolvedGroups[root(group), default: []].append(contentsOf: records)
        }

        var records: [TrainingImportedWorkoutProjection] = []
        let rejected: [TrainingImportedRecordRejection] = snapshot.rejectedRows
        let rejectedRowCount = snapshot.rejectedRowCount
        let truncatedRowCount = snapshot.truncatedRowCount
        var conflictEvidence = snapshot.conflictEvidence
        records.reserveCapacity(resolvedGroups.count)
        for (_, group) in resolvedGroups.sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted(by: importedRecordOrder)
            var uniquePayloadRecords: [TrainingImportedHistoryRecord] = []
            var seenPayloads = Set<String>()
            for record in ordered {
                let payload = recordPayloadFingerprint(record)
                guard seenPayloads.insert(payload).inserted else {
                    // An exact duplicate is harmless replayed source data. It
                    // is removed deterministically and must not downgrade an
                    // otherwise complete query or inflate rejection counts.
                    continue
                }
                uniquePayloadRecords.append(record)
            }

            guard let winner = uniquePayloadRecords.first else { continue }
            let aggregateIdentity = mergedIdentity(for: ordered, preferred: winner.identity)
            let resolvedWinner = aggregateIdentity.flatMap {
                replacingIdentity(winner, with: $0)
            } ?? winner
            let sameRevisionRecords = uniquePayloadRecords.filter {
                $0.identity.revision == winner.identity.revision
            }
            let sameRevisionPayloads = Set(sameRevisionRecords.map(recordPayloadFingerprint))
            let sameRevisionConflict = sameRevisionPayloads.count > 1
            let projectedRecord: TrainingImportedHistoryRecord
            let identityConflict = aggregateIdentity == nil
            if (sameRevisionConflict || identityConflict),
               let conflict = makeConflictRecord(resolvedWinner) {
                projectedRecord = conflict
                if conflictEvidence.count < TrainingDomainLimits.maximumImportedConflictEvidence {
                    let conflictRecords = sameRevisionRecords.isEmpty ? uniquePayloadRecords : sameRevisionRecords
                    let fingerprints = conflictRecords.map(recordPayloadFingerprint).sorted()
                    let conflictKey = (try? TrainingImportedWorkoutIdentity.canonicalStableKey(
                        from: ordered.map(\.id)
                    )) ?? resolvedWinner.id
                    conflictEvidence.append(TrainingImportedConflictEvidence(
                        stableKey: conflictKey,
                        payloadFingerprints: fingerprints,
                        conflictingRecordCount: max(conflictRecords.count, 2)
                    ))
                }
            } else {
                projectedRecord = resolvedWinner
            }
            records.append(TrainingImportedWorkoutProjection(
                record: projectedRecord,
                healthState: healthState(for: projectedRecord)
            ))
        }
        records.sort(by: importedProjectionOrder)
        return ImportedBuild(
            records: records,
            rejectedRows: rejected,
            rejectedRowCount: rejectedRowCount,
            truncatedRowCount: truncatedRowCount,
            conflictEvidence: conflictEvidence
        )
    }

    private static func healthState(for record: TrainingImportedHistoryRecord) -> TrainingImportedHealthState {
        switch record.sourceState {
        case .imported: .observed
        case .partial: .partial
        case .stale: .stale
        case .conflict: .conflict
        case .unavailable: .unavailable
        case .readIndeterminate: .readIndeterminate
        case .error: .error
        case .local, .mixed: .error
        }
    }

    private static func importedRecordOrder(_ lhs: TrainingImportedHistoryRecord, _ rhs: TrainingImportedHistoryRecord) -> Bool {
        switch (lhs.identity.revision.numericValue, rhs.identity.revision.numericValue) {
        case let (.some(left), .some(right)) where left != right:
            return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        if lhs.endedAt != rhs.endedAt { return lhs.endedAt < rhs.endedAt }
        if lhs.durationSeconds != rhs.durationSeconds { return lhs.durationSeconds < rhs.durationSeconds }
        let leftAliasCount = lhs.identity.aliasKeys.count
        let rightAliasCount = rhs.identity.aliasKeys.count
        if leftAliasCount != rightAliasCount { return leftAliasCount > rightAliasCount }
        let leftPayload = recordPayloadFingerprint(lhs)
        let rightPayload = recordPayloadFingerprint(rhs)
        if leftPayload != rightPayload { return leftPayload < rightPayload }
        return lhs.id < rhs.id
    }

    private static func recordPayloadFingerprint(_ record: TrainingImportedHistoryRecord) -> String {
        struct Payload: Encodable {
            let activityTypeRawValue: Int
            let startedAt: Date
            let endedAt: Date
            let durationSeconds: TimeInterval
            let activeEnergyKilocalories: Double?
            let sourceState: TrainingSourceState
            let coverage: TrainingCoverage
            let provenance: TrainingImportedWorkoutProvenance?
            let qualification: TrainingSourceQualification?
        }
        let payload = Payload(
            activityTypeRawValue: record.activityTypeRawValue,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            activeEnergyKilocalories: record.activeEnergyKilocalories,
            sourceState: record.sourceState,
            coverage: record.coverage,
            provenance: record.provenance,
            qualification: record.provenance?.qualification
        )
        guard let data = try? TrainingDateCoding.makeEncoder().encode(payload) else {
            return "activity:\(record.activityTypeRawValue)|start:\(record.startedAt.timeIntervalSinceReferenceDate)|end:\(record.endedAt.timeIntervalSinceReferenceDate)|duration:\(record.durationSeconds)|state:\(record.sourceState.rawValue)"
        }
        return TrainingFingerprint.hex(data: data)
    }

    private static func makeConflictRecord(_ record: TrainingImportedHistoryRecord) -> TrainingImportedHistoryRecord? {
        let conflictCoverage = record.coverage.kind == .partial
            ? record.coverage
            : try? TrainingCoverage(
                kind: .partial,
                lowerBound: record.startedAt,
                upperBound: record.endedAt,
                now: record.endedAt
            )
        guard let conflictCoverage else { return nil }
        return try? TrainingImportedHistoryRecord(
            identity: record.identity,
            activityTypeRawValue: record.activityTypeRawValue,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            activeEnergyKilocalories: record.activeEnergyKilocalories,
            sourceState: .conflict,
            coverage: conflictCoverage,
            provenance: record.provenance,
            now: record.endedAt
        )
    }

    private static func replacingIdentity(
        _ record: TrainingImportedHistoryRecord,
        with identity: TrainingImportedWorkoutIdentity
    ) -> TrainingImportedHistoryRecord? {
        guard record.identity != identity else { return record }
        return try? TrainingImportedHistoryRecord(
            identity: identity,
            activityTypeRawValue: record.activityTypeRawValue,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            activeEnergyKilocalories: record.activeEnergyKilocalories,
            sourceState: record.sourceState,
            coverage: record.coverage,
            provenance: record.provenance,
            now: record.endedAt
        )
    }

    private static func mergedIdentity(
        for records: [TrainingImportedHistoryRecord],
        preferred: TrainingImportedWorkoutIdentity
    ) -> TrainingImportedWorkoutIdentity? {
        var uuids = Set<UUID>()
        var syncIdentifiers = Set<String>()
        for record in records {
            uuids.insert(record.identity.uuid)
            uuids.formUnion(record.identity.aliases)
            if let syncIdentifier = record.identity.syncIdentifier {
                syncIdentifiers.insert(syncIdentifier)
            }
        }
        guard !uuids.isEmpty,
              uuids.count <= TrainingDomainLimits.maximumImportedAliases + 1,
              syncIdentifiers.count <= 1 else {
            return nil
        }
        let sortedUUIDs = uuids.sorted { $0.uuidString < $1.uuidString }
        let primary = sortedUUIDs.contains(preferred.uuid) ? preferred.uuid : sortedUUIDs[0]
        let aliases = sortedUUIDs.filter { $0 != primary }
        let syncIdentifier = syncIdentifiers.first
        let revision = preferred.syncIdentifier == nil && syncIdentifier != nil
            ? records.first(where: { $0.identity.syncIdentifier != nil })?.identity.revision ?? preferred.revision
            : preferred.revision
        return try? TrainingImportedWorkoutIdentity(
            uuid: primary,
            syncIdentifier: syncIdentifier,
            aliases: aliases,
            revision: revision
        )
    }

    private static func importedProjectionOrder(_ lhs: TrainingImportedWorkoutProjection, _ rhs: TrainingImportedWorkoutProjection) -> Bool {
        if lhs.record.startedAt != rhs.record.startedAt { return lhs.record.startedAt > rhs.record.startedAt }
        if lhs.record.endedAt != rhs.record.endedAt { return lhs.record.endedAt > rhs.record.endedAt }
        return lhs.record.id < rhs.record.id
    }

    private static func localSessionOrder(_ lhs: TrainingSession, _ rhs: TrainingSession) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        if lhs.endedAt != rhs.endedAt { return (lhs.endedAt ?? .distantPast) > (rhs.endedAt ?? .distantPast) }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func combinedEntries(
        local: [TrainingHistoryItem],
        imported: [TrainingImportedWorkoutProjection]
    ) -> [TrainingHistoryEntry] {
        let localEntries = local.map(TrainingHistoryEntry.local)
        let importedEntries = imported.map { TrainingHistoryEntry.imported($0.record) }
        return (localEntries + importedEntries).sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            let leftRank = lhs.sourceState == .local ? 0 : 1
            let rightRank = rhs.sourceState == .local ? 0 : 1
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.id < rhs.id
        }
    }

    private struct LinkBuild {
        let states: [TrainingLinkState]
        let linkedLocalIDs: Set<TrainingRecordID>
        let linkedImportedKeys: Set<String>
    }

    private static func buildLinks(
        sessions: [TrainingSession],
        imported: [TrainingImportedWorkoutProjection],
        queryState: TrainingImportQueryState,
        queryCoverage: TrainingCoverage?
    ) -> LinkBuild {
        var importedByIdentityKey: [String: [TrainingImportedWorkoutProjection]] = [:]
        for item in imported {
            for identityKey in item.identityKeys {
                let tokens = (try? TrainingImportedWorkoutIdentity.stableKeyTokens(identityKey)) ?? []
                for token in tokens {
                    importedByIdentityKey[token, default: []].append(item)
                }
            }
        }
        var matchesByLocalID: [TrainingRecordID: [TrainingImportedWorkoutProjection]] = [:]
        var ownersByImportedID: [String: Set<TrainingRecordID>] = [:]
        for session in sessions {
            guard let importedKey = session.importedRecordKey,
                  let sessionTokens = try? TrainingImportedWorkoutIdentity.stableKeyTokens(importedKey) else {
                continue
            }
            let matches = Set(sessionTokens.flatMap { importedByIdentityKey[$0] ?? [] })
                .sorted { $0.record.id < $1.record.id }
            matchesByLocalID[session.id] = matches
            for match in matches {
                ownersByImportedID[match.record.id, default: []].insert(session.id)
            }
        }
        var states: [TrainingLinkState] = []
        var linkedLocalIDs = Set<TrainingRecordID>()
        var linkedImportedKeys = Set<String>()
        states.reserveCapacity(sessions.count)

        for session in sessions {
            let localKey = "local:\(session.id.rawValue)"
            guard let importedKey = session.importedRecordKey else {
                states.append(TrainingLinkState(
                    localID: session.id,
                    localIdentityKey: localKey,
                    importedRecordKey: nil,
                    importedIdentityKeys: [],
                    status: .unlinked
                ))
                continue
            }
            guard TrainingImportedWorkoutIdentity.isValidStableKey(importedKey) else {
                states.append(TrainingLinkState(
                    localID: session.id,
                    localIdentityKey: localKey,
                    importedRecordKey: importedKey,
                    importedIdentityKeys: [],
                    status: .invalidImportedKey
                ))
                continue
            }
            let matches = matchesByLocalID[session.id] ?? []
            if matches.count == 1, let match = matches.first {
                let ownerCount = ownersByImportedID[match.record.id]?.count ?? 0
                if ownerCount == 1 {
                    linkedLocalIDs.insert(session.id)
                    linkedImportedKeys.insert(match.record.id)
                }
                states.append(TrainingLinkState(
                    localID: session.id,
                    localIdentityKey: localKey,
                    importedRecordKey: importedKey,
                    importedIdentityKeys: match.identityKeys,
                    status: ownerCount == 1 ? .linked : .conflict
                ))
            } else if matches.count > 1 {
                let identityKeys = Array(Set(matches.flatMap(\.identityKeys))).sorted()
                states.append(TrainingLinkState(
                    localID: session.id,
                    localIdentityKey: localKey,
                    importedRecordKey: importedKey,
                    importedIdentityKeys: identityKeys,
                    status: .ambiguousImported
                ))
            } else {
                let isCoveredCompleteQuery = queryState == .imported &&
                    queryCoverage?.kind == .complete &&
                    queryCoverage?.contains(
                        startedAt: session.startedAt,
                        endedAt: session.endedAt ?? session.startedAt
                    ) == true
                states.append(TrainingLinkState(
                    localID: session.id,
                    localIdentityKey: localKey,
                    importedRecordKey: importedKey,
                    importedIdentityKeys: [],
                    status: queryState == .noSource ? .noImportedSource :
                        (isCoveredCompleteQuery ? .missingImported : .unavailable)
                ))
            }
        }
        return LinkBuild(states: states, linkedLocalIDs: linkedLocalIDs, linkedImportedKeys: linkedImportedKeys)
    }

    private struct DuplicateBuild {
        let candidates: [TrainingDuplicateCandidate]
        let comparisonCount: Int
        let wasBounded: Bool
    }

    private struct ImportedIndexItem {
        let projection: TrainingImportedWorkoutProjection
    }

    private static func buildDuplicateCandidates(
        sessions: [TrainingSession],
        imported: [TrainingImportedWorkoutProjection],
        linkedLocalIDs: Set<TrainingRecordID>,
        linkedImportedKeys: Set<String>
    ) -> DuplicateBuild {
        var index: [TrainingActivityKind: [ImportedIndexItem]] = [:]
        for item in imported {
            guard let kind = item.activityKind, !linkedImportedKeys.contains(item.record.id) else { continue }
            index[kind, default: []].append(ImportedIndexItem(projection: item))
        }
        for kind in index.keys {
            index[kind]?.sort {
                if $0.projection.record.startedAt != $1.projection.record.startedAt {
                    return $0.projection.record.startedAt < $1.projection.record.startedAt
                }
                return $0.projection.record.id < $1.projection.record.id
            }
        }

        var candidates: [TrainingDuplicateCandidate] = []
        candidates.reserveCapacity(min(maximumDuplicateCandidates, sessions.count))
        var comparisonCount = 0
        var wasBounded = false

        for session in sessions {
            guard session.status != .discarded,
                  !linkedLocalIDs.contains(session.id),
                  session.importedRecordKey == nil,
                  let duration = session.recordedDuration,
                  duration.isFinite,
                  duration > 0,
                  let bucket = index[session.activityKind] else { continue }
            let lower = session.startedAt.addingTimeInterval(-duplicateStartToleranceSeconds)
            let upper = session.startedAt.addingTimeInterval(duplicateStartToleranceSeconds)
            let startIndex = lowerBound(bucket) { $0.projection.record.startedAt < lower }
            let endIndex = lowerBound(bucket) { $0.projection.record.startedAt <= upper }
            var localCandidates = 0
            var localComparisons = 0
            for item in bucket[startIndex..<endIndex] {
                guard localComparisons < maximumDuplicateComparisonsPerLocal else {
                    wasBounded = true
                    break
                }
                localComparisons += 1
                comparisonCount += 1
                let record = item.projection.record
                guard !linkedImportedKeys.contains(record.id) else { continue }
                let startDifference = abs(record.startedAt.timeIntervalSince(session.startedAt))
                let durationDifference = abs(record.durationSeconds - duration)
                let durationTolerance = max(60, duration * 0.10)
                guard startDifference <= duplicateStartToleranceSeconds,
                      durationDifference <= durationTolerance else { continue }
                candidates.append(TrainingDuplicateCandidate(
                    localID: session.id,
                    localIdentityKey: "local:\(session.id.rawValue)",
                    importedRecordKey: record.id,
                    importedIdentityKeys: item.projection.identityKeys,
                    importedActivityTypeRawValue: record.activityTypeRawValue,
                    startDifferenceSeconds: startDifference,
                    durationDifferenceSeconds: durationDifference
                ))
                localCandidates += 1
                if localCandidates >= maximumDuplicateCandidatesPerLocal || candidates.count >= maximumDuplicateCandidates {
                    wasBounded = true
                    break
                }
            }
            if candidates.count >= maximumDuplicateCandidates { break }
        }

        candidates.sort {
            if $0.localIdentityKey != $1.localIdentityKey { return $0.localIdentityKey < $1.localIdentityKey }
            if $0.startDifferenceSeconds != $1.startDifferenceSeconds { return $0.startDifferenceSeconds < $1.startDifferenceSeconds }
            if $0.durationDifferenceSeconds != $1.durationDifferenceSeconds { return $0.durationDifferenceSeconds < $1.durationDifferenceSeconds }
            return $0.importedRecordKey < $1.importedRecordKey
        }
        return DuplicateBuild(candidates: candidates, comparisonCount: comparisonCount, wasBounded: wasBounded)
    }

    private static func lowerBound(
        _ values: [ImportedIndexItem],
        by predicate: (ImportedIndexItem) -> Bool
    ) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(values[middle]) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func makeStatistics(
        sessions: [TrainingSession],
        calendar: Calendar,
        now: Date
    ) -> TrainingStrengthStatistics {
        let completed = sessions.filter { $0.status == .completed }
        var totalDuration: Double = 0
        var durationOverflowed = false
        var completedSetCount = 0
        var knownVolume: Double = 0
        var hasKnownVolume = false
        var incompleteVolumeSetCount = 0
        var records: [String: PersonalRecordAccumulator] = [:]

        for session in completed {
            if let duration = session.recordedDuration, duration.isFinite, duration >= 0 {
                if let sum = safeAdd(totalDuration, duration) {
                    totalDuration = sum
                } else {
                    durationOverflowed = true
                }
            }
            for exercise in session.exercises {
                var exerciseWorkingVolume: Double = 0
                var hasWorkingVolume = false
                var exerciseVolumeOverflowed = false
                let exerciseKey = exercise.templateExerciseID.map { "template:\($0)" } ??
                    "session:\(session.id.rawValue):exercise:\(exercise.id.rawValue)"
                var accumulator = records[exerciseKey] ?? PersonalRecordAccumulator(
                    key: exerciseKey,
                    name: exercise.name,
                    convention: exercise.loadConvention
                )

                for set in exercise.sets where set.countsAsCompletedSet {
                    completedSetCount += 1
                    guard exercise.loadConvention == .externalTotal,
                          let repetitions = set.actualRepetitions,
                          let load = set.actualLoadKilograms else {
                        incompleteVolumeSetCount += 1
                        continue
                    }
                    let contribution = Double(repetitions) * load
                    guard contribution.isFinite else {
                        incompleteVolumeSetCount += 1
                        exerciseVolumeOverflowed = true
                        continue
                    }
                    if let total = safeAdd(knownVolume, contribution) {
                        knownVolume = total
                        hasKnownVolume = true
                    } else {
                        incompleteVolumeSetCount += 1
                    }
                    if set.kind == .working {
                        if let total = safeAdd(exerciseWorkingVolume, contribution) {
                            exerciseWorkingVolume = total
                            hasWorkingVolume = true
                        } else {
                            exerciseVolumeOverflowed = true
                        }
                    }
                    if let current = accumulator.maximumLoad, current >= load {
                        // Keep the existing deterministic winner.
                    } else {
                        accumulator.maximumLoad = load
                        accumulator.maximumLoadSessionID = session.id
                        accumulator.maximumLoadRecordedAt = session.startedAt
                    }
                }
                if hasWorkingVolume && !exerciseVolumeOverflowed {
                    if let current = accumulator.bestWorkingVolume,
                       current >= exerciseWorkingVolume {
                        // Keep the existing deterministic winner on ties.
                    } else {
                        accumulator.bestWorkingVolume = exerciseWorkingVolume
                        accumulator.bestVolumeSessionID = session.id
                        accumulator.bestVolumeRecordedAt = session.startedAt
                    }
                }
                records[exerciseKey] = accumulator
            }
        }

        let personalRecords = records.values
            .filter { $0.maximumLoad != nil || $0.bestWorkingVolume != nil }
            .map { $0.publicValue }
            .sorted { $0.exerciseIdentityKey < $1.exerciseIdentityKey }

        let volumeCoverage: TrainingCoverageKind
        if completedSetCount == 0 {
            volumeCoverage = .unavailable
        } else if incompleteVolumeSetCount == 0 && hasKnownVolume {
            volumeCoverage = .complete
        } else {
            volumeCoverage = .partial
        }
        let streak = currentStreak(sessions: completed, calendar: calendar, now: now)
        return TrainingStrengthStatistics(
            completedSessionCount: completed.count,
            completedSetCount: completedSetCount,
            totalDurationSeconds: completed.isEmpty || durationOverflowed ? nil : totalDuration,
            durationOverflowed: durationOverflowed,
            knownExternalVolumeKilograms: hasKnownVolume ? knownVolume : nil,
            volumeCoverage: volumeCoverage,
            incompleteVolumeSetCount: incompleteVolumeSetCount,
            personalRecords: personalRecords,
            currentStreakDays: streak,
            calendarTimeZoneIdentifier: calendar.timeZone.identifier
        )
    }

    private struct PersonalRecordAccumulator {
        let key: String
        let name: String
        let convention: TrainingLoadConvention
        var maximumLoad: Double? = nil
        var maximumLoadSessionID: TrainingRecordID? = nil
        var maximumLoadRecordedAt: Date? = nil
        var bestWorkingVolume: Double? = nil
        var bestVolumeSessionID: TrainingRecordID? = nil
        var bestVolumeRecordedAt: Date? = nil

        var publicValue: TrainingPersonalRecord {
            TrainingPersonalRecord(
                exerciseIdentityKey: key,
                exerciseName: name,
                loadConvention: convention,
                maximumExternalLoadKilograms: maximumLoad,
                maximumLoadSessionID: maximumLoadSessionID,
                maximumLoadRecordedAt: maximumLoadRecordedAt,
                bestWorkingSetVolumeKilograms: bestWorkingVolume,
                bestVolumeSessionID: bestVolumeSessionID,
                bestVolumeRecordedAt: bestVolumeRecordedAt
            )
        }
    }

    private static func safeAdd(_ lhs: Double, _ rhs: Double) -> Double? {
        let result = lhs + rhs
        return result.isFinite ? result : nil
    }

    private static func currentStreak(sessions: [TrainingSession], calendar: Calendar, now: Date) -> Int {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return 0 }
        let days = Set(sessions.map { calendar.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
        var cursor = days.contains(today) ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor), previous != cursor else { break }
            cursor = previous
        }
        return count
    }
}
