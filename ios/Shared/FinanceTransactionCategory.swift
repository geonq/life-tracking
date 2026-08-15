import Foundation
import SwiftUI

// MARK: - Spending category for manually imported transactions

/// A coarse spending/income category assigned on the fly by
/// `FinanceCategorizer` to a `FinanceImportedTransaction`. This is
/// deliberately separate from the live-connector `FinanceDomain` category
/// system: it never persists (imported transactions are categorized fresh
/// from the keyword ruleset every time), and `.uncategorized` is an honest
/// "we don't know," never a fabricated guess.
public enum FinanceTransactionCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case groceries
    case dining
    case transport
    case shopping
    case bills
    case subscriptions
    case income
    case cash
    case uncategorized

    /// User-facing label.
    public var displayName: String {
        switch self {
        case .groceries: "Groceries"
        case .dining: "Dining"
        case .transport: "Transport"
        case .shopping: "Shopping"
        case .bills: "Bills"
        case .subscriptions: "Subscriptions"
        case .income: "Income"
        case .cash: "Cash"
        case .uncategorized: "Uncategorized"
        }
    }

    /// Hue token this category renders with. Reuses `LifeOSTokens.Hue` cases
    /// only — no new raw colors are introduced for categories.
    public var hue: LifeOSTokens.Hue {
        switch self {
        case .groceries: .green
        case .dining: .orange
        case .transport: .blue
        case .shopping: .pink
        case .bills: .amber
        case .subscriptions: .violet
        case .income: .teal
        case .cash: .lime
        case .uncategorized: .purple
        }
    }

    /// Icon shown next to the category in a spend list. Reuses existing
    /// `LifeOSIconName` cases only — no new Iconoir mappings are introduced.
    public var iconName: LifeOSIconName {
        switch self {
        case .groceries: .grocery
        case .dining: .shopping
        case .transport: .investments
        case .shopping: .shopping
        case .bills: .budget
        case .subscriptions: .refresh
        case .income: .revenue
        case .cash: .savings
        case .uncategorized: .more
        }
    }
}
