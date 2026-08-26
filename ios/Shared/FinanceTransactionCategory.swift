import Foundation
import SwiftUI

// MARK: - Spending category for manually imported transactions

/// A coarse spending/income category assigned by `FinanceCategorizer` to a
/// `FinanceImportedTransaction`. This is deliberately separate from the
/// live-connector `FinanceDomain` category system. Automatic categorization
/// remains pure, while an explicit canonical user override may be persisted
/// on an imported transaction; `.uncategorized` is always honest unknown.
public enum FinanceTransactionCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case groceries
    case dining
    case transport
    case shopping
    case bills
    case subscriptions
    case health
    case travel
    case transfers
    case fees
    case taxes
    case investments
    case income
    case cash
    case uncategorized

    /// Maps common bank/provider labels to LifeOS's canonical category
    /// vocabulary. Unknown labels intentionally return nil so a provider's
    /// private taxonomy is not presented as a false match.
    public static func from(sourceCategory: String?) -> Self? {
        guard let sourceCategory else { return nil }
        let key = sourceCategory
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch key {
        case "food", "foods", "grocery", "groceries", "groceries and food", "lebensmittel", "supermarket", "supermarkt":
            return .groceries
        case "dining", "restaurant", "restaurants", "food and dining", "essen":
            return .dining
        case "transport", "transportation", "public transport", "mobility", "verkehr":
            return .transport
        case "shopping", "retail", "online shopping", "einkaufen":
            return .shopping
        case "bills", "utilities", "household", "home", "housing", "rent", "wohnen", "miete", "rechnungen":
            return .bills
        case "subscription", "subscriptions", "recurring", "abonnement", "abos":
            return .subscriptions
        case "health", "healthcare", "medical", "pharmacy", "gesundheit", "medizin", "apotheke":
            return .health
        case "travel", "reisen", "reise", "hotels", "hotel":
            return .travel
        case "transfer", "transfers", "bank transfer", "bank transfers", "ueberweisung", "uberweisung":
            return .transfers
        case "fee", "fees", "charges", "bank fee", "bank fees", "gebuehr", "gebuhren", "entgelt":
            return .fees
        case "tax", "taxes", "steuer", "steuern":
            return .taxes
        case "investment", "investments", "investing", "brokerage", "wertpapiere", "aktien", "etf":
            return .investments
        case "income", "salary", "salaries", "wages", "gehalt", "lohn":
            return .income
        case "cash", "cash withdrawal", "atm", "bargeld", "bargeldauszahlung":
            return .cash
        case "other", "unknown", "uncategorized":
            return .uncategorized
        default:
            return nil
        }
    }

    /// User-facing label.
    public var displayName: String {
        switch self {
        case .groceries: "Groceries"
        case .dining: "Dining"
        case .transport: "Transport"
        case .shopping: "Shopping"
        case .bills: "Bills"
        case .subscriptions: "Subscriptions"
        case .health: "Health"
        case .travel: "Travel"
        case .transfers: "Transfers"
        case .fees: "Fees"
        case .taxes: "Taxes"
        case .investments: "Investments"
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
        case .health: .red
        case .travel: .blue
        case .transfers: .teal
        case .fees: .amber
        case .taxes: .orange
        case .investments: .purple
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
        case .health: .health
        case .travel: .calendar
        case .transfers: .finance
        case .fees: .documents
        case .taxes: .tax
        case .investments: .investments
        case .income: .revenue
        case .cash: .savings
        case .uncategorized: .more
        }
    }
}
