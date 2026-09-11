import Foundation
import SwiftUI
import Charts

struct OverviewView: View {
    private let snapshot: OverviewSnapshot
    private let usageSnapshots: [ProviderSnapshot]
    private let usageAnalytics: [UsageAnalyticsSnapshot]
    private let usageState: UsageLoadState
    private let refreshAction: (() async -> Void)?
    private let clipperRefreshAction: (() async -> Void)?
    private let clipperState: ClipperLoadState
    private let fitnessSnapshot: FitnessSnapshot
    private let financeSummary: FinanceSummary?
    private let financeState: FinanceLoadState
    private let openDestination: ((LifeOSDeepLink) -> Void)?
    @Binding private var showingUsage: Bool
    @State private var selectedDetail: OverviewDetail?

    private enum OverviewDetail: Hashable {
        case clipper
        /// RF-20: pushed from the Finance card's Wealth row. Renders the
        /// exact same real wealth surface Finance's own screen uses
        /// (`FinanceWealthCard`, sourced from `FinanceWealthAllocationEngine`
        /// over `FinanceSummary.wealth`), not a second implementation.
        case financeWealth
    }

    init(
        snapshot: OverviewSnapshot = .unavailable(),
        usageSnapshots: [ProviderSnapshot] = [],
        usageAnalytics: [UsageAnalyticsSnapshot] = [],
        usageState: UsageLoadState = .unavailable,
        refreshAction: (() async -> Void)? = nil,
        clipperRefreshAction: (() async -> Void)? = nil,
        clipperState: ClipperLoadState = .unavailable,
        fitnessSnapshot: FitnessSnapshot = .unavailable,
        financeSummary: FinanceSummary? = nil,
        financeState: FinanceLoadState = .unavailable,
        openDestination: ((LifeOSDeepLink) -> Void)? = nil,
        showingUsage: Binding<Bool> = .constant(false)
    ) {
        self.snapshot = snapshot
        self.usageSnapshots = usageSnapshots
        self.usageAnalytics = usageAnalytics
        self.usageState = usageState
        self.refreshAction = refreshAction
        self.clipperRefreshAction = clipperRefreshAction
        self.clipperState = clipperState
        self.fitnessSnapshot = fitnessSnapshot
        self.financeSummary = financeSummary
        self.financeState = financeState
        self.openDestination = openDestination
        _showingUsage = showingUsage
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LifeOSResponsiveContentContainer(
                    horizontalPadding: responsiveHorizontalInset,
                    topPadding: headerTopSpacing,
                    bottomPadding: contentBottomPadding,
                    maxReadableWidth: OverviewLayoutContract.maxContentWidth
                ) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.sectionGap) {
                        header
                        dashboard
                    }
                }
            }
#if os(iOS)
            .accessibilityIdentifier("overview-screen")
#endif
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .refreshable { await refreshAction?() }
            .navigationDestination(item: $selectedDetail) { destination in
                switch destination {
                case .clipper:
                    ClipperAnalyticsView(
                        section: clipperSection,
                        snapshot: snapshot.clipperSnapshot,
                        refreshAction: clipperRefreshAction,
                        clipperState: clipperState
                    )
                case .financeWealth:
                    OverviewFinanceWealthDetail(financeSummary: financeSummary)
                }
            }
        }
    }

    private var responsiveHorizontalInset: CGFloat {
#if os(macOS)
        LifeOSTokens.pageGutter
#else
        LifeOSTokens.pageGutter
#endif
    }

    private var headerTopSpacing: CGFloat {
#if os(macOS)
        16
#else
        8
#endif
    }

    private var contentBottomPadding: CGFloat {
#if os(macOS)
        32
#else
        24
#endif
    }

    /// Usage is the lead signal. The other three surfaces form a responsive
    /// bento row on regular widths and a readable single column on iPhone.
    @ViewBuilder
    private var dashboard: some View {
        if showsNoSourceDashboard {
            noSourceDashboard
        } else {
            regularDashboard
        }
    }

    @ViewBuilder
    private var regularDashboard: some View {
        let supportingSections = visibleSections.filter { $0.kind != .llm }
        VStack(alignment: .leading, spacing: 0) {
            if showsUpdatingNotice {
                updatingRow
                    .padding(.bottom, LifeOSTokens.overviewCardGap + 4)
            }

            if let usage = visibleSections.first(where: { $0.kind == .llm }) {
                sectionRow(usage, featured: true)
            }

            supportingDashboard(sections: supportingSections)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func supportingDashboard(sections: [OverviewSection]) -> some View {
        OverviewSupportingLayout {
            ForEach(sections) { section in
                sectionRow(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A fresh production install has no observations to summarize. Keep this
    /// path intentionally separate from the populated dashboard so an absent
    /// source cannot acquire a fake chart, ring, or card-sized explanation.
    private var showsNoSourceDashboard: Bool {
        guard usageState == .unavailable,
              clipperState == .unavailable,
              financeState == .unavailable else {
            return false
        }

        switch fitnessSnapshot.source.status {
        case .unavailable, .permissionRequired:
            break
        case .connected, .stale, .demo:
            return false
        }

        guard visibleSections.allSatisfy({ $0.provenance.quality == .unavailable }),
              usageSnapshots.allSatisfy({ $0.provenance.quality == .unavailable }),
              !hasObservedHealthMetrics,
              !hasObservedFinanceValue,
              snapshot.clipperSnapshot?.availability != .observed else {
            return false
        }
        return true
    }

    private var hasObservedHealthMetrics: Bool {
        fitnessSnapshot.healthMonitor.contains {
            $0.value != nil && $0.quality == .observed
        } || fitnessSnapshot.loadDetail.trendCards.contains {
            $0.metric.value != nil && $0.metric.quality == .observed
        }
    }

    private var hasObservedFinanceValue: Bool {
        financeSummary.map(Self.financeSummaryHasObservedValue) ?? false
    }

    /// The source setup row is the only setup surface. The module rows below
    /// remain navigable, but they never present an unavailable operation as a
    /// button of their own.
    private var noSourceDashboard: some View {
        OverviewSupportingLayout {
            noSourceStatusBlock
            noSourceModuleList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("overview-no-source")
    }

    private var showsUpdatingNotice: Bool {
        usageState == .loading || clipperState == .loading || financeState == .loading
    }

    private var updatingRow: some View {
        LifeOSCard(
            level: .surface,
            cornerRadius: LifeOSTokens.Radius.control,
            padding: LifeOSTokens.Space.sm
        ) {
            HStack(spacing: LifeOSTokens.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                    .tint(LifeOSTokens.accent)
                Text("Updating connected sources…")
                    .lifeOSTypography(.body, weight: .medium)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overview-updating")
    }

    private var noSourceStatusBlock: some View {
        let settingsAction: (() -> Void)?
        if let openDestination {
            settingsAction = { openDestination(.settings) }
        } else {
            settingsAction = nil
        }

        return LifeOSEmptyStatePanel(
            icon: .settings,
            title: "No connected sources",
            explanation: "Connect a supported source in Settings to populate Home with observed data.",
            actionTitle: settingsAction == nil ? nil : "Open Settings",
            action: settingsAction,
            actionAccessibilityIdentifier: "overview-no-source-settings"
        )
        .accessibilityIdentifier("overview-no-source-status")
    }

    private var noSourceModuleList: some View {
        LifeOSCard(
            level: .surface,
            cornerRadius: LifeOSTokens.Radius.widget,
            padding: 0
        ) {
            VStack(spacing: 0) {
                ForEach([OverviewSectionKind.llm, .clipper, .health, .finance], id: \.self) { kind in
                    noSourceModuleRow(kind)
                    if kind != .finance {
                        Divider()
                            .overlay(LifeOSTokens.hairlineBorder)
                            .padding(.leading, 52)
                    }
                }
            }
        }
        .accessibilityIdentifier("overview-no-source-modules")
    }

    @ViewBuilder
    private func noSourceModuleRow(_ kind: OverviewSectionKind) -> some View {
        if noSourceModuleIsOpenable(kind) {
            Button {
                openNoSourceModule(kind)
            } label: {
                noSourceModuleRowContent(kind, showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview-no-source-\(kind.rawValue)")
            .accessibilityHint("Opens \(noSourceModuleTitle(kind))")
        } else {
            noSourceModuleRowContent(kind, showsChevron: false)
                .accessibilityIdentifier("overview-no-source-\(kind.rawValue)")
        }
    }

    private func noSourceModuleRowContent(
        _ kind: OverviewSectionKind,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: LifeOSTokens.Space.sm) {
            LifeOSIcon(noSourceModuleIcon(kind), context: .card)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text(noSourceModuleTitle(kind))
                    .lifeOSTypography(.cardTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text(noSourceModuleCause(kind))
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: LifeOSTokens.Space.xs)

            if showsChevron {
                LifeOSIcon(.chevronRight, context: .disclosure)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, LifeOSTokens.Space.md)
        .padding(.vertical, LifeOSTokens.Space.sm)
        .frame(minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func noSourceModuleIsOpenable(_ kind: OverviewSectionKind) -> Bool {
        switch kind {
        case .llm, .clipper:
            return true
        case .health, .finance:
            return openDestination != nil
        }
    }

    private func openNoSourceModule(_ kind: OverviewSectionKind) {
        switch kind {
        case .llm:
            if let openDestination {
                openDestination(.usage)
            } else {
                showingUsage = true
            }
        case .clipper:
            selectedDetail = .clipper
        case .health:
            openDestination?(.fitness)
        case .finance:
            openDestination?(.finance)
        }
    }

    private func noSourceModuleTitle(_ kind: OverviewSectionKind) -> String {
        switch kind {
        case .llm: "Usage"
        case .clipper: "Clipper"
        case .health: "Health"
        case .finance: "Finance"
        }
    }

    private func noSourceModuleCause(_ kind: OverviewSectionKind) -> String {
        switch kind {
        case .llm:
            "Provider connection required"
        case .clipper:
            "Clipper connector required"
        case .health:
            fitnessSnapshot.source.status == .permissionRequired
                ? "HealthKit permission required"
                : "HealthKit observation required"
        case .finance:
            "Account connection required"
        }
    }

    private func noSourceModuleIcon(_ kind: OverviewSectionKind) -> LifeOSIconName {
        switch kind {
        case .llm: .usage
        case .clipper: .clipper
        case .health: .health
        case .finance: .finance
        }
    }

    /// Usage observations replace the stored LLM summary when the coordinator
    /// has data. Every other section remains sourced from the snapshot; in
    /// particular, Clipper is never hidden or synthesized here.
    private var visibleSections: [OverviewSection] {
        var sections = snapshot.sections
        guard !usageSnapshots.isEmpty else { return sections }
        let usage = OverviewSection.usageSummary(from: usageSnapshots)
        if let index = sections.firstIndex(where: { $0.kind == .llm }) {
            sections[index] = usage
        } else {
            sections.insert(usage, at: 0)
        }
        return sections
    }

    private var clipperSection: OverviewSection {
        visibleSections.first(where: { $0.kind == .clipper })
            ?? OverviewSnapshot.unavailable().sections.first(where: { $0.kind == .clipper })!
    }

    private var snapshotStatusLabel: String {
        let qualities = visibleSections.map(\.provenance.quality)
        return OverviewHomeStatusPolicy.snapshotStatusLabel(
            qualities: qualities,
            healthState: fitnessSnapshot.source.status,
            healthIntegrityIssue: healthIntegrityStatusPresent,
            financeState: financeState,
            financeHasObservedValue: financeSummary.map(Self.financeSummaryHasObservedValue) ?? false,
            clipperState: clipperState,
            hasRefreshDueSection: visibleSections.contains {
                $0.provenance.quality == .observed && $0.provenance.connector == .refreshDue
            },
            usageState: usageState,
            hasPartialUsage: usageHasPartialCoverage
        )
    }

    private var usageHasPartialCoverage: Bool {
        guard !usageSnapshots.isEmpty else { return false }
        return usageSnapshots.contains { snapshot in
            snapshot.provenance.quality == .observed
                && snapshot.windows.contains { $0.usedPercent == nil }
        }
    }

    private var healthIntegrityStatusPresent: Bool {
        OverviewHomeStatusPolicy.healthIntegrityStatus(
            source: fitnessSnapshot.source,
            hasObservedMetrics: fitnessSnapshot.healthMonitor.contains {
                $0.value != nil && $0.quality == .observed
            } || fitnessSnapshot.loadDetail.trendCards.contains {
                $0.metric.value != nil && $0.metric.quality == .observed
            }
        ) != nil
    }

    private static func financeSummaryHasObservedValue(_ summary: FinanceSummary) -> Bool {
        [summary.monthlyIncome, summary.fixedCosts, summary.discretionaryBuffer,
         summary.spent, summary.savingsGoal, summary.saved]
            .contains { $0.availability == .observed && $0.amountCents != nil }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text("Home")
                    .lifeOSTypography(.pageTitle, weight: .semibold)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text(overviewDateLabel)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: LifeOSTokens.Space.sm)

            if shouldShowStatusBadge {
                statusBadge
            }
            if refreshAction != nil {
                LifeOSIconButton(
                    icon: .refresh,
                    accessibilityLabel: "Refresh Home",
                    size: 32,
                    tint: LifeOSTokens.secondaryText
                ) {
                    Task { await refreshAction?() }
                }
            }
        }
        .frame(minHeight: 44, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    private var overviewDateLabel: String {
        Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var shouldShowStatusBadge: Bool {
        snapshotStatusLabel != "CONNECTED DATA"
    }

    private var statusBadge: some View {
        let status = snapshotStatusLabel
        let isDemo = status.hasPrefix("DEMO")
        let isStale = status.hasPrefix("STALE")
        let isPartial = status.hasPrefix("PARTIAL")
        let isUpdating = status == "UPDATING DATA"
        let color = isUpdating
            ? LifeOSTokens.info
            : (isDemo || isStale || isPartial ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)

        return HStack(spacing: LifeOSTokens.Space.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(homeStatusLabel)
                .lifeOSTypography(.metadata, weight: .medium)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var homeStatusLabel: String {
        switch snapshotStatusLabel {
        case let value where value.hasPrefix("DEMO"):
            "Demo · not live"
        case let value where value.hasPrefix("STALE"):
            "Stale · refresh required"
        case let value where value.hasPrefix("PARTIAL"):
            "Partial · review source"
        case "UPDATING DATA":
            "Updating"
        case "DATA UNAVAILABLE":
            "Not connected"
        default:
            "Connected"
        }
    }

    @ViewBuilder
    private func sectionRow(_ section: OverviewSection, featured: Bool = false) -> some View {
        switch section.kind {
        case .llm:
            if openDestination != nil {
                Button {
                    openDestination?(.usage)
                } label: {
                    OverviewMetricCard(
                        section: section,
                        featured: featured,
                        usageSnapshots: usageSnapshots,
                        usageAnalytics: usageAnalytics,
                        fitnessSnapshot: fitnessSnapshot,
                        financeSummary: financeSummary,
                        financeState: financeState,
                        usageHasPartialCoverage: usageHasPartialCoverage
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("account-usage-link")
                .accessibilityHint("Opens detailed Usage analytics")
            } else {
                OverviewMetricCard(
                    section: section,
                    featured: featured,
                    usageSnapshots: usageSnapshots,
                    usageAnalytics: usageAnalytics,
                    fitnessSnapshot: fitnessSnapshot,
                    financeSummary: financeSummary,
                    financeState: financeState,
                    usageHasPartialCoverage: usageHasPartialCoverage
                )
            }
        case .clipper:
            Button {
                selectedDetail = .clipper
            } label: {
                OverviewMetricCard(
                    section: section,
                    usageSnapshots: usageSnapshots,
                    clipperState: clipperState,
                    clipperSnapshot: snapshot.clipperSnapshot,
                    fitnessSnapshot: fitnessSnapshot,
                    financeSummary: financeSummary,
                    financeState: financeState
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview-clipper-card")
            .accessibilityHint("Opens Clipper Analytics; connector status and unavailable fields are shown honestly")
        case .health:
            if openDestination != nil {
                Button { openDestination?(.fitness) } label: {
                    OverviewMetricCard(
                        section: section,
                        usageSnapshots: usageSnapshots,
                        fitnessSnapshot: fitnessSnapshot,
                        financeSummary: financeSummary,
                        financeState: financeState
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overview-health-link")
                .accessibilityHint("Opens Fitness")
            } else {
                OverviewMetricCard(
                    section: section,
                    usageSnapshots: usageSnapshots,
                    fitnessSnapshot: fitnessSnapshot,
                    financeSummary: financeSummary,
                    financeState: financeState
                )
            }
        case .finance:
            financeSectionRow(section)
        }
    }

    @ViewBuilder
    private func financeSectionRow(_ section: OverviewSection) -> some View {
        if let openDestination {
            VStack(alignment: .leading, spacing: 8) {
                Button { openDestination(.finance) } label: {
                    OverviewMetricCard(
                        section: section,
                        usageSnapshots: usageSnapshots,
                        fitnessSnapshot: fitnessSnapshot,
                        financeSummary: financeSummary,
                        financeState: financeState
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overview-finance-link")
                .accessibilityHint("Opens Finance")

                financeWealthLink
            }
        } else {
            OverviewMetricCard(
                section: section,
                usageSnapshots: usageSnapshots,
                fitnessSnapshot: fitnessSnapshot,
                financeSummary: financeSummary,
                financeState: financeState
            )
        }
    }

    @ViewBuilder
    private var financeWealthLink: some View {
        Button {
            selectedDetail = .financeWealth
        } label: {
            HStack(spacing: 8) {
                LifeOSIcon(.investments, context: .card)
                    .foregroundStyle(LifeOSTokens.Module.finance)
                    .frame(width: 14, height: 14)
                Text("Wealth")
                    .lifeOSTypography(.metadata, weight: .medium)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                if let cents = financeSummary?.wealth?.observedValueCents {
                    Text(OverviewCurrencyFormatter.eur(cents: cents))
                        .lifeOSTypography(.metadata, weight: .semibold)
                        .monospacedDigit()
                } else {
                    Text("Unavailable")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                LifeOSIcon(.chevronRight, context: .disclosure)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 10, height: 10)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("overview-finance-wealth-link")
        .accessibilityLabel("Wealth")
        .accessibilityValue(financeSummary?.wealth?.observedValueCents.map { OverviewCurrencyFormatter.eur(cents: $0) } ?? "Unavailable")
        .accessibilityHint("Opens the Finance wealth surface")
    }

}

/// The Home dashboard's measured-width contract. The view receives the
/// already-guttered width from `LifeOSResponsiveContentContainer`, so a
/// sidebar or split-detail proposal naturally participates in the decision.
enum OverviewLayoutContract {
    static let maxContentWidth: CGFloat = 1040
    static let twoColumnBreakpoint: CGFloat = 720
    static let columnMinimumWidth: CGFloat = 300
    static let threeColumnBreakpoint: CGFloat = 960
    static let threeColumnMinimumWidth: CGFloat = 300
    static let columnSpacing: CGFloat = LifeOSTokens.overviewCardGap + 4

    static func measuredContentWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite else { return 0 }
        return min(max(0, availableWidth), maxContentWidth)
    }

    static func contentWidth(forOuterWidth outerWidth: CGFloat, horizontalPadding: CGFloat) -> CGFloat {
        let padding = max(0, horizontalPadding)
        return measuredContentWidth(availableWidth: outerWidth - padding * 2)
    }

    static func columnCount(for contentWidth: CGFloat) -> Int {
        measuredContentWidth(availableWidth: contentWidth) >= twoColumnBreakpoint ? 2 : 1
    }

    static func minimumRequiredWidth(for contentWidth: CGFloat) -> CGFloat {
        columnCount(for: contentWidth) == 2
            ? columnMinimumWidth * 2 + columnSpacing
            : 0
    }

    /// Supporting cards use three columns only when the measured width keeps
    /// every card at the documented minimum. The older two-column helper above
    /// remains the compatibility check used by the existing snapshot contract.
    static func supportingColumnCount(for contentWidth: CGFloat, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let width = measuredContentWidth(availableWidth: contentWidth)
        guard width >= twoColumnBreakpoint else { return 1 }
        let canUseThree = width >= threeColumnBreakpoint
            && (width - columnSpacing * 2) / 3 >= threeColumnMinimumWidth
        return min(canUseThree ? 3 : 2, itemCount)
    }
}

/// Measures the width proposed by the existing Home content container and
/// lays out its cards without introducing another scroll owner. Keeping the
/// measurement in `Layout` means a split-detail resize is applied in the same
/// pass as placement instead of relying on a stale size-class value or a
/// second data-driven view tree.
private struct OverviewSupportingLayout: Layout {
    private func width(for proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            return OverviewLayoutContract.measuredContentWidth(availableWidth: proposedWidth)
        }

        let intrinsicWidth = subviews.reduce(CGFloat.zero) { result, subview in
            max(result, subview.sizeThatFits(.unspecified).width)
        }
        return OverviewLayoutContract.measuredContentWidth(availableWidth: intrinsicWidth)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let width = width(for: proposal, subviews: subviews)
        let count = OverviewLayoutContract.supportingColumnCount(for: width, itemCount: subviews.count)
        let spacing = OverviewLayoutContract.columnSpacing
        let columnWidth = max(1, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let sizes = subviews.map {
            $0.sizeThatFits(.init(width: columnWidth, height: nil))
        }

        var rowHeights = Array(repeating: CGFloat.zero, count: (sizes.count + count - 1) / count)
        for (index, size) in sizes.enumerated() {
            rowHeights[index / count] = max(rowHeights[index / count], size.height)
        }
        let height = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let width = OverviewLayoutContract.measuredContentWidth(availableWidth: bounds.width)
        let count = OverviewLayoutContract.supportingColumnCount(for: width, itemCount: subviews.count)
        let spacing = OverviewLayoutContract.columnSpacing
        let columnWidth = max(1, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let sizes = subviews.map {
            $0.sizeThatFits(.init(width: columnWidth, height: nil))
        }

        var rowHeights = Array(repeating: CGFloat.zero, count: (sizes.count + count - 1) / count)
        for (index, size) in sizes.enumerated() {
            rowHeights[index / count] = max(rowHeights[index / count], size.height)
        }

        var rowOrigins = Array(repeating: bounds.minY, count: rowHeights.count)
        for index in rowHeights.indices.dropFirst() {
            rowOrigins[index] = rowOrigins[index - 1] + rowHeights[index - 1] + spacing
        }

        for index in subviews.indices {
            let column = index % count
            let row = index / count
            let size = sizes[index]
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (columnWidth + spacing),
                    y: rowOrigins[row]
                ),
                anchor: .topLeading,
                proposal: .init(width: columnWidth, height: size.height)
            )
        }
    }
}

/// RF-20: the Overview push destination for the Finance card's Wealth row.
/// Reuses `FinanceWealthCard` verbatim (constructing the same
/// `FinanceDisplaySnapshot` Finance's own screen builds), so this is the
/// exact same real wealth surface, not a second implementation of it.
private struct OverviewFinanceWealthDetail: View {
    let financeSummary: FinanceSummary?

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: 16, bottomPadding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Wealth")
                        .lifeOSTypography(.pageTitle)
                        .tracking(-0.5)
                    FinanceWealthCard(
                        snapshot: FinanceDisplaySnapshot(summary: financeSummary, transactions: nil, usesVisualFixtures: false),
                        onOpenConnections: nil
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Wealth")
        .accessibilityIdentifier("overview-finance-wealth-detail")
    }
}

/// Pure presentation policy for Home's source badges. Keeping the section
/// scope explicit prevents a HealthKit/Finance warning from tinting another
/// card, while the integrity-status helper preserves HealthKit's detailed
/// source wording when displayable observations coexist with a partial,
/// conflicted, or errored composition.
enum OverviewHomeStatusPolicy {
    static func isWarning(
        section: OverviewSectionKind,
        quality: DataQuality,
        connector: ConnectorState,
        sectionState: OverviewSectionState,
        clipperState: ClipperLoadState,
        healthState: FitnessSourceState.Status,
        healthIntegrityIssue: Bool,
        financeState: FinanceLoadState,
        partialUsage: Bool = false
    ) -> Bool {
        switch section {
        case .llm:
            return quality == .demo || connector == .refreshDue || sectionState == .partial || partialUsage
        case .clipper:
            return quality == .demo || connector == .refreshDue || sectionState == .partial || clipperState == .stale
        case .health:
            return quality == .demo
                || healthState == .demo
                || healthState == .stale
                || healthState == .permissionRequired
                || healthIntegrityIssue
        case .finance:
            return quality == .demo || financeState == .demo || financeState == .stale
        }
    }

    static func healthIntegrityStatus(
        source: FitnessSourceState,
        hasObservedMetrics: Bool
    ) -> String? {
        guard source.status == .unavailable, hasObservedMetrics else { return nil }
        let combined = "\(source.title) · \(source.detail)"
        guard ["Partial", "Conflict", "Error"].contains(where: {
            combined.range(of: $0, options: .caseInsensitive) != nil
        }) else { return nil }
        return combined
    }

    static func snapshotStatusLabel(
        qualities: [DataQuality],
        healthState: FitnessSourceState.Status,
        healthIntegrityIssue: Bool,
        financeState: FinanceLoadState,
        financeHasObservedValue: Bool,
        clipperState: ClipperLoadState,
        hasRefreshDueSection: Bool,
        usageState: UsageLoadState? = nil,
        hasPartialUsage: Bool = false
    ) -> String {
        if qualities.allSatisfy({ $0 == .demo }) { return "DEMO FIXTURES · NOT LIVE DATA" }
        if usageState == .loading || financeState == .loading || clipperState == .loading {
            return "UPDATING DATA"
        }
        if healthState == .stale || financeState == .stale {
            return "STALE DATA · REFRESH REQUIRED"
        }
        if healthIntegrityIssue || hasPartialUsage {
            return "PARTIAL DATA · REVIEW SOURCE"
        }
        let healthConnected = healthState == .connected || healthState == .stale
        if qualities.allSatisfy({ $0 == .unavailable })
            && !healthConnected
            && !financeHasObservedValue {
            return "DATA UNAVAILABLE"
        }
        if clipperState == .stale || hasRefreshDueSection {
            return "STALE DATA · REFRESH REQUIRED"
        }
        return "CONNECTED DATA"
    }
}

enum OverviewCurrencyFormatter {
    static func eur(cents: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        let amount = Decimal(cents) / Decimal(100)
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
    }
}

private struct OverviewMetricCard: View {
    let section: OverviewSection
    let featured: Bool
    let usageSnapshots: [ProviderSnapshot]
    let usageAnalytics: [UsageAnalyticsSnapshot]
    let clipperState: ClipperLoadState
    let clipperSnapshot: ClipperSnapshot?
    let fitnessSnapshot: FitnessSnapshot
    let financeSummary: FinanceSummary?
    let financeState: FinanceLoadState
    let usageHasPartialCoverage: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    init(section: OverviewSection, featured: Bool = false, usageSnapshots: [ProviderSnapshot] = [],
         usageAnalytics: [UsageAnalyticsSnapshot] = [],
         clipperState: ClipperLoadState = .unavailable, clipperSnapshot: ClipperSnapshot? = nil,
         fitnessSnapshot: FitnessSnapshot = .unavailable, financeSummary: FinanceSummary? = nil,
         financeState: FinanceLoadState = .unavailable,
         usageHasPartialCoverage: Bool = false) {
        self.section = section
        self.featured = featured
        self.usageSnapshots = usageSnapshots
        self.usageAnalytics = usageAnalytics
        self.clipperState = clipperState
        self.clipperSnapshot = clipperSnapshot
        self.fitnessSnapshot = fitnessSnapshot
        self.financeSummary = financeSummary
        self.financeState = financeState
        self.usageHasPartialCoverage = usageHasPartialCoverage
    }

    private var title: String {
        switch section.kind {
        case .llm: "Usage"
        case .clipper: "Clipper Analytics"
        case .health: "Health"
        case .finance: "Finance"
        }
    }

    private var sourceStatus: String {
        if section.kind == .health {
            if let integrityStatus = OverviewHomeStatusPolicy.healthIntegrityStatus(
                source: fitnessSnapshot.source,
                hasObservedMetrics: !homeHealthMetrics.isEmpty
            ) {
                return integrityStatus
            }
            switch fitnessSnapshot.source.status {
            case .demo: return "Demo fixture · not live"
            case .connected: return "Observed · \(fitnessSnapshot.source.title)"
            case .stale: return "Stale · \(fitnessSnapshot.source.title) · refresh required"
            case .permissionRequired: return "Permission needed · HealthKit"
            case .unavailable: break
            }
        }
        if section.kind == .finance {
            switch financeState {
            case .demo: return "Demo fixture · not live"
            case .stale: return "Stale · Finance source · refresh required"
            case .observed where financeSummaryHasObservedValue: return "Observed · Finance source"
            case .loading: return "Loading · Finance source"
            case .unavailable, .observed: break
            }
        }
        if section.kind == .llm && usageHasPartialCoverage && section.provenance.quality == .observed {
            return "Partial observed · some provider windows unavailable"
        }
        return switch section.provenance.quality {
        case .demo: "Demo fixture · not live"
        case .unavailable:
            switch section.kind {
            case .clipper: "Not connected · Clipper connector required"
            case .health: "Not connected · HealthKit observation required"
            case .finance: "Not connected · account connection required"
            case .llm: "Not connected · provider connection required"
            }
        case .observed:
            if section.kind == .clipper && clipperState == .stale {
                "Stale · \(section.provenance.source) · refresh required"
            } else if section.kind == .clipper && section.state == .partial {
                "Partial observed · \(section.provenance.source)"
            } else if section.provenance.connector == .refreshDue {
                "Stale · \(section.provenance.source) · refresh required"
            } else {
                "Observed · \(section.provenance.source)"
            }
        case .estimated: "Estimated · \(section.provenance.source)"
        }
    }

    private var sourceStatusColor: Color {
        let healthIntegrityIssue = healthIntegrityStatusPresent
        if OverviewHomeStatusPolicy.isWarning(
            section: section.kind,
            quality: section.provenance.quality,
            connector: section.provenance.connector,
            sectionState: section.state,
            clipperState: clipperState,
            healthState: fitnessSnapshot.source.status,
            healthIntegrityIssue: healthIntegrityIssue,
            financeState: financeState,
            partialUsage: usageHasPartialCoverage
        ) {
            return LifeOSTokens.warning
        }
        return LifeOSTokens.tertiaryText
    }

    private var healthIntegrityStatusPresent: Bool {
        OverviewHomeStatusPolicy.healthIntegrityStatus(
            source: fitnessSnapshot.source,
            hasObservedMetrics: !homeHealthMetrics.isEmpty
        ) != nil
    }

    private var financeSummaryHasObservedValue: Bool {
        guard let financeSummary else { return false }
        return [financeSummary.monthlyIncome, financeSummary.fixedCosts,
                financeSummary.discretionaryBuffer, financeSummary.spent,
                financeSummary.savingsGoal, financeSummary.saved]
            .contains { $0.availability == .observed && $0.amountCents != nil }
    }

    private var sectionIcon: LifeOSIconName {
        switch section.kind {
        case .llm: .usage
        case .clipper: .clipper
        case .health: .health
        case .finance: .finance
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            HStack(alignment: .center, spacing: LifeOSTokens.Space.sm) {
                LifeOSIcon(sectionIcon, context: .card)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                    Text(title)
                        .lifeOSTypography(.label, weight: .semibold)
                        .foregroundStyle(LifeOSTokens.primaryText)
                }
                Spacer(minLength: LifeOSTokens.Space.sm)
                LifeOSIcon(.chevronRight, context: .disclosure)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 16, height: 16)
            }

            if shouldShowSourceStatus {
                HStack(spacing: 6) {
                    Circle()
                        .fill(sourceStatusColor)
                        .frame(width: 6, height: 6)
                    Text(sourceStatus)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(sourceStatusColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            if featured && section.kind == .llm {
                usageBody
            } else {
                supportingBody
            }
        }
        .padding(.horizontal, LifeOSTokens.Space.md)
        .padding(.vertical, featured ? LifeOSTokens.Space.md : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard(cornerRadius: LifeOSTokens.Radius.widget, featured: featured)
        // §5.1 hover (macOS): border brightens to strongBorder; no offset lift.
        .overlay(cardShape.stroke(hovering ? LifeOSTokens.strongBorder : Color.clear, lineWidth: 1))
        .animation(reduceMotion ? nil : LifeOSMotion.hover, value: hovering)
#if os(macOS)
        .onHover { hovering = $0 }
#endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(sourceStatus)")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LifeOSTokens.Radius.widget, style: .continuous)
    }

    private var shouldShowSourceStatus: Bool {
        if section.provenance.quality == .demo { return false }
        if section.provenance.quality != .observed { return true }
        if section.provenance.connector != .healthy || section.state != .complete { return true }
        if section.kind == .health && healthIntegrityStatusPresent { return true }
        if section.kind == .finance && financeState == .stale { return true }
        return section.kind == .clipper && clipperState == .stale
    }

    @ViewBuilder
    private var usageBody: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                if let remaining = leadUsageSnapshot?.smallestObservedWindow?.usedPercent.map({ 1 - $0 }) {
                    Text("\(Int((remaining * 100).rounded()))")
                        .lifeOSTypography(.metric)
                        .foregroundStyle(.primary)
                        .numericTransition()
                    Text("% remaining")
                        .lifeOSTypography(.metadata, weight: .medium)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                } else {
                    Text("—")
                        .lifeOSTypography(.metricCompact)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: LifeOSTokens.Space.sm)
                Text(leadUsageSnapshot.map { "\($0.provider.displayName) · \($0.smallestObservedWindow?.label ?? "Window")" } ?? "No connected provider")
                    .lifeOSTypography(.metadata, weight: .medium)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            if usageTrendPoints.count >= 2 {
                OverviewSparkline(points: usageTrendPoints, tint: LifeOSTokens.Module.usage)
                    .frame(height: 36)
                    // This chart is a summary inside a tappable card. Its
                    // detail view owns chart scrubbing; letting this overlay
                    // hit-test would swallow the card's navigation tap.
                    .allowsHitTesting(false)
            }

            Text(usageSummaryMetadata)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usageSummaryMetadata: String {
        guard let window = leadUsageSnapshot?.smallestObservedWindow else {
            return "No validated usage window is connected."
        }
        let reset = window.resetAt.map {
            "Resets \($0.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        }
        let observed = leadUsageSnapshot.map {
            "Updated \($0.provenance.observedAt.formatted(.dateTime.hour().minute()))"
        }
        return [reset, observed].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var supportingBody: some View {
        switch section.kind {
        case .clipper:
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    ValueMetric(value: clipperHomeMetricValue(containing: "Views"), label: "Views today")
                    ValueMetric(value: clipperHomeMetricValue(containing: "Subscribers"), label: "Subscribers")
                    ValueMetric(value: clipperHomeMetricValue(containing: "Revenue"), label: "Revenue")
                }
                if let clipperTrend {
                    OverviewSparkline(points: clipperTrend.points, tint: LifeOSTokens.Module.business)
                        .frame(height: 36)
                        .allowsHitTesting(false)
                } else {
                    OverviewChartUnavailable(detail: clipperChartDetail)
                        .frame(minHeight: 40)
                }
            }
        case .health:
            VStack(alignment: .leading, spacing: 10) {
                if !homeHealthMetrics.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(homeHealthMetrics) { metric in
                            ValueMetric(value: fitnessDisplayValue(metric), label: metric.title)
                        }
                    }
                    Text(fitnessSnapshot.source.freshness)
                    .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else if section.provenance.quality == .demo {
                    overviewFallbackMetrics
                } else {
                    OverviewChartUnavailable(detail: fitnessSnapshot.source.detail)
                        .frame(minHeight: 58)
                }
            }
        case .finance:
            VStack(alignment: .leading, spacing: 10) {
                if !financeOverviewMetrics.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(financeOverviewMetrics) { metric in
                            ValueMetric(value: metric.value, label: metric.label)
                        }
                    }
                    Text(financeState == .stale ? "Stale source · refresh required" : "Observed finance summary")
                    .lifeOSTypography(.metadata)
                        .foregroundStyle(financeState == .stale ? LifeOSTokens.warning : LifeOSTokens.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                } else if section.provenance.quality == .demo {
                    overviewFallbackMetrics
                } else {
                    OverviewChartUnavailable(detail: "Finance summary is not connected.")
                        .frame(minHeight: 58)
                }
            }
        case .llm:
            EmptyView()
        }
    }

    private var leadUsageSnapshot: ProviderSnapshot? {
        usageSnapshots.first(where: { $0.smallestObservedWindow != nil }) ?? usageSnapshots.first
    }

    private var leadUsageAnalytics: UsageAnalyticsSnapshot? {
        guard let lead = leadUsageSnapshot, let window = lead.smallestObservedWindow else { return nil }
        return UsageAnalyticsResolver.matching(snapshot: lead, candidates: usageAnalytics, windowID: window.id)
    }

    private var usageTrendPoints: [OverviewChartPoint] {
        guard let analytics = leadUsageAnalytics,
              OverviewUsageTrendPresentation.isRenderable(for: analytics.provenance.quality) else { return [] }
        return OverviewChartProjection.usageRemaining(from: analytics, window: leadUsageSnapshot?.smallestObservedWindow)
    }

    private var clipperTrend: OverviewClipperTrend? {
        guard let clipperSnapshot, clipperSnapshot.availability == .observed else { return nil }
        return OverviewChartProjection.preferredClipperTrend(from: clipperSnapshot.trends ?? [])
    }

    private var clipperChartDetail: String {
        if section.provenance.quality == .demo { return "DEMO fixture · no trend history supplied." }
        if clipperSnapshot?.availability == .observed { return "Not enough observed trend points for a chart." }
        return "Trend history is unavailable until the Clipper connector supplies it."
    }

    private var homeHealthMetrics: [FitnessMetric] {
        var candidates = fitnessSnapshot.healthMonitor
        candidates.append(contentsOf: fitnessSnapshot.loadDetail.trendCards.compactMap { card in
            switch card.id {
            case .steps, .totalEnergy: card.metric
            default: nil
            }
        })
        var seen = Set<String>()
        return candidates.filter { metric in
            guard metric.value != nil, metric.quality == .observed else { return false }
            return seen.insert(metric.id).inserted
        }.prefix(4).map { $0 }
    }

    private var financeOverviewMetrics: [OverviewDisplayMetric] {
        guard let financeSummary else { return [] }
        let candidates: [(String, FinanceAmountMetric?)] = [
            ("Spent", financeSummary.spent),
            ("Saved", financeSummary.saved),
            ("Income", financeSummary.monthlyIncome),
            ("Buffer", financeSummary.discretionaryBuffer)
        ]
        return candidates.compactMap { label, metric in
            guard let metric, metric.availability == .observed, let cents = metric.amountCents else { return nil }
            return OverviewDisplayMetric(label: label, value: overviewCurrency(cents: cents))
        }
    }

    private var overviewFallbackMetrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(section.metrics.filter { $0.value != nil }) { metric in
                ValueMetric(value: metric.displayValue, label: metric.label)
            }
        }
    }

    private func metricValue(containing needle: String) -> String? {
        section.metric(containing: needle)?.displayValue
    }

    private func clipperHomeMetricValue(containing needle: String) -> String? {
        guard needle.localizedCaseInsensitiveCompare("Revenue") == .orderedSame else {
            return metricValue(containing: needle)
        }
        if let revenue = clipperSnapshot?.metrics?.revenue,
           revenue.availability == .observed,
           let amountCents = revenue.amountCents {
            return OverviewCurrencyFormatter.eur(cents: amountCents)
        }
        return metricValue(containing: needle)
    }

    private func fitnessDisplayValue(_ metric: FitnessMetric) -> String? {
        guard let value = metric.value else { return nil }
        return metric.unit.isEmpty ? value : "\(value) \(metric.unit)"
    }

    private func overviewCurrency(cents: Int) -> String {
        OverviewCurrencyFormatter.eur(cents: cents)
    }

}

private struct OverviewDisplayMetric: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// A quiet, line-only trend accent: no fill, no axes, no gridlines. The single `tint` hue is
/// the card's one accent color — everything else on the card stays neutral. Deliberately
/// undecorated so it reads as a small supporting signal, not a dominant colored region.
private struct OverviewSparkline: View {
    let points: [OverviewChartPoint]
    let tint: Color
    @State private var selectedDate: Date?

    private var orderedPoints: [OverviewChartPoint] {
        points.sorted { $0.date < $1.date }
    }

    private var selectedPoint: OverviewChartPoint? {
        guard let selectedDate else { return nil }
        return orderedPoints.first { $0.date == selectedDate }
    }

    private var selectedPointValueText: String {
        selectedPoint?.value.formatted(.number.precision(.fractionLength(0...2))) ?? ""
    }

    private var selectedPointDateText: String {
        guard let date = selectedPoint?.date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var selectedPointIndex: Int {
        guard !orderedPoints.isEmpty else { return 0 }
        guard let selectedDate else { return orderedPoints.count - 1 }
        return orderedPoints.firstIndex { $0.date == selectedDate } ?? orderedPoints.count - 1
    }

    private var trendAccessibilityValue: String {
        guard let point = selectedPoint ?? orderedPoints.last else { return "No observations" }
        return point.value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        guard maximum > minimum else {
            let padding = max(abs(maximum) * 0.12, 1)
            return max(0, minimum - padding)...maximum + padding
        }
        let padding = max((maximum - minimum) * 0.16, abs(maximum) * 0.02)
        return max(0, minimum - padding)...maximum + padding
    }

    private var chartXDomain: ClosedRange<Date> {
        guard let first = orderedPoints.first?.date,
              let last = orderedPoints.last?.date,
              last > first else {
            let now = Date.now
            return now.addingTimeInterval(-60)...now.addingTimeInterval(60)
        }
        let padding = max(last.timeIntervalSince(first) * 0.02, 60)
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    var body: some View {
        Chart(orderedPoints) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Value", point.value)
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)

            if selectedDate == point.date {
                RuleMark(x: .value("Selected time", point.date))
                    .foregroundStyle(LifeOSTokens.metadataText.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                PointMark(
                    x: .value("Selected time", point.date),
                    y: .value("Selected value", point.value)
                )
                .foregroundStyle(tint)
                .symbolSize(32)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: chartXDomain)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let frame = geometry[plotFrame]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
#if os(iOS)
                        .simultaneousGesture(DragGesture(minimumDistance: LifeOSDirectionalClassifier.minimumDistance).onChanged { value in
                            guard LifeOSDirectionalClassifier.classify(value.translation) == .horizontal,
                                  let date = LifeOSChartKit.timestamp(
                                      forPlotX: value.location.x,
                                      in: frame,
                                      domain: chartXDomain
                                  ) else { return }
                            selectClosest(to: date)
                        })
                        .onTapGesture { location in
                            guard let date = LifeOSChartKit.timestamp(
                                forPlotX: location.x,
                                in: frame,
                                domain: chartXDomain
                            ) else { return }
                            selectClosest(to: date)
                        }
#elseif os(macOS)
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            if case .active(let location) = phase {
                                guard let date = LifeOSChartKit.timestamp(
                                    forPlotX: location.x,
                                    in: frame,
                                    domain: chartXDomain
                                ) else { return }
                                selectClosest(to: date)
                            }
                        }
#endif
                    if let selectedPoint,
                       let x = proxy.position(forX: selectedPoint.date),
                       let y = proxy.position(forY: selectedPoint.value) {
                        ScrubBubble(
                            x: frame.origin.x + x,
                            y: frame.origin.y + y,
                            bounds: frame
                        ) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(selectedPointValueText)
                                Text(selectedPointDateText)
                                    .lifeOSTypography(.metadata)
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend")
        .accessibilityValue(trendAccessibilityValue)
        .accessibilityHint(orderedPoints.count > 1 ? "Swipe left or right to inspect dates." : "")
        .accessibilityAdjustableAction { direction in
            guard !orderedPoints.isEmpty else { return }
            let currentIndex = selectedPointIndex
            let nextIndex: Int
            switch direction {
            case .increment:
                nextIndex = min(currentIndex + 1, orderedPoints.count - 1)
            case .decrement:
                nextIndex = max(currentIndex - 1, 0)
            @unknown default:
                nextIndex = currentIndex
            }
            selectedDate = orderedPoints[nextIndex].date
        }
        .onChange(of: orderedPoints) { _, newPoints in
            if let selectedDate, !newPoints.contains(where: { $0.date == selectedDate }) {
                self.selectedDate = nil
            }
        }
    }

    private func selectClosest(to date: Date) {
        let chartPoints = orderedPoints.map { LifeOSChartPoint(timestamp: $0.date, value: $0.value) }
        guard let nearest = LifeOSChartKit.nearestPoint(in: chartPoints, to: date) else { return }
        guard selectedDate != nearest.timestamp else { return }
        ScrubBubble<EmptyView>.snapHaptic()
        selectedDate = nearest.timestamp
    }
}

private struct OverviewChartUnavailable: View {
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Trend unavailable")
                .lifeOSTypography(.metadata, weight: .semibold)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(detail)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ValueMetric: View {
    let value: String?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value ?? "—")
                .lifeOSTypography(.button, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ClipperAnalyticsView: View {
    let section: OverviewSection
    let snapshot: ClipperSnapshot?
    let refreshAction: (() async -> Void)?
    let clipperState: ClipperLoadState
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(
                horizontalPadding: horizontalPadding,
                topPadding: 18,
                bottomPadding: 28
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    if let snapshot, snapshot.availability == .observed {
                        observedDetailCards(snapshot)
                    } else if section.provenance.quality == .demo {
                        demoDetailCard(
                            title: "Bot and account breakdown",
                            detail: "Fixture-only detail; this is a deterministic visual example and not live provider data."
                        )
                        demoDetailCard(
                            title: "Trends",
                            detail: "Fixture-only trend detail; no provider request or provider key is used in demo mode."
                        )
                    } else {
                        unavailableDetailCard(
                            title: "Bot and account breakdown",
                            detail: "Per-bot and per-account earnings, views and subscribers are unavailable until a reviewed provider connector supplies them. LifeOS does not keep provider keys on the client."
                        )
                        unavailableDetailCard(
                            title: "Trends",
                            detail: "Views, subscribers and revenue history are unavailable until a reviewed provider connector supplies them. LifeOS will not invent a trend line."
                        )
                    }
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
#endif
        .accessibilityIdentifier("clipper-analytics-screen")
    }

    private var horizontalPadding: CGFloat {
#if os(macOS)
        LifeOSTokens.overviewContentInset
#else
        18
#endif
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                LifeOSIcon(.clipper)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 18, height: 18)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[.bottom]
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clipper Analytics")
                        .lifeOSTypography(.sectionTitle)
                        .tracking(-0.2)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sourceStatusColor)
                            .frame(width: 6, height: 6)
                        Text(sourceStatus)
                            .lifeOSTypography(.metadata)
                            .tracking(0.2)
                            .foregroundStyle(sourceStatusColor)
                    }
                }
                Spacer(minLength: 8)
                refreshButton
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metricValue(containing: "Revenue") ?? "—")
                        .lifeOSTypography(.metric)
                        .tracking(-0.3)
                    Text("Revenue this month")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Circle()
                        .fill(sourceStatusColor)
                        .frame(width: 6, height: 6)
                    Text(snapshotBadge)
                        .lifeOSTypography(.label)
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(sourceStatusColor)
                }
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 14) {
                detailMetric(label: "Views today", value: metricValue(containing: "Views"))
                detailMetric(label: "Subscribers today", value: metricValue(containing: "Subscribers"))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
    }

    private func detailMetric(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value ?? "—")
                .lifeOSTypography(.body, weight: .semibold)
                .monospacedDigit()
            Text(label)
                .lifeOSTypography(.metadata)
                .tracking(0.2)
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func observedDetailCards(_ snapshot: ClipperSnapshot) -> some View {
        if let accounts = snapshot.accounts {
            observedAccountsCard(accounts)
        }
        if let breakdowns = snapshot.breakdowns {
            observedBreakdownsCard(breakdowns)
        }
        if let trends = snapshot.trends {
            observedTrendsCard(trends)
        }
    }

    private func observedAccountsCard(_ accounts: [ClipperAccount]) -> some View {
        observedDetailCard(title: "Accounts and bots") {
            if accounts.isEmpty {
                emptyObservedRow("No account or bot breakdown was supplied in this observed snapshot.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(accounts) { account in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(account.name)
                                    .lifeOSTypography(.label, weight: .semibold)
                                Spacer(minLength: 8)
                                Text("\(account.bots.count) bots · \(account.breakdowns.count) breakdowns")
                                    .lifeOSTypography(.metadata)
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                            compactMetricRow(account.metrics)
                            ForEach(account.bots) { bot in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(bot.name)
                                        .lifeOSTypography(.metadata, weight: .medium)
                                    compactMetricRow(bot.metrics)
                                }
                                .padding(.leading, 12)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
            }
        }
    }

    private func observedBreakdownsCard(_ breakdowns: [ClipperBreakdown]) -> some View {
        observedDetailCard(title: "Breakdowns") {
            if breakdowns.isEmpty {
                emptyObservedRow("No period breakdown was supplied in this observed snapshot.")
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(breakdowns) { breakdown in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(breakdown.label)
                                    .lifeOSTypography(.label, weight: .semibold)
                                Spacer(minLength: 8)
                                Text(periodLabel(start: breakdown.periodStart, end: breakdown.periodEnd))
                                    .lifeOSTypography(.metadata)
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                            compactMetricRow(breakdown.metrics)
                        }
                    }
                }
            }
        }
    }

    private func observedTrendsCard(_ trends: [ClipperTrendPoint]) -> some View {
        observedDetailCard(title: "Trends") {
            if trends.isEmpty {
                emptyObservedRow("No trend points were supplied in this observed snapshot.")
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(trends.suffix(8))) { trend in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(trend.at.formatted(date: .abbreviated, time: .shortened))
                                .lifeOSTypography(.metadata, weight: .semibold)
                            compactMetricRow(trend.metrics)
                        }
                    }
                    if trends.count > 8 {
                        Text("Showing the latest 8 of \(trends.count) observed points.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
            }
        }
    }

    private func observedDetailCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .lifeOSTypography(.cardTitle)
                .tracking(-0.1)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
    }

    private func compactMetricRow(_ metrics: ClipperMetricSet) -> some View {
        HStack(spacing: 10) {
            compactMetric(label: "Views", value: countValue(metrics.views))
            compactMetric(label: "Subscribers", value: countValue(metrics.subscribers))
            compactMetric(label: "Revenue", value: revenueValue(metrics.revenue))
        }
    }

    private func compactMetric(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .lifeOSTypography(.metadata, weight: .semibold)
                .monospacedDigit()
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyObservedRow(_ detail: String) -> some View {
        HStack(spacing: 10) {
            LifeOSIcon(.clipper)
                .frame(width: 15, height: 15)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(detail)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func periodLabel(start: Date, end: Date) -> String {
        "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }

    private func countValue(_ metric: ClipperCountMetric) -> String? {
        guard metric.availability == .observed, let value = metric.value else { return nil }
        return String(value)
    }

    private func revenueValue(_ metric: ClipperRevenueMetric) -> String? {
        guard metric.availability == .observed, let amountCents = metric.amountCents else { return nil }
        let euros = amountCents / 100
        let cents = amountCents % 100
        guard cents != 0 else { return "€\(euros)" }
        let centsText = cents < 10 ? "0\(cents)" : "\(cents)"
        return "€\(euros).\(centsText)"
    }

    private func unavailableDetailCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .lifeOSTypography(.cardTitle)
                .tracking(-0.1)
            HStack(spacing: 10) {
                LifeOSIcon(.clipper)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not connected")
                        .lifeOSTypography(.label, weight: .semibold)
                    Text(detail)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .combine)
    }

    private func demoDetailCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .lifeOSTypography(.cardTitle)
                .tracking(-0.1)
            HStack(spacing: 10) {
                LifeOSIcon(.clipper)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(LifeOSTokens.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DEMO FIXTURE · NOT LIVE")
                        .lifeOSTypography(.label, weight: .semibold)
                        .foregroundStyle(LifeOSTokens.warning)
                    Text(detail)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .combine)
    }

    private var sourceStatus: String {
        if clipperState == .stale {
            return "Stale · \(section.provenance.source) · refresh required"
        }
        switch section.provenance.quality {
        case .demo: return "Demo fixture · not live"
        case .unavailable: return "Not connected · Clipper connector required"
        case .observed where section.state == .partial: return "Partial observed · \(section.provenance.source)"
        case .observed:
            return section.provenance.connector == .refreshDue
                ? "Stale · \(section.provenance.source) · refresh required"
                : "Observed · \(section.provenance.source)"
        case .estimated: return "Estimated · \(section.provenance.source)"
        }
    }

    private var sourceStatusColor: Color {
        if section.provenance.quality == .demo || section.provenance.connector == .refreshDue || clipperState == .stale || section.state == .partial {
            return LifeOSTokens.warning
        }
        return LifeOSTokens.tertiaryText
    }

    private var snapshotBadge: String {
        if clipperState == .stale { return "Stale snapshot" }
        switch section.provenance.quality {
        case .demo: return "Demo snapshot"
        case .unavailable: return "Not connected"
        case .observed: return section.state == .partial ? "Partial snapshot" : section.provenance.connector == .refreshDue ? "Stale snapshot" : "Observed snapshot"
        case .estimated: return "Estimated snapshot"
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if let refreshAction {
            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task { @MainActor in
                    await refreshAction()
                    isRefreshing = false
                }
            } label: {
                Label(
                    isRefreshing ? "Refreshing…" : section.provenance.quality == .unavailable ? "Retry" : "Refresh",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRefreshing)
            .accessibilityIdentifier("clipper-refresh")
        }
    }

    private func metricValue(containing needle: String) -> String? {
        section.metric(containing: needle)?.displayValue
    }
}
