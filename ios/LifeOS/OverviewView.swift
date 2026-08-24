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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var cardNamespace
    @State private var selectedDetail: OverviewDetail?

    private enum OverviewDetail: Hashable {
        case clipper
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
                    bottomPadding: contentBottomPadding
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.bottom, headerBottomSpacing)
                        dashboard
                    }
                }
            }
#if os(iOS)
            .accessibilityIdentifier("overview-screen")
#endif
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .refreshable { await refreshAction?() }
            .navigationDestination(isPresented: $showingUsage) {
                UsageView(
                    snapshots: usageSnapshots,
                    analytics: usageAnalytics,
                    state: usageState,
                    refreshAction: refreshAction
                )
            }
            .navigationDestination(item: $selectedDetail) { destination in
                switch destination {
                case .clipper:
                    zoomTransitioned(
                        ClipperAnalyticsView(
                            section: clipperSection,
                            snapshot: snapshot.clipperSnapshot,
                            refreshAction: clipperRefreshAction,
                            clipperState: clipperState
                        ),
                        sourceID: OverviewSectionKind.clipper.rawValue
                    )
                }
            }
        }
    }

    private var responsiveHorizontalInset: CGFloat {
#if os(macOS)
        LifeOSTokens.overviewContentInset
#else
        18
#endif
    }

    private var headerTopSpacing: CGFloat {
#if os(macOS)
        28
#else
        14
#endif
    }

    private var headerBottomSpacing: CGFloat {
#if os(macOS)
        24
#else
        16
#endif
    }

    private var contentBottomPadding: CGFloat {
#if os(macOS)
        40
#else
        24
#endif
    }

    /// Usage is the lead signal. The other three surfaces form a responsive
    /// bento row on regular widths and a readable single column on iPhone.
    @ViewBuilder
    private var dashboard: some View {
        if let usage = visibleSections.first(where: { $0.kind == .llm }) {
            sectionRow(usage, featured: true)
                .transition(reduceMotion ? .identity : .opacity)
                .padding(.bottom, LifeOSTokens.overviewCardGap + 4)
        }

        let supportingSections = visibleSections.filter { $0.kind != .llm }
        if horizontalSizeClass == .compact {
            VStack(spacing: LifeOSTokens.overviewCardGap + 4) {
                ForEach(supportingSections) { section in
                    sectionRow(section)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
        } else {
            let hasOddFinalSection = supportingSections.count % 2 == 1
            let pairedSections = hasOddFinalSection ? Array(supportingSections.dropLast()) : supportingSections
            VStack(spacing: LifeOSTokens.overviewCardGap + 4) {
                if !pairedSections.isEmpty {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 320), spacing: LifeOSTokens.overviewCardGap + 4),
                            GridItem(.flexible(minimum: 320), spacing: LifeOSTokens.overviewCardGap + 4)
                        ],
                        alignment: .leading,
                        spacing: LifeOSTokens.overviewCardGap + 4
                    ) {
                        ForEach(pairedSections) { section in
                            sectionRow(section)
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                    }
                }
                if hasOddFinalSection, let finalSection = supportingSections.last {
                    sectionRow(finalSection)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
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
            }
        )
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
#if os(macOS)
        VStack(alignment: .leading, spacing: 5) {
            Text("Life OS")
                .font(LifeOSFont.manrope(32, weight: .extraBold))
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text("A quiet view of what matters now")
                    .font(LifeOSFont.callout())
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                statusBadge
            }
        }
        .accessibilityElement(children: .combine)
#else
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Life OS")
                    .font(LifeOSFont.manrope(28, weight: .extraBold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            Text("A quiet view of what matters now")
                .font(LifeOSFont.callout())
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(2)
            statusBadge
        }
        .accessibilityElement(children: .combine)
#endif
    }

    private var statusBadge: some View {
        // §4.2 dot + overline — no tinted capsule. Color is a signal:
        // warning for demo/stale/partial, tertiary when unavailable,
        // success only when data is genuinely connected.
        let isDemo = snapshotStatusLabel.hasPrefix("DEMO")
        let isStale = snapshotStatusLabel.hasPrefix("STALE")
        let needsReview = snapshotStatusLabel.hasPrefix("PARTIAL")
        let unavailable = snapshotStatusLabel == "DATA UNAVAILABLE"
        let color = isDemo || isStale || needsReview
            ? LifeOSTokens.warning
            : (unavailable ? LifeOSTokens.tertiaryText : LifeOSTokens.success)
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(snapshotStatusLabel)
                .font(LifeOSFont.overline())
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sectionRow(_ section: OverviewSection, featured: Bool = false) -> some View {
        switch section.kind {
        case .llm:
            if openDestination != nil {
                Button {
                    showingUsage = true
                } label: {
                    OverviewMetricCard(
                        section: section,
                        featured: featured,
                        usageSnapshots: usageSnapshots,
                        usageAnalytics: usageAnalytics,
                        fitnessSnapshot: fitnessSnapshot,
                        financeSummary: financeSummary,
                        financeState: financeState
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
                    financeState: financeState
                )
            }
        case .clipper:
            Button {
                if reduceMotion {
                    selectedDetail = .clipper
                } else {
                    withAnimation(LifeOSMotion.heroMorph) {
                        selectedDetail = .clipper
                    }
                }
            } label: {
                zoomSource(
                    OverviewMetricCard(
                        section: section,
                        usageSnapshots: usageSnapshots,
                        clipperState: clipperState,
                        clipperSnapshot: snapshot.clipperSnapshot,
                        fitnessSnapshot: fitnessSnapshot,
                        financeSummary: financeSummary,
                        financeState: financeState
                    ),
                    id: section.kind.rawValue
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
            if openDestination != nil {
                Button { openDestination?(.finance) } label: {
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
    }

    /// Tags the clipper card as the source of an iOS 18 zoom navigation transition.
    /// `matchedGeometryEffect` cannot animate across a `navigationDestination` boundary, so the
    /// hero-morph into `ClipperAnalyticsView` needs the dedicated `matchedTransitionSource` API
    /// instead. No-op on iOS 17 (falls back to a plain push) and on macOS, where
    /// `NavigationTransition.zoom` is unavailable entirely.
    @ViewBuilder
    private func zoomSource<Content: View>(_ content: Content, id: String) -> some View {
#if os(iOS)
        if reduceMotion {
            content
        } else if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: id, in: cardNamespace)
        } else {
            content
        }
#else
        content
#endif
    }

    /// Wraps a navigationDestination's content with the matching iOS 18 zoom transition. No-op
    /// on iOS 17, where the destination keeps today's plain push behavior, and on macOS, where
    /// `NavigationTransition.zoom` is unavailable entirely.
    @ViewBuilder
    private func zoomTransitioned<Content: View>(_ content: Content, sourceID: String) -> some View {
#if os(iOS)
        if reduceMotion {
            content
        } else if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: sourceID, in: cardNamespace))
        } else {
            content
        }
#else
        content
#endif
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
        financeState: FinanceLoadState
    ) -> Bool {
        switch section {
        case .llm:
            return quality == .demo || connector == .refreshDue || sectionState == .partial
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
        hasRefreshDueSection: Bool
    ) -> String {
        if qualities.allSatisfy({ $0 == .demo }) { return "DEMO FIXTURES · NOT LIVE DATA" }
        if healthState == .stale || financeState == .stale {
            return "STALE DATA · REFRESH REQUIRED"
        }
        if healthIntegrityIssue {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    init(section: OverviewSection, featured: Bool = false, usageSnapshots: [ProviderSnapshot] = [],
         usageAnalytics: [UsageAnalyticsSnapshot] = [],
         clipperState: ClipperLoadState = .unavailable, clipperSnapshot: ClipperSnapshot? = nil,
         fitnessSnapshot: FitnessSnapshot = .unavailable, financeSummary: FinanceSummary? = nil,
         financeState: FinanceLoadState = .unavailable) {
        self.section = section
        self.featured = featured
        self.usageSnapshots = usageSnapshots
        self.usageAnalytics = usageAnalytics
        self.clipperState = clipperState
        self.clipperSnapshot = clipperSnapshot
        self.fitnessSnapshot = fitnessSnapshot
        self.financeSummary = financeSummary
        self.financeState = financeState
    }

    private var title: String {
        switch section.kind {
        case .llm: "Usage"
        case .clipper: "Clipper Analytics"
        case .health: "Health"
        case .finance: "Finance"
        }
    }

    private var description: String {
        switch section.kind {
        case .llm: "Limits and activity across connected models"
        case .clipper: "Reach, audience and revenue across accounts"
        case .health: "Recovery, sleep and daily signals"
        case .finance: "Cash flow, spending and savings"
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
            financeState: financeState
        ) {
            return LifeOSTokens.warning
        }
        return LifeOSTokens.tertiaryText
    }

    /// True only for the plain "demo fixture" case, never for a stale/partial/not-connected
    /// status. The top-level header badge already states DEMO FIXTURES once; repeating the
    /// full yellow "Demo fixture · not live" line on every single card is noise, so those
    /// cards collapse to a small unobtrusive marker instead. Any other status (stale, partial,
    /// not connected, permission needed) stays as full text — that's load-bearing per-card
    /// information, not repetition.
    private var isPlainDemoStatus: Bool {
        sourceStatus == "Demo fixture · not live"
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
        VStack(alignment: .leading, spacing: featured ? 16 : 14) {
            // §5.1: no icon tile — a bare tertiary icon aligned to the title.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                LifeOSIcon(sectionIcon)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 18, height: 18)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[.bottom]
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(LifeOSFont.cardTitle())
                .tracking(-0.1)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(description)
                        .font(LifeOSFont.callout())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(featured ? 1 : 2)
                }
                Spacer(minLength: 8)
                if isPlainDemoStatus {
                    Circle()
                        .fill(LifeOSTokens.warning)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                LifeOSIcon(.chevronRight)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 12, height: 12)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[.bottom]
                    }
            }

            if !isPlainDemoStatus {
                // §4.2 status indicator: semantic dot + axis text. Amber only
                // when the source is genuinely stale/partial/demo.
                HStack(spacing: 6) {
                    Circle()
                        .fill(sourceStatusColor)
                        .frame(width: 6, height: 6)
                    Text(sourceStatus)
                        .font(LifeOSFont.axis())
                        .tracking(0.2)
                        .foregroundStyle(sourceStatusColor)
                        .lineLimit(section.kind == .health && healthIntegrityStatusPresent ? 2 : 1)
                        .minimumScaleFactor(0.78)
                }
                .accessibilityElement(children: .combine)
            }

            if featured && section.kind == .llm {
                usageBody
            } else {
                supportingBody
            }
        }
        .padding(.horizontal, featured ? 18 : 18)
        .padding(.vertical, featured ? 18 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: featured ? 196 : 190, alignment: .topLeading)
        .glassCard(featured: featured)
        // §5.1 hover (macOS): border brightens to strongBorder; no offset lift.
        .overlay(cardShape.stroke(hovering ? LifeOSTokens.strongBorder : Color.clear, lineWidth: 1))
        .animation(reduceMotion ? nil : LifeOSMotion.springSnappy, value: hovering)
#if os(macOS)
        .onHover { hovering = $0 }
#endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(sourceStatus)")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous)
    }

    @ViewBuilder
    private var usageBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                if let remaining = leadUsageSnapshot?.smallestObservedWindow?.usedPercent.map({ 1 - $0 }) {
                    Text("\(Int((remaining * 100).rounded()))")
                        .font(LifeOSFont.kpi())
                        .tracking(-0.3)
                        .foregroundStyle(.primary)
                    Text("% remaining")
                        .font(LifeOSFont.callout())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .padding(.bottom, 6)
                } else {
                    Text("—")
                        .font(LifeOSFont.kpi())
                        .tracking(-0.3)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(leadUsageSnapshot?.provider.displayName ?? "Usage")
                        .font(LifeOSFont.callout().weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(usageTrendLabel)
                        .font(.caption2)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }

            if usageTrendPoints.count >= 2 {
                OverviewSparkline(points: usageTrendPoints, tint: LifeOSTokens.accent)
                    .frame(height: 44)
            } else {
                OverviewChartUnavailable(detail: usageChartDetail)
                    .frame(minHeight: 44)
            }

            HStack(spacing: 8) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    UsageMiniRing(provider: provider, snapshot: usageSnapshots.first { $0.provider == provider })
                }
            }
        }
    }

    @ViewBuilder
    private var supportingBody: some View {
        switch section.kind {
        case .clipper:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ValueMetric(value: clipperHomeMetricValue(containing: "Views"), label: "Views today")
                    ValueMetric(value: clipperHomeMetricValue(containing: "Subscribers"), label: "Subscribers")
                    ValueMetric(value: clipperHomeMetricValue(containing: "Revenue"), label: "Revenue")
                }
                if let clipperTrend {
                    OverviewSparkline(points: clipperTrend.points, tint: LifeOSTokens.accent)
                        .frame(height: 36)
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
                        .font(.caption2)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
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
                        .font(.caption2)
                        .foregroundStyle(financeState == .stale ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
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

    private var usageTrendLabel: String {
        OverviewUsageTrendPresentation.label(for: leadUsageAnalytics?.provenance.quality)
    }

    private var usageChartDetail: String {
        guard leadUsageSnapshot != nil else { return "No provider observations are connected." }
        guard leadUsageAnalytics != nil else { return "Usage history is unavailable for this provider window." }
        return "Not enough observed history for a trend."
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Value", point.value)
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: yDomain)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend")
        .accessibilityValue(points.last.map { String(format: "%.2f", $0.value) } ?? "No observations")
    }
}

private struct OverviewChartUnavailable: View {
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Trend unavailable")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct UsageMiniRing: View {
    let provider: Provider
    let snapshot: ProviderSnapshot?

    private var remaining: Double? {
        snapshot?.smallestObservedWindow?.usedPercent.map { 1 - $0 }
    }

    var body: some View {
        VStack(spacing: 3) {
            // §5.1 mini rings: plain accent arc, no halo, hairline track.
            GlowRing(progress: remaining ?? 0, diameter: 38, lineWidth: 3) {
                Text(remaining.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Text(provider.displayName)
                .font(LifeOSFont.axis())
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(remaining.map { "\(Int(($0 * 100).rounded())) percent remaining" } ?? "Not connected")
    }
}

private struct ValueMetric: View {
    let value: String?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value ?? "—")
                .font(LifeOSFont.callout().weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(LifeOSFont.axis())
                .tracking(0.2)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(1)
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
                    heroCard.transition(.opacity)
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
        .navigationTitle("Clipper Analytics")
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
                        .font(LifeOSFont.title())
                        .tracking(-0.2)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sourceStatusColor)
                            .frame(width: 6, height: 6)
                        Text(sourceStatus)
                            .font(LifeOSFont.axis())
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
                        .font(LifeOSFont.kpi(42))
                        .tracking(-0.3)
                    Text("Revenue this month")
                        .font(LifeOSFont.metadata())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Circle()
                        .fill(sourceStatusColor)
                        .frame(width: 6, height: 6)
                    Text(snapshotBadge)
                        .font(LifeOSFont.overline())
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
        .glassCard()
    }

    private func detailMetric(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value ?? "—")
                .font(LifeOSFont.callout().weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(LifeOSFont.axis())
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
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 8)
                                Text("\(account.bots.count) bots · \(account.breakdowns.count) breakdowns")
                                    .font(.caption2)
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                            compactMetricRow(account.metrics)
                            ForEach(account.bots) { bot in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(bot.name)
                                        .font(.caption.weight(.medium))
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
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(periodLabel(start: breakdown.periodStart, end: breakdown.periodEnd))
                                    .font(.caption2)
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
                                .font(.caption.weight(.semibold))
                            compactMetricRow(trend.metrics)
                        }
                    }
                    if trends.count > 8 {
                        Text("Showing the latest 8 of \(trends.count) observed points.")
                            .font(.caption2)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
            }
        }
    }

    private func observedDetailCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(LifeOSFont.cardTitle())
                .tracking(-0.1)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
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
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
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
                .font(.caption)
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
                .font(LifeOSFont.cardTitle())
                .tracking(-0.1)
            HStack(spacing: 10) {
                LifeOSIcon(.clipper)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not connected")
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }

    private func demoDetailCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(LifeOSFont.cardTitle())
                .tracking(-0.1)
            HStack(spacing: 10) {
                LifeOSIcon(.clipper)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(LifeOSTokens.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DEMO FIXTURE · NOT LIVE")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LifeOSTokens.warning)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
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
