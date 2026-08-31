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

public enum FinanceCategoryResolutionSource: String, Codable, Equatable, Sendable {
    case userOverride
    case provider
    case providerCode
    case heuristic
    case investmentSource
    case uncategorized
}

public struct FinanceCategoryResolution: Equatable, Sendable {
    public let category: FinanceTransactionCategory
    public let source: FinanceCategoryResolutionSource

    public init(category: FinanceTransactionCategory, source: FinanceCategoryResolutionSource) {
        self.category = category
        self.source = source
    }
}

// MARK: - Keyword-based categorizer

/// A pure categorizer for `FinanceImportedTransaction` rows. When a saved
/// source or user override exists it is honored; otherwise a small keyword
/// ruleset assigns a category on the fly. An unmatched description is left
/// `.uncategorized` rather than guessed.
public enum FinanceCategorizer {
    /// One ruleset entry: a target category plus the case-insensitive
    /// substrings that, if found in a transaction's description, match it.
    /// Kept as a small, readable, append-only table. User corrections live on
    /// the imported transaction and do not mutate this global ruleset.
    private struct Rule {
        let category: FinanceTransactionCategory
        let keywords: [String]
        /// If non-nil, the rule only matches transactions whose direction
        /// agrees (`true` = inflow only, `false` = outflow only). `nil`
        /// matches either direction.
        let requiresInflow: Bool?
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
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

        // Transfers must be checked before the short `uber` ride-hail token:
        // folded German "Überweisung" otherwise contains that substring.
        Rule(category: .transfers, keywords: [
            "überweisung", "ueberweisung", "bank transfer", "sepa transfer"
        ], requiresInflow: nil),

        // Transport — ride-hail, transit, rail, fuel.
        Rule(category: .transport, keywords: [
            "uber", "bolt", "free now", "freenow", "db ", "deutsche bahn",
            "bvg", "mvg", "vvo", "rmv", "hvv", "flixbus", "flixtrain",
            "ryanair", "lufthansa", "eurowings", "tankstelle", "shell",
            "aral", "esso", "sixt", "parkhaus", "parking"
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

        // Shopping — general retail / e-commerce. Kept after subscriptions so
        // the broad `amazon` token cannot swallow `amazon prime`.
        Rule(category: .shopping, keywords: [
            "amazon", "zalando", "otto.de", "ikea", "mediamarkt",
            "saturn", "h&m", "zara", "decathlon", "dm-drogerie", "rossmann",
            "müller", "mueller", "ebay", "shein", "temu"
        ], requiresInflow: nil),

        // Health — providers that do not supply a usable category.
        Rule(category: .health, keywords: [
            "apotheke", "pharmacy", "arzt", "doctor", "medical", "gesundheit",
            "krankenhaus", "hospital", "zahnarzt", "dentist"
        ], requiresInflow: nil),

        // Travel — hotels, booking providers, and airports.
        Rule(category: .travel, keywords: [
            "booking.com", "airbnb", "hotel", "expedia", "travel", "reise",
            "airport", "flughafen", "airline"
        ], requiresInflow: nil),

        // Fees and taxes are kept separate from generic bills.
        Rule(category: .fees, keywords: [
            "gebühr", "gebuehr", "bank fee", "service fee", "commission", "entgelt",
            "overdraft", "kontoführung", "kontofuehrung"
        ], requiresInflow: nil),
        Rule(category: .taxes, keywords: [
            "finanzamt", "steuer", "tax payment", "taxes"
        ], requiresInflow: nil),

        // Investments and transfers should not inflate ordinary shopping or
        // income totals when a statement names them explicitly.
        Rule(category: .investments, keywords: [
            "trade republic", "scalable capital", "broker", "depot", "aktien", "etf",
            "securities", "investment"
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
    public static func category(
        for description: String,
        amountCents: Int,
        sourceCategory: String? = nil,
        providerCode: String? = nil
    ) -> FinanceTransactionCategory {
        let isInflow = amountCents > 0

        // A recognized category explicitly supplied by the bank/CSV wins over
        // merchant heuristics. Income remains direction-aware so a provider
        // mistake cannot turn an outgoing payment into salary.
        if let supplied = FinanceTransactionCategory.from(sourceCategory: sourceCategory),
           supplied != .income || isInflow {
            return supplied
        }
        if let coded = FinanceTransactionCategory.from(providerCode: providerCode) {
            return coded
        }
        let normalized = normalized(description)
        guard !normalized.isEmpty else { return .uncategorized }

        for rule in rules {
            if let requiresInflow = rule.requiresInflow, requiresInflow != isInflow {
                continue
            }
            if rule.keywords.contains(where: { normalized.contains(Self.normalized($0)) }) {
                return rule.category
            }
        }
        return .uncategorized
    }

    /// Resolves a persisted import row with an explicit precedence contract.
    /// Category precedence is explicit: user override, trusted provider
    /// category, provider code, structural investment marker, deterministic
    /// merchant heuristic, then honest unknown. Investment orders remain
    /// excluded from budget actuals even when a user labels the row for a
    /// different display category.
    public static func resolve(transaction: FinanceImportedTransaction) -> FinanceCategoryResolution {
        if let override = FinanceTransactionCategory.from(sourceCategory: transaction.category) {
            return FinanceCategoryResolution(category: override, source: .userOverride)
        }
        if let provider = FinanceTransactionCategory.from(sourceCategory: transaction.sourceCategory),
           provider != .income || transaction.amountCents > 0 {
            return FinanceCategoryResolution(category: provider, source: .provider)
        }
        if let providerCode = FinanceTransactionCategory.from(providerCode: transaction.providerCode) {
            return FinanceCategoryResolution(category: providerCode, source: .providerCode)
        }
        if transaction.isInvestmentOrder {
            return FinanceCategoryResolution(category: .investments, source: .investmentSource)
        }
        let heuristic = category(for: transaction.description, amountCents: transaction.amountCents)
        return FinanceCategoryResolution(
            category: heuristic,
            source: heuristic == .uncategorized ? .uncategorized : .heuristic
        )
    }

    public static func category(for transaction: FinanceImportedTransaction) -> FinanceTransactionCategory {
        resolve(transaction: transaction).category
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
            let category = category(for: transaction)
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

    /// Budget actuals are derived only from locally imported rows and only
    /// from ordinary spend categories. Investment orders, transfers, income,
    /// and other non-budgetable categories are excluded; no live bank summary
    /// is used to manufacture a budget actual.
    public static func isBudgetEligible(_ transaction: FinanceImportedTransaction) -> Bool {
        !transaction.isInvestmentOrder && category(for: transaction).isBudgetable
    }

    public static func budgetSummary(for transactions: [FinanceImportedTransaction]) -> [FinanceCategorySpend] {
        summary(for: transactions.filter(isBudgetEligible))
    }
}
