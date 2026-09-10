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

// MARK: - Usage screen shell
//
// Usage is a monitoring surface: source context, provider-defined windows, one
// chart inspection surface, then factual detail. The layout deliberately keeps
// the quota signal and its provenance close together instead of presenting a
// second dashboard hero.

enum UsageGraphKind: String, CaseIterable, Hashable {
    case remaining = "Usage remaining"
    case tokenActivity = "Token activity"

    var title: String {
        switch self {
        case .remaining: "Remaining"
        case .tokenActivity: "Token activity"
        }
    }
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

    var title: String {
        switch self {
        case .fiveHour: "5-hour"
        case .sevenDay: "7-day"
        }
    }

    static func matching(durationMinutes: Int?) -> Self? {
        guard let durationMinutes else { return nil }
        return allCases.first { $0.durationMinutes == durationMinutes }
    }

    var sourceWindowIDs: [String] {
        switch self {
        case .fiveHour: ["five_hour", "5h"]
        case .sevenDay: ["seven_day", "7d"]
        }
    }
}

enum UsageLayoutContract {
    static let maxContentWidth: CGFloat = 1_040
    static let contentGap: CGFloat = 24
    static let controlGap: CGFloat = 8
    static let compactBreakpoint: CGFloat = 560
    static let twoColumnBreakpoint: CGFloat = 720
}

struct UsageView: View {
    let snapshots: [ProviderSnapshot]
    let state: UsageLoadState
    let refreshAction: (() async -> Void)?
    private let onBack: (() -> Void)?
    private let analytics: [UsageAnalyticsSnapshot]

    // These selections belong to the scene, not to one mounted copy of the
    // screen. Route changes can replace UsageView, but they must not reset the
    // provider/window the user was inspecting.
    @SceneStorage("LifeOS.usage.selectedProvider.v1") private var selectedProviderIdentifier = Provider.codex.rawValue
    @SceneStorage("LifeOS.usage.selectedGraph.v1") private var selectedGraphIdentifier = UsageGraphKind.remaining.rawValue
    @SceneStorage("LifeOS.usage.selectedRange.v1") private var selectedRangeIdentifier = UsageRange.fiveHour.rawValue
    @Environment(\.dismiss) private var dismiss

    init(
        snapshots: [ProviderSnapshot],
        analytics: [UsageAnalyticsSnapshot],
        state: UsageLoadState = .observed,
        refreshAction: (() async -> Void)? = nil,
        onBack: (() -> Void)? = nil
    ) {
        self.snapshots = snapshots
        self.state = state
        self.refreshAction = refreshAction
        self.onBack = onBack
        self.analytics = analytics
    }

    private var selectedProvider: Provider {
        get { Provider(rawValue: selectedProviderIdentifier) ?? .codex }
        nonmutating set { selectedProviderIdentifier = newValue.rawValue }
    }

    private var selectedGraph: UsageGraphKind {
        get { UsageGraphKind(rawValue: selectedGraphIdentifier) ?? .remaining }
        nonmutating set { selectedGraphIdentifier = newValue.rawValue }
    }

    private var selectedRange: UsageRange {
        get { UsageRange(rawValue: selectedRangeIdentifier) ?? .fiveHour }
        nonmutating set { selectedRangeIdentifier = newValue.rawValue }
    }

    private var selectedProviderBinding: Binding<Provider> {
        Binding(
            get: { selectedProvider },
            set: { selectedProvider = $0 }
        )
    }

    private var selectedGraphBinding: Binding<UsageGraphKind> {
        Binding(
            get: { selectedGraph },
            set: { selectedGraph = $0 }
        )
    }

    private var selectedRangeBinding: Binding<UsageRange> {
        Binding(
            get: { selectedRange },
            set: { selectedRange = $0 }
        )
    }

    private var activeSnapshot: ProviderSnapshot? {
        // Do not fall back to another provider: an unavailable selected identity
        // must never render a different provider's observed numbers or analytics.
        snapshots.first { $0.provider == selectedProvider }
    }

    private var activeAnalytics: UsageAnalyticsSnapshot? {
        guard let activeSnapshot else { return nil }
        let sourceIDs = selectedWindow(in: activeSnapshot).map { [$0.id] } ?? selectedRange.sourceWindowIDs
        return analytics.first { candidate in
            candidate.provider == activeSnapshot.provider &&
            sourceIDs.contains(candidate.windowID ?? "") &&
            (activeSnapshot.provenance.quality == .demo
                ? candidate.provenance.quality == .demo
                : candidate.provenance.quality != .demo)
        }
    }

    private var availableRanges: Set<UsageRange> {
        guard let activeSnapshot else { return [] }
        return Set(availableRangeOrder(for: activeSnapshot))
    }

    private func availableRangeOrder(for snapshot: ProviderSnapshot) -> [UsageRange] {
        var ranges: [UsageRange] = []
        var seen = Set<UsageRange>()

        func append(_ range: UsageRange?) {
            guard let range, seen.insert(range).inserted else { return }
            ranges.append(range)
        }

        for window in snapshot.windows where window.usedPercent != nil {
            append(UsageRange.matching(durationMinutes: window.durationMinutes))
        }

        for candidate in analytics where matchesQuality(candidate, for: snapshot) {
            append(UsageRange.allCases.first { $0.sourceWindowIDs.contains(candidate.windowID ?? "") })
        }

        return ranges
    }

    private func matchesQuality(_ candidate: UsageAnalyticsSnapshot, for snapshot: ProviderSnapshot) -> Bool {
        guard candidate.provider == snapshot.provider, !candidate.history.isEmpty else { return false }
        return snapshot.provenance.quality == .demo
            ? candidate.provenance.quality == .demo
            : candidate.provenance.quality != .demo
    }

    private func reconcileSelectedRange(for snapshot: ProviderSnapshot?) {
        guard let snapshot else { return }
        let ranges = availableRangeOrder(for: snapshot)
        guard !ranges.contains(selectedRange) else { return }
        selectedRange = ranges.first(where: { $0 == .fiveHour }) ?? ranges.first ?? .fiveHour
    }

    private func reconcileProviderAndRange(with snapshots: [ProviderSnapshot]) {
        guard let provider = snapshots.first(where: { $0.provider == selectedProvider })?.provider
                ?? snapshots.first?.provider else { return }
        if provider != selectedProvider {
            selectedProvider = provider
        }
        reconcileSelectedRange(for: snapshots.first { $0.provider == provider })
    }

    private func selectedWindow(in snapshot: ProviderSnapshot) -> UsageWindow? {
        snapshot.windows.first { $0.durationMinutes == selectedRange.durationMinutes }
    }

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(
                horizontalPadding: usageHorizontalPadding,
                topPadding: usageTopPadding,
                bottomPadding: usageBottomPadding,
                maxReadableWidth: UsageLayoutContract.maxContentWidth
            ) {
                VStack(alignment: .leading, spacing: UsageLayoutContract.contentGap) {
#if os(iOS)
                    backButton
#endif
                    if let activeSnapshot {
                        usageHeader(activeSnapshot)
                        sourceSummary(activeSnapshot)
                        windowSummaries(activeSnapshot)
                        monitoringSurface(activeSnapshot)
                        UsageFactsView(snapshot: activeSnapshot, analytics: activeAnalytics)
                        if let activeAnalytics,
                           !activeAnalytics.modelBreakdowns.isEmpty || !activeAnalytics.heatmap.isEmpty {
                            UsageSupplementaryAnalyticsView(analytics: activeAnalytics)
                        }
                    } else {
                        usageHeader(nil)
                        providerSwitcher
                        UsageEmptyState(
                            title: "Usage data unavailable",
                            detail: "No provider account is connected. LifeOS will not display placeholder usage."
                        )
                    }
                }
                .frame(maxWidth: UsageLayoutContract.maxContentWidth, alignment: .leading)
            }
        }
        .accessibilityIdentifier("usage-screen")
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
        .tint(LifeOSTokens.accent)
        .refreshable { await refreshAction?() }
        .onAppear {
            reconcileProviderAndRange(with: snapshots)
        }
        .onChange(of: selectedProvider) { _, newProvider in
            reconcileSelectedRange(for: snapshots.first { $0.provider == newProvider })
        }
        .onChange(of: snapshots) { _, newSnapshots in
            reconcileProviderAndRange(with: newSnapshots)
        }
    }

    private func usageHeader(_ snapshot: ProviderSnapshot?) -> some View {
        HStack(alignment: .center, spacing: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text("Usage")
                    .lifeOSTypography(.sectionTitle, weight: .semibold)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text(snapshot.map { "\($0.provider.displayName) · \(statusText(for: $0.provider))" } ?? "Provider monitoring")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: LifeOSTokens.Space.sm)
            heroActions
        }
        .frame(minHeight: 44, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    private func sourceSummary(_ snapshot: ProviderSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
            Text(sourceLabel(for: snapshot))
                .lifeOSTypography(.label, weight: .medium)
                .foregroundStyle(sourceColor(for: snapshot))
            Spacer(minLength: LifeOSTokens.Space.sm)
            Text("Updated \(snapshot.provenance.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceLabel(for snapshot: ProviderSnapshot) -> String {
        switch snapshot.provenance.quality {
        case .observed:
            switch snapshot.provenance.connector {
            case .healthy: "Observed · \(snapshot.provenance.source)"
            case .refreshDue: "Refresh due · \(snapshot.provenance.source)"
            case .reauthRequired: "Re-auth required · \(snapshot.provenance.source)"
            case .rateLimited: "Rate limited · \(snapshot.provenance.source)"
            case .revoked, .disabled, .unavailable, .error: "Unavailable · \(snapshot.provenance.source)"
            }
        case .estimated: "Estimate · non-official"
        case .demo: "Demo · not live"
        case .unavailable: "Not connected"
        }
    }

    private func sourceColor(for snapshot: ProviderSnapshot) -> Color {
        switch snapshot.provenance.quality {
        case .observed where snapshot.provenance.connector == .healthy:
            LifeOSTokens.secondaryText
        case .estimated:
            LifeOSTokens.estimate
        case .demo, .observed:
            LifeOSTokens.warningText
        case .unavailable:
            LifeOSTokens.tertiaryText
        }
    }

    private func windowSummaries(_ snapshot: ProviderSnapshot) -> some View {
        let windows = snapshot.windows.sorted {
            ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max)
        }

        return Group {
            if windows.isEmpty {
                UsageEmptyState(
                    title: "No usage windows",
                    detail: "The connected source has not supplied a quota window."
                )
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: LifeOSTokens.Space.md) {
                        ForEach(windows) { window in
                            windowSummary(window, in: snapshot)
                        }
                    }
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                        ForEach(windows) { window in
                            windowSummary(window, in: snapshot)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func windowSummary(_ window: UsageWindow, in snapshot: ProviderSnapshot) -> some View {
        let range = UsageRange.matching(durationMinutes: window.durationMinutes)
        let content = UsageWindowSummaryRow(window: window, state: stateFor(window, snapshot: snapshot))
        if let range {
            Button {
                selectedRange = range
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedRange == range ? .isSelected : [])
            .accessibilityIdentifier("usage-window-\(range.rawValue)")
        } else {
            content
        }
    }

    private func stateFor(_ window: UsageWindow, snapshot: ProviderSnapshot) -> UsageValueState {
        UsageWindowStateResolver.state(for: window, snapshot: snapshot, loadState: state)
    }

    private func monitoringSurface(_ snapshot: ProviderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
                Text(selectedGraph.title)
                    .lifeOSTypography(.cardTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Spacer(minLength: LifeOSTokens.Space.sm)
                Text(snapshot.provenance.source)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .lineLimit(1)
            }

            controlRow

            if let activeAnalytics {
                switch selectedGraph {
                case .remaining:
                    UsageProjectionChart(
                        provider: snapshot.provider,
                        window: selectedWindow(in: snapshot),
                        analytics: activeAnalytics
                    )
                case .tokenActivity:
                    UsageTokenActivityView(
                        provider: snapshot.provider,
                        activity: activity(in: selectedWindow(in: snapshot), analytics: activeAnalytics)
                    )
                }
            } else {
                UsageEmptyState(
                    title: "No chart observations",
                    detail: "The source has not supplied history for this window, so LifeOS will not invent a plot."
                )
            }
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
        Button { onBack?() ?? dismiss() } label: {
            LifeOSIcon(.chevronLeft, context: .toolbar)
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
                LifeOSIcon(.refresh, context: .toolbar)
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
                LifeOSIcon(.settings, context: .toolbar)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Usage settings")
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                graphControl
                    .frame(minWidth: 160, idealWidth: 180, maxWidth: 240, alignment: .leading)
                rangeControl
                    .frame(minWidth: 160, idealWidth: 180, maxWidth: 240, alignment: .leading)
                providerSwitcher
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 360, alignment: .leading)
                Spacer(minLength: 0)
            }

#if os(iOS)
            VStack(alignment: .leading, spacing: UsageLayoutContract.controlGap) {
                graphControl
                    .frame(maxWidth: .infinity, alignment: .leading)
                rangeControl
                    .frame(maxWidth: .infinity, alignment: .leading)
                providerSwitcher
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
#else
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145, maximum: 360), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                graphControl
                rangeControl
                providerSwitcher
            }
#endif
        }
    }

    private var graphControl: some View {
        controlMenu(label: "Graph") {
            Picker("Graph", selection: selectedGraphBinding) {
                ForEach(UsageGraphKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
        } valueText: { selectedGraph.rawValue }
    }

    private var rangeControl: some View {
        controlMenu(label: "Range") {
            Picker("Range", selection: selectedRangeBinding) {
                ForEach(UsageRange.allCases, id: \.self) { range in
                    Text(availableRanges.contains(range) ? range.rawValue : "\(range.rawValue) · Needs more history")
                        .tag(range)
                        .disabled(!availableRanges.contains(range))
                }
            }
        } valueText: {
            availableRanges.contains(selectedRange)
                ? (activeSnapshot.flatMap { selectedWindow(in: $0)?.label } ?? selectedRange.accessibilityName)
                : "\(selectedRange.rawValue) · Needs more history"
        }
    }

    private var providerSwitcher: some View {
        Menu {
            Picker("Provider", selection: selectedProviderBinding) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    Text("\(provider.displayName) · \(statusText(for: provider))").tag(provider)
                }
            }
        } label: {
            HStack(spacing: 4) {
                LifeOSIcon(providerIcon(selectedProvider), context: .toolbar)
                    .foregroundStyle(LifeOSTokens.accent)
                Text("Provider · \(selectedProvider.displayName) · \(statusText(for: selectedProvider))")
                    .lifeOSTypography(.button)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
            }
            .frame(minHeight: LifeOSTokens.Control.standardHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Menus re-tint their label with the system accent; pin neutral chrome (§1).
        .foregroundStyle(LifeOSTokens.secondaryText)
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

    private func providerIcon(_ provider: Provider) -> LifeOSIconName {
        switch provider {
        case .codex: return .usage
        case .claude: return .usage
        case .glm: return .graphUp
        case .deepseek: return .search
        case .googleAIStudio: return .business
        }
    }

    @ViewBuilder
    private func controlMenu<Content: View>(label: String, @ViewBuilder content: () -> Content, valueText: () -> String) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .lifeOSTypography(.label)
                    .foregroundStyle(.secondary)
                Text(valueText())
                    .lifeOSTypography(.button)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                LifeOSIcon(.chevronRight, context: .disclosure)
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: LifeOSTokens.Control.standardHeight, alignment: .leading)
        }
        .foregroundStyle(.primary)
    }
}

private struct UsageSupplementaryAnalyticsView: View {
    let analytics: UsageAnalyticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text("Additional observations")
                    .lifeOSTypography(.cardTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text("Observed breakdowns, when supplied by the provider")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            if !analytics.modelBreakdowns.isEmpty {
                UsageModelMixCard(models: analytics.modelBreakdowns)
            }
            if !analytics.heatmap.isEmpty {
                UsageHeatmapCard(cells: analytics.heatmap)
            }
        }
    }
}

struct UsageEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).lifeOSTypography(.cardTitle)
            Text(detail)
                .lifeOSTypography(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .combine)
    }
}

/// Compact quota summary used above the chart. The quota value is the primary
/// signal; reset and provenance stay on the same card so the screen does not
/// need a second hero or a decorative ring to explain the number.
private struct UsageWindowSummaryRow: View {
    let window: UsageWindow
    let state: UsageValueState

    private var remainingFraction: Double? {
        window.usedPercent.map { min(max(1 - $0, 0), 1) }
    }

    private var remainingText: String {
        remainingFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private var resetText: String {
        guard let resetAt = window.resetAt else { return "Reset unavailable" }
        let format: Date.FormatStyle = if let durationMinutes = window.durationMinutes, durationMinutes >= 24 * 60 {
            .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        } else {
            .dateTime.hour().minute()
        }
        return "Resets \(resetAt.formatted(format))"
    }

    private var stateColor: Color {
        switch state {
        case .observed:
            LifeOSTokens.successText
        case .estimated, .projected:
            LifeOSTokens.estimate
        case .demo:
            LifeOSTokens.warningText
        case .stale, .unavailable, .error, .loading:
            LifeOSTokens.tertiaryText
        }
    }

    private var valueColor: Color {
        switch state {
        case .estimated, .projected:
            LifeOSTokens.estimate
        default:
            LifeOSTokens.primaryText
        }
    }

    private var trackColor: Color {
        switch state {
        case .estimated, .projected:
            LifeOSTokens.Series.estimate
        case .demo, .observed:
            LifeOSTokens.Series.actual
        case .stale, .unavailable, .error, .loading:
            LifeOSTokens.tertiaryText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                Text(window.label)
                    .lifeOSTypography(.label, weight: .medium)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .lineLimit(1)

                Spacer(minLength: LifeOSTokens.Space.xs)

                Text(remainingText)
                    .lifeOSTypography(.inlineMonitoringValue)
                    .foregroundStyle(valueColor)
                Text("remaining")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }

            HStack(alignment: .center, spacing: LifeOSTokens.Space.xs) {
                Text("Used")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(LifeOSTokens.primaryText.opacity(0.10))
                        if let remainingFraction {
                            Capsule()
                                .fill(trackColor)
                                .frame(width: geometry.size.width * CGFloat(1 - remainingFraction))
                        }
                    }
                }
                .frame(height: 4)
            }
            .frame(height: 14)

            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                Text(state.label)
                    .lifeOSTypography(.metadata, weight: .medium)
                    .foregroundStyle(stateColor)
                Spacer(minLength: LifeOSTokens.Space.xs)
                Text(resetText)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, LifeOSTokens.Space.sm)
        .padding(.vertical, LifeOSTokens.Space.xs)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label), \(remainingText) remaining, \(state.label), \(resetText)")
    }
}

// MARK: - Model mix (02 §4) — kept as a supplementary card, restyled to blue-forward tokens.

struct UsageModelMixCard: View {
    let models: [UsageModelBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UsageCardHeader(title: "Model mix", subtitle: "Token composition by model", icon: .usage)
            ModelCompositionChart(models: models)
        }
        .flatCard()
        .accessibilityElement(children: .contain)
    }
}

private struct ModelCompositionChart: View {
    let models: [UsageModelBreakdown]

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
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
            }
            .lineLimit(1)

            if models.isEmpty {
                Text("No model breakdown supplied.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(.secondary)
            }

            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.model)
                            .lifeOSTypography(.metadata, weight: .semibold)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(model.totalTokens.formatted(.number.notation(.compactName)))
                            .lifeOSTypography(.metadata).monospacedDigit()
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
                                    .frame(width: max(0, available * share))
                                    .accessibilityLabel("\(category.label), \(category.value.formatted(.number.notation(.compactName)))")
                            }
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 0) {
                        ForEach(model.categories, id: \.label) { category in
                            Text(category.value.formatted(.number.notation(.compactName)))
                                .lifeOSTypography(.metadata).monospacedDigit()
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
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
                        Text("\(hour)").lifeOSTypography(.metadata).foregroundStyle(.secondary)
                    case .dayHeader(let weekday):
                        Text(shortDay(weekday)).lifeOSTypography(.metadata).foregroundStyle(.secondary)
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
                        .lifeOSTypography(.metadata).monospacedDigit()
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            }
            .lifeOSTypography(.metadata)
            .foregroundStyle(.secondary)
        }
        .flatCard()
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
            LifeOSIcon(icon, context: .card)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lifeOSTypography(.cardTitle)
                Text(subtitle)
                    .lifeOSTypography(.body)
                    .foregroundStyle(.secondary)
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
                .lifeOSTypography(.metadata)
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
