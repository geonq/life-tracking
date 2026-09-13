import Foundation
import SwiftUI

// MARK: - Bar chart contract
//
// Mirrors the vocabulary in `LifeOSChartKit.swift` (domain → normalized point →
// segment/selection) but for weekly-bucketed integer-cent money values instead
// of continuous Double series. Money never becomes a `Double` here.
//
// Honesty contract (the reason this file exists — see 00-READ-FIRST.md /
// 02-charts-rings-widgets.md §7): a week with no coverage is not a zero. A
// `LifeOSBarBucket.totalCents == nil` means "no observation could have landed
// here" (outside the known-coverage range) and must never be rendered as a
// zero-height bar. A non-nil total, including exactly `0`, means the coverage
// range included this week and the observed sum really is that amount — that
// IS a legitimate zero-height bar. Renderers tell the two apart by branching
// on `totalCents == nil` (or `LifeOSBarNormalizedBucket.isGap`/`.height == nil`),
// never by treating a nil as 0.

/// One calendar week's aggregated income, bucketed by the caller's `Calendar`
/// (so `firstWeekday` — not a hardcoded Monday/Sunday — decides the boundary).
public struct LifeOSBarBucket: Equatable, Identifiable, Sendable {
    /// Inclusive lower bound of the week, as produced by
    /// `Calendar.dateInterval(of: .weekOfYear, for:)`.
    public let weekStart: Date
    /// Exclusive upper bound — the instant the next week begins. A value
    /// timestamped exactly at `weekEnd` belongs to the *next* bucket.
    public let weekEnd: Date
    /// Sum of matching values in integer cents. `nil` means this week fell
    /// outside the known-coverage range passed to `weeklyBuckets` — an
    /// honest "no data", never a zero.
    public let totalCents: Int?
    /// False only for the week that contains `now` at bucketing time: it is
    /// still accumulating and must read as visually distinct from a fully
    /// elapsed week, even when both currently show the same total.
    public let isComplete: Bool

    public init(weekStart: Date, weekEnd: Date, totalCents: Int?, isComplete: Bool) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.totalCents = totalCents
        self.isComplete = isComplete
    }

    public var id: Date { weekStart }

    /// True when this week has no coverage at all. Distinct from an observed
    /// `totalCents == 0`.
    public var isUnavailable: Bool { totalCents == nil }
}

/// A single dated income observation in integer cents. No `Double` money.
public struct LifeOSMoneyObservation: Equatable, Sendable {
    public let timestamp: Date
    public let cents: Int

    public init(timestamp: Date, cents: Int) {
        self.timestamp = timestamp
        self.cents = cents
    }
}

public struct LifeOSBarChartDomain: Equatable, Sendable {
    /// Largest observed weekly total across non-unavailable buckets. `nil`
    /// when every bucket in range is unavailable.
    public let maximumCents: Int?

    public init(maximumCents: Int?) {
        self.maximumCents = maximumCents
    }

    public static func resolved(from buckets: [LifeOSBarBucket]) -> LifeOSBarChartDomain {
        LifeOSBarChartDomain(maximumCents: buckets.compactMap(\.totalCents).max())
    }
}

/// A `LifeOSBarBucket` placed on the unit plot. `height` is nil exactly when
/// the source bucket is unavailable — the renderer must not draw a bar for a
/// nil height; it draws the honest "no data" treatment instead (per
/// `02-charts-rings-widgets.md` §7).
public struct LifeOSBarNormalizedBucket: Equatable, Identifiable, Sendable {
    public let weekStart: Date
    public let weekEnd: Date
    public let totalCents: Int?
    public let isComplete: Bool
    /// Unit x coordinate in chronological order.
    public let x: Double
    /// Unit height, 0...1, baseline at 0. Nil means "do not draw a bar."
    public let height: Double?

    public var id: Date { weekStart }
    public var isGap: Bool { totalCents == nil }
}

// MARK: - Pure bar chart operations

public enum LifeOSBarChartKit {
    /// Buckets dated integer-cent observations into calendar weeks across
    /// `displayRange`, using `calendar` (so `calendar.firstWeekday` decides
    /// the week boundary, not a hardcoded day) and `calendar.timeZone` for
    /// boundary correctness.
    ///
    /// - `displayRange`: the half-open span of weeks to emit — every week
    ///   overlapping it gets exactly one bucket, including unavailable ones.
    /// - `coverageRange`: the half-open span in which real data could exist.
    ///   A week entirely outside this range is emitted with `totalCents ==
    ///   nil`. A week inside it with zero matching observations is emitted
    ///   with `totalCents == 0` — a real, observed zero.
    /// - `now`: decides `isComplete`. A week is complete when it has fully
    ///   elapsed (`weekEnd <= now`); the week containing `now` is partial.
    public static func weeklyBuckets(
        observations: [LifeOSMoneyObservation],
        calendar: Calendar,
        displayRange: Range<Date>,
        coverageRange: Range<Date>,
        now: Date
    ) -> [LifeOSBarBucket] {
        guard displayRange.lowerBound < displayRange.upperBound else { return [] }

        var buckets: [LifeOSBarBucket] = []
        var cursor = displayRange.lowerBound
        var guardCount = 0
        // A week is at most a handful of days; bound the loop generously so
        // a misbehaving calendar can never spin forever.
        let maxWeeks = 100_000

        while cursor < displayRange.upperBound, guardCount < maxWeeks {
            guardCount += 1
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: cursor) else { break }
            let weekStart = interval.start
            let weekEnd = interval.end
            guard weekEnd > weekStart else { break }

            let overlapsCoverage = weekStart < coverageRange.upperBound && weekEnd > coverageRange.lowerBound
            let totalCents: Int?
            if overlapsCoverage {
                totalCents = observations
                    .filter { $0.timestamp >= weekStart && $0.timestamp < weekEnd }
                    .reduce(0) { $0 + $1.cents }
            } else {
                totalCents = nil
            }

            buckets.append(
                LifeOSBarBucket(
                    weekStart: weekStart,
                    weekEnd: weekEnd,
                    totalCents: totalCents,
                    isComplete: weekEnd <= now
                )
            )

            cursor = weekEnd
        }

        return buckets
    }

    /// Places buckets on the unit plot. Bars scale against the largest
    /// non-unavailable weekly total in `domain` (or a freshly resolved one).
    public static func normalizedBuckets(
        from buckets: [LifeOSBarBucket],
        domain: LifeOSBarChartDomain? = nil
    ) -> [LifeOSBarNormalizedBucket] {
        guard !buckets.isEmpty else { return [] }

        let ordered = buckets.sorted { $0.weekStart < $1.weekStart }
        let resolvedDomain = domain ?? .resolved(from: ordered)
        let maxCents = resolvedDomain.maximumCents.map(Double.init) ?? 0
        let count = ordered.count

        return ordered.enumerated().map { index, bucket in
            let x: Double = count > 1 ? Double(index) / Double(count - 1) : 0.5
            let height: Double?
            if let total = bucket.totalCents {
                height = maxCents > 0 ? min(max(Double(total) / maxCents, 0), 1) : 0
            } else {
                height = nil
            }
            return LifeOSBarNormalizedBucket(
                weekStart: bucket.weekStart,
                weekEnd: bucket.weekEnd,
                totalCents: bucket.totalCents,
                isComplete: bucket.isComplete,
                x: x,
                height: height
            )
        }
    }

    /// Selects the bucket whose `[weekStart, weekEnd)` contains `timestamp`
    /// (clamped to the nearest edge bucket when the request falls outside
    /// every bucket's range, mirroring the line chart's nearest-point
    /// snapping). Reuses `LifeOSChartNoDataSelection`/
    /// `LifeOSChartSelectionNoDataReason` from `LifeOSChartKit.swift` so a
    /// later tranche can share the same no-data plumbing across modes; the
    /// selected payload is bar-specific (`LifeOSBarSelectedDatum`) because a
    /// bucket's shape (`weekStart`/`weekEnd`/`totalCents`/`isComplete`)
    /// differs from a line point's, and money here stays integer cents.
    public static func nearestSelection(
        in buckets: [LifeOSBarBucket],
        seriesID: String,
        to timestamp: Date
    ) -> LifeOSBarSelectionResult {
        guard !buckets.isEmpty else {
            return .noData(
                LifeOSChartNoDataSelection(
                    requestedTimestamp: timestamp,
                    reason: .noValidData,
                    seriesID: seriesID
                )
            )
        }

        let ordered = buckets.sorted { $0.weekStart < $1.weekStart }

        let containing = ordered.first { timestamp >= $0.weekStart && timestamp < $0.weekEnd }
        let nearest = containing ?? ordered.min { lhs, rhs in
            distance(from: timestamp, to: lhs) < distance(from: timestamp, to: rhs)
        }

        guard let bucket = nearest else {
            return .noData(
                LifeOSChartNoDataSelection(
                    requestedTimestamp: timestamp,
                    reason: .noValidData,
                    seriesID: seriesID
                )
            )
        }

        guard bucket.totalCents != nil else {
            return .noData(
                LifeOSChartNoDataSelection(
                    requestedTimestamp: timestamp,
                    reason: .explicitGap,
                    seriesID: seriesID
                )
            )
        }

        return .selected(LifeOSBarSelectedDatum(seriesID: seriesID, bucket: bucket))
    }

    private static func distance(from timestamp: Date, to bucket: LifeOSBarBucket) -> TimeInterval {
        if timestamp < bucket.weekStart { return bucket.weekStart.timeIntervalSince(timestamp) }
        if timestamp >= bucket.weekEnd { return timestamp.timeIntervalSince(bucket.weekEnd) }
        return 0
    }
}

// MARK: - Selection

/// A selected bar bucket. Shaped after `LifeOSChartSelectedDatum` (same
/// `seriesID` + `Identifiable` idiom) so scrub/tooltip call sites can switch
/// between line and bar modes without changing their surrounding state model.
public struct LifeOSBarSelectedDatum: Equatable, Identifiable, Sendable {
    public let seriesID: String
    public let bucket: LifeOSBarBucket

    public init(seriesID: String, bucket: LifeOSBarBucket) {
        self.seriesID = seriesID
        self.bucket = bucket
    }

    public var id: String {
        "\(seriesID)·\(bucket.weekStart.timeIntervalSinceReferenceDate)"
    }
}

/// Same shape as `LifeOSChartSelectionResult`, and shares its `.noData`
/// payload type outright, so no-data handling (explicit gap vs. no valid
/// data at all) is identical across line and bar charts.
public enum LifeOSBarSelectionResult: Equatable, Sendable {
    case selected(LifeOSBarSelectedDatum)
    case noData(LifeOSChartNoDataSelection)

    public var selectedDatum: LifeOSBarSelectedDatum? {
        guard case .selected(let datum) = self else { return nil }
        return datum
    }

    public var noDataSelection: LifeOSChartNoDataSelection? {
        guard case .noData(let selection) = self else { return nil }
        return selection
    }
}
