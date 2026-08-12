import Foundation

private let clipperMaximumClockSkew: TimeInterval = 5
private let clipperFreshnessWindow: TimeInterval = 15 * 60
private let clipperMaximumCents = 9_007_199_254_740_991
private let clipperConnectorStates: Set<ConnectorState> = [
    .healthy, .refreshDue, .reauthRequired, .revoked, .rateLimited, .unavailable
]

public enum ClipperMetricAvailability: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
}

public enum ClipperPayloadFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unknown
}

public enum ClipperPayloadQuality: String, Codable, Equatable, Sendable {
    case observed
    case partial
    case unavailable
}

public struct ClipperPayloadProvenance: Codable, Equatable, Sendable {
    public let source: String
    public let observedAt: Date
    public let freshness: ClipperPayloadFreshness
    public let quality: ClipperPayloadQuality
    public let connectorState: ConnectorState

    private enum CodingKeys: String, CodingKey {
        case source, observedAt, freshness, quality, connectorState
    }

    public init(source: String, observedAt: Date, freshness: ClipperPayloadFreshness,
                quality: ClipperPayloadQuality, connectorState: ConnectorState) {
        self.source = source
        self.observedAt = observedAt
        self.freshness = freshness
        self.quality = quality
        self.connectorState = connectorState
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "source", "observedAt", "freshness", "quality", "connectorState"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        freshness = try container.decode(ClipperPayloadFreshness.self, forKey: .freshness)
        quality = try container.decode(ClipperPayloadQuality.self, forKey: .quality)
        connectorState = try container.decode(ConnectorState.self, forKey: .connectorState)

        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        let age = now.timeIntervalSince(observedAt)
        let expectedFreshness: ClipperPayloadFreshness? = age < -clipperMaximumClockSkew
            ? nil
            : age <= clipperFreshnessWindow ? .fresh : .stale
        let isUnavailable = quality == .unavailable
        let connectorIsLive = connectorState == .healthy || connectorState == .refreshDue
        let expectedConnector: ConnectorState? = expectedFreshness == .fresh
            ? .healthy
            : expectedFreshness == .stale ? .refreshDue : nil
        let valid = !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && clipperConnectorStates.contains(connectorState)
            && expectedFreshness != nil
            && (isUnavailable
                ? freshness == .unknown && !connectorIsLive
                : freshness == expectedFreshness && connectorState == expectedConnector)
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .source, in: container,
                debugDescription: "Clipper provenance is contradictory or unsafe"
            )
        }
    }
}

public struct ClipperCountMetric: Codable, Equatable, Sendable {
    public let availability: ClipperMetricAvailability
    public let value: Int?
    public let provenance: ClipperPayloadProvenance

    private enum CodingKeys: String, CodingKey { case availability, value, provenance }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["availability", "value", "provenance"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(ClipperMetricAvailability.self, forKey: .availability)
        let hasValue = container.contains(.value)
        value = try container.decodeIfPresent(Int.self, forKey: .value)
        provenance = try container.decode(ClipperPayloadProvenance.self, forKey: .provenance)
        let live = provenance.connectorState == .healthy || provenance.connectorState == .refreshDue
        let valid: Bool
        switch availability {
        case .observed:
            valid = hasValue && value.map { $0 >= 0 && $0 <= clipperMaximumCents } == true
                && provenance.quality == .observed && live
        case .unavailable:
            valid = !hasValue && value == nil && provenance.quality == .unavailable && !live
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability, in: container,
                debugDescription: "Clipper count availability and value are inconsistent"
            )
        }
    }
}

public struct ClipperRevenueMetric: Codable, Equatable, Sendable {
    public let availability: ClipperMetricAvailability
    public let amountCents: Int?
    public let currency: String
    public let provenance: ClipperPayloadProvenance

    private enum CodingKeys: String, CodingKey { case availability, amountCents, currency, provenance }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["availability", "amountCents", "currency", "provenance"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(ClipperMetricAvailability.self, forKey: .availability)
        let hasAmount = container.contains(.amountCents)
        amountCents = try container.decodeIfPresent(Int.self, forKey: .amountCents)
        currency = try container.decode(String.self, forKey: .currency)
        provenance = try container.decode(ClipperPayloadProvenance.self, forKey: .provenance)
        let live = provenance.connectorState == .healthy || provenance.connectorState == .refreshDue
        let valid: Bool
        switch availability {
        case .observed:
            valid = currency == "EUR" && hasAmount
                && amountCents.map { $0 >= 0 && $0 <= clipperMaximumCents } == true
                && provenance.quality == .observed && live
        case .unavailable:
            valid = currency == "EUR" && !hasAmount && amountCents == nil
                && provenance.quality == .unavailable && !live
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability, in: container,
                debugDescription: "Clipper revenue availability, currency, or amount is invalid"
            )
        }
    }
}

public struct ClipperMetricSet: Codable, Equatable, Sendable {
    public let views: ClipperCountMetric
    public let subscribers: ClipperCountMetric
    public let revenue: ClipperRevenueMetric

    private enum CodingKeys: String, CodingKey { case views, subscribers, revenue }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["views", "subscribers", "revenue"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        views = try container.decode(ClipperCountMetric.self, forKey: .views)
        subscribers = try container.decode(ClipperCountMetric.self, forKey: .subscribers)
        revenue = try container.decode(ClipperRevenueMetric.self, forKey: .revenue)
    }

    public var hasObservedMetric: Bool {
        views.availability == .observed || subscribers.availability == .observed || revenue.availability == .observed
    }
}

private func clipperMetricObservationDates(_ metrics: ClipperMetricSet) -> [Date] {
    [
        metrics.views.provenance.observedAt,
        metrics.subscribers.provenance.observedAt,
        metrics.revenue.provenance.observedAt
    ]
}

private func clipperHasObservedDetail(_ account: ClipperAccount) -> Bool {
    account.metrics.hasObservedMetric
        || account.bots.contains { bot in
            bot.metrics.hasObservedMetric
                || bot.breakdowns.contains { $0.metrics.hasObservedMetric }
        }
        || account.breakdowns.contains { $0.metrics.hasObservedMetric }
}

public struct ClipperTrendPoint: Codable, Equatable, Identifiable, Sendable {
    public let at: Date
    public let metrics: ClipperMetricSet
    public var id: Date { at }

    private enum CodingKeys: String, CodingKey { case at, metrics }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["at", "metrics"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Date.self, forKey: .at)
        metrics = try container.decode(ClipperMetricSet.self, forKey: .metrics)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        guard at <= now.addingTimeInterval(clipperMaximumClockSkew) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "Future Clipper trend point")
        }
    }
}

public struct ClipperBreakdown: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let periodStart: Date
    public let periodEnd: Date
    public let metrics: ClipperMetricSet

    private enum CodingKeys: String, CodingKey { case id, label, periodStart, periodEnd, metrics }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["id", "label", "periodStart", "periodEnd", "metrics"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        periodStart = try container.decode(Date.self, forKey: .periodStart)
        periodEnd = try container.decode(Date.self, forKey: .periodEnd)
        metrics = try container.decode(ClipperMetricSet.self, forKey: .metrics)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              periodEnd > periodStart else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid Clipper breakdown")
        }
    }
}

public struct ClipperBot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let metrics: ClipperMetricSet
    public let breakdowns: [ClipperBreakdown]

    private enum CodingKeys: String, CodingKey { case id, name, metrics, breakdowns }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["id", "name", "metrics", "breakdowns"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        metrics = try container.decode(ClipperMetricSet.self, forKey: .metrics)
        breakdowns = try container.decode([ClipperBreakdown].self, forKey: .breakdowns)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(breakdowns.map(\.id)).count == breakdowns.count else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid or duplicate Clipper bot data")
        }
    }
}

public struct ClipperAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let metrics: ClipperMetricSet
    public let bots: [ClipperBot]
    public let breakdowns: [ClipperBreakdown]

    private enum CodingKeys: String, CodingKey { case id, name, metrics, bots, breakdowns }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["id", "name", "metrics", "bots", "breakdowns"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        metrics = try container.decode(ClipperMetricSet.self, forKey: .metrics)
        bots = try container.decode([ClipperBot].self, forKey: .bots)
        breakdowns = try container.decode([ClipperBreakdown].self, forKey: .breakdowns)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(bots.map(\.id)).count == bots.count,
              Set(breakdowns.map(\.id)).count == breakdowns.count else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid or duplicate Clipper account data")
        }
    }
}

public enum ClipperSnapshotAvailability: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
}

public struct ClipperSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let availability: ClipperSnapshotAvailability
    public let generatedAt: Date
    public let currency: String
    public let metrics: ClipperMetricSet?
    public let accounts: [ClipperAccount]?
    public let trends: [ClipperTrendPoint]?
    public let breakdowns: [ClipperBreakdown]?
    public let provenance: ClipperPayloadProvenance

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, availability, generatedAt, currency, metrics, accounts, trends, breakdowns, provenance
    }

    private init(schemaVersion: Int, availability: ClipperSnapshotAvailability, generatedAt: Date,
                 currency: String, metrics: ClipperMetricSet?, accounts: [ClipperAccount]?,
                 trends: [ClipperTrendPoint]?, breakdowns: [ClipperBreakdown]?,
                 provenance: ClipperPayloadProvenance) {
        self.schemaVersion = schemaVersion
        self.availability = availability
        self.generatedAt = generatedAt
        self.currency = currency
        self.metrics = metrics
        self.accounts = accounts
        self.trends = trends
        self.breakdowns = breakdowns
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "schemaVersion", "availability", "generatedAt", "currency", "metrics", "accounts", "trends", "breakdowns", "provenance"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        availability = try container.decode(ClipperSnapshotAvailability.self, forKey: .availability)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        currency = try container.decode(String.self, forKey: .currency)
        metrics = try container.decodeIfPresent(ClipperMetricSet.self, forKey: .metrics)
        accounts = try container.decodeIfPresent([ClipperAccount].self, forKey: .accounts)
        trends = try container.decodeIfPresent([ClipperTrendPoint].self, forKey: .trends)
        breakdowns = try container.decodeIfPresent([ClipperBreakdown].self, forKey: .breakdowns)
        provenance = try container.decode(ClipperPayloadProvenance.self, forKey: .provenance)

        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        let live = provenance.connectorState == .healthy || provenance.connectorState == .refreshDue
        let observed = metrics?.hasObservedMetric == true || accounts?.contains(where: clipperHasObservedDetail) == true
        let uniqueAccounts = accounts.map { Set($0.map(\.id)).count == $0.count } ?? true
        let uniqueBreakdowns = breakdowns.map { Set($0.map(\.id)).count == $0.count } ?? true
        var nestedObservationDates = [provenance.observedAt]
        if let metrics {
            nestedObservationDates.append(contentsOf: clipperMetricObservationDates(metrics))
        }
        for account in accounts ?? [] {
            nestedObservationDates.append(contentsOf: clipperMetricObservationDates(account.metrics))
            for bot in account.bots {
                nestedObservationDates.append(contentsOf: clipperMetricObservationDates(bot.metrics))
                for breakdown in bot.breakdowns {
                    nestedObservationDates.append(contentsOf: clipperMetricObservationDates(breakdown.metrics))
                }
            }
            for breakdown in account.breakdowns {
                nestedObservationDates.append(contentsOf: clipperMetricObservationDates(breakdown.metrics))
            }
        }
        for trend in trends ?? [] {
            nestedObservationDates.append(trend.at)
            nestedObservationDates.append(contentsOf: clipperMetricObservationDates(trend.metrics))
        }
        for breakdown in breakdowns ?? [] {
            nestedObservationDates.append(contentsOf: clipperMetricObservationDates(breakdown.metrics))
        }
        let generatedAtCoversNestedObservations = nestedObservationDates.allSatisfy {
            $0 <= generatedAt.addingTimeInterval(clipperMaximumClockSkew)
        }
        let valid: Bool
        switch availability {
        case .observed:
            valid = schemaVersion == 1 && currency == "EUR"
                && metrics != nil && accounts != nil && trends != nil && breakdowns != nil
                && uniqueAccounts && uniqueBreakdowns
                && provenance.quality != .unavailable && live && observed
        case .unavailable:
            valid = schemaVersion == 1 && currency == "EUR"
                && metrics == nil && accounts == nil && trends == nil && breakdowns == nil
                && provenance.quality == .unavailable && provenance.freshness == .unknown && !live
        }
        guard generatedAt <= now.addingTimeInterval(clipperMaximumClockSkew), generatedAtCoversNestedObservations, valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability, in: container,
                debugDescription: "Clipper snapshot availability, detail, or provenance is inconsistent"
            )
        }
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> ClipperSnapshot {
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(ClipperSnapshot.self, from: data)
    }

    public static func unavailable(at date: Date = .now) -> ClipperSnapshot {
        let provenance = ClipperPayloadProvenance(
            source: "no-authorized-clipper-source", observedAt: date,
            freshness: .unknown, quality: .unavailable, connectorState: .unavailable
        )
        return ClipperSnapshot(
            schemaVersion: 1, availability: .unavailable, generatedAt: date,
            currency: "EUR", metrics: nil, accounts: nil, trends: nil,
            breakdowns: nil, provenance: provenance
        )
    }
}
