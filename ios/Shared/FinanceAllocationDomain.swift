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
    /// `rules` failed `FinanceAllocationEngine.validate` — `preview` refuses
    /// to compute a split for an unvalidated rule set rather than fail open
    /// with an unbounded or otherwise nonsensical result. This is the case a
    /// UI previewing a candidate rule set before saving is expected to hold
    /// exactly (an array it has not yet validated), so this path must be
    /// exercised, not just the store's own pre-save validation.
    case invalidRuleSet(FinanceAllocationRuleSetError)
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
    /// Two or more rules share the same `id`. Rejected here rather than
    /// merely by convention: `preview` indexes rules positionally (not by
    /// `id`), and a corrupt or hand-edited file could otherwise smuggle
    /// duplicate ids past everything except this check.
    case duplicateRuleID
}

/// Pure, store-independent allocation logic. Deterministic: the same rule
/// set and income always produce the same preview, with no reliance on
/// wall-clock time, randomness, or dictionary/set ordering.
public enum FinanceAllocationEngine {
    /// Validates one rule set as a whole (used both for a brand-new set and
    /// for a set with one rule replaced/added/removed). Order of `rules`
    /// does not affect validity — only content does.
    public static func validate(_ rules: [FinanceAllocationRule]) -> FinanceAllocationRuleSetError? {
        var seenIDs = Set<UUID>()
        for rule in rules {
            guard seenIDs.insert(rule.id).inserted else { return .duplicateRuleID }
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
    /// before later ones).
    ///
    /// `rules` is validated via `FinanceAllocationEngine.validate` as the
    /// very first step, before any arithmetic — the natural caller here is a
    /// UI previewing a candidate rule set before it has been saved (and
    /// therefore before the store's own pre-save validation has ever run
    /// against it), so this function cannot assume its input is already
    /// valid. An invalid rule set is refused via `.invalidRuleSet` rather
    /// than silently producing an out-of-range or negative split.
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
    ///    rule order — every percentage rule has a distinct position in
    ///    `rules`, so that alone is already a total order and no further
    ///    tie-break (e.g. by `id`) is reachable.
    /// 4. Anything not claimed by a fixed or percentage rule — because
    ///    percentages under-total 100%, or because of the floor in step 3 —
    ///    is reported as `unallocatedCents`, never dropped or fabricated.
    ///
    /// This guarantees `sum(lineItems.amountCents) + unallocatedCents ==
    /// incomeCents` exactly, for every input this function actually accepts
    /// (i.e. every input that reaches `.allocated` rather than one of the
    /// refusal cases above) — every time.
    public static func preview(rules: [FinanceAllocationRule], incomeCents: Int) -> FinanceAllocationPreviewResult {
        guard incomeCents > 0, incomeCents <= FinanceBudgetAmountParser.maximumCents else { return .invalidIncome }
        guard !rules.isEmpty else { return .noAllocationConfigured }
        if let ruleSetError = validate(rules) { return .invalidRuleSet(ruleSetError) }

        var fixedTotal = 0
        for rule in rules {
            if case .fixedCents(let cents) = rule.share {
                let (sum, overflowed) = fixedTotal.addingReportingOverflow(cents)
                guard !overflowed, sum <= incomeCents else { return .fixedAmountsExceedIncome }
                fixedTotal = sum
            }
        }

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
            // `index` is each rule's position in `rules`, which is unique
            // per percentage rule by construction (`enumerated()` above) —
            // this is already a total order, so no further tie-break is
            // reachable.
            return percentageIndexed[lhs].index < percentageIndexed[rhs].index
        }

        var finalCents = baselineCents
        for position in distributionOrder {
            guard leftoverCentsToDistribute > 0 else { break }
            finalCents[position] += 1
            leftoverCentsToDistribute -= 1
        }

        // Built positionally over `rules`, never keyed by `id` — a rule set
        // could otherwise contain (or, pre-`validate`, previously did
        // contain) two rules sharing a UUID, which would collapse into one
        // entry in a dictionary keyed by `id` and silently misreport both
        // rules' amounts. `rules.count`-many distinct array slots cannot
        // collide this way.
        var finalAmounts = [Int](repeating: 0, count: rules.count)
        for (index, rule) in rules.enumerated() {
            if case .fixedCents(let cents) = rule.share {
                finalAmounts[index] = cents
            }
        }
        for (position, entry) in percentageIndexed.enumerated() {
            finalAmounts[entry.index] = finalCents[position]
        }

        let lineItems = rules.enumerated().map { index, rule in
            FinanceAllocationPreview.LineItem(
                ruleID: rule.id,
                label: rule.label,
                bucket: rule.bucket,
                amountCents: finalAmounts[index]
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
