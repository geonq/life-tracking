import Foundation

// MARK: - Wealth projection: a labelled forecast, never an observation

/// One observed wealth data point: an exact integer-cents value as of a
/// date. This is the minimal shape `FinanceWealthProjector` consumes; the
/// durable history/observation store for these points is a separate,
/// later tranche and out of scope here.
public struct FinanceWealthObservationPoint: Equatable, Sendable {
    public let date: Date
    public let valueCents: Int

    public init(date: Date, valueCents: Int) {
        self.date = date
        self.valueCents = valueCents
    }
}

/// A future wealth value derived from historical observations by
/// extrapolation. Deliberately a distinct type from any observed-wealth
/// type in `FinanceDomain` — a view must go out of its way to render a
/// `FinanceWealthProjection` (e.g. via a dashed/labelled series), and can
/// never receive one where an observation was expected, because the two
/// are not interchangeable in the type system.
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

    public init(
        basedOnPointCount: Int,
        asOfDate: Date,
        targetDate: Date,
        projectedValueCents: Int
    ) {
        self.basedOnPointCount = basedOnPointCount
        self.asOfDate = asOfDate
        self.targetDate = targetDate
        self.projectedValueCents = projectedValueCents
        let roundedEuros = (Double(projectedValueCents) / 100).rounded()
        self.displayRoundedValueCents = Int(roundedEuros * 100)
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
        let targetX = targetDate.timeIntervalSince(first.date)
        let projectedValue = slope * targetX + intercept
        guard projectedValue.isFinite else { return .degenerateHistory }

        return .projected(FinanceWealthProjection(
            basedOnPointCount: sorted.count,
            asOfDate: last.date,
            targetDate: targetDate,
            projectedValueCents: Int(projectedValue.rounded())
        ))
    }
}
