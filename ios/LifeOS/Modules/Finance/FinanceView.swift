import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Public route values used by callers that open a specific Finance detail.
public enum FinanceDetailRoute: String, CaseIterable, Hashable, Sendable {
    case spend
    case income
    case cashFlow
    case netWorth
}

// MARK: - Finance screen contract

/// Finance is intentionally a view over injected observations. The native app does not
/// manufacture balances when the gateway has not supplied them. Pass `usesVisualFixtures: true`
/// only from a visual-review entry point; that path is labelled throughout the screen.
public struct FinanceView: View {
    private let summary: FinanceSummary?
    private let transactions: [FinanceTransactionObservation]?
    private let usesVisualFixtures: Bool
    private let initialDetail: FinanceDetailRoute?
    private let onOpenConnections: (() -> Void)?
    private let onRefresh: (() async -> Void)?
    private let requestedObservationState: FinanceObservationState?
    private let financeErrorMessage: String?

    @State private var selectedDetail: FinanceDetail = .spend
    @State private var selectedRange: FinanceRange = .month
    @State private var selectedSpendPoint: String?
    @State private var selectedIncomePoint: String?
    @State private var selectedCashFlowPoint: String?
    @State private var selectedNetWorthPoint: String?
    @State private var selectedCategoryID: String?
    @State private var selectedCategorySource: String?
    @State private var selectedIncomeCategoryID: String?
    @State private var isRefreshing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A small public route value keeps deep-link callers independent from the private
    /// chart-selection model used by the view.
    public init(
        summary: FinanceSummary? = nil,
        transactions: [FinanceTransactionObservation]? = nil,
        usesVisualFixtures: Bool = false,
        initialDetail: FinanceDetailRoute? = nil,
        onOpenConnections: (() -> Void)? = nil,
        onRefresh: (() async -> Void)? = nil,
        observationState: FinanceObservationState? = nil,
        errorMessage: String? = nil
    ) {
        self.summary = summary
        self.transactions = transactions
        self.usesVisualFixtures = usesVisualFixtures
        self.initialDetail = initialDetail
        self.onOpenConnections = onOpenConnections
        self.onRefresh = onRefresh
        self.requestedObservationState = observationState
        self.financeErrorMessage = errorMessage
        switch initialDetail {
        case .income: _selectedDetail = State(initialValue: .income)
        case .cashFlow: _selectedDetail = State(initialValue: .cashFlow)
        case .netWorth: _selectedDetail = State(initialValue: .netWorth)
        case .spend, nil: _selectedDetail = State(initialValue: .spend)
        }
    }

    public var body: some View {
        let snapshot = FinanceDisplaySnapshot(
            summary: summary,
            transactions: transactions,
            usesVisualFixtures: usesVisualFixtures,
            observationState: requestedObservationState ?? (summary == nil && onRefresh != nil ? .loading : nil),
            errorMessage: financeErrorMessage
        )

        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: 16, bottomPadding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    financeHeader(snapshot: snapshot)
                    FinanceStateNotice(snapshot: snapshot, onRefresh: onRefresh)
                    FinanceHeroCard(snapshot: snapshot)

                    financeDetailAndCategories(snapshot: snapshot)

                    financeMetricGrid(snapshot: snapshot)
                    FinanceWealthCard(snapshot: snapshot)
                    FinanceAccountsCard(snapshot: snapshot, onOpenConnections: onOpenConnections)
                    FinanceImportCard()
                }
            }

        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .onAppear {
            selectLatestPoints(in: snapshot)
        }
        .task {
            guard !usesVisualFixtures, summary == nil, let onRefresh else { return }
            await refresh(using: onRefresh)
        }
        .onChange(of: selectedRange) { _, _ in
            selectLatestPoints(in: snapshot)
        }
        .onChange(of: initialDetail) { _, route in
            let requestedDetail = detail(for: route)
            guard selectedDetail != requestedDetail else { return }
            if reduceMotion {
                selectedDetail = requestedDetail
            } else {
                withAnimation(LifeOSMotion.snappy) {
                    selectedDetail = requestedDetail
                }
            }
            selectLatestPoints(in: snapshot)
        }
        .accessibilityIdentifier("finance-view")
    }

    private func financeHeader(snapshot: FinanceDisplaySnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            LifeOSIcon(.finance)
                .foregroundStyle(LifeOSTokens.Module.finance)
                .frame(width: 21, height: 21)

            VStack(alignment: .leading, spacing: 1) {
                Text("Finance")
                    .font(LifeOSFont.display())
                    .tracking(-0.5)
                Text("Private overview")
                    .font(LifeOSFont.metadata())
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }

            Spacer(minLength: 6)

            if let onRefresh {
                Button {
                    Task { await refresh(using: onRefresh) }
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            LifeOSIcon(.refresh)
                                .frame(width: 15, height: 15)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh finance summary")
                .accessibilityIdentifier("finance-refresh")
            }

            FinanceStatusBadge(snapshot: snapshot)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finance")
        .accessibilityValue(snapshot.accessibilityStatus)
    }

    @MainActor
    private func refresh(using action: @escaping () async -> Void) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await action()
        isRefreshing = false
    }

    @ViewBuilder
    private func financeDetailAndCategories(snapshot: FinanceDisplaySnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                financeDetailPanel(snapshot: snapshot)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                FinanceCategoriesCard(
                    snapshot: snapshot,
                    selectedCategoryID: $selectedCategoryID,
                    selectedSourceID: $selectedCategorySource,
                    selectedIncomeCategoryID: $selectedIncomeCategoryID,
                    selectedRange: selectedRange
                )
                .frame(minWidth: 300, maxWidth: 390, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 16) {
                financeDetailPanel(snapshot: snapshot)
                FinanceCategoriesCard(
                    snapshot: snapshot,
                    selectedCategoryID: $selectedCategoryID,
                    selectedSourceID: $selectedCategorySource,
                    selectedIncomeCategoryID: $selectedIncomeCategoryID,
                    selectedRange: selectedRange
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func financeDetailPanel(snapshot: FinanceDisplaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FinanceSectionHeader(title: "Details", subtitle: "Trend context for this period", icon: .views, accent: LifeOSTokens.Module.finance)
            SpringPillSelector(
                options: FinanceDetail.allCases,
                selection: $selectedDetail
            ) { detail, isSelected in
                Text(detail.title)
                    .font(LifeOSFont.metadata().weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : LifeOSTokens.tertiaryText)
                    .frame(maxWidth: .infinity)
            }
            .padding(4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(LifeOSTokens.hairlineBorder, lineWidth: 1))
            .accessibilityLabel("Finance detail")
            .accessibilityValue(selectedDetail.title)

            FinanceRangePills(
                selection: $selectedRange,
                availableRanges: snapshot.availableRanges(for: selectedDetail)
            )
            detailCard(snapshot: snapshot)
        }
    }

    private func financeMetricGrid(snapshot: FinanceDisplaySnapshot) -> some View {
        let columns: [GridItem] = {
#if os(macOS)
            Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: 4)
#else
            [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 12)]
#endif
        }()
        return LazyVGrid(
            columns: columns,
            spacing: 10
        ) {
            FinanceMetricCard(
                title: "Spent",
                value: snapshot.spent.valueText,
                detail: snapshot.spent.detail,
                icon: .spending,
                accent: LifeOSTokens.danger,
                progress: snapshot.spendProgress,
                isUnavailable: snapshot.spent.isUnavailable
            )
            FinanceMetricCard(
                title: "Cash flow",
                value: snapshot.cashFlow.valueText,
                detail: snapshot.cashFlow.detail,
                icon: .cashFlow,
                accent: LifeOSTokens.Module.business,
                progress: snapshot.cashFlow.progress,
                isUnavailable: snapshot.cashFlow.isUnavailable
            )
            FinanceMetricCard(
                title: "Income",
                value: snapshot.income.valueText,
                detail: snapshot.income.detail,
                icon: .income,
                accent: LifeOSTokens.success,
                progress: nil,
                isUnavailable: snapshot.income.isUnavailable
            )
            FinanceMetricCard(
                title: "Saved",
                value: snapshot.saved.valueText,
                detail: snapshot.saved.detail,
                icon: .savings,
                accent: LifeOSTokens.success,
                progress: snapshot.savingsProgress,
                isUnavailable: snapshot.saved.isUnavailable
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailCard(snapshot: FinanceDisplaySnapshot) -> some View {
        switch selectedDetail {
        case .spend:
            FinanceDetailChartCard(
                title: "Spend",
                subtitle: "Across connected accounts",
                metric: snapshot.spent,
                points: snapshot.points(for: .spend, range: selectedRange),
                selectedPoint: $selectedSpendPoint,
                isDemo: snapshot.isDemo,
                emptyDetail: "Spend history will appear after a reviewed account connection is available."
            )
        case .income:
            FinanceDetailChartCard(
                title: "Income",
                subtitle: "Deposits across connected accounts",
                metric: snapshot.income,
                points: snapshot.points(for: .income, range: selectedRange),
                selectedPoint: $selectedIncomePoint,
                isDemo: snapshot.isDemo,
                emptyDetail: "Income history will appear after a reviewed account connection is available."
            )
        case .cashFlow:
            FinanceDetailChartCard(
                title: "Cash flow",
                subtitle: "Money in minus money out",
                metric: snapshot.cashFlow,
                points: snapshot.points(for: .cashFlow, range: selectedRange),
                selectedPoint: $selectedCashFlowPoint,
                isDemo: snapshot.isDemo,
                emptyDetail: "Cash-flow history needs a connected source with transaction history."
            )
        case .netWorth:
            FinanceDetailChartCard(
                title: "Net worth",
                subtitle: "Balance trend",
                metric: snapshot.netWorth,
                points: snapshot.points(for: .netWorth, range: selectedRange),
                selectedPoint: $selectedNetWorthPoint,
                isDemo: snapshot.isDemo,
                emptyDetail: "Net-worth history is not available from the current Finance contract."
            )
        }
    }

    private func selectLatestPoints(in snapshot: FinanceDisplaySnapshot) {
        selectedSpendPoint = snapshot.points(for: .spend, range: selectedRange).last?.id
        selectedIncomePoint = snapshot.points(for: .income, range: selectedRange).last?.id
        selectedCashFlowPoint = snapshot.points(for: .cashFlow, range: selectedRange).last?.id
        selectedNetWorthPoint = snapshot.points(for: .netWorth, range: selectedRange).last?.id
    }

    private func detail(for route: FinanceDetailRoute?) -> FinanceDetail {
        switch route {
        case .income: .income
        case .cashFlow: .cashFlow
        case .netWorth: .netWorth
        case .spend, nil: .spend
        }
    }

    /// A small, data-only acceptance seam for the production display model.
    /// It keeps account-only truth testable without exposing the private
    /// SwiftUI view hierarchy or any fixture-only entry point.
    internal static func displayTruth(
        summary: FinanceSummary?,
        transactions: [FinanceTransactionObservation]? = nil,
        usesVisualFixtures: Bool = false
    ) -> FinanceDisplayTruth {
        let snapshot = FinanceDisplaySnapshot(
            summary: summary,
            transactions: transactions,
            usesVisualFixtures: usesVisualFixtures
        )
        return FinanceDisplayTruth(
            statusLabel: snapshot.statusLabel,
            observationState: snapshot.observationState,
            sourceDisclosure: snapshot.sourceDisclosure,
            netWorthCents: snapshot.netWorth.cents,
            accountsCount: snapshot.accounts.count,
            hasObservedValue: snapshot.hasObservedValue,
            transactionTotalsAvailable: snapshot.transactionTotalsAvailable
        )
    }
}

internal struct FinanceDisplayTruth: Equatable {
    let statusLabel: String
    let observationState: FinanceObservationState
    let sourceDisclosure: String
    let netWorthCents: Int?
    let accountsCount: Int
    let hasObservedValue: Bool
    let transactionTotalsAvailable: Bool
}

// MARK: - Header and honest states

private struct FinanceStatusBadge: View {
    let snapshot: FinanceDisplaySnapshot

    var body: some View {
        // Status uses both an icon and text; color is only a supporting signal.
        HStack(spacing: 6) {
            LifeOSIcon(snapshot.statusIcon)
                .frame(width: 14, height: 14)
            Text(snapshot.statusLabel)
                .font(LifeOSFont.axis().weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(snapshot.statusColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finance data status")
        .accessibilityValue(snapshot.statusLabel)
    }
}

private struct FinanceStateNotice: View {
    let snapshot: FinanceDisplaySnapshot
    let onRefresh: (() async -> Void)?

    private var isVisible: Bool {
        snapshot.observationState != .observed && snapshot.observationState != .demo
    }

    private var accent: Color {
        switch snapshot.observationState {
        case .error: LifeOSTokens.danger
        case .partial, .stale, .loading: LifeOSTokens.warning
        case .unavailable: LifeOSTokens.tertiaryText
        case .observed, .demo: LifeOSTokens.success
        }
    }

    private var title: String {
        switch snapshot.observationState {
        case .loading: "Loading Finance data"
        case .partial: "Some Finance data is unavailable"
        case .stale: "Finance data may be out of date"
        case .error: "Finance refresh failed"
        case .unavailable: "Finance data unavailable"
        case .observed, .demo: ""
        }
    }

    private var detail: String {
        if let errorMessage = snapshot.errorMessage,
           !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return errorMessage
        }
        switch snapshot.observationState {
        case .loading: return "Waiting for an authorized source response."
        case .partial: return "Only explicitly observed values are shown; missing values are not treated as zero."
        case .stale: return "The displayed values remain source-backed, but the source needs a refresh."
        case .error: return "The last source-backed values remain visible where available."
        case .unavailable: return "Connect an authorized source to show account and transaction values."
        case .observed, .demo: return ""
        }
    }

    @ViewBuilder
    var body: some View {
        if isVisible {
            HStack(alignment: .top, spacing: 10) {
                LifeOSIcon(snapshot.statusIcon)
                    .foregroundStyle(accent)
                    .frame(width: 17, height: 17)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(LifeOSFont.control().weight(.semibold))
                        .foregroundStyle(LifeOSTokens.primaryText)
                    Text(detail)
                        .font(LifeOSFont.axis())
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let onRefresh {
                    Button("Retry") {
                        Task { await onRefresh() }
                    }
                    .font(LifeOSFont.axis().weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(accent)
                    .accessibilityLabel("Retry Finance refresh")
                }
            }
            .padding(12)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accent.opacity(0.24), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(detail)
            .accessibilityIdentifier("finance-state-notice")
        }
    }
}

private struct FinanceHeroCard: View {
    let snapshot: FinanceDisplaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Net worth")
                        .font(LifeOSFont.overline())
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                    Text(snapshot.netWorth.valueText)
                        .font(LifeOSFont.kpi())
                        .tracking(-0.3)
                        .numericTransition()
                    Text(snapshot.netWorth.detail)
                        .font(LifeOSFont.metadata())
                        .foregroundStyle(snapshot.netWorth.isUnavailable ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                }

                Spacer(minLength: 10)

                if snapshot.netWorth.isUnavailable {
                    UnavailableMetricMark(label: "Not available")
                } else {
                    FinanceMiniSparkline(points: snapshot.netWorthPoints)
                        .frame(width: 132, height: 62)
                }
            }

            HStack(spacing: 0) {
                FinanceHeroFact(title: "Accounts", value: snapshot.accounts.isEmpty ? "Not available" : "\(snapshot.accounts.count) connected")
                Divider().frame(height: 28)
                FinanceHeroFact(title: "Updated", value: snapshot.updatedLabel)
                Divider().frame(height: 28)
                FinanceHeroFact(title: "Currency", value: "EUR")
            }

            Text(snapshot.sourceDisclosure)
                .font(LifeOSFont.axis())
                .foregroundStyle(snapshot.isDemo ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Finance source and freshness")
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard(featured: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Net worth")
        .accessibilityValue("\(snapshot.netWorth.accessibilityValue). Accounts \(snapshot.accounts.isEmpty ? "not available" : "\(snapshot.accounts.count) connected"). Updated \(snapshot.updatedLabel).")
    }
}

private struct FinanceHeroFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(LifeOSFont.axis())
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(value)
                .font(LifeOSFont.control())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

private struct UnavailableMetricMark: View {
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            Text("—")
                .font(LifeOSFont.kpi(32))
                .tracking(-0.3)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(label)
                .font(LifeOSFont.axis())
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }
}

private struct FinanceWealthCard: View {
    let snapshot: FinanceDisplaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FinanceSectionHeader(
                title: "Wealth & investments",
                subtitle: "Explicit holdings source only",
                icon: .investments,
                accent: LifeOSTokens.Module.finance
            )
            if let wealth = snapshot.wealth, wealth.availability == .observed {
                if let valueCents = wealth.observedValueCents {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(FinanceCurrencyFormatter.euro(cents: valueCents))
                                .font(LifeOSFont.kpi(28).monospacedDigit())
                            Text("Observed EUR holdings value · \(wealth.holdings?.count ?? 0) rows")
                                .font(LifeOSFont.axis())
                                .foregroundStyle(LifeOSTokens.secondaryText)
                        }
                        Spacer(minLength: 12)
                        LifeOSIcon(.investments)
                            .foregroundStyle(LifeOSTokens.Module.finance)
                            .frame(width: 22, height: 22)
                    }
                } else {
                    FinanceEmptyModuleRow(
                        icon: .investments,
                        title: "Holdings value unavailable",
                        detail: "No observed EUR holding values were supplied. Non-EUR rows remain visible without conversion."
                    )
                }
                if let holdings = wealth.holdings, !holdings.isEmpty {
                    Divider()
                        .overlay(LifeOSTokens.hairlineBorder)
                    VStack(spacing: 0) {
                        ForEach(holdings, id: \.id) { holding in
                            FinanceHoldingRow(holding: holding)
                            if holding.id != holdings.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
                Text("Separate from bank-account net worth. Investment orders and bank transactions never infer a holding value.")
                    .font(LifeOSFont.axis())
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(FinanceSourceLabel.display(wealth.provenance.source)) · \(FinanceFreshnessLabel.text(wealth.provenance.freshness))")
                    .font(LifeOSFont.axis())
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            } else {
                FinanceEmptyModuleRow(
                    icon: .investments,
                    title: "Wealth unavailable",
                    detail: "No EUR holdings observation was supplied. Bank transactions and account balances are not used to estimate investments."
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-wealth")
    }
}

private struct FinanceHoldingRow: View {
    let holding: FinanceHoldingObservation

    private var subtitle: String {
        let descriptors = [holding.symbol, holding.assetClass, holding.currency]
            .compactMap { $0 }
        return descriptors.isEmpty ? FinanceSourceLabel.display(holding.source) : descriptors.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            LifeOSIcon(.investments)
                .foregroundStyle(holding.availability == .observed ? LifeOSTokens.Module.finance : LifeOSTokens.warning)
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(holding.name)
                    .font(LifeOSFont.callout().weight(.semibold))
                Text(subtitle)
                    .font(LifeOSFont.axis())
                    .foregroundStyle(holding.availability == .observed ? LifeOSTokens.tertiaryText : LifeOSTokens.warning)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if holding.availability == .observed,
               holding.currency == "EUR",
               let valueCents = holding.valueCents {
                Text(FinanceCurrencyFormatter.euro(cents: valueCents))
                    .font(LifeOSFont.control().monospacedDigit())
                    .foregroundStyle(LifeOSTokens.primaryText)
            } else {
                Text("Value unavailable")
                    .font(LifeOSFont.axis())
                    .foregroundStyle(LifeOSTokens.warning)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(holding.name)
        .accessibilityValue(holding.availability == .observed && holding.currency == "EUR" && holding.valueCents != nil
                            ? "\(FinanceCurrencyFormatter.euro(cents: holding.valueCents ?? 0)), \(subtitle)"
                            : "Value unavailable, \(subtitle)")
    }
}

// MARK: - Metric cards

private struct FinanceMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: LifeOSIconName
    let accent: Color
    let progress: Double?
    let isUnavailable: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LifeOSIcon(icon)
                    .foregroundStyle(accent)
                    .frame(width: 17, height: 17)
                    .frame(width: 34, height: 34)
                Spacer()
                if let progress {
                    Circle()
                        .trim(from: 0, to: animatedProgress)
                        .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 23, height: 23)
                        .rotationEffect(.degrees(-90))
                        .accessibilityHidden(true)
                        .task(id: "\(progress)-\(reduceMotion)") {
                            let target = min(max(progress, 0), 1)
                            if reduceMotion {
                                animatedProgress = target
                            } else {
                                withAnimation(LifeOSMotion.ringReveal) { animatedProgress = target }
                            }
                        }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LifeOSFont.metadata())
                    .foregroundStyle(LifeOSTokens.secondaryText)
                Text(value)
                    .font(LifeOSFont.inter(17, weight: .semiBold).monospacedDigit())
                    .foregroundStyle(isUnavailable ? LifeOSTokens.tertiaryText : LifeOSTokens.primaryText)
                    .numericTransition()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail)
                    .font(LifeOSFont.axis())
                    .foregroundStyle(isUnavailable ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .overlay(alignment: .topLeading) {
            Capsule()
                .fill(accent)
                .frame(width: 34, height: 3)
                .padding(.leading, 14)
                .padding(.top, 1)
                .accessibilityHidden(true)
        }
        .flatCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value). \(detail)")
    }
}

// MARK: - Detail charts

private struct FinanceDetailChartCard: View {
    let title: String
    let subtitle: String
    let metric: FinanceDisplayMetric
    let points: [FinanceChartPoint]
    @Binding var selectedPoint: String?
    let isDemo: Bool
    let emptyDetail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(LifeOSFont.cardTitle())
                    Text(subtitle)
                        .font(LifeOSFont.axis())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 10)
                Text(metric.valueText)
                    .font(LifeOSFont.inter(17, weight: .semiBold).monospacedDigit())
                    .numericTransition()
            }

            if points.isEmpty {
                FinanceUnavailableChart(detail: emptyDetail)
            } else {
                FinanceLineChart(
                    points: points,
                    selectedPoint: $selectedPoint,
                    isDemo: isDemo
                )
                FinanceChartSelectionDetail(
                    points: points,
                    selectedPoint: $selectedPoint,
                    isDemo: isDemo
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-detail-chart-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

private struct FinanceUnavailableChart: View {
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(LifeOSTokens.primaryText.opacity(0.10))
                .frame(height: 1)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(LifeOSTokens.primaryText.opacity(0.18))
                        .frame(width: 58, height: 2)
                }
            HStack(spacing: 8) {
                LifeOSIcon(.security)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 15, height: 15)
                Text("Not available")
                    .font(LifeOSFont.control())
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Text(detail)
                .font(LifeOSFont.axis())
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chart not available")
        .accessibilityValue(detail)
    }
}

/// The chart is embedded in the Finance route's vertical `ScrollView`. A chart drag
/// must therefore be classified before it changes the selected point: a primarily
/// vertical gesture belongs to the parent scroll view, while a primarily horizontal
/// gesture belongs to chart scrubbing. Keeping this classifier independent of SwiftUI
/// makes the boundary easy to regression-test without relying on simulator gesture
/// timing.
enum FinanceChartGestureAxis: Equatable {
    case undecided
    case horizontal
    case vertical
    case ambiguous
}

enum FinanceChartGestureClassifier {
    /// Translation must clear this distance before a touch is considered a directional
    /// drag. Below it, the recognizer remains unresolved and the separate tap path
    /// handles point selection.
    static let directionThreshold: CGFloat = 8

    /// A direction needs a modest 15% dominance over the other axis. Near-diagonal
    /// movement remains ambiguous so it cannot churn chart selection while a user is
    /// trying to move the surrounding page.
    static let dominanceRatio: CGFloat = 1.15

    static func axis(
        for translation: CGSize,
        threshold: CGFloat = FinanceChartGestureClassifier.directionThreshold,
        dominanceRatio: CGFloat = FinanceChartGestureClassifier.dominanceRatio
    ) -> FinanceChartGestureAxis {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard max(horizontal, vertical) >= threshold else { return .undecided }

        if horizontal >= vertical * dominanceRatio {
            return .horizontal
        }
        if vertical >= horizontal * dominanceRatio {
            return .vertical
        }
        return .ambiguous
    }
}

#if os(iOS)
/// UIKit's directional failure decision is important here: SwiftUI's child
/// `DragGesture` can still starve the enclosing `UIScrollView` even when marked
/// simultaneous. This recognizer fails before beginning for vertical movement,
/// so the ancestor's native pan recognizer receives the same touch sequence.
private struct FinanceDirectionalScrubOverlay: UIViewRepresentable {
    let onTap: (CGFloat) -> Void
    let onChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onChanged: onChanged)
    }

    func makeUIView(context: Context) -> FinanceDirectionalScrubView {
        let view = FinanceDirectionalScrubView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.scrubPan = pan
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: FinanceDirectionalScrubView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onChanged = onChanged
        view.installScrollFailureRelationshipIfNeeded()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (CGFloat) -> Void
        var onChanged: (CGFloat) -> Void

        init(onTap: @escaping (CGFloat) -> Void, onChanged: @escaping (CGFloat) -> Void) {
            self.onTap = onTap
            self.onChanged = onChanged
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            onTap(recognizer.location(in: view).x)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            onChanged(recognizer.location(in: view).x)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // The same delegate owns the tap recognizer; it should always be
            // allowed to begin. Directional arbitration applies only to the pan.
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return true }
            let translation = pan.translation(in: view)
            return FinanceChartGestureClassifier.axis(
                for: CGSize(width: translation.x, height: translation.y)
            ) == .horizontal
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The explicit failure relationship below makes horizontal scrubbing
            // win when the ancestor is a UIScrollView. Keep the fallback permissive
            // for SwiftUI wrappers that do not expose that relationship in time;
            // vertical motion still fails this recognizer before it begins.
            otherGestureRecognizer.view is UIScrollView
        }
    }
}

private final class FinanceDirectionalScrubView: UIView {
    weak var scrubPan: UIPanGestureRecognizer?
    private weak var attachedScrollView: UIScrollView?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        installScrollFailureRelationshipIfNeeded()
    }

    func installScrollFailureRelationshipIfNeeded() {
        guard let scrubPan else { return }

        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                guard attachedScrollView !== scrollView else { return }
                // The native scroll waits for direction arbitration. A vertical
                // gesture makes scrubPan fail at 8pt, then the scroll can begin;
                // a horizontal gesture starts scrubPan and leaves the parent failed.
                scrollView.panGestureRecognizer.require(toFail: scrubPan)
                attachedScrollView = scrollView
                return
            }
            ancestor = current.superview
        }
    }
}
#endif

private struct FinanceLineChart: View {
    let points: [FinanceChartPoint]
    @Binding var selectedPoint: String?
    let isDemo: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @FocusState private var chartIsFocused: Bool

    private var chartDatasetID: String {
        points
            .map { "\($0.id):\($0.value)" }
            .joined(separator: "|")
    }

    private var selectedDatum: FinanceChartPoint? {
        guard let selectedPoint else { return nil }
        return points.first { $0.id == selectedPoint }
    }

    private var selectedIndex: Int? {
        guard let selectedPoint else { return nil }
        return points.firstIndex { $0.id == selectedPoint }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geometry = FinanceChartGeometry(points: points, size: size)

            ZStack(alignment: .topLeading) {
                FinanceChartGrid(zeroY: geometry.zeroY)

                geometry.smoothPath()
                    .trim(from: 0, to: drawn)
                    .stroke(
                        LifeOSTokens.Series.observed,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                if let selectedIndex, points.indices.contains(selectedIndex) {
                    let position = geometry.coordinate(for: selectedIndex)
                    Path { path in
                        path.move(to: CGPoint(x: position.x, y: 9))
                        path.addLine(to: CGPoint(x: position.x, y: size.height - 20))
                    }
                    .stroke(LifeOSTokens.metadataText, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    Circle()
                        .fill(LifeOSTokens.surface)
                        .overlay(Circle().stroke(LifeOSTokens.Series.observed, lineWidth: 2))
                        .frame(width: 10, height: 10)
                        .position(position)

                    ScrubBubble(
                        x: min(max(position.x, 44), size.width - 44),
                        y: position.y,
                        bounds: CGRect(origin: .zero, size: size)
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(points[selectedIndex].valueText)
                                .foregroundStyle(LifeOSTokens.primaryText)
                            Text(points[selectedIndex].dateLabel)
                                .font(LifeOSFont.axis())
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Text(isDemo ? "Demo · not live" : points[selectedIndex].sourceDisclosure)
                                .font(LifeOSFont.axis())
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
#if os(iOS)
            // SwiftUI DragGesture competes with the UIKit-backed ScrollView even
            // when attached through simultaneousGesture. A small UIKit recognizer
            // below fails before beginning for vertical/ambiguous movement, leaving
            // the native route scroll in charge; it begins only for horizontal scrub.
            .overlay(alignment: .topLeading) {
                FinanceDirectionalScrubOverlay(
                    onTap: { x in updateSelection(at: x, in: size) },
                    onChanged: { x in updateSelection(at: x, in: size) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            }
#else
            .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let index = nearestIndex(for: value.location.x, in: size)
                        let pointID = points[index].id
                        if selectedPoint != pointID {
                            ScrubBubble<EmptyView>.snapHaptic()
                        }
                        selectedPoint = pointID
                    }
            )
#endif
            .focusable(true)
            .focused($chartIsFocused)
#if os(macOS)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let index = nearestIndex(for: location.x, in: size)
                    let pointID = points[index].id
                    if selectedPoint != pointID {
                        ScrubBubble<EmptyView>.snapHaptic()
                    }
                    selectedPoint = pointID
                case .ended:
                    break
                }
            }
            .onMoveCommand { direction in
                guard !points.isEmpty else { return }
                let currentIndex = selectedIndex ?? points.count - 1
                switch direction {
                case .left:
                    selectedPoint = points[max(currentIndex - 1, 0)].id
                case .right:
                    selectedPoint = points[min(currentIndex + 1, points.count - 1)].id
                default:
                    break
                }
            }
#endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(points.first?.seriesTitle ?? "Finance") chart")
            .accessibilityValue(selectedDatum?.accessibilityValue ?? "Swipe to inspect values")
            .accessibilityHint("Swipe up or down to inspect adjacent data points.")
            .accessibilityAdjustableAction { direction in
                guard !points.isEmpty else { return }
                let currentIndex = selectedIndex ?? points.count - 1
                let nextIndex: Int
                switch direction {
                case .increment:
                    nextIndex = min(currentIndex + 1, points.count - 1)
                case .decrement:
                    nextIndex = max(currentIndex - 1, 0)
                @unknown default:
                    return
                }
                guard points.indices.contains(nextIndex) else { return }
                let pointID = points[nextIndex].id
                if selectedPoint != pointID {
                    ScrubBubble<EmptyView>.snapHaptic()
                    selectedPoint = pointID
                }
            }
            .task(id: chartDatasetID) {
                // The reveal belongs to the dataset, not to an unrelated parent redraw. Reset
                // before a replacement series arrives so a refreshed chart never reuses a stale
                // completed mask.
                drawn = 0
                if let selectedPoint, !points.contains(where: { $0.id == selectedPoint }) {
                    self.selectedPoint = nil
                }
                guard !reduceMotion else {
                    drawn = 1
                    return
                }
                withAnimation(LifeOSMotion.chartDraw) { drawn = 1 }
            }
        }
        .frame(height: 166)
    }

    private func nearestIndex(for x: CGFloat, in size: CGSize) -> Int {
        guard points.count > 1 else { return 0 }
        let horizontalInset: CGFloat = 10
        let width = max(size.width - horizontalInset * 2, 1)
        let fraction = min(max((x - horizontalInset) / width, 0), 1)
        guard let firstDate = points.first?.date, let lastDate = points.last?.date else { return 0 }
        let span = max(lastDate.timeIntervalSince(firstDate), 1)
        let targetDate = firstDate.addingTimeInterval(span * TimeInterval(fraction))
        return points.indices.min { left, right in
            abs(points[left].date.timeIntervalSince(targetDate))
                < abs(points[right].date.timeIntervalSince(targetDate))
        } ?? 0
    }

    private func updateSelection(at x: CGFloat, in size: CGSize) {
        let index = nearestIndex(for: x, in: size)
        let pointID = points[index].id
        if selectedPoint != pointID {
            ScrubBubble<EmptyView>.snapHaptic()
        }
        selectedPoint = pointID
    }
}

private struct FinanceChartGrid: View {
    let zeroY: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // §5.4: horizontal gridlines only — the chart hairline at 0.5pt,
                // with the zero baseline slightly stronger at 1pt.
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        Rectangle()
                            .fill(index == 2 ? LifeOSTokens.strongBorder : LifeOSTokens.chartGrid)
                            .frame(height: index == 2 ? 1 : 0.5)
                        if index < 2 { Spacer() }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 23)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: zeroY))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: zeroY))
                }
                .stroke(LifeOSTokens.hairlineBorder, lineWidth: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct FinanceChartGeometry {
    let points: [FinanceChartPoint]
    let size: CGSize

    private let horizontalInset: CGFloat = 10
    private let topInset: CGFloat = 12
    private let bottomInset: CGFloat = 23

    private var values: [Double] { points.map { Double($0.value) } }
    private var firstDate: Date { points.first?.date ?? .now }
    private var lastDate: Date { points.last?.date ?? firstDate }
    private var dateSpan: TimeInterval { max(lastDate.timeIntervalSince(firstDate), 1) }
    private var minimum: Double { min(values.min() ?? 0, 0) }
    private var maximum: Double { max(values.max() ?? 0, 0) }
    private var spread: Double { max(maximum - minimum, 1) }

    var zeroY: CGFloat { coordinate(for: 0).y }

    func coordinate(for index: Int, value: Double? = nil) -> CGPoint {
        let width = max(size.width - horizontalInset * 2, 1)
        let height = max(size.height - topInset - bottomInset, 1)
        let date = points.indices.contains(index) ? points[index].date : firstDate
        let fraction = min(max(date.timeIntervalSince(firstDate) / dateSpan, 0), 1)
        let x = horizontalInset + width * CGFloat(fraction)
        let rawValue = value ?? (points.indices.contains(index) ? Double(points[index].value) : 0)
        let normalized = min(max((rawValue - minimum) / spread, 0), 1)
        return CGPoint(x: x, y: topInset + height * (1 - CGFloat(normalized)))
    }

    func smoothPath() -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: coordinate(for: 0))
        appendSmoothSegments(to: &path)
        if points.count == 1 {
            path.addLine(to: coordinate(for: 0, value: Double(first.value)))
        }
        return path
    }

    func appendSmoothSegments(to path: inout Path) {
        guard points.count > 1 else { return }
        for index in 0..<(points.count - 1) {
            let previous = coordinate(for: max(index - 1, 0))
            let current = coordinate(for: index)
            let next = coordinate(for: index + 1)

            // A sparse bank history must retain its real time domain. Do not
            // imply an observed trend across an unobserved multi-day interval.
            if points[index + 1].date.timeIntervalSince(points[index].date) > 36 * 60 * 60 {
                path.move(to: next)
                continue
            }

            let following = coordinate(for: min(index + 2, points.count - 1))
            let control1 = CGPoint(
                x: current.x + (next.x - previous.x) / 6,
                y: clamped(
                    current.y + (next.y - previous.y) / 6,
                    lowerBound: min(current.y, next.y),
                    upperBound: max(current.y, next.y)
                )
            )
            let control2 = CGPoint(
                x: next.x - (following.x - current.x) / 6,
                y: clamped(
                    next.y - (following.y - current.y) / 6,
                    lowerBound: min(current.y, next.y),
                    upperBound: max(current.y, next.y)
                )
            )
            path.addCurve(to: next, control1: control1, control2: control2)
        }
    }

    private func clamped(_ value: CGFloat, lowerBound: CGFloat, upperBound: CGFloat) -> CGFloat {
        min(max(value, lowerBound), upperBound)
    }
}

private struct FinanceChartSelectionDetail: View {
    let points: [FinanceChartPoint]
    @Binding var selectedPoint: String?
    let isDemo: Bool

    private var point: FinanceChartPoint? {
        selectedPoint.flatMap { id in points.first { $0.id == id } } ?? points.last
    }

    var body: some View {
        if let point {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LifeOSTokens.Series.observed)
                    .frame(width: 4, height: 35)
                VStack(alignment: .leading, spacing: 3) {
                    Text(point.seriesTitle)
                        .font(LifeOSFont.axis().weight(.semibold))
                        .foregroundStyle(LifeOSTokens.primaryText)
                    Text(point.valueText)
                        .font(LifeOSFont.inter(17, weight: .semiBold).monospacedDigit())
                        .numericTransition()
                    Text("\(point.dateLabel) · \(isDemo ? "Demo · not live" : point.sourceDisclosure)")
                        .font(LifeOSFont.axis())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected \(point.seriesTitle) value")
            .accessibilityValue(point.accessibilityValue)
        }
    }
}

// MARK: - Accounts and categories

private struct FinanceAccountsCard: View {
    let snapshot: FinanceDisplaySnapshot
    let onOpenConnections: (() -> Void)?
    @State private var visibleAccountCount = FinancePagination.defaultPageSize

    private var accountPage: FinancePageDescriptor {
        FinancePageDescriptor(
            totalCount: snapshot.accounts.count,
            offset: 0,
            limit: visibleAccountCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            FinanceSectionHeader(title: "Accounts", subtitle: "Where your money is held", icon: .bankConnections, accent: LifeOSTokens.Module.finance)
            if snapshot.accounts.isEmpty {
                FinanceEmptyModuleRow(
                    icon: .bankConnections,
                    title: "No accounts connected",
                    detail: "Connect a reviewed bank source before account balances appear.",
                    actionTitle: onOpenConnections == nil ? nil : "Manage connections",
                    action: onOpenConnections
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.accounts.prefix(accountPage.endOffset)) { account in
                        FinanceAccountRow(account: account)
                        if account.id != snapshot.accounts.prefix(accountPage.endOffset).last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                if accountPage.totalCount > FinancePagination.defaultPageSize {
                    HStack {
                        Text("Showing \(accountPage.endOffset) of \(accountPage.totalCount)")
                            .font(LifeOSFont.axis())
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                        Spacer(minLength: 8)
                        if accountPage.hasNextPage {
                            Button("Show next \(min(FinancePagination.defaultPageSize, accountPage.totalCount - accountPage.endOffset))") {
                                visibleAccountCount = accountPage.endOffset + FinancePagination.defaultPageSize
                            }
                            .font(LifeOSFont.control())
                            .buttonStyle(.bordered)
                            .tint(LifeOSTokens.accent)
                        }
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Account pagination")
                    .accessibilityValue("Showing \(accountPage.endOffset) of \(accountPage.totalCount)")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-accounts")
        .task(id: snapshot.accounts.map(\.id).joined(separator: "|")) {
            visibleAccountCount = FinancePagination.defaultPageSize
        }
    }
}

private struct FinanceAccountRow: View {
    let account: FinanceAccount

    var body: some View {
        HStack(spacing: 12) {
            LifeOSIcon(account.icon)
                .foregroundStyle(account.isUnavailable ? LifeOSTokens.warning : LifeOSTokens.Module.finance)
                .frame(width: 18, height: 18)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(LifeOSFont.control())
                Text(account.detail)
                    .font(LifeOSFont.axis())
                    .foregroundStyle(account.isUnavailable ? LifeOSTokens.warning : LifeOSTokens.secondaryText)
            }
            Spacer(minLength: 8)
            if let balanceText = account.balanceText {
                Text(balanceText)
                    .font(LifeOSFont.cardTitle().monospacedDigit())
                    .foregroundStyle(LifeOSTokens.primaryText)
            } else {
                Text("Balance unavailable")
                    .font(LifeOSFont.metadata())
                    .foregroundStyle(LifeOSTokens.warning)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(account.name)
        .accessibilityValue("\(account.balanceText ?? "Balance unavailable"). \(account.detail)")
    }
}

private struct FinanceCategoriesCard: View {
    let snapshot: FinanceDisplaySnapshot
    @Binding var selectedCategoryID: String?
    @Binding var selectedSourceID: String?
    @Binding var selectedIncomeCategoryID: String?
    let selectedRange: FinanceRange
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleTransactionCount = FinancePagination.defaultPageSize
    @State private var visibleIncomeTransactionCount = FinancePagination.defaultPageSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FinanceSectionHeader(title: "By category", subtitle: "How spending is distributed", icon: .budget, accent: LifeOSTokens.danger)
            if snapshot.categories.isEmpty {
                FinanceEmptyModuleRow(
                    icon: .budget,
                    title: snapshot.hasTransactionSource ? "No categories in this period" : "Categories unavailable",
                    detail: snapshot.hasTransactionSource
                        ? "No spending transactions were supplied by the connected source."
                        : "Category totals appear once transaction history is connected."
                )
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        FinanceCategoryRing(categories: snapshot.categories)
                            .frame(width: 126, height: 126)
                        categoryLegend
                            .frame(minWidth: 176, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .center, spacing: 15) {
                        FinanceCategoryRing(categories: snapshot.categories)
                            .frame(width: 126, height: 126)
                        categoryLegend
                    }
                }

                if let selectedCategoryID,
                   let selectedCategory = snapshot.categories.first(where: { $0.id == selectedCategoryID }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(selectedCategory.name) transactions")
                                    .font(LifeOSFont.control())
                                let filteredTransactions = snapshot.filteredTransactions(
                                    category: selectedCategory.name,
                                    source: selectedSourceID,
                                    range: selectedRange
                                )
                                let filteredSpendCents = (try? FinanceTransactionTotals(transactions: filteredTransactions))?.spendingCents
                                let filteredSpendLabel = filteredSpendCents.map { FinanceCurrencyFormatter.euro(cents: $0) } ?? "Unavailable"
                                Text("\(filteredTransactions.count) · \(filteredSpendLabel) · \(selectedRange.accessibilityTitle)")
                                    .font(LifeOSFont.axis())
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                                    .monospacedDigit()
                                    .numericTransition()
                            }
                            Spacer(minLength: 8)
                            if selectedCategory.contributingSources.count > 1 {
                                Menu {
                                    Button("All sources") { selectedSourceID = nil }
                                    ForEach(selectedCategory.contributingSources, id: \.self) { source in
                                        Button(FinanceSourceLabel.display(source)) { selectedSourceID = source }
                                    }
                                } label: {
                            Text(selectedSourceID.map(FinanceSourceLabel.display) ?? "All sources")
                                .font(LifeOSFont.control())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                                }
                                .accessibilityLabel("Category source filter")
                                .accessibilityValue(selectedSourceID.map(FinanceSourceLabel.display) ?? "All sources")
                            }
                        }
                        let filteredTransactions = snapshot.filteredTransactions(
                            category: selectedCategory.name,
                            source: selectedSourceID,
                            range: selectedRange
                        )
                        if filteredTransactions.isEmpty {
                            FinanceEmptyModuleRow(
                                icon: .finance,
                                title: "No matching transactions",
                                detail: "Try another source or date range."
                            )
                        } else {
                            let transactionPage = FinancePageDescriptor(
                                totalCount: filteredTransactions.count,
                                offset: 0,
                                limit: visibleTransactionCount
                            )
                            ForEach(filteredTransactions.prefix(transactionPage.endOffset)) { transaction in
                                FinanceTransactionRow(transaction: transaction)
                            }
                            if transactionPage.totalCount > FinancePagination.defaultPageSize {
                                HStack {
                                    Text("Showing \(transactionPage.endOffset) of \(transactionPage.totalCount)")
                                        .font(LifeOSFont.axis())
                                        .foregroundStyle(LifeOSTokens.tertiaryText)
                                    Spacer(minLength: 8)
                                    if transactionPage.hasNextPage {
                                        Button("Show next \(min(FinancePagination.defaultPageSize, transactionPage.totalCount - transactionPage.endOffset))") {
                                            visibleTransactionCount = transactionPage.endOffset + FinancePagination.defaultPageSize
                                        }
                                        .font(LifeOSFont.control())
                                        .buttonStyle(.bordered)
                                        .tint(LifeOSTokens.accent)
                                    }
                                }
                                .padding(.top, 4)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Transaction pagination")
                                .accessibilityValue("Showing \(transactionPage.endOffset) of \(transactionPage.totalCount)")
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }

            if !snapshot.incomeCategories.isEmpty {
                Divider()
                    .overlay(LifeOSTokens.hairlineBorder)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Income by category")
                        .font(LifeOSFont.control())
                    Text("Source-backed deposits in this transaction history")
                        .font(LifeOSFont.axis())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 16) {
                            FinanceCategoryRing(categories: snapshot.incomeCategories, centerTitle: "Income")
                                .frame(width: 112, height: 112)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(snapshot.incomeCategories) { category in
                                    FinanceIncomeCategoryRow(
                                        category: category,
                                        isSelected: selectedIncomeCategoryID == category.id,
                                        action: { selectIncomeCategory(category.id) }
                                    )
                                }
                            }
                        }
                        VStack(alignment: .center, spacing: 12) {
                            FinanceCategoryRing(categories: snapshot.incomeCategories, centerTitle: "Income")
                                .frame(width: 112, height: 112)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(snapshot.incomeCategories) { category in
                                    FinanceIncomeCategoryRow(
                                        category: category,
                                        isSelected: selectedIncomeCategoryID == category.id,
                                        action: { selectIncomeCategory(category.id) }
                                    )
                                }
                            }
                        }
                    }
                    incomeDrilldown
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-categories")
        .task(id: "\(selectedCategoryID ?? "none")|\(selectedSourceID ?? "all")|\(selectedIncomeCategoryID ?? "none")|\(selectedRange.rawValue)|\(snapshot.transactions.map(\.id).joined(separator: "|"))") {
            visibleTransactionCount = FinancePagination.defaultPageSize
            visibleIncomeTransactionCount = FinancePagination.defaultPageSize
        }
    }

    @ViewBuilder
    private var categoryLegend: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(snapshot.categories) { category in
                Button {
                    selectCategory(category.id)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(category.hue.base)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name)
                                .font(LifeOSFont.axis().weight(.semibold))
                            Text("\(category.transactionCount) transaction\(category.transactionCount == 1 ? "" : "s") · \(category.sourceDisclosure)")
                                .font(LifeOSFont.axis())
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(category.amountText)
                                .font(LifeOSFont.axis().weight(.semibold))
                                .monospacedDigit()
                            Text("\(Int(category.fraction * 100))%")
                                .font(LifeOSFont.axis())
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .monospacedDigit()
                        }
                        if selectedCategoryID == category.id {
                            LifeOSIcon(.chevronRight)
                                .rotationEffect(.degrees(90))
                                .frame(width: 13, height: 13)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(category.name)
                .accessibilityValue("\(category.amountText), \(Int(category.fraction * 100)) percent, \(category.transactionCount) transactions, \(category.sourceDisclosure)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectCategory(_ categoryID: String) {
        let update = {
            if selectedCategoryID == categoryID {
                selectedCategoryID = nil
                selectedSourceID = nil
                visibleTransactionCount = FinancePagination.defaultPageSize
            } else {
                selectedCategoryID = categoryID
                selectedSourceID = nil
                visibleTransactionCount = FinancePagination.defaultPageSize
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(LifeOSMotion.snappy) { update() }
        }
    }

    @ViewBuilder
    private var incomeDrilldown: some View {
        if let selectedIncomeCategoryID,
           let selectedCategory = snapshot.incomeCategories.first(where: { $0.id == selectedIncomeCategoryID }) {
            Divider()
                .overlay(LifeOSTokens.hairlineBorder)
            let filteredTransactions = snapshot.filteredTransactions(
                category: selectedCategory.name,
                source: nil,
                range: selectedRange,
                incomeOnly: true
            )
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(selectedCategory.name) income")
                            .font(LifeOSFont.control())
                        let total = (try? FinanceTransactionTotals(transactions: filteredTransactions))?.incomeCents
                        Text("\(filteredTransactions.count) deposit\(filteredTransactions.count == 1 ? "" : "s") · \(total.map { FinanceCurrencyFormatter.euro(cents: $0) } ?? "Unavailable")")
                            .font(LifeOSFont.axis())
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Button("Clear") { selectIncomeCategory(selectedIncomeCategoryID) }
                        .font(LifeOSFont.axis())
                        .buttonStyle(.bordered)
                        .tint(LifeOSTokens.accent)
                }
                if filteredTransactions.isEmpty {
                    FinanceEmptyModuleRow(
                        icon: .income,
                        title: "No matching deposits",
                        detail: "This category has no transactions in the selected range."
                    )
                } else {
                    let transactionPage = FinancePageDescriptor(
                        totalCount: filteredTransactions.count,
                        offset: 0,
                        limit: visibleIncomeTransactionCount
                    )
                    ForEach(filteredTransactions.prefix(transactionPage.endOffset)) { transaction in
                        FinanceTransactionRow(transaction: transaction)
                    }
                    if transactionPage.totalCount > FinancePagination.defaultPageSize {
                        HStack {
                            Text("Showing \(transactionPage.endOffset) of \(transactionPage.totalCount)")
                                .font(LifeOSFont.axis())
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Spacer(minLength: 8)
                            if transactionPage.hasNextPage {
                                Button("Show next \(min(FinancePagination.defaultPageSize, transactionPage.totalCount - transactionPage.endOffset))") {
                                    visibleIncomeTransactionCount = transactionPage.endOffset + FinancePagination.defaultPageSize
                                }
                                .font(LifeOSFont.control())
                                .buttonStyle(.bordered)
                                .tint(LifeOSTokens.accent)
                            }
                        }
                        .padding(.top, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Income transaction pagination")
                        .accessibilityValue("Showing \(transactionPage.endOffset) of \(transactionPage.totalCount)")
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func selectIncomeCategory(_ categoryID: String) {
        let update = {
            selectedIncomeCategoryID = selectedIncomeCategoryID == categoryID ? nil : categoryID
            visibleIncomeTransactionCount = FinancePagination.defaultPageSize
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(LifeOSMotion.snappy) { update() }
        }
    }
}

private struct FinanceCategoryRing: View {
    let categories: [FinanceCategory]
    let centerTitle: String

    init(categories: [FinanceCategory], centerTitle: String = "Spend") {
        self.categories = categories
        self.centerTitle = centerTitle
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealProgress: Double = 0

    private var categoryID: String {
        categories.map { "\($0.id):\($0.fraction)" }.joined(separator: "|")
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(LifeOSTokens.Ring.track, lineWidth: 14)

            categoryArcs

            VStack(spacing: 1) {
                Text(centerTitle)
                    .font(LifeOSFont.metadata())
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Text("100%")
                    .font(LifeOSFont.cardTitle().monospacedDigit())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(centerTitle) category ring")
        .accessibilityValue(categories.map { "\($0.name) \(Int($0.fraction * 100)) percent" }.joined(separator: ", "))
        .task(id: "\(categoryID)-\(reduceMotion)") {
            if reduceMotion {
                revealProgress = 1
                return
            }

            revealProgress = 0
            withAnimation(LifeOSMotion.ringReveal) { revealProgress = 1 }

            do {
                try await Task.sleep(nanoseconds: 720_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
        }
    }

    /// The per-category arc segments, trimmed by `revealProgress` so the whole ring sweeps
    /// on together during the one-shot reveal rather than each segment appearing pre-drawn.
    /// Category hues are data semantics (sanctioned); strokes stay SOLID — no angular
    /// gradients (§2.4).
    private var categoryArcs: some View {
        ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
            let start = categories.prefix(index).reduce(0.0) { $0 + $1.fraction }
            let end = start + category.fraction
            let revealedEnd = start + (end - start) * revealProgress
            Circle()
                .trim(from: start + 0.006, to: max(revealedEnd - 0.006, start + 0.01))
                .stroke(
                    category.hue.base,
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct FinanceIncomeCategoryRow: View {
    let category: FinanceCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LifeOSIcon(.income)
                    .foregroundStyle(LifeOSTokens.success)
                    .frame(width: 15, height: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .font(LifeOSFont.axis().weight(.semibold))
                    Text("\(category.transactionCount) deposit\(category.transactionCount == 1 ? "" : "s") · \(category.sourceDisclosure)")
                        .font(LifeOSFont.axis())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 6)
                Text(category.amountText)
                    .font(LifeOSFont.axis().weight(.semibold).monospacedDigit())
                    .foregroundStyle(LifeOSTokens.success)
                LifeOSIcon(.chevronRight)
                    .rotationEffect(.degrees(isSelected ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .background(isSelected ? LifeOSTokens.success.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(category.name)
        .accessibilityValue("\(category.amountText), \(category.transactionCount) deposits, \(category.sourceDisclosure), \(isSelected ? "Selected" : "Select to inspect")")
    }
}

private struct FinanceTransactionRow: View {
    let transaction: FinanceTransactionObservation

    var body: some View {
        HStack(spacing: 10) {
            LifeOSIcon(transaction.isIncome ? .income : .spending)
                .foregroundStyle(transaction.isIncome ? LifeOSTokens.success : LifeOSTokens.danger)
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant)
                    .font(LifeOSFont.callout().weight(.semibold))
                Text("\(transaction.title) · \(transaction.account) · \(FinanceSourceLabel.display(transaction.source)) · \(FinanceFreshnessLabel.text(transaction.provenance.freshness))")
                    .font(LifeOSFont.axis())
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(FinanceCurrencyFormatter.signedEuro(cents: transaction.signedAmountCents))
                    .font(LifeOSFont.axis().weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(transaction.isIncome ? LifeOSTokens.success : LifeOSTokens.danger)
                Text(FinanceDateFormatter.timestamp(transaction.timestamp))
                    .font(LifeOSFont.axis())
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(transaction.merchant)
        .accessibilityValue("\(FinanceCurrencyFormatter.signedEuro(cents: transaction.signedAmountCents)), \(transaction.account), \(FinanceSourceLabel.display(transaction.source)), \(FinanceFreshnessLabel.text(transaction.provenance.freshness))")
    }
}

private struct FinanceEmptyModuleRow: View {
    let icon: LifeOSIconName
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: LifeOSIconName,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                LifeOSIcon(icon)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 21, height: 21)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(LifeOSFont.control())
                    Text(detail)
                        .font(LifeOSFont.axis())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(LifeOSFont.control())
                    .buttonStyle(.bordered)
                    .tint(LifeOSTokens.accent)
                    .accessibilityIdentifier("finance-open-connections")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

// MARK: - Range controls and reusable chrome

private struct FinanceRangePills: View {
    @Binding var selection: FinanceRange
    let availableRanges: Set<FinanceRange>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 3) {
            ForEach(FinanceRange.allCases, id: \.self) { range in
                let enabled = availableRanges.contains(range)
                Button {
                    guard enabled else { return }
                    if reduceMotion {
                        selection = range
                    } else {
                        withAnimation(LifeOSMotion.snappy) { selection = range }
                    }
                } label: {
                    Text(range.title)
                        .font(LifeOSFont.axis().weight(selection == range ? .semibold : .regular))
                        .foregroundStyle(selection == range ? .primary : (enabled ? LifeOSTokens.tertiaryText : LifeOSTokens.tertiaryText.opacity(0.42)))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selection == range {
                                Capsule()
                                    .fill(LifeOSTokens.surface)
                                    .overlay(Capsule().stroke(LifeOSTokens.hairlineBorder, lineWidth: 1))
                                    .matchedGeometryEffect(id: "finance.range.highlight", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(range.accessibilityTitle)
                .accessibilityValue(enabled ? (selection == range ? "Selected" : "Available") : "Needs more history")
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finance date range")
        .accessibilityValue(selection.accessibilityTitle)
    }
}

private struct FinanceSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: LifeOSIconName?
    let accent: Color

    init(title: String, subtitle: String, icon: LifeOSIconName? = nil, accent: Color = LifeOSTokens.Module.finance) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accent = accent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if let icon {
                LifeOSIcon(icon)
                    .foregroundStyle(accent)
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LifeOSFont.cardTitle())
                Text(subtitle)
                    .font(LifeOSFont.metadata())
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
        }
    }
}

private struct FinanceMiniSparkline: View {
    let points: [FinanceChartPoint]

    var body: some View {
        GeometryReader { proxy in
                let geometry = FinanceChartGeometry(points: points, size: proxy.size)
            geometry.smoothPath()
                .stroke(
                    LifeOSTokens.Series.observed,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Display models

private struct FinanceDisplaySnapshot {
    let isDemo: Bool
    let transactions: [FinanceTransactionObservation]
    let hasTransactionSource: Bool
    let transactionTotalsAvailable: Bool
    let netWorth: FinanceDisplayMetric
    let spent: FinanceDisplayMetric
    let spendBudget: FinanceDisplayMetric
    let cashFlow: FinanceDisplayMetric
    let income: FinanceDisplayMetric
    let fixedCosts: FinanceDisplayMetric
    let saved: FinanceDisplayMetric
    let savingsGoal: FinanceDisplayMetric
    let accounts: [FinanceAccount]
    let categories: [FinanceCategory]
    let incomeCategories: [FinanceCategory]
    let wealth: FinanceWealthSnapshot?
    let netWorthPoints: [FinanceChartPoint]
    let spendPoints: [FinanceChartPoint]
    let incomePoints: [FinanceChartPoint]
    let cashFlowPoints: [FinanceChartPoint]
    let updatedLabel: String
    let sourceDisclosure: String
    let overallFreshness: FinancePayloadFreshness
    let observationState: FinanceObservationState
    let errorMessage: String?

    init(
        summary: FinanceSummary?,
        transactions suppliedTransactions: [FinanceTransactionObservation]?,
        usesVisualFixtures: Bool,
        observationState requestedObservationState: FinanceObservationState? = nil,
        errorMessage: String? = nil
    ) {
        if usesVisualFixtures {
            self = .demo
            return
        }

        let transactionSourceAvailable = suppliedTransactions != nil
            || (summary?.transactions?.availability == .observed
                && summary?.transactions?.transactions != nil)
        let transactionRows = suppliedTransactions ?? summary?.transactions?.transactions ?? []
        let transactionTotals = transactionSourceAvailable
            ? try? FinanceTransactionTotals(transactions: transactionRows)
            : nil
        let accountRows = Self.accountRows(from: summary)
        let accountObservations = Self.usableObservedAccounts(from: summary)
        let observed = summary != nil && [
            summary?.monthlyIncomeCents,
            summary?.fixedCostsCents,
            summary?.spentCents,
            summary?.savedCents
        ].contains(where: { $0 != nil }) || transactionSourceAvailable
            || !accountRows.isEmpty
            || summary?.wealth?.observedValueCents != nil

        isDemo = false
        transactions = transactionRows
        hasTransactionSource = transactionSourceAvailable
        transactionTotalsAvailable = transactionTotals != nil
        spent = transactionTotals.map {
            FinanceDisplayMetric(cents: $0.spendingCents, detail: "\($0.transactionCount) transactions")
        } ?? FinanceDisplayMetric(cents: summary?.spentCents, detail: summary == nil ? "Not connected" : "Observed total")
        spendBudget = FinanceDisplayMetric(cents: summary?.spendableBudgetCents, detail: summary == nil ? "Not connected" : "Available budget")
        cashFlow = transactionTotals.map {
            FinanceDisplayMetric(
                cents: $0.netCashFlowCents,
                detail: "Income \(FinanceCurrencyFormatter.euro(cents: $0.incomeCents)) · Spend \(FinanceCurrencyFormatter.euro(cents: $0.spendingCents))"
            )
        } ?? .unavailable(summary == nil ? "Not connected" : "Not available")
        income = transactionTotals.map {
            FinanceDisplayMetric(
                cents: $0.incomeCents,
                detail: "\(transactionRows.filter(\.isIncome).count) deposits"
            )
        } ?? FinanceDisplayMetric(cents: summary?.monthlyIncomeCents, detail: summary == nil ? "Not connected" : "Observed total")
        fixedCosts = FinanceDisplayMetric(cents: summary?.fixedCostsCents, detail: summary == nil ? "Not connected" : "Observed total")
        saved = FinanceDisplayMetric(cents: summary?.savedCents, detail: summary == nil ? "Not connected" : "Observed total")
        savingsGoal = FinanceDisplayMetric(cents: summary?.savingsGoalCents, detail: summary == nil ? "Not connected" : "Savings goal")
        accounts = accountRows.map { observation in
            FinanceAccount(
                id: observation.id,
                name: observation.name,
                detail: observation.detail,
                balanceCents: observation.balanceCents,
                availability: observation.availability,
                icon: .bankConnections
            )
        }
        netWorth = Self.overflowCheckedAccountTotal(accountObservations).map {
            FinanceDisplayMetric(cents: $0, detail: "Observed account balances")
        } ?? .unavailable("Not available")
        categories = transactionTotals?.categoryObservations.map(FinanceCategory.init) ?? []
        incomeCategories = transactionTotals?.incomeCategoryObservations.map(FinanceCategory.init) ?? []
        wealth = summary?.wealth
        netWorthPoints = []
        spendPoints = transactionTotals.flatMap { _ in
            Self.transactionPoints(transactionRows, title: "Spend", series: .spending)
        } ?? []
        incomePoints = transactionTotals.flatMap { _ in
            Self.transactionPoints(transactionRows, title: "Income", series: .income)
        } ?? []
        cashFlowPoints = transactionTotals.flatMap { _ in
            Self.transactionPoints(transactionRows, title: "Cash flow", series: .cashFlow)
        } ?? []
        overallFreshness = Self.overallFreshness(
            summary: summary,
            transactionSourceAvailable: transactionSourceAvailable,
            transactionRows: transactionRows,
            accountObservations: accountObservations
        )
        observationState = requestedObservationState
            ?? summary?.financeAssessment(errorMessage: errorMessage).state
            ?? (suppliedTransactions == nil ? .unavailable : .observed)
        self.errorMessage = errorMessage
        updatedLabel = observed ? summary.map { FinanceDateFormatter.short($0.generatedAt) } ?? "Not available" : "Not available"
        let wealthSource: [String]
        if let wealth = summary?.wealth {
            wealthSource = [wealth.provenance.source]
        } else {
            wealthSource = []
        }
        let sourceIDs = Array(Set(transactionRows.map(\.source) + accountRows.map(\.source) + wealthSource)).sorted()
        if !sourceIDs.isEmpty {
            sourceDisclosure = "\(FinanceSourceLabel.join(sourceIDs)) · \(FinanceFreshnessLabel.text(overallFreshness)) · Updated \(updatedLabel)"
        } else if let metric = summary?.spent {
            sourceDisclosure = "\(FinanceSourceLabel.display(metric.provenance.source)) · \(FinanceFreshnessLabel.text(metric.provenance.freshness)) · Updated \(updatedLabel)"
        } else {
            sourceDisclosure = "No authorized source · Not available"
        }
    }

    private static let maximumFinanceCents = 9_007_199_254_740_991
    private static let financeStaleAfter: TimeInterval = 15 * 60

    private static func usableObservedAccounts(from summary: FinanceSummary?) -> [FinanceAccountObservation] {
        accountRows(from: summary).filter {
            $0.availability == .observed
                && $0.balanceCents != nil
                && isUsableObservedProvenance($0.provenance)
        }
    }

    private static func accountRows(from summary: FinanceSummary?) -> [FinanceAccountObservation] {
        guard let snapshot = summary?.accounts,
              snapshot.availability == .observed,
              isUsableObservedProvenance(snapshot.provenance),
              let accounts = snapshot.accounts,
              !accounts.isEmpty else {
            return []
        }
        return accounts
    }

    private static func overflowCheckedAccountTotal(_ accounts: [FinanceAccountObservation]) -> Int? {
        guard !accounts.isEmpty else { return nil }
        var total = 0
        for account in accounts {
            guard let balanceCents = account.balanceCents else { return nil }
            let (next, overflowed) = total.addingReportingOverflow(balanceCents)
            guard !overflowed,
                  next >= -maximumFinanceCents,
                  next <= maximumFinanceCents else {
                return nil
            }
            total = next
        }
        return total
    }

    private static func isUsableObservedProvenance(_ provenance: FinancePayloadProvenance) -> Bool {
        provenance.quality == .observed
            && provenance.freshness != .unknown
            && (provenance.connectorState == .healthy || provenance.connectorState == .refreshDue)
    }

    private static func overallFreshness(
        summary: FinanceSummary?,
        transactionSourceAvailable: Bool,
        transactionRows: [FinanceTransactionObservation],
        accountObservations: [FinanceAccountObservation]
    ) -> FinancePayloadFreshness {
        if let summary,
           Date.now.timeIntervalSince(summary.generatedAt) >= financeStaleAfter {
            return .stale
        }
        var provenances: [FinancePayloadProvenance] = []
        if transactionSourceAvailable {
            if let transactionProvenance = summary?.transactions?.provenance {
                provenances.append(transactionProvenance)
            }
            provenances.append(contentsOf: transactionRows.map(\.provenance))
        }
        if !accountObservations.isEmpty {
            if let accountProvenance = summary?.accounts?.provenance {
                provenances.append(accountProvenance)
            }
            provenances.append(contentsOf: accountObservations.map(\.provenance))
        }
        if let wealth = summary?.wealth, wealth.availability == .observed {
            provenances.append(wealth.provenance)
            provenances.append(contentsOf: (wealth.holdings ?? []).map(\.provenance))
        }
        if let summary {
            let metrics = [
                summary.monthlyIncome,
                summary.fixedCosts,
                summary.discretionaryBuffer,
                summary.spent,
                summary.savingsGoal,
                summary.saved
            ]
            provenances.append(contentsOf: metrics.compactMap { metric in
                guard metric.availability == .observed,
                      metric.amountCents != nil,
                      isUsableObservedProvenance(metric.provenance) else { return nil }
                return metric.provenance
            })
        }
        return FinanceFreshnessLabel.value(for: provenances)
    }

    private init(
        isDemo: Bool,
        transactions: [FinanceTransactionObservation],
        hasTransactionSource: Bool,
        transactionTotalsAvailable: Bool,
        netWorth: FinanceDisplayMetric,
        spent: FinanceDisplayMetric,
        spendBudget: FinanceDisplayMetric,
        cashFlow: FinanceDisplayMetric,
        income: FinanceDisplayMetric,
        fixedCosts: FinanceDisplayMetric,
        saved: FinanceDisplayMetric,
        savingsGoal: FinanceDisplayMetric,
        accounts: [FinanceAccount],
        categories: [FinanceCategory],
        incomeCategories: [FinanceCategory] = [],
        wealth: FinanceWealthSnapshot? = nil,
        netWorthPoints: [FinanceChartPoint],
        spendPoints: [FinanceChartPoint],
        incomePoints: [FinanceChartPoint],
        cashFlowPoints: [FinanceChartPoint],
        updatedLabel: String,
        sourceDisclosure: String,
        overallFreshness: FinancePayloadFreshness,
        observationState: FinanceObservationState = .observed,
        errorMessage: String? = nil
    ) {
        self.isDemo = isDemo
        self.transactions = transactions
        self.hasTransactionSource = hasTransactionSource
        self.transactionTotalsAvailable = transactionTotalsAvailable
        self.netWorth = netWorth
        self.spent = spent
        self.spendBudget = spendBudget
        self.cashFlow = cashFlow
        self.income = income
        self.fixedCosts = fixedCosts
        self.saved = saved
        self.savingsGoal = savingsGoal
        self.accounts = accounts
        self.categories = categories
        self.incomeCategories = incomeCategories
        self.wealth = wealth
        self.netWorthPoints = netWorthPoints
        self.spendPoints = spendPoints
        self.incomePoints = incomePoints
        self.cashFlowPoints = cashFlowPoints
        self.updatedLabel = updatedLabel
        self.sourceDisclosure = sourceDisclosure
        self.overallFreshness = overallFreshness
        self.observationState = observationState
        self.errorMessage = errorMessage
    }

    static let demo: FinanceDisplaySnapshot = {
        let now = Date.now
        let transactions = Self.demoTransactions(now: now)
        guard let totals = try? FinanceTransactionTotals(transactions: transactions) else {
            return FinanceDisplaySnapshot(
                isDemo: true,
                transactions: [],
                hasTransactionSource: false,
                transactionTotalsAvailable: false,
                netWorth: .unavailable("Not available"),
                spent: .unavailable("Not available"),
                spendBudget: .unavailable("Not available"),
                cashFlow: .unavailable("Not available"),
                income: .unavailable("Not available"),
                fixedCosts: .unavailable("Not available"),
                saved: .unavailable("Not available"),
                savingsGoal: .unavailable("Not available"),
                accounts: [],
                categories: [],
                netWorthPoints: [],
                spendPoints: [],
                incomePoints: [],
                cashFlowPoints: [],
                updatedLabel: "Not available",
                sourceDisclosure: "Demo fixture · aggregate unavailable",
                overallFreshness: .unknown
            )
        }
        let calendar = Calendar.current
        let dayStarts = (0..<12).compactMap { calendar.date(byAdding: .day, value: -11 + $0, to: now) }
        let netValues = [772_000, 782_000, 779_000, 798_000, 804_000, 811_000, 818_000, 826_000, 831_000, 842_000, 850_000, 856_000]
        let points: ([Int], String) -> [FinanceChartPoint] = { values, title in
            zip(dayStarts, values).map { date, value in
                FinanceChartPoint(date: date, value: value, seriesTitle: title)
            }
        }
        let accounts = [
            FinanceAccount(name: "Revolut Personal", detail: "Main account · synced today", balanceCents: 562_000, icon: .finance),
            FinanceAccount(name: "Revolut Savings", detail: "Vault · synced today", balanceCents: 244_000, icon: .savings),
            FinanceAccount(name: "Sparkasse", detail: "Checking · synced today", balanceCents: 50_000, icon: .bankConnections)
        ]
        let accountBalanceCents = accounts.reduce(0) { $0 + ($1.balanceCents ?? 0) }
        return FinanceDisplaySnapshot(
            isDemo: true,
            transactions: transactions,
            hasTransactionSource: true,
            transactionTotalsAvailable: true,
            netWorth: FinanceDisplayMetric(cents: accountBalanceCents, detail: "Observed account balances"),
            spent: FinanceDisplayMetric(cents: totals.spendingCents, detail: "\(totals.transactionCount) transactions", progress: 0.64),
            spendBudget: FinanceDisplayMetric(cents: 200_000, detail: "Monthly budget"),
            cashFlow: FinanceDisplayMetric(
                cents: totals.netCashFlowCents,
                detail: "Income \(FinanceCurrencyFormatter.euro(cents: totals.incomeCents)) · Spend \(FinanceCurrencyFormatter.euro(cents: totals.spendingCents))",
                progress: 0.72
            ),
            income: FinanceDisplayMetric(cents: totals.incomeCents, detail: "\(transactions.filter(\.isIncome).count) deposits"),
            fixedCosts: FinanceDisplayMetric(cents: 182_000, detail: "Recurring"),
            saved: FinanceDisplayMetric(cents: 64_000, detail: "This month", progress: 0.64),
            savingsGoal: FinanceDisplayMetric(cents: 100_000, detail: "Monthly goal"),
            accounts: accounts,
            categories: totals.categoryObservations.map(FinanceCategory.init),
            netWorthPoints: points(netValues, "Net worth"),
            spendPoints: Self.transactionPoints(transactions, title: "Spend", series: .spending) ?? [],
            incomePoints: Self.transactionPoints(transactions, title: "Income", series: .income) ?? [],
            cashFlowPoints: Self.transactionPoints(transactions, title: "Cash flow", series: .cashFlow) ?? [],
            updatedLabel: "Just now",
            sourceDisclosure: "Demo fixture · not live · Revolut Personal · Fresh",
            overallFreshness: .fresh
        )
    }()

    private static func demoTransactions(now: Date) -> [FinanceTransactionObservation] {
        let calendar = Calendar.current
        let observedAt = now
        let provenance = FinancePayloadProvenance(
            source: "revolut_personal-demo-fixture",
            observedAt: observedAt,
            freshness: .fresh,
            quality: .observed,
            connectorState: .healthy
        )
        func date(_ day: Int) -> Date {
            calendar.date(byAdding: .day, value: day - 11, to: now) ?? now
        }
        func row(
            _ id: String,
            _ merchant: String,
            _ title: String,
            _ cents: Int,
            _ day: Int,
            _ category: String
        ) -> FinanceTransactionObservation {
            FinanceTransactionObservation(
                id: id,
                merchant: merchant,
                title: title,
                signedAmountCents: cents,
                timestamp: date(day),
                account: "Revolut Personal",
                source: "revolut_personal",
                category: category,
                provenance: provenance
            )
        }
        return [
            row("salary-1", "Salary", "Monthly salary", 180_000, 0, "Income"),
            row("home-1", "Rent", "Apartment", -20_000, 0, "Home"),
            row("food-1", "REWE", "Groceries", -5_000, 1, "Food"),
            row("transport-1", "BVG", "Transit", -8_000, 2, "Transport"),
            row("salary-2", "Salary", "Freelance deposit", 104_000, 3, "Income"),
            row("lifestyle-1", "Gym", "Membership", -7_000, 3, "Lifestyle"),
            row("other-1", "Apple", "Hardware", -4_000, 4, "Other"),
            row("home-2", "IKEA", "Household", -22_000, 5, "Home"),
            row("food-2", "REWE", "Groceries", -12_000, 6, "Food"),
            row("transport-2", "DB", "Train", -6_000, 7, "Transport"),
            row("lifestyle-2", "Restaurant", "Dinner", -12_000, 8, "Lifestyle"),
            row("salary-3", "Salary", "Side project", 40_000, 9, "Income"),
            row("other-2", "Amazon", "Supplies", -11_400, 9, "Other"),
            row("food-3", "REWE", "Groceries", -13_000, 10, "Food"),
            row("transport-3", "BVG", "Transit", -8_000, 11, "Transport")
        ]
    }

    private static func transactionPoints(
        _ transactions: [FinanceTransactionObservation],
        title: String,
        series: FinanceTransactionSeries
    ) -> [FinanceChartPoint]? {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: transactions) { calendar.startOfDay(for: $0.timestamp) }
        var points: [FinanceChartPoint] = []
        points.reserveCapacity(grouped.count)
        for date in grouped.keys.sorted() {
            let rows = grouped[date, default: []]
            guard let totals = try? FinanceTransactionTotals(transactions: rows) else {
                return nil
            }
            let value: Int
            switch series {
            case .income:
                value = totals.incomeCents
            case .spending:
                value = totals.spendingCents
            case .cashFlow:
                value = totals.netCashFlowCents
            }
            points.append(FinanceChartPoint(
                date: date,
                value: value,
                seriesTitle: title,
                sourceLabel: FinanceSourceLabel.join(Array(Set(rows.map(\.source))).sorted()),
                freshness: FinanceFreshnessLabel.value(for: rows)
            ))
        }
        return points
    }

    func filteredTransactions(
        category: String,
        source: String?,
        range: FinanceRange,
        incomeOnly: Bool = false
    ) -> [FinanceTransactionObservation] {
        guard let latest = transactions.map(\.timestamp).max() else { return [] }
        let start = calendarWindowStart(for: range, latest: latest)
        return FinanceTransactionFilter(
            category: category,
            source: source,
            startDate: start,
            endDate: latest,
            spendingOnly: !incomeOnly,
            incomeOnly: incomeOnly
        ).applying(to: transactions)
    }

    var spendProgress: Double? {
        guard let spent = spent.cents, let budget = spendBudget.cents, budget > 0 else { return nil }
        return min(Double(spent) / Double(budget), 1)
    }

    var savingsProgress: Double? {
        guard let saved = saved.cents, let goal = savingsGoal.cents, goal > 0 else { return nil }
        return min(Double(saved) / Double(goal), 1)
    }

    var statusLabel: String {
        if isDemo { return "Demo · not live" }
        switch observationState {
        case .demo: return "Demo · not live"
        case .loading: return "Loading"
        case .observed: return "Observed"
        case .partial: return "Partial data"
        case .stale: return "Stale"
        case .error: return "Refresh error"
        case .unavailable: return "Not connected"
        }
    }
    var statusColor: Color {
        if isDemo { return LifeOSTokens.warning }
        switch observationState {
        case .observed: return LifeOSTokens.success
        case .partial, .stale, .loading: return LifeOSTokens.warning
        case .error: return LifeOSTokens.danger
        case .demo: return LifeOSTokens.warning
        case .unavailable: return LifeOSTokens.tertiaryText
        }
    }
    var statusIcon: LifeOSIconName {
        switch observationState {
        case .observed: .verified
        case .partial, .stale, .loading, .error: .warning
        case .demo: .views
        case .unavailable: .security
        }
    }
    var accessibilityStatus: String {
        if let errorMessage, !errorMessage.isEmpty {
            return statusLabel + ". " + errorMessage
        }
        return statusLabel
    }
    var hasObservedValue: Bool {
        hasTransactionSource
            || [netWorth, spent, income, fixedCosts, saved].contains(where: { !$0.isUnavailable })
            || wealth?.observedValueCents != nil
    }

    func points(for detail: FinanceDetail, range: FinanceRange) -> [FinanceChartPoint] {
        let source: [FinanceChartPoint]
        switch detail {
        case .spend: source = spendPoints
        case .income: source = incomePoints
        case .cashFlow: source = cashFlowPoints
        case .netWorth: source = netWorthPoints
        }
        guard source.count > 1 else { return [] }
        switch range {
        case .week: return points(in: source, calendarDays: 7)
        case .month: return points(in: source, calendarDays: 31)
        case .halfYear: return points(in: source, calendarDays: 180)
        case .year: return points(in: source, calendarDays: 365)
        case .max: return source
        }
    }

    func availableRanges(for detail: FinanceDetail) -> Set<FinanceRange> {
        Set(FinanceRange.allCases.filter { !points(for: detail, range: $0).isEmpty })
    }

    private func points(in source: [FinanceChartPoint], calendarDays: Int) -> [FinanceChartPoint] {
        guard let latest = source.map(\.date).max(),
              let start = Calendar.current.date(
                  byAdding: .day,
                  value: -(calendarDays - 1),
                  to: Calendar.current.startOfDay(for: latest)
              ),
              hasDistinctHistory(source, days: calendarDays) else { return [] }
        return source.filter { $0.date >= start && $0.date <= latest }
    }

    private func hasDistinctHistory(_ points: [FinanceChartPoint], days: Int) -> Bool {
        let calendar = Calendar.current
        guard let first = points.map(\.date).min(), let last = points.map(\.date).max() else { return false }
        let firstDay = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last)
        let coveredDays = calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0
        // The range is inclusive: seven calendar dates span six day
        // boundaries. Calendar arithmetic stays correct over DST changes.
        return coveredDays >= days - 1
    }

    private func calendarWindowStart(for range: FinanceRange, latest: Date) -> Date? {
        let calendar = Calendar.current
        let calendarDays: Int
        switch range {
        case .week: calendarDays = 7
        case .month: calendarDays = 31
        case .halfYear: calendarDays = 180
        case .year: calendarDays = 365
        case .max: return nil
        }
        return calendar.date(
            byAdding: .day,
            value: -(calendarDays - 1),
            to: calendar.startOfDay(for: latest)
        )
    }
}

private struct FinanceDisplayMetric {
    let cents: Int?
    let detail: String
    let progress: Double?

    init(cents: Int?, detail: String, progress: Double? = nil) {
        self.cents = cents
        self.detail = detail
        self.progress = progress
    }

    static func unavailable(_ detail: String) -> FinanceDisplayMetric {
        FinanceDisplayMetric(cents: nil, detail: detail)
    }

    var isUnavailable: Bool { cents == nil }
    var valueText: String { FinanceCurrencyFormatter.euro(cents: cents) }
    var accessibilityValue: String { isUnavailable ? "not available" : valueText }
}

private struct FinanceChartPoint: Identifiable {
    let date: Date
    let value: Int
    let seriesTitle: String
    let sourceLabel: String
    let freshness: FinancePayloadFreshness

    var id: String { "\(seriesTitle)|\(date.timeIntervalSinceReferenceDate)" }

    init(
        date: Date,
        value: Int,
        seriesTitle: String,
        sourceLabel: String = "Not available",
        freshness: FinancePayloadFreshness = .unknown
    ) {
        self.date = date
        self.value = value
        self.seriesTitle = seriesTitle
        self.sourceLabel = sourceLabel
        self.freshness = freshness
    }

    var valueText: String { FinanceCurrencyFormatter.euro(cents: value) }
    var dateLabel: String { FinanceDateFormatter.point(date) }
    var accessibilityValue: String { "\(valueText), \(dateLabel), \(sourceDisclosure)" }
    var sourceDisclosure: String { "\(sourceLabel) · \(FinanceFreshnessLabel.text(freshness))" }
}

private struct FinanceAccount: Identifiable {
    let id: String
    let name: String
    let detail: String
    let balanceCents: Int?
    let availability: FinanceMetricAvailability
    let icon: LifeOSIconName

    init(
        id: String = UUID().uuidString,
        name: String,
        detail: String,
        balanceCents: Int?,
        availability: FinanceMetricAvailability = .observed,
        icon: LifeOSIconName
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.balanceCents = balanceCents
        self.availability = availability
        self.icon = icon
    }

    var balanceText: String? { balanceCents.map { FinanceCurrencyFormatter.euro(cents: $0) } }
    var isUnavailable: Bool { availability == .unavailable || balanceCents == nil }
}

private struct FinanceCategory: Identifiable {
    let id: String
    let name: String
    let amountCents: Int
    let transactionCount: Int
    let fraction: Double
    let hue: LifeOSTokens.Hue
    let contributingSources: [String]
    let provenanceFreshness: FinancePayloadFreshness

    init(_ observation: FinanceCategoryObservation) {
        id = observation.id
        name = observation.name
        amountCents = observation.amountCents
        transactionCount = observation.transactionCount
        fraction = observation.fraction
        contributingSources = observation.contributingSources
        provenanceFreshness = observation.provenance.freshness
        if let canonical = FinanceTransactionCategory.from(sourceCategory: observation.name) {
            hue = canonical.hue
        } else {
            switch observation.name.lowercased() {
            case "home", "rent": hue = .violet
            case "food", "groceries": hue = .orange
            case "transport": hue = .blue
            case "lifestyle", "entertainment": hue = .pink
            default: hue = .teal
            }
        }
    }

    var amountText: String { FinanceCurrencyFormatter.euro(cents: amountCents) }

    var sourceDisclosure: String {
        "\(FinanceSourceLabel.join(contributingSources)) · \(FinanceFreshnessLabel.text(provenanceFreshness))"
    }
}

private enum FinanceDetail: String, CaseIterable, Hashable {
    case spend
    case income
    case cashFlow
    case netWorth

    var title: String {
        switch self {
        case .spend: "Spend"
        case .income: "Income"
        case .cashFlow: "Cash flow"
        case .netWorth: "Net worth"
        }
    }
}

private enum FinanceTransactionSeries {
    case income
    case spending
    case cashFlow
}

private enum FinanceRange: String, CaseIterable, Hashable {
    case week
    case month
    case halfYear
    case year
    case max

    var title: String {
        switch self {
        case .week: "1W"
        case .month: "1M"
        case .halfYear: "6M"
        case .year: "1Y"
        case .max: "Max"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .week: "One week"
        case .month: "One month"
        case .halfYear: "Six months"
        case .year: "One year"
        case .max: "Max"
        }
    }
}

private enum FinanceCurrencyFormatter {
    static func euro(cents: Int?) -> String {
        guard let cents else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "€\(cents / 100)"
    }

    static func signedEuro(cents: Int) -> String {
        let sign = cents > 0 ? "+" : ""
        return "\(sign)\(euro(cents: cents))"
    }
}

private enum FinanceSourceLabel {
    static func display(_ source: String) -> String {
        switch source {
        case "sparkasse_leipzig": "Sparkasse Leipzig"
        case "revolut_personal": "Revolut Personal"
        case "revolut_business": "Revolut Business"
        case "trade_republic": "Trade Republic"
        case "manual": "Manual import"
        case "derived-transaction-rollup": "Derived rollup"
        case "no-authorized-finance-source": "No authorized source"
        default:
            source
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    static func join(_ sources: [String]) -> String {
        let labels = sources.map(display)
        if labels.isEmpty { return "Not available" }
        return labels.joined(separator: " + ")
    }
}

private enum FinanceFreshnessLabel {
    static func text(_ freshness: FinancePayloadFreshness) -> String {
        switch freshness {
        case .fresh: "Fresh"
        case .stale: "Stale"
        case .unknown: "Freshness unknown"
        }
    }

    static func value(for rows: [FinanceTransactionObservation]) -> FinancePayloadFreshness {
        guard !rows.isEmpty else { return .unknown }
        if rows.contains(where: { $0.provenance.freshness == .unknown }) { return .unknown }
        if rows.contains(where: { $0.provenance.freshness == .stale || $0.provenance.connectorState == .refreshDue }) {
            return .stale
        }
        return .fresh
    }

    static func value(for provenances: [FinancePayloadProvenance]) -> FinancePayloadFreshness {
        guard !provenances.isEmpty else { return .unknown }
        if provenances.contains(where: {
            $0.quality != .observed || $0.freshness == .unknown
        }) {
            return .unknown
        }
        if provenances.contains(where: {
            $0.freshness == .stale || $0.connectorState == .refreshDue
        }) {
            return .stale
        }
        return .fresh
    }

    static func text(for rows: [FinanceTransactionObservation]) -> String {
        text(value(for: rows))
    }
}

private enum FinanceDateFormatter {
    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    static func point(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · HH:mm"
        return formatter.string(from: date)
    }
}
