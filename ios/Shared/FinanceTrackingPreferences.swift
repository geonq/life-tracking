import Foundation

// MARK: - Income/expense tracking cadence preferences

/// How often the user wants income/expense tracking to prompt or refresh.
/// `.customDayOfMonth` carries its own day rather than deferring to a
/// separate optional field, so "custom with no day" is unrepresentable
/// rather than merely rejected at validation time.
public enum FinanceTrackingFrequency: Codable, Equatable, Sendable {
    case weekly
    case biweekly
    case monthly
    case customDayOfMonth(Int)

    private enum CodingKeys: String, CodingKey {
        case kind, day
    }

    private enum Kind: String, Codable {
        case weekly, biweekly, monthly, customDayOfMonth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .weekly: self = .weekly
        case .biweekly: self = .biweekly
        case .monthly: self = .monthly
        case .customDayOfMonth: self = .customDayOfMonth(try container.decode(Int.self, forKey: .day))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .weekly: try container.encode(Kind.weekly, forKey: .kind)
        case .biweekly: try container.encode(Kind.biweekly, forKey: .kind)
        case .monthly: try container.encode(Kind.monthly, forKey: .kind)
        case .customDayOfMonth(let day):
            try container.encode(Kind.customDayOfMonth, forKey: .kind)
            try container.encode(day, forKey: .day)
        }
    }

    /// `1...31` inclusive. Day 0 and any day past 31 are rejected — this is
    /// a calendar day-of-month, not an arbitrary integer.
    static let validDayOfMonthRange = 1...31
}

/// A durable income/expense tracking cadence preference. Represents a
/// single current record (not a history) plus, via
/// `FinanceTrackingPreferencesStore`, an independent non-destructive draft
/// so a UI can implement save/cancel without mutating the committed value
/// until an explicit save.
public struct FinanceTrackingPreferences: Codable, Equatable, Sendable {
    public let frequency: FinanceTrackingFrequency
    /// The reference date a cycle is measured from — e.g. which day
    /// `.weekly`/`.biweekly` recur on, or the first cycle start for
    /// `.monthly`. Must be a finite, representable date.
    public let cycleAnchorDate: Date
    public let incomeTrackingEnabled: Bool
    public let expenseTrackingEnabled: Bool
    public let updatedAt: Date

    public init(
        frequency: FinanceTrackingFrequency,
        cycleAnchorDate: Date,
        incomeTrackingEnabled: Bool,
        expenseTrackingEnabled: Bool,
        updatedAt: Date = .now
    ) {
        self.frequency = frequency
        self.cycleAnchorDate = cycleAnchorDate
        self.incomeTrackingEnabled = incomeTrackingEnabled
        self.expenseTrackingEnabled = expenseTrackingEnabled
        self.updatedAt = updatedAt
    }
}

/// Validation failures for a `FinanceTrackingPreferences` value, independent
/// of persistence (reused by both the store and any UI-level pre-check).
public enum FinanceTrackingPreferencesValidationError: Error, Equatable, Sendable {
    case invalidAnchorDate
    case invalidCustomDayOfMonth
}

public extension FinanceTrackingPreferences {
    /// `nil` when valid; otherwise the first validation failure found.
    /// Checked wherever a value is persisted — draft or committed — so an
    /// invalid preference can never be silently saved.
    var validationError: FinanceTrackingPreferencesValidationError? {
        guard cycleAnchorDate.timeIntervalSinceReferenceDate.isFinite else {
            return .invalidAnchorDate
        }
        if case .customDayOfMonth(let day) = frequency,
           !FinanceTrackingFrequency.validDayOfMonthRange.contains(day) {
            return .invalidCustomDayOfMonth
        }
        return nil
    }
}
