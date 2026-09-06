import Foundation

// MARK: - Automatic income-sorting rules and deterministic allocation preview

/// How one allocation rule claims its share of an income amount. Percentages
/// are whole percent (1...100) rather than `Double` — money and money-shaped
/// inputs are never floating point anywhere in LifeOS Finance. Fixed amounts
/// are positive integer cents, validated against the specific income amount
/// at preview time (the store cannot know the income in advance).
public enum FinanceAllocationShare: Codable, Equatable, Sendable {
    case percentage(Int)
    case fixedCents(Int)

    private enum CodingKeys: String, CodingKey {
        case kind, percentage, fixedCents
    }

    private enum Kind: String, Codable {
        case percentage, fixedCents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .percentage:
            self = .percentage(try container.decode(Int.self, forKey: .percentage))
        case .fixedCents:
            self = .fixedCents(try container.decode(Int.self, forKey: .fixedCents))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .percentage(let value):
            try container.encode(Kind.percentage, forKey: .kind)
            try container.encode(value, forKey: .percentage)
        case .fixedCents(let value):
            try container.encode(Kind.fixedCents, forKey: .kind)
            try container.encode(value, forKey: .fixedCents)
        }
    }

    /// `true` when the value itself is in a legal range, independent of any
    /// other rule in the set. Cross-rule checks (percentage total, fixed
    /// total vs. a specific income) are the caller's responsibility.
    var isIndividuallyValid: Bool {
        switch self {
        case .percentage(let value):
            return value >= 1 && value <= 100
        case .fixedCents(let value):
            return value > 0 && value <= FinanceBudgetAmountParser.maximumCents
        }
    }
}

/// A single user-defined income allocation rule: incoming money matching
/// this rule is automatically sorted into `bucket`. Rules form an ordered,
/// user-managed list; `FinanceAllocationEngine.preview` treats their
/// position in that list (their "rule order") as the documented, stable
/// tie-break for splitting remainder cents.
public struct FinanceAllocationRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var label: String
    public var bucket: String
    public var share: FinanceAllocationShare
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        bucket: String,
        share: FinanceAllocationShare,
        createdAt: Date = .now
    ) {
        self.id = id
        self.label = label
        self.bucket = bucket
        self.share = share
        self.createdAt = createdAt
    }

    var hasNonEmptyText: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The exact per-bucket split of one income amount. Always present alongside
/// `.allocated` — never fabricated when a rule set is empty (see
/// `FinanceAllocationPreviewResult.noAllocationConfigured`).
public struct FinanceAllocationPreview: Equatable, Sendable {
    public struct LineItem: Equatable, Identifiable, Sendable {
        public let ruleID: UUID
        public let label: String
        public let bucket: String
        public let amountCents: Int
        public var id: UUID { ruleID }
    }

    public let incomeCents: Int
    /// One line item per rule, in rule order. Every fixed-share rule's
    /// amount equals its configured cents exactly; every percentage-share
    /// rule's amount is the largest-remainder-distributed share of the
    /// income left over after fixed rules are honored.
    public let lineItems: [LineItem]
    /// Cents not claimed by any rule: either because percentage rules do not
    /// sum to 100%, or because integer division left a residual that
    /// belongs to no single rule. Never silently dropped or invented —
    /// always accounted for so `sum(lineItems) + unallocatedCents ==
    /// incomeCents` exactly.
    public let unallocatedCents: Int
}

/// The outcome of previewing an allocation. An empty rule set is an honest
/// "nothing configured" result, never presented as a zero-valued split.
public enum FinanceAllocationPreviewResult: Equatable, Sendable {
    case noAllocationConfigured
    case invalidIncome
    case fixedAmountsExceedIncome
    case allocated(FinanceAllocationPreview)
}

/// Cross-rule validation performed whenever a rule set changes (create,
/// update, delete). Independent of any specific income amount — the
/// percentage budget is a property of the rule set alone.
public enum FinanceAllocationRuleSetError: Error, Equatable, Sendable {
    case invalidLabel
    case invalidBucket
    case invalidShare
    case percentageTotalExceeds100
}

/// Pure, store-independent allocation logic. Deterministic: the same rule
/// set and income always produce the same preview, with no reliance on
/// wall-clock time, randomness, or dictionary/set ordering.
public enum FinanceAllocationEngine {
    /// Validates one rule set as a whole (used both for a brand-new set and
    /// for a set with one rule replaced/added/removed). Order of `rules`
    /// does not affect validity — only content does.
    public static func validate(_ rules: [FinanceAllocationRule]) -> FinanceAllocationRuleSetError? {
        for rule in rules {
            guard rule.hasNonEmptyText else {
                return rule.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .invalidLabel
                    : .invalidBucket
            }
            guard rule.share.isIndividuallyValid else { return .invalidShare }
        }
        let percentageTotal = rules.reduce(into: 0) { total, rule in
            if case .percentage(let value) = rule.share { total += value }
        }
        guard percentageTotal <= 100 else { return .percentageTotalExceeds100 }
        return nil
    }

    /// Produces the exact per-bucket split of `incomeCents` given `rules`,
    /// in rule order (the order of the `rules` array, which is the
    /// documented tie-break precedence — earlier rules win remainder cents
    /// before later ones; a UUID comparison breaks any remaining tie).
    ///
    /// Remainder rule (largest-remainder / Hare-quota method), applied only
    /// to the percentage-share rules over whatever income remains after
    /// fixed-share rules are honored:
    /// 1. Fixed-share rules are subtracted first, each claiming exactly its
    ///    configured cents. If their total exceeds `incomeCents`, the whole
    ///    preview is refused (`.fixedAmountsExceedIncome`) rather than
    ///    silently truncating anyone's fixed amount.
    /// 2. For the remaining amount `R` and each percentage rule's whole
    ///    percent `p`, compute the exact integer product `p * R` (no
    ///    floating point). Its floor-divided-by-100 value is that rule's
    ///    baseline share; the `p * R mod 100` remainder records how close
    ///    that rule came to the next whole cent.
    /// 3. The target total owed to percentage rules is
    ///    `floor(R * sumOfPercentages / 100)` — the exact, undistorted
    ///    fraction of `R` that `sumOfPercentages`% represents, floored so no
    ///    cent is invented. The gap between that target and the sum of
    ///    baseline shares (always a small non-negative integer, bounded by
    ///    the rule count) is distributed one cent at a time to the rules
    ///    with the largest remainder from step 2, ties broken by earliest
    ///    rule order and then by ascending `id` — a total order, so the
    ///    result never depends on array/dictionary iteration order.
    /// 4. Anything not claimed by a fixed or percentage rule — because
    ///    percentages under-total 100%, or because of the floor in step 3 —
    ///    is reported as `unallocatedCents`, never dropped or fabricated.
    ///
    /// This guarantees `sum(lineItems.amountCents) + unallocatedCents ==
    /// incomeCents` exactly, for any valid input, every time.
    public static func preview(rules: [FinanceAllocationRule], incomeCents: Int) -> FinanceAllocationPreviewResult {
        guard incomeCents > 0 else { return .invalidIncome }
        guard !rules.isEmpty else { return .noAllocationConfigured }

        var fixedTotal = 0
        for rule in rules {
            if case .fixedCents(let cents) = rule.share {
                fixedTotal += cents
            }
        }
        guard fixedTotal <= incomeCents else { return .fixedAmountsExceedIncome }

        let remaining = incomeCents - fixedTotal
        let percentageIndexed: [(index: Int, rule: FinanceAllocationRule, percent: Int)] = rules.enumerated().compactMap { index, rule in
            guard case .percentage(let percent) = rule.share else { return nil }
            return (index, rule, percent)
        }

        var baselineCents = [Int](repeating: 0, count: percentageIndexed.count)
        var remainders = [Int](repeating: 0, count: percentageIndexed.count)
        var sumPercent = 0
        var sumBaseline = 0
        for (position, entry) in percentageIndexed.enumerated() {
            let product = remaining * entry.percent
            baselineCents[position] = product / 100
            remainders[position] = product % 100
            sumPercent += entry.percent
            sumBaseline += baselineCents[position]
        }

        let target = (remaining * sumPercent) / 100
        var leftoverCentsToDistribute = target - sumBaseline

        let distributionOrder = percentageIndexed.indices.sorted { lhs, rhs in
            if remainders[lhs] != remainders[rhs] { return remainders[lhs] > remainders[rhs] }
            if percentageIndexed[lhs].index != percentageIndexed[rhs].index {
                return percentageIndexed[lhs].index < percentageIndexed[rhs].index
            }
            return percentageIndexed[lhs].rule.id.uuidString < percentageIndexed[rhs].rule.id.uuidString
        }

        var finalCents = baselineCents
        for position in distributionOrder {
            guard leftoverCentsToDistribute > 0 else { break }
            finalCents[position] += 1
            leftoverCentsToDistribute -= 1
        }

        var amountByRuleID: [UUID: Int] = [:]
        // Populate fixed-share amounts.
        for rule in rules {
            if case .fixedCents(let cents) = rule.share {
                amountByRuleID[rule.id] = cents
            }
        }
        // Populate percentage-share amounts using the distributed result.
        for (position, entry) in percentageIndexed.enumerated() {
            amountByRuleID[entry.rule.id] = finalCents[position]
        }

        let lineItems = rules.map { rule in
            FinanceAllocationPreview.LineItem(
                ruleID: rule.id,
                label: rule.label,
                bucket: rule.bucket,
                amountCents: amountByRuleID[rule.id] ?? 0
            )
        }
        let allocatedTotal = lineItems.reduce(0) { $0 + $1.amountCents }
        let unallocated = incomeCents - allocatedTotal

        return .allocated(FinanceAllocationPreview(
            incomeCents: incomeCents,
            lineItems: lineItems,
            unallocatedCents: unallocated
        ))
    }
}
