import Foundation

// MARK: - Durable, user-editable nutrition goal domain

/// A single dated nutrition goal. Goals form a dated history rather than a
/// single mutable record: `NutritionGoalStore.setGoal` always appends a new
/// entry, and `currentGoal(on:)` resolves "the goal in effect" as the latest
/// entry whose `effectiveFrom` is on or before the requested day. This makes
/// past days answerable against the goal that was actually active then,
/// rather than silently rewriting history when a user changes their target.
///
/// Every target is `Int?`, not `Int`. `nil` means the user has not set that
/// target — a real, honest "unset" state — and is never coerced to `0`. An
/// explicit `0` (if a user ever entered it) would be a real observed value
/// and is preserved as-is; the store does not fabricate or infer either
/// direction.
public struct NutritionGoal: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The calendar day (and time) this goal takes effect from. Combined
    /// with `createdAt`, this lets a goal be backdated or scheduled without
    /// losing the audit trail of when it was actually entered.
    public var effectiveFrom: Date
    public var calorieTarget: Int?
    public var proteinGramsTarget: Int?
    public var carbGramsTarget: Int?
    public var fatGramsTarget: Int?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        effectiveFrom: Date,
        calorieTarget: Int? = nil,
        proteinGramsTarget: Int? = nil,
        carbGramsTarget: Int? = nil,
        fatGramsTarget: Int? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.effectiveFrom = effectiveFrom
        self.calorieTarget = calorieTarget
        self.proteinGramsTarget = proteinGramsTarget
        self.carbGramsTarget = carbGramsTarget
        self.fatGramsTarget = fatGramsTarget
        self.createdAt = createdAt
    }

    /// `true` only when every target is unset. A goal with at least one
    /// explicit target (even if the others are nil) is not empty.
    public var isEmpty: Bool {
        calorieTarget == nil && proteinGramsTarget == nil && carbGramsTarget == nil && fatGramsTarget == nil
    }
}
