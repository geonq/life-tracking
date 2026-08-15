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
/// Only spendable categories can carry a budget. `.income` is not a spending
/// category and is rejected by `FinanceBudgetStore.setBudget` — budgeting
/// income makes no sense in this model and would be a fabricated concept.
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

/// Categories a budget can legitimately be set against. `.income` is not a
/// spending category, so it is excluded here rather than merely discouraged
/// at the call site — a single source of truth for "spendable."
public extension FinanceTransactionCategory {
    static var budgetableCategories: [FinanceTransactionCategory] {
        allCases.filter { $0 != .income }
    }

    var isBudgetable: Bool { self != .income }
}
