import SwiftUI
import Charts

struct CodexView: View {
    let snapshot: ProviderSnapshot
    let analytics: [UsageAnalyticsSnapshot]
    private let onOpenSettings: (() -> Void)?

    init(
        snapshot: ProviderSnapshot,
        analytics: [UsageAnalyticsSnapshot] = [],
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.analytics = analytics
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        UsageView(
            snapshots: [snapshot],
            analytics: analytics,
            onOpenSettings: onOpenSettings
        )
    }
}

// MARK: - Usage screen shell
//
// Usage is a monitoring surface: source context, provider-defined windows, one
// chart inspection surface, then factual detail. The layout deliberately keeps
// the quota signal and its provenance close together instead of presenting a
// second dashboard hero.

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
    static let twoColumnBreakpoint: CGFloat = 720
}

struct UsageView: View {
    let snapshots: [ProviderSnapshot]
    let state: UsageLoadState
    let refreshAction: (() async -> Void)?
    private let onBack: (() -> Void)?
    private let onOpenSettings: (() -> Void)?
    private let analytics: [UsageAnalyticsSnapshot]
    private let presentationPacket: UsagePresentationPacket?
    private let presentationAuthorities: [UsagePresentationScope: UsagePresentationAuthority]

    // These selections belong to the scene, not to one mounted copy of the
    // screen. Route changes can replace UsageView, but they must not reset the
    // provider/window the user was inspecting.
    @SceneStorage("LifeOS.usage.selectedProvider.v1") private var selectedProviderIdentifier = Provider.codex.rawValue
    @SceneStorage("LifeOS.usage.selectedRange.v1") private var selectedRangeIdentifier = UsageRange.fiveHour.rawValue
    @Environment(\.dismiss) private var dismiss

    init(
        snapshots: [ProviderSnapshot],
        analytics: [UsageAnalyticsSnapshot],
        state: UsageLoadState = .observed,
        refreshAction: (() async -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        presentationPacket: UsagePresentationPacket? = nil
    ) {
        self.snapshots = presentationPacket?.providers ?? snapshots
        self.state = presentationPacket?.loadState ?? state
        self.refreshAction = refreshAction
        self.onBack = onBack
        self.onOpenSettings = onOpenSettings
        self.analytics = presentationPacket?.analytics ?? analytics
        self.presentationPacket = presentationPacket
        self.presentationAuthorities = presentationPacket?.presentationAuthorities ?? [:]
    }

    private var selectedProvider: Provider {
        get { Provider(rawValue: selectedProviderIdentifier) ?? .codex }
        nonmutating set { selectedProviderIdentifier = newValue.rawValue }
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

    private func chartAnalytics(for snapshot: ProviderSnapshot) -> UsageAnalyticsSnapshot {
        if let activeAnalytics { return activeAnalytics }
        let window = selectedWindow(in: snapshot)
        return UsageAnalyticsSnapshot(
            provider: snapshot.provider,
            windowID: window?.id ?? selectedRange.sourceWindowIDs.first,
            activity: [],
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: window?.provenance ?? snapshot.provenance
        )
    }

    private var activePresentationAuthority: UsagePresentationAuthority {
        guard let activeSnapshot else { return .unknown }
        let windowID = selectedWindow(in: activeSnapshot)?.id
            ?? activeAnalytics?.windowID
            ?? selectedRange.sourceWindowIDs.first
        guard let windowID,
              let scope = UsagePresentationScope.canonical(
                  provider: activeSnapshot.provider,
                  windowID: windowID
              ) else { return .unknown }
        return presentationAuthorities[scope] ?? .unknown
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
                        usageSummary(activeSnapshot)
                        monitoringSurface(activeSnapshot)
                        UsageObservationSummary(snapshot: activeSnapshot, analytics: activeAnalytics)
                        if let activeAnalytics,
                           !activeAnalytics.modelBreakdowns.isEmpty || !activeAnalytics.heatmap.isEmpty {
                            UsageAdditionalObservations(analytics: activeAnalytics)
                        }
                    } else {
                        usageHeader(nil)
                        UsageEmptyState(
                            title: "Connect a usage provider",
                            detail: "No provider account is connected. Connect one in Settings to see observed usage.",
                            onOpenSettings: onOpenSettings
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
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
            HStack(alignment: .center, spacing: LifeOSTokens.Space.md) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                    Text("Usage")
                        .lifeOSTypography(.pageTitle, weight: .semibold)
                        .foregroundStyle(LifeOSTokens.primaryText)
                    Text(snapshot.map { $0.accountLabel.isEmpty ? $0.provider.displayName : $0.accountLabel } ?? "Provider limits")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: LifeOSTokens.Space.sm)
                heroActions
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: LifeOSTokens.Space.sm) {
                    providerSwitcher
                    if let snapshot {
                        sourceSummary(snapshot)
                    }
                }
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                    providerSwitcher
                    if let snapshot {
                        sourceSummary(snapshot)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func sourceSummary(_ snapshot: ProviderSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
            Circle()
                .fill(sourceColor(for: snapshot))
                .frame(width: 6, height: 6)
            Text(sourceLabel(for: snapshot))
                .lifeOSTypography(.metadata, weight: .medium)
                .foregroundStyle(sourceColor(for: snapshot))
                .lineLimit(2)
            Text("Updated \(snapshot.provenance.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
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
            LifeOSTokens.Series.actual
        case .estimated:
            LifeOSTokens.estimate
        case .demo, .observed:
            LifeOSTokens.warningText
        case .unavailable:
            LifeOSTokens.tertiaryText
        }
    }

    /// Quota windows share one compact row grammar. On a wide surface the
    /// selected window and the remaining windows form two balanced columns;
    /// the same rows stack on narrow surfaces without introducing a second
    /// hero treatment or a decorative visualization.
    @ViewBuilder
    private func usageSummary(_ snapshot: ProviderSnapshot) -> some View {
        let windows = snapshot.windows.sorted {
            ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max)
        }
        let primary = selectedWindow(in: snapshot) ?? snapshot.smallestObservedWindow ?? windows.first

        Group {
            if let primary {
                let secondary = windows.filter { $0.id != primary.id }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: LifeOSTokens.Space.md) {
                        usageWindowCard(primary, in: snapshot)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !secondary.isEmpty {
                            usageSecondaryWindowCard(secondary, in: snapshot)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(minWidth: UsageLayoutContract.twoColumnBreakpoint, alignment: .leading)
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                        usageWindowCard(primary, in: snapshot)
                        if !secondary.isEmpty {
                            usageSecondaryWindowCard(secondary, in: snapshot)
                        }
                    }
                }
            } else {
                LifeOSCard(level: .raised, cornerRadius: 12, padding: LifeOSTokens.Space.md) {
                    UsageEmptyState(
                        title: "No usage window",
                        detail: "The connected source has not supplied a quota window."
                    )
                }
            }
        }
        .accessibilityIdentifier("usage-summary")
    }

    private func usageWindowCard(_ window: UsageWindow, in snapshot: ProviderSnapshot) -> some View {
        LifeOSCard(level: .raised, cornerRadius: 12, padding: LifeOSTokens.Space.md) {
            UsageWindowSummaryRow(window: window, state: stateFor(window, snapshot: snapshot))
        }
    }

    private func usageSecondaryWindowCard(_ windows: [UsageWindow], in snapshot: ProviderSnapshot) -> some View {
        LifeOSCard(level: .raised, cornerRadius: 12, padding: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    if index > 0 {
                        Divider()
                            .overlay(LifeOSTokens.hairlineBorder)
                    }
                    secondaryWindowRow(window, in: snapshot)
                }
            }
        }
    }

    private func secondaryWindowRow(_ window: UsageWindow, in snapshot: ProviderSnapshot) -> some View {
        Button {
            if let range = UsageRange.matching(durationMinutes: window.durationMinutes) {
                selectedRange = range
            }
        } label: {
            UsageWindowSummaryRow(window: window, state: stateFor(window, snapshot: snapshot))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            UsageRange.matching(durationMinutes: window.durationMinutes).map { selectedRange == $0 ? .isSelected : [] } ?? []
        )
        .accessibilityIdentifier("usage-secondary-window-\(window.id)")
    }

    private func stateFor(_ window: UsageWindow, snapshot: ProviderSnapshot) -> UsageValueState {
        UsageWindowStateResolver.state(for: window, snapshot: snapshot, loadState: state)
    }

    private func monitoringSurface(_ snapshot: ProviderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: UsageLayoutContract.controlGap) {
                    monitoringTitle
                        .layoutPriority(1)
                    rangeControl
                }
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                    monitoringTitle
                    rangeControl
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            UsageProjectionChart(
                provider: snapshot.provider,
                window: selectedWindow(in: snapshot),
                analytics: chartAnalytics(for: snapshot),
                accountScope: snapshot.accountLabel,
                generation: presentationPacket?.generation ?? 0,
                presentationAuthority: activePresentationAuthority,
                updateKind: presentationPacket?.updateKind ?? .initial
            )
        }
    }

    private var monitoringTitle: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text("Usage trend")
                .lifeOSTypography(.cardTitle)
                .foregroundStyle(LifeOSTokens.primaryText)
            Text("Percent consumed across the selected window")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
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
        LifeOSIconButton(
            icon: .chevronLeft,
            accessibilityLabel: "Back",
            size: LifeOSTokens.Control.iconButton,
            tint: LifeOSTokens.secondaryText
        ) {
            onBack?() ?? dismiss()
        }
        .accessibilityIdentifier("usage-back")
    }
#endif

    // MARK: Hero row (§0.1) — the reference puts existing chrome in this row.

    private var heroActions: some View {
        HStack(spacing: 8) {
            LifeOSIconButton(
                icon: .refresh,
                accessibilityLabel: "Refresh usage data",
                size: LifeOSTokens.Control.iconButton,
                tint: state == .loading ? LifeOSTokens.accent : LifeOSTokens.secondaryText
            ) {
                Task { await refreshAction?() }
            }
            .disabled(refreshAction == nil || state == .loading)

            NavigationLink {
                ProviderConnectionsSettingsView()
            } label: {
                LifeOSIcon(.settings, context: .toolbar)
            }
            .buttonStyle(LifeOSButtonStyle(.tertiary))
            .frame(width: LifeOSTokens.Control.iconButton, height: LifeOSTokens.Control.iconButton)
            .foregroundStyle(LifeOSTokens.secondaryText)
            .accessibilityLabel("Usage settings")
        }
    }

    private var rangeControl: some View {
        Menu {
            Picker("Range", selection: selectedRangeBinding) {
                ForEach(UsageRange.allCases, id: \.self) { range in
                    Text(availableRanges.contains(range) ? range.rawValue : "\(range.rawValue) · Needs more history")
                        .tag(range)
                        .disabled(!availableRanges.contains(range))
                }
            }
        } label: {
            HStack(spacing: LifeOSTokens.Space.xs) {
                Text(
                    availableRanges.contains(selectedRange)
                        ? (activeSnapshot.flatMap { selectedWindow(in: $0)?.label } ?? selectedRange.accessibilityName)
                        : "\(selectedRange.rawValue) · Needs more history"
                )
                .lifeOSTypography(.label, weight: .medium)
                .foregroundStyle(LifeOSTokens.primaryText)
                .lineLimit(1)

                LifeOSIcon(.chevronRight, context: .disclosure)
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
            .padding(.horizontal, LifeOSTokens.Space.sm)
            .padding(.vertical, LifeOSTokens.Space.xs)
            .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
            }
            .frame(minHeight: LifeOSTokens.Control.standardHeight, alignment: .center)
        }
        .foregroundStyle(LifeOSTokens.primaryText)
        .accessibilityLabel("Usage window")
        .accessibilityValue(activeSnapshot.flatMap { selectedWindow(in: $0)?.label } ?? selectedRange.accessibilityName)
    }

    private var providerSwitcher: some View {
        Menu {
            Picker("Provider", selection: selectedProviderBinding) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    Text("\(provider.displayName) · \(statusText(for: provider))").tag(provider)
                }
            }
        } label: {
            HStack(spacing: LifeOSTokens.Space.xs) {
                LifeOSIcon(providerIcon(selectedProvider), context: .toolbar)
                    .foregroundStyle(LifeOSTokens.accent)
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                    Text(selectedProvider.displayName)
                        .lifeOSTypography(.label, weight: .medium)
                        .foregroundStyle(LifeOSTokens.primaryText)
                        .lineLimit(1)
                    Text(statusText(for: selectedProvider))
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, LifeOSTokens.Space.sm)
            .padding(.vertical, LifeOSTokens.Space.xs)
            .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
            }
            .frame(minWidth: 156, maxWidth: 250, minHeight: LifeOSTokens.Control.standardHeight, alignment: .leading)
        }
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

}

private struct UsageObservationSummary: View {
    let snapshot: ProviderSnapshot
    let analytics: UsageAnalyticsSnapshot?

    private var facts: UsageFacts {
        UsageFacts.compute(from: analytics, fallbackProvenance: snapshot.provenance)
    }

    private var updatedText: String {
        snapshot.provenance.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    var body: some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: LifeOSTokens.Space.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: LifeOSTokens.Space.lg) {
                    observationMetric("Observed points", facts.observedTotals.map { $0.observationCount.formatted() } ?? "—")
                    observationMetric("Peak hour", facts.peakActivity.map { $0.tokens.formatted(.number.notation(.compactName)) } ?? "—")
                    observationMetric("Updated", updatedText)
                }
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: LifeOSTokens.Space.md
                ) {
                    observationMetric("Observed points", facts.observedTotals.map { $0.observationCount.formatted() } ?? "—")
                    observationMetric("Peak hour", facts.peakActivity.map { $0.tokens.formatted(.number.notation(.compactName)) } ?? "—")
                    observationMetric("Updated", updatedText)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-observation-summary")
    }

    private func observationMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
            Text(value)
                .lifeOSTypography(.button, weight: .semibold)
                .foregroundStyle(LifeOSTokens.primaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageAdditionalObservations: View {
    let analytics: UsageAnalyticsSnapshot
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                if !analytics.modelBreakdowns.isEmpty {
                    UsageModelMixCard(models: analytics.modelBreakdowns)
                }
                if !analytics.heatmap.isEmpty {
                    UsageHeatmapCard(cells: analytics.heatmap)
                }
            }
            .padding(.top, LifeOSTokens.Space.sm)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
                LifeOSIcon(.views, context: .card)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                    Text("Additional observations")
                        .lifeOSTypography(.cardTitle)
                        .foregroundStyle(LifeOSTokens.primaryText)
                    Text("Provider supplied breakdowns")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("usage-additional-observations")
    }
}

struct UsageEmptyState: View {
    let title: String
    let detail: String
    let onOpenSettings: (() -> Void)?

    init(
        title: String,
        detail: String,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        LifeOSEmptyStatePanel(
            icon: .usage,
            title: title,
            explanation: detail,
            actionTitle: onOpenSettings == nil ? nil : "Open Settings",
            action: onOpenSettings
        )
        .accessibilityIdentifier("usage-empty-state")
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
            LifeOSTokens.Series.actual
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
        case .demo:
            LifeOSTokens.warningText
        case .observed:
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
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
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
        HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
            LifeOSIcon(icon, context: .card)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lifeOSTypography(.cardTitle)
                Text(subtitle)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
