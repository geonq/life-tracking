import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum ConnectorState: String, Codable, CaseIterable, Equatable, Sendable {
    case healthy
    case refreshDue = "refresh_due"
    case reauthRequired = "reauth_required"
    case revoked
    case rateLimited = "rate_limited"
    case unavailable
    case disabled
    case error
}

public enum Freshness: String, Codable, CaseIterable, Equatable, Sendable {
    case fresh, aging, stale, unavailable
}

public enum DataQuality: String, Codable, CaseIterable, Equatable, Sendable {
    case observed, estimated, demo, unavailable
}

public struct Provenance: Codable, Equatable, Sendable {
    public let source: String
    public let observedAt: Date
    public let quality: DataQuality
    public let connector: ConnectorState

    public init(source: String, observedAt: Date, quality: DataQuality, connector: ConnectorState) {
        self.source = source
        self.observedAt = observedAt
        self.quality = quality
        self.connector = connector
    }

    public func freshness(now: Date = .now, staleAfter: TimeInterval = 3600) -> Freshness {
        guard connector == .healthy || connector == .refreshDue else { return .unavailable }
        let age = max(0, now.timeIntervalSince(observedAt))
        return age < staleAfter / 2 ? .fresh : age < staleAfter ? .aging : .stale
    }
}

public struct Projection: Codable, Equatable, Sendable {
    public let percentAtReset: Double?
    public let percentAtExhaustion: Double?
    public let confidence: Double?
    public let sampleSpan: String?

    public init(percentAtReset: Double? = nil, percentAtExhaustion: Double? = nil,
                confidence: Double? = nil, sampleSpan: String? = nil) {
        self.percentAtReset = percentAtReset
        self.percentAtExhaustion = percentAtExhaustion
        self.confidence = confidence
        self.sampleSpan = sampleSpan
    }
}

public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let limit: Double?
    public let used: Double?
    public let resetAt: Date?
    public let projection: Projection?

    public init(id: String, label: String, limit: Double? = nil, used: Double? = nil,
                resetAt: Date? = nil, projection: Projection? = nil) {
        self.id = id; self.label = label; self.limit = limit; self.used = used
        self.resetAt = resetAt; self.projection = projection
    }

    public var usedPercent: Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

public struct Metric: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: String
    public let provenance: Provenance
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let provider: Provider
    public let accountLabel: String
    public let windows: [UsageWindow]
    public let model: String?
    public let metrics: [Metric]
    public let provenance: Provenance

    public init(provider: Provider, accountLabel: String, windows: [UsageWindow], model: String? = nil,
                metrics: [Metric] = [], provenance: Provenance) {
        self.provider = provider; self.accountLabel = accountLabel; self.windows = windows
        self.model = model; self.metrics = metrics; self.provenance = provenance
    }
}

public typealias CodexSnapshot = ProviderSnapshot

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let providers: [ProviderSnapshot]
    public let codexStatus: String
    public let clipperSignal: String
    public let healthSignal: String
    public let financeSignal: String
    public let updatedAt: Date
    public let freshness: Freshness
    public let warning: String?
    public let provenance: Provenance
}

// The native client mirrors the provider-neutral /api/usage contract. No aggregate
// percentage is represented, so callers cannot accidentally display one.
public struct APIUsagePayload: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let windows: [APIUsageWindow]
    public let estimates: [APIUsageEstimate]
    public let connectors: [String: ConnectorState]
}

public struct APIUsageWindow: Codable, Equatable, Sendable {
    public let provider: Provider
    public let window: String
    public let durationMinutes: Int
    public let usedPercent: Double?
    public let resetAt: Date?
    public let availability: String
    public let provenance: APIUsageProvenance
}

public struct APIUsageProvenance: Codable, Equatable, Sendable {
    public let source: String
    public let observedAt: Date
    public let freshness: String
    public let official: Bool
    public let quality: String
    public let connectorState: ConnectorState
}

public struct APIUsageEstimate: Codable, Equatable, Sendable {
    public let provider: Provider
    public let window: String
    public let projectedPercentAtReset: Double?
    public let estimatedExhaustionAt: Date?
    public let velocityPercentPerHour: Double?
    public let confidence: String
    public let sampleSpanHours: Double
    public let explanation: String
    public let official: Bool
}

public enum CapabilityState: Equatable, Sendable { case blocked(String) }

public enum AppGroupConfiguration {
    public static let infoPlistKey = "APP_GROUP_IDENTIFIER"
    public static let placeholder = "REPLACE_WITH_TEAM_CONFIGURED_ID"

    public static func validatedIdentifier(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("group."), value.count > 6,
              !value.contains("$("), !value.contains(placeholder) else { return nil }
        return value
    }

    public static func identifier(bundle: Bundle = .main) -> String? {
        validatedIdentifier(bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }
}

public enum SharedSnapshotStore {
    public static let snapshotFilename = "widget-snapshot.json"

    public static func url(fileManager: FileManager = .default,
                           appGroupIdentifier: String? = AppGroupConfiguration.identifier()) -> URL? {
        guard let id = AppGroupConfiguration.validatedIdentifier(appGroupIdentifier),
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return container.appendingPathComponent(snapshotFilename)
    }

    public static func decode(_ data: Data) -> WidgetSnapshot? { try? JSONDecoder.lifeOS.decode(WidgetSnapshot.self, from: data) }

    public static func write(_ snapshot: WidgetSnapshot, fileManager: FileManager = .default,
                             appGroupIdentifier: String? = AppGroupConfiguration.identifier()) throws {
        guard let target = url(fileManager: fileManager, appGroupIdentifier: appGroupIdentifier) else { throw StoreError.unavailableContainer }
        try JSONEncoder.lifeOS.encode(snapshot).write(to: target, options: .atomic)
    }

    public static func read(fileManager: FileManager = .default,
                            appGroupIdentifier: String? = AppGroupConfiguration.identifier()) -> WidgetSnapshot? {
        guard let target = url(fileManager: fileManager, appGroupIdentifier: appGroupIdentifier),
              let data = try? Data(contentsOf: target) else { return nil }
        return decode(data)
    }

    public enum StoreError: Error, Equatable, Sendable { case invalidAppGroup, unavailableContainer }
}

public extension JSONDecoder {
    static var lifeOS: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
public extension JSONEncoder {
    static var lifeOS: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}
public enum DomainParser {
    public static func percentage(_ raw: String) -> Double? {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")) else { return nil }
        return min(max(value / 100, 0), 1)
    }
}
