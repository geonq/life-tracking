import Foundation

// MARK: - Wealth allocation breakdown (RF-06)
//
// Pure domain logic that turns a `FinanceWealthSnapshot`'s individual holding
// observations into an asset-class allocation breakdown. This file never
// touches SwiftUI/design tokens -- the view layer maps the categories below
// onto its own presentation model (hue, formatted amount text, etc).

/// A single asset-class allocation slice, computed only from holdings whose
/// value was actually observed. Never constructed from a holding whose value
/// is unavailable -- see `FinanceWealthAllocationEngine.breakdown` for the
/// exclusion rule.
public struct FinanceWealthAllocationCategory: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let valueCents: Int
    public let holdingCount: Int
    /// Whole percent share of the breakdown's `totalValueCents`,
    /// integer-cent-derived. See `FinanceWealthAllocationEngine` for the
    /// rounding rule: every breakdown's category percentages sum to exactly
    /// 100, so a rounded display can never imply a different total.
    public let percentage: Int
    /// `[0, 1]` proportion of `totalValueCents`, for ring/chart geometry
    /// only. This is never money and is never treated as an independent
    /// source of truth for the displayed percentage -- `percentage` above
    /// is authoritative for anything the user reads as a number.
    public let fraction: Double
}

/// The full allocation result for one wealth snapshot.
public struct FinanceWealthAllocationBreakdownValue: Equatable, Sendable {
    public let categories: [FinanceWealthAllocationCategory]
    public let totalValueCents: Int
    /// `true` when one or more of the snapshot's holdings were excluded from
    /// both the numerator and the denominator (value unavailable, non-EUR,
    /// or non-positive). An excluded holding is never treated as a
    /// zero-value contributor -- silently folding it into the total would
    /// misrepresent every other category's share.
    public let isPartial: Bool
    public let excludedHoldingCount: Int
}

/// The allocation breakdown over a wealth snapshot's observed holdings.
/// `.unavailable` covers every case where there is nothing honest to draw a
/// ring over: no snapshot, an unavailable snapshot, an empty holdings list,
/// or a holdings list where no row contributed a usable positive EUR value.
/// The surface must never render a ring implying a real split over no data.
public enum FinanceWealthAllocationBreakdown: Equatable, Sendable {
    case unavailable
    case observed(FinanceWealthAllocationBreakdownValue)
}

public enum FinanceWealthAllocationEngine {
    /// Groups a wealth snapshot's observed EUR holdings by `assetClass`
    /// (a missing or blank asset class falls into "Uncategorized") and
    /// computes each category's integer-cent total and whole-percent share
    /// of the group's total.
    ///
    /// **Exclusion rule.** A holding is included in a category's total (and
    /// therefore in the shared denominator) only when all of the following
    /// hold: `availability == .observed`, `currency == "EUR"`,
    /// `valueCents != nil`, and `valueCents > 0`. Everything else --
    /// unavailable rows, and the degenerate case of a non-positive observed
    /// value that cannot be assigned a meaningful positive share -- is
    /// dropped from both sides of the fraction and counted in
    /// `excludedHoldingCount`. It is never coerced to zero and folded into
    /// the total, which is exactly the silent-absorption failure this engine
    /// exists to avoid.
    ///
    /// **Rounding rule (largest remainder method).** For a category with
    /// value `v` out of observed total `T` (`T > 0`), the exact share in
    /// percent is `v * 100 / T`. Each category first gets
    /// `floor(v * 100 / T)` whole percentage points. Because every floor can
    /// only round down, the floors sum to at most 100; the remaining points
    /// (`100 - sum of floors`) are handed out one at a time to the
    /// categories with the largest fractional remainder
    /// (`(v * 100) % T`), breaking ties by larger `valueCents` and then by
    /// ascending category name for a fully deterministic order. This
    /// guarantees `categories.map(\.percentage).reduce(0, +) == 100`
    /// whenever the breakdown is `.observed` -- the rounded whole-percent
    /// values shown to the user can never imply a total other than 100%.
    ///
    /// **Degenerate inputs.** An empty holdings list, or a holdings list
    /// where every row is excluded (or the observed total is not strictly
    /// positive), returns `.unavailable` rather than a zero-category or
    /// divide-by-zero result -- there is nothing to allocate, so nothing is
    /// drawn.
    public static func breakdown(from snapshot: FinanceWealthSnapshot?) -> FinanceWealthAllocationBreakdown {
        guard let snapshot, snapshot.availability == .observed, let holdings = snapshot.holdings else {
            return .unavailable
        }

        var order: [String] = []
        var totalsByName: [String: Int] = [:]
        var countsByName: [String: Int] = [:]
        var total = 0
        var excludedCount = 0

        for holding in holdings {
            guard holding.availability == .observed,
                  holding.currency == "EUR",
                  let value = holding.valueCents,
                  value > 0 else {
                excludedCount += 1
                continue
            }

            let trimmedAssetClass = holding.assetClass?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmedAssetClass?.isEmpty == false ? trimmedAssetClass : nil) ?? "Uncategorized"

            if totalsByName[name] == nil {
                order.append(name)
                totalsByName[name] = 0
                countsByName[name] = 0
            }

            let categoryAddition = totalsByName[name]!.addingReportingOverflow(value)
            guard !categoryAddition.overflow else { return .unavailable }
            totalsByName[name] = categoryAddition.partialValue
            countsByName[name]! += 1

            let totalAddition = total.addingReportingOverflow(value)
            guard !totalAddition.overflow else { return .unavailable }
            total = totalAddition.partialValue
        }

        guard total > 0, !order.isEmpty else {
            return .unavailable
        }

        struct RawCategory {
            let name: String
            let valueCents: Int
            let holdingCount: Int
        }

        let rawCategories: [RawCategory] = order
            .map { RawCategory(name: $0, valueCents: totalsByName[$0]!, holdingCount: countsByName[$0]!) }
            .sorted { lhs, rhs in
                if lhs.valueCents != rhs.valueCents { return lhs.valueCents > rhs.valueCents }
                return lhs.name < rhs.name
            }

        guard let percentages = FinancePercentageAllocator.percentages(for: rawCategories.map(\.valueCents)) else {
            return .unavailable
        }

        let categories = rawCategories.enumerated().map { offset, category in
            FinanceWealthAllocationCategory(
                id: category.name.lowercased(),
                name: category.name,
                valueCents: category.valueCents,
                holdingCount: category.holdingCount,
                percentage: percentages[offset],
                fraction: Double(category.valueCents) / Double(total)
            )
        }

        return .observed(FinanceWealthAllocationBreakdownValue(
            categories: categories,
            totalValueCents: total,
            isPartial: excludedCount > 0,
            excludedHoldingCount: excludedCount
        ))
    }
}
