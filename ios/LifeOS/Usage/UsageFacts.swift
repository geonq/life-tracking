import Foundation

// MARK: - Facts tab pure computation (02-charts-rings-widgets.md §0 Facts table)
//
// Every fact is either computed from real fields on `UsageAnalyticsSnapshot`/`Provenance`, or
// left `nil` when the local data model has no source for it. `UsageFactsView` renders `nil` as
// "Not available" — never a fabricated number. See `docs/...02-charts-rings-widgets.md` GAP
// table for the authoritative list of what's still missing from the data model upstream.

/// A single activity point promoted to "peak" status, with its true observed granularity.
public struct UsagePeakActivityFact: Equatable, Sendable {
    public let tokens: Int
    public let date: Date
    /// Human label for the granularity of `date` spacing in the source activity series
    /// (e.g. "hour"). Must always match the true spacing — never claim "day" for hourly data.
    public let granularityLabel: String

    public init(tokens: Int, date: Date, granularityLabel: String) {
        self.tokens = tokens
        self.date = date
        self.granularityLabel = granularityLabel
    }
}

/// Total tokens observed across the currently loaded activity window, plus how many discrete
/// observations contributed to that total. This is NOT lifetime usage — only what is in
/// `UsageAnalyticsSnapshot.activity` for the active provider/window.
public struct UsageObservedTotalsFact: Equatable, Sendable {
    public let totalTokens: Int
    public let observationCount: Int

    public init(totalTokens: Int, observationCount: Int) {
        self.totalTokens = totalTokens
        self.observationCount = observationCount
    }
}

/// Freshness of the source data, derived from `Provenance`.
public struct UsageFreshnessFact: Equatable, Sendable {
    public let observedAt: Date
    public let freshness: Freshness
    public let source: String

    public init(observedAt: Date, freshness: Freshness, source: String) {
        self.observedAt = observedAt
        self.freshness = freshness
        self.source = source
    }
}

/// Typed facts for the Usage "Facts" tab. Every field is optional: `nil` means the local data
/// model genuinely has no source for that fact today (honest-unavailable), not that computation
/// failed. Fields with no local source at all (lifetime tokens, longest turn, streaks, credits,
/// banked resets) are not represented here — `UsageFactsView` renders them as static
/// "Not available" rows so they flow through the same honest path without pretending to be
/// derived from a model that doesn't exist yet.
public struct UsageFacts: Equatable, Sendable {
    public let peakActivity: UsagePeakActivityFact?
    public let observedTotals: UsageObservedTotalsFact?
    public let freshness: UsageFreshnessFact?

    public init(peakActivity: UsagePeakActivityFact?, observedTotals: UsageObservedTotalsFact?, freshness: UsageFreshnessFact?) {
        self.peakActivity = peakActivity
        self.observedTotals = observedTotals
        self.freshness = freshness
    }

    /// Computes facts from an analytics snapshot. Returns a struct of `nil`s (not fabricated
    /// zeros) when `analytics` is `nil` or its `activity` series is empty.
    public static func compute(from analytics: UsageAnalyticsSnapshot?, now: Date = .now) -> UsageFacts {
        guard let analytics else {
            return UsageFacts(peakActivity: nil, observedTotals: nil, freshness: nil)
        }

        let peak: UsagePeakActivityFact? = analytics.activity
            .max { $0.tokens < $1.tokens }
            .map { point in
                UsagePeakActivityFact(tokens: point.tokens, date: point.date, granularityLabel: "hour")
            }

        let totals: UsageObservedTotalsFact? = analytics.activity.isEmpty
            ? nil
            : UsageObservedTotalsFact(
                totalTokens: analytics.activity.reduce(0) { $0 + $1.tokens },
                observationCount: analytics.activity.count
            )

        let freshness = UsageFreshnessFact(
            observedAt: analytics.provenance.observedAt,
            freshness: analytics.provenance.freshness(now: now),
            source: analytics.provenance.source
        )

        return UsageFacts(peakActivity: peak, observedTotals: totals, freshness: freshness)
    }
}
