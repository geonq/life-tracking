import Foundation

public enum HealthKitAnchorStoreError: Error, Equatable, Sendable {
    case persistenceFailed
    case invalidMetric
    case invalidProjection
    case concurrentModification
    case loadFailure
    case protectedDataUnavailable
}

public enum HealthKitAnchorStoreLoadFailure: String, Codable, Equatable, Sendable {
    case malformedData = "malformed_data"
    case protectedDataUnavailable = "protected_data_unavailable"
    case unreadable = "unreadable"
}

public struct HealthKitObservationConflict: Codable, Equatable, Sendable {
    public let metric: HealthKitMetricID
    public let identity: HealthKitSampleIdentity
    public let existing: HealthKitObservation
    public let incoming: HealthKitObservation

    public init(metric: HealthKitMetricID, identity: HealthKitSampleIdentity, existing: HealthKitObservation, incoming: HealthKitObservation) {
        self.metric = metric
        self.identity = identity
        self.existing = existing
        self.incoming = incoming
    }

    private enum CodingKeys: String, CodingKey { case metric, identity, existing, incoming }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["metric", "identity", "existing", "incoming"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            metric: try container.decode(HealthKitMetricID.self, forKey: .metric),
            identity: try container.decode(HealthKitSampleIdentity.self, forKey: .identity),
            existing: try container.decode(HealthKitObservation.self, forKey: .existing),
            incoming: try container.decode(HealthKitObservation.self, forKey: .incoming)
        )
    }
}

public struct HealthKitMetricProjection: Codable, Equatable, Sendable {
    public let metric: HealthKitMetricID
    public let observations: [HealthKitObservation]
    public let tombstones: [HealthKitDeletionTombstone]
    public let sourceIndex: [String: HealthKitSourceMatch]
    public let conflicts: [HealthKitObservationConflict]
    public let quarantine: HealthKitQuarantineState
    public let anchorArchive: String?
    public let lastCommittedAt: Date?
    public let lastObservedAt: Date?
    public let syncState: HealthKitSyncState

    public init(
        metric: HealthKitMetricID,
        observations: [HealthKitObservation] = [],
        tombstones: [HealthKitDeletionTombstone] = [],
        sourceIndex: [String: HealthKitSourceMatch] = [:],
        conflicts: [HealthKitObservationConflict] = [],
        quarantine: HealthKitQuarantineState = .empty,
        anchorArchive: String? = nil,
        lastCommittedAt: Date? = nil,
        lastObservedAt: Date? = nil,
        syncState: HealthKitSyncState = .neverSynced
    ) throws {
        guard observations.count <= HealthKitSafetyLimits.maxProjectionItems,
              tombstones.count <= HealthKitSafetyLimits.maxProjectionItems,
              sourceIndex.count <= HealthKitSafetyLimits.maxSourceIndexItems,
              conflicts.count <= HealthKitSafetyLimits.maxConflictItems,
              quarantine.isWithinSafetyBounds,
              anchorArchive == nil || anchorArchive!.count <= HealthKitSafetyLimits.maxAnchorArchiveCharacters else {
            throw HealthKitAnchorStoreError.invalidProjection
        }
        guard sourceIndex.keys.allSatisfy(HealthKitSourceIndexKey.isValid) else {
            throw HealthKitAnchorStoreError.invalidProjection
        }
        let rebuiltSourceIndex = try HealthKitSourceIndex.build(observations: observations)
        guard observations.allSatisfy({ $0.metric == metric }),
              tombstones.allSatisfy({ $0.metric == metric }),
              conflicts.allSatisfy({
                  $0.metric == metric &&
                  $0.identity.isWithinSafetyBounds &&
                  $0.existing.metric == metric &&
                  $0.existing.identity.isWithinSafetyBounds &&
                  $0.incoming.metric == metric &&
                  $0.incoming.identity.isWithinSafetyBounds &&
                  $0.existing.provenance.matchesCanonicalRegistry &&
                  $0.incoming.provenance.matchesCanonicalRegistry
              }),
              observations.allSatisfy({
                  $0.identity.isWithinSafetyBounds &&
                  $0.provenance.matchesCanonicalRegistry &&
                  ($0.identity.syncIdentifier == nil || $0.identity.revision.numericValue != nil)
              }),
              tombstones.allSatisfy({
                  $0.identity.isWithinSafetyBounds &&
                  ($0.identity.syncIdentifier == nil || $0.identity.revision.numericValue != nil)
              }) else {
            throw HealthKitAnchorStoreError.invalidProjection
        }
        let hasConflict = !conflicts.isEmpty || rebuiltSourceIndex.values.contains(.conflict)
        let normalizedSyncState: HealthKitSyncState
        if syncState == .fullResyncRequired {
            normalizedSyncState = .fullResyncRequired
        } else if hasConflict {
            normalizedSyncState = .conflict
        } else {
            normalizedSyncState = syncState
        }
        let derivedLastObservedAt = observations.map(\.endDate).max()
        if let lastObservedAt {
            guard lastObservedAt.timeIntervalSinceReferenceDate.isFinite,
                  derivedLastObservedAt == lastObservedAt else {
                throw HealthKitAnchorStoreError.invalidProjection
            }
        }
        if let lastCommittedAt {
            guard lastCommittedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw HealthKitAnchorStoreError.invalidProjection
            }
        } else {
            guard syncState == .neverSynced && !hasConflict else {
                throw HealthKitAnchorStoreError.invalidProjection
            }
        }
        self.metric = metric
        self.observations = observations
        self.tombstones = tombstones
        self.sourceIndex = rebuiltSourceIndex
        self.conflicts = conflicts
        self.quarantine = quarantine
        self.anchorArchive = anchorArchive
        self.lastCommittedAt = lastCommittedAt
        self.lastObservedAt = derivedLastObservedAt
        self.syncState = normalizedSyncState
    }

    /// The main JSON envelope retains the raw archive string even when it is
    /// malformed. This lets the loader expose a bounded full-resync state
    /// while leaving valid observations untouched.
    public var decodedAnchor: HealthKitOpaqueAnchor? {
        guard let anchorArchive,
              let data = Data(base64Encoded: anchorArchive),
              let anchor = try? HealthKitOpaqueAnchor(archivedData: data) else { return nil }
        return anchor
    }

    public var requiresFullResync: Bool {
        guard anchorArchive != nil else { return false }
        return decodedAnchor == nil
    }

    public var hasValidAnchor: Bool { decodedAnchor != nil }

    private enum CodingKeys: String, CodingKey {
        case metric, observations, tombstones, sourceIndex, conflicts, quarantine, anchorArchive, lastCommittedAt, lastObservedAt, syncState
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["metric", "observations", "tombstones", "sourceIndex", "conflicts", "quarantine", "anchorArchive", "lastCommittedAt", "lastObservedAt", "syncState"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metric = try container.decode(HealthKitMetricID.self, forKey: .metric)
        let observations = try container.decode([HealthKitObservation].self, forKey: .observations)
        let tombstones = try container.decode([HealthKitDeletionTombstone].self, forKey: .tombstones)
        let sourceIndex = try container.decode([String: HealthKitSourceMatch].self, forKey: .sourceIndex)
        let conflicts = try container.decode([HealthKitObservationConflict].self, forKey: .conflicts)
        let quarantine = try decodeStrictOptional(HealthKitQuarantineState.self, forKey: .quarantine, from: container) ?? .empty
        let anchorArchive = try decodeStrictOptional(String.self, forKey: .anchorArchive, from: container)
        let lastCommittedAt = try decodeStrictOptional(Date.self, forKey: .lastCommittedAt, from: container)
        let lastObservedAt = try decodeStrictOptional(Date.self, forKey: .lastObservedAt, from: container)
        let syncState = try container.decode(HealthKitSyncState.self, forKey: .syncState)

        let projection = try HealthKitMetricProjection(
            metric: metric,
            observations: observations,
            tombstones: tombstones,
            sourceIndex: sourceIndex,
            conflicts: conflicts,
            quarantine: quarantine,
            anchorArchive: anchorArchive,
            lastCommittedAt: lastCommittedAt,
            lastObservedAt: lastObservedAt,
            syncState: syncState
        )
        guard projection.sourceIndex == sourceIndex else { throw HealthKitAnchorStoreError.invalidProjection }
        self = projection
    }
}

public struct HealthKitAnchorStoreEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let projections: [HealthKitMetricProjection]

    public init(projections: [HealthKitMetricProjection] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projections = projections
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, projections }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["schemaVersion", "projections"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else { throw HealthKitAnchorStoreError.invalidProjection }
        let projections = try container.decode([HealthKitMetricProjection].self, forKey: .projections)
        guard projections.count <= HealthKitMetricID.allCases.count,
              Set(projections.map(\.metric)).count == projections.count else { throw HealthKitAnchorStoreError.invalidProjection }
        self.schemaVersion = schemaVersion
        self.projections = projections
    }
}

public struct HealthKitStoredMetricState: Equatable, Sendable {
    public let metric: HealthKitMetricID
    public let observations: [HealthKitObservation]
    public let tombstones: [HealthKitDeletionTombstone]
    public let sourceIndex: [String: HealthKitSourceMatch]
    public let conflicts: [HealthKitObservationConflict]
    public let quarantine: HealthKitQuarantineState
    public let anchor: HealthKitOpaqueAnchor?
    public let anchorArchive: String?
    public let lastCommittedAt: Date?
    public let lastObservedAt: Date?
    public let syncState: HealthKitSyncState

    public init(projection: HealthKitMetricProjection) {
        self.metric = projection.metric
        self.observations = projection.observations
        self.tombstones = projection.tombstones
        self.sourceIndex = projection.sourceIndex
        self.conflicts = projection.conflicts
        self.quarantine = projection.quarantine
        self.anchor = projection.decodedAnchor
        self.anchorArchive = projection.anchorArchive
        self.lastCommittedAt = projection.lastCommittedAt
        self.lastObservedAt = projection.lastObservedAt
        self.syncState = projection.requiresFullResync ? .fullResyncRequired : projection.syncState
    }

    private init(emptyMetric: HealthKitMetricID) {
        self.metric = emptyMetric
        self.observations = []
        self.tombstones = []
        self.sourceIndex = [:]
        self.conflicts = []
        self.quarantine = .empty
        self.anchor = nil
        self.anchorArchive = nil
        self.lastCommittedAt = nil
        self.lastObservedAt = nil
        self.syncState = .neverSynced
    }

    public static func empty(for metric: HealthKitMetricID) -> HealthKitStoredMetricState {
        HealthKitStoredMetricState(emptyMetric: metric)
    }
}

/// Actor-isolated durable HealthKit projection and anchor store. A commit
/// writes observations, deletions, source-index updates, and the new opaque
/// anchor in one atomic envelope. If writing fails, the previous anchor and
/// projection remain the only visible state.
public actor HealthKitAnchorStore {
    public let persistenceURL: URL?

    private var envelope: HealthKitAnchorStoreEnvelope
    private var loadFailure: Error?
    private var loadFailureKind: HealthKitAnchorStoreLoadFailure?

    public init(persistenceURL: URL?, fileManager: FileManager = .default, now: Date = .now) {
        self.persistenceURL = persistenceURL
        self.envelope = HealthKitAnchorStoreEnvelope()
        self.loadFailure = nil
        self.loadFailureKind = nil
        if let persistenceURL {
            do {
                let data = try Data(contentsOf: persistenceURL)
                let decoded = try Self.decodeEnvelope(data, now: now)
                let repaired = try Self.markMalformedAnchors(decoded, now: now)
                self.envelope = repaired.envelope
                if repaired.hadMalformedAnchor {
                    // Keep valid observations and preserve the raw malformed
                    // archive, but durably mark the projection for a bounded
                    // full resync. The quarantined copy is diagnostic only.
                    Self.quarantine(url: persistenceURL, fileManager: fileManager, suffix: "anchor")
                    do {
                        try Self.persist(repaired.envelope, to: persistenceURL)
                    } catch {
                        self.loadFailure = HealthKitAnchorStoreError.persistenceFailed
                        self.loadFailureKind = .unreadable
                    }
                }
            } catch {
                let failureKind = Self.classifyLoadFailure(error)
                // An absent optional persistence file is the normal first
                // launch state.  Every other read failure, including a
                // protected/locked file whose path may not be visible to
                // FileManager, remains a durable load failure.
                if failureKind != .unreadable || fileManager.fileExists(atPath: persistenceURL.path) {
                    self.loadFailure = HealthKitAnchorStoreError.loadFailure
                    self.loadFailureKind = failureKind
                    if failureKind == .malformedData {
                        Self.quarantine(url: persistenceURL, fileManager: fileManager, suffix: "envelope")
                    }
                }
            }
        }
    }

    public func hasLoadFailure() -> Bool { loadFailure != nil }

    public func loadFailureState() -> HealthKitAnchorStoreLoadFailure? { loadFailureKind }

    public func snapshot(for metric: HealthKitMetricID) -> HealthKitStoredMetricState {
        if let projection = envelope.projections.first(where: { $0.metric == metric }) {
            return HealthKitStoredMetricState(projection: projection)
        }
        return .empty(for: metric)
    }

    /// Explicit operator/user recovery for an unreadable envelope.  Normal
    /// reconciliation is blocked until this is called; no corrupt bytes are
    /// silently treated as an empty truth or overwritten by a commit.
    @discardableResult
    public func resetAfterLoadFailure() throws -> Bool {
        guard loadFailure != nil else { throw HealthKitAnchorStoreError.invalidProjection }
        let next = HealthKitAnchorStoreEnvelope()
        try persist(next)
        envelope = next
        loadFailure = nil
        loadFailureKind = nil
        return true
    }

    /// Replaces the single metric projection only after the complete envelope
    /// is durably written. `nextAnchor == nil` intentionally represents a
    /// successful projection with no anchor (for example a client that cannot
    /// supply one); callers that need incremental sync must retain the old
    /// anchor until an opaque archive is provided.
    @discardableResult
    public func commit(
        metric: HealthKitMetricID,
        observations: [HealthKitObservation],
        tombstones: [HealthKitDeletionTombstone],
        sourceIndex: [String: HealthKitSourceMatch],
        conflicts: [HealthKitObservationConflict] = [],
        quarantine: HealthKitQuarantineState = .empty,
        nextAnchor: HealthKitOpaqueAnchor?,
        syncState: HealthKitSyncState,
        committedAt: Date,
        expectedAnchorArchive: String? = nil,
        expectedAnchorChecked: Bool = false,
        expectedState: HealthKitStoredMetricState? = nil
    ) throws -> HealthKitStoredMetricState {
        guard loadFailure == nil else {
            if loadFailureKind == .protectedDataUnavailable { throw HealthKitAnchorStoreError.protectedDataUnavailable }
            throw HealthKitAnchorStoreError.loadFailure
        }
        guard observations.allSatisfy({ $0.metric == metric }),
              tombstones.allSatisfy({ $0.metric == metric }),
              conflicts.allSatisfy({ $0.metric == metric }),
              observations.count <= HealthKitSafetyLimits.maxProjectionItems,
              tombstones.count <= HealthKitSafetyLimits.maxProjectionItems,
              conflicts.count <= HealthKitSafetyLimits.maxConflictItems,
              quarantine.isWithinSafetyBounds,
              committedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HealthKitAnchorStoreError.invalidProjection
        }

        let current = envelope.projections.first(where: { $0.metric == metric })
        if expectedAnchorChecked, current?.anchorArchive != expectedAnchorArchive {
            throw HealthKitAnchorStoreError.concurrentModification
        }
        if let expectedState {
            let currentState = current.map(HealthKitStoredMetricState.init(projection:)) ?? .empty(for: metric)
            guard currentState == expectedState else {
                throw HealthKitAnchorStoreError.concurrentModification
            }
        }
        let archive = nextAnchor.map { $0.archivedData.base64EncodedString() } ?? current?.anchorArchive
        try Self.validateForCommit(
            metric: metric,
            observations: observations,
            tombstones: tombstones,
            conflicts: conflicts,
            now: committedAt
        )
        let rebuiltSourceIndex = try Self.rebuildSourceIndex(observations: observations)
        guard sourceIndex.keys.allSatisfy(HealthKitSourceIndexKey.isValid) else {
            throw HealthKitAnchorStoreError.invalidProjection
        }
        let projection = try HealthKitMetricProjection(
            metric: metric,
            observations: observations,
            tombstones: tombstones,
            sourceIndex: rebuiltSourceIndex,
            conflicts: conflicts,
            quarantine: quarantine,
            anchorArchive: archive,
            lastCommittedAt: committedAt,
            lastObservedAt: observations.map(\.endDate).max(),
            syncState: syncState
        )
        let projections = envelope.projections.filter { $0.metric != metric } + [projection]
        let nextEnvelope = HealthKitAnchorStoreEnvelope(projections: projections.sorted { $0.metric.rawValue < $1.metric.rawValue })
        try persist(nextEnvelope)
        envelope = nextEnvelope
        loadFailure = nil
        return HealthKitStoredMetricState(projection: projection)
    }

    /// Clears a corrupt anchor after a bounded full resync has been accepted.
    /// The projection itself is retained; only the anchor is reset.
    @discardableResult
    public func clearAnchor(for metric: HealthKitMetricID, committedAt: Date) throws -> HealthKitStoredMetricState {
        guard loadFailure == nil else { throw HealthKitAnchorStoreError.loadFailure }
        let current = snapshot(for: metric)
        let projection = try HealthKitMetricProjection(
            metric: metric,
            observations: current.observations,
            tombstones: current.tombstones,
            sourceIndex: current.sourceIndex,
            conflicts: current.conflicts,
            quarantine: current.quarantine,
            anchorArchive: nil,
            lastCommittedAt: committedAt,
            lastObservedAt: current.lastObservedAt,
            syncState: current.syncState == .conflict ||
                !current.conflicts.isEmpty ||
                current.sourceIndex.values.contains(.conflict) ? .conflict : .neverSynced
        )
        let nextEnvelope = HealthKitAnchorStoreEnvelope(
            projections: (envelope.projections.filter { $0.metric != metric } + [projection])
                .sorted { $0.metric.rawValue < $1.metric.rawValue }
        )
        try persist(nextEnvelope)
        envelope = nextEnvelope
        loadFailure = nil
        return HealthKitStoredMetricState(projection: projection)
    }

    /// Records that the adapter could not unarchive the opaque anchor.  The
    /// original archive remains in the envelope for diagnosis; the next
    /// reconciliation must use an unanchored full read until `clearAnchor` is
    /// explicitly accepted after that read.
    @discardableResult
    public func markFullResyncRequired(for metric: HealthKitMetricID, committedAt: Date) throws -> HealthKitStoredMetricState {
        guard loadFailure == nil else { throw HealthKitAnchorStoreError.loadFailure }
        let current = snapshot(for: metric)
        if current.anchorArchive != nil, let persistenceURL {
            // Preserve the archive that the iOS adapter could not unarchive;
            // it is diagnostic input, never replacement truth.
            Self.quarantine(url: persistenceURL, fileManager: .default, suffix: "anchor")
        }
        let projection = try HealthKitMetricProjection(
            metric: metric,
            observations: current.observations,
            tombstones: current.tombstones,
            sourceIndex: current.sourceIndex,
            conflicts: current.conflicts,
            quarantine: current.quarantine,
            anchorArchive: envelope.projections.first(where: { $0.metric == metric })?.anchorArchive,
            lastCommittedAt: committedAt,
            lastObservedAt: current.lastObservedAt,
            syncState: .fullResyncRequired
        )
        let nextEnvelope = HealthKitAnchorStoreEnvelope(
            projections: (envelope.projections.filter { $0.metric != metric } + [projection])
                .sorted { $0.metric.rawValue < $1.metric.rawValue }
        )
        try persist(nextEnvelope)
        envelope = nextEnvelope
        return HealthKitStoredMetricState(projection: projection)
    }

    private func persist(_ value: HealthKitAnchorStoreEnvelope) throws {
        guard let persistenceURL else { return }
        try Self.persist(value, to: persistenceURL)
    }

    private static func persist(_ value: HealthKitAnchorStoreEnvelope, to persistenceURL: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= HealthKitSafetyLimits.maxEnvelopeBytes else {
                throw HealthKitAnchorStoreError.persistenceFailed
            }
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw HealthKitAnchorStoreError.persistenceFailed
        }
    }

    private static func decodeEnvelope(_ data: Data, now: Date) throws -> HealthKitAnchorStoreEnvelope {
        guard data.count <= HealthKitSafetyLimits.maxEnvelopeBytes else {
            throw HealthKitAnchorStoreError.invalidProjection
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(HealthKitAnchorStoreEnvelope.self, from: data)
    }

    private static func markMalformedAnchors(_ envelope: HealthKitAnchorStoreEnvelope, now: Date) throws -> (envelope: HealthKitAnchorStoreEnvelope, hadMalformedAnchor: Bool) {
        var malformed = false
        var projections: [HealthKitMetricProjection] = []
        projections.reserveCapacity(envelope.projections.count)
        for projection in envelope.projections {
            guard projection.requiresFullResync, projection.syncState != .fullResyncRequired else {
                projections.append(projection)
                continue
            }
            malformed = true
            projections.append(try HealthKitMetricProjection(
                metric: projection.metric,
                observations: projection.observations,
                tombstones: projection.tombstones,
                sourceIndex: projection.sourceIndex,
                conflicts: projection.conflicts,
                quarantine: projection.quarantine,
                anchorArchive: projection.anchorArchive,
                lastCommittedAt: projection.lastCommittedAt ?? now,
                lastObservedAt: projection.lastObservedAt,
                syncState: .fullResyncRequired
            ))
        }
        return (HealthKitAnchorStoreEnvelope(projections: projections), malformed)
    }

    private static func validateForCommit(
        metric: HealthKitMetricID,
        observations: [HealthKitObservation],
        tombstones: [HealthKitDeletionTombstone],
        conflicts: [HealthKitObservationConflict],
        now: Date
    ) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw HealthKitAnchorStoreError.invalidProjection }
        let tolerance = HealthKitObservation.defaultFutureTolerance
        guard observations.allSatisfy({ observation in
            observation.metric == metric &&
            observation.identity.isWithinSafetyBounds &&
            observation.startDate.timeIntervalSinceReferenceDate.isFinite &&
            observation.endDate.timeIntervalSinceReferenceDate.isFinite &&
            observation.startDate <= observation.endDate &&
            observation.endDate.timeIntervalSince(now) <= tolerance &&
            observation.provenance.matchesCanonicalRegistry &&
            (observation.identity.syncIdentifier == nil || observation.identity.revision.numericValue != nil)
        }), tombstones.allSatisfy({ tombstone in
            tombstone.metric == metric &&
            tombstone.identity.isWithinSafetyBounds &&
            tombstone.deletedAt.timeIntervalSinceReferenceDate.isFinite &&
            tombstone.deletedAt.timeIntervalSince(now) <= tolerance &&
            (tombstone.identity.syncIdentifier == nil || tombstone.identity.revision.numericValue != nil)
        }), conflicts.allSatisfy({ conflict in
            conflict.metric == metric &&
            conflict.identity.isWithinSafetyBounds &&
            conflict.existing.metric == metric &&
            conflict.existing.identity.isWithinSafetyBounds &&
            conflict.incoming.metric == metric &&
            conflict.incoming.identity.isWithinSafetyBounds &&
            conflict.existing.provenance.matchesCanonicalRegistry &&
            conflict.incoming.provenance.matchesCanonicalRegistry
        }) else {
            throw HealthKitAnchorStoreError.invalidProjection
        }
    }

    private static func rebuildSourceIndex(observations: [HealthKitObservation]) throws -> [String: HealthKitSourceMatch] {
        try HealthKitSourceIndex.build(observations: observations)
    }

    private static func classifyLoadFailure(_ error: Error) -> HealthKitAnchorStoreLoadFailure {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.fileReadNoPermission.rawValue:
                return .protectedDataUnavailable
            case CocoaError.fileReadNoSuchFile.rawValue:
                return .unreadable
            case CocoaError.fileReadCorruptFile.rawValue,
                 CocoaError.fileReadInvalidFileName.rawValue,
                 CocoaError.fileReadInapplicableStringEncoding.rawValue:
                return .malformedData
            default:
                break
            }
        }
        if nsError.domain == "NSPOSIXErrorDomain", nsError.code == 1 || nsError.code == 13 {
            // EPERM (1) and EACCES (13) are the protected-data/read-policy
            // path on Darwin.  They must not be quarantined as corruption.
            return .protectedDataUnavailable
        }
        return .malformedData
    }

    private static func quarantine(url: URL, fileManager: FileManager, suffix: String) {
        let stamp = String(Int(Date().timeIntervalSince1970))
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).quarantine-\(suffix)-\(stamp)-\(UUID().uuidString)")
        guard (try? fileManager.copyItem(at: url, to: quarantineURL)) != nil else { return }
#if os(iOS)
        // Quarantine copies may contain protected HealthKit-derived metadata;
        // keep the same protection posture as the live envelope.
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: quarantineURL.path)
#endif
    }
}
