import Foundation

public enum FinanceConnectorKind: String, Codable, CaseIterable, Sendable {
    case sparkasse
    case paypal
    case tradeRepublic = "trade_republic"
}

public enum FinanceAccessMethod: String, Codable, Sendable {
    case official
    case regulatedOpenBanking = "regulated_open_banking"
    case regulatedProviderPending = "regulated_provider_pending"
}

public enum FinanceConnectorRisk: String, Codable, Sendable {
    case providerConfirmationRequired = "provider_confirmation_required"
    case accountEligibilityRequired = "account_eligibility_required"
    case experimentalOnly = "experimental_only"
}

public struct FinanceConnectorDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: FinanceConnectorKind { kind }
    public let kind: FinanceConnectorKind
    public let displayName: String
    public let accessMethod: FinanceAccessMethod
    public let isEnabled: Bool
    public let requiresExplicitOptIn: Bool
    public let risk: FinanceConnectorRisk

    public init(kind: FinanceConnectorKind, displayName: String, accessMethod: FinanceAccessMethod,
                isEnabled: Bool = false, requiresExplicitOptIn: Bool = true, risk: FinanceConnectorRisk) {
        self.kind = kind
        self.displayName = displayName
        self.accessMethod = accessMethod
        self.isEnabled = isEnabled
        self.requiresExplicitOptIn = requiresExplicitOptIn
        self.risk = risk
    }
}

public enum FinanceConnectorCatalog {
    public static let defaults: [FinanceConnectorDescriptor] = [
        .init(kind: .sparkasse, displayName: "Sparkasse", accessMethod: .regulatedOpenBanking,
              risk: .providerConfirmationRequired),
        .init(kind: .paypal, displayName: "PayPal", accessMethod: .official,
              risk: .accountEligibilityRequired),
        .init(kind: .tradeRepublic, displayName: "Trade Republic", accessMethod: .regulatedProviderPending,
              risk: .experimentalOnly)
    ]
}

public struct FinanceSummary: Codable, Equatable, Sendable {
    public let monthlyIncomeCents: Int
    public let fixedCostsCents: Int
    public let discretionaryBufferCents: Int
    public let spentCents: Int
    public let savingsGoalCents: Int
    public let savedCents: Int
    public let provenance: Provenance

    public init(monthlyIncomeCents: Int, fixedCostsCents: Int, discretionaryBufferCents: Int,
                spentCents: Int, savingsGoalCents: Int, savedCents: Int, provenance: Provenance) {
        self.monthlyIncomeCents = max(0, monthlyIncomeCents)
        self.fixedCostsCents = max(0, fixedCostsCents)
        self.discretionaryBufferCents = max(0, discretionaryBufferCents)
        self.spentCents = max(0, spentCents)
        self.savingsGoalCents = max(0, savingsGoalCents)
        self.savedCents = max(0, savedCents)
        self.provenance = provenance
    }

    public var spendableBudgetCents: Int {
        max(0, monthlyIncomeCents - fixedCostsCents - discretionaryBufferCents)
    }

    public var budgetUsedFraction: Double? {
        guard spendableBudgetCents > 0 else { return nil }
        return min(max(Double(spentCents) / Double(spendableBudgetCents), 0), 1)
    }

    public var savingsProgressFraction: Double? {
        guard savingsGoalCents > 0 else { return nil }
        return min(max(Double(savedCents) / Double(savingsGoalCents), 0), 1)
    }
}
