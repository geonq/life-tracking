import CryptoKit
import Foundation

/// Immutable detector input. The raw transaction values are held only for the
/// duration of local calculation; the durable recurring store persists hashes,
/// references and assessment metadata, never transaction copies.
public struct FinanceRecurringPaymentInput: Equatable, Sendable {
    public let transactions: [FinanceImportedTransaction]
    public let batches: [FinanceImportBatchProvenance]
    public let timeZoneIdentifier: String
    public let inputDigest: String

    fileprivate let evidenceByTransactionID: [UUID: FinanceRecurringEvidenceReference]

    fileprivate init(
        transactions: [FinanceImportedTransaction],
        batches: [FinanceImportBatchProvenance],
        timeZoneIdentifier: String,
        inputDigest: String,
        evidenceByTransactionID: [UUID: FinanceRecurringEvidenceReference]
    ) {
        self.transactions = transactions
        self.batches = batches
        self.timeZoneIdentifier = timeZoneIdentifier
        self.inputDigest = inputDigest
        self.evidenceByTransactionID = evidenceByTransactionID
    }
}

public enum FinanceRecurringPaymentDetectorError: Error, Equatable, Sendable {
    case invalidTimeZone
    case inputTooLarge
    case conflictingTransactionID
    case invalidTransaction
    case invalidDate
    case calendarCalculationFailed
}

/// Pure, deterministic recurring-payment detection for reviewed mapped-v3
/// imports. It intentionally does not inspect live Finance observations.
public enum FinanceRecurringPaymentDetector {
    private static let maximumSafeCents = FinanceImportedSyncRecord.maximumSafeCents
    private static let cadenceOrder: [FinanceRecurringCadence] = [.weekly, .monthly, .yearly]
    private static let calendarToleranceDays = 3

    private struct DigestRow: Codable, Sendable {
        let id: String
        let bookedAt: Date
        let amountCents: Int
        let description: String
        let category: String?
        let sourceCategory: String?
        let providerCode: String?
        let source: FinanceImportSource
        let identityScheme: FinanceImportedIdentityScheme
        let accountID: String?
        let kind: FinanceImportedTransactionKind
        let investmentSymbol: String?
        let investmentTradeType: String?
        let evidence: FinanceRecurringEvidenceReference?
    }

    private struct PaymentObservation: Sendable {
        let transaction: FinanceImportedTransaction
        let key: FinanceRecurringPaymentKey
        let evidence: FinanceRecurringEvidenceReference
        let localDate: Date
        let amountMagnitudeCents: Int
    }

    private struct CadenceScan {
        let cadence: FinanceRecurringCadence
        let anchorObservation: PaymentObservation
        let observations: [PaymentObservation]
        let representatives: [PaymentObservation]
        let lastConsumedPeriodIndex: Int
        let supportCount: Int
        let totalDateDeviation: Int
        let amountConsistent: Bool
        let ambiguous: Bool
        let scheduleDrift: Bool
    }

    /// Builds a bounded input and collapses exact duplicate observations by
    /// UUID. A same-ID disagreement fails closed instead of choosing one row.
    public static func makeInput(
        transactions: [FinanceImportedTransaction],
        batches: [FinanceImportBatchProvenance],
        timeZoneIdentifier: String = FinanceRecurringPaymentContract.defaultTimeZoneIdentifier
    ) throws -> FinanceRecurringPaymentInput {
        guard transactions.count <= FinanceImportedTransactionStore.maximumTransactions,
              batches.count <= FinanceImportedTransactionStore.maximumImportBatches else {
            throw FinanceRecurringPaymentDetectorError.inputTooLarge
        }
        _ = try calendar(for: timeZoneIdentifier)

        var uniqueByID: [UUID: FinanceImportedTransaction] = [:]
        uniqueByID.reserveCapacity(transactions.count)
        for transaction in transactions {
            try Task.checkCancellation()
            guard transaction.bookedAt.timeIntervalSinceReferenceDate.isFinite,
                  transaction.importedAt.timeIntervalSinceReferenceDate.isFinite,
                  transaction.description.utf8.count <= FinanceImportedSyncRecord.maximumDescriptionBytes else {
                throw FinanceRecurringPaymentDetectorError.invalidTransaction
            }
            if let prior = uniqueByID[transaction.id] {
                guard prior.hasSameSourceObservation(as: transaction),
                      prior.category == transaction.category else {
                    throw FinanceRecurringPaymentDetectorError.conflictingTransactionID
                }
                continue
            }
            uniqueByID[transaction.id] = transaction
        }

        var evidenceByTransactionID: [UUID: FinanceRecurringEvidenceReference] = [:]
        for batch in batches.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            for link in batch.rowLinks.sorted(by: { lhs, rhs in
                if lhs.sourceRowNumber != rhs.sourceRowNumber {
                    return lhs.sourceRowNumber < rhs.sourceRowNumber
                }
                return lhs.transactionID.uuidString < rhs.transactionID.uuidString
            }) {
                guard uniqueByID[link.transactionID] != nil,
                      evidenceByTransactionID[link.transactionID] == nil else {
                    continue
                }
                evidenceByTransactionID[link.transactionID] = try FinanceRecurringEvidenceReference(
                    sourceNamespace: uniqueByID[link.transactionID]!.source.rawValue,
                    transactionID: link.transactionID,
                    batchID: batch.id,
                    sourceRowNumber: link.sourceRowNumber
                )
            }
        }

        let orderedTransactions = uniqueByID.values.sorted { lhs, rhs in
            if lhs.bookedAt != rhs.bookedAt { return lhs.bookedAt < rhs.bookedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for transaction in orderedTransactions where transaction.identityScheme == .mappedV3 {
            try Task.checkCancellation()
            guard transaction.mappedIdentity != nil,
                  evidenceByTransactionID[transaction.id] == nil else { continue }
            evidenceByTransactionID[transaction.id] = try FinanceRecurringEvidenceReference(
                sourceNamespace: transaction.source.rawValue,
                transactionID: transaction.id
            )
        }
        let digestRows = orderedTransactions.map { transaction in
            DigestRow(
                id: transaction.id.uuidString.lowercased(),
                bookedAt: transaction.bookedAt,
                amountCents: transaction.amountCents,
                description: transaction.description,
                category: transaction.category,
                sourceCategory: transaction.sourceCategory,
                providerCode: transaction.providerCode,
                source: transaction.source,
                identityScheme: transaction.identityScheme,
                accountID: transaction.mappedIdentity?.accountID.uuidString.lowercased(),
                kind: transaction.kind,
                investmentSymbol: transaction.investment?.symbol,
                investmentTradeType: transaction.investment?.tradeType,
                evidence: evidenceByTransactionID[transaction.id]
            )
        }
        let encoder = JSONEncoder.lifeOS
        encoder.outputFormatting = [.sortedKeys]
        let digestData = try encoder.encode(digestRows)
        let digest = SHA256.hash(data: digestData).map { String(format: "%02x", $0) }.joined()

        _ = calendar
        return FinanceRecurringPaymentInput(
            transactions: orderedTransactions,
            batches: batches,
            timeZoneIdentifier: timeZoneIdentifier,
            inputDigest: digest,
            evidenceByTransactionID: evidenceByTransactionID
        )
    }

    /// Runs the complete bounded detector. Grouping is O(n), each group is
    /// sorted once, and the three cadence scans are linear in that sorted
    /// group, yielding O(n log n) time and O(n) memory.
    public static func detect(
        input: FinanceRecurringPaymentInput,
        now: Date = .now
    ) throws -> FinanceRecurringPaymentAssessment {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw FinanceRecurringPaymentDetectorError.invalidDate
        }
        let calendar = try calendar(for: input.timeZoneIdentifier)
        guard input.transactions.count <= FinanceImportedTransactionStore.maximumTransactions else {
            throw FinanceRecurringPaymentDetectorError.inputTooLarge
        }

        var exclusionCounts: [FinanceRecurringReasonCode: Int] = [:]
        var grouped: [FinanceRecurringPaymentKey: [PaymentObservation]] = [:]
        grouped.reserveCapacity(input.transactions.count)

        for transaction in input.transactions {
            try Task.checkCancellation()
            guard let observation = try eligibleObservation(
                transaction,
                evidence: input.evidenceByTransactionID[transaction.id],
                calendar: calendar
            ) else {
                let reason = exclusionReason(
                    for: transaction,
                    hasEvidence: input.evidenceByTransactionID[transaction.id] != nil
                )
                exclusionCounts[reason, default: 0] += 1
                continue
            }
            grouped[observation.key, default: []].append(observation)
        }

        var builds: [FinanceRecurringPaymentCandidate] = []
        builds.reserveCapacity(grouped.count)
        for (key, rows) in grouped {
            try Task.checkCancellation()
            let ordered = rows.sorted { lhs, rhs in
                if lhs.localDate != rhs.localDate { return lhs.localDate < rhs.localDate }
                return lhs.transaction.id.uuidString < rhs.transaction.id.uuidString
            }
            if let candidate = try buildCandidate(key: key, observations: ordered, calendar: calendar) {
                builds.append(candidate)
            }
        }

        let candidates = builds.sorted { lhs, rhs in lhs.id < rhs.id }
        let exclusions = try exclusionCounts
            .sorted { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
            .map { try FinanceRecurringExclusion(reason: $0.key, count: $0.value) }
        let coverage: FinanceRecurringCoverage = grouped.isEmpty
            ? .noValidatedMappedImports
            : .mappedImportsOnly
        return try FinanceRecurringPaymentAssessment(
            candidates: candidates,
            exclusions: exclusions,
            coverage: coverage,
            timeZoneIdentifier: input.timeZoneIdentifier,
            generatedAt: now
        )
    }

    /// Validates a rebuildable cache against the exact immutable input that is
    /// currently on screen. A matching digest alone is insufficient if a file
    /// was edited without recomputing its assessment, so every cached evidence
    /// reference is also checked against the current eligible identity.
    public static func validateCachedAssessment(
        _ assessment: FinanceRecurringPaymentAssessment,
        for input: FinanceRecurringPaymentInput
    ) -> Bool {
        guard assessment.detectorVersion == FinanceRecurringPaymentContract.detectorVersion,
              assessment.timeZoneIdentifier == input.timeZoneIdentifier else {
            return false
        }
        guard let calendar = try? calendar(for: input.timeZoneIdentifier) else { return false }
        var eligibleByID: [UUID: PaymentObservation] = [:]
        eligibleByID.reserveCapacity(input.transactions.count)
        do {
            for transaction in input.transactions {
                try Task.checkCancellation()
                if let observation = try eligibleObservation(
                    transaction,
                    evidence: input.evidenceByTransactionID[transaction.id],
                    calendar: calendar
                ) {
                    eligibleByID[transaction.id] = observation
                }
            }
        } catch {
            return false
        }
        return assessment.candidates.allSatisfy { candidate in
            candidate.detectorVersion == assessment.detectorVersion
                && candidate.anchor.timeZoneIdentifier == assessment.timeZoneIdentifier
                && candidate.key.normalizationVersion == FinanceRecurringPaymentContract.normalizationVersion
                && candidate.supportingEvidence.allSatisfy { reference in
                    guard let observation = eligibleByID[reference.transactionID] else { return false }
                    return reference.sourceNamespace == candidate.key.sourceNamespace
                        && observation.key == candidate.key
                }
        }
    }

    /// Returns the next calendar occurrence after `date` using the anchor's
    /// original month/day. This avoids February clamping drift and keeps DST
    /// in local calendar space rather than fixed seconds.
    public static func nextExpectedDate(
        cadence: FinanceRecurringCadence,
        anchor: FinanceRecurringAnchor,
        after date: Date
    ) throws -> Date {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw FinanceRecurringPaymentDetectorError.invalidDate
        }
        let calendar = try anchor.calendar()
        let anchorComponents = calendar.dateComponents([.year, .month, .day], from: anchor.date)
        guard let anchorYear = anchorComponents.year,
              let anchorMonth = anchorComponents.month else {
            throw FinanceRecurringPaymentDetectorError.calendarCalculationFailed
        }

        var index: Int
        switch cadence {
        case .weekly:
            let start = calendar.startOfDay(for: anchor.date)
            let target = calendar.startOfDay(for: date)
            let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
            index = max(0, days / 7)
        case .monthly:
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else {
                throw FinanceRecurringPaymentDetectorError.calendarCalculationFailed
            }
            index = max(0, (year - anchorYear) * 12 + month - anchorMonth)
        case .yearly:
            let year = calendar.component(.year, from: date)
            index = max(0, year - anchorYear)
        }

        for _ in 0..<12_000 {
            guard let candidate = scheduledDate(
                anchor: anchor,
                cadence: cadence,
                periodIndex: index,
                calendar: calendar
            ) else {
                throw FinanceRecurringPaymentDetectorError.calendarCalculationFailed
            }
            if candidate > date { return candidate }
            index += 1
        }
        throw FinanceRecurringPaymentDetectorError.calendarCalculationFailed
    }

    /// Returns the occurrence after a cadence period that has already been
    /// consumed by the detector. This is intentionally separate from the
    /// timestamp-based overload: a payment may arrive before its scheduled
    /// day, and using that timestamp alone would return the same period again.
    public static func nextExpectedDate(
        cadence: FinanceRecurringCadence,
        anchor: FinanceRecurringAnchor,
        afterConsumedPeriodIndex periodIndex: Int
    ) throws -> Date {
        guard periodIndex >= 0 else {
            throw FinanceRecurringPaymentDetectorError.invalidDate
        }
        let calendar = try anchor.calendar()
        guard let next = scheduledDate(
            anchor: anchor,
            cadence: cadence,
            periodIndex: periodIndex + 1,
            calendar: calendar
        ) else {
            throw FinanceRecurringPaymentDetectorError.calendarCalculationFailed
        }
        return next
    }

    /// Finds the last calendar period represented by a set of supporting
    /// payments for a user-managed schedule. Every evidence date must fit the
    /// same bounded calendar tolerance; otherwise the override is left without
    /// a prediction instead of silently falling back to timestamp arithmetic.
    public static func consumedPeriodIndex(
        cadence: FinanceRecurringCadence,
        anchor: FinanceRecurringAnchor,
        evidenceDates: [Date]
    ) throws -> Int? {
        guard !evidenceDates.isEmpty else { return nil }
        let calendar = try anchor.calendar()
        var lastPeriodIndex = -1
        for date in evidenceDates.sorted() {
            guard date.timeIntervalSinceReferenceDate.isFinite,
                  let match = scheduleMatch(
                      cadence: cadence,
                      anchor: anchor,
                      date: date,
                      calendar: calendar
                  ),
                  match.periodIndex >= lastPeriodIndex else {
                return nil
            }
            lastPeriodIndex = max(lastPeriodIndex, match.periodIndex)
        }
        return lastPeriodIndex >= 0 ? lastPeriodIndex : nil
    }

    public static func normalizedMerchantKey(_ value: String) -> String? {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in value.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased().unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if pendingSpace, !output.isEmpty { output.append(" ") }
                output.append(scalar)
                pendingSpace = false
            } else {
                pendingSpace = true
            }
        }
        let normalized = String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= FinanceRecurringPaymentContract.maximumMerchantKeyBytes else {
            return nil
        }
        return normalized
    }

    private static func calendar(for identifier: String) throws -> Calendar {
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw FinanceRecurringPaymentDetectorError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    private static func eligibleObservation(
        _ transaction: FinanceImportedTransaction,
        evidence: FinanceRecurringEvidenceReference?,
        calendar: Calendar
    ) throws -> PaymentObservation? {
        guard transaction.identityScheme == .mappedV3 else { return nil }
        guard let mappedIdentity = transaction.mappedIdentity else { return nil }
        guard classificationExclusionReason(for: transaction) == nil else { return nil }
        guard transaction.kind == .cash,
              transaction.investment == nil,
              transaction.amountCents < 0,
              transaction.amountCents >= -maximumSafeCents,
              let evidence else { return nil }
        guard let merchant = normalizedMerchantKey(transaction.description) else { return nil }
        guard let key = try? FinanceRecurringPaymentKey(
            sourceNamespace: transaction.source.rawValue,
            accountID: mappedIdentity.accountID,
            currency: "EUR",
            normalizedMerchantKey: merchant
        ) else { return nil }
        let magnitude = -transaction.amountCents
        let localDate = calendar.startOfDay(for: transaction.bookedAt)
        guard localDate.timeIntervalSinceReferenceDate.isFinite else {
            throw FinanceRecurringPaymentDetectorError.invalidDate
        }
        return PaymentObservation(
            transaction: transaction,
            key: key,
            evidence: evidence,
            localDate: localDate,
            amountMagnitudeCents: magnitude
        )
    }

    private static func exclusionReason(
        for transaction: FinanceImportedTransaction,
        hasEvidence: Bool
    ) -> FinanceRecurringReasonCode {
        guard transaction.identityScheme == .mappedV3 else { return .unsupportedLegacyIdentity }
        guard transaction.mappedIdentity != nil else { return .missingMappedIdentity }
        if let classification = classificationExclusionReason(for: transaction) {
            return classification
        }
        guard hasEvidence else { return .missingProvenance }
        guard transaction.kind == .cash, transaction.investment == nil else { return .investmentOrder }
        guard transaction.amountCents < 0 else { return .notNegativeCash }
        if normalizedMerchantKey(transaction.description) == nil { return .emptyMerchant }
        return .unsupportedCurrency
    }

    private static func classificationExclusionReason(
        for transaction: FinanceImportedTransaction
    ) -> FinanceRecurringReasonCode? {
        let categories = [
            transaction.category.flatMap(FinanceTransactionCategory.init(rawValue:)),
            FinanceTransactionCategory.from(sourceCategory: transaction.sourceCategory)
        ].compactMap { $0 }
        if categories.contains(.income) { return .income }
        if categories.contains(.transfers) { return .transfer }
        if categories.contains(.investments) || transaction.kind == .investmentOrder || transaction.investment != nil {
            return .investmentOrder
        }

        let classification = [transaction.description, transaction.sourceCategory ?? ""]
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        if ["refund", "refunded", "erstattung", "rückerstattung", "rueckerstattung", "reimbursement", "chargeback"]
            .contains(where: classification.contains) {
            return .refund
        }
        if ["transfer", "überweisung", "ueberweisung", "bank transfer", "sepa transfer"]
            .contains(where: classification.contains) {
            return .transfer
        }
        return nil
    }

    private static func buildCandidate(
        key: FinanceRecurringPaymentKey,
        observations: [PaymentObservation],
        calendar: Calendar
    ) throws -> FinanceRecurringPaymentCandidate? {
        guard let first = observations.first else { return nil }
        let firstAnchor = try FinanceRecurringAnchor(
            date: first.transaction.bookedAt,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
        var scans: [CadenceScan] = []
        scans.reserveCapacity(cadenceOrder.count)
        for cadence in cadenceOrder {
            if let scan = try scan(cadence: cadence, observations: observations, calendar: calendar) {
                scans.append(scan)
            }
        }
        let viable = scans.filter { $0.supportCount >= 3 }

        guard let best = viable.sorted(by: rank).first else {
            let candidate = try FinanceRecurringPaymentCandidate(
                key: key,
                supportingEvidence: observations.map(\.evidence),
                detectedCadence: nil,
                confidence: .needsReview,
                reasonCodes: [.insufficientHistory],
                anchor: firstAnchor,
                predictedDate: nil,
                latestEligiblePaymentDate: observations.map(\.transaction.bookedAt).max()
            )
            return candidate
        }

        let tie = viable.contains { other in
            other.cadence != best.cadence
                && other.supportCount == best.supportCount
                && other.totalDateDeviation == best.totalDateDeviation
        }
        var reasons: Set<FinanceRecurringReasonCode> = []
        if best.supportCount == 3 { reasons.insert(.minimumHistoryOnly) }
        if !best.amountConsistent { reasons.insert(.amountVariance) }
        if best.ambiguous { reasons.insert(.multiplePaymentsInPeriod) }
        if best.scheduleDrift { reasons.insert(.scheduleDrift) }
        if tie { reasons.insert(.ambiguousCadence) }

        let proposedPrediction = try nextExpectedDate(
            cadence: best.cadence,
            anchor: try FinanceRecurringAnchor(
                date: best.anchorObservation.transaction.bookedAt,
                timeZoneIdentifier: calendar.timeZone.identifier
            ),
            afterConsumedPeriodIndex: best.lastConsumedPeriodIndex
        )
        let latestEligiblePaymentDate = observations.map(\.transaction.bookedAt).max()
        let predictionIsSafe = !best.scheduleDrift
            && latestEligiblePaymentDate.map { proposedPrediction > $0 } == true
        if !predictionIsSafe { reasons.insert(.scheduleDrift) }
        let highConfidence = best.supportCount >= 4
            && best.amountConsistent
            && !best.ambiguous
            && predictionIsSafe
            && !tie
        let confidence: FinanceRecurringConfidence = highConfidence ? .high : .needsReview
        if !highConfidence && reasons.isEmpty { reasons.insert(.minimumHistoryOnly) }
        let evidence = best.observations
            .sorted { lhs, rhs in
                if lhs.localDate != rhs.localDate { return lhs.localDate < rhs.localDate }
                return lhs.transaction.id.uuidString < rhs.transaction.id.uuidString
            }
            .map(\.evidence)
        let winningAnchor = try FinanceRecurringAnchor(
            date: best.anchorObservation.transaction.bookedAt,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
        let predicted = predictionIsSafe ? proposedPrediction : nil
        let candidate = try FinanceRecurringPaymentCandidate(
            key: key,
            supportingEvidence: evidence,
            detectedCadence: best.cadence,
            confidence: confidence,
            reasonCodes: reasons.sorted { $0.rawValue < $1.rawValue },
            anchor: winningAnchor,
            predictedDate: predicted,
            latestEligiblePaymentDate: latestEligiblePaymentDate,
            lastConsumedPeriodIndex: best.lastConsumedPeriodIndex
        )
        return candidate
    }

    private static func rank(lhs: CadenceScan, rhs: CadenceScan) -> Bool {
        if lhs.supportCount != rhs.supportCount { return lhs.supportCount > rhs.supportCount }
        if lhs.totalDateDeviation != rhs.totalDateDeviation {
            return lhs.totalDateDeviation < rhs.totalDateDeviation
        }
        if lhs.scheduleDrift != rhs.scheduleDrift {
            return !lhs.scheduleDrift
        }
        return cadenceOrder.firstIndex(of: lhs.cadence)! < cadenceOrder.firstIndex(of: rhs.cadence)!
    }

    private static func scan(
        cadence: FinanceRecurringCadence,
        observations: [PaymentObservation],
        calendar: Calendar
    ) throws -> CadenceScan? {
        guard !observations.isEmpty else { return nil }
        switch cadence {
        case .weekly:
            return try scanWeekly(observations: observations, calendar: calendar)
        case .monthly, .yearly:
            return try scanCalendarCadence(cadence, observations: observations, calendar: calendar)
        }
    }

    private static func scanWeekly(
        observations: [PaymentObservation],
        calendar: Calendar
    ) throws -> CadenceScan {
        let first = observations[0]
        var anchor = try FinanceRecurringAnchor(
            date: first.transaction.bookedAt,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
        var best = try makeWeeklyRun(
            observations: [first],
            periodIndices: [0],
            totalDateDeviation: 0,
            scheduleDrift: false
        )
        var run: [PaymentObservation] = [first]
        var periodIndices = [0]
        var totalDateDeviation = 0
        var scheduleDrift = false
        var lastPeriodIndex = 0
        for observation in observations.dropFirst() {
            try Task.checkCancellation()
            if let match = scheduleMatch(
                cadence: .weekly,
                anchor: anchor,
                date: observation.localDate,
                calendar: calendar
            ), match.periodIndex == lastPeriodIndex + 1 {
                run.append(observation)
                periodIndices.append(match.periodIndex)
                totalDateDeviation += match.deviation
                scheduleDrift = scheduleDrift || match.deviation > 1
                lastPeriodIndex = match.periodIndex
            } else {
                best = better(
                    best,
                    try makeWeeklyRun(
                        observations: run,
                        periodIndices: periodIndices,
                        totalDateDeviation: totalDateDeviation,
                        scheduleDrift: scheduleDrift
                    )
                )
                run = [observation]
                periodIndices = [0]
                totalDateDeviation = 0
                scheduleDrift = false
                lastPeriodIndex = 0
                anchor = try FinanceRecurringAnchor(
                    date: observation.transaction.bookedAt,
                    timeZoneIdentifier: calendar.timeZone.identifier
                )
            }
        }
        return better(
            best,
            try makeWeeklyRun(
                observations: run,
                periodIndices: periodIndices,
                totalDateDeviation: totalDateDeviation,
                scheduleDrift: scheduleDrift
            )
        )
    }

    private static func makeWeeklyRun(
        observations: [PaymentObservation],
        periodIndices: [Int],
        totalDateDeviation: Int,
        scheduleDrift: Bool
    ) throws -> CadenceScan {
        return CadenceScan(
            cadence: .weekly,
            anchorObservation: observations[0],
            observations: observations,
            representatives: observations,
            lastConsumedPeriodIndex: max(0, periodIndices.last ?? 0),
            supportCount: observations.count,
            totalDateDeviation: totalDateDeviation,
            amountConsistent: amountsAreConsistent(observations),
            ambiguous: false,
            scheduleDrift: scheduleDrift
        )
    }

    private static func scanCalendarCadence(
        _ cadence: FinanceRecurringCadence,
        observations: [PaymentObservation],
        calendar: Calendar
    ) throws -> CadenceScan {
        var best = try makeCalendarRun(
            cadence: cadence,
            observations: [observations[0]],
            representatives: [observations[0]],
            lastConsumedPeriodIndex: 0,
            totalDateDeviation: 0,
            ambiguous: false,
            scheduleDrift: false
        )
        var run: [PaymentObservation] = [observations[0]]
        var representatives: [PaymentObservation] = [observations[0]]
        var anchor = observations[0]
        var expectedPeriod = 1
        var lastConsumedPeriodIndex = 0
        var deviation = 0
        var ambiguous = false

        for observation in observations.dropFirst() {
            try Task.checkCancellation()
            let anchorValue = try FinanceRecurringAnchor(
                date: anchor.transaction.bookedAt,
                timeZoneIdentifier: calendar.timeZone.identifier
            )
            if let expected = scheduledDate(anchor: anchorValue, cadence: cadence, periodIndex: expectedPeriod, calendar: calendar),
               abs(dayDistance(expected, observation.localDate, calendar: calendar)) <= calendarToleranceDays {
                run.append(observation)
                representatives.append(observation)
                deviation += abs(dayDistance(expected, observation.localDate, calendar: calendar))
                lastConsumedPeriodIndex = expectedPeriod
                expectedPeriod += 1
                continue
            }

            if expectedPeriod > 0,
               let expected = scheduledDate(anchor: anchorValue, cadence: cadence, periodIndex: expectedPeriod - 1, calendar: calendar),
               abs(dayDistance(expected, observation.localDate, calendar: calendar)) <= calendarToleranceDays {
                run.append(observation)
                ambiguous = true
                continue
            }

            best = better(
                best,
                try makeCalendarRun(
                    cadence: cadence,
                    observations: run,
                    representatives: representatives,
                    lastConsumedPeriodIndex: lastConsumedPeriodIndex,
                    totalDateDeviation: deviation,
                    ambiguous: ambiguous,
                    scheduleDrift: false
                )
            )
            anchor = observation
            run = [observation]
            representatives = [observation]
            expectedPeriod = 1
            lastConsumedPeriodIndex = 0
            deviation = 0
            ambiguous = false
        }

        return better(
            best,
            try makeCalendarRun(
                cadence: cadence,
                observations: run,
                representatives: representatives,
                lastConsumedPeriodIndex: lastConsumedPeriodIndex,
                totalDateDeviation: deviation,
                ambiguous: ambiguous,
                scheduleDrift: false
            )
        )
    }

    private static func makeCalendarRun(
        cadence: FinanceRecurringCadence,
        observations: [PaymentObservation],
        representatives: [PaymentObservation],
        lastConsumedPeriodIndex: Int,
        totalDateDeviation: Int,
        ambiguous: Bool,
        scheduleDrift: Bool
    ) throws -> CadenceScan {
        CadenceScan(
            cadence: cadence,
            anchorObservation: observations[0],
            observations: observations,
            representatives: representatives,
            lastConsumedPeriodIndex: lastConsumedPeriodIndex,
            supportCount: representatives.count,
            totalDateDeviation: totalDateDeviation,
            amountConsistent: amountsAreConsistent(representatives),
            ambiguous: ambiguous,
            scheduleDrift: scheduleDrift
        )
    }

    private static func better(_ lhs: CadenceScan, _ rhs: CadenceScan) -> CadenceScan {
        rank(lhs: lhs, rhs: rhs) ? lhs : rhs
    }

    private static func amountsAreConsistent(_ observations: [PaymentObservation]) -> Bool {
        guard !observations.isEmpty else { return false }
        let amounts = observations.map(\.amountMagnitudeCents).sorted()
        let median = amounts[amounts.count / 2]
        let tolerance = max(100, Int((Double(median) * 0.05).rounded(.up)))
        return amounts.allSatisfy { abs($0 - median) <= tolerance }
    }

    private static func dayDistance(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: lhs), to: calendar.startOfDay(for: rhs)).day ?? 0
    }

    private static func scheduleMatch(
        cadence: FinanceRecurringCadence,
        anchor: FinanceRecurringAnchor,
        date: Date,
        calendar: Calendar
    ) -> (periodIndex: Int, deviation: Int)? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let anchorComponents = calendar.dateComponents([.year, .month], from: anchor.date)
        let dateComponents = calendar.dateComponents([.year, .month], from: date)
        guard let anchorYear = anchorComponents.year,
              let anchorMonth = anchorComponents.month,
              let dateYear = dateComponents.year,
              let dateMonth = dateComponents.month else {
            return nil
        }

        let estimate: Int
        switch cadence {
        case .weekly:
            let days = dayDistance(anchor.date, date, calendar: calendar)
            guard days >= -calendarToleranceDays else { return nil }
            estimate = max(0, Int((Double(days) / 7.0).rounded()))
        case .monthly:
            estimate = max(0, (dateYear - anchorYear) * 12 + dateMonth - anchorMonth)
        case .yearly:
            estimate = max(0, dateYear - anchorYear)
        }

        let lowerBound = max(0, estimate - 1)
        let upperBound = estimate + 1
        var best: (periodIndex: Int, deviation: Int)?
        for periodIndex in lowerBound...upperBound {
            guard let expected = scheduledDate(
                anchor: anchor,
                cadence: cadence,
                periodIndex: periodIndex,
                calendar: calendar
            ) else { continue }
            let deviation = abs(dayDistance(expected, date, calendar: calendar))
            guard deviation <= calendarToleranceDays else { continue }
            if let current = best,
               current.deviation < deviation
                || (current.deviation == deviation && current.periodIndex <= periodIndex) {
                continue
            }
            best = (periodIndex, deviation)
        }
        return best
    }

    private static func scheduledDate(
        anchor: FinanceRecurringAnchor,
        cadence: FinanceRecurringCadence,
        periodIndex: Int,
        calendar: Calendar
    ) -> Date? {
        guard periodIndex >= 0 else { return nil }
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: anchor.date)
        guard let baseYear = components.year,
              let baseMonth = components.month,
              let baseDay = components.day else { return nil }

        switch cadence {
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: periodIndex, to: anchor.date)
        case .monthly:
            guard let monthStart = calendar.date(from: DateComponents(year: baseYear, month: baseMonth, day: 1)),
                  let targetMonth = calendar.date(byAdding: .month, value: periodIndex, to: monthStart) else {
                return nil
            }
            let target = calendar.dateComponents([.year, .month], from: targetMonth)
            guard let targetYear = target.year, let targetMonthValue = target.month,
                  let range = calendar.range(of: .day, in: .month, for: targetMonth) else { return nil }
            return calendar.date(from: DateComponents(
                year: targetYear,
                month: targetMonthValue,
                day: min(baseDay, range.count),
                hour: components.hour,
                minute: components.minute,
                second: components.second
            ))
        case .yearly:
            let targetYear = baseYear + periodIndex
            guard let yearStart = calendar.date(from: DateComponents(year: targetYear, month: baseMonth, day: 1)),
                  let range = calendar.range(of: .day, in: .month, for: yearStart) else { return nil }
            return calendar.date(from: DateComponents(
                year: targetYear,
                month: baseMonth,
                day: min(baseDay, range.count),
                hour: components.hour,
                minute: components.minute,
                second: components.second
            ))
        }
    }
}
