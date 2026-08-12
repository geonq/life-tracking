import Foundation

private let financeMaximumClockSkew: TimeInterval = 5
private let financeDerivedTransactionSnapshotSource = "derived-transaction-snapshot"

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
    case revolutPersonal = "revolut_personal"
    case revolutBusiness = "revolut_business"
    case tradeRepublic = "trade_republic"
}

public enum FinanceAccessMethod: String, Codable, Equatable, Sendable {
    case officialOAuth = "official_oauth"
    case regulatedOpenBanking = "regulated_open_banking"
    case manualImport = "manual_import"
}

public enum FinanceConnectorRisk: String, Codable, Equatable, Sendable {
    case consentRequired = "consent_required"
    case accountEligibilityRequired = "account_eligibility_required"
    case manualImportOnly = "manual_import_only"
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
              provider: "GoCardless Bank Account Data", risk: .consentRequired,
              recommendation: "Configure the Sparkasse institution and complete one-time GoCardless consent before enabling; keep statement import as the fallback."),
        .init(kind: .revolutPersonal, displayName: "Revolut Personal", accessMethod: .regulatedOpenBanking,
              provider: "GoCardless Bank Account Data", risk: .consentRequired,
              recommendation: "Configure the personal Revolut institution and complete one-time GoCardless consent before enabling; keep statement import as the fallback."),
        .init(kind: .revolutBusiness, displayName: "Revolut Business", accessMethod: .officialOAuth,
              provider: "Official Revolut Business API", risk: .accountEligibilityRequired,
              recommendation: "Register an eligible Revolut Business app and complete official OAuth before enabling; Revolut review may delay access."),
        .init(kind: .tradeRepublic, displayName: "Trade Republic", accessMethod: .manualImport,
              provider: "Manual CSV/PDF import", risk: .manualImportOnly,
              recommendation: "Permanent manual CSV/PDF import only; do not use private APIs or imply a live connector.")
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

public struct FinancePayloadProvenance: Codable, Equatable, Sendable {
    public let source: String
    public let observedAt: Date
    public let freshness: FinancePayloadFreshness
    public let quality: FinancePayloadQuality
    public let connectorState: ConnectorState

    private enum CodingKeys: String, CodingKey {
        case source, observedAt, freshness, quality, connectorState
    }

    public init(
        source: String,
        observedAt: Date,
        freshness: FinancePayloadFreshness,
        quality: FinancePayloadQuality,
        connectorState: ConnectorState
    ) {
        self.source = source
        self.observedAt = observedAt
        self.freshness = freshness
        self.quality = quality
        self.connectorState = connectorState
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

/// A single bank observation. Amounts are signed: positive values are income and
/// negative values are spending. This shape is deliberately source-aware so a
/// future connector cannot silently turn an unavailable feed into an empty one.
public struct FinanceTransactionObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let merchant: String
    public let title: String
    public let signedAmountCents: Int
    public let timestamp: Date
    public let account: String
    public let source: String
    public let category: String
    public let provenance: FinancePayloadProvenance

    private enum CodingKeys: String, CodingKey {
        case id, merchant, title, signedAmountCents, timestamp, account, source, category, provenance
    }

    public init(
        id: String,
        merchant: String,
        title: String,
        signedAmountCents: Int,
        timestamp: Date,
        account: String,
        source: String,
        category: String,
        provenance: FinancePayloadProvenance
    ) {
        self.id = id
        self.merchant = merchant
        self.title = title
        self.signedAmountCents = signedAmountCents
        self.timestamp = timestamp
        self.account = account
        self.source = source
        self.category = category
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: [
            "id", "merchant", "title", "signedAmountCents", "timestamp",
            "account", "source", "category", "provenance"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        merchant = try container.decode(String.self, forKey: .merchant)
        title = try container.decode(String.self, forKey: .title)
        signedAmountCents = try container.decode(Int.self, forKey: .signedAmountCents)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        account = try container.decode(String.self, forKey: .account)
        source = try container.decode(String.self, forKey: .source)
        category = try container.decode(String.self, forKey: .category)
        provenance = try container.decode(FinancePayloadProvenance.self, forKey: .provenance)

        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        let fields = [id, merchant, title, account, source, category]
        let validAmount = signedAmountCents >= -9_007_199_254_740_991
            && signedAmountCents <= 9_007_199_254_740_991
        guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              validAmount,
              timestamp <= now.addingTimeInterval(financeMaximumClockSkew),
              source == provenance.source,
              provenance.quality == .observed,
              provenance.connectorState == .healthy || provenance.connectorState == .refreshDue else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Finance transaction observation is invalid"
            )
        }
    }

    public var isIncome: Bool { signedAmountCents > 0 }
    public var isSpending: Bool { signedAmountCents < 0 }
    public var spendingCents: Int { isSpending ? -signedAmountCents : 0 }
}

/// A category rollup derived from transaction observations. Amounts are always
/// positive spending magnitudes; `fraction` is the share of total spending.
public struct FinanceCategoryObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let amountCents: Int
    public let transactionCount: Int
    public let fraction: Double
    public let source: String
    /// The connector source ids that contributed spending rows to this local
    /// rollup. `source` remains the derivation label; this list is the audit
    /// trail that prevents a mixed-source category from looking like a single
    /// account observation.
    public let contributingSources: [String]
    public let provenance: FinancePayloadProvenance

    private enum CodingKeys: String, CodingKey {
        case id, name, amountCents, transactionCount, fraction, source, contributingSources, provenance
    }

    public init(
        id: String,
        name: String,
        amountCents: Int,
        transactionCount: Int,
        fraction: Double,
        source: String,
        provenance: FinancePayloadProvenance,
        contributingSources: [String] = []
    ) {
        self.id = id
        self.name = name
        self.amountCents = amountCents
        self.transactionCount = transactionCount
        self.fraction = fraction
        self.source = source
        let normalizedSources = Set(contributingSources.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        self.contributingSources = normalizedSources.isEmpty ? [source] : normalizedSources.sorted()
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: [
            "id", "name", "amountCents", "transactionCount", "fraction", "source",
            "contributingSources", "provenance"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let amountCents = try container.decode(Int.self, forKey: .amountCents)
        let transactionCount = try container.decode(Int.self, forKey: .transactionCount)
        let fraction = try container.decode(Double.self, forKey: .fraction)
        let source = try container.decode(String.self, forKey: .source)
        let contributingSources = try container.decode([String].self, forKey: .contributingSources)
        let provenance = try container.decode(FinancePayloadProvenance.self, forKey: .provenance)
        let nonEmptySources = contributingSources.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let validAmount = amountCents > 0 && amountCents <= 9_007_199_254_740_991
        let validCount = transactionCount > 0
        let validFraction = fraction.isFinite && fraction >= 0 && fraction <= 1
        let fields = [id, name, source]
        guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              validAmount,
              validCount,
              validFraction,
              nonEmptySources.count == contributingSources.count,
              Set(contributingSources).count == contributingSources.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Finance category observation invariants are invalid"
            )
        }
        self.init(
            id: id,
            name: name,
            amountCents: amountCents,
            transactionCount: transactionCount,
            fraction: fraction,
            source: source,
            provenance: provenance,
            contributingSources: contributingSources
        )
    }

    public var isMixedSource: Bool { contributingSources.count > 1 }

    public var sourceSummary: String {
        contributingSources.joined(separator: ", ")
    }
}

/// A composable, deterministic filter for the transaction drilldown. The
/// Finance view uses it for category/source/date-range filtering; keeping the
/// predicate in the shared domain makes the interaction testable without a
/// simulator and prevents the UI from silently changing ledger totals.
public struct FinanceTransactionFilter: Equatable, Sendable {
    public let category: String?
    public let source: String?
    public let startDate: Date?
    public let endDate: Date?
    public let spendingOnly: Bool

    public init(
        category: String? = nil,
        source: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        spendingOnly: Bool = false
    ) {
        self.category = category
        self.source = source
        self.startDate = startDate
        self.endDate = endDate
        self.spendingOnly = spendingOnly
    }

    public func matches(_ transaction: FinanceTransactionObservation) -> Bool {
        guard category == nil || category == transaction.category,
              source == nil || source == transaction.source,
              startDate == nil || transaction.timestamp >= startDate!,
              endDate == nil || transaction.timestamp <= endDate!,
              !spendingOnly || transaction.isSpending else {
            return false
        }
        return true
    }

    public func applying(to transactions: [FinanceTransactionObservation]) -> [FinanceTransactionObservation] {
        transactions.filter(matches)
    }
}

public struct FinanceTransactionSnapshot: Codable, Equatable, Sendable {
    public let availability: FinanceMetricAvailability
    public let transactions: [FinanceTransactionObservation]?
    public let provenance: FinancePayloadProvenance

    private enum CodingKeys: String, CodingKey {
        case availability, transactions, provenance
    }

    public init(
        availability: FinanceMetricAvailability,
        transactions: [FinanceTransactionObservation]?,
        provenance: FinancePayloadProvenance
    ) {
        self.availability = availability
        self.transactions = transactions
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: ["availability", "transactions", "provenance"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(FinanceMetricAvailability.self, forKey: .availability)
        let hasTransactions = container.contains(.transactions)
        transactions = try container.decodeIfPresent([FinanceTransactionObservation].self, forKey: .transactions)
        provenance = try container.decode(FinancePayloadProvenance.self, forKey: .provenance)

        let healthy = provenance.connectorState == .healthy || provenance.connectorState == .refreshDue
        let valid: Bool
        switch availability {
        case .observed:
            let rows = transactions ?? []
            let rowSources = Set(rows.map(\.source))
            let sourceReconciles = rowSources.isEmpty
                || (rowSources.count == 1 && rowSources.contains(provenance.source))
                || provenance.source == financeDerivedTransactionSnapshotSource
            let latestRowObservation = rows.map(\.provenance.observedAt).max()
            let observationTimeCoversRows = latestRowObservation.map {
                provenance.observedAt >= $0
            } ?? true
            valid = hasTransactions && transactions != nil
                && provenance.quality == .observed
                && provenance.freshness != .unknown
                && healthy
                && sourceReconciles
                && observationTimeCoversRows
        case .unavailable:
            valid = !hasTransactions && transactions == nil
                && provenance.quality == .unavailable
                && provenance.freshness == .unknown && !healthy
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability,
                in: container,
                debugDescription: "Finance transaction availability, observations, and provenance are inconsistent"
            )
        }
    }
}

/// Deterministic rollups used by the Finance detail surfaces and their tests.
public struct FinanceTransactionTotals: Equatable, Sendable {
    public let incomeCents: Int
    public let spendingCents: Int
    public let netCashFlowCents: Int
    public let transactionCount: Int
    public let categoryObservations: [FinanceCategoryObservation]

    public init(transactions: [FinanceTransactionObservation]) {
        incomeCents = transactions.reduce(0) { total, transaction in
            total + max(transaction.signedAmountCents, 0)
        }
        spendingCents = transactions.reduce(0) { total, transaction in
            total + transaction.spendingCents
        }
        netCashFlowCents = incomeCents - spendingCents
        transactionCount = transactions.count

        let grouped = Dictionary(grouping: transactions.filter(\.isSpending), by: \.category)
        let totalSpending = spendingCents
        categoryObservations = grouped.keys.sorted().map { category in
            let rows = grouped[category, default: []]
            let amount = rows.reduce(0) { $0 + $1.spendingCents }
            return FinanceCategoryObservation(
                id: category,
                name: category,
                amountCents: amount,
                transactionCount: rows.count,
                fraction: totalSpending > 0 ? Double(amount) / Double(totalSpending) : 0,
                source: "derived-transaction-rollup",
                provenance: Self.derivedCategoryProvenance(from: rows),
                contributingSources: rows.map(\.source)
            )
        }
    }

    /// Category totals are a local derivation and must never inherit the
    /// provenance of whichever transaction happened to be first. For a
    /// mixed-source category, the oldest contributing observation and the
    /// least-fresh connector state are retained under an explicit derived
    /// source label. This prevents a fresh row from masking stale input.
    private static func derivedCategoryProvenance(
        from rows: [FinanceTransactionObservation]
    ) -> FinancePayloadProvenance {
        guard !rows.isEmpty else {
            return FinancePayloadProvenance(
                source: "derived-transaction-rollup",
                observedAt: .now,
                freshness: .unknown,
                quality: .unavailable,
                connectorState: .unavailable
            )
        }

        let observedAt = rows.map(\.provenance.observedAt).min() ?? .now
        let hasInvalidQuality = rows.contains {
            $0.provenance.quality != .observed
                || ($0.provenance.connectorState != .healthy && $0.provenance.connectorState != .refreshDue)
        }
        guard !hasInvalidQuality else {
            return FinancePayloadProvenance(
                source: "derived-transaction-rollup",
                observedAt: observedAt,
                freshness: .unknown,
                quality: .unavailable,
                connectorState: .unavailable
            )
        }

        let hasUnknownFreshness = rows.contains { $0.provenance.freshness == .unknown }
        let hasStaleInput = rows.contains {
            $0.provenance.freshness == .stale || $0.provenance.connectorState == .refreshDue
        }
        let freshness: FinancePayloadFreshness = hasUnknownFreshness
            ? .unknown
            : hasStaleInput ? .stale : .fresh
        let connectorState: ConnectorState = freshness == .fresh ? .healthy : .refreshDue
        return FinancePayloadProvenance(
            source: "derived-transaction-rollup",
            observedAt: observedAt,
            freshness: freshness,
            quality: .observed,
            connectorState: connectorState
        )
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
    /// Optional for backwards compatibility with summary-only connectors. A
    /// missing snapshot is not an empty ledger; the transaction surfaces must
    /// remain unavailable until an observed source supplies it.
    public let transactions: FinanceTransactionSnapshot?

    private enum CodingKeys: String, CodingKey {
        case generatedAt, currency, monthlyIncome, fixedCosts, discretionaryBuffer, spent, savingsGoal, saved
        case transactions
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceKeys(decoder, allowed: [
            "generatedAt", "currency", "monthlyIncome", "fixedCosts",
            "discretionaryBuffer", "spent", "savingsGoal", "saved", "transactions"
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
        transactions = try container.decodeIfPresent(FinanceTransactionSnapshot.self, forKey: .transactions)
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
