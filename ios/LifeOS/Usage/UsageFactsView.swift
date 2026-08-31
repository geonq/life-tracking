import SwiftUI

// MARK: - Facts tab (02-charts-rings-widgets.md §0 Facts table)
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

    private var timestamp: String {
        snapshot.provenance.observedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    private var subLabel: String { "\(snapshot.provider.displayName) · \(timestamp)" }

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
        VStack(alignment: .leading, spacing: 14) {
            factsCard
            bankedResetsCard
        }
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageCardHeader(
                title: "Account facts",
                subtitle: "Sourced observations for \(snapshot.provider.displayName)",
                icon: .usage
            )
            .padding(.bottom, 12)

            // Lifetime tokens — GAP. No cumulative-tokens-ever field in UsageAnalytics.swift;
            // `activity` only covers the current short window.
            factRow(label: "Lifetime tokens", value: "Not available")
            divider

            // Peak daily tokens is only promoted when the activity feed contains
            // every hour for a complete calendar day. Partial feeds stay unavailable.
            factRow(
                label: "Peak daily tokens",
                value: facts.peakDailyActivity.map { "\(formatTokens($0.tokens)) tok" } ?? "Not available"
            )
            divider

            // Observed tokens — sum across the currently loaded window, with the number of
            // observations that contributed. Explicitly NOT lifetime usage.
            factRow(
                label: "Observed tokens (window)",
                value: facts.observedTotals.map { "\(formatTokens($0.totalTokens)) tok · \($0.observationCount) obs" }
                    ?? "Not available"
            )
            divider

            // Longest running turn — GAP. No per-turn/session duration field in the domain model.
            factRow(label: "Longest running turn", value: "Not available")
            divider

            // Current / Longest streak — GAP. No usage-streak concept modeled.
            factRow(label: "Current streak", value: "Not available")
            divider
            factRow(label: "Longest streak", value: "Not available")
            divider

            // Credits — GAP. No credits/balance field; provider model here is percent-of-window.
            factRow(label: "Credits", value: "Not available")
            divider

            // Source freshness — derived from Provenance.freshness(); real signal, not fabricated.
            factRow(
                label: "Source freshness",
                value: facts.freshness.map { freshnessLabel($0) } ?? "Not available"
            )
        }
        .flatCard()
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

    private var bankedResetsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Banked resets")
                .font(LifeOSFont.cardTitle(16))
                .padding(.bottom, 6)

            // Banked resets — GAP across all four sub-fields. Only a static demo string exists
            // today (OverviewDomain.swift), not a real modeled field. 02 §0 data-gaps item 1.
            factRow(label: "Available", value: "Not available")
            divider
            factRow(label: "Reset detail", value: "Not available")
            divider
            factRow(label: "Next expiry", value: "Not available")
            divider
            factRow(label: "Source", value: "Not available")
        }
        .flatCard()
    }

    private var divider: some View {
        Divider().opacity(0.25).padding(.vertical, 8)
    }

    private func factRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(LifeOSFont.bodyText(14))
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text(subLabel)
                    .font(LifeOSFont.metadata(11))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 12)
            Text(value)
                .font(LifeOSFont.control(14))
                .foregroundStyle(value == "Not available" ? LifeOSTokens.tertiaryText : .primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}
