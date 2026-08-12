import SwiftUI

// MARK: - Facts tab (02-charts-rings-widgets.md §0 Facts table)
//
// Every row maps to a real field or renders "Not available" — no fabricated numbers. See the
// GAP table in 02 §0 for the authoritative list of what's missing from the data model.

struct UsageFactsView: View {
    let snapshot: ProviderSnapshot
    let analytics: UsageAnalyticsSnapshot?

    private var timestamp: String {
        snapshot.provenance.observedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    private var subLabel: String { "\(snapshot.provider.displayName) · \(timestamp)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            factsCard
            bankedResetsCard
        }
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account facts")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 10)

            // Lifetime tokens — GAP. No cumulative-tokens-ever field in UsageAnalytics.swift;
            // `activity` only covers the current short window.
            factRow(label: "Lifetime tokens", value: "Not available")
            divider

            // Peak daily tokens — Partial per 02 §0: computable once daily-granularity history
            // lands. Today's activity is hourly, not daily, so this is not a fair "peak day".
            factRow(label: "Peak daily tokens", value: "Not available")
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
        }
        .lifeOSCard()
    }

    private var bankedResetsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Banked resets")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 10)

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
        .lifeOSCard()
    }

    private var divider: some View {
        Divider().opacity(0.25).padding(.vertical, 8)
    }

    private func factRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline)
                Text(subLabel).font(.caption2).foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(value == "Not available" ? .regular : .semibold))
                .foregroundStyle(value == "Not available" ? LifeOSTokens.tertiaryText : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}
