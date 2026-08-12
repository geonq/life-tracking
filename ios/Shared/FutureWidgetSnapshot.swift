import Foundation

/// The only privacy modes that a future-module widget snapshot may carry.
///
/// `redacted` is deliberately the default.  A producer must explicitly opt in to
/// `summaryAllowed` before any aggregate value can cross the app/widget boundary.
public enum WidgetPrivacyMode: String, Codable, Equatable, Sendable {
    case redacted
    case summaryAllowed = "summary_allowed"
}

public enum WidgetConnectorAvailability: String, Codable, Equatable, Sendable {
    case connected
    case unavailable
}

public enum WidgetConsentState: String, Codable, Equatable, Sendable {
    case granted
    case notGranted = "not_granted"
}

/// Freshness is carried with each module instead of being inferred by the view.
/// Stale values may be shown only with an explicit stale label; unavailable values
/// never carry an amount or score.
public enum WidgetSnapshotFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

public enum WidgetAggregateAvailability: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unavailable
    case redacted
}

private let widgetSafeMaximumCents = 9_007_199_254_740_991
/// The maximum age at which an observed widget aggregate is considered fresh.
/// Providers schedule another timeline at this boundary because WidgetKit does
/// not re-evaluate a persisted entry merely because wall-clock time advanced.
public let futureWidgetFreshnessWindow: TimeInterval = 15 * 60
private let futureWidgetMaximumClockSkew: TimeInterval = 5

private func rejectUnknownWidgetKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: LifeOSAnyCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown future-widget snapshot field"
        ))
    }
}

/// A finance aggregate intentionally contains no account, transaction, merchant,
/// institution, or connector identity.  Amounts are EUR integer cents only.
public struct WidgetSafeFinanceSummary: Codable, Equatable, Sendable {
    public let connector: WidgetConnectorAvailability
    public let consent: WidgetConsentState
    public let freshness: WidgetSnapshotFreshness
    public let observedAt: Date?
    public let currencyCode: String
    public let netWorthCents: Int?
    public let spendCents: Int?
    public let cashFlowCents: Int?

    public init(
        connector: WidgetConnectorAvailability = .unavailable,
        consent: WidgetConsentState = .notGranted,
        freshness: WidgetSnapshotFreshness = .unavailable,
        observedAt: Date? = nil,
        currencyCode: String = "EUR",
        netWorthCents: Int? = nil,
        spendCents: Int? = nil,
        cashFlowCents: Int? = nil
    ) {
        let safeObservedAt = Self.validatedObservedAt(observedAt, now: .now)
        let allowed = connector == .connected && consent == .granted && freshness != .unavailable && safeObservedAt != nil
        self.connector = connector
        self.consent = consent
        self.freshness = freshness
        self.observedAt = allowed ? safeObservedAt : nil
        // Widget finance is intentionally EUR-only; never persist a caller-provided
        // currency string that could carry account metadata or alter formatting.
        self.currencyCode = "EUR"

        // Direct construction is used by tests and by the eventual app producer.
        // Normalize instead of ever allowing an unsafe combination to render.
        self.netWorthCents = allowed ? Self.validatedSignedCents(netWorthCents) : nil
        self.spendCents = allowed ? Self.validatedUnsignedCents(spendCents) : nil
        self.cashFlowCents = allowed ? Self.validatedSignedCents(cashFlowCents) : nil
    }

    public static func unavailable() -> WidgetSafeFinanceSummary {
        WidgetSafeFinanceSummary()
    }

    public static func redacted() -> WidgetSafeFinanceSummary {
        WidgetSafeFinanceSummary()
    }

    public var hasAggregateValue: Bool {
        netWorthCents != nil || spendCents != nil || cashFlowCents != nil
    }

    public var availability: WidgetAggregateAvailability { availability(at: .now) }

    /// Derives freshness from the observation age instead of trusting the
    /// producer's persisted label forever.
    public func availability(at now: Date) -> WidgetAggregateAvailability {
        guard hasAggregateValue, connector == .connected, consent == .granted,
              let observedAt, observedAt.timeIntervalSince1970.isFinite else { return .unavailable }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -futureWidgetMaximumClockSkew else { return .unavailable }
        if freshness == .stale { return .stale }
        return age <= futureWidgetFreshnessWindow ? .fresh : .stale
    }

    private static func validatedObservedAt(_ value: Date?, now: Date) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite,
              value <= now.addingTimeInterval(futureWidgetMaximumClockSkew) else { return nil }
        return value
    }

    private static func validatedSignedCents(_ value: Int?) -> Int? {
        guard let value, value >= -widgetSafeMaximumCents, value <= widgetSafeMaximumCents else { return nil }
        return value
    }

    private static func validatedUnsignedCents(_ value: Int?) -> Int? {
        guard let value, value >= 0, value <= widgetSafeMaximumCents else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case connector, consent, freshness, observedAt, currencyCode
        case netWorthCents, spendCents, cashFlowCents
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: [
            "connector", "consent", "freshness", "observedAt", "currencyCode",
            "netWorthCents", "spendCents", "cashFlowCents"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let connector = try container.decode(WidgetConnectorAvailability.self, forKey: .connector)
        let consent = try container.decode(WidgetConsentState.self, forKey: .consent)
        let freshness = try container.decode(WidgetSnapshotFreshness.self, forKey: .freshness)
        let observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        let currencyCode = try container.decode(String.self, forKey: .currencyCode)
        let netWorth = try container.decodeIfPresent(Int.self, forKey: .netWorthCents)
        let spend = try container.decodeIfPresent(Int.self, forKey: .spendCents)
        let cashFlow = try container.decodeIfPresent(Int.self, forKey: .cashFlowCents)

        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        guard currencyCode == "EUR",
              observedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              observedAt.map({ $0 <= now.addingTimeInterval(futureWidgetMaximumClockSkew) }) ?? true,
              Self.validatedSignedCents(netWorth) == netWorth,
              Self.validatedUnsignedCents(spend) == spend,
              Self.validatedSignedCents(cashFlow) == cashFlow else {
            throw DecodingError.dataCorruptedError(forKey: .currencyCode, in: container, debugDescription: "Unsafe finance aggregate")
        }
        let allowed = connector == .connected && consent == .granted && freshness != .unavailable && observedAt != nil
        guard allowed || (netWorth == nil && spend == nil && cashFlow == nil) else {
            throw DecodingError.dataCorruptedError(forKey: .connector, in: container, debugDescription: "Finance aggregate requires connector, consent, and freshness")
        }
        guard (freshness == .unavailable && observedAt == nil) || (freshness != .unavailable && observedAt != nil) else {
            throw DecodingError.dataCorruptedError(forKey: .freshness, in: container, debugDescription: "Finance freshness and observation timestamp disagree")
        }

        self.connector = connector
        self.consent = consent
        self.freshness = freshness
        self.observedAt = observedAt
        self.currencyCode = currencyCode
        self.netWorthCents = netWorth
        self.spendCents = spend
        self.cashFlowCents = cashFlow
    }

    fileprivate func bounded(to snapshotDate: Date) -> WidgetSafeFinanceSummary {
        guard let observedAt,
              observedAt.timeIntervalSince1970.isFinite,
              observedAt <= snapshotDate else {
            return WidgetSafeFinanceSummary(connector: connector, consent: consent, freshness: .unavailable)
        }
        return self
    }
}

/// Fitness widgets receive aggregate scores only.  No body measurement, meal,
/// photo, supplement, notification, or journal field is representable here.
public struct WidgetSafeFitnessSummary: Codable, Equatable, Sendable {
    public let connector: WidgetConnectorAvailability
    public let consent: WidgetConsentState
    public let freshness: WidgetSnapshotFreshness
    public let observedAt: Date?
    public let healthScore: Double?
    public let recoveryScore: Double?
    public let strainScore: Double?

    public init(
        connector: WidgetConnectorAvailability = .unavailable,
        consent: WidgetConsentState = .notGranted,
        freshness: WidgetSnapshotFreshness = .unavailable,
        observedAt: Date? = nil,
        healthScore: Double? = nil,
        recoveryScore: Double? = nil,
        strainScore: Double? = nil
    ) {
        let safeObservedAt = Self.validatedObservedAt(observedAt, now: .now)
        let allowed = connector == .connected && consent == .granted && freshness != .unavailable && safeObservedAt != nil
        self.connector = connector
        self.consent = consent
        self.freshness = freshness
        self.observedAt = allowed ? safeObservedAt : nil
        self.healthScore = allowed ? Self.validatedScore(healthScore) : nil
        self.recoveryScore = allowed ? Self.validatedScore(recoveryScore) : nil
        self.strainScore = allowed ? Self.validatedScore(strainScore) : nil
    }

    public static func unavailable() -> WidgetSafeFitnessSummary {
        WidgetSafeFitnessSummary()
    }

    public static func redacted() -> WidgetSafeFitnessSummary {
        WidgetSafeFitnessSummary()
    }

    public var hasAggregateValue: Bool {
        healthScore != nil || recoveryScore != nil || strainScore != nil
    }

    public var availability: WidgetAggregateAvailability { availability(at: .now) }

    public func availability(at now: Date) -> WidgetAggregateAvailability {
        guard hasAggregateValue, connector == .connected, consent == .granted,
              let observedAt, observedAt.timeIntervalSince1970.isFinite else { return .unavailable }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -futureWidgetMaximumClockSkew else { return .unavailable }
        if freshness == .stale { return .stale }
        return age <= futureWidgetFreshnessWindow ? .fresh : .stale
    }

    private static func validatedObservedAt(_ value: Date?, now: Date) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite,
              value <= now.addingTimeInterval(futureWidgetMaximumClockSkew) else { return nil }
        return value
    }

    private static func validatedScore(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case connector, consent, freshness, observedAt, healthScore, recoveryScore, strainScore
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: [
            "connector", "consent", "freshness", "observedAt", "healthScore", "recoveryScore", "strainScore"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let connector = try container.decode(WidgetConnectorAvailability.self, forKey: .connector)
        let consent = try container.decode(WidgetConsentState.self, forKey: .consent)
        let freshness = try container.decode(WidgetSnapshotFreshness.self, forKey: .freshness)
        let observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        let health = try container.decodeIfPresent(Double.self, forKey: .healthScore)
        let recovery = try container.decodeIfPresent(Double.self, forKey: .recoveryScore)
        let strain = try container.decodeIfPresent(Double.self, forKey: .strainScore)

        guard Self.validatedScore(health) == health,
              Self.validatedScore(recovery) == recovery,
              Self.validatedScore(strain) == strain else {
            throw DecodingError.dataCorruptedError(forKey: .freshness, in: container, debugDescription: "Unsafe fitness aggregate")
        }
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        guard observedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              observedAt.map({ $0 <= now.addingTimeInterval(futureWidgetMaximumClockSkew) }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .observedAt, in: container, debugDescription: "Fitness observation timestamp is invalid")
        }
        let allowed = connector == .connected && consent == .granted && freshness != .unavailable
        guard allowed || (health == nil && recovery == nil && strain == nil) else {
            throw DecodingError.dataCorruptedError(forKey: .connector, in: container, debugDescription: "Fitness aggregate requires connector, consent, and freshness")
        }
        guard (freshness == .unavailable && observedAt == nil) || (freshness != .unavailable && observedAt != nil) else {
            throw DecodingError.dataCorruptedError(forKey: .freshness, in: container, debugDescription: "Fitness freshness and observation timestamp disagree")
        }

        self.connector = connector
        self.consent = consent
        self.freshness = freshness
        self.observedAt = observedAt
        self.healthScore = health
        self.recoveryScore = recovery
        self.strainScore = strain
    }

    fileprivate func bounded(to snapshotDate: Date) -> WidgetSafeFitnessSummary {
        guard let observedAt,
              observedAt.timeIntervalSince1970.isFinite,
              observedAt <= snapshotDate else {
            return WidgetSafeFitnessSummary(connector: connector, consent: consent, freshness: .unavailable)
        }
        return self
    }
}

/// Fixed units permitted by the Fitness widget boundary. The widget payload
/// never carries HealthKit quantity identifiers or a caller-provided unit.
public enum WidgetFitnessMetricUnit: String, Codable, Equatable, Sendable {
    case score
    case hours
    case breathsPerMinute = "breaths_per_minute"
    case beatsPerMinute = "beats_per_minute"
    case milliseconds
    case percent
    case oxygenPercent = "oxygen_percent"
    case celsius

    public var displayName: String {
        switch self {
        case .score: "score"
        case .hours: "h"
        case .breathsPerMinute: "rpm"
        case .beatsPerMinute: "bpm"
        case .milliseconds: "ms"
        case .percent, .oxygenPercent: "%"
        case .celsius: "°C"
        }
    }
}

/// One scalar Fitness observation. Its bounded value, fixed unit, source,
/// freshness, and timestamp are all validated before they can render.
public struct WidgetFitnessMetric: Codable, Equatable, Sendable {
    public let value: Double?
    public let unit: WidgetFitnessMetricUnit
    public let state: WidgetAggregateAvailability
    public let observedAt: Date?
    public let sourceLabel: String?

    public init(
        value: Double? = nil,
        unit: WidgetFitnessMetricUnit,
        state: WidgetAggregateAvailability = .unavailable,
        observedAt: Date? = nil,
        sourceLabel: String? = nil
    ) {
        let safeValue = Self.validatedValue(value, unit: unit)
        let safeObservedAt = Self.validatedObservedAt(observedAt, now: .now)
        let safeSourceLabel = Self.validatedSourceLabel(sourceLabel)
        let carriesValue = (state == .fresh || state == .stale)
            && safeValue != nil
            && safeObservedAt != nil
            && safeSourceLabel != nil
        self.value = carriesValue ? safeValue : nil
        self.unit = unit
        self.state = carriesValue ? state : (state == .redacted ? .redacted : .unavailable)
        self.observedAt = carriesValue ? safeObservedAt : nil
        self.sourceLabel = carriesValue ? safeSourceLabel : nil
    }

    public static func unavailable(unit: WidgetFitnessMetricUnit) -> WidgetFitnessMetric {
        WidgetFitnessMetric(unit: unit)
    }

    public static func redacted(unit: WidgetFitnessMetricUnit) -> WidgetFitnessMetric {
        WidgetFitnessMetric(unit: unit, state: .redacted)
    }

    public func state(at now: Date) -> WidgetAggregateAvailability {
        guard let value, Self.validatedValue(value, unit: unit) == value,
              let observedAt, observedAt.timeIntervalSince1970.isFinite else {
            return state == .redacted ? .redacted : .unavailable
        }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -futureWidgetMaximumClockSkew else { return .unavailable }
        if state == .stale { return .stale }
        return age <= futureWidgetFreshnessWindow ? .fresh : .stale
    }

    fileprivate func bounded(to snapshotDate: Date) -> WidgetFitnessMetric {
        guard let observedAt,
              observedAt.timeIntervalSince1970.isFinite,
              observedAt <= snapshotDate else {
            return state == .redacted ? .redacted(unit: unit) : .unavailable(unit: unit)
        }
        return self
    }

    private static func validatedValue(_ value: Double?, unit: WidgetFitnessMetricUnit) -> Double? {
        guard let value, value.isFinite else { return nil }
        let range: ClosedRange<Double>
        switch unit {
        case .score, .percent: range = 0...100
        case .hours: range = 0...48
        case .breathsPerMinute: range = 0.1...100
        case .beatsPerMinute: range = 0.1...300
        case .milliseconds: range = 0...5_000
        case .oxygenPercent: range = 0.1...100
        case .celsius: range = 20...45
        }
        guard range.contains(value) else { return nil }
        return value
    }

    private static func validatedObservedAt(_ value: Date?, now: Date) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite,
              value <= now.addingTimeInterval(futureWidgetMaximumClockSkew) else { return nil }
        return value
    }

    private static func validatedSourceLabel(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 100,
              !value.contains("\n"),
              !value.contains("\r") else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case value, unit, state, observedAt, sourceLabel
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: ["value", "unit", "state", "observedAt", "sourceLabel"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(Double.self, forKey: .value)
        let unit = try container.decode(WidgetFitnessMetricUnit.self, forKey: .unit)
        let state = try container.decode(WidgetAggregateAvailability.self, forKey: .state)
        let observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        let sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        guard Self.validatedValue(value, unit: unit) == value,
              observedAt.map({ Self.validatedObservedAt($0, now: now) == $0 }) ?? true,
              sourceLabel.map({ Self.validatedSourceLabel($0) == $0 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsafe Fitness widget metric"
            ))
        }
        let requiresObservation = state == .fresh || state == .stale
        guard requiresObservation == (value != nil && observedAt != nil && sourceLabel != nil),
              !requiresObservation ? (value == nil && observedAt == nil && sourceLabel == nil) : true else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Fitness metric state and value disagree"
            ))
        }
        self.value = value
        self.unit = unit
        self.state = state
        self.observedAt = observedAt
        self.sourceLabel = sourceLabel
    }
}

/// A bounded intraday stress trend. These are at most 24 normalized aggregate
/// buckets plus a validated aggregate window boundary, never raw HealthKit
/// samples or timestamped source records.
public struct WidgetStressTrend: Codable, Equatable, Sendable {
    public let buckets: [Double]
    public let state: WidgetAggregateAvailability
    public let observedAt: Date?
    public let sourceLabel: String?
    public let windowStart: Date?
    public let windowEnd: Date?

    public init(
        buckets: [Double] = [],
        state: WidgetAggregateAvailability = .unavailable,
        observedAt: Date? = nil,
        sourceLabel: String? = nil,
        windowStart: Date? = nil,
        windowEnd: Date? = nil
    ) {
        let safeBuckets = Self.validatedBuckets(buckets)
        let safeObservedAt = Self.validatedObservedAt(observedAt, now: .now)
        let safeSourceLabel = Self.validatedSourceLabel(sourceLabel)
        let safeWindowStart = Self.validatedWindowDate(windowStart, now: .now)
        let safeWindowEnd = Self.validatedWindowDate(windowEnd, now: .now)
        let validWindow: Bool
        if state == .fresh || state == .stale {
            validWindow = safeObservedAt != nil
                && safeWindowStart != nil
                && safeWindowEnd != nil
                && safeWindowStart! < safeWindowEnd!
                && abs(safeWindowEnd!.timeIntervalSince(safeObservedAt!)) <= futureWidgetMaximumClockSkew
        } else {
            validWindow = safeWindowStart == nil && safeWindowEnd == nil
        }
        let carriesValue = (state == .fresh || state == .stale)
            && !safeBuckets.isEmpty
            && safeObservedAt != nil
            && safeSourceLabel != nil
            && validWindow
        self.buckets = carriesValue ? safeBuckets : []
        self.state = carriesValue ? state : (state == .redacted ? .redacted : .unavailable)
        self.observedAt = carriesValue ? safeObservedAt : nil
        self.sourceLabel = carriesValue ? safeSourceLabel : nil
        self.windowStart = carriesValue ? safeWindowStart : nil
        self.windowEnd = carriesValue ? safeWindowEnd : nil
    }

    public static func unavailable() -> WidgetStressTrend { WidgetStressTrend() }
    public static func redacted() -> WidgetStressTrend { WidgetStressTrend(state: .redacted) }

    public func state(at now: Date) -> WidgetAggregateAvailability {
        guard !buckets.isEmpty, let observedAt,
              observedAt.timeIntervalSince1970.isFinite else {
            return state == .redacted ? .redacted : .unavailable
        }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -futureWidgetMaximumClockSkew else { return .unavailable }
        if state == .stale { return .stale }
        return age <= futureWidgetFreshnessWindow ? .fresh : .stale
    }

    public var axisDates: [Date]? {
        guard let windowStart, let windowEnd, windowStart < windowEnd else { return nil }
        let interval = windowEnd.timeIntervalSince(windowStart)
        return (0..<4).map { windowStart.addingTimeInterval(interval * Double($0) / 3) }
    }

    public var latestObservedAt: Date? {
        [observedAt, windowEnd].compactMap { $0 }.max()
    }

    fileprivate func bounded(to snapshotDate: Date) -> WidgetStressTrend {
        guard let observedAt, observedAt.timeIntervalSince1970.isFinite, observedAt <= snapshotDate,
              windowEnd.map({ $0 <= snapshotDate }) ?? true else {
            return state == .redacted ? .redacted() : .unavailable()
        }
        return WidgetStressTrend(
            buckets: buckets,
            state: state,
            observedAt: observedAt,
            sourceLabel: sourceLabel,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
    }

    private static func validatedBuckets(_ value: [Double]) -> [Double] {
        guard !value.isEmpty, value.count <= 24,
              value.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { return [] }
        return value
    }

    private static func validatedObservedAt(_ value: Date?, now: Date) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite,
              value <= now.addingTimeInterval(futureWidgetMaximumClockSkew) else { return nil }
        return value
    }

    private static func validatedWindowDate(_ value: Date?, now: Date) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite,
              value <= now.addingTimeInterval(futureWidgetMaximumClockSkew) else { return nil }
        return value
    }

    private static func validatedSourceLabel(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 100,
              !value.contains("\n"),
              !value.contains("\r") else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case buckets, state, observedAt, sourceLabel, windowStart, windowEnd
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: ["buckets", "state", "observedAt", "sourceLabel", "windowStart", "windowEnd"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let buckets = try container.decode([Double].self, forKey: .buckets)
        let state = try container.decode(WidgetAggregateAvailability.self, forKey: .state)
        let observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        let sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        let windowStart = try container.decodeIfPresent(Date.self, forKey: .windowStart)
        let windowEnd = try container.decodeIfPresent(Date.self, forKey: .windowEnd)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        guard Self.validatedBuckets(buckets) == buckets,
              observedAt.map({ Self.validatedObservedAt($0, now: now) == $0 }) ?? true,
              sourceLabel.map({ Self.validatedSourceLabel($0) == $0 }) ?? true,
              windowStart.map({ Self.validatedWindowDate($0, now: now) == $0 }) ?? true,
              windowEnd.map({ Self.validatedWindowDate($0, now: now) == $0 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsafe stress trend aggregate"
            ))
        }
        let requiresObservation = state == .fresh || state == .stale
        let validWindow = requiresObservation
            ? (observedAt != nil && windowStart != nil && windowEnd != nil
               && windowStart! < windowEnd!
               && abs(windowEnd!.timeIntervalSince(observedAt!)) <= futureWidgetMaximumClockSkew)
            : (windowStart == nil && windowEnd == nil)
        guard requiresObservation == (!buckets.isEmpty && observedAt != nil && sourceLabel != nil && validWindow),
              !requiresObservation ? (buckets.isEmpty && observedAt == nil && sourceLabel == nil) : true else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Stress trend state and buckets disagree"
            ))
        }
        self.buckets = buckets
        self.state = state
        self.observedAt = observedAt
        self.sourceLabel = sourceLabel
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

/// Energy Reserve's chips are aggregate deltas. The invariant is explicit so
/// a rendered level cannot silently disagree with the charged/discharged data.
public struct WidgetEnergyReserveSummary: Codable, Equatable, Sendable {
    public let level: WidgetFitnessMetric
    public let startingLevel: WidgetFitnessMetric
    public let chargedPercent: WidgetFitnessMetric
    public let dischargedPercent: WidgetFitnessMetric
    public let lastChargedAt: Date?

    public init(
        level: WidgetFitnessMetric = .unavailable(unit: .percent),
        startingLevel: WidgetFitnessMetric = .unavailable(unit: .percent),
        chargedPercent: WidgetFitnessMetric = .unavailable(unit: .percent),
        dischargedPercent: WidgetFitnessMetric = .unavailable(unit: .percent),
        lastChargedAt: Date? = nil
    ) {
        let validUnits = [level, startingLevel, chargedPercent, dischargedPercent]
            .allSatisfy { $0.unit == .percent }
        let values = [level.value, startingLevel.value, chargedPercent.value, dischargedPercent.value]
        let reconciles = values.allSatisfy { $0 != nil }
            ? abs((startingLevel.value ?? 0) + (chargedPercent.value ?? 0) - (dischargedPercent.value ?? 0) - (level.value ?? 0)) <= 0.01
            : true
        let latestMetricObservation = [level.observedAt, startingLevel.observedAt, chargedPercent.observedAt, dischargedPercent.observedAt]
            .compactMap { $0 }
            .max()
        let validLastChargedAt = lastChargedAt.map { date in
            date.timeIntervalSince1970.isFinite
                && date <= Date.now.addingTimeInterval(futureWidgetMaximumClockSkew)
                && (latestMetricObservation.map { date <= $0 } ?? false)
                && chargedPercent.value != nil
        } ?? (chargedPercent.value == nil)
        if validUnits && reconciles && validLastChargedAt {
            self.level = level
            self.startingLevel = startingLevel
            self.chargedPercent = chargedPercent
            self.dischargedPercent = dischargedPercent
            self.lastChargedAt = lastChargedAt
        } else {
            self.level = .unavailable(unit: .percent)
            self.startingLevel = .unavailable(unit: .percent)
            self.chargedPercent = .unavailable(unit: .percent)
            self.dischargedPercent = .unavailable(unit: .percent)
            self.lastChargedAt = nil
        }
    }

    public static func unavailable() -> WidgetEnergyReserveSummary { WidgetEnergyReserveSummary() }

    public static func redacted() -> WidgetEnergyReserveSummary {
        WidgetEnergyReserveSummary(
            level: .redacted(unit: .percent),
            startingLevel: .redacted(unit: .percent),
            chargedPercent: .redacted(unit: .percent),
            dischargedPercent: .redacted(unit: .percent)
        )
    }

    public static func demo(at observedAt: Date) -> WidgetEnergyReserveSummary {
        func metric(_ value: Double) -> WidgetFitnessMetric {
            WidgetFitnessMetric(value: value, unit: .percent, state: .fresh, observedAt: observedAt, sourceLabel: "DEMO · NOT LIVE")
        }
        return WidgetEnergyReserveSummary(
            level: metric(70),
            startingLevel: metric(48),
            chargedPercent: metric(38),
            dischargedPercent: metric(16),
            lastChargedAt: observedAt.addingTimeInterval(-40 * 60)
        )
    }

    public var observedAt: Date? {
        [level.observedAt, startingLevel.observedAt, chargedPercent.observedAt,
         dischargedPercent.observedAt, lastChargedAt].compactMap { $0 }.min()
    }

    public var latestObservedAt: Date? {
        [level.observedAt, startingLevel.observedAt, chargedPercent.observedAt,
         dischargedPercent.observedAt, lastChargedAt].compactMap { $0 }.max()
    }

    public func displayState(at now: Date) -> WidgetAggregateAvailability {
        let states = [level, startingLevel, chargedPercent, dischargedPercent].map { $0.state(at: now) }
        if states.contains(.fresh) { return states.contains(.stale) ? .stale : .fresh }
        if states.contains(.stale) { return .stale }
        if states.contains(.redacted) { return .redacted }
        return .unavailable
    }

    fileprivate func bounded(to snapshotDate: Date) -> WidgetEnergyReserveSummary {
        WidgetEnergyReserveSummary(
            level: level.bounded(to: snapshotDate),
            startingLevel: startingLevel.bounded(to: snapshotDate),
            chargedPercent: chargedPercent.bounded(to: snapshotDate),
            dischargedPercent: dischargedPercent.bounded(to: snapshotDate),
            lastChargedAt: lastChargedAt.flatMap { $0 <= snapshotDate ? $0 : nil }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case level, startingLevel, chargedPercent, dischargedPercent, lastChargedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: ["level", "startingLevel", "chargedPercent", "dischargedPercent", "lastChargedAt"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let level = try container.decode(WidgetFitnessMetric.self, forKey: .level)
        let startingLevel = try container.decode(WidgetFitnessMetric.self, forKey: .startingLevel)
        let chargedPercent = try container.decode(WidgetFitnessMetric.self, forKey: .chargedPercent)
        let dischargedPercent = try container.decode(WidgetFitnessMetric.self, forKey: .dischargedPercent)
        let lastChargedAt = try container.decodeIfPresent(Date.self, forKey: .lastChargedAt)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        let latestMetricObservation = [level.observedAt, startingLevel.observedAt, chargedPercent.observedAt, dischargedPercent.observedAt]
            .compactMap { $0 }
            .max()
        guard [level, startingLevel, chargedPercent, dischargedPercent].allSatisfy({ $0.unit == .percent }),
              lastChargedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= now.addingTimeInterval(futureWidgetMaximumClockSkew) }) ?? true,
              (chargedPercent.value == nil) == (lastChargedAt == nil),
              lastChargedAt.map({ chargedAt in
                  latestMetricObservation.map { observation in chargedAt <= observation } ?? false
              }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsafe Energy Reserve aggregate"))
        }
        if let levelValue = level.value,
           let startingValue = startingLevel.value,
           let chargedValue = chargedPercent.value,
           let dischargedValue = dischargedPercent.value {
            guard abs(startingValue + chargedValue - dischargedValue - levelValue) <= 0.01 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Energy Reserve chips do not reconcile with level"))
            }
        }
        self.level = level
        self.startingLevel = startingLevel
        self.chargedPercent = chargedPercent
        self.dischargedPercent = dischargedPercent
        self.lastChargedAt = lastChargedAt
    }
}

/// Aggregate-only data for the four exact Fitness widget families. It has no
/// raw samples, source identifiers, journal fields, or HealthKit identifiers.
public struct WidgetSafeFitnessWidgetsSummary: Codable, Equatable, Sendable {
    public let connector: WidgetConnectorAvailability
    public let consent: WidgetConsentState
    public let strain: WidgetFitnessMetric
    public let recovery: WidgetFitnessMetric
    public let sleepScore: WidgetFitnessMetric
    public let sleepDuration: WidgetFitnessMetric
    public let respiration: WidgetFitnessMetric
    public let heartRate: WidgetFitnessMetric
    public let hrv: WidgetFitnessMetric
    public let spo2: WidgetFitnessMetric
    public let temperature: WidgetFitnessMetric
    public let stressScore: WidgetFitnessMetric
    public let stressTrend: WidgetStressTrend
    public let energyReserve: WidgetEnergyReserveSummary
    public let provenanceLabel: String?

    public init(
        connector: WidgetConnectorAvailability = .unavailable,
        consent: WidgetConsentState = .notGranted,
        strain: WidgetFitnessMetric = .unavailable(unit: .score),
        recovery: WidgetFitnessMetric = .unavailable(unit: .score),
        sleepScore: WidgetFitnessMetric = .unavailable(unit: .score),
        sleepDuration: WidgetFitnessMetric = .unavailable(unit: .hours),
        respiration: WidgetFitnessMetric = .unavailable(unit: .breathsPerMinute),
        heartRate: WidgetFitnessMetric = .unavailable(unit: .beatsPerMinute),
        hrv: WidgetFitnessMetric = .unavailable(unit: .milliseconds),
        spo2: WidgetFitnessMetric = .unavailable(unit: .oxygenPercent),
        temperature: WidgetFitnessMetric = .unavailable(unit: .celsius),
        stressScore: WidgetFitnessMetric = .unavailable(unit: .score),
        stressTrend: WidgetStressTrend = .unavailable(),
        energyReserve: WidgetEnergyReserveSummary = .unavailable(),
        provenanceLabel: String? = nil
    ) {
        let allowed = connector == .connected && consent == .granted
        func normalized(_ metric: WidgetFitnessMetric, unit: WidgetFitnessMetricUnit) -> WidgetFitnessMetric {
            metric.unit == unit ? metric : .unavailable(unit: unit)
        }
        let safeStrain = normalized(strain, unit: .score)
        let safeRecovery = normalized(recovery, unit: .score)
        let safeSleepScore = normalized(sleepScore, unit: .score)
        let safeSleepDuration = normalized(sleepDuration, unit: .hours)
        let safeRespiration = normalized(respiration, unit: .breathsPerMinute)
        let safeHeartRate = normalized(heartRate, unit: .beatsPerMinute)
        let safeHRV = normalized(hrv, unit: .milliseconds)
        let safeSpO2 = normalized(spo2, unit: .oxygenPercent)
        let safeTemperature = normalized(temperature, unit: .celsius)
        let safeStressScore = normalized(stressScore, unit: .score)
        let stressAgrees = safeStressScore.value == nil || (stressTrend.buckets.last.map {
            abs($0 - (safeStressScore.value ?? 0)) <= 0.01
        } ?? true)
        self.connector = connector
        self.consent = consent
        self.strain = allowed ? safeStrain : .unavailable(unit: .score)
        self.recovery = allowed ? safeRecovery : .unavailable(unit: .score)
        self.sleepScore = allowed ? safeSleepScore : .unavailable(unit: .score)
        self.sleepDuration = allowed ? safeSleepDuration : .unavailable(unit: .hours)
        self.respiration = allowed ? safeRespiration : .unavailable(unit: .breathsPerMinute)
        self.heartRate = allowed ? safeHeartRate : .unavailable(unit: .beatsPerMinute)
        self.hrv = allowed ? safeHRV : .unavailable(unit: .milliseconds)
        self.spo2 = allowed ? safeSpO2 : .unavailable(unit: .oxygenPercent)
        self.temperature = allowed ? safeTemperature : .unavailable(unit: .celsius)
        self.stressScore = allowed && stressAgrees ? safeStressScore : .unavailable(unit: .score)
        self.stressTrend = allowed ? stressTrend : .unavailable()
        self.energyReserve = allowed ? energyReserve : .unavailable()
        let hasValue = allowed && (
            [safeStrain, safeRecovery, safeSleepScore, safeSleepDuration, safeRespiration, safeHeartRate, safeHRV, safeSpO2, safeTemperature, safeStressScore]
                .contains { $0.value != nil }
                || !stressTrend.buckets.isEmpty
                || energyReserve.level.value != nil
        )
        self.provenanceLabel = hasValue ? Self.validatedLabel(provenanceLabel) : nil
    }

    public static func unavailable() -> WidgetSafeFitnessWidgetsSummary {
        WidgetSafeFitnessWidgetsSummary()
    }

    public static func redacted() -> WidgetSafeFitnessWidgetsSummary {
        WidgetSafeFitnessWidgetsSummary(
            connector: .connected,
            consent: .granted,
            strain: .redacted(unit: .score),
            recovery: .redacted(unit: .score),
            sleepScore: .redacted(unit: .score),
            sleepDuration: .redacted(unit: .hours),
            respiration: .redacted(unit: .breathsPerMinute),
            heartRate: .redacted(unit: .beatsPerMinute),
            hrv: .redacted(unit: .milliseconds),
            spo2: .redacted(unit: .oxygenPercent),
            temperature: .redacted(unit: .celsius),
            stressScore: .redacted(unit: .score),
            stressTrend: .redacted(),
            energyReserve: .redacted()
        )
    }

    public static func demo(at observedAt: Date) -> WidgetSafeFitnessWidgetsSummary {
        func metric(_ value: Double, unit: WidgetFitnessMetricUnit) -> WidgetFitnessMetric {
            WidgetFitnessMetric(value: value, unit: unit, state: .fresh, observedAt: observedAt, sourceLabel: "DEMO · NOT LIVE")
        }
        return WidgetSafeFitnessWidgetsSummary(
            connector: .connected,
            consent: .granted,
            strain: metric(15, unit: .score),
            recovery: metric(90, unit: .score),
            sleepScore: metric(80, unit: .score),
            sleepDuration: metric(2.9, unit: .hours),
            respiration: metric(9.3, unit: .breathsPerMinute),
            heartRate: metric(72, unit: .beatsPerMinute),
            hrv: metric(33.6, unit: .milliseconds),
            spo2: metric(94.7, unit: .oxygenPercent),
            temperature: metric(35.6, unit: .celsius),
            stressScore: metric(53, unit: .score),
            stressTrend: WidgetStressTrend(
                buckets: [31, 38, 35, 46, 39, 33, 42, 61, 53, 56, 52, 53],
                state: .fresh,
                observedAt: observedAt,
                sourceLabel: "DEMO · NOT LIVE",
                windowStart: observedAt.addingTimeInterval(-18 * 60 * 60),
                windowEnd: observedAt
            ),
            energyReserve: .demo(at: observedAt),
            provenanceLabel: "DEMO · NOT LIVE"
        )
    }

    public var observedAt: Date? {
        metrics.compactMap(\.observedAt).min()
    }

    public var latestObservedAt: Date? {
        (metrics.compactMap(\.observedAt) + [stressTrend.latestObservedAt, energyReserve.latestObservedAt].compactMap { $0 }).max()
    }

    public var isDemoFixture: Bool {
        let demoLabel = "DEMO · NOT LIVE"
        return provenanceLabel == demoLabel
            || stressTrend.sourceLabel == demoLabel
            || metrics.contains { $0.sourceLabel == demoLabel }
    }

    public func displayState(at now: Date) -> WidgetAggregateAvailability {
        let states = metrics.map { $0.state(at: now) } + [stressTrend.state(at: now), energyReserve.displayState(at: now)]
        if states.contains(.fresh) { return states.contains(.stale) ? .stale : .fresh }
        if states.contains(.stale) { return .stale }
        if states.contains(.redacted) { return .redacted }
        return .unavailable
    }

    fileprivate func bounded(to snapshotDate: Date) -> WidgetSafeFitnessWidgetsSummary {
        WidgetSafeFitnessWidgetsSummary(
            connector: connector,
            consent: consent,
            strain: strain.bounded(to: snapshotDate),
            recovery: recovery.bounded(to: snapshotDate),
            sleepScore: sleepScore.bounded(to: snapshotDate),
            sleepDuration: sleepDuration.bounded(to: snapshotDate),
            respiration: respiration.bounded(to: snapshotDate),
            heartRate: heartRate.bounded(to: snapshotDate),
            hrv: hrv.bounded(to: snapshotDate),
            spo2: spo2.bounded(to: snapshotDate),
            temperature: temperature.bounded(to: snapshotDate),
            stressScore: stressScore.bounded(to: snapshotDate),
            stressTrend: stressTrend.bounded(to: snapshotDate),
            energyReserve: energyReserve.bounded(to: snapshotDate),
            provenanceLabel: provenanceLabel
        )
    }

    private var metrics: [WidgetFitnessMetric] {
        [strain, recovery, sleepScore, sleepDuration, respiration, heartRate, hrv, spo2, temperature, stressScore,
         energyReserve.level, energyReserve.startingLevel, energyReserve.chargedPercent, energyReserve.dischargedPercent]
    }

    private static func validatedLabel(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 100,
              !value.contains("\n"),
              !value.contains("\r") else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case connector, consent, strain, recovery, sleepScore, sleepDuration, respiration, heartRate, hrv, spo2, temperature
        case stressScore, stressTrend, energyReserve, provenanceLabel
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: [
            "connector", "consent", "strain", "recovery", "sleepScore", "sleepDuration", "respiration", "heartRate", "hrv", "spo2", "temperature",
            "stressScore", "stressTrend", "energyReserve", "provenanceLabel"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let connector = try container.decode(WidgetConnectorAvailability.self, forKey: .connector)
        let consent = try container.decode(WidgetConsentState.self, forKey: .consent)
        let strain = try container.decode(WidgetFitnessMetric.self, forKey: .strain)
        let recovery = try container.decode(WidgetFitnessMetric.self, forKey: .recovery)
        let sleepScore = try container.decode(WidgetFitnessMetric.self, forKey: .sleepScore)
        let sleepDuration = try container.decode(WidgetFitnessMetric.self, forKey: .sleepDuration)
        let respiration = try container.decode(WidgetFitnessMetric.self, forKey: .respiration)
        let heartRate = try container.decode(WidgetFitnessMetric.self, forKey: .heartRate)
        let hrv = try container.decode(WidgetFitnessMetric.self, forKey: .hrv)
        let spo2 = try container.decode(WidgetFitnessMetric.self, forKey: .spo2)
        let temperature = try container.decode(WidgetFitnessMetric.self, forKey: .temperature)
        let stressScore = try container.decode(WidgetFitnessMetric.self, forKey: .stressScore)
        let stressTrend = try container.decode(WidgetStressTrend.self, forKey: .stressTrend)
        let energyReserve = try container.decode(WidgetEnergyReserveSummary.self, forKey: .energyReserve)
        let provenanceLabel = try container.decodeIfPresent(String.self, forKey: .provenanceLabel)
        let expected: [(WidgetFitnessMetric, WidgetFitnessMetricUnit)] = [
            (strain, .score), (recovery, .score), (sleepScore, .score), (sleepDuration, .hours), (respiration, .breathsPerMinute),
            (heartRate, .beatsPerMinute), (hrv, .milliseconds), (spo2, .oxygenPercent), (temperature, .celsius), (stressScore, .score)
        ]
        guard expected.allSatisfy({ $0.0.unit == $0.1 }),
              Self.validatedLabel(provenanceLabel) == provenanceLabel,
              stressScore.value == nil || (stressTrend.buckets.last.map({ abs($0 - (stressScore.value ?? 0)) <= 0.01 }) ?? true) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsafe Fitness widget units or label"))
        }
        let allowed = connector == .connected && consent == .granted
        if !allowed {
            let values = expected.map(\.0) + [energyReserve.level, energyReserve.startingLevel, energyReserve.chargedPercent, energyReserve.dischargedPercent]
            guard values.allSatisfy({ $0.value == nil && $0.state != .fresh && $0.state != .stale }),
                  stressTrend.buckets.isEmpty,
                  provenanceLabel == nil,
                  energyReserve.lastChargedAt == nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Fitness widget values require connector consent"))
            }
        }
        self.connector = connector
        self.consent = consent
        self.strain = strain
        self.recovery = recovery
        self.sleepScore = sleepScore
        self.sleepDuration = sleepDuration
        self.respiration = respiration
        self.heartRate = heartRate
        self.hrv = hrv
        self.spo2 = spo2
        self.temperature = temperature
        self.stressScore = stressScore
        self.stressTrend = stressTrend
        self.energyReserve = energyReserve
        self.provenanceLabel = provenanceLabel
    }
}

/// A single privacy-safe Nutrition observation. Values are deliberately scalar
/// aggregates only: the widget boundary cannot represent a meal, image, food
/// label, journal entry, or any other identifying payload.
public struct WidgetNutritionMetric: Codable, Equatable, Sendable {
    public let value: Double?
    public let state: WidgetAggregateAvailability
    public let observedAt: Date?
    public let sourceLabel: String?

    public init(
        value: Double? = nil,
        state: WidgetAggregateAvailability = .unavailable,
        observedAt: Date? = nil,
        sourceLabel: String? = nil
    ) {
        let safeValue = Self.validatedValue(value)
        let safeObservedAt = Self.validatedObservedAt(observedAt, now: .now)
        let carriesValue = (state == .fresh || state == .stale)
            && safeValue != nil
            && safeObservedAt != nil
        self.value = carriesValue ? safeValue : nil
        self.state = carriesValue ? state : (state == .redacted ? .redacted : .unavailable)
        self.observedAt = carriesValue ? safeObservedAt : nil
        self.sourceLabel = carriesValue ? Self.validatedSourceLabel(sourceLabel) : nil
    }

    public static func unavailable() -> WidgetNutritionMetric { WidgetNutritionMetric() }
    public static func redacted() -> WidgetNutritionMetric {
        WidgetNutritionMetric(state: .redacted)
    }

    public func state(at now: Date) -> WidgetAggregateAvailability {
        guard let value, value.isFinite, value >= 0,
              let observedAt, observedAt.timeIntervalSince1970.isFinite else {
            return state == .redacted ? .redacted : .unavailable
        }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -futureWidgetMaximumClockSkew else { return .unavailable }
        if state == .stale { return .stale }
        return age <= futureWidgetFreshnessWindow ? .fresh : .stale
    }

    fileprivate func bounded(to snapshotDate: Date) -> WidgetNutritionMetric {
        guard let observedAt,
              observedAt.timeIntervalSince1970.isFinite,
              observedAt <= snapshotDate else {
            return state == .redacted ? .redacted() : .unavailable()
        }
        return self
    }

    private static func validatedValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100_000).contains(value) else { return nil }
        return value
    }

    private static func validatedObservedAt(_ value: Date?, now: Date) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite,
              value <= now.addingTimeInterval(futureWidgetMaximumClockSkew) else { return nil }
        return value
    }

    private static func validatedSourceLabel(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 100,
              !value.contains("\n"),
              !value.contains("\r") else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case value, state, observedAt, sourceLabel
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: ["value", "state", "observedAt", "sourceLabel"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(Double.self, forKey: .value)
        let state = try container.decode(WidgetAggregateAvailability.self, forKey: .state)
        let observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        let sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        let validValue = Self.validatedValue(value) == value
        let validObservedAt = observedAt.map {
            Self.validatedObservedAt($0, now: now) == $0
        } ?? true
        guard validValue, validObservedAt,
              sourceLabel.map({ Self.validatedSourceLabel($0) == $0 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsafe Nutrition widget metric"
            ))
        }

        let requiresObservation = state == .fresh || state == .stale
        guard requiresObservation == (value != nil && observedAt != nil && sourceLabel != nil),
              !requiresObservation ? (value == nil && observedAt == nil && sourceLabel == nil) : true else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Nutrition metric state and value disagree"
            ))
        }
        self.value = value
        self.state = state
        self.observedAt = observedAt
        self.sourceLabel = sourceLabel
    }
}

/// Aggregate-only Nutrition payload shared by the three exact medium widgets.
/// Every field is independently unavailable/stale/redacted; one missing source
/// never becomes a zero or collapses another metric to a fake value.
public struct WidgetSafeNutritionSummary: Codable, Equatable, Sendable {
    public let connector: WidgetConnectorAvailability
    public let consent: WidgetConsentState
    public let caloriesEaten: WidgetNutritionMetric
    public let calorieGoal: WidgetNutritionMetric
    public let fatGrams: WidgetNutritionMetric
    public let fatGoalGrams: WidgetNutritionMetric
    public let carbsGrams: WidgetNutritionMetric
    public let carbsGoalGrams: WidgetNutritionMetric
    public let proteinGrams: WidgetNutritionMetric
    public let proteinGoalGrams: WidgetNutritionMetric
    public let caloriesBurned: WidgetNutritionMetric
    public let qualityScore: WidgetNutritionMetric
    public let qualityLabel: String?
    public let provenanceLabel: String?

    public init(
        connector: WidgetConnectorAvailability = .unavailable,
        consent: WidgetConsentState = .notGranted,
        caloriesEaten: WidgetNutritionMetric = .unavailable(),
        calorieGoal: WidgetNutritionMetric = .unavailable(),
        fatGrams: WidgetNutritionMetric = .unavailable(),
        fatGoalGrams: WidgetNutritionMetric = .unavailable(),
        carbsGrams: WidgetNutritionMetric = .unavailable(),
        carbsGoalGrams: WidgetNutritionMetric = .unavailable(),
        proteinGrams: WidgetNutritionMetric = .unavailable(),
        proteinGoalGrams: WidgetNutritionMetric = .unavailable(),
        caloriesBurned: WidgetNutritionMetric = .unavailable(),
        qualityScore: WidgetNutritionMetric = .unavailable(),
        qualityLabel: String? = nil,
        provenanceLabel: String? = nil
    ) {
        let allowed = connector == .connected && consent == .granted
        self.connector = connector
        self.consent = consent
        self.caloriesEaten = allowed ? caloriesEaten : .unavailable()
        self.calorieGoal = allowed ? calorieGoal : .unavailable()
        self.fatGrams = allowed ? fatGrams : .unavailable()
        self.fatGoalGrams = allowed ? fatGoalGrams : .unavailable()
        self.carbsGrams = allowed ? carbsGrams : .unavailable()
        self.carbsGoalGrams = allowed ? carbsGoalGrams : .unavailable()
        self.proteinGrams = allowed ? proteinGrams : .unavailable()
        self.proteinGoalGrams = allowed ? proteinGoalGrams : .unavailable()
        self.caloriesBurned = allowed ? caloriesBurned : .unavailable()
        self.qualityScore = allowed ? Self.validatedQualityMetric(qualityScore) : .unavailable()
        self.qualityLabel = allowed && qualityScore.value != nil ? Self.validatedLabel(qualityLabel) : nil
        self.provenanceLabel = allowed && [caloriesEaten, calorieGoal, fatGrams, fatGoalGrams,
                                           carbsGrams, carbsGoalGrams, proteinGrams, proteinGoalGrams,
                                           caloriesBurned, qualityScore].contains(where: { $0.value != nil })
            ? Self.validatedLabel(provenanceLabel) : nil
    }

    public static func unavailable() -> WidgetSafeNutritionSummary {
        WidgetSafeNutritionSummary()
    }

    public static func redacted() -> WidgetSafeNutritionSummary {
        WidgetSafeNutritionSummary(
            connector: .connected,
            consent: .granted,
            caloriesEaten: .redacted(),
            calorieGoal: .redacted(),
            fatGrams: .redacted(),
            fatGoalGrams: .redacted(),
            carbsGrams: .redacted(),
            carbsGoalGrams: .redacted(),
            proteinGrams: .redacted(),
            proteinGoalGrams: .redacted(),
            caloriesBurned: .redacted(),
            qualityScore: .redacted()
        )
    }

    /// Deterministic widget-only content for visual review. It carries no meal
    /// detail and the score explicitly says it is fixture-only.
    public static func demo(at observedAt: Date) -> WidgetSafeNutritionSummary {
        func metric(_ value: Double) -> WidgetNutritionMetric {
            WidgetNutritionMetric(
                value: value,
                state: .fresh,
                observedAt: observedAt,
                sourceLabel: "DEMO · NOT LIVE"
            )
        }
        return WidgetSafeNutritionSummary(
            connector: .connected,
            consent: .granted,
            caloriesEaten: metric(1_860),
            calorieGoal: metric(2_200),
            fatGrams: metric(61),
            fatGoalGrams: metric(75),
            carbsGrams: metric(194),
            carbsGoalGrams: metric(250),
            proteinGrams: metric(138),
            proteinGoalGrams: metric(160),
            caloriesBurned: metric(2_340),
            qualityScore: metric(93),
            qualityLabel: "Fixture score · not live",
            provenanceLabel: "DEMO · NOT LIVE"
        )
    }

    public var observedAt: Date? {
        metrics.compactMap(\.observedAt).min()
    }

    /// The decode/store boundary must account for every nested observation.
    /// `observedAt` intentionally remains the earliest observation for refresh
    /// scheduling, while this max is used to reject mixed old+future payloads.
    fileprivate var latestObservedAt: Date? {
        metrics.compactMap(\.observedAt).max()
    }

    public var hasAggregateValue: Bool { metrics.contains { $0.value != nil } }

    public func displayState(at now: Date) -> WidgetAggregateAvailability {
        let states = metrics.map { $0.state(at: now) }
        if states.contains(.fresh) { return states.contains(.stale) ? .stale : .fresh }
        if states.contains(.stale) { return .stale }
        if states.contains(.redacted) { return .redacted }
        return .unavailable
    }

    fileprivate func bounded(to snapshotDate: Date) -> WidgetSafeNutritionSummary {
        WidgetSafeNutritionSummary(
            connector: connector,
            consent: consent,
            caloriesEaten: caloriesEaten.bounded(to: snapshotDate),
            calorieGoal: calorieGoal.bounded(to: snapshotDate),
            fatGrams: fatGrams.bounded(to: snapshotDate),
            fatGoalGrams: fatGoalGrams.bounded(to: snapshotDate),
            carbsGrams: carbsGrams.bounded(to: snapshotDate),
            carbsGoalGrams: carbsGoalGrams.bounded(to: snapshotDate),
            proteinGrams: proteinGrams.bounded(to: snapshotDate),
            proteinGoalGrams: proteinGoalGrams.bounded(to: snapshotDate),
            caloriesBurned: caloriesBurned.bounded(to: snapshotDate),
            qualityScore: qualityScore.bounded(to: snapshotDate),
            qualityLabel: qualityLabel,
            provenanceLabel: provenanceLabel
        )
    }

    private var metrics: [WidgetNutritionMetric] {
        [caloriesEaten, calorieGoal, fatGrams, fatGoalGrams, carbsGrams, carbsGoalGrams,
         proteinGrams, proteinGoalGrams, caloriesBurned, qualityScore]
    }

    private static func validatedLabel(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 100,
              !value.contains("\n"),
              !value.contains("\r") else { return nil }
        return value
    }

    private static func validatedQualityMetric(_ metric: WidgetNutritionMetric) -> WidgetNutritionMetric {
        guard let value = metric.value, (0...100).contains(value) else {
            return metric.state == .redacted ? .redacted() : .unavailable()
        }
        return metric
    }

    private enum CodingKeys: String, CodingKey {
        case connector, consent, caloriesEaten, calorieGoal, fatGrams, fatGoalGrams, carbsGrams, carbsGoalGrams
        case proteinGrams, proteinGoalGrams, caloriesBurned, qualityScore, qualityLabel, provenanceLabel
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: [
            "connector", "consent", "caloriesEaten", "calorieGoal", "fatGrams", "carbsGrams",
            "fatGoalGrams", "carbsGoalGrams", "proteinGrams", "proteinGoalGrams", "caloriesBurned",
            "qualityScore", "qualityLabel", "provenanceLabel"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let connector = try container.decode(WidgetConnectorAvailability.self, forKey: .connector)
        let consent = try container.decode(WidgetConsentState.self, forKey: .consent)
        let caloriesEaten = try container.decode(WidgetNutritionMetric.self, forKey: .caloriesEaten)
        let calorieGoal = try container.decode(WidgetNutritionMetric.self, forKey: .calorieGoal)
        let fatGrams = try container.decode(WidgetNutritionMetric.self, forKey: .fatGrams)
        let fatGoalGrams = try container.decode(WidgetNutritionMetric.self, forKey: .fatGoalGrams)
        let carbsGrams = try container.decode(WidgetNutritionMetric.self, forKey: .carbsGrams)
        let carbsGoalGrams = try container.decode(WidgetNutritionMetric.self, forKey: .carbsGoalGrams)
        let proteinGrams = try container.decode(WidgetNutritionMetric.self, forKey: .proteinGrams)
        let proteinGoalGrams = try container.decode(WidgetNutritionMetric.self, forKey: .proteinGoalGrams)
        let caloriesBurned = try container.decode(WidgetNutritionMetric.self, forKey: .caloriesBurned)
        let qualityScore = try container.decode(WidgetNutritionMetric.self, forKey: .qualityScore)
        let qualityLabel = try container.decodeIfPresent(String.self, forKey: .qualityLabel)
        let provenanceLabel = try container.decodeIfPresent(String.self, forKey: .provenanceLabel)
        guard Self.validatedLabel(qualityLabel) == qualityLabel,
              Self.validatedLabel(provenanceLabel) == provenanceLabel,
              qualityScore.value.map({ (0...100).contains($0) }) ?? true else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsafe Nutrition summary label or score"
            ))
        }
        let allowed = connector == .connected && consent == .granted
        if !allowed {
            guard [caloriesEaten, calorieGoal, fatGrams, fatGoalGrams, carbsGrams, carbsGoalGrams,
                   proteinGrams, proteinGoalGrams, caloriesBurned, qualityScore]
                .allSatisfy({ $0.value == nil && $0.state != .fresh && $0.state != .stale }) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Nutrition values require connector consent"
                ))
            }
            guard qualityLabel == nil, provenanceLabel == nil else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unavailable Nutrition summary cannot carry labels"
                ))
            }
        }
        if qualityScore.value == nil {
            guard qualityLabel == nil else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Quality label requires a quality score"
                ))
            }
        }
        self.connector = connector
        self.consent = consent
        self.caloriesEaten = caloriesEaten
        self.calorieGoal = calorieGoal
        self.fatGrams = fatGrams
        self.fatGoalGrams = fatGoalGrams
        self.carbsGrams = carbsGrams
        self.carbsGoalGrams = carbsGoalGrams
        self.proteinGrams = proteinGrams
        self.proteinGoalGrams = proteinGoalGrams
        self.caloriesBurned = caloriesBurned
        self.qualityScore = qualityScore
        self.qualityLabel = qualityLabel
        self.provenanceLabel = provenanceLabel
    }
}

/// Versioned, privacy-filtered data boundary consumed by future Finance/Fitness widgets.
/// The type intentionally has no access to the full Finance, Fitness, meal, or journal models.
public struct FutureWidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let privacyMode: WidgetPrivacyMode
    public let finance: WidgetSafeFinanceSummary
    public let fitness: WidgetSafeFitnessSummary
    public let fitnessWidgets: WidgetSafeFitnessWidgetsSummary
    public let nutrition: WidgetSafeNutritionSummary

    public init(
        generatedAt: Date = .now,
        privacyMode: WidgetPrivacyMode = .redacted,
        finance: WidgetSafeFinanceSummary = .unavailable(),
        fitness: WidgetSafeFitnessSummary = .unavailable(),
        fitnessWidgets: WidgetSafeFitnessWidgetsSummary = .unavailable(),
        nutrition: WidgetSafeNutritionSummary = .unavailable()
    ) {
        let safeGeneratedAt = Self.validatedGeneratedAt(generatedAt, now: .now) ?? .now
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = safeGeneratedAt
        self.privacyMode = privacyMode
        self.finance = privacyMode == .redacted ? .redacted() : finance.bounded(to: safeGeneratedAt)
        self.fitness = privacyMode == .redacted ? .redacted() : fitness.bounded(to: safeGeneratedAt)
        self.fitnessWidgets = privacyMode == .redacted ? .redacted() : fitnessWidgets.bounded(to: safeGeneratedAt)
        self.nutrition = privacyMode == .redacted ? .redacted() : nutrition.bounded(to: safeGeneratedAt)
    }

    private init(validatedGeneratedAt: Date, privacyMode: WidgetPrivacyMode,
                 finance: WidgetSafeFinanceSummary, fitness: WidgetSafeFitnessSummary,
                 fitnessWidgets: WidgetSafeFitnessWidgetsSummary,
                 nutrition: WidgetSafeNutritionSummary) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = validatedGeneratedAt
        self.privacyMode = privacyMode
        self.finance = privacyMode == .redacted ? .redacted() : finance
        self.fitness = privacyMode == .redacted ? .redacted() : fitness
        self.fitnessWidgets = privacyMode == .redacted ? .redacted() : fitnessWidgets
        self.nutrition = privacyMode == .redacted ? .redacted() : nutrition
    }

    public static func unavailable(at date: Date = .now) -> FutureWidgetSnapshot {
        FutureWidgetSnapshot(generatedAt: date, privacyMode: .redacted)
    }

    public var financeDisplayState: WidgetAggregateAvailability {
        financeDisplayState(at: .now)
    }

    public func financeDisplayState(at now: Date) -> WidgetAggregateAvailability {
        privacyMode == .redacted ? .redacted : finance.availability(at: now)
    }

    public var fitnessDisplayState: WidgetAggregateAvailability {
        fitnessDisplayState(at: .now)
    }

    public func fitnessDisplayState(at now: Date) -> WidgetAggregateAvailability {
        privacyMode == .redacted ? .redacted : fitness.availability(at: now)
    }

    public var fitnessWidgetsDisplayState: WidgetAggregateAvailability {
        fitnessWidgetsDisplayState(at: .now)
    }

    public func fitnessWidgetsDisplayState(at now: Date) -> WidgetAggregateAvailability {
        privacyMode == .redacted ? .redacted : fitnessWidgets.displayState(at: now)
    }

    public var nutritionDisplayState: WidgetAggregateAvailability {
        nutritionDisplayState(at: .now)
    }

    public func nutritionDisplayState(at now: Date) -> WidgetAggregateAvailability {
        privacyMode == .redacted ? .redacted : nutrition.displayState(at: now)
    }

    private static func validatedGeneratedAt(_ value: Date, now: Date) -> Date? {
        guard value.timeIntervalSince1970.isFinite,
              value <= now.addingTimeInterval(futureWidgetMaximumClockSkew) else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, privacyMode, finance, fitness, fitnessWidgets, nutrition
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWidgetKeys(decoder, allowed: ["schemaVersion", "generatedAt", "privacyMode", "finance", "fitness", "fitnessWidgets", "nutrition"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported future-widget snapshot version")
        }
        let generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        guard generatedAt.timeIntervalSince1970.isFinite,
              generatedAt <= now.addingTimeInterval(futureWidgetMaximumClockSkew) else {
            throw DecodingError.dataCorruptedError(forKey: .generatedAt, in: container, debugDescription: "Future-widget snapshot timestamp is too far in the future")
        }
        let privacyMode = try container.decode(WidgetPrivacyMode.self, forKey: .privacyMode)
        let finance = try container.decode(WidgetSafeFinanceSummary.self, forKey: .finance)
        let fitness = try container.decode(WidgetSafeFitnessSummary.self, forKey: .fitness)
        // Fitness widget detail was added to schema 1 as an aggregate-only extension.
        // Missing it fails closed for older persisted snapshots.
        let fitnessWidgets = try container.decodeIfPresent(WidgetSafeFitnessWidgetsSummary.self, forKey: .fitnessWidgets)
            ?? .unavailable()
        if privacyMode == .redacted {
            let values = [
                fitnessWidgets.strain, fitnessWidgets.recovery, fitnessWidgets.sleepScore,
                fitnessWidgets.sleepDuration, fitnessWidgets.respiration, fitnessWidgets.heartRate,
                fitnessWidgets.hrv, fitnessWidgets.spo2, fitnessWidgets.temperature,
                fitnessWidgets.stressScore, fitnessWidgets.energyReserve.level,
                fitnessWidgets.energyReserve.startingLevel, fitnessWidgets.energyReserve.chargedPercent,
                fitnessWidgets.energyReserve.dischargedPercent
            ]
            guard values.allSatisfy({ $0.value == nil }),
                  fitnessWidgets.stressTrend.buckets.isEmpty,
                  fitnessWidgets.energyReserve.lastChargedAt == nil,
                  fitnessWidgets.provenanceLabel == nil else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Redacted Fitness widget snapshot carries values"
                ))
            }
        }
        // Nutrition was added to schema 1 as a strict, aggregate-only extension.
        // Missing it is treated as an unavailable summary so older persisted
        // payloads fail closed without inventing values.
        let nutrition = try container.decodeIfPresent(WidgetSafeNutritionSummary.self, forKey: .nutrition)
            ?? .unavailable()
        guard finance.observedAt.map({ $0 <= generatedAt }) ?? true,
              fitness.observedAt.map({ $0 <= generatedAt }) ?? true,
              fitnessWidgets.observedAt.map({ $0 <= generatedAt }) ?? true,
              fitnessWidgets.latestObservedAt.map({ $0 <= generatedAt }) ?? true,
              nutrition.observedAt.map({ $0 <= generatedAt }) ?? true,
              nutrition.latestObservedAt.map({ $0 <= generatedAt }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .generatedAt, in: container, debugDescription: "Nested observation postdates future-widget snapshot")
        }
        // Do not call the public initializer here: decoding may intentionally
        // use an injected clock for deterministic tests and must not revalidate
        // against the wall clock a second time.
        self.init(validatedGeneratedAt: generatedAt, privacyMode: privacyMode, finance: finance,
                  fitness: fitness, fitnessWidgets: fitnessWidgets, nutrition: nutrition)
    }
}

/// Atomic app-group storage for the privacy-filtered future-widget snapshot.
/// This is a separate file from the existing Usage snapshot store so a future
/// widget cannot accidentally decode the broader Usage/Finance payload.
public enum FutureWidgetSnapshotStore {
    public static let snapshotFilename = "future-widget-snapshot.v1.json"

    public static func url(
        fileManager: FileManager = .default,
        appGroupIdentifier: String? = AppGroupConfiguration.identifier()
    ) -> URL? {
        guard let id = AppGroupConfiguration.validatedIdentifier(appGroupIdentifier),
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return container.appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    public static func encode(_ snapshot: FutureWidgetSnapshot) throws -> Data {
        guard snapshot.generatedAt.timeIntervalSince1970.isFinite,
              snapshot.generatedAt <= Date().addingTimeInterval(futureWidgetMaximumClockSkew),
              snapshot.finance.observedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= snapshot.generatedAt }) ?? true,
              snapshot.fitness.observedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= snapshot.generatedAt }) ?? true,
              snapshot.fitnessWidgets.observedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= snapshot.generatedAt }) ?? true,
              snapshot.fitnessWidgets.latestObservedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= snapshot.generatedAt }) ?? true,
              snapshot.nutrition.observedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= snapshot.generatedAt }) ?? true,
              snapshot.nutrition.latestObservedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= snapshot.generatedAt }) ?? true else {
            throw StoreError.invalidSnapshot
        }
        return try JSONEncoder.lifeOS.encode(snapshot)
    }

    public static func decode(_ data: Data, now: Date = .now) -> FutureWidgetSnapshot? {
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = now
        return try? decoder.decode(FutureWidgetSnapshot.self, from: data)
    }

    public static func write(_ snapshot: FutureWidgetSnapshot, to target: URL) throws {
        // Foundation's .atomic writes a sibling temporary file and replaces the
        // destination, so readers see either the previous complete JSON or the new one.
        try encode(snapshot).write(to: target, options: [.atomic, .completeFileProtection])
    }

    public static func write(
        _ snapshot: FutureWidgetSnapshot,
        fileManager: FileManager = .default,
        appGroupIdentifier: String? = AppGroupConfiguration.identifier()
    ) throws {
        guard let target = url(fileManager: fileManager, appGroupIdentifier: appGroupIdentifier) else {
            throw StoreError.unavailableContainer
        }
        try write(snapshot, to: target)
    }

    public static func read(from target: URL, now: Date = .now) -> FutureWidgetSnapshot? {
        guard let data = try? Data(contentsOf: target) else { return nil }
        return decode(data, now: now)
    }

    public static func read(
        fileManager: FileManager = .default,
        appGroupIdentifier: String? = AppGroupConfiguration.identifier(),
        now: Date = .now
    ) -> FutureWidgetSnapshot? {
        guard let target = url(fileManager: fileManager, appGroupIdentifier: appGroupIdentifier) else { return nil }
        return read(from: target, now: now)
    }

    public enum StoreError: Error, Equatable, Sendable {
        case unavailableContainer
        case invalidSnapshot
    }
}
