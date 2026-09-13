import SwiftUI

// MARK: - Facts surface (02-charts-rings-widgets.md §0 Facts table)
//
// Every row is either computed by `UsageFacts.compute(from:)` from real fields on
// `UsageAnalyticsSnapshot`, or rendered as an honest "Not available" when the local data model
// has no source for it — no fabricated numbers. See the GAP table in 02 §0 for the authoritative
// list of what's still missing from the data model (lifetime tokens, per-turn duration, streaks,
// credits, banked resets).

struct UsageFactsView: View {
    let snapshot: ProviderSnapshot
    let analytics: UsageAnalyticsSnapshot?

    private var facts: UsageFacts {
        UsageFacts.compute(from: analytics, fallbackProvenance: snapshot.provenance)
    }

    private static let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    private func formatTokens(_ tokens: Int) -> String {
        Self.tokenFormatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    var body: some View {
        factsCard
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageCardHeader(
                title: "Window facts",
                subtitle: "Observed activity for \(snapshot.provider.displayName)",
                icon: .usage
            )
            .padding(.bottom, LifeOSTokens.Space.xs)

            activityRows
            if facts.peakDailyActivity == nil && facts.peakActivity == nil && facts.observedTotals == nil {
                divider
            }

            // Source freshness is derived from Provenance.freshness(); it is the one
            // source-status fact retained on this compact detail surface.
            factRow(label: "Source freshness", value: sourceFreshnessValue)
            divider

            Text("Provider details unavailable: lifetime totals, turn duration, streaks, credits, and banked resets are not supplied by this source.")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, LifeOSTokens.Space.xs)
        }
        .padding(UsageLayoutContract.cardPadding)
        .flatCard()
        .accessibilityIdentifier("usage-facts")
    }

    @ViewBuilder
    private var activityRows: some View {
        if let peakDaily = facts.peakDailyActivity {
            factRow(
                label: "Peak daily activity",
                value: "\(formatTokens(peakDaily.tokens)) tok · \(peakDaily.granularityLabel)"
            )
            divider
        }

        if let peak = facts.peakActivity {
            factRow(
                label: "Peak hourly activity",
                value: "\(formatTokens(peak.tokens)) tok · \(peak.granularityLabel)"
            )
            divider
        }

        if let totals = facts.observedTotals {
            factRow(
                label: "Observed tokens (window)",
                value: "\(formatTokens(totals.totalTokens)) tok · \(totals.observationCount) obs"
            )
            divider
        }

        if facts.peakDailyActivity == nil && facts.peakActivity == nil && facts.observedTotals == nil {
            Text(noActivityDetail)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, LifeOSTokens.Space.xs)
        }
    }

    private var sourceFreshnessValue: String {
        facts.freshness.map(freshnessLabel) ?? "Not available"
    }

    private var noActivityDetail: String {
        snapshot.provenance.quality == .demo
            ? "No fixture activity observations are available for this window."
            : "No token activity observations were supplied for this window."
    }

    private func freshnessLabel(_ fact: UsageFreshnessFact) -> String {
        let observed = fact.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        switch fact.freshness {
        case .fresh: return "Fresh · \(observed)"
        case .aging: return "Aging · \(observed)"
        case .stale: return "Stale · \(observed)"
        case .unavailable: return "Not available"
        }
    }

    private var divider: some View {
        Divider().overlay(LifeOSTokens.hairlineBorder)
    }

    private func factRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: LifeOSTokens.Space.sm)
            Text(value)
                .lifeOSTypography(.label, weight: .medium)
                .foregroundStyle(value == "Not available" ? LifeOSTokens.tertiaryText : .primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, LifeOSTokens.Space.xs)
        .accessibilityElement(children: .combine)
    }
}
