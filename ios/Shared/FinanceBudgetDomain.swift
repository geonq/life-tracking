import Foundation

// MARK: - Durable, user-set monthly category budget

/// A single dated monthly spending limit for one `FinanceTransactionCategory`.
/// Budgets form a dated history rather than a single mutable record, mirroring
/// `NutritionGoal`: `FinanceBudgetStore.setBudget` always appends a new entry
/// per category, and `currentBudgets(on:)` resolves "the budget in effect" as
/// the latest per-category entry whose `effectiveFrom` is on or before the
/// requested day. This makes past months answerable against the limit that
/// was actually active then, rather than silently rewriting history when the
/// user changes a limit.
///
/// Only ordinary spend categories can carry a budget. Income, transfers, and
/// investment orders are not ordinary spend and are rejected by
/// `FinanceBudgetStore.setBudget` — treating them as household budget actuals
/// would be a fabricated concept.
public struct FinanceCategoryBudget: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let category: FinanceTransactionCategory
    /// The monthly spending limit, in positive integer EUR cents. Never a
    /// float — money is always integer cents throughout LifeOS Finance.
    public let monthlyLimitCents: Int
    /// The calendar day (and time) this limit takes effect from.
    public let effectiveFrom: Date
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        category: FinanceTransactionCategory,
        monthlyLimitCents: Int,
        effectiveFrom: Date,
        createdAt: Date = .now
    ) {
        self.id = id
        self.category = category
        self.monthlyLimitCents = monthlyLimitCents
        self.effectiveFrom = effectiveFrom
        self.createdAt = createdAt
    }
}

/// Parses the small amount editor used by Finance into positive EUR cents.
/// Keeping this conversion in the shared domain prevents the SwiftUI editor
/// and persistence boundary from disagreeing about decimal commas, precision,
/// or zero-valued limits.
public enum FinanceBudgetAmountParser {
    /// Matches the integer-money bound used by the Finance payload contract.
    public static let maximumCents = 9_007_199_254_740_991

    public static func cents(from rawValue: String) -> Int? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !value.isEmpty else { return nil }
        if value.first == "+" {
            value.removeFirst()
        }
        guard !value.isEmpty, !value.contains("-") else { return nil }

        let hasComma = value.contains(",")
        let hasDot = value.contains(".")
        let decimalSeparator: Character?
        let groupingSeparator: Character?
        if hasComma && hasDot {
            guard let comma = value.lastIndex(of: ","), let dot = value.lastIndex(of: ".") else {
                return nil
            }
            decimalSeparator = comma > dot ? "," : "."
            groupingSeparator = comma > dot ? "." : ","
        } else if hasComma {
            decimalSeparator = ","
            groupingSeparator = nil
        } else if hasDot {
            decimalSeparator = "."
            groupingSeparator = nil
        } else {
            decimalSeparator = nil
            groupingSeparator = nil
        }

        if let groupingSeparator {
            value = value.replacingOccurrences(of: String(groupingSeparator), with: "")
        }
        let components = decimalSeparator.map {
            value.split(separator: $0, omittingEmptySubsequences: false).map(String.init)
        } ?? [value]
        guard components.count <= 2,
              let euros = components.first,
              !euros.isEmpty,
              euros.allSatisfy(\.isNumber) else {
            return nil
        }
        let fraction: String
        if components.count == 2 {
            guard let fractional = components.last,
                  fractional.count == 1 || fractional.count == 2,
                  fractional.allSatisfy(\.isNumber) else {
                return nil
            }
            fraction = fractional.count == 1 ? fractional + "0" : fractional
        } else {
            fraction = "00"
        }
        guard let wholeCents = Int(euros),
              let fractionalCents = Int(fraction) else {
            return nil
        }
        let (scaledEuros, eurosOverflow) = wholeCents.multipliedReportingOverflow(by: 100)
        guard !eurosOverflow else { return nil }
        let (cents, centsOverflow) = scaledEuros.addingReportingOverflow(fractionalCents)
        guard !centsOverflow, cents > 0, cents <= maximumCents else { return nil }
        return cents
    }

    public static func inputText(for cents: Int) -> String {
        guard cents > 0 else { return "" }
        let euros = cents / 100
        let remainder = cents % 100
        guard remainder != 0 else { return String(euros) }
        let fraction = remainder < 10 ? "0\(remainder)" : String(remainder)
        return "\(euros).\(fraction)"
    }
}

/// Categories a budget can legitimately be set against. Income, transfers,
/// and investment orders are excluded here rather than merely discouraged at
/// the call site — a single source of truth for "spendable."
public extension FinanceTransactionCategory {
    static var budgetableCategories: [FinanceTransactionCategory] {
        allCases.filter { $0.isBudgetable }
    }

    var isBudgetable: Bool {
        self != .income && self != .transfers && self != .investments
    }
}
