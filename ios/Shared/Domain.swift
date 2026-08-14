import Foundation

struct LifeOSAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func rejectUnknownLifeOSKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: LifeOSAnyCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "Unknown LifeOS response field"))
    }
}

func decodeStrictOptional<T: Decodable, Key: CodingKey>(
    _ type: T.Type, forKey key: Key, from container: KeyedDecodingContainer<Key>
) throws -> T? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw DecodingError.valueNotFound(type, .init(codingPath: container.codingPath + [key],
            debugDescription: "Explicit null is not accepted"))
    }
    return try container.decode(type, forKey: key)
}

extension CodingUserInfoKey {
    static let lifeOSNow = CodingUserInfoKey(rawValue: "com.hermes.lifeos.now")!
}

public enum LifeOSDeepLink: Equatable, Sendable {
    case usage
    case calendar
    case newCalendarEvent
    case tax
    case finance
    case financeSpend
    case financeCashFlow
    case fitness
    case fitnessDailyOverview
    case fitnessStrain
    case fitnessRecovery
    case fitnessSleep
    case fitnessHealthMonitor
    case fitnessRespiration
    case fitnessHeartRate
    case fitnessHRV
    case fitnessSpO2
    case fitnessTemperature
    case fitnessSleepDuration
    case fitnessNutrition
    case fitnessNutritionGoals
    case fitnessNutritionImport
    case fitnessNutritionCamera
    case fitnessNutritionBarcode
    case fitnessNutritionAIProposal
    case fitnessNutritionSearch
    case fitnessNetEnergy
    case fitnessStress
    case fitnessEnergyReserve
    case tasks
    case settings

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "lifeos" else { return nil }
        // `lifeos://finance/spend` is the canonical shape. Accepting a path-only
        // form as well keeps links copied from universal-link tooling useful
        // (`lifeos:///finance/spend`) without weakening the scheme check.
        let host = url.host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pathSegments = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased().replacingOccurrences(of: "_", with: "-") }
        let segments: [String] = (host.map { [$0] } ?? []) + pathSegments
        guard let module = segments.first else { return nil }
        let section = segments.dropFirst().first

        if module == "fitness" {
            switch Array(segments.dropFirst()) {
            case ["daily-overview"], ["overview"]: self = .fitnessDailyOverview; return
            case ["strain"], ["load"]: self = .fitnessStrain; return
            case ["recovery"], ["readiness"]: self = .fitnessRecovery; return
            case ["sleep"]: self = .fitnessSleep; return
            case ["health"]: self = .fitnessHealthMonitor; return
            case ["health", "respiration"]: self = .fitnessRespiration; return
            case ["health", "heart-rate"], ["health", "heartrate"]: self = .fitnessHeartRate; return
            case ["health", "hrv"]: self = .fitnessHRV; return
            case ["health", "spo2"], ["health", "oxygen"]: self = .fitnessSpO2; return
            case ["health", "temperature"]: self = .fitnessTemperature; return
            case ["health", "sleep"], ["health", "sleep-duration"]: self = .fitnessSleepDuration; return
            case ["nutrition", "goals"]: self = .fitnessNutritionGoals; return
            case ["nutrition", "import"], ["nutrition", "photo"]: self = .fitnessNutritionImport; return
            case ["nutrition", "camera"]: self = .fitnessNutritionCamera; return
            case ["nutrition", "barcode"]: self = .fitnessNutritionBarcode; return
            case ["nutrition", "ai-proposal"], ["nutrition", "ai"]: self = .fitnessNutritionAIProposal; return
            case ["nutrition", "search"]: self = .fitnessNutritionSearch; return
            default: break
            }
        }

        switch (module, section) {
        case ("usage", _): self = .usage
        case ("calendar", "new"): self = .newCalendarEvent
        case ("calendar", _): self = .calendar
        case ("tax", _): self = .tax
        case ("finance", nil): self = .finance
        case ("finance", "spend"), ("finance", "spending"): self = .financeSpend
        case ("finance", "cash-flow"), ("finance", "cashflow"): self = .financeCashFlow
        case ("fitness", nil): self = .fitness
        case ("fitness", "nutrition"): self = .fitnessNutrition
        case ("fitness", "health"): self = .fitnessHealthMonitor
        case ("fitness", "net-energy"), ("fitness", "netenergy"): self = .fitnessNetEnergy
        case ("fitness", "stress"): self = .fitnessStress
        case ("fitness", "energy-reserve"), ("fitness", "energyreserve"): self = .fitnessEnergyReserve
        case ("tasks", _): self = .tasks
        case ("settings", _): self = .settings
        default: return nil
        }
    }
}

public enum Provider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case glm
    case deepseek
    case googleAIStudio = "google_ai_studio"

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .glm: "GLM"
        case .deepseek: "DeepSeek"
        case .googleAIStudio: "Google AI Studio"
        }
    }
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

    public func freshness(now: Date = .now, staleAfter: TimeInterval = 15 * 60) -> Freshness {
        guard connector == .healthy || connector == .refreshDue else { return .unavailable }
        let age = now.timeIntervalSince(observedAt)
        guard age >= 0 else { return .unavailable }
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
    public let durationMinutes: Int?
    public let provenance: Provenance?

    public init(id: String, label: String, limit: Double? = nil, used: Double? = nil,
                resetAt: Date? = nil, projection: Projection? = nil, durationMinutes: Int? = nil,
                provenance: Provenance? = nil) {
        self.id = id; self.label = label; self.limit = limit; self.used = used
        self.resetAt = resetAt; self.projection = projection; self.durationMinutes = durationMinutes
        self.provenance = provenance
    }

    public var usedPercent: Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

public extension ProviderSnapshot {
    /// The shortest observed limit window is the most actionable summary.
    /// Unknown-duration and unavailable windows sort behind measured windows.
    var smallestObservedWindow: UsageWindow? {
        windows
            .filter { $0.usedPercent != nil }
            .sorted {
                if $0.durationMinutes == $1.durationMinutes { return $0.id < $1.id }
                return ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max)
            }
            .first
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

public extension WidgetSnapshot {
    static func unavailable(at date: Date = .now) -> WidgetSnapshot {
        let provenance = Provenance(
            source: "No connected data source",
            observedAt: date,
            quality: .unavailable,
            connector: .unavailable
        )
        return WidgetSnapshot(
            providers: [],
            codexStatus: "Unavailable",
            clipperSignal: "Unavailable",
            healthSignal: "Unavailable",
            financeSignal: "Unavailable",
            updatedAt: date,
            freshness: .unavailable,
            warning: "Usage data unavailable",
            provenance: provenance
        )
    }
}

// The native client mirrors the provider-neutral /api/usage contract. No aggregate
// percentage is represented, so callers cannot accidentally display one.
public struct APIUsagePayload: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let windows: [APIUsageWindow]
    public let estimates: [APIUsageEstimate]
    public let connectors: [String: ConnectorState]

    private enum CodingKeys: String, CodingKey { case generatedAt, windows, estimates, connectors }

    public init(generatedAt: Date, windows: [APIUsageWindow], estimates: [APIUsageEstimate],
                connectors: [String: ConnectorState]) {
        self.generatedAt = generatedAt; self.windows = windows; self.estimates = estimates; self.connectors = connectors
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["generatedAt", "windows", "estimates", "connectors"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        windows = try container.decode([APIUsageWindow].self, forKey: .windows)
        estimates = try container.decode([APIUsageEstimate].self, forKey: .estimates)
        connectors = try container.decode([String: ConnectorState].self, forKey: .connectors)
        _ = try UsageIngestion.map(self, now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> APIUsagePayload {
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(APIUsagePayload.self, from: data)
    }
}

public struct APIUsageWindow: Codable, Equatable, Sendable {
    public let provider: Provider
    public let window: String
    public let durationMinutes: Int
    public let usedPercent: Double?
    public let resetAt: Date?
    public let availability: String
    public let provenance: APIUsageProvenance

    private enum CodingKeys: String, CodingKey {
        case provider, window, durationMinutes, usedPercent, resetAt, availability, provenance
    }

    public init(provider: Provider, window: String, durationMinutes: Int, usedPercent: Double?, resetAt: Date?,
                availability: String, provenance: APIUsageProvenance) {
        self.provider = provider; self.window = window; self.durationMinutes = durationMinutes
        self.usedPercent = usedPercent; self.resetAt = resetAt; self.availability = availability; self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "provider", "window", "durationMinutes", "usedPercent", "resetAt", "availability", "provenance"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(Provider.self, forKey: .provider)
        window = try container.decode(String.self, forKey: .window)
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)
        usedPercent = try decodeStrictOptional(Double.self, forKey: .usedPercent, from: container)
        resetAt = try decodeStrictOptional(Date.self, forKey: .resetAt, from: container)
        availability = try container.decode(String.self, forKey: .availability)
        provenance = try container.decode(APIUsageProvenance.self, forKey: .provenance)
    }
}

public struct APIUsageProvenance: Codable, Equatable, Sendable {
    public let source: String
    public let observedAt: Date
    public let freshness: String
    public let official: Bool
    public let quality: String
    public let connectorState: ConnectorState

    private enum CodingKeys: String, CodingKey {
        case source, observedAt, freshness, official, quality, connectorState
    }

    public init(source: String, observedAt: Date, freshness: String, official: Bool, quality: String,
                connectorState: ConnectorState) {
        self.source = source; self.observedAt = observedAt; self.freshness = freshness
        self.official = official; self.quality = quality; self.connectorState = connectorState
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "source", "observedAt", "freshness", "official", "quality", "connectorState"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        freshness = try container.decode(String.self, forKey: .freshness)
        official = try container.decode(Bool.self, forKey: .official)
        quality = try container.decode(String.self, forKey: .quality)
        connectorState = try container.decode(ConnectorState.self, forKey: .connectorState)
    }
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

    private enum CodingKeys: String, CodingKey {
        case provider, window, projectedPercentAtReset, estimatedExhaustionAt, velocityPercentPerHour,
             confidence, sampleSpanHours, explanation, official
    }

    public init(provider: Provider, window: String, projectedPercentAtReset: Double?, estimatedExhaustionAt: Date?,
                velocityPercentPerHour: Double?, confidence: String, sampleSpanHours: Double,
                explanation: String, official: Bool) {
        self.provider = provider; self.window = window; self.projectedPercentAtReset = projectedPercentAtReset
        self.estimatedExhaustionAt = estimatedExhaustionAt; self.velocityPercentPerHour = velocityPercentPerHour
        self.confidence = confidence; self.sampleSpanHours = sampleSpanHours; self.explanation = explanation; self.official = official
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "provider", "window", "projectedPercentAtReset", "estimatedExhaustionAt", "velocityPercentPerHour",
            "confidence", "sampleSpanHours", "explanation", "official"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(Provider.self, forKey: .provider)
        window = try container.decode(String.self, forKey: .window)
        projectedPercentAtReset = try decodeStrictOptional(Double.self, forKey: .projectedPercentAtReset, from: container)
        estimatedExhaustionAt = try decodeStrictOptional(Date.self, forKey: .estimatedExhaustionAt, from: container)
        velocityPercentPerHour = try decodeStrictOptional(Double.self, forKey: .velocityPercentPerHour, from: container)
        confidence = try container.decode(String.self, forKey: .confidence)
        sampleSpanHours = try container.decode(Double.self, forKey: .sampleSpanHours)
        explanation = try container.decode(String.self, forKey: .explanation)
        official = try container.decode(Bool.self, forKey: .official)
    }
}

public enum CapabilityState: Equatable, Sendable { case blocked(String) }

public enum AppGroupConfiguration {
    public static let infoPlistKey = "APP_GROUP_IDENTIFIER"
    /// The checked-in source marker is accepted only by Debug/Personal-Team
    /// development builds. Release validation still requires a real
    /// team-registered identifier before distribution.
    public static let releasePlaceholder = "REPLACE_WITH_TEAM_CONFIGURED_ID"

    public static func validatedIdentifier(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("group."),
              !value.contains("$(") else { return nil }

#if !DEBUG
        guard !value.contains(releasePlaceholder) else { return nil }
#endif

        // App Group identifiers are provisioned values, not arbitrary paths or
        // build-setting expressions. Keep this check deliberately small and
        // provider-neutral, but reject values that could otherwise reach
        // FileManager.containerURL as malformed identifiers.
        let suffix = value.dropFirst("group.".count)
        guard !suffix.isEmpty,
              suffix.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ component in
                  !component.isEmpty && component.allSatisfy { character in
                      character.isLetter || character.isNumber || character == "-" || character == "_"
                  }
              }) else { return nil }
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
#if os(iOS)
        try JSONEncoder.lifeOS.encode(snapshot).write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
        try JSONEncoder.lifeOS.encode(snapshot).write(to: target, options: .atomic)
#endif
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
    static var lifeOS: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { nestedDecoder in
            let container = try nestedDecoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = fractional.date(from: raw) ?? standard.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 timestamp")
            }
            return date
        }
        return decoder
    }
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
