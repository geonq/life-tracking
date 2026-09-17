import Foundation

/// The bounded operational state emitted by the gateway alongside the
/// validated `/finance/summary` body. Header values are deliberately an enum:
/// an unknown value is a contract failure, never an ignored diagnostic.
public enum FinanceBankingState: String, Codable, Equatable, Sendable {
    case healthy
    case partial
    case consent
    case transport
    case auth
    case malformed
    case configuration
    case storage
}

public enum FinanceReadbackValidationError: Error, Equatable, Sendable {
    case invalidMetadata
    case contradictoryMetadata
    case invalidCoverage
    case invalidExclusion
    case tooManyItems
}

private enum FinanceReadbackLimits {
    static let maximumResponseBytes = 1_048_576
    static let maximumHeaderBytes = 256
    static let maximumAccounts = 256
    static let maximumTransactions = 20_000
    static let maximumExclusions = 512
    static let maximumEvidenceReferences = 128
    static let maximumClockSkew: TimeInterval = 5
    static let liveBankFreshness: TimeInterval = 15 * 60
}

private struct FinanceReadbackCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownFinanceReadbackKeys(
    _ decoder: Decoder,
    allowed: Set<String>
) throws {
    let container = try decoder.container(keyedBy: FinanceReadbackCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw FinanceReadbackValidationError.invalidMetadata
    }
}

private func parseFinanceReadbackDate(_ rawValue: String) -> Date? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= FinanceReadbackLimits.maximumHeaderBytes else {
        return nil
    }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: trimmed) { return date }

    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: trimmed)
}

private func financeReadbackDateIsValid(_ date: Date, now: Date) -> Bool {
    date.timeIntervalSinceReferenceDate.isFinite
        && date <= now.addingTimeInterval(FinanceReadbackLimits.maximumClockSkew)
}

/// Validated response metadata retained from the bounded HTTP read. It is
/// content-free: no response body, account label, transaction, or provider
/// error text is stored here.
public struct FinanceResponseMetadata: Codable, Equatable, Sendable {
    public let statusCode: Int
    public let contentType: String
    public let bodySize: Int
    public let bankingState: FinanceBankingState?
    public let isPartial: Bool?
    public let lastSuccessAt: Date?
    public let lastFailureAt: Date?

    public init(
        statusCode: Int,
        contentType: String,
        bodySize: Int,
        bankingState: FinanceBankingState?,
        isPartial: Bool?,
        lastSuccessAt: Date?,
        lastFailureAt: Date?,
        now: Date = .now
    ) throws {
        let trimmedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaType = trimmedContentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard (200...299).contains(statusCode),
              bodySize >= 0,
              bodySize <= FinanceReadbackLimits.maximumResponseBytes,
              trimmedContentType.utf8.count <= FinanceReadbackLimits.maximumHeaderBytes,
              mediaType == "application/json",
              lastSuccessAt.map({ financeReadbackDateIsValid($0, now: now) }) ?? true,
              lastFailureAt.map({ financeReadbackDateIsValid($0, now: now) }) ?? true else {
            throw FinanceReadbackValidationError.invalidMetadata
        }

        if let bankingState {
            switch bankingState {
            case .healthy:
                guard isPartial != true else {
                    throw FinanceReadbackValidationError.contradictoryMetadata
                }
            case .partial:
                guard isPartial == true else {
                    throw FinanceReadbackValidationError.contradictoryMetadata
                }
            case .consent, .transport, .auth, .malformed, .configuration, .storage:
                break
            }
        }
        if let lastSuccessAt, let lastFailureAt,
           lastFailureAt > lastSuccessAt,
           bankingState == .healthy {
            throw FinanceReadbackValidationError.contradictoryMetadata
        }

        self.statusCode = statusCode
        self.contentType = trimmedContentType
        self.bodySize = bodySize
        self.bankingState = bankingState
        self.isPartial = isPartial
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
    }

    /// Builds metadata from the actual response after the shared transport
    /// has bounded the body and rejected redirects/non-2xx responses.
    public init(response: HTTPURLResponse, bodySize: Int, now: Date = .now) throws {
        let rawState = response.value(forHTTPHeaderField: "X-LifeOS-Banking-State")
        let bankingState: FinanceBankingState?
        if let rawState {
            let normalized = rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let parsed = FinanceBankingState(rawValue: normalized) else {
                throw FinanceReadbackValidationError.invalidMetadata
            }
            bankingState = parsed
        } else {
            bankingState = nil
        }

        let rawPartial = response.value(forHTTPHeaderField: "X-LifeOS-Banking-Partial")
        let isPartial: Bool?
        if let rawPartial {
            switch rawPartial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": isPartial = true
            case "false": isPartial = false
            default: throw FinanceReadbackValidationError.invalidMetadata
            }
        } else {
            isPartial = nil
        }

        func parseOptionalDate(_ field: String) throws -> Date? {
            guard let raw = response.value(forHTTPHeaderField: field) else { return nil }
            guard let date = parseFinanceReadbackDate(raw) else {
                throw FinanceReadbackValidationError.invalidMetadata
            }
            return date
        }

        try self.init(
            statusCode: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
            bodySize: bodySize,
            bankingState: bankingState,
            isPartial: isPartial,
            lastSuccessAt: try parseOptionalDate("X-LifeOS-Banking-Last-Success"),
            lastFailureAt: try parseOptionalDate("X-LifeOS-Banking-Last-Failure"),
            now: now
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case statusCode, contentType, bodySize, bankingState, isPartial
        case lastSuccessAt, lastFailureAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceReadbackKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            statusCode: container.decode(Int.self, forKey: .statusCode),
            contentType: container.decode(String.self, forKey: .contentType),
            bodySize: container.decode(Int.self, forKey: .bodySize),
            bankingState: container.decodeIfPresent(FinanceBankingState.self, forKey: .bankingState),
            isPartial: container.decodeIfPresent(Bool.self, forKey: .isPartial),
            lastSuccessAt: container.decodeIfPresent(Date.self, forKey: .lastSuccessAt),
            lastFailureAt: container.decodeIfPresent(Date.self, forKey: .lastFailureAt)
        )
    }
}

public struct FinanceReadbackEvidenceReference: Codable, Equatable, Hashable, Sendable {
    public let source: String
    public let observedAt: Date
    public let component: String

    public init(source: String, observedAt: Date, component: String) throws {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedComponent = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty,
              !normalizedComponent.isEmpty,
              normalizedSource.utf8.count <= FinanceReadbackLimits.maximumHeaderBytes,
              normalizedComponent.utf8.count <= FinanceReadbackLimits.maximumHeaderBytes,
              observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FinanceReadbackValidationError.invalidMetadata
        }
        self.source = normalizedSource
        self.observedAt = observedAt
        self.component = normalizedComponent
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, observedAt, component
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceReadbackKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(String.self, forKey: .source),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            component: container.decode(String.self, forKey: .component)
        )
    }
}

public enum FinanceReadbackExclusionReason: String, Codable, Equatable, Sendable {
    case missingAccountSnapshot
    case accountUnavailable
    case missingBalance
    case unsupportedCurrency
    case staleObservation
    case futureObservation
    case partialCoverage
    case duplicateIdentity
    case conflictingIdentity
    case nonLiveSource
    case transactionSourceUnavailable
    case liveRecurringIdentityUnsupported
    case consentRequired
}

public struct FinanceReadbackExclusion: Codable, Equatable, Sendable {
    public let id: String
    public let reason: FinanceReadbackExclusionReason
    public let evidence: FinanceReadbackEvidenceReference?

    public init(
        id: String,
        reason: FinanceReadbackExclusionReason,
        evidence: FinanceReadbackEvidenceReference? = nil
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              normalizedID.utf8.count <= FinanceReadbackLimits.maximumHeaderBytes else {
            throw FinanceReadbackValidationError.invalidExclusion
        }
        self.id = normalizedID
        self.reason = reason
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, reason, evidence
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceReadbackKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            reason: container.decode(FinanceReadbackExclusionReason.self, forKey: .reason),
            evidence: container.decodeIfPresent(FinanceReadbackEvidenceReference.self, forKey: .evidence)
        )
    }
}

public struct FinanceReadbackCoverage: Codable, Equatable, Sendable {
    public let accountCount: Int
    public let observedAccountCount: Int
    public let unavailableAccountCount: Int
    public let staleAccountCount: Int
    public let futureAccountCount: Int
    public let transactionCount: Int
    public let hasTransactionSnapshot: Bool
    public let hasWealthSnapshot: Bool

    public init(
        accountCount: Int,
        observedAccountCount: Int,
        unavailableAccountCount: Int,
        staleAccountCount: Int,
        futureAccountCount: Int,
        transactionCount: Int,
        hasTransactionSnapshot: Bool,
        hasWealthSnapshot: Bool
    ) throws {
        guard 0...FinanceReadbackLimits.maximumAccounts ~= accountCount,
              0...accountCount ~= observedAccountCount,
              0...accountCount ~= unavailableAccountCount,
              0...accountCount ~= staleAccountCount,
              0...accountCount ~= futureAccountCount,
              observedAccountCount + unavailableAccountCount <= accountCount,
              staleAccountCount + futureAccountCount <= accountCount,
              0...FinanceReadbackLimits.maximumTransactions ~= transactionCount else {
            throw FinanceReadbackValidationError.invalidCoverage
        }
        self.accountCount = accountCount
        self.observedAccountCount = observedAccountCount
        self.unavailableAccountCount = unavailableAccountCount
        self.staleAccountCount = staleAccountCount
        self.futureAccountCount = futureAccountCount
        self.transactionCount = transactionCount
        self.hasTransactionSnapshot = hasTransactionSnapshot
        self.hasWealthSnapshot = hasWealthSnapshot
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case accountCount, observedAccountCount, unavailableAccountCount, staleAccountCount, futureAccountCount
        case transactionCount, hasTransactionSnapshot, hasWealthSnapshot
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceReadbackKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountCount: container.decode(Int.self, forKey: .accountCount),
            observedAccountCount: container.decode(Int.self, forKey: .observedAccountCount),
            unavailableAccountCount: container.decode(Int.self, forKey: .unavailableAccountCount),
            staleAccountCount: container.decode(Int.self, forKey: .staleAccountCount),
            futureAccountCount: container.decode(Int.self, forKey: .futureAccountCount),
            transactionCount: container.decode(Int.self, forKey: .transactionCount),
            hasTransactionSnapshot: container.decode(Bool.self, forKey: .hasTransactionSnapshot),
            hasWealthSnapshot: container.decode(Bool.self, forKey: .hasWealthSnapshot)
        )
    }
}

public enum FinanceRecurringEligibility: String, Codable, Equatable, Sendable {
    case unavailable
    case liveRowsRequireVersionedAccountIdentity
}

public enum FinanceReadbackAvailability: String, Codable, Equatable, Sendable {
    case observed
    case partial
    case stale
    case unavailable

    public var observationState: FinanceObservationState {
        switch self {
        case .observed: .observed
        case .partial: .partial
        case .stale: .stale
        case .unavailable: .unavailable
        }
    }
}

public struct FinanceReadbackAssessment: Codable, Equatable, Sendable {
    public let availability: FinanceReadbackAvailability
    public let bankingState: FinanceBankingState?
    public let isPartial: Bool
    public let generatedAt: Date
    public let latestSourceObservationAt: Date?
    public let lastSuccessfulObservationAt: Date?
    public let lastFailureAt: Date?
    public let coverage: FinanceReadbackCoverage
    public let evidence: [FinanceReadbackEvidenceReference]
    public let exclusions: [FinanceReadbackExclusion]
    public let recurringEligibility: FinanceRecurringEligibility

    public init(
        availability: FinanceReadbackAvailability,
        bankingState: FinanceBankingState?,
        isPartial: Bool,
        generatedAt: Date,
        latestSourceObservationAt: Date?,
        lastSuccessfulObservationAt: Date?,
        lastFailureAt: Date?,
        coverage: FinanceReadbackCoverage,
        evidence: [FinanceReadbackEvidenceReference],
        exclusions: [FinanceReadbackExclusion],
        recurringEligibility: FinanceRecurringEligibility
    ) throws {
        guard evidence.count <= FinanceReadbackLimits.maximumEvidenceReferences,
              exclusions.count <= FinanceReadbackLimits.maximumExclusions,
              Set(evidence).count == evidence.count,
              generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FinanceReadbackValidationError.tooManyItems
        }
        guard availability != .observed || !isPartial else {
            throw FinanceReadbackValidationError.contradictoryMetadata
        }
        self.availability = availability
        self.bankingState = bankingState
        self.isPartial = isPartial
        self.generatedAt = generatedAt
        self.latestSourceObservationAt = latestSourceObservationAt
        self.lastSuccessfulObservationAt = lastSuccessfulObservationAt
        self.lastFailureAt = lastFailureAt
        self.coverage = coverage
        self.evidence = evidence
        self.exclusions = exclusions
        self.recurringEligibility = recurringEligibility
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case availability, bankingState, isPartial, generatedAt
        case latestSourceObservationAt, lastSuccessfulObservationAt, lastFailureAt
        case coverage, evidence, exclusions, recurringEligibility
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFinanceReadbackKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            availability: container.decode(FinanceReadbackAvailability.self, forKey: .availability),
            bankingState: container.decodeIfPresent(FinanceBankingState.self, forKey: .bankingState),
            isPartial: container.decode(Bool.self, forKey: .isPartial),
            generatedAt: container.decode(Date.self, forKey: .generatedAt),
            latestSourceObservationAt: container.decodeIfPresent(Date.self, forKey: .latestSourceObservationAt),
            lastSuccessfulObservationAt: container.decodeIfPresent(Date.self, forKey: .lastSuccessfulObservationAt),
            lastFailureAt: container.decodeIfPresent(Date.self, forKey: .lastFailureAt),
            coverage: container.decode(FinanceReadbackCoverage.self, forKey: .coverage),
            evidence: container.decode([FinanceReadbackEvidenceReference].self, forKey: .evidence),
            exclusions: container.decode([FinanceReadbackExclusion].self, forKey: .exclusions),
            recurringEligibility: container.decode(FinanceRecurringEligibility.self, forKey: .recurringEligibility)
        )
    }
}

/// A compact, Codable envelope for a successful readback. The FinanceSummary
/// remains the existing source payload and is intentionally kept outside this
/// envelope so the envelope cannot accidentally become a second persistence or
/// wire contract for financial rows.
public struct FinanceReadback: Codable, Equatable, Sendable {
    public let response: FinanceResponseMetadata
    public let assessment: FinanceReadbackAssessment

    public init(response: FinanceResponseMetadata, assessment: FinanceReadbackAssessment) {
        self.response = response
        self.assessment = assessment
    }

    public static func make(
        summary: FinanceSummary,
        response: FinanceResponseMetadata,
        now: Date = .now,
        staleAfter: TimeInterval = 15 * 60
    ) throws -> FinanceReadback {
        guard staleAfter.isFinite, staleAfter >= 0 else {
            throw FinanceReadbackValidationError.invalidMetadata
        }

        var evidence = Set<FinanceReadbackEvidenceReference>()
        var exclusions: [FinanceReadbackExclusion] = []
        var accountCount = 0
        var observedAccountCount = 0
        var unavailableAccountCount = 0
        var staleAccountCount = 0
        var futureAccountCount = 0
        var transactionCount = 0
        var hasTransactionSnapshot = false

        func addEvidence(source: String, observedAt: Date, component: String) {
            guard evidence.count < FinanceReadbackLimits.maximumEvidenceReferences,
                  let reference = try? FinanceReadbackEvidenceReference(
                      source: source,
                      observedAt: observedAt,
                      component: component
                  ) else { return }
            evidence.insert(reference)
        }

        func addExclusion(
            id: String,
            reason: FinanceReadbackExclusionReason,
            source: String,
            observedAt: Date
        ) {
            guard exclusions.count < FinanceReadbackLimits.maximumExclusions,
                  let exclusion = try? FinanceReadbackExclusion(
                      id: id,
                      reason: reason,
                      evidence: try? FinanceReadbackEvidenceReference(
                          source: source,
                          observedAt: observedAt,
                          component: "account"
                      )
                  ) else { return }
            exclusions.append(exclusion)
        }

        if let accounts = summary.accounts {
            let rows = accounts.accounts ?? []
            guard rows.count <= FinanceReadbackLimits.maximumAccounts else {
                throw FinanceReadbackValidationError.tooManyItems
            }
            accountCount = rows.count
            for account in rows {
                let age = now.timeIntervalSince(account.provenance.observedAt)
                let accountID = "\(account.source)|\(account.id)"
                switch account.availability {
                case .unavailable:
                    unavailableAccountCount += 1
                    addExclusion(
                        id: accountID,
                        reason: Self.explicitlyNonEUR(account.detail) ? .unsupportedCurrency : .accountUnavailable,
                        source: account.source,
                        observedAt: account.provenance.observedAt
                    )
                case .observed:
                    guard account.balanceCents != nil else {
                        unavailableAccountCount += 1
                        addExclusion(
                            id: accountID,
                            reason: .missingBalance,
                            source: account.source,
                            observedAt: account.provenance.observedAt
                        )
                        continue
                    }
                    if Self.explicitlyNonEUR(account.detail) {
                        unavailableAccountCount += 1
                        addExclusion(
                            id: accountID,
                            reason: .unsupportedCurrency,
                            source: account.source,
                            observedAt: account.provenance.observedAt
                        )
                    } else if age < 0 {
                        futureAccountCount += 1
                        addExclusion(
                            id: accountID,
                            reason: .futureObservation,
                            source: account.source,
                            observedAt: account.provenance.observedAt
                        )
                    } else if age >= staleAfter
                                || account.provenance.freshness == .stale
                                || account.provenance.connectorState == .refreshDue {
                        staleAccountCount += 1
                        addExclusion(
                            id: accountID,
                            reason: age < 0 ? .futureObservation : .staleObservation,
                            source: account.source,
                            observedAt: account.provenance.observedAt
                        )
                    } else {
                        observedAccountCount += 1
                        addEvidence(
                            source: account.source,
                            observedAt: account.provenance.observedAt,
                            component: "account"
                        )
                    }
                }
            }
        } else {
            addExclusion(
                id: "accounts",
                reason: .missingAccountSnapshot,
                source: "no-authorized-finance-source",
                observedAt: summary.generatedAt
            )
        }

        if let transactions = summary.transactions {
            hasTransactionSnapshot = true
            let rows = transactions.transactions ?? []
            guard rows.count <= FinanceReadbackLimits.maximumTransactions else {
                throw FinanceReadbackValidationError.tooManyItems
            }
            transactionCount = rows.count
            if transactions.availability == .observed {
                for row in rows {
                    addEvidence(source: row.source, observedAt: row.provenance.observedAt, component: "transaction")
                }
            } else {
                addExclusion(
                    id: "transactions",
                    reason: .transactionSourceUnavailable,
                    source: transactions.provenance.source,
                    observedAt: transactions.provenance.observedAt
                )
            }
        }

        if let wealth = summary.wealth, wealth.availability == .observed {
            for holding in wealth.holdings ?? [] {
                addEvidence(source: holding.source, observedAt: holding.provenance.observedAt, component: "wealth")
            }
        }

        let summaryAssessment = summary.financeAssessment(now: now, staleAfter: staleAfter)
        let hasObservedValue = summaryAssessment.observedComponentCount > 0
            || observedAccountCount > 0
            || (hasTransactionSnapshot && summary.transactions?.availability == .observed)
        let hasStaleValue = staleAccountCount > 0
            || futureAccountCount > 0
            || summaryAssessment.state == .stale
            || response.bankingState.map { ![.healthy, .partial].contains($0) } == true
        let partial = response.isPartial == true
            || summaryAssessment.state == .partial
            || unavailableAccountCount > 0
            || summary.accounts == nil
            || (hasTransactionSnapshot && summary.transactions?.availability == .unavailable)

        let availability: FinanceReadbackAvailability
        if response.bankingState == .consent {
            availability = .unavailable
            addExclusion(
                id: "finance-consent",
                reason: .consentRequired,
                source: "finance-gateway",
                observedAt: summary.generatedAt
            )
        } else if !hasObservedValue {
            availability = .unavailable
        } else if hasStaleValue {
            availability = .stale
        } else if partial {
            availability = .partial
        } else {
            availability = .observed
        }

        let sourceObservations = evidence.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.component < $1.component
        }
        let latestSourceObservationAt = sourceObservations.map(\.observedAt).max()
        let coverage = try FinanceReadbackCoverage(
            accountCount: accountCount,
            observedAccountCount: observedAccountCount,
            unavailableAccountCount: unavailableAccountCount,
            staleAccountCount: staleAccountCount,
            futureAccountCount: futureAccountCount,
            transactionCount: transactionCount,
            hasTransactionSnapshot: hasTransactionSnapshot,
            hasWealthSnapshot: summary.wealth != nil
        )
        let assessment = try FinanceReadbackAssessment(
            availability: availability,
            bankingState: response.bankingState,
            isPartial: partial,
            generatedAt: summary.generatedAt,
            latestSourceObservationAt: latestSourceObservationAt,
            lastSuccessfulObservationAt: response.lastSuccessAt,
            lastFailureAt: response.lastFailureAt,
            coverage: coverage,
            evidence: sourceObservations,
            exclusions: exclusions,
            recurringEligibility: hasTransactionSnapshot && summary.transactions?.availability == .observed
                ? .liveRowsRequireVersionedAccountIdentity
                : .unavailable
        )
        return FinanceReadback(response: response, assessment: assessment)
    }

    private static func explicitlyNonEUR(_ detail: String) -> Bool {
        let knownNonEURCodes: Set<String> = [
            "USD", "GBP", "CHF", "CAD", "AUD", "JPY", "PLN", "SEK", "DKK", "NOK", "CZK", "HUF"
        ]
        return detail.uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .contains(where: knownNonEURCodes.contains)
    }
}

/// The summary stays as the compatibility payload; this result merely joins
/// it with the independently validated response envelope for coordinator/UI
/// state. It is intentionally not Codable so no second financial wire format
/// can be inferred from it.
public struct FinanceReadbackResult: Equatable, Sendable {
    public let summary: FinanceSummary
    public let readback: FinanceReadback

    public init(summary: FinanceSummary, readback: FinanceReadback) {
        self.summary = summary
        self.readback = readback
    }
}
