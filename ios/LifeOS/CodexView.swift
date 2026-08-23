import SwiftUI
import Charts

struct CodexView: View {
    let snapshot: ProviderSnapshot
    let analytics: [UsageAnalyticsSnapshot]

    init(snapshot: ProviderSnapshot, analytics: [UsageAnalyticsSnapshot] = []) {
        self.snapshot = snapshot
        self.analytics = analytics
    }

    var body: some View {
        UsageView(snapshots: [snapshot], analytics: analytics)
    }
}

// MARK: - Usage screen shell (02-charts-rings-widgets.md §0)
//
// Layout: hero row -> metadata row -> honesty banner -> Graphs/Facts/Insights tabs.
// Graphs tab: control row (Graph/Range/Account) + projection chart or token-activity chart.
// Facts tab: key-value list, honest "Not available" for every unbacked field.
// Insights tab: honest empty state, never fabricated.
//
// Model mix + heatmap (02 §4/§5) have no slot in the reference's top-level tabs; they are
// kept as supplementary cards below the tab content so real functionality isn't dropped
// silently (see Coordination/HANDOFF.md note from this workstream).

enum UsageGraphKind: String, CaseIterable, Hashable {
    case remaining = "Usage remaining"
    case tokenActivity = "Token activity"
}

enum UsageRange: String, CaseIterable, Hashable {
    case fiveHour = "5h"
    case sevenDay = "7d"

    var durationMinutes: Int {
        switch self {
        case .fiveHour: 300
        case .sevenDay: 10_080
        }
    }

    var accessibilityName: String {
        switch self {
        case .fiveHour: "5-hour window"
        case .sevenDay: "7-day window"
        }
    }

    static func matching(durationMinutes: Int?) -> Self? {
        guard let durationMinutes else { return nil }
        return allCases.first { $0.durationMinutes == durationMinutes }
    }
}

enum UsageTab: String, CaseIterable, Hashable {
    case graphs = "Graphs"
    case facts = "Facts"
    case insights = "Insights"
}

struct UsageView: View {
    let snapshots: [ProviderSnapshot]
    let state: UsageLoadState
    let refreshAction: (() async -> Void)?
    private let analytics: [UsageAnalyticsSnapshot]

    @State private var selectedProvider: Provider
    @State private var selectedTab: UsageTab = .graphs
    @State private var selectedGraph: UsageGraphKind = .remaining
    @State private var selectedRange: UsageRange = .fiveHour
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    init(snapshots: [ProviderSnapshot], analytics: [UsageAnalyticsSnapshot], state: UsageLoadState = .observed, refreshAction: (() async -> Void)? = nil) {
        self.snapshots = snapshots
        self.state = state
        self.refreshAction = refreshAction
        self.analytics = analytics
        _selectedProvider = State(initialValue: snapshots.first?.provider ?? .codex)
    }

    private var activeSnapshot: ProviderSnapshot? {
        // Do not fall back to another provider: an unavailable selected identity
        // must never render a different provider's observed numbers or analytics.
        snapshots.first { $0.provider == selectedProvider }
    }

    private var activeAnalytics: UsageAnalyticsSnapshot? {
        guard let activeSnapshot else { return nil }
        return UsageAnalyticsResolver.matching(
            snapshot: activeSnapshot,
            candidates: analytics,
            windowID: selectedWindow(in: activeSnapshot)?.id
        )
    }

    private var availableRanges: Set<UsageRange> {
        Set(activeSnapshot?.windows.compactMap { UsageRange.matching(durationMinutes: $0.durationMinutes) } ?? [])
    }

    private func preferredRange(for snapshot: ProviderSnapshot?) -> UsageRange {
        guard let snapshot else { return .fiveHour }
        let candidates = snapshot.windows.compactMap { UsageRange.matching(durationMinutes: $0.durationMinutes) }
        let observed = snapshot.windows.compactMap { window -> UsageRange? in
            guard window.usedPercent != nil else { return nil }
            return UsageRange.matching(durationMinutes: window.durationMinutes)
        }
        return observed.first(where: { $0 == .fiveHour }) ?? observed.first ?? candidates.first ?? .fiveHour
    }

    private func selectedWindow(in snapshot: ProviderSnapshot) -> UsageWindow? {
        snapshot.windows.first { $0.durationMinutes == selectedRange.durationMinutes }
            ?? snapshot.smallestObservedWindow
    }

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(
                horizontalPadding: usageHorizontalPadding,
                topPadding: usageTopPadding,
                bottomPadding: usageBottomPadding
            ) {
                VStack(alignment: .leading, spacing: 16) {
#if os(iOS)
                    backButton
#endif
                    if let activeSnapshot {
                        let window = selectedWindow(in: activeSnapshot)
                        heroRow(window: window)
                        metadataRow(activeSnapshot, window: window)
                        honestyBanner(activeSnapshot, window: window)
                        UsageLimitsCard(snapshot: activeSnapshot, selectedWindow: window)
                        UsageTabBar(selection: $selectedTab)

                        tabContent(activeSnapshot, window: window)
                    } else {
                        providerSwitcher
                        UsageEmptyState(
                            title: "Usage data unavailable",
                            detail: "No provider account is connected. LifeOS will not display placeholder usage."
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("usage-screen")
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
        .tint(LifeOSTokens.accent)
        .animation(reduceMotion ? nil : LifeOSMotion.primary, value: selectedProvider)
        .animation(reduceMotion ? nil : LifeOSMotion.snappy, value: selectedTab)
        .refreshable { await refreshAction?() }
        .onAppear {
            if !snapshots.contains(where: { $0.provider == selectedProvider }), let first = snapshots.first {
                selectedProvider = first.provider
            }
            selectedRange = preferredRange(for: activeSnapshot)
        }
        .onChange(of: selectedProvider) { _, newProvider in
            selectedRange = preferredRange(for: snapshots.first { $0.provider == newProvider })
        }
    }

    private var usageHorizontalPadding: CGFloat {
#if os(iOS)
        18
#else
        LifeOSTokens.pagePadding
#endif
    }

    private var usageTopPadding: CGFloat {
#if os(iOS)
        10
#else
        LifeOSTokens.pagePadding
#endif
    }

    private var usageBottomPadding: CGFloat {
#if os(iOS)
        24
#else
        LifeOSTokens.pagePadding
#endif
    }

#if os(iOS)
    private var backButton: some View {
        Button { dismiss() } label: {
            LifeOSIcon(.chevronLeft)
                .frame(width: 15, height: 15)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.055), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("usage-back")
    }
#endif

    // MARK: Hero row (§0.1) — the reference puts existing chrome in this row.

    private var heroActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await refreshAction?() }
            } label: {
                LifeOSIcon(.refresh)
                    .frame(width: 14, height: 14)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(state == .loading ? LifeOSTokens.accent : .secondary)
            .disabled(refreshAction == nil || state == .loading)
            .accessibilityLabel("Refresh usage data")

            NavigationLink {
                ProviderConnectionsSettingsView()
            } label: {
                LifeOSIcon(.settings)
                    .frame(width: 14, height: 14)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Usage settings")
        }
    }

    // MARK: Hero row (§0.1)

    private func heroRow(window: UsageWindow?) -> some View {
        let remainingPercent = window?.usedPercent.map { 100 - $0 * 100 }

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let remainingPercent {
                        Text("\(Int(remainingPercent.rounded()))")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .numericTransition()
                    } else {
                        Text("—")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    Text(remainingPercent == nil ? "Not connected" : "% remaining")
                        .font(.title3)
                        .foregroundStyle(remainingPercent == nil ? LifeOSTokens.tertiaryText : LifeOSTokens.secondaryTextCompat)
                }
                Text(window?.label ?? "Current window")
                    .font(.caption)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 12)
            heroActions
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(remainingPercent.map { "\(Int($0.rounded())) percent remaining, \(window?.label ?? "current window")" } ?? "Usage not connected, \(window?.label ?? "current window")")
    }

    // MARK: Metadata row (§0.2)

    private func metadataRow(_ snapshot: ProviderSnapshot, window: UsageWindow?) -> some View {
        ViewThatFits(in: .horizontal) {
            // Keep the reference's three-fact row on wide surfaces. The minimum widths make
            // ViewThatFits choose the readable compact layout before SwiftUI can squeeze a
            // reset date or provenance value into an ellipsis on iPhone.
            HStack(alignment: .top, spacing: 16) {
                metadataItem(label: "Reset", value: resetText(window))
                    .frame(minWidth: 150, alignment: .leading)
                metadataItem(label: "Banked resets", value: "Not available")
                    .frame(minWidth: 130, alignment: .leading)
                metadataItem(label: "Freshness", value: freshnessText(snapshot, window: window))
                    .frame(minWidth: 130, alignment: .leading)
            }

            // Compact surfaces get one full-width reset fact, then two equal-width facts. This
            // preserves all labels and values while allowing long dates to wrap naturally.
            VStack(alignment: .leading, spacing: 10) {
                metadataItem(label: "Reset", value: resetText(window))
                HStack(alignment: .top, spacing: 16) {
                    metadataItem(label: "Banked resets", value: "Not available")
                    metadataItem(label: "Freshness", value: freshnessText(snapshot, window: window))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func resetText(_ window: UsageWindow?) -> String {
        guard let resetAt = window?.resetAt else { return "Not available" }
        return resetAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    private func freshnessText(_ snapshot: ProviderSnapshot, window: UsageWindow?) -> String {
        let provenance = window?.provenance ?? snapshot.provenance
        switch provenance.freshness() {
        case .fresh:
            let minutes = max(0, Int(Date.now.timeIntervalSince(provenance.observedAt) / 60))
            return minutes <= 1 ? "Just now" : "\(minutes) min ago"
        case .aging:
            let minutes = max(0, Int(Date.now.timeIntervalSince(provenance.observedAt) / 60))
            return "\(minutes) min ago"
        case .stale: return "Stale"
        case .unavailable: return "Not connected"
        }
    }

    private func metadataItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .foregroundStyle(LifeOSTokens.secondaryTextCompat)
                .font(.caption2)
            Text(value)
                .foregroundStyle(.primary)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Honesty banner (§0.3)

    private func honestyBanner(_ snapshot: ProviderSnapshot, window: UsageWindow?) -> some View {
        let quality = window?.provenance?.quality ?? snapshot.provenance.quality
        let notice: (title: String, detail: String)?
        if window?.usedPercent == nil || quality == .unavailable {
            notice = ("No validated data", "Not connected for this window")
        } else {
            switch quality {
            case .observed:
                notice = nil
            case .estimated:
                let confidence = window?.projection?.confidence.map {
                    " · confidence \(Int(($0 * 100).rounded()))%"
                } ?? ""
                notice = ("Derived estimate · non-official", "Projection only\(confidence)")
            case .demo:
                notice = ("Demo fixture · not live", "Synthetic values for visual QA")
            case .unavailable:
                notice = ("No validated data", "Not connected for this window")
            }
        }

        return Group {
            if let notice {
                HStack(alignment: .top, spacing: 8) {
                    LifeOSIcon(.usage)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notice.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(notice.detail)
                            .font(.caption2)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Tab content

    @ViewBuilder
    private func tabContent(_ snapshot: ProviderSnapshot, window: UsageWindow?) -> some View {
        switch selectedTab {
        case .graphs:
            graphsTab(snapshot, window: window)
        case .facts:
            UsageFactsView(snapshot: snapshot, analytics: activeAnalytics)
        case .insights:
            UsageInsightsView(analytics: activeAnalytics)
        }
    }

    private func graphsTab(_ snapshot: ProviderSnapshot, window: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            controlRow

            if let activeAnalytics {
                switch selectedGraph {
                case .remaining:
                    UsageProjectionChart(provider: snapshot.provider, window: window, analytics: activeAnalytics)
                case .tokenActivity:
                    UsageTokenActivityView(provider: snapshot.provider, activity: activity(in: window, analytics: activeAnalytics))
                }
            } else {
                UsageEmptyState(
                    title: window?.usedPercent == nil ? "\(snapshot.provider.displayName) unavailable" : "Analytics unavailable",
                    detail: window?.usedPercent == nil
                        ? "No validated observation is connected for this provider."
                        : "No activity or projection data was supplied; LifeOS will not invent one."
                )
            }
        }
    }

    private func activity(in window: UsageWindow?, analytics: UsageAnalyticsSnapshot) -> [UsageActivityPoint] {
        guard let window, let resetAt = window.resetAt, let durationMinutes = window.durationMinutes else {
            return analytics.activity.sorted { $0.date < $1.date }
        }
        let start = resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
        return analytics.activity
            .filter { $0.date >= start && $0.date <= resetAt }
            .sorted { $0.date < $1.date }
    }

    private var controlRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 145, maximum: 360), alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            controlMenu(label: "Graph") {
                Picker("Graph", selection: $selectedGraph) {
                    ForEach(UsageGraphKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
            } valueText: { selectedGraph.rawValue }

            controlMenu(label: "Range") {
                Picker("Range", selection: $selectedRange) {
                    ForEach(UsageRange.allCases, id: \.self) { range in
                        Text(availableRanges.contains(range) ? range.rawValue : "\(range.rawValue) · Not connected")
                            .tag(range)
                            .disabled(!availableRanges.contains(range))
                    }
                }
            } valueText: { activeSnapshot.flatMap { selectedWindow(in: $0)?.label } ?? "Not available" }

            providerSwitcher
        }
    }

    private var providerSwitcher: some View {
        Menu {
            Picker("Provider", selection: $selectedProvider) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    Text("\(provider.displayName) · \(statusText(for: provider))").tag(provider)
                }
            }
        } label: {
            HStack(spacing: 4) {
                LifeOSIcon(.assistant).frame(width: 12, height: 12)
                Text("Provider · \(selectedProvider.displayName) · \(statusText(for: selectedProvider))")
                    .font(.caption)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Provider switcher, currently \(selectedProvider.displayName), \(statusText(for: selectedProvider))")
    }

    private func statusText(for provider: Provider) -> String {
        guard let snapshot = snapshots.first(where: { $0.provider == provider }) else { return "Not connected" }
        switch snapshot.provenance.quality {
        case .observed:
            switch snapshot.provenance.connector {
            case .healthy: return "Connected"
            case .refreshDue: return "Refresh due"
            case .reauthRequired: return "Re-auth required"
            case .rateLimited: return "Rate limited"
            case .revoked, .disabled, .unavailable, .error: return "Unavailable"
            }
        case .demo: return "Demo · not live"
        case .estimated: return "Estimate · non-official"
        case .unavailable: return "Unavailable"
        }
    }

    @ViewBuilder
    private func controlMenu<Content: View>(label: String, @ViewBuilder content: () -> Content, valueText: () -> String) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(valueText())
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                LifeOSIcon(.chevronRight)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.primary)
    }
}

private struct UsageInsightsView: View {
    let analytics: UsageAnalyticsSnapshot?

    var body: some View {
        if let analytics, (!analytics.modelBreakdowns.isEmpty || !analytics.heatmap.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Additional views")
                        .font(.subheadline.weight(.semibold))
                    Text("Optional model and activity detail; the primary reading path stays in Graphs and Facts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !analytics.modelBreakdowns.isEmpty {
                    UsageModelMixCard(models: analytics.modelBreakdowns)
                }
                if !analytics.heatmap.isEmpty {
                    UsageHeatmapCard(cells: analytics.heatmap)
                }
            }
        } else {
            UsageEmptyState(
                title: "No insights yet",
                detail: "Insights requires more observed history than is currently available for this account."
            )
        }
    }
}

// MARK: - Limits ring/bars card (02-charts-rings-widgets.md §1)
//
// The shortest-duration window gets a GlowRing (148pt detail-screen geometry); any additional
// windows stack beneath as slim gradient bars (§1d). This preserves the real per-window
// usedPercent data that `ProviderLimitsCard` used to show — the reference's hero number alone
// only covers the single shortest window, and LifeOS has real data for more than one window
// (e.g. demo fixtures ship a 5-hour AND a 7-day window) that would otherwise be dropped.

struct UsageLimitsCard: View {
    let snapshot: ProviderSnapshot
    let selectedWindow: UsageWindow?

    init(snapshot: ProviderSnapshot, selectedWindow: UsageWindow? = nil) {
        self.snapshot = snapshot
        self.selectedWindow = selectedWindow
    }

    private var sortedWindows: [UsageWindow] {
        snapshot.windows.sorted {
            ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max)
        }
    }

    private var ringWindow: UsageWindow? {
        selectedWindow ?? sortedWindows.first { $0.usedPercent != nil }
    }

    private var barWindows: [UsageWindow] {
        sortedWindows.filter { $0.id != ringWindow?.id }
    }

    var body: some View {
        VStack(spacing: 14) {
            if let ringWindow {
                // Usage owns one blue visual language; provider identity is carried by
                // the account switcher and labels, never by a provider-specific ring hue.
                GlowRing(progress: ringWindow.usedPercent ?? 0, hue: .blue, diameter: 148, lineWidth: 12) {
                    VStack(spacing: 3) {
                        Text(ringWindow.usedPercent.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .numericTransition()
                        if let percent = ringWindow.usedPercent {
                            Text("% used")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            statusPill(percent: percent)
                        } else {
                            Text("Not connected")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                }
                Text(ringWindow.label)
                    .font(.caption2)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            } else if snapshot.windows.isEmpty {
                Text("Not connected")
                    .font(.caption)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }

            if !barWindows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(barWindows) { window in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(window.label).font(.caption.weight(.semibold))
                                Spacer()
                                Text(window.usedPercent.map {
                                    "\($0.formatted(.percent.precision(.fractionLength(0)))) used"
                                } ?? "Not available")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(window.usedPercent == nil ? LifeOSTokens.tertiaryText : .primary)
                            }
                            if let percent = window.usedPercent {
                                UsageSlimBar(value: percent)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard(featured: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(snapshot.provider.displayName) usage limits")
    }

    private func statusPill(percent: Double) -> some View {
        let (text, color): (String, Color) = percent < 0.7
            ? ("Under normal", LifeOSTokens.success)
            : percent < 0.9 ? ("Near limit", LifeOSTokens.warning) : ("Over limit", LifeOSTokens.danger)
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// §1d — slim bar for non-primary windows: 4pt Capsule, reveal/light->base gradient fill.
private struct UsageSlimBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: [LifeOSTokens.Hue.blue.glow, LifeOSTokens.Hue.blue.base], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Supporting shell views

/// Segmented "Graphs / Facts / Insights" control. `SpringPillSelector` (LifeOSMotionKit)
/// always fills the selected pill with the neutral `LifeOSTokens.surface`; the reference
/// (§0.4) needs a colored `usage.primary` fill + white text for the selected segment
/// specifically, so this reimplements the same motion contract (matchedGeometryEffect +
/// `LifeOSMotion.snappy`, Reduce-Motion aware) with the reference's fill instead of
/// wrapping the shared primitive.
private struct UsageTabBar: View {
    @Binding var selection: UsageTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
    private let highlightID = "usage.tabBar.highlight"

    var body: some View {
        HStack(spacing: 4) {
            ForEach(UsageTab.allCases, id: \.self) { tab in
                let isSelected = tab == selection
                Button {
                    if reduceMotion {
                        selection = tab
                    } else {
                        withAnimation(LifeOSMotion.snappy) { selection = tab }
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                if reduceMotion {
                                    Capsule().fill(LifeOSTokens.accent)
                                } else {
                                    Capsule().fill(LifeOSTokens.accent)
                                        .matchedGeometryEffect(id: highlightID, in: namespace)
                                }
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

struct UsageEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Model mix (02 §4) — kept as a supplementary card, restyled to blue-forward tokens.

struct UsageModelMixCard: View {
    let models: [UsageModelBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UsageCardHeader(title: "Model mix", subtitle: "Token composition by model", icon: .assistant)
            ModelCompositionChart(models: models)
        }
        .glassCard()
        .accessibilityElement(children: .contain)
    }
}

private struct ModelCompositionChart: View {
    let models: [UsageModelBreakdown]
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let categoryOpacity = [1.0, 0.78, 0.58, 0.40, 0.24]

    private var legendCategories: [(label: String, value: Int)] {
        models.first?.categories ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ForEach(Array(legendCategories.enumerated()), id: \.offset) { index, category in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(sampledColor(at: index))
                            .frame(width: 5, height: 5)
                        Text(category.label)
                            .font(.caption2)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
            }
            .lineLimit(1)

            if models.isEmpty {
                Text("No model breakdown supplied.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.model)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(model.totalTokens.formatted(.number.notation(.compactName)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geometry in
                        let categories = model.categories
                        let gap: CGFloat = 2
                        let available = max(0, geometry.size.width - gap * CGFloat(max(categories.count - 1, 0)))
                        HStack(spacing: gap) {
                            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                                let share = model.totalTokens == 0 ? 0 : Double(category.value) / Double(model.totalTokens)
                                Capsule()
                                    .fill(sampledColor(at: index))
                                    .frame(width: revealed ? available * share : 0)
                                    .accessibilityLabel("\(category.label), \(category.value.formatted(.number.notation(.compactName)))")
                            }
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 0) {
                        ForEach(model.categories, id: \.label) { category in
                            Text(category.value.formatted(.number.notation(.compactName)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task {
            if reduceMotion { revealed = true }
            else { withAnimation(LifeOSMotion.chartDraw) { revealed = true } }
        }
    }

    /// Samples the usage base color at an opacity proportional to the segment's intensity — 02 §4.
    private func sampledColor(at index: Int) -> Color {
        let t = categoryOpacity[min(index, categoryOpacity.count - 1)]
        return LifeOSTokens.Series.actual.opacity(0.4 + 0.6 * t)
    }
}

// MARK: - Heatmap (02 §5) — restyled with an opacity ramp, never a halo.

struct UsageHeatmapCard: View {
    let cells: [UsageHeatmapCell]
    @State private var selectedCell: UsageHeatmapCell?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UsageCardHeader(title: "Usage rhythm", subtitle: "When activity typically happens", icon: .usage)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(UsageHeatmapGrid.items(cells: cells)) { item in
                    switch item.kind {
                    case .corner:
                        Text("").frame(height: 12)
                    case .hourHeader(let hour):
                        Text("\(hour)").font(.system(size: 8)).foregroundStyle(.secondary)
                    case .dayHeader(let weekday):
                        Text(shortDay(weekday)).font(.system(size: 8)).foregroundStyle(.secondary)
                    case .cell(let cell):
                        heatmapCell(cell)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Less")
                ForEach(0..<5, id: \.self) { step in
                    Circle()
                        .fill(sampledColor(intensity: Double(step) / 4))
                        .frame(width: 7, height: 7)
                }
                Text("More")
                Spacer()
                if let selectedCell {
                    Text("\(shortDay(selectedCell.weekday)) \(selectedCell.hour):00 · \(selectedCell.intensity.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .glassCard()
        .animation(reduceMotion ? nil : LifeOSMotion.snappy, value: selectedCell?.id)
    }

    private func sampledColor(intensity: Double) -> Color {
        Color(
            hueBlend: LifeOSTokens.Series.actual,
            glow: LifeOSTokens.Series.actual,
            t: 0.08 + intensity * 0.82
        )
    }

    @ViewBuilder
    private func heatmapCell(_ cell: UsageHeatmapCell) -> some View {
        let isSelected = selectedCell?.id == cell.id
        let isDimmed = selectedCell != nil && !isSelected
        let tile = Circle()
            .fill(sampledColor(intensity: cell.intensity))
            .overlay {
                if isSelected {
                    Circle().stroke(Color.primary.opacity(0.8), lineWidth: 1)
                }
            }
            .opacity(isDimmed ? 0.28 : 1)
            .frame(width: 11, height: 11)
            .frame(maxWidth: .infinity, minHeight: 16)
            .contentShape(Rectangle())
            .onTapGesture { selectedCell = isSelected ? nil : cell }
            .accessibilityLabel("\(shortDay(cell.weekday)) \(cell.hour):00, \(cell.intensity.formatted(.percent)) activity")

        #if os(macOS)
        tile.onHover { hovering in
            if hovering { selectedCell = cell }
            else if selectedCell?.id == cell.id { selectedCell = nil }
        }
        #else
        tile
        #endif
    }

    private func shortDay(_ weekday: Int) -> String {
        Calendar.current.shortWeekdaySymbols[max(0, min(weekday - 1, 6))]
    }
}

private extension Color {
    /// Simple opacity-based blend placeholder used for intensity sampling; both `hueBlend`
    /// and `glow` inputs are retained for source compatibility. The result is opacity only;
    /// no persistent halo is rendered.
    init(hueBlend: Color, glow: Color, t: Double) {
        self = hueBlend.opacity(t)
    }
}

// MARK: - Shared small pieces used by the split Usage/*.swift files.

struct UsageCardHeader: View {
    let title: String
    let subtitle: String
    let icon: LifeOSIconName

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            LifeOSIcon(icon)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct UsageLegendKey: View {
    let color: Color
    let label: String
    var dashed: Bool = false
    var dotted: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if dotted {
                DashedLine(dash: [1, 2]).stroke(color, style: StrokeStyle(lineWidth: 2, dash: [1, 2]))
                    .frame(width: 14, height: 2)
            } else if dashed {
                DashedLine(dash: [4, 3]).stroke(color, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: 14, height: 2)
            } else {
                Capsule().fill(color).frame(width: 14, height: 3)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashedLine: Shape {
    let dash: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

extension LifeOSTokens {
    /// `secondaryText` token referenced by 02-charts-rings-widgets.md doesn't exist yet in
    /// DesignTokens.swift (that file is out of this workstream's edit boundary); this is a
    /// local equivalent using the existing `.secondary` semantic color so the spec's intent
    /// (label color distinct from value color) is honored without touching Shared/.
    static var secondaryTextCompat: Color { Color.secondary }
}
