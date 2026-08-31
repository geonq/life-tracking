import Foundation
import CoreGraphics
import CryptoKit

/// The native history cache stores only observations that already passed the
/// provider-neutral `/api/usage` contract. It is not a source of new usage
/// facts: a history row always carries the source and connector that produced
/// the original observation.
public struct UsageHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let provider: Provider
    public let window: String
    public let durationMinutes: Int
    public let usedPercent: Double
    public let resetAt: Date?
    public let observedAt: Date
    public let source: String
    public let connectorState: ConnectorState

    public var windowID: String { window }

    public var id: String {
        UsageHistoryDigest.observationKey(provider: provider, window: window, observedAt: observedAt)
    }

    public init(provider: Provider, window: String, durationMinutes: Int, usedPercent: Double,
                resetAt: Date?, observedAt: Date, source: String,
                connectorState: ConnectorState) {
        self.provider = provider
        self.window = window
        self.durationMinutes = durationMinutes
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.observedAt = observedAt
        self.source = source
        self.connectorState = connectorState
    }

    private enum CodingKeys: String, CodingKey {
        case provider, window, durationMinutes, usedPercent, resetAt, observedAt, source, connectorState
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "provider", "window", "durationMinutes", "usedPercent", "resetAt", "observedAt", "source", "connectorState"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(Provider.self, forKey: .provider)
        window = try container.decode(String.self, forKey: .window)
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        resetAt = try container.decodeIfPresent(String.self, forKey: .resetAt).map {
            try Self.decodeArchiveDate($0, decoder: decoder)
        }
        observedAt = try Self.decodeArchiveDate(
            container.decode(String.self, forKey: .observedAt), decoder: decoder
        )
        source = try container.decode(String.self, forKey: .source)
        connectorState = try container.decode(ConnectorState.self, forKey: .connectorState)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(window, forKey: .window)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(resetAt.map(Self.encodeArchiveDate), forKey: .resetAt)
        try container.encode(Self.encodeArchiveDate(observedAt), forKey: .observedAt)
        try container.encode(source, forKey: .source)
        try container.encode(connectorState, forKey: .connectorState)
    }

    private static func encodeArchiveDate(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSinceReferenceDate)
    }

    private static func decodeArchiveDate(_ raw: String, decoder: Decoder) throws -> Date {
        if let seconds = Double(raw), seconds.isFinite {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? standard.date(from: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid Usage history timestamp"
            ))
        }
        return date
    }

    public func validated(now: Date = .now) throws -> UsageHistoryEntry {
        let expectedDuration: Int
        switch window {
        case "five_hour": expectedDuration = 300
        case "seven_day": expectedDuration = 10_080
        default: throw UsageHistoryError.invalidEntry
        }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let observedAge = now.timeIntervalSince(observedAt)
        let observedConnector: Set<ConnectorState> = [.healthy, .refreshDue, .rateLimited]
        guard durationMinutes == expectedDuration,
              usedPercent.isFinite, (0...100).contains(usedPercent),
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              observedAge >= -UsageHistoryLedger.maximumClockSkew,
              !trimmedSource.isEmpty,
              observedConnector.contains(connectorState),
              resetAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw UsageHistoryError.invalidEntry
        }
        return UsageHistoryEntry(
            provider: provider,
            window: window,
            durationMinutes: durationMinutes,
            usedPercent: usedPercent,
            resetAt: resetAt,
            observedAt: observedAt,
            source: trimmedSource,
            connectorState: connectorState
        )
    }
}

public struct UsageHistoryIdempotencyRecord: Codable, Equatable, Sendable {
    public let key: String
    public let fingerprint: String
    public let revision: Int

    public init(key: String, fingerprint: String, revision: Int) {
        self.key = key
        self.fingerprint = fingerprint
        self.revision = revision
    }
}

public struct UsageHistoryTombstone: Codable, Equatable, Sendable {
    public let scope: String
    public let deletedAt: Date

    public init(scope: String, deletedAt: Date) {
        self.scope = scope
        self.deletedAt = deletedAt
    }
}

public enum UsageHistoryError: Error, Equatable, Sendable {
    case invalidEntry
    case invalidIdempotencyKey
    case idempotencyKeyReuse
    case idempotencyStoreFull
    case archiveInvalid
    case archiveTooLarge
    case revisionOverflow
}

public enum UsageHistoryAppendResult: Equatable, Sendable {
    case accepted(revision: Int)
    case replay(revision: Int)
    case stale(revision: Int)
}

public enum UsageHistoryStatus: String, Codable, Equatable, Sendable {
    case empty
    case available
    case storageError
}

/// Versioned local authority metadata. `authority` is intentionally explicit:
/// the phone cache is a projection of the gateway observations, not an
/// alternative provider authority.
public struct UsageHistoryArchive: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let domain: String
    public let authority: String
    public let revision: Int
    public let bodyDigest: String
    public let entries: [UsageHistoryEntry]
    public let idempotency: [UsageHistoryIdempotencyRecord]
    public let tombstones: [UsageHistoryTombstone]

    public init(revision: Int = 0, entries: [UsageHistoryEntry] = [],
                idempotency: [UsageHistoryIdempotencyRecord] = [],
                tombstones: [UsageHistoryTombstone] = []) {
        self.schemaVersion = 1
        self.domain = "usage"
        self.authority = "local-observation-cache"
        self.revision = revision
        self.bodyDigest = UsageHistoryDigest.entries(entries)
        self.entries = entries
        self.idempotency = idempotency
        self.tombstones = tombstones
    }

    public func validated(now: Date = .now) throws -> UsageHistoryArchive {
        guard schemaVersion == 1,
              domain == "usage",
              authority == "local-observation-cache",
              revision >= 0,
              revision <= UsageHistoryLedger.maximumRevision,
              entries.count <= UsageHistoryLedger.maximumSamples,
              idempotency.count <= UsageHistoryLedger.maximumIdempotencyRecords,
              tombstones.count <= UsageHistoryLedger.maximumTombstones,
              bodyDigest == UsageHistoryDigest.entries(entries) else {
            throw UsageHistoryError.archiveInvalid
        }

        var observationKeys = Set<String>()
        for entry in entries {
            let validated = try entry.validated(now: now)
            guard observationKeys.insert(validated.id).inserted else {
                throw UsageHistoryError.archiveInvalid
            }
        }

        var idempotencyKeys = Set<String>()
        for record in idempotency {
            guard UsageHistoryDigest.isValidIdempotencyKey(record.key),
                  UsageHistoryDigest.isDigest(record.fingerprint),
                  record.revision >= 0, record.revision <= revision,
                  idempotencyKeys.insert(record.key).inserted else {
                throw UsageHistoryError.archiveInvalid
            }
        }
        for tombstone in tombstones {
            guard !tombstone.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  tombstone.deletedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw UsageHistoryError.archiveInvalid
            }
        }
        return self
    }
}

/// A bounded append-only observation ledger. Repeated refreshes of the same
/// provider/window value are no-ops, delayed observations cannot replace a
/// newer value, and a reused idempotency key with different content fails
/// closed.
public struct UsageHistoryLedger: Equatable, Sendable {
    public static let maximumSamples = 500
    public static let maximumIdempotencyRecords = 10_000
    public static let maximumTombstones = 10_000
    public static let maximumRevision = Int.max
    public static let maximumClockSkew: TimeInterval = 5
    public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumArchiveBytes = 1 * 1024 * 1024

    public private(set) var entries: [UsageHistoryEntry]
    public private(set) var revision: Int
    public private(set) var idempotency: [UsageHistoryIdempotencyRecord]
    public private(set) var tombstones: [UsageHistoryTombstone]

    public init() {
        entries = []
        revision = 0
        idempotency = []
        tombstones = []
    }

    public init(archive: UsageHistoryArchive, now: Date = .now) throws {
        _ = try archive.validated(now: now)
        entries = archive.entries
            .filter { now.timeIntervalSince($0.observedAt) <= Self.maximumAge }
            .sorted(by: UsageHistoryDigest.entrySort)
            .suffix(Self.maximumSamples)
            .map { $0 }
        revision = archive.revision
        idempotency = archive.idempotency
        tombstones = archive.tombstones
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func archive() -> UsageHistoryArchive {
        UsageHistoryArchive(revision: revision, entries: entries,
                            idempotency: idempotency, tombstones: tombstones)
    }

    public mutating func append(_ incoming: [UsageHistoryEntry], idempotencyKey: String,
                                now: Date = .now) throws -> UsageHistoryAppendResult {
        guard UsageHistoryDigest.isValidIdempotencyKey(idempotencyKey) else {
            throw UsageHistoryError.invalidIdempotencyKey
        }
        guard !incoming.isEmpty else { return .stale(revision: revision) }

        let fingerprint = UsageHistoryDigest.entries(incoming)
        if let previous = idempotency.first(where: { $0.key == idempotencyKey }) {
            guard previous.fingerprint == fingerprint else { throw UsageHistoryError.idempotencyKeyReuse }
            return .replay(revision: revision)
        }

        var validated = [UsageHistoryEntry]()
        var batchKeys = Set<String>()
        for entry in incoming {
            let item = try entry.validated(now: now)
            guard batchKeys.insert(item.id).inserted else { throw UsageHistoryError.invalidEntry }
            validated.append(item)
        }
        validated.sort(by: UsageHistoryDigest.entrySort)

        guard idempotency.count < Self.maximumIdempotencyRecords else {
            throw UsageHistoryError.idempotencyStoreFull
        }

        var nextEntries = entries
        var bodyChanged = false
        for item in validated {
            let latest = nextEntries
                .filter { $0.provider == item.provider && $0.window == item.window }
                .max { $0.observedAt < $1.observedAt }

            if let latest {
                if latest.usedPercent == item.usedPercent && latest.resetAt == item.resetAt {
                    continue
                }
                guard item.observedAt > latest.observedAt else { continue }
            }
            nextEntries.append(item)
            bodyChanged = true
        }

        let nextRevision: Int
        if bodyChanged {
            guard revision < Self.maximumRevision else { throw UsageHistoryError.revisionOverflow }
            nextRevision = revision + 1
            nextEntries = nextEntries
                .filter { now.timeIntervalSince($0.observedAt) <= Self.maximumAge }
                .sorted(by: UsageHistoryDigest.entrySort)
                .suffix(Self.maximumSamples)
                .map { $0 }
        } else {
            nextRevision = revision
        }

        let nextIdempotency = idempotency + [UsageHistoryIdempotencyRecord(
            key: idempotencyKey, fingerprint: fingerprint, revision: nextRevision
        )]
        let prospective = UsageHistoryArchive(
            revision: nextRevision,
            entries: nextEntries,
            idempotency: nextIdempotency,
            tombstones: tombstones
        )
        let encoded = try JSONEncoder.lifeOS.encode(prospective)
        guard encoded.count <= Self.maximumArchiveBytes else { throw UsageHistoryError.archiveTooLarge }
        if bodyChanged {
            entries = nextEntries
            revision = nextRevision
        }
        idempotency = nextIdempotency
        return bodyChanged ? .accepted(revision: revision) : .stale(revision: revision)
    }

    /// Local deletion is explicit and recoverable in the archive audit trail.
    /// It never claims that the remote provider or gateway was deleted.
    public mutating func delete(provider: Provider? = nil, window: String? = nil,
                                now: Date = .now) throws {
        let removed = entries.filter { entry in
            (provider == nil || entry.provider == provider) &&
            (window == nil || entry.window == window)
        }
        guard !removed.isEmpty else { return }
        guard revision < Self.maximumRevision else { throw UsageHistoryError.revisionOverflow }
        entries.removeAll { entry in
            (provider == nil || entry.provider == provider) &&
            (window == nil || entry.window == window)
        }
        revision += 1
        let providerScope = provider?.rawValue ?? "*"
        let windowScope = window ?? "*"
        tombstones.append(UsageHistoryTombstone(
            scope: "\(providerScope):\(windowScope)", deletedAt: now
        ))
        if tombstones.count > Self.maximumTombstones {
            tombstones.removeFirst(tombstones.count - Self.maximumTombstones)
        }
    }
}

public protocol UsageHistoryPersistence {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// UserDefaults holds only bounded, non-secret observation metadata. Provider
/// credentials and connector tokens are never written here.
public final class UserDefaultsUsageHistoryPersistence: UsageHistoryPersistence {
    public static let defaultKey = "LifeOS.Usage.history.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> Data? { defaults.data(forKey: key) }

    public func save(_ data: Data) throws {
        guard data.count <= UsageHistoryLedger.maximumArchiveBytes else {
            throw UsageHistoryError.archiveTooLarge
        }
        defaults.set(data, forKey: key)
    }
}

public enum UsageHistoryDigest {
    public static func idempotencyKey(for entries: [UsageHistoryEntry]) -> String {
        "usage-" + String(digest(entries: entries).prefix(64))
    }

    public static func observationKey(provider: Provider, window: String, observedAt: Date) -> String {
        "\(provider.rawValue):\(window):\(String(format: "%.6f", observedAt.timeIntervalSinceReferenceDate))"
    }

    fileprivate static func entrySort(_ lhs: UsageHistoryEntry, _ rhs: UsageHistoryEntry) -> Bool {
        if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
        if lhs.window != rhs.window { return lhs.window < rhs.window }
        return lhs.observedAt < rhs.observedAt
    }

    fileprivate static func entries(_ entries: [UsageHistoryEntry]) -> String {
        let canonical = entries.sorted(by: entrySort).map { entry in
            let reset = entry.resetAt.map { String(format: "%.6f", $0.timeIntervalSinceReferenceDate) } ?? "nil"
            return [
                entry.provider.rawValue,
                entry.window,
                String(entry.durationMinutes),
                String(format: "%.12f", entry.usedPercent),
                reset,
                String(format: "%.6f", entry.observedAt.timeIntervalSinceReferenceDate),
                entry.source,
                entry.connectorState.rawValue
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return sha256(canonical)
    }

    fileprivate static func digest(entries values: [UsageHistoryEntry]) -> String {
        Self.entries(values)
    }

    fileprivate static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    fileprivate static func isValidIdempotencyKey(_ value: String) -> Bool {
        value.count >= 1 && value.count <= 128 && value.unicodeScalars.allSatisfy {
            (0x21...0x7e).contains($0.value)
        }
    }
}

public enum UsageAnalyticsHistoryBuilder {
    public static func snapshots(from ledger: UsageHistoryLedger,
                                 providers: [ProviderSnapshot], now: Date = .now) -> [UsageAnalyticsSnapshot] {
        let retained = ledger.entries.filter {
            now.timeIntervalSince($0.observedAt) <= UsageHistoryLedger.maximumAge
        }
        let grouped = Dictionary(grouping: retained) { "\($0.provider.rawValue):\($0.window)" }
        return grouped.values.compactMap { records in
            guard let first = records.first else { return nil }
            let sorted = records.sorted(by: UsageHistoryDigest.entrySort)
            let providerSnapshot = providers.first { $0.provider == first.provider }
            let currentWindow = providerSnapshot?.windows.first { $0.id == first.window }
            let latest = sorted.max { $0.observedAt < $1.observedAt } ?? first
            let provenance = Provenance(
                source: latest.source,
                observedAt: latest.observedAt,
                quality: .observed,
                connector: latest.connectorState
            )

            var projection: [UsageProjectionPoint] = []
            if let resetAt = currentWindow?.resetAt,
               let projected = currentWindow?.projection?.percentAtReset,
               resetAt > latest.observedAt,
               projected.isFinite, (0...1).contains(projected) {
                projection = [
                    UsageProjectionPoint(date: latest.observedAt, usedPercent: latest.usedPercent / 100),
                    UsageProjectionPoint(date: resetAt, usedPercent: projected)
                ]
            }

            return UsageAnalyticsSnapshot(
                provider: first.provider,
                windowID: first.window,
                activity: [],
                projection: projection,
                modelBreakdowns: [],
                heatmap: [],
                provenance: provenance,
                history: sorted
            )
        }
        .sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return ($0.windowID ?? "") < ($1.windowID ?? "")
        }
    }
}

/// Presentation state for an individual Usage value. `UsageLoadState` remains
/// the compatibility shell used by the existing Settings surfaces; this
/// finer-grained state is used where a value must say exactly what it means.
public enum UsageValueState: String, Codable, Equatable, Sendable {
    case observed
    case estimated
    case projected
    case stale
    case unavailable
    case error
    case demo
    case loading

    public var label: String {
        switch self {
        case .observed: return "Observed"
        case .estimated: return "Estimated"
        case .projected: return "Projected"
        case .stale: return "Stale"
        case .unavailable: return "Not available"
        case .error: return "Error"
        case .demo: return "Demo · not live"
        case .loading: return "Loading"
        }
    }
}

public enum UsageWindowStateResolver {
    public static func state(for window: UsageWindow?, snapshot: ProviderSnapshot? = nil,
                             loadState: UsageLoadState = .observed,
                             now: Date = .now) -> UsageValueState {
        let provenance = window?.provenance ?? snapshot?.provenance
        if loadState == .loading && window?.usedPercent == nil { return .loading }
        if provenance?.quality == .demo { return .demo }
        if window?.usedPercent == nil { return .unavailable }
        guard let provenance else { return .unavailable }
        switch provenance.freshness(now: now) {
        case .fresh, .aging: return .observed
        case .stale: return .stale
        case .unavailable: return .unavailable
        }
    }

    public static func state(forProjection: Bool, quality: DataQuality,
                             loadState: UsageLoadState = .observed) -> UsageValueState {
        if loadState == .loading { return .loading }
        if quality == .demo { return .demo }
        if quality == .unavailable { return .unavailable }
        return forProjection ? .projected : (quality == .estimated ? .estimated : .observed)
    }
}

/// A daily roll-up is only complete when the source supplied one observation
/// for every hour in that calendar day. Partial days remain visible as
/// coverage metadata but cannot be promoted to a peak-day fact.
public struct UsageDailyActivitySummary: Identifiable, Equatable, Sendable {
    public let date: Date
    public let tokens: Int
    public let observationCount: Int
    public let expectedObservationCount: Int

    public var id: Date { date }
    public var isComplete: Bool { observationCount >= expectedObservationCount }

    public init(date: Date, tokens: Int, observationCount: Int, expectedObservationCount: Int) {
        self.date = date
        self.tokens = max(0, tokens)
        self.observationCount = max(0, observationCount)
        self.expectedObservationCount = max(1, expectedObservationCount)
    }
}

public enum UsageActivityAggregation {
    public static func daily(from points: [UsageActivityPoint],
                             calendar: Calendar = .current) -> [UsageDailyActivitySummary] {
        let grouped = Dictionary(grouping: points) { calendar.startOfDay(for: $0.date) }
        return grouped.map { day, values in
            let hourlyBuckets = Set(values.compactMap { calendar.dateInterval(of: .hour, for: $0.date)?.start })
            let expected = expectedHours(on: day, calendar: calendar)
            return UsageDailyActivitySummary(
                date: day,
                tokens: values.reduce(0) { $0 + $1.tokens },
                observationCount: hourlyBuckets.count,
                expectedObservationCount: expected
            )
        }
        .sorted { $0.date < $1.date }
    }

    public static func completeDays(from points: [UsageActivityPoint],
                                    calendar: Calendar = .current) -> [UsageDailyActivitySummary] {
        daily(from: points, calendar: calendar).filter(\.isComplete)
    }

    private static func expectedHours(on day: Date, calendar: Calendar) -> Int {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return 24 }
        return max(1, Int(ceil(interval.duration / 3_600)))
    }
}

public struct UsageHourWeight: Codable, Equatable, Sendable {
    public let weekday: Int
    public let hour: Int
    public let weight: Double

    public init(weekday: Int, hour: Int, weight: Double) {
        self.weekday = weekday
        self.hour = hour
        self.weight = max(0, weight)
    }
}

public struct UsageActivityProfile: Codable, Equatable, Sendable {
    public let hourlyWeights: [UsageHourWeight]

    public init(hourlyWeights: [UsageHourWeight]) {
        self.hourlyWeights = hourlyWeights
    }

    public func weight(at date: Date, calendar: Calendar = .current) -> Double {
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        return hourlyWeights.first { $0.weekday == weekday && $0.hour == hour }?.weight ?? 1
    }
}

public struct UsageProjectionPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let usedPercent: Double

    public init(date: Date, usedPercent: Double) {
        self.date = date
        self.usedPercent = min(max(usedPercent, 0), 1)
    }
}

public enum UsageProjectionEngine {
    /// Projects to the natural reset using a learned hour-of-week activity profile.
    /// The baseline is the recent observed hourly increase; profile weights model daily cycles.
    public static func points(
        currentUsedPercent: Double,
        observedAt: Date,
        resetAt: Date,
        baselineHourlyIncrease: Double,
        profile: UsageActivityProfile,
        calendar: Calendar = .current
    ) -> [UsageProjectionPoint] {
        guard resetAt > observedAt, baselineHourlyIncrease >= 0 else { return [] }
        var result = [UsageProjectionPoint(date: observedAt, usedPercent: currentUsedPercent)]
        var cursor = observedAt
        var projected = min(max(currentUsedPercent, 0), 1)

        while cursor < resetAt {
            let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end
            let candidate = hourEnd.flatMap { $0 > cursor ? $0 : nil }
                ?? cursor.addingTimeInterval(3_600)
            let next = min(candidate, resetAt)
            let hours = next.timeIntervalSince(cursor) / 3_600
            projected = min(
                1,
                projected + baselineHourlyIncrease * profile.weight(at: cursor, calendar: calendar) * hours
            )
            result.append(UsageProjectionPoint(date: next, usedPercent: projected))
            cursor = next
        }
        return result
    }
}

public struct UsageActivityPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let tokens: Int
    public let usedPercent: Double

    public init(date: Date, tokens: Int, usedPercent: Double) {
        self.date = date
        self.tokens = max(0, tokens)
        self.usedPercent = min(max(usedPercent, 0), 1)
    }
}

public struct UsageModelBreakdown: Identifiable, Codable, Equatable, Sendable {
    public var id: String { model }
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let toolTokens: Int
    public let imageTokens: Int

    public init(model: String, inputTokens: Int, outputTokens: Int, reasoningTokens: Int,
                toolTokens: Int, imageTokens: Int) {
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.toolTokens = max(0, toolTokens)
        self.imageTokens = max(0, imageTokens)
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + toolTokens + imageTokens
    }

    public var categories: [(label: String, value: Int)] {
        [("Input", inputTokens), ("Output", outputTokens), ("Reasoning", reasoningTokens),
         ("Tools", toolTokens), ("Images", imageTokens)]
    }
}

public struct UsageHeatmapCell: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(weekday)-\(hour)" }
    public let weekday: Int
    public let hour: Int
    public let intensity: Double

    public init(weekday: Int, hour: Int, intensity: Double) {
        self.weekday = weekday
        self.hour = hour
        self.intensity = min(max(intensity, 0), 1)
    }
}

public struct UsageHeatmapGridItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case corner
        case hourHeader(Int)
        case dayHeader(Int)
        case cell(UsageHeatmapCell)
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public enum UsageHeatmapGrid {
    public static let displayedHours = stride(from: 0, to: 24, by: 3).map { $0 }

    public static func items(cells: [UsageHeatmapCell]) -> [UsageHeatmapGridItem] {
        var items = [UsageHeatmapGridItem(id: "corner", kind: .corner)]
        items += displayedHours.map {
            UsageHeatmapGridItem(id: "hour-header-\($0)", kind: .hourHeader($0))
        }

        for weekday in 1...7 {
            items.append(UsageHeatmapGridItem(id: "day-header-\(weekday)", kind: .dayHeader(weekday)))
            for hour in displayedHours {
                let cell = cells.first { $0.weekday == weekday && $0.hour == hour }
                    ?? UsageHeatmapCell(weekday: weekday, hour: hour, intensity: 0)
                items.append(UsageHeatmapGridItem(id: "cell-\(weekday)-\(hour)", kind: .cell(cell)))
            }
        }
        return items
    }
}

public struct UsageAnalyticsSnapshot: Codable, Equatable, Sendable {
    public let provider: Provider
    /// Analytics are scoped to one provider window. Keeping that scope explicit prevents a
    /// 5-hour estimate from being shown after the user switches the detail surface to 7 days.
    public let windowID: String?
    public let activity: [UsageActivityPoint]
    public let projection: [UsageProjectionPoint]
    public let modelBreakdowns: [UsageModelBreakdown]
    public let heatmap: [UsageHeatmapCell]
    public let provenance: Provenance
    /// Durable quota observations collected from the validated Usage payload.
    /// This is deliberately separate from token activity: a quota observation
    /// cannot be relabelled as token volume.
    public let history: [UsageHistoryEntry]

    private enum CodingKeys: String, CodingKey {
        case provider, windowID, activity, projection, modelBreakdowns, heatmap, provenance, history
    }

    public init(provider: Provider, windowID: String? = nil, activity: [UsageActivityPoint], projection: [UsageProjectionPoint],
                modelBreakdowns: [UsageModelBreakdown], heatmap: [UsageHeatmapCell], provenance: Provenance,
                history: [UsageHistoryEntry] = []) {
        self.provider = provider
        self.windowID = windowID
        self.activity = activity
        self.projection = projection
        self.modelBreakdowns = modelBreakdowns
        self.heatmap = heatmap
        self.provenance = provenance
        self.history = history
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "provider", "windowID", "activity", "projection", "modelBreakdowns", "heatmap", "provenance", "history"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(Provider.self, forKey: .provider)
        windowID = try container.decodeIfPresent(String.self, forKey: .windowID)
        activity = try container.decode([UsageActivityPoint].self, forKey: .activity)
        projection = try container.decode([UsageProjectionPoint].self, forKey: .projection)
        modelBreakdowns = try container.decode([UsageModelBreakdown].self, forKey: .modelBreakdowns)
        heatmap = try container.decode([UsageHeatmapCell].self, forKey: .heatmap)
        provenance = try container.decode(Provenance.self, forKey: .provenance)
        // History was added after the first analytics schema. Missing history
        // is an empty, honest migration state rather than a decode failure.
        history = try container.decodeIfPresent([UsageHistoryEntry].self, forKey: .history) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(windowID, forKey: .windowID)
        try container.encode(activity, forKey: .activity)
        try container.encode(projection, forKey: .projection)
        try container.encode(modelBreakdowns, forKey: .modelBreakdowns)
        try container.encode(heatmap, forKey: .heatmap)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(history, forKey: .history)
    }
}

public struct UsageSelectionPoint: Equatable, Sendable {
    public let date: Date
    public let usedPercent: Double
    public let isProjected: Bool

    /// Stable selection identity. Selection must survive a source reorder or refresh;
    /// array offsets are presentation details and are not valid IDs.
    public var id: String {
        "\(isProjected ? "projected" : "observed")|\(date.timeIntervalSinceReferenceDate)"
    }
}

public enum UsageSelection {
    public static func closestPoint(
        to date: Date,
        observed: [UsageProjectionPoint],
        projected: [UsageProjectionPoint]
    ) -> UsageSelectionPoint? {
        var observedByDate: [Date: UsageProjectionPoint] = [:]
        observed.forEach { observedByDate[$0.date] = $0 }
        var projectedByDate: [Date: UsageProjectionPoint] = [:]
        projected.forEach { projectedByDate[$0.date] = $0 }

        let candidates = observedByDate.values.map {
            UsageSelectionPoint(date: $0.date, usedPercent: $0.usedPercent, isProjected: false)
        } + projectedByDate.values.map {
            UsageSelectionPoint(date: $0.date, usedPercent: $0.usedPercent, isProjected: true)
        }
        return candidates.min {
            let leftDistance = abs($0.date.timeIntervalSince(date))
            let rightDistance = abs($1.date.timeIntervalSince(date))
            guard leftDistance == rightDistance else { return leftDistance < rightDistance }
            if $0.isProjected != $1.isProjected {
                return !$0.isProjected
            }
            return $0.date < $1.date
        }
    }

    public static func radarCategoryIndex(at location: CGPoint, center: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = location.x - center.x
        let dy = location.y - center.y
        guard hypot(dx, dy) > 4 else { return nil }
        let normalized = (atan2(dy, dx) + .pi / 2 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let sector = 2 * .pi / Double(count)
        return min(Int(floor(normalized / sector)), count - 1)
    }
}

public enum UsageAnalyticsResolver {
    public static func matching(
        snapshot: ProviderSnapshot,
        candidates: [UsageAnalyticsSnapshot],
        windowID: String? = nil
    ) -> UsageAnalyticsSnapshot? {
        let qualityMatches = candidates.filter { candidate in
            guard candidate.provider == snapshot.provider else { return false }
            if snapshot.provenance.quality == .demo {
                return candidate.provenance.quality == .demo
            }
            return candidate.provenance.quality != .demo
        }

        guard let windowID else { return qualityMatches.first }

        // A scoped analytics record must never be reused for another range. An unscoped
        // record remains a valid provider-level fallback, but it cannot contribute a forward
        // estimate because `UsageProjectionChart` requires an explicit matching window ID.
        if let exact = qualityMatches.first(where: { $0.windowID == windowID }) {
            return exact
        }
        return qualityMatches.first(where: { $0.windowID == nil })
    }
}

public struct UsageWidgetSummary: Equatable, Sendable {
    public let provider: Provider
    public let windowIndicator: String
    public let remainingPercent: Double
    public let observedUsedPercent: Double
    public let projectedUsedPercent: Double?

    public init?(snapshot: ProviderSnapshot) {
        guard let window = snapshot.smallestObservedWindow, let used = window.usedPercent else { return nil }
        provider = snapshot.provider
        remainingPercent = 1 - used
        observedUsedPercent = used
        projectedUsedPercent = window.projection?.percentAtReset
        if let duration = window.durationMinutes {
            windowIndicator = Self.indicator(forMinutes: duration)
        } else {
            windowIndicator = window.id.localizedCaseInsensitiveContains("5") ? "5hr" : "w"
        }
    }

    private static func indicator(forMinutes minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 10_080 == 0 { return minutes == 10_080 ? "w" : "\(minutes / 10_080)w" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)hr" }
        return "\(minutes)m"
    }
}

public enum DemoUsageAnalytics {
    public static let snapshots: [UsageAnalyticsSnapshot] = [
        make(provider: .codex, scale: 1, models: [
            UsageModelBreakdown(model: "gpt-5.6-sol", inputTokens: 186_000, outputTokens: 54_000, reasoningTokens: 92_000, toolTokens: 31_000, imageTokens: 8_000),
            UsageModelBreakdown(model: "gpt-5.6-luna", inputTokens: 74_000, outputTokens: 29_000, reasoningTokens: 41_000, toolTokens: 12_000, imageTokens: 3_000)
        ]),
        make(provider: .claude, scale: 0.72, models: [
            UsageModelBreakdown(model: "Claude", inputTokens: 121_000, outputTokens: 47_000, reasoningTokens: 58_000, toolTokens: 18_000, imageTokens: 2_000)
        ])
    ]

    private static func make(provider: Provider, scale: Double, models: [UsageModelBreakdown]) -> UsageAnalyticsSnapshot {
        let start = DemoDataProvider.observedAt.addingTimeInterval(-11 * 3_600)
        let activity = (0..<12).map { index in
            let cycle = [0.18, 0.12, 0.08, 0.06, 0.10, 0.28, 0.62, 0.86, 0.74, 0.93, 0.56, 0.42][index]
            return UsageActivityPoint(
                date: start.addingTimeInterval(Double(index) * 3_600),
                tokens: Int(Double(42_000) * cycle * scale),
                usedPercent: min(0.08 + Double(index) * 0.026 * scale, 0.72)
            )
        }
        let profile = UsageActivityProfile(hourlyWeights: (0..<24).map {
            UsageHourWeight(weekday: Calendar.current.component(.weekday, from: DemoDataProvider.observedAt),
                            hour: $0, weight: $0 >= 8 && $0 <= 22 ? 1.35 : 0.28)
        })
        let projection = UsageProjectionEngine.points(
            currentUsedPercent: activity.last?.usedPercent ?? 0,
            observedAt: DemoDataProvider.observedAt,
            resetAt: DemoDataProvider.observedAt.addingTimeInterval(3_600),
            baselineHourlyIncrease: 0.018 * scale,
            profile: profile
        )
        let heatmap = (1...7).flatMap { weekday in
            stride(from: 0, to: 24, by: 3).map { hour in
                let active = hour >= 9 && hour <= 21
                let variation = Double((weekday * 7 + hour) % 5) / 10
                return UsageHeatmapCell(weekday: weekday, hour: hour,
                                        intensity: min((active ? 0.45 : 0.08) + variation * scale, 1))
            }
        }
        return UsageAnalyticsSnapshot(provider: provider, windowID: "5h", activity: activity, projection: projection,
                                      modelBreakdowns: models, heatmap: heatmap,
                                      provenance: DemoDataProvider.provenance)
    }
}
