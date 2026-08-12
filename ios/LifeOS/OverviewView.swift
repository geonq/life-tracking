import Foundation
import SwiftUI

struct OverviewView: View {
    private let snapshot: OverviewSnapshot
    private let usageSnapshots: [ProviderSnapshot]
    private let usageAnalytics: [UsageAnalyticsSnapshot]
    private let usageState: UsageLoadState
    private let refreshAction: (() async -> Void)?
    private let clipperRefreshAction: (() async -> Void)?
    private let clipperState: ClipperLoadState
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
                    ClipperAnalyticsView(
                        section: clipperSection,
                        snapshot: snapshot.clipperSnapshot,
                        refreshAction: clipperRefreshAction,
                        clipperState: clipperState,
                        namespace: cardNamespace
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
            VStack(spacing: 16) {
                if !pairedSections.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.flexible(minimum: 320), spacing: 16), GridItem(.flexible(minimum: 320), spacing: 16)],
                        alignment: .leading,
                        spacing: 16
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
        if qualities.allSatisfy({ $0 == .demo }) { return "DEMO FIXTURES · NOT LIVE DATA" }
        if qualities.allSatisfy({ $0 == .unavailable }) { return "DATA UNAVAILABLE" }
        if clipperState == .stale || visibleSections.contains(where: { $0.provenance.quality == .observed && $0.provenance.connector == .refreshDue }) {
            return "STALE DATA · REFRESH REQUIRED"
        }
        return "CONNECTED DATA"
    }

    private var header: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 5) {
            Text("Life OS")
                .font(LifeOSFont.manrope(32, weight: .extraBold))
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text("A quiet view of what matters now")
                    .font(LifeOSFont.inter(13, weight: .regular))
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
                .font(LifeOSFont.inter(13, weight: .regular))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(2)
            statusBadge
        }
        .accessibilityElement(children: .combine)
#endif
    }

    private var statusBadge: some View {
        let isDemo = snapshotStatusLabel.hasPrefix("DEMO")
        let isStale = snapshotStatusLabel.hasPrefix("STALE")
        let color = isDemo || isStale ? LifeOSTokens.warning : LifeOSTokens.accent
        return Text(snapshotStatusLabel)
            .font(LifeOSFont.inter(9, weight: .semiBold))
            .tracking(0.45)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func sectionRow(_ section: OverviewSection, featured: Bool = false) -> some View {
        switch section.kind {
        case .llm:
            if openDestination != nil {
                Button {
                    showingUsage = true
                } label: {
                    matchedSource(
                        OverviewMetricCard(section: section, featured: featured, usageSnapshots: usageSnapshots),
                        id: section.kind.rawValue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("account-usage-link")
                .accessibilityHint("Opens detailed Usage analytics")
            } else {
                matchedSource(
                    OverviewMetricCard(section: section, featured: featured, usageSnapshots: usageSnapshots),
                    id: section.kind.rawValue
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
                matchedSource(
                    OverviewMetricCard(section: section, usageSnapshots: usageSnapshots, clipperState: clipperState),
                    id: section.kind.rawValue
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview-clipper-card")
            .accessibilityHint("Opens Clipper Analytics; connector status and unavailable fields are shown honestly")
        case .health:
            if openDestination != nil {
                Button { openDestination?(.fitness) } label: {
                    matchedSource(
                        OverviewMetricCard(section: section, usageSnapshots: usageSnapshots),
                        id: section.kind.rawValue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overview-health-link")
                .accessibilityHint("Opens Fitness")
            } else {
                matchedSource(
                    OverviewMetricCard(section: section, usageSnapshots: usageSnapshots),
                    id: section.kind.rawValue
                )
            }
        case .finance:
            if openDestination != nil {
                Button { openDestination?(.finance) } label: {
                    matchedSource(
                        OverviewMetricCard(section: section, usageSnapshots: usageSnapshots),
                        id: section.kind.rawValue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overview-finance-link")
                .accessibilityHint("Opens Finance")
            } else {
                matchedSource(
                    OverviewMetricCard(section: section, usageSnapshots: usageSnapshots),
                    id: section.kind.rawValue
                )
            }
        }
    }

    @ViewBuilder
    private func matchedSource<Content: View>(_ content: Content, id: String) -> some View {
        if reduceMotion {
            content
        } else {
            content.matchedCard(id: id, in: cardNamespace)
        }
    }
}

private struct OverviewMetricCard: View {
    let section: OverviewSection
    let featured: Bool
    let usageSnapshots: [ProviderSnapshot]
    let clipperState: ClipperLoadState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    init(section: OverviewSection, featured: Bool = false, usageSnapshots: [ProviderSnapshot] = [],
         clipperState: ClipperLoadState = .unavailable) {
        self.section = section
        self.featured = featured
        self.usageSnapshots = usageSnapshots
        self.clipperState = clipperState
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
        if section.provenance.quality == .demo || section.provenance.connector == .refreshDue || clipperState == .stale || section.state == .partial {
            return LifeOSTokens.warning
        }
        return LifeOSTokens.tertiaryText
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
        VStack(alignment: .leading, spacing: featured ? 18 : 14) {
            HStack(spacing: 12) {
                LifeOSIcon(sectionIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .frame(width: LifeOSTokens.overviewIconTile, height: LifeOSTokens.overviewIconTile)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(LifeOSFont.spaceGrotesk(featured ? 18 : 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(description)
                        .font(LifeOSFont.inter(12.5, weight: .regular))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                LifeOSIcon(.chevronRight)
                    .foregroundStyle(LifeOSTokens.accent.opacity(0.8))
                    .frame(width: 14, height: 14)
            }

            Text(sourceStatus)
                .font(LifeOSFont.inter(10.5, weight: .medium))
                .foregroundStyle(sourceStatusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            if featured && section.kind == .llm {
                usageBody
            } else {
                supportingBody
            }
        }
        .padding(.horizontal, featured ? 24 : 20)
        .padding(.vertical, featured ? 20 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: featured ? 238 : 264, alignment: .topLeading)
        .background(cardBackground, in: cardShape)
        .overlay(cardShape.stroke(hovering ? Color.primary.opacity(0.18) : LifeOSTokens.quietBorder, lineWidth: 0.75))
        .contentShape(cardShape)
        .offset(y: hovering && !reduceMotion ? -1 : 0)
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

    private var cardBackground: LinearGradient {
        LinearGradient(
            colors: [LifeOSTokens.surface, LifeOSTokens.surface.opacity(featured ? 0.96 : 0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var usageBody: some View {
        ViewThatFits(in: .horizontal) {
            wideUsageBody
            compactUsageBody
        }
    }

    private var wideUsageBody: some View {
        HStack(alignment: .center, spacing: 22) {
            UsageLeadRing(snapshot: leadUsageSnapshot)
            usageSummaryAndProviderRings
        }
        .frame(minWidth: 670, alignment: .leading)
    }

    private var compactUsageBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                UsageLeadRing(snapshot: leadUsageSnapshot)
                VStack(alignment: .leading, spacing: 5) {
                    Text(leadUsageSnapshot?.provider.displayName ?? "Usage")
                        .font(LifeOSFont.spaceGrotesk(15, weight: .medium))
                    Text(leadUsageSnapshot == nil ? "No provider observations are connected." : "Current provider window")
                        .font(LifeOSFont.inter(12, weight: .regular))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    UsageMiniRing(provider: provider, snapshot: usageSnapshots.first { $0.provider == provider })
                }
            }
        }
    }

    private var usageSummaryAndProviderRings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(leadUsageSnapshot?.provider.displayName ?? "Usage")
                .font(LifeOSFont.spaceGrotesk(15, weight: .medium))
            Text(leadUsageSnapshot == nil ? "No provider observations are connected." : "Current provider window")
                .font(LifeOSFont.inter(12, weight: .regular))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    UsageMiniRing(provider: provider, snapshot: usageSnapshots.first { $0.provider == provider })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var supportingBody: some View {
        switch section.kind {
        case .clipper:
            HStack(spacing: 14) {
                ValueMetric(value: metricValue(containing: "Views"), label: "Views today")
                ValueMetric(value: metricValue(containing: "Subscribers"), label: "Subscribers")
                ValueMetric(value: metricValue(containing: "Revenue"), label: "Revenue")
            }
        case .health:
            HStack(alignment: .center, spacing: 16) {
                HealthSleepRing(value: percentValue(containing: "Sleep"))
                VStack(alignment: .leading, spacing: 9) {
                    ValueMetric(value: metricValue(containing: "heart"), label: "Resting HR")
                    ValueMetric(value: metricValue(containing: "Steps"), label: "Steps")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .finance:
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    ValueMetric(value: metricValue(containing: "Savings"), label: "Savings goal")
                    ValueMetric(value: metricValue(containing: "budget"), label: "Monthly budget")
                }
                OverviewUnavailableTrack(label: "History", detail: "Not connected")
                    .frame(maxWidth: .infinity)
            }
        case .llm:
            EmptyView()
        }
    }

    private var leadUsageSnapshot: ProviderSnapshot? {
        usageSnapshots.first(where: { $0.smallestObservedWindow != nil }) ?? usageSnapshots.first
    }

    private func metricValue(containing needle: String) -> String? {
        section.metric(containing: needle)?.displayValue
    }

    private func percentValue(containing needle: String) -> Double? {
        guard let raw = section.metric(containing: needle)?.value,
              let number = Double(raw.replacingOccurrences(of: "%", with: "")) else { return nil }
        return min(max(number / 100, 0), 1)
    }
}

private struct UsageLeadRing: View {
    let snapshot: ProviderSnapshot?

    private var remaining: Double? {
        snapshot?.smallestObservedWindow?.usedPercent.map { 1 - $0 }
    }

    var body: some View {
        GlowRing(progress: remaining ?? 0, hue: .blue, diameter: 142, lineWidth: 12) {
            VStack(spacing: 2) {
                if let remaining {
                    Text("\(Int((remaining * 100).rounded()))")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .numericTransition()
                    Text("% left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                } else {
                    Text("—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Not connected")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
        .accessibilityLabel(snapshot?.provider.displayName ?? "Usage")
        .accessibilityValue(remaining.map { "\(Int(($0 * 100).rounded())) percent remaining" } ?? "Not connected")
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
            GlowRing(progress: remaining ?? 0, hue: .blue, diameter: 38, lineWidth: 4) {
                Text(remaining.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Text(provider.displayName)
                .font(.system(size: 8.5, weight: .medium))
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

private struct HealthSleepRing: View {
    let value: Double?

    var body: some View {
        GlowRing(progress: value ?? 0, hue: .green, diameter: 86, lineWidth: 8) {
            VStack(spacing: 1) {
                Text(value.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(value == nil ? "Not connected" : "% sleep")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .accessibilityLabel("Sleep quality")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Not connected")
    }
}

private struct ValueMetric: View {
    let value: String?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value ?? "—")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewUnavailableTrack: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Spacer(minLength: 4)
                Text("—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 5)
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LifeOSTokens.tertiaryText)
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
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(
                horizontalPadding: horizontalPadding,
                topPadding: 18,
                bottomPadding: 28
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    matchedDetail(heroCard)
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
            HStack(spacing: 12) {
                LifeOSIcon(.clipper)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .frame(width: LifeOSTokens.overviewIconTile, height: LifeOSTokens.overviewIconTile)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clipper Analytics")
                        .font(LifeOSFont.spaceGrotesk(20, weight: .medium))
                    Text(sourceStatus)
                        .font(LifeOSFont.inter(11, weight: .medium))
                        .foregroundStyle(sourceStatusColor)
                }
                Spacer(minLength: 8)
                refreshButton
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metricValue(containing: "Revenue") ?? "—")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("Revenue this month")
                        .font(.caption)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 12)
                Text(snapshotBadge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(sourceStatusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            HStack(spacing: 14) {
                detailMetric(label: "Views today", value: metricValue(containing: "Views"))
                detailMetric(label: "Subscribers today", value: metricValue(containing: "Subscribers"))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
    }

    @ViewBuilder
    private func matchedDetail<Content: View>(_ content: Content) -> some View {
        if reduceMotion {
            content.transition(.opacity)
        } else {
            content
                .matchedCard(id: OverviewSectionKind.clipper.rawValue, in: namespace)
                .transition(.opacity)
        }
    }

    private func detailMetric(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
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
                .font(LifeOSFont.spaceGrotesk(16, weight: .medium))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
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
                .font(LifeOSFont.spaceGrotesk(16, weight: .medium))
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
        .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .accessibilityElement(children: .combine)
    }

    private func demoDetailCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(LifeOSFont.spaceGrotesk(16, weight: .medium))
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
        .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
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
