import Foundation

// MARK: - Wealth projection: a labelled forecast, never an observation

/// One observed wealth data point: an exact integer-cents value as of a
/// date. This is the minimal shape `FinanceWealthProjector` consumes; the
/// durable history/observation store for these points is a separate,
/// later tranche and out of scope here.
///
/// The memberwise init is internal, not public: nothing outside this module
/// should be able to fabricate an "observation" out of thin air, since
/// `FinanceWealthProjector.project` is meant to be the trusted boundary that
/// decides what counts as observed history.
public struct FinanceWealthObservationPoint: Equatable, Sendable {
    public let date: Date
    public let valueCents: Int

    init(date: Date, valueCents: Int) {
        self.date = date
        self.valueCents = valueCents
    }
}

/// A future wealth value derived from historical observations by
/// extrapolation. Deliberately a distinct type from any observed-wealth
/// type in `FinanceDomain` — a view must go out of its way to render a
/// `FinanceWealthProjection` (e.g. via a dashed/labelled series).
///
/// Its memberwise init is internal (not public) and failable, for the same
/// reason `FinanceWealthObservationPoint`'s is internal: only
/// `FinanceWealthProjector.project` produces these values, and it always
/// does so from validated, in-range inputs — an out-of-module caller can
/// receive one but never launder an observation into a projection, or
/// construct a degenerate one (`basedOnPointCount <= 0`, or a
/// `projectedValueCents` so extreme that the display-rounding computation
/// below cannot represent it as an `Int`) that would otherwise trap.
///
/// Exact-value semantics: `projectedValueCents` is the authoritative
/// integer-cents value. `displayRoundedValueCents` rounds that to the
/// nearest whole euro purely for compact axis/label display and is never
/// authoritative — callers doing math must always use
/// `projectedValueCents`.
public struct FinanceWealthProjection: Equatable, Sendable {
    public let basedOnPointCount: Int
    /// The date of the latest observation the projection was extrapolated
    /// from — the boundary between observed history and projected future.
    public let asOfDate: Date
    public let targetDate: Date
    public let projectedValueCents: Int
    public let displayRoundedValueCents: Int

    init?(
        basedOnPointCount: Int,
        asOfDate: Date,
        targetDate: Date,
        projectedValueCents: Int
    ) {
        guard basedOnPointCount > 0 else { return nil }
        guard asOfDate.timeIntervalSinceReferenceDate.isFinite,
              targetDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let roundedEuros = (Double(projectedValueCents) / 100).rounded()
        guard let displayCents = FinanceWealthProjection.safeInt(fromFiniteRangeChecked: roundedEuros * 100) else {
            return nil
        }
        self.basedOnPointCount = basedOnPointCount
        self.asOfDate = asOfDate
        self.targetDate = targetDate
        self.projectedValueCents = projectedValueCents
        self.displayRoundedValueCents = displayCents
    }

    /// Converts a `Double` to `Int` without ever trapping. `Int(_:)` traps
    /// for any finite `Double` outside the representable `Int` range (e.g.
    /// `Int(Double(Int.max))` traps, since that `Double` rounds up past
    /// `Int.max`), so `isFinite` alone is not sufficient — every
    /// `Double`-to-`Int` money conversion in this file goes through this
    /// helper instead. `Double(Int.min)` and `Double(Int.max) + 1` are both
    /// exactly representable as `Double`, so this bound is exact, not an
    /// approximation.
    static func safeInt(fromFiniteRangeChecked value: Double) -> Int? {
        let lowerBound = -0x1p63 // Double(Int.min), exactly representable.
        let upperBound = 0x1p63 // Double(Int.max) + 1, exactly representable.
        guard value.isFinite, value >= lowerBound, value < upperBound else { return nil }
        return Int(value)
    }
}

/// The outcome of attempting a projection. Insufficient or degenerate
/// history is an honest, explicit refusal — never a fabricated trend line
/// drawn from too little (or too flat) data.
public enum FinanceWealthProjectionResult: Equatable, Sendable {
    /// Fewer than `FinanceWealthProjector.minimumHistoryPointCount`
    /// observations were provided.
    case insufficientHistory(pointsProvided: Int, minimumRequired: Int)
    /// Enough points were provided, but they share a single timestamp (or
    /// collapse to one after sorting), so no time-based trend can be fit.
    case degenerateHistory
    /// `horizonDays` was not a positive number of days.
    case invalidHorizon
    /// The regression produced a value (or a display-rounding of one) too
    /// extreme to represent as an exact integer-cents `Int` — an honest
    /// refusal instead of a silent process crash. Reachable from realistic
    /// inputs: a small but nonzero slope times a very large `horizonDays`
    /// can legitimately extrapolate past what `Int` cents can hold.
    case valueOutOfRange
    case projected(FinanceWealthProjection)
}

/// Pure, deterministic wealth projection. The same observations and horizon
/// always produce the same result — no wall-clock dependence, no
/// randomness.
public enum FinanceWealthProjector {
    /// The documented minimum number of observed points required before a
    /// trend is projected at all. Below this, projecting would be
    /// extrapolating noise, not a trend — refused via
    /// `.insufficientHistory` rather than silently drawn anyway.
    public static let minimumHistoryPointCount = 3

    /// Projects a linear trend from `observations` forward by
    /// `horizonDays` days past the latest observation, using ordinary
    /// least-squares regression over (seconds-since-first-observation,
    /// value-in-cents). The regression's internal arithmetic uses `Double`
    /// (this is curve-fitting math, not a stored money value); the result
    /// is rounded back to an exact `Int` cents value before being returned,
    /// so no money anywhere in the public surface is ever a `Double`.
    public static func project(
        observations: [FinanceWealthObservationPoint],
        horizonDays: Int
    ) -> FinanceWealthProjectionResult {
        guard horizonDays > 0 else { return .invalidHorizon }
        let sorted = observations.sorted { $0.date < $1.date }
        guard sorted.count >= minimumHistoryPointCount else {
            return .insufficientHistory(pointsProvided: sorted.count, minimumRequired: minimumHistoryPointCount)
        }
        guard let first = sorted.first, let last = sorted.last, last.date > first.date else {
            return .degenerateHistory
        }

        let n = Double(sorted.count)
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for point in sorted {
            let x = point.date.timeIntervalSince(first.date)
            let y = Double(point.valueCents)
            sumX += x
            sumY += y
            sumXY += x * y
            sumXX += x * x
        }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return .degenerateHistory }

        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n

        let targetDate = last.date.addingTimeInterval(Double(horizonDays) * 86_400)
        guard targetDate.timeIntervalSinceReferenceDate.isFinite else { return .valueOutOfRange }
        let targetX = targetDate.timeIntervalSince(first.date)
        let projectedValue = slope * targetX + intercept
        // `projectedValue.isFinite` alone is not a sufficient guard here: a
        // finite `Double` can still sit outside the range `Int` can hold,
        // and `Int(_:)` traps (not throws) on that — see
        // `FinanceWealthProjection.safeInt(fromFiniteRangeChecked:)`.
        guard let projectedValueCents = FinanceWealthProjection.safeInt(fromFiniteRangeChecked: projectedValue.rounded()) else {
            return .valueOutOfRange
        }

        guard let projection = FinanceWealthProjection(
            basedOnPointCount: sorted.count,
            asOfDate: last.date,
            targetDate: targetDate,
            projectedValueCents: projectedValueCents
        ) else {
            return .valueOutOfRange
        }
        return .projected(projection)
    }
}
