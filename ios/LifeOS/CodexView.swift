import SwiftUI
import Charts
import Combine

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
    static let contentGap: CGFloat = 16
    static let controlGap: CGFloat = 8
    static let twoColumnBreakpoint: CGFloat = 720
    static let cardPadding: CGFloat = 12
    static let macChartHeight: CGFloat = 224
    static let macTokenActivityChartHeight: CGFloat = 196
}

struct UsageView: View {
    let snapshots: [ProviderSnapshot]
    let state: UsageLoadState
    let refreshAction: (() async -> Void)?
    private let onBack: (() -> Void)?
    private let onOpenSettings: (() -> Void)?
    private let onManageConnections: (() -> Void)?
    private let analytics: [UsageAnalyticsSnapshot]
    private let presentationPacket: UsagePresentationPacket?
    private let presentationAuthorities: [UsagePresentationScope: UsagePresentationAuthority]
    private let registryPresentation: UsageRegistryPresentation

    // These selections belong to the scene, not to one mounted copy of the
    // screen. Route changes can replace UsageView, but they must not reset the
    // provider/window the user was inspecting.
    @SceneStorage("LifeOS.usage.selectedProvider.v1") private var selectedProviderIdentifier = Provider.codex.rawValue
    @SceneStorage("LifeOS.usage.selectedRange.v1") private var selectedRangeIdentifier = UsageRange.fiveHour.rawValue
    @SceneStorage("LifeOS.usage.selectedConnection.v2") private var selectedConnectionIdentifier = ""
    @SceneStorage("LifeOS.usage.selectedWindow.v2") private var selectedWindowIdentifier = ""
    @Environment(\.dismiss) private var dismiss
    @State private var freshnessNow = Date.now

    init(
        snapshots: [ProviderSnapshot],
        analytics: [UsageAnalyticsSnapshot],
        state: UsageLoadState = .observed,
        refreshAction: (() async -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onManageConnections: (() -> Void)? = nil,
        presentationPacket: UsagePresentationPacket? = nil
    ) {
        self.snapshots = presentationPacket?.providers ?? snapshots
        self.state = presentationPacket?.loadState ?? state
        self.refreshAction = refreshAction
        self.onBack = onBack
        self.onOpenSettings = onOpenSettings
        self.onManageConnections = onManageConnections
        self.analytics = presentationPacket?.analytics ?? analytics
        self.presentationPacket = presentationPacket
        self.presentationAuthorities = presentationPacket?.presentationAuthorities ?? [:]
        if let presentationPacket {
            // A packet is the coordinator's authoritative handoff. An empty
            // or failed registry is meaningful state and must remain visible;
            // reconstructing a fixture here can erase its failure semantics.
            self.registryPresentation = presentationPacket.registryPresentation
        } else {
            self.registryPresentation = Self.fixtureRegistry(snapshots: snapshots, analytics: analytics)
        }
    }

    private static func fixtureRegistry(
        snapshots: [ProviderSnapshot],
        analytics: [UsageAnalyticsSnapshot]
    ) -> UsageRegistryPresentation {
        let mapping = UsageRegistryAdapter.legacyMapping(providers: snapshots, analytics: analytics)
        do {
            return try UsageRegistryAdapter.fromLegacy(
                mapping: mapping,
                generatedAt: snapshots.map(\.provenance.observedAt).max()
            )
        } catch {
            return .empty.withFailure(.registryConversion)
        }
    }

    private var selectedConnectionID: UsageConnectionID? {
        get { try? UsageConnectionID(selectedConnectionIdentifier) }
        nonmutating set { selectedConnectionIdentifier = newValue?.rawValue ?? "" }
    }

    private var selectedWindowID: UsageWindowID? {
        get { try? UsageWindowID(selectedWindowIdentifier) }
        nonmutating set { selectedWindowIdentifier = newValue?.rawValue ?? "" }
    }

    private var selectedRange: UsageRange {
        get { UsageRange(rawValue: selectedRangeIdentifier) ?? .fiveHour }
        nonmutating set { selectedRangeIdentifier = newValue.rawValue }
    }

    private var selectedConnectionBinding: Binding<UsageConnectionID>? {
        let visible = registryPresentation.visibleConnections
        guard let fallback = visible.first?.connectionID else { return nil }
        return Binding(
            get: {
                guard let selected = selectedConnectionID,
                      visible.contains(where: { $0.connectionID == selected }) else {
                    return fallback
                }
                return selected
            },
            set: { selectedConnectionID = $0 }
        )
    }

    private var activeConnection: UsageRegistryConnection? {
        registryPresentation.connection(id: selectedConnectionID)
    }

    private var activeSelection: UsageRegistrySelection? {
        guard let connection = activeConnection else { return nil }
        let window = registryPresentation.windows(for: connection.connectionID)
            .first { $0.id == selectedWindowID } ?? registryPresentation.windows(for: connection.connectionID).first
        guard let window else { return nil }
        return UsageRegistrySelection(connectionID: connection.connectionID, windowID: window.id, dimension: window.dimension)
    }

    private var activeLegacyDetail: UsageLegacyDetailReference? {
        registryPresentation.legacyDetail(for: activeSelection)
    }

    private var activeSnapshot: ProviderSnapshot? {
        // Do not fall back to another provider: an unavailable selected identity
        // must never render a different provider's observed numbers or analytics.
        guard let activeLegacyDetail else { return nil }
        return snapshots.first { $0.provider == activeLegacyDetail.provider }
    }

    private var activeAnalytics: UsageAnalyticsSnapshot? {
        guard let activeSnapshot, let activeLegacyDetail else { return nil }
        let sourceIDs = [activeLegacyDetail.sourceWindowID]
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
        let windowID = activeLegacyDetail?.sourceWindowID ?? activeAnalytics?.windowID
        guard let windowID,
              let scope = UsagePresentationScope.canonical(
                  provider: activeSnapshot.provider,
                  windowID: windowID
              ) else { return .unknown }
        return presentationAuthorities[scope] ?? .unknown
    }

    private func selectedWindow(in snapshot: ProviderSnapshot) -> UsageWindow? {
        guard let activeLegacyDetail, activeLegacyDetail.provider == snapshot.provider else { return nil }
        return snapshot.windows.first { $0.id == activeLegacyDetail.sourceWindowID }
    }

    private func reconcileSelection() {
        let visible = registryPresentation.visibleConnections
        guard !visible.isEmpty else {
            selectedConnectionID = nil
            selectedWindowID = nil
            return
        }

        let currentConnectionIsVisible = selectedConnectionID.map { id in
            visible.contains { $0.connectionID == id }
        } ?? false
        if !currentConnectionIsVisible {
            let migrated: UsageConnectionID? = if let provider = Provider(rawValue: selectedProviderIdentifier) {
                try? UsageRegistryLegacyMapping.connectionID(for: provider)
            } else {
                nil
            }
            selectedConnectionID = visible.first(where: { $0.connectionID == migrated })?.connectionID
                ?? visible.first?.connectionID
        }

        guard let connection = activeConnection else { return }
        let windows = registryPresentation.windows(for: connection.connectionID)
        if let selectedWindowID, windows.contains(where: { $0.id == selectedWindowID }) {
            return
        }

        let migratedWindow: UsageWindowID? = if let provider = Provider(rawValue: selectedProviderIdentifier),
                                                let sourceWindowID = UsageRange(rawValue: selectedRangeIdentifier)?.sourceWindowIDs.first(where: { sourceID in
                                                    guard let candidateID = try? UsageRegistryLegacyMapping.windowID(
                                                        for: provider, sourceWindowID: sourceID
                                                    ) else { return false }
                                                    return registryPresentation.legacyDetail(for: UsageRegistrySelection(
                                                        connectionID: connection.connectionID,
                                                        windowID: candidateID
                                                    )) != nil
                                                }) {
            try? UsageRegistryLegacyMapping.windowID(for: provider, sourceWindowID: sourceWindowID)
        } else {
            nil
        }
        selectedWindowID = windows.first(where: { $0.id == migratedWindow })?.id ?? windows.first?.id
        syncLegacyRangeFromSelection()
    }

    private func selectWindow(_ id: UsageWindowID) {
        selectedWindowID = id
        syncLegacyRangeFromSelection()
    }

    private func syncLegacyRangeFromSelection() {
        guard let selection = activeSelection,
              let legacy = registryPresentation.legacyDetail(for: selection),
              let snapshot = snapshots.first(where: { $0.provider == legacy.provider }),
              let window = snapshot.windows.first(where: { $0.id == legacy.sourceWindowID }),
              let range = UsageRange.matching(durationMinutes: window.durationMinutes) else { return }
        selectedRange = range
    }

    @ViewBuilder
    private func usageObservationSummary(for snapshot: ProviderSnapshot) -> some View {
        let analytics = activeAnalytics
        let windowState = stateFor(selectedWindow(in: snapshot), snapshot: snapshot)
        UsageObservationSummary(snapshot: snapshot, analytics: analytics, state: windowState)
    }

    private func hasObservedChartData(in snapshot: ProviderSnapshot) -> Bool {
        guard activePresentationAuthority != .authoritativeEmpty else { return false }
        let analytics = chartAnalytics(for: snapshot)
        if !analytics.history.isEmpty { return true }
        guard let window = selectedWindow(in: snapshot) else {
            return !analytics.activity.isEmpty
        }
        guard let resetAt = window.resetAt, let durationMinutes = window.durationMinutes else {
            return !analytics.activity.isEmpty
        }
        let start = resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
        return analytics.activity.contains { point in
            point.date >= start && point.date <= resetAt
        }
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
                    if let activeSnapshot, activeLegacyDetail != nil {
                        usageHeader(activeSnapshot)
                        if activeSnapshot.provenance.quality == .unavailable {
                            unavailableProviderRow(for: activeSnapshot)
                        } else {
                            usageSummary(activeSnapshot)
                            monitoringSurface(activeSnapshot)
                            usageObservationSummary(for: activeSnapshot)
                            if let activeAnalytics,
                               !activeAnalytics.modelBreakdowns.isEmpty || !activeAnalytics.heatmap.isEmpty {
                                UsageAdditionalObservations(analytics: activeAnalytics)
                            }
                        }
                    } else if let activeConnection {
                        usageHeader(nil)
                        UsageRegistryDetailView(
                            presentation: registryPresentation,
                            connectionID: activeConnection.connectionID,
                            selectedWindowID: selectedWindowID,
                            onSelectWindow: selectWindow,
                            onOpenSettings: onManageConnections ?? onOpenSettings
                        )
                    } else {
                        usageHeader(nil)
                        compactEmptyStateCard(for: nil)
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
            reconcileSelection()
        }
        .onChange(of: selectedConnectionID) { _, _ in
            reconcileSelection()
        }
        .onChange(of: registryPresentation) { _, _ in
            reconcileSelection()
        }
        .onChange(of: snapshots) { _, _ in
            reconcileSelection()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            guard registryPresentation.observations.contains(where: { $0.evidenceKind == .manual }) else {
                return
            }
            freshnessNow = date
        }
    }

    private func unavailableProviderRow(for snapshot: ProviderSnapshot) -> some View {
        compactEmptyStateCard(for: snapshot)
    }

    private func compactEmptyStateCard(for snapshot: ProviderSnapshot?) -> some View {
        let presentation = emptyStatePresentation(for: snapshot)
        return LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: 0) {
            UsageEmptyState(
                title: presentation.title,
                detail: presentation.detail,
                onOpenSettings: presentation.action
            )
        }
        .accessibilityIdentifier("usage-empty-provider")
    }

    private func emptyStatePresentation(
        for snapshot: ProviderSnapshot?
    ) -> (title: String, detail: String, action: (() -> Void)?) {
        if state == .loading && activePresentationAuthority != .authoritativeEmpty {
            return (
                "Loading usage data",
                "Waiting for the provider to supply quota observations.",
                nil
            )
        }

        if let failure = presentationPacket?.failure, failure != .none {
            let detail: String
            switch failure {
            case .historyStorage:
                detail = "The saved usage history could not be read. Retry to request a fresh observation."
            case .transport, .invalidPayload:
                detail = "The latest provider request failed. Retry from the toolbar or check Settings."
            case .registryConversion:
                detail = "The latest source was received, but the local Usage presentation could not be rebuilt. Retry from the toolbar."
            case .none:
                detail = "The provider did not return a readable usage observation."
            }
            return ("Usage refresh failed", detail, nil)
        }

        guard let snapshot else {
            if activePresentationAuthority == .authoritativeEmpty {
                return (
                    "No observed usage",
                    "The provider returned no quota observations for this window.",
                    nil
                )
            }
            return (
                "Connect a usage provider",
                "No provider account is connected. Connect one in Settings to see observed usage.",
                onOpenSettings
            )
        }

        switch snapshot.provenance.connector {
        case .reauthRequired:
            return (
                "Reconnect \(snapshot.provider.displayName)",
                "Access to this provider has expired. Reconnect it in Settings to request new observations.",
                onOpenSettings
            )
        case .revoked:
            return (
                "Reconnect \(snapshot.provider.displayName)",
                "This provider authorization was revoked. Reconnect it in Settings before requesting data.",
                onOpenSettings
            )
        case .rateLimited:
            return (
                "Usage refresh is rate-limited",
                "The provider is temporarily refusing new quota reads. Try again later.",
                nil
            )
        case .healthy, .refreshDue:
            if activePresentationAuthority == .authoritativeEmpty {
                return (
                    "No observed usage",
                    "The provider returned no quota observations for this window.",
                    nil
                )
            }
            return (
                "No account data received yet",
                "The configured source has not supplied a readable quota observation.",
                nil
            )
        case .unavailable:
            return (
                "Usage source unavailable",
                "No account data is available from the configured source. Check Settings or retry.",
                onOpenSettings
            )
        case .disabled:
            return (
                "Usage source disabled",
                "Enable this source in Settings to request a quota observation.",
                onOpenSettings
            )
        case .error:
            return (
                "Usage source unavailable",
                "The last provider request could not be read. Retry from the toolbar or check Settings.",
                onOpenSettings
            )
        }
    }

    private func usageHeader(_ snapshot: ProviderSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: LifeOSTokens.Space.sm) {
                    usageTitle(snapshot)
                        .layoutPriority(1)
                    Spacer(minLength: LifeOSTokens.Space.xs)
                    providerSwitcher
                    heroActions
                }
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                    usageTitle(snapshot)
                    HStack(alignment: .center, spacing: LifeOSTokens.Space.sm) {
                        providerSwitcher
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                        heroActions
                    }
                }
            }
            if let snapshot {
                sourceSummary(snapshot)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func usageTitle(_ snapshot: ProviderSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text("Usage")
                .lifeOSTypography(.pageTitle, weight: .semibold)
                .foregroundStyle(LifeOSTokens.primaryText)
            Text(snapshot.map { $0.accountLabel.isEmpty ? $0.provider.displayName : $0.accountLabel } ?? "Provider limits")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceSummary(_ snapshot: ProviderSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                sourceIndicator(snapshot)
                sourceStatus(snapshot)
                if shouldShowTimestamp(for: snapshot) {
                    lastUpdated(snapshot)
                }
            }
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                    sourceIndicator(snapshot)
                    sourceStatus(snapshot)
                }
                if shouldShowTimestamp(for: snapshot) {
                    lastUpdated(snapshot)
                        .padding(.leading, 6 + LifeOSTokens.Space.xs)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func sourceIndicator(_ snapshot: ProviderSnapshot) -> some View {
        Circle()
            .fill(sourceColor(for: snapshot))
            .frame(width: 6, height: 6)
    }

    private func sourceStatus(_ snapshot: ProviderSnapshot) -> some View {
        Text(sourceLabel(for: snapshot))
            .lifeOSTypography(.metadata, weight: .medium)
            .foregroundStyle(sourceColor(for: snapshot))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lastUpdated(_ snapshot: ProviderSnapshot) -> some View {
        Text("Last updated \(snapshot.provenance.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
            .lifeOSTypography(.metadata)
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func shouldShowTimestamp(for snapshot: ProviderSnapshot) -> Bool {
        snapshot.provenance.quality == .observed || snapshot.provenance.quality == .estimated
    }

    private func sourceLabel(for snapshot: ProviderSnapshot) -> String {
        if let failure = presentationPacket?.failure, failure != .none {
            return "Refresh failed · \(snapshot.provenance.source)"
        }

        switch snapshot.provenance.quality {
        case .observed:
            switch snapshot.provenance.connector {
            case .healthy:
                switch snapshot.provenance.freshness() {
                case .fresh, .aging: return "Observed · \(snapshot.provenance.source)"
                case .stale: return "Stale · \(snapshot.provenance.source)"
                case .unavailable: return "Unavailable · \(snapshot.provenance.source)"
                }
            case .refreshDue: return "Refresh due · \(snapshot.provenance.source)"
            case .reauthRequired: return "Re-auth required · \(snapshot.provenance.source)"
            case .rateLimited: return "Rate limited · \(snapshot.provenance.source)"
            case .revoked, .disabled, .unavailable, .error: return "Unavailable · \(snapshot.provenance.source)"
            }
        case .estimated: return "Estimate · non-official"
        case .demo: return "Demo · not live"
        case .unavailable:
            switch snapshot.provenance.connector {
            case .healthy, .refreshDue:
                return "No account data · \(snapshot.provenance.source)"
            case .reauthRequired:
                return "Re-auth required · \(snapshot.provenance.source)"
            case .revoked:
                return "Authorization revoked · \(snapshot.provenance.source)"
            case .rateLimited:
                return "Rate limited · \(snapshot.provenance.source)"
            case .disabled:
                return "Disabled · \(snapshot.provenance.source)"
            case .unavailable, .error:
                return "Unavailable · \(snapshot.provenance.source)"
            }
        }
    }

    private func sourceColor(for snapshot: ProviderSnapshot) -> Color {
        switch snapshot.provenance.quality {
        case .observed:
            switch snapshot.provenance.connector {
            case .healthy:
                switch snapshot.provenance.freshness() {
                case .fresh, .aging: return LifeOSTokens.Series.actual
                case .stale: return LifeOSTokens.warningText
                case .unavailable: return LifeOSTokens.tertiaryText
            }
            case .refreshDue, .reauthRequired, .rateLimited, .error:
                return LifeOSTokens.warningText
            case .revoked, .disabled, .unavailable:
                return LifeOSTokens.tertiaryText
            }
        case .estimated:
            return LifeOSTokens.estimate
        case .demo:
            return LifeOSTokens.warningText
        case .unavailable:
            switch snapshot.provenance.connector {
            case .reauthRequired, .revoked, .rateLimited, .error:
                return LifeOSTokens.warningText
            case .healthy, .refreshDue, .unavailable, .disabled:
                return LifeOSTokens.tertiaryText
            }
        }
    }

    /// Quota windows share one compact row grammar. The adaptive grid gives each
    /// provider-defined window its own surface, then moves from two columns to
    /// one before labels or reset information can become cramped.
    @ViewBuilder
    private func usageSummary(_ snapshot: ProviderSnapshot) -> some View {
        let windows = snapshot.windows.sorted {
            if ($0.durationMinutes ?? .max) != ($1.durationMinutes ?? .max) {
                return ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max)
            }
            return $0.id < $1.id
        }

        Group {
            if windows.isEmpty {
                LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: 0) {
                    UsageEmptyState(
                        title: "No usage window",
                        detail: "The connected source has not supplied a quota window."
                    )
                }
                .accessibilityIdentifier("usage-summary-empty")
            } else {
                ViewThatFits(in: .horizontal) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 0), spacing: LifeOSTokens.Space.md),
                            GridItem(.flexible(minimum: 0), spacing: LifeOSTokens.Space.md)
                        ],
                        alignment: .leading,
                        spacing: LifeOSTokens.Space.md
                    ) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            usageWindowCard(window, in: snapshot, isSecondary: index > 0)
                        }
                    }
                    .frame(minWidth: UsageLayoutContract.twoColumnBreakpoint, alignment: .leading)

                    LazyVGrid(
                        columns: [GridItem(.flexible(minimum: 0))],
                        alignment: .leading,
                        spacing: LifeOSTokens.Space.sm
                    ) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            usageWindowCard(window, in: snapshot, isSecondary: index > 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("usage-summary")
    }

    private func usageWindowCard(
        _ window: UsageWindow,
        in snapshot: ProviderSnapshot,
        isSecondary: Bool = false
    ) -> some View {
        let content = UsageWindowSummaryRow(window: window, state: stateFor(window, snapshot: snapshot))
        let range = UsageRange.matching(durationMinutes: window.durationMinutes)
        let registryWindowID = activeConnection.flatMap { connection in
            try? UsageRegistryLegacyMapping.windowID(for: snapshot.provider, sourceWindowID: window.id)
        }
        let accessibilityIdentifier = isSecondary
            ? "usage-secondary-window-\(window.id)"
            : "usage-window-\(window.id)"

        return Group {
            if range != nil, let registryWindowID {
                Button {
                    guard activeSelection?.windowID != registryWindowID else { return }
                    selectWindow(registryWindowID)
                } label: {
                    LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: UsageLayoutContract.cardPadding) {
                        content
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(activeSelection?.windowID == registryWindowID ? .isSelected : [])
                .accessibilityIdentifier(accessibilityIdentifier)
            } else {
                LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: UsageLayoutContract.cardPadding) {
                    content
                }
                .accessibilityIdentifier(accessibilityIdentifier)
            }
        }
        .accessibilityLabel("\(window.label) usage window")
    }

    private func stateFor(_ window: UsageWindow?, snapshot: ProviderSnapshot) -> UsageValueState {
        UsageWindowStateResolver.state(for: window, snapshot: snapshot, loadState: state)
    }

    private func monitoringSurface(_ snapshot: ProviderSnapshot) -> some View {
        let hasChartData = hasObservedChartData(in: snapshot)
        let hasAvailableRange = !availableRanges.isEmpty

        return LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: UsageLayoutContract.cardPadding) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: UsageLayoutContract.controlGap) {
                        monitoringTitle(hasChartData: hasChartData)
                            .layoutPriority(1)
                        if hasAvailableRange {
                            rangeControl
                        }
                    }
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                        monitoringTitle(hasChartData: hasChartData)
                        if hasAvailableRange {
                            rangeControl
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if hasChartData {
                    UsageProjectionChart(
                        provider: snapshot.provider,
                        window: selectedWindow(in: snapshot),
                        analytics: chartAnalytics(for: snapshot),
                        accountScope: snapshot.accountLabel,
                        generation: presentationPacket?.generation ?? 0,
                        presentationAuthority: activePresentationAuthority,
                        updateKind: presentationPacket?.updateKind ?? .initial
                    )
                } else {
                    UsageEmptyState(
                        title: "No observed usage history",
                        detail: "The provider has not supplied quota observations for this window."
                    )
                    .accessibilityIdentifier("usage-history-unavailable")
                }
            }
        }
        .accessibilityIdentifier("usage-chart-shell")
    }

    private func monitoringTitle(hasChartData: Bool) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text("Usage trend")
                .lifeOSTypography(.cardTitle)
                .foregroundStyle(LifeOSTokens.primaryText)
            Text(hasChartData ? "Percent consumed across the selected window" : "Waiting for observed quota history")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Toolbar row — title, provider context, refresh and settings.

    private var heroActions: some View {
        HStack(spacing: LifeOSTokens.Space.xs) {
            if let onManageConnections {
                LifeOSIconButton(
                    icon: .views,
                    accessibilityLabel: "Manage Usage sources",
                    size: LifeOSTokens.Control.iconButton,
                    tint: LifeOSTokens.secondaryText,
                    action: onManageConnections
                )
                .accessibilityIdentifier("usage-manage-sources")
            }
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
            ForEach(registryPresentation.windows(for: activeConnection?.connectionID)) { window in
                Button {
                    selectWindow(window.id)
                } label: {
                    HStack {
                        Text(window.label)
                        if window.id == activeSelection?.windowID { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: LifeOSTokens.Space.xs) {
                Text(
                    activeSnapshot.flatMap { selectedWindow(in: $0)?.label }
                        ?? registryPresentation.windows(for: activeConnection?.connectionID).first { $0.id == selectedWindowID }?.label
                        ?? "Select window"
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
            .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                    .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
            }
            .frame(minHeight: LifeOSTokens.Control.standardHeight, alignment: .center)
        }
        .foregroundStyle(LifeOSTokens.primaryText)
        .accessibilityLabel("Usage window")
        .accessibilityValue(
            activeSnapshot.flatMap { selectedWindow(in: $0)?.label }
                ?? registryPresentation.windows(for: activeConnection?.connectionID).first { $0.id == selectedWindowID }?.label
                ?? "Select window"
        )
    }

    @ViewBuilder
    private var providerSwitcher: some View {
        if let binding = selectedConnectionBinding {
            Menu {
                Picker("Source", selection: binding) {
                    ForEach(registryPresentation.visibleConnections) { connection in
                        Text("\(connectionTitle(connection)) · \(statusText(for: connection))")
                            .tag(connection.connectionID)
                    }
                }
            } label: {
                HStack(spacing: LifeOSTokens.Space.xs) {
                    LifeOSIcon(.usage, context: .toolbar)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                    Text(connectionTitle(activeConnection))
                        .lifeOSTypography(.label, weight: .medium)
                        .foregroundStyle(LifeOSTokens.primaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, LifeOSTokens.Space.sm)
                .padding(.vertical, LifeOSTokens.Space.xs)
                .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                        .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
                }
                .frame(minWidth: 148, minHeight: LifeOSTokens.Control.standardHeight, alignment: .leading)
            }
            // Menus re-tint their label with the system accent; pin neutral chrome (§1).
            .foregroundStyle(LifeOSTokens.secondaryText)
            .accessibilityLabel("Usage source switcher, currently \(connectionTitle(activeConnection)), \(statusText(for: activeConnection))")
        }
    }

    private func connectionTitle(_ connection: UsageRegistryConnection?) -> String {
        guard let connection else { return "Usage sources" }
        if connection.providerID.rawValue == "gemini_subscription" { return "Google AI Pro" }
        return connection.label
    }

    private func statusText(for connection: UsageRegistryConnection?) -> String {
        guard let connection else { return "No source selected" }
        if connection.providerID.rawValue == "gemini_subscription" {
            return manualGeminiStatus(for: connection) ?? "Quota unavailable"
        }
        switch connection.authState {
        case .reauthRequired: return "Reauthorization required"
        case .revoked: return "Access revoked"
        case .disconnected where connection.availability == .available: return "Cached value"
        default: break
        }
        if registryPresentation.failure != .none, connection.availability == .available {
            return registryPresentation.failure.label
        }
        if connection.providerID.rawValue == "gemini_api" { return "API / project" }
        switch connection.availability {
        case .available:
            return connection.freshness == .stale ? "Stale" : "Observed"
        case .unsupported: return "Unavailable"
        case .disabled: return "Hidden"
        case .unavailable: return "No data"
        }
    }

    private func manualGeminiStatus(for connection: UsageRegistryConnection) -> String? {
        let manualObservations = registryPresentation.observations
            .filter({
                $0.selection.connectionID == connection.connectionID &&
                $0.evidenceKind == .manual
            })
        guard let latestObservation = manualObservations.max(by: { $0.observedAt < $1.observedAt }) else {
            return nil
        }
        let recorded = "Manually recorded · \(latestObservation.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        let needsUpdating = manualObservations.contains { manualGeminiIsStale($0) }
        return needsUpdating ? "\(recorded) · Needs updating" : recorded
    }

    private func manualGeminiIsStale(_ observation: UsageRegistryObservation) -> Bool {
        guard freshnessNow.timeIntervalSinceReferenceDate.isFinite,
              observation.observedAt.timeIntervalSinceReferenceDate.isFinite else {
            return true
        }
        let age = max(0, freshnessNow.timeIntervalSince(observation.observedAt))
        guard age < UsageManualReading.staleAfter else { return true }
        return observation.resetAt.map { freshnessNow >= $0 } ?? false
    }

}

private struct UsageObservationSummary: View {
    let snapshot: ProviderSnapshot
    let analytics: UsageAnalyticsSnapshot?
    let state: UsageValueState

    private var facts: UsageFacts {
        UsageFacts.compute(from: analytics, fallbackProvenance: snapshot.provenance)
    }

    var body: some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: UsageLayoutContract.cardPadding) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                        Text("Window facts")
                            .lifeOSTypography(.cardTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        Text("Observed details for the selected window")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                    }
                    Spacer(minLength: 0)
                }

                Divider()
                    .overlay(LifeOSTokens.hairlineBorder)

                factsContent
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-observation-summary")
    }

    @ViewBuilder
    private var factsContent: some View {
        VStack(spacing: 0) {
            if let totals = facts.observedTotals {
                factRow("Observed points", totals.observationCount.formatted())
                Divider().overlay(LifeOSTokens.hairlineBorder)
            }
            if let peak = facts.peakActivity {
                factRow("Peak hourly activity", "\(peak.tokens.formatted(.number.notation(.compactName))) tokens")
                Divider().overlay(LifeOSTokens.hairlineBorder)
            }
            factRow("Window status", state.label)
            if facts.observedTotals == nil && facts.peakActivity == nil {
                Divider().overlay(LifeOSTokens.hairlineBorder)
                Text(noObservationsDetail)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, LifeOSTokens.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noObservationsDetail: String {
        switch state {
        case .loading:
            return "Waiting for provider observations for this window."
        case .demo:
            return "No fixture activity observations are available for this window."
        case .unavailable:
            return "No provider activity observations are available for this window."
        default:
            return "No token activity observations were supplied for this window."
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: LifeOSTokens.Space.sm)
            Text(value)
                .lifeOSTypography(.label, weight: .semibold)
                .foregroundStyle(LifeOSTokens.primaryText)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, LifeOSTokens.Space.xs)
    }
}

private struct UsageAdditionalObservations: View {
    let analytics: UsageAnalyticsSnapshot
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                if !analytics.modelBreakdowns.isEmpty {
                    UsageModelMixCard(models: analytics.modelBreakdowns)
                }
                if !analytics.heatmap.isEmpty {
                    UsageHeatmapCard(cells: analytics.heatmap)
                }
            }
            .padding(.top, LifeOSTokens.Space.xs)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
                LifeOSIcon(.graphUp, context: .card)
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
        .padding(UsageLayoutContract.cardPadding)
        .flatCard()
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
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            stackedLayout
        }
        .padding(.horizontal, LifeOSTokens.Space.sm)
        .padding(.vertical, LifeOSTokens.Space.sm)
        .frame(minHeight: 72, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("usage-empty-state")
    }

    private var messageBlock: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(title)
                .lifeOSTypography(.cardTitle)
                .foregroundStyle(LifeOSTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .lifeOSTypography(.body)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if let onOpenSettings {
            LifeOSButton("Open Settings", variant: .tertiary, action: onOpenSettings)
        }
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: LifeOSTokens.Space.sm) {
            LifeOSIcon(.usage, context: .card)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            messageBlock
                .layoutPriority(1)
            actionView
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
            HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
                LifeOSIcon(.usage, context: .card)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                messageBlock
            }
            actionView
        }
    }
}

/// Compact quota summary used above the chart. The quota value is the primary
/// signal; reset and provenance stay on the same card so the screen does not
/// need a second hero or a decorative ring to explain the number.
private struct UsageWindowSummaryRow: View {
    let window: UsageWindow
    let state: UsageValueState

    private var remainingFraction: Double? {
        guard let usedPercent = window.usedPercent, usedPercent.isFinite else { return nil }
        return min(max(1 - usedPercent, 0), 1)
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
            return LifeOSTokens.Series.actual
        case .estimated, .projected:
            return LifeOSTokens.estimate
        case .demo:
            return LifeOSTokens.warningText
        case .stale:
            return LifeOSTokens.warningText
        case .error:
            return LifeOSTokens.danger
        case .loading:
            return LifeOSTokens.info
        case .unavailable:
            return LifeOSTokens.tertiaryText
        }
    }

    private var valueColor: Color {
        switch state {
        case .observed:
            return LifeOSTokens.Series.actual
        case .estimated, .projected:
            return LifeOSTokens.estimate
        case .demo:
            return LifeOSTokens.warningText
        case .stale:
            return LifeOSTokens.warningText
        case .error:
            return LifeOSTokens.danger
        case .loading:
            return LifeOSTokens.info
        case .unavailable:
            return LifeOSTokens.tertiaryText
        }
    }

    private var trackColor: Color {
        switch state {
        case .estimated, .projected:
            return LifeOSTokens.Series.estimate
        case .demo:
            return LifeOSTokens.warningText
        case .observed:
            return LifeOSTokens.Series.actual
        case .stale:
            return LifeOSTokens.warningText
        case .error:
            return LifeOSTokens.danger
        case .loading:
            return LifeOSTokens.info
        case .unavailable:
            return LifeOSTokens.tertiaryText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                Text(window.label)
                    .lifeOSTypography(.label, weight: .medium)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

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
                if let remainingFraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(LifeOSTokens.primaryText.opacity(0.10))
                            Capsule()
                                .fill(trackColor)
                                .frame(width: geometry.size.width * CGFloat(1 - remainingFraction))
                        }
                    }
                    .frame(height: 4)
                } else {
                    Text("No observed value")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            .frame(minHeight: 14, alignment: .center)

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
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label), \(remainingText) remaining, \(state.label), \(resetText)")
    }
}

// MARK: - Model mix (02 §4) — kept as a supplementary card, restyled to blue-forward tokens.

struct UsageModelMixCard: View {
    let models: [UsageModelBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
            UsageCardHeader(title: "Model mix", subtitle: "Token composition by model", icon: .usage)
            ModelCompositionChart(models: models)
        }
        .padding(UsageLayoutContract.cardPadding)
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
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
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
        .padding(UsageLayoutContract.cardPadding)
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
        HStack(alignment: .top, spacing: LifeOSTokens.Space.xs) {
            LifeOSIcon(icon, context: .card)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text(title).lifeOSTypography(.cardTitle)
                Text(subtitle)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
