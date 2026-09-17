import Foundation

public enum FinanceBankCashProjectionAvailability: String, Codable, Equatable, Sendable {
    case observed
    case partial
    case stale
    case unavailable

    public var label: String {
        switch self {
        case .observed: "Observed"
        case .partial: "Partial"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        }
    }
}

public enum FinanceBankCashExclusionReason: String, Codable, Equatable, Sendable {
    case missingAccountSnapshot
    case unavailableAccount
    case missingBalance
    case unsupportedCurrency
    case staleObservation
    case futureObservation
    case partialCoverage
    case duplicateIdentity
    case conflictingIdentity
    case nonLiveSource
    case unsupportedSource
    case overflow
    case consentRequired
    case refreshFailed
}

public struct FinanceBankCashExclusion: Codable, Equatable, Sendable {
    public let identity: String
    public let reason: FinanceBankCashExclusionReason
    public let evidence: FinanceReadbackEvidenceReference?

    public init(
        identity: String,
        reason: FinanceBankCashExclusionReason,
        evidence: FinanceReadbackEvidenceReference? = nil
    ) {
        self.identity = identity
        self.reason = reason
        self.evidence = evidence
    }
}

/// A source-backed subtotal of live EUR bank balances. It is deliberately
/// separate from `FinanceNetWorthBreakdown`: a bank-only projection can never
/// claim complete personal net worth while investment holdings and other
/// wealth sources remain outside this connector response.
public struct FinanceBankCashProjection: Codable, Equatable, Sendable {
    public let availability: FinanceBankCashProjectionAvailability
    public let totalCents: Int?
    public let includedAccounts: [FinanceVerifiedBankCashObservation]
    public let exclusions: [FinanceBankCashExclusion]
    public let observedAt: Date?
    public let evidence: [FinanceReadbackEvidenceReference]

    public var isBankOnlySubtotal: Bool { true }
    public var netWorthAvailability: FinanceNetWorthAvailability { .partial }

    public var detailText: String {
        switch availability {
        case .observed:
            return "\(includedAccounts.count) source-backed EUR balance\(includedAccounts.count == 1 ? "" : "s") · investments excluded"
        case .partial:
            return "Partial EUR balances · \(exclusions.count) excluded · investments excluded"
        case .stale:
            return "Last observed EUR balances · refresh required"
        case .unavailable:
            return "EUR bank cash is not available from an authorized source"
        }
    }

    public var accessibilityValue: String {
        if let totalCents {
            return "\(totalCents) cents, \(availability.label)"
        }
        return "\(availability.label), amount not available"
    }

    public init(
        availability: FinanceBankCashProjectionAvailability,
        totalCents: Int?,
        includedAccounts: [FinanceVerifiedBankCashObservation],
        exclusions: [FinanceBankCashExclusion],
        observedAt: Date?,
        evidence: [FinanceReadbackEvidenceReference]
    ) {
        self.availability = availability
        self.totalCents = totalCents
        self.includedAccounts = includedAccounts
        self.exclusions = exclusions
        self.observedAt = observedAt
        self.evidence = evidence
    }

    public static func project(
        summary: FinanceSummary?,
        readback: FinanceReadback? = nil,
        requestedState: FinanceObservationState? = nil,
        now: Date = .now,
        maximumObservationAge: TimeInterval = 15 * 60
    ) -> FinanceBankCashProjection {
        guard maximumObservationAge.isFinite, maximumObservationAge >= 0 else {
            return unavailable(reason: .missingAccountSnapshot)
        }
        guard let summary else {
            return unavailable(reason: .missingAccountSnapshot)
        }
        guard let accountSnapshot = summary.accounts else {
            return unavailable(reason: .missingAccountSnapshot)
        }
        guard accountSnapshot.availability == .observed,
              let accountRows = accountSnapshot.accounts else {
            return unavailable(reason: .missingAccountSnapshot)
        }

        var exclusions: [FinanceBankCashExclusion] = []
        var grouped: [String: [FinanceAccountObservation]] = [:]
        let rows = accountRows
        for row in rows {
            let identity = Self.identity(for: row)
            grouped[identity, default: []].append(row)
        }

        var candidates: [FinanceAccountObservation] = []
        candidates.reserveCapacity(grouped.count)
        for identity in grouped.keys.sorted() {
            guard let group = grouped[identity] else { continue }
            if group.count > 1 {
                let conflicting = Set(group.map { "\($0.balanceCents.map(String.init) ?? "nil")|\($0.provenance.observedAt.timeIntervalSinceReferenceDate)" }).count > 1
                let reason: FinanceBankCashExclusionReason = conflicting ? .conflictingIdentity : .duplicateIdentity
                for row in group {
                    exclusions.append(Self.exclusion(identity: identity, reason: reason, row: row))
                }
            } else if let row = group.first {
                candidates.append(row)
            }
        }

        var included: [FinanceVerifiedBankCashObservation] = []
        included.reserveCapacity(candidates.count)
        var evidence = Set<FinanceReadbackEvidenceReference>()
        var total = 0
        var sumOverflowed = false
        var hasFreshOrObservedRows = false
        var hasStaleRows = false

        for row in candidates {
            let identity = Self.identity(for: row)
            let normalizedSource = Self.normalizedSource(row.source)
            if let sourceExclusion = Self.sourceExclusionReason(for: normalizedSource) {
                exclusions.append(Self.exclusion(identity: identity, reason: sourceExclusion, row: row))
                continue
            }
            let verifiedSource = Self.canonicalSource(for: normalizedSource) ?? normalizedSource
            if row.availability == .unavailable {
                exclusions.append(Self.exclusion(
                    identity: identity,
                    reason: Self.explicitlyNonEUR(row.detail) ? .unsupportedCurrency : .unavailableAccount,
                    row: row
                ))
                continue
            }
            guard let balanceCents = row.balanceCents else {
                exclusions.append(Self.exclusion(identity: identity, reason: .missingBalance, row: row))
                continue
            }
            if Self.explicitlyNonEUR(row.detail) {
                exclusions.append(Self.exclusion(identity: identity, reason: .unsupportedCurrency, row: row))
                continue
            }

            let age = now.timeIntervalSince(row.provenance.observedAt)
            if age < 0 {
                hasStaleRows = true
                exclusions.append(Self.exclusion(identity: identity, reason: .futureObservation, row: row))
                continue
            }
            if age >= maximumObservationAge
                || row.provenance.freshness == .stale
                || row.provenance.connectorState == .refreshDue {
                hasStaleRows = true
                exclusions.append(Self.exclusion(identity: identity, reason: .staleObservation, row: row))
                continue
            }

            guard let amount = Self.money(cents: balanceCents),
                  let observation = try? FinanceVerifiedBankCashObservation(
                      accountID: row.id,
                      amount: amount,
                      observedAt: row.provenance.observedAt,
                      source: verifiedSource,
                      verificationID: "finance-account|\(identity)|\(row.provenance.observedAt.timeIntervalSinceReferenceDate)"
                  ) else {
                exclusions.append(Self.exclusion(identity: identity, reason: .missingBalance, row: row))
                continue
            }
            let addition = total.addingReportingOverflow(balanceCents)
            guard !addition.overflow else {
                sumOverflowed = true
                exclusions.append(Self.exclusion(identity: identity, reason: .overflow, row: row))
                continue
            }
            total = addition.partialValue
            included.append(observation)
            hasFreshOrObservedRows = true
            if let reference = try? FinanceReadbackEvidenceReference(
                source: verifiedSource,
                observedAt: row.provenance.observedAt,
                component: "account"
            ) {
                evidence.insert(reference)
            }
        }

        if let readback {
            switch readback.assessment.availability {
            case .unavailable:
                hasStaleRows = true
                exclusions.append(FinanceBankCashExclusion(
                    identity: "finance-readback",
                    reason: readback.assessment.bankingState == .consent ? .consentRequired : .refreshFailed
                ))
            case .stale:
                hasStaleRows = true
                exclusions.append(FinanceBankCashExclusion(identity: "finance-readback", reason: .refreshFailed))
            case .partial:
                exclusions.append(FinanceBankCashExclusion(identity: "finance-readback", reason: .partialCoverage))
            case .observed:
                break
            }
        }
        if requestedState == .error {
            hasStaleRows = true
            exclusions.append(FinanceBankCashExclusion(identity: "finance-refresh", reason: .refreshFailed))
        } else if requestedState == .stale {
            hasStaleRows = true
            exclusions.append(FinanceBankCashExclusion(identity: "finance-refresh", reason: .refreshFailed))
        } else if requestedState == .partial {
            exclusions.append(FinanceBankCashExclusion(identity: "finance-refresh", reason: .partialCoverage))
        }

        let accountSnapshotIsPartial = accountSnapshot.accounts?.contains { $0.availability == .unavailable } == true
        let partial = accountSnapshotIsPartial || !exclusions.isEmpty || readback?.assessment.isPartial == true
        let availability: FinanceBankCashProjectionAvailability
        if !hasFreshOrObservedRows {
            availability = hasStaleRows ? .stale : (rows.isEmpty ? .unavailable : .partial)
        } else if hasStaleRows {
            availability = .stale
        } else if partial {
            availability = .partial
        } else {
            availability = .observed
        }

        let observedAt = included.map(\.observedAt).max()
        exclusions.sort {
            if $0.identity != $1.identity { return $0.identity < $1.identity }
            return $0.reason.rawValue < $1.reason.rawValue
        }
        return FinanceBankCashProjection(
            availability: sumOverflowed ? .unavailable : availability,
            totalCents: sumOverflowed ? nil : (included.isEmpty ? nil : total),
            includedAccounts: included.sorted { lhs, rhs in
                if lhs.source != rhs.source { return lhs.source < rhs.source }
                return lhs.accountID < rhs.accountID
            },
            exclusions: exclusions,
            observedAt: observedAt,
            evidence: evidence.sorted {
                if $0.source != $1.source { return $0.source < $1.source }
                if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                return $0.component < $1.component
            }
        )
    }

    public static func unavailable(reason: FinanceBankCashExclusionReason) -> FinanceBankCashProjection {
        FinanceBankCashProjection(
            availability: .unavailable,
            totalCents: nil,
            includedAccounts: [],
            exclusions: [FinanceBankCashExclusion(identity: "finance-accounts", reason: reason)],
            observedAt: nil,
            evidence: []
        )
    }

    private static func identity(for row: FinanceAccountObservation) -> String {
        "\(canonicalSource(for: row.source) ?? normalizedSource(row.source))|\(row.id)"
    }

    private static func exclusion(
        identity: String,
        reason: FinanceBankCashExclusionReason,
        row: FinanceAccountObservation
    ) -> FinanceBankCashExclusion {
        FinanceBankCashExclusion(
            identity: identity,
            reason: reason,
            evidence: try? FinanceReadbackEvidenceReference(
                source: canonicalSource(for: row.source) ?? normalizedSource(row.source),
                observedAt: row.provenance.observedAt,
                component: "account"
            )
        )
    }

    private static func sourceExclusionReason(for source: String) -> FinanceBankCashExclusionReason? {
        let normalized = normalizedSource(source)
        if canonicalSource(for: normalized) != nil {
            return nil
        }
        switch normalized {
        case "csv", "manual", "robinhood", "trade-republic", "trade_republic", "traderepublic":
            return .nonLiveSource
        default:
            // A provenance label is data from the wire, not proof that a
            // connector was reviewed. Keep matching closed and exact.
            return .unsupportedSource
        }
    }

    private static func normalizedSource(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func canonicalSource(for source: String) -> String? {
        switch normalizedSource(source) {
        case "sparkasse_leipzig", "enablebanking:sparkasse_leipzig":
            return "enablebanking:sparkasse_leipzig"
        case "revolut_personal", "enablebanking:revolut_personal":
            return "enablebanking:revolut_personal"
        default:
            return nil
        }
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

    // Kept internal so the Mac logic lane can exercise the same conversion
    // used by projection without constructing an otherwise invalid summary.
    static func money(cents: Int) -> FinanceInvestmentMoney? {
        let maximumSafeCents = 9_007_199_254_740_991
        guard cents >= -maximumSafeCents, cents <= maximumSafeCents else { return nil }
        let sign = cents < 0 ? "-" : ""
        // `Int.min` cannot be negated as an `Int`. `magnitude` is the
        // overflow-safe unsigned representation, so malformed direct inputs
        // cannot trap the projection while the source-domain decoder still
        // rejects values outside its bounded cents range.
        let magnitude = cents.magnitude
        let whole = magnitude / 100
        let fractionValue = String(magnitude % 100)
        let fraction = String(repeating: "0", count: max(0, 2 - fractionValue.count)) + fractionValue
        guard let exact = try? FinanceExactDecimal("\(sign)\(whole).\(fraction)") else { return nil }
        return try? FinanceInvestmentMoney(amount: exact, currency: "EUR")
    }
}
