import Foundation

private let financeMaximumClockSkew: TimeInterval = 5

private struct FinanceAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownFinanceKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: FinanceAnyCodingKey.self)
    let received = Set(container.allKeys.map(\.stringValue))
    guard received.isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown Finance response field")
        )
    }
}

public enum FinanceConnectorKind: String, Codable, CaseIterable, Equatable, Sendable {
    case sparkasse
    case paypal
    case tradeRepublic = "trade_republic"
}

public enum FinanceAccessMethod: String, Codable, Equatable, Sendable {
    case officialOAuth = "official_oauth"
    case regulatedOpenBanking = "regulated_open_banking"
    case regulatedProviderPending = "regulated_provider_pending"
}

public enum FinanceConnectorRisk: String, Codable, Equatable, Sendable {
    case providerConfirmationRequired = "provider_confirmation_required"
    case accountEligibilityRequired = "account_eligibility_required"
    case experimentalOnly = "experimental_only"
}

public struct FinanceConnectorDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: FinanceConnectorKind { kind }
    public let kind: FinanceConnectorKind
    public let displayName: String
    public let accessMethod: FinanceAccessMethod
    public let provider: String
    public let isEnabled: Bool
    public let requiresExplicitOptIn: Bool
    public let risk: FinanceConnectorRisk
    public let recommendation: String

    private enum CodingKeys: String, CodingKey {
        case kind = "id"
        case displayName, accessMethod, provider
        case isEnabled = "enabled"
        case requiresExplicitOptIn, risk, recommendation
    }

    public init(kind: FinanceConnectorKind, displayName: String, accessMethod: FinanceAccessMethod,
                provider: String, risk: FinanceConnectorRisk, recommendation: String) {
        self.kind = kind
        self.displayName = displayName
        self.accessMethod = accessMethod
        self.provider = provider
        self.isEnabled = false
        self.requiresExplicitOptIn = true
        self.risk = risk
        self.recommendation = recommendation
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: [
            "id", "displayName", "accessMethod", "provider", "enabled",
            "requiresExplicitOptIn", "risk", "recommendation"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(FinanceConnectorKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        accessMethod = try container.decode(FinanceAccessMethod.self, forKey: .accessMethod)
        provider = try container.decode(String.self, forKey: .provider)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        requiresExplicitOptIn = try container.decode(Bool.self, forKey: .requiresExplicitOptIn)
        risk = try container.decode(FinanceConnectorRisk.self, forKey: .risk)
        recommendation = try container.decode(String.self, forKey: .recommendation)
        guard !isEnabled, requiresExplicitOptIn,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !recommendation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Finance connector must be disabled, opt-in, and fully described")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(accessMethod, forKey: .accessMethod)
        try container.encode(provider, forKey: .provider)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(requiresExplicitOptIn, forKey: .requiresExplicitOptIn)
        try container.encode(risk, forKey: .risk)
        try container.encode(recommendation, forKey: .recommendation)
    }
}

public struct FinanceConnectorCatalog: Decodable, Equatable, Sendable {
    public let connectors: [FinanceConnectorDescriptor]

    private enum CodingKeys: String, CodingKey { case connectors }

    public static let defaults: [FinanceConnectorDescriptor] = [
        .init(kind: .sparkasse, displayName: "Sparkasse", accessMethod: .regulatedOpenBanking,
              provider: "Enable Banking candidate; finAPI fallback", risk: .providerConfirmationRequired,
              recommendation: "Confirm the exact Sparkasse institution and restricted-production eligibility before OAuth consent."),
        .init(kind: .paypal, displayName: "PayPal", accessMethod: .officialOAuth,
              provider: "PayPal Transaction Search API", risk: .accountEligibilityRequired,
              recommendation: "Use official OAuth only; fall back to statement import if this account cannot access transaction history."),
        .init(kind: .tradeRepublic, displayName: "Trade Republic", accessMethod: .regulatedProviderPending,
              provider: "Regulated PSD2 provider or official route", risk: .experimentalOnly,
              recommendation: "Keep pytr out of production because it uses an unsupported private API and handles PIN/SMS device authentication.")
    ]

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: ["connectors"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectors = try container.decode([FinanceConnectorDescriptor].self, forKey: .connectors)
        let required = Set(FinanceConnectorKind.allCases.map(\.rawValue))
        let received = Set(connectors.map { $0.kind.rawValue })
        guard connectors.count == required.count, received == required else {
            throw DecodingError.dataCorruptedError(
                forKey: .connectors,
                in: container,
                debugDescription: "Complete unique Finance connector catalog required"
            )
        }
    }

    public static func decode(_ data: Data) throws -> FinanceConnectorCatalog {
        try JSONDecoder().decode(FinanceConnectorCatalog.self, from: data)
    }
}

public enum FinanceMetricAvailability: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
}

public enum FinancePayloadFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unknown
}

public enum FinancePayloadQuality: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
}

public struct FinancePayloadProvenance: Decodable, Equatable, Sendable {
    public let source: String
    public let observedAt: Date
    public let freshness: FinancePayloadFreshness
    public let quality: FinancePayloadQuality
    public let connectorState: ConnectorState

    private enum CodingKeys: String, CodingKey {
        case source, observedAt, freshness, quality, connectorState
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: [
            "source", "observedAt", "freshness", "quality", "connectorState"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        freshness = try container.decode(FinancePayloadFreshness.self, forKey: .freshness)
        quality = try container.decode(FinancePayloadQuality.self, forKey: .quality)
        connectorState = try container.decode(ConnectorState.self, forKey: .connectorState)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        let supportedStates: [ConnectorState] = [
            .healthy, .refreshDue, .reauthRequired, .revoked, .rateLimited, .unavailable
        ]
        guard observedAt <= now.addingTimeInterval(financeMaximumClockSkew),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              supportedStates.contains(connectorState) else {
            throw DecodingError.dataCorruptedError(
                forKey: .source,
                in: container,
                debugDescription: "Finance provenance source or connector state is invalid"
            )
        }
    }

}

public struct FinanceAmountMetric: Decodable, Equatable, Sendable {
    public let availability: FinanceMetricAvailability
    public let amountCents: Int?
    public let provenance: FinancePayloadProvenance

    private enum CodingKeys: String, CodingKey {
        case availability, amountCents, provenance
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: ["availability", "amountCents", "provenance"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(FinanceMetricAvailability.self, forKey: .availability)
        let hasAmount = container.contains(.amountCents)
        amountCents = try container.decodeIfPresent(Int.self, forKey: .amountCents)
        provenance = try container.decode(FinancePayloadProvenance.self, forKey: .provenance)

        let healthy = provenance.connectorState == .healthy || provenance.connectorState == .refreshDue
        let valid: Bool
        switch availability {
        case .observed:
            let age = (decoder.userInfo[.lifeOSNow] as? Date ?? .now).timeIntervalSince(provenance.observedAt)
            let expectedFreshness: FinancePayloadFreshness = age <= 15 * 60 ? .fresh : .stale
            let expectedConnector: ConnectorState = expectedFreshness == .fresh ? .healthy : .refreshDue
            valid = amountCents.map { $0 >= 0 && $0 <= 9_007_199_254_740_991 } == true
                && age >= -financeMaximumClockSkew && provenance.quality == .observed
                && provenance.freshness == expectedFreshness && provenance.connectorState == expectedConnector
        case .unavailable:
            valid = !hasAmount && amountCents == nil && provenance.quality == .unavailable
                && provenance.freshness == .unknown && !healthy
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability,
                in: container,
                debugDescription: "Finance metric availability, amount, and provenance are inconsistent"
            )
        }
    }

}

public struct FinanceSummary: Decodable, Equatable, Sendable {
    public let generatedAt: Date
    public let currency: String
    public let monthlyIncome: FinanceAmountMetric
    public let fixedCosts: FinanceAmountMetric
    public let discretionaryBuffer: FinanceAmountMetric
    public let spent: FinanceAmountMetric
    public let savingsGoal: FinanceAmountMetric
    public let saved: FinanceAmountMetric

    private enum CodingKeys: String, CodingKey {
        case generatedAt, currency, monthlyIncome, fixedCosts, discretionaryBuffer, spent, savingsGoal, saved
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: [
            "generatedAt", "currency", "monthlyIncome", "fixedCosts",
            "discretionaryBuffer", "spent", "savingsGoal", "saved"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        currency = try container.decode(String.self, forKey: .currency)
        monthlyIncome = try container.decode(FinanceAmountMetric.self, forKey: .monthlyIncome)
        fixedCosts = try container.decode(FinanceAmountMetric.self, forKey: .fixedCosts)
        discretionaryBuffer = try container.decode(FinanceAmountMetric.self, forKey: .discretionaryBuffer)
        spent = try container.decode(FinanceAmountMetric.self, forKey: .spent)
        savingsGoal = try container.decode(FinanceAmountMetric.self, forKey: .savingsGoal)
        saved = try container.decode(FinanceAmountMetric.self, forKey: .saved)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        guard generatedAt <= now.addingTimeInterval(financeMaximumClockSkew), currency == "EUR" else {
            throw DecodingError.dataCorruptedError(
                forKey: .currency, in: container, debugDescription: "Unsupported finance currency"
            )
        }
    }


    public var monthlyIncomeCents: Int? { monthlyIncome.amountCents }
    public var fixedCostsCents: Int? { fixedCosts.amountCents }
    public var discretionaryBufferCents: Int? { discretionaryBuffer.amountCents }
    public var spentCents: Int? { spent.amountCents }
    public var savingsGoalCents: Int? { savingsGoal.amountCents }
    public var savedCents: Int? { saved.amountCents }

    public var spendableBudgetCents: Int? {
        guard let income = monthlyIncomeCents, let fixed = fixedCostsCents,
              let buffer = discretionaryBufferCents else { return nil }
        guard fixed <= income else { return 0 }
        let afterFixed = income - fixed
        guard buffer <= afterFixed else { return 0 }
        return afterFixed - buffer
    }

    public var budgetUsedFraction: Double? {
        guard let budget = spendableBudgetCents, budget > 0, let spent = spentCents else { return nil }
        return min(Double(spent) / Double(budget), 1)
    }

    public var savingsProgressFraction: Double? {
        guard let goal = savingsGoalCents, goal > 0, let saved = savedCents else { return nil }
        return min(Double(saved) / Double(goal), 1)
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> FinanceSummary {
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(FinanceSummary.self, from: data)
    }
}
