import Foundation
import SwiftUI

/// RF-03 / RF-02 (honest-state half): Finance's Analytics & Tools surface.
/// Reached from `FinanceView`'s "Analytics & Tools" card via an in-place hero
/// morph (Motion §A in `03-motion-revolut.md`), not a pushed screen — see
/// `FinanceView.financeHeroNamespace`/`FinanceHeroMorphTag`.
///
/// This is a Finance sub-surface, not a new primary destination: LifeOS's
/// binding IA is Home · Calendar · Finance · Fitness · Tax · Settings, and a
/// previous agent's unasked top-level modules were fully reverted (see
/// `Coordination/HANDOFF.md`).
///
/// Wealth reuses `FinanceView`'s own `FinanceWealthCard` (allocation +
/// holdings) and net-worth `FinanceDetailChartCard` (chart + linear
/// projection) verbatim — it is the exact same real, working surface the
/// main Finance screen renders, not a second implementation of it. Spending
/// abroad and Travel are honestly unavailable: `FinanceStatementImporter`
/// rejects any transaction row whose currency is not EUR at import time (see
/// that file's `unsupportedCurrency` diagnostic), and no country field
/// exists anywhere in the domain model. There is therefore no data source
/// for either entry, and this file must never fabricate one — no
/// IBAN/MCC-derived country guess, no trip model, no synthesized totals or
/// counts. Building the travel *feature* half (a map, trip counts, manual
/// trip entry) is a product-scope decision for geonq, not this tranche.
struct FinanceAnalyticsView: View {
    enum Entry: String, CaseIterable, Identifiable, Hashable {
        case wealth
        case spendingAbroad
        case travel

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wealth: "Wealth"
            case .spendingAbroad: "Spending abroad"
            case .travel: "Travel"
            }
        }

        var subtitle: String {
            switch self {
            case .wealth: "Allocation, holdings, and the net-worth trend"
            case .spendingAbroad: "Foreign-currency spending"
            case .travel: "Countries and trips"
            }
        }

        var icon: LifeOSIconName {
            switch self {
            case .wealth: .investments
            case .spendingAbroad: .spending
            case .travel: .empty
            }
        }

        /// Whether opening this entry can show anything. Marked on the list
        /// itself so the row does not promise content it cannot deliver: both
        /// unavailable entries lack a data source entirely, and a reader should
        /// learn that before tapping, not after.
        var hasData: Bool {
            switch self {
            case .wealth: true
            case .spendingAbroad, .travel: false
            }
        }
    }

    let snapshot: FinanceDisplaySnapshot
    let onOpenConnections: (() -> Void)?
    @Binding var selectedRange: FinanceRange
    @Binding var selectedNetWorthPoint: String?
    let initialEntry: Entry?
    /// `nil` under Reduce Motion — see `FinanceHeroMorphTag`.
    let heroNamespace: Namespace.ID?
    let onClose: () -> Void

    @State private var selectedEntry: Entry?

    init(
        snapshot: FinanceDisplaySnapshot,
        onOpenConnections: (() -> Void)?,
        selectedRange: Binding<FinanceRange>,
        selectedNetWorthPoint: Binding<String?>,
        initialEntry: Entry?,
        heroNamespace: Namespace.ID?,
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.onOpenConnections = onOpenConnections
        _selectedRange = selectedRange
        _selectedNetWorthPoint = selectedNetWorthPoint
        self.initialEntry = initialEntry
        self.heroNamespace = heroNamespace
        self.onClose = onClose
        _selectedEntry = State(initialValue: initialEntry)
    }

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: 16, bottomPadding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let selectedEntry {
                        detailContent(for: selectedEntry)
                    } else {
                        entryList
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .onChange(of: initialEntry) { _, entry in
            selectedEntry = entry
        }
        .accessibilityIdentifier("finance-analytics")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                if selectedEntry != nil {
                    selectedEntry = nil
                } else {
                    onClose()
                }
            } label: {
                LifeOSIcon(.chevronLeft)
                    .frame(width: 18, height: 18)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectedEntry == nil ? "Back to Finance" : "Back to Analytics and Tools")
            .accessibilityIdentifier("finance-analytics-back")

            VStack(alignment: .leading, spacing: 1) {
                Text(selectedEntry?.title ?? "Analytics & Tools")
                    .lifeOSTypography(.pageTitle)
                    .tracking(-0.5)
                    .modifier(FinanceHeroMorphTag(id: "finance-analytics-hero", namespace: selectedEntry == nil ? heroNamespace : nil))
                Text(selectedEntry?.subtitle ?? "Wealth, spending abroad, and travel")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
            Spacer(minLength: 6)
        }
        .accessibilityElement(children: .combine)
    }

    private var entryList: some View {
        VStack(spacing: 10) {
            ForEach(Entry.allCases) { entry in
                Button {
                    selectedEntry = entry
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        LifeOSIcon(entry.icon)
                            .foregroundStyle(LifeOSTokens.Module.finance)
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .lifeOSTypography(.button)
                            Text(entry.subtitle)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                        Spacer(minLength: 8)
                        if !entry.hasData {
                            Text("Unavailable")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(LifeOSTokens.tertiaryText.opacity(0.12), in: Capsule())
                        }
                        LifeOSIcon(.chevronRight)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .frame(width: 12, height: 12)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .flatCard()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("finance-analytics-entry-\(entry.rawValue)")
                .accessibilityLabel(entry.hasData ? entry.title : "\(entry.title), unavailable")
                .accessibilityHint(entry.subtitle)
            }
        }
    }

    @ViewBuilder
    private func detailContent(for entry: Entry) -> some View {
        switch entry {
        case .wealth:
            wealthDetail
        case .spendingAbroad:
            FinanceEmptyModuleRow(
                icon: entry.icon,
                title: "Spending abroad unavailable",
                detail: "Foreign-currency transactions are not imported: the statement importer accepts EUR rows only, so there is no foreign-currency spending to break down here. This is a deliberate data-source limit, not a bug.",
                actionTitle: onOpenConnections == nil ? nil : "Manage connections",
                action: onOpenConnections
            )
            .padding(.vertical, 4)
            .accessibilityIdentifier("finance-analytics-spending-abroad")
        case .travel:
            FinanceEmptyModuleRow(
                icon: entry.icon,
                title: "Travel unavailable",
                detail: "No country or foreign-currency data is ingested by Finance, so trips and travel spending can't be shown. Adding trip or country tracking is a product decision this surface doesn't make on its own.",
                actionTitle: onOpenConnections == nil ? nil : "Manage connections",
                action: onOpenConnections
            )
            .padding(.vertical, 4)
            .accessibilityIdentifier("finance-analytics-travel")
        }
    }

    private var wealthDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            FinanceWealthCard(snapshot: snapshot, onOpenConnections: onOpenConnections)
            VStack(alignment: .leading, spacing: 12) {
                FinanceSectionHeader(
                    title: "Net worth",
                    subtitle: "Balance trend and estimate",
                    icon: .netWorth,
                    accent: LifeOSTokens.Module.finance
                )
                FinanceRangePills(
                    selection: $selectedRange,
                    availableRanges: snapshot.availableRanges(for: .netWorth)
                )
                FinanceDetailChartCard(
                    title: "Net worth",
                    subtitle: "Balance trend",
                    metric: snapshot.netWorth,
                    points: snapshot.points(for: .netWorth, range: selectedRange),
                    selectedPoint: $selectedNetWorthPoint,
                    isDemo: snapshot.isDemo,
                    availabilityIdentity: "wealth|\(selectedRange.rawValue)",
                    chartState: snapshot.chartState(for: .netWorth, range: selectedRange),
                    emptyDetail: "Net-worth history is not available from the current Finance contract.",
                    showMaxAction: selectedRange == .max ? nil : { selectedRange = .max },
                    projection: Self.wealthProjection(from: snapshot.netWorthPoints)
                )
            }
        }
    }

    /// Mirrors `FinanceView.wealthProjection(from:)` exactly: a linear
    /// projection derived only from real observed points via
    /// `FinanceWealthProjector`, the trusted boundary for what counts as an
    /// "estimate". Duplicated rather than exposed from `FinanceView` to avoid
    /// widening that type's private surface for a two-line helper.
    private static func wealthProjection(from points: [FinanceChartPoint]) -> FinanceWealthProjectionResult {
        let observations = points.map { FinanceWealthObservationPoint(date: $0.date, valueCents: $0.value) }
        return FinanceWealthProjector.project(observations: observations, horizonDays: 90)
    }
}
