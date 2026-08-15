import Foundation

// MARK: - Per-category spend summary

/// Aggregate spend/income for a single category, as computed by
/// `FinanceCategorizer.summary(for:)`. Money is always integer EUR cents.
public struct FinanceCategorySpend: Equatable, Hashable, Sendable {
    public let category: FinanceTransactionCategory
    /// Sum of outflow cents in this category, as a positive magnitude
    /// (i.e. `abs` of the negative transaction amounts). Zero if the
    /// category has no outflow transactions.
    public let outflowCents: Int
    /// Sum of inflow cents in this category, positive. Zero if the category
    /// has no inflow transactions.
    public let inflowCents: Int
    /// Number of transactions contributing to this category (outflow + inflow).
    public let count: Int

    public init(category: FinanceTransactionCategory, outflowCents: Int, inflowCents: Int, count: Int) {
        self.category = category
        self.outflowCents = outflowCents
        self.inflowCents = inflowCents
        self.count = count
    }

    /// Net cents for this category: inflow minus outflow.
    public var netCents: Int { inflowCents - outflowCents }
}

/// Overall totals across every transaction handed to
/// `FinanceCategorizer.summary(for:)`, independent of category.
public struct FinanceSpendTotals: Equatable, Hashable, Sendable {
    public let outflowCents: Int
    public let inflowCents: Int
    public let transactionCount: Int

    public init(outflowCents: Int, inflowCents: Int, transactionCount: Int) {
        self.outflowCents = outflowCents
        self.inflowCents = inflowCents
        self.transactionCount = transactionCount
    }

    public var netCents: Int { inflowCents - outflowCents }
}

// MARK: - Keyword-based categorizer

/// A pure, stateless categorizer for `FinanceImportedTransaction` rows.
/// Categorization is always computed on the fly from a small keyword
/// ruleset — nothing is persisted, and an unmatched description is left
/// `.uncategorized` rather than guessed. This mirrors the "honest empty"
/// principle used across LifeOS: no fabricated category is ever better
/// than an admitted "we don't know."
public enum FinanceCategorizer {
    /// One ruleset entry: a target category plus the case-insensitive
    /// substrings that, if found in a transaction's description, match it.
    /// Kept as a small, readable, append-only table — extending the
    /// ruleset (or making it user-editable) is deferred, not designed away.
    private struct Rule {
        let category: FinanceTransactionCategory
        let keywords: [String]
        /// If non-nil, the rule only matches transactions whose direction
        /// agrees (`true` = inflow only, `false` = outflow only). `nil`
        /// matches either direction.
        let requiresInflow: Bool?
    }

    private static let rules: [Rule] = [
        // Income — matched first since salary/refund keywords should win
        // over any coincidental merchant-style overlap.
        Rule(category: .income, keywords: [
            "gehalt", "lohn", "salary", "payroll", "rente", "pension",
            "erstattung", "refund", "reimbursement"
        ], requiresInflow: true),

        // Groceries — DE + EN supermarket chains.
        Rule(category: .groceries, keywords: [
            "rewe", "aldi", "lidl", "edeka", "kaufland", "penny", "netto",
            "denns", "alnatura", "supermarkt", "grocery", "whole foods",
            "trader joe"
        ], requiresInflow: nil),

        // Dining — restaurants, cafes, delivery.
        Rule(category: .dining, keywords: [
            "restaurant", "cafe", "café", "bäckerei", "baeckerei", "bakery",
            "lieferando", "uber eats", "ubereats", "wolt", "mcdonald",
            "burger king", "starbucks", "kfc", "dominos", "domino's",
            "imbiss", "bistro", "pizzeria"
        ], requiresInflow: nil),

        // Transport — ride-hail, transit, rail, fuel.
        Rule(category: .transport, keywords: [
            "uber", "bolt", "free now", "freenow", "db ", "deutsche bahn",
            "bvg", "mvg", "vvo", "rmv", "hvv", "flixbus", "flixtrain",
            "ryanair", "lufthansa", "eurowings", "tankstelle", "shell",
            "aral", "esso", "sixt", "parkhaus", "parking"
        ], requiresInflow: nil),

        // Shopping — general retail / e-commerce.
        Rule(category: .shopping, keywords: [
            "amazon", "zalando", "otto.de", "ikea", "mediamarkt",
            "saturn", "h&m", "zara", "decathlon", "dm-drogerie", "rossmann",
            "müller", "mueller", "ebay", "shein", "temu"
        ], requiresInflow: nil),

        // Bills — utilities, rent, insurance, telecom.
        Rule(category: .bills, keywords: [
            "miete", "rent", "stromrechnung", "electricity", "stadtwerke",
            "vodafone", "telekom", "o2", "1&1", "versicherung", "insurance",
            "internet", "wasser", "heizung", "gez", "rundfunkbeitrag"
        ], requiresInflow: nil),

        // Subscriptions — recurring media/software.
        Rule(category: .subscriptions, keywords: [
            "netflix", "spotify", "disney+", "disney plus", "amazon prime",
            "apple.com/bill", "youtube premium", "icloud", "google one",
            "adobe", "audible", "dazn", "paramount+"
        ], requiresInflow: nil),

        // Cash — ATM withdrawals.
        Rule(category: .cash, keywords: [
            "geldautomat", "atm", "bargeldauszahlung", "cash withdrawal"
        ], requiresInflow: nil)
    ]

    /// Categorizes a single transaction description using the default
    /// keyword ruleset. Matching is case-insensitive substring matching
    /// against `description`; direction (`amountCents` sign) is honored
    /// where a rule requires it (e.g. income rules only match inflows).
    /// Returns `.uncategorized` when nothing matches — never a guess.
    public static func category(for description: String, amountCents: Int) -> FinanceTransactionCategory {
        let normalized = description.lowercased()
        guard !normalized.isEmpty else { return .uncategorized }
        let isInflow = amountCents > 0

        for rule in rules {
            if let requiresInflow = rule.requiresInflow, requiresInflow != isInflow {
                continue
            }
            if rule.keywords.contains(where: { normalized.contains($0) }) {
                return rule.category
            }
        }
        return .uncategorized
    }

    /// Builds a per-category spend/income summary over the given
    /// transactions, sorted by absolute total spend (outflow + inflow
    /// magnitude) descending. Empty input returns an empty summary — no
    /// placeholder rows are fabricated.
    public static func summary(for transactions: [FinanceImportedTransaction]) -> [FinanceCategorySpend] {
        guard !transactions.isEmpty else { return [] }

        var outflowByCategory: [FinanceTransactionCategory: Int] = [:]
        var inflowByCategory: [FinanceTransactionCategory: Int] = [:]
        var countByCategory: [FinanceTransactionCategory: Int] = [:]

        for transaction in transactions {
            let category = category(for: transaction.description, amountCents: transaction.amountCents)
            countByCategory[category, default: 0] += 1
            if transaction.amountCents < 0 {
                outflowByCategory[category, default: 0] += -transaction.amountCents
            } else if transaction.amountCents > 0 {
                inflowByCategory[category, default: 0] += transaction.amountCents
            }
        }

        let categories = Set(outflowByCategory.keys).union(inflowByCategory.keys).union(countByCategory.keys)
        return categories
            .map { category in
                FinanceCategorySpend(
                    category: category,
                    outflowCents: outflowByCategory[category] ?? 0,
                    inflowCents: inflowByCategory[category] ?? 0,
                    count: countByCategory[category] ?? 0
                )
            }
            .sorted { lhs, rhs in
                let lhsMagnitude = lhs.outflowCents + lhs.inflowCents
                let rhsMagnitude = rhs.outflowCents + rhs.inflowCents
                if lhsMagnitude != rhsMagnitude { return lhsMagnitude > rhsMagnitude }
                return lhs.category.displayName < rhs.category.displayName
            }
    }

    /// Overall in/out/net totals across the given transactions, independent
    /// of category. Empty input returns zeroed totals with `transactionCount == 0`.
    public static func totals(for transactions: [FinanceImportedTransaction]) -> FinanceSpendTotals {
        var outflow = 0
        var inflow = 0
        for transaction in transactions {
            if transaction.amountCents < 0 {
                outflow += -transaction.amountCents
            } else if transaction.amountCents > 0 {
                inflow += transaction.amountCents
            }
        }
        return FinanceSpendTotals(outflowCents: outflow, inflowCents: inflow, transactionCount: transactions.count)
    }
}
