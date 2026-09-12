import SwiftUI

@MainActor
final class FitnessObservationCoordinator: ObservableObject {
    @Published private(set) var observation: FitnessObservationEnvelope?

    private let usesVisualFixtures: Bool
    private let client: TailscaleSyncClient?
    private let fetchObservation: (@Sendable () async throws -> FitnessObservationEnvelope)?
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<FitnessObservationEnvelope?, Never>?

    init(
        usesVisualFixtures: Bool,
        fetchObservation: (@Sendable () async throws -> FitnessObservationEnvelope)? = nil
    ) {
        self.usesVisualFixtures = usesVisualFixtures
        self.fetchObservation = fetchObservation
        self.client = FitnessObservationSyncPolicy.allowsNetwork(usesVisualFixtures: usesVisualFixtures)
            ? TailscaleSyncClient()
            : nil
    }

    func refresh() async {
        guard FitnessObservationSyncPolicy.allowsNetwork(usesVisualFixtures: usesVisualFixtures),
              let client else {
            observation = nil
            return
        }

        if let refreshTask {
            // Launch, activation, and the menu refresh can arrive together.
            // They must observe one fetch so an older response or failure can
            // never replace a newer result.
            _ = await refreshTask.value
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        let fetch = fetchObservation ?? { try await client.fetchFitnessObservation() }
        let task = Task<FitnessObservationEnvelope?, Never> {
            try? await fetch()
        }
        refreshTask = task
        let nextObservation = await task.value
        guard generation == refreshGeneration else { return }
        refreshTask = nil
        observation = nextObservation
    }
}

@main
struct LifeOSMacApp: App {
    @StateObject private var calendarCoordinator: CalendarCoordinator
    @StateObject private var usageCoordinator: UsageCoordinator
    @StateObject private var financeCoordinator: FinanceCoordinator
    @StateObject private var clipperCoordinator: ClipperCoordinator
    @StateObject private var fitnessTrainingCoordinator: FitnessTrainingCoordinator
    @StateObject private var fitnessObservationCoordinator: FitnessObservationCoordinator
    private let usesVisualFixtures: Bool
    /// Coalescing state for the future-module widget snapshot publisher.
    /// Mac has no HealthKit, so only Finance/Nutrition are mapped; Fitness
    /// stays permanently unavailable via `WidgetSnapshotPublisher`'s
    /// non-iOS mapping functions. `WidgetSnapshotPublisher` is an actor, so
    /// a plain `let` keeps one durable instance alive across the call sites
    /// below — its own mailbox serializes concurrent `publish` calls.
    private let widgetSnapshotPublisher = WidgetSnapshotPublisher()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let enabled = Self.visualFixturesEnabled
        usesVisualFixtures = enabled
        let cachedUsage = enabled ? nil : SharedSnapshotStore.readLive()
        _usageCoordinator = StateObject(
            wrappedValue: enabled
                ? UsageCoordinator.visualFixture()
                : UsageCoordinator(
                    initialProviders: cachedUsage?.providers ?? [],
                    initialUpdatedAt: cachedUsage?.updatedAt
                )
        )
        _financeCoordinator = StateObject(wrappedValue: FinanceCoordinator(
            initialState: enabled ? .demo : .unavailable
        ))
        _clipperCoordinator = StateObject(wrappedValue: ClipperCoordinator(
            initialState: enabled ? .demo : .unavailable
        ))
        _calendarCoordinator = StateObject(
            wrappedValue: CalendarCoordinator(
                initialSnapshot: enabled ? CalendarVisualFixtures.snapshot() : CalendarSnapshot(),
                usesVisualFixtures: enabled,
                defaults: enabled ? CalendarCoordinator.makeVisualFixtureDefaults() : nil
            )
        )
        _fitnessTrainingCoordinator = StateObject(
            wrappedValue: enabled
                ? FitnessTrainingCoordinator(usesVisualFixtures: true)
                : FitnessTrainingCoordinator()
        )
        _fitnessObservationCoordinator = StateObject(
            wrappedValue: FitnessObservationCoordinator(usesVisualFixtures: enabled)
        )
    }

    /// TestAction supplies the environment flag before the hosted app is
    /// initialized. Keep the argument form for existing UI-test launchers,
    /// while making the scheme/test-plan environment the deterministic gate
    /// for unit-test hosts.
    private static var visualFixturesEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-LifeOSVisualFixtures")
            || ProcessInfo.processInfo.environment["LIFEOS_VISUAL_FIXTURES"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            LifeOSMacSceneRoot(
                calendarCoordinator: calendarCoordinator,
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                clipperCoordinator: clipperCoordinator,
                fitnessTrainingCoordinator: fitnessTrainingCoordinator,
                fitnessObservation: fitnessObservationCoordinator.observation,
                usesVisualFixtures: usesVisualFixtures
            )
                // Keep the narrow acceptance viewport reachable. The root
                // layout collapses its sidebar below 900pt, so the window
                // must be allowed to reach the documented 800pt state.
                .frame(minWidth: 800, minHeight: 600)
                .tint(LifeOSTokens.accent)
                .task {
                    if !usesVisualFixtures {
                        await calendarCoordinator.load()
                        calendarCoordinator.startSync()
                        await usageCoordinator.refresh()
                        await financeCoordinator.refresh()
                        await clipperCoordinator.refresh()
                        await fitnessObservationCoordinator.refresh()
                        publishWidgetSnapshots()
                    }
                }
                .onChange(of: financeCoordinator.summary) { _, _ in
                    publishWidgetSnapshots()
                }
                .onChange(of: financeCoordinator.state) { _, _ in
                    publishWidgetSnapshots()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, !usesVisualFixtures else { return }
                    Task { @MainActor in
                        await fitnessObservationCoordinator.refresh()
                    }
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1512, height: 982)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    guard !usesVisualFixtures else { return }
                    Task {
                        await calendarCoordinator.manualRefresh()
                        await usageCoordinator.refresh()
                        await financeCoordinator.refresh()
                        await clipperCoordinator.refresh()
                        await fitnessObservationCoordinator.refresh()
                        publishWidgetSnapshots()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView(
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                clipperCoordinator: clipperCoordinator,
                usesVisualFixtures: usesVisualFixtures
            )
                .frame(minWidth: 520, minHeight: 360)
                .tint(LifeOSTokens.accent)
        }
    }

    /// Mirrors `LifeOSApp.publishWidgetSnapshots()` on iOS: maps confirmed
    /// Finance/Nutrition state into a `FutureWidgetSnapshot` and requests a
    /// coalesced reload for `LifeOSMacWidget`'s future-module widget kinds.
    /// No-op during `-LifeOSVisualFixtures` (demo data must never publish)
    /// and when no App Group container is configured.
    private func publishWidgetSnapshots() {
        guard !usesVisualFixtures,
              FutureWidgetSnapshotStore.url() != nil else { return }

        let financeSummary = financeCoordinator.summary
        let financeState = financeCoordinator.state
        let now = Date.now
        let publisher = widgetSnapshotPublisher

        // `publisher` is an actor; every call here targets the same
        // instance, so a burst of near-simultaneous
        // `publishWidgetSnapshots()` calls serializes on its mailbox and
        // only a genuine content change results in a write + reload.
        Task.detached(priority: .utility) {
            let finance = WidgetSnapshotPublisher.mapFinance(summary: financeSummary, state: financeState, now: now)
            let fitness = WidgetSnapshotPublisher.mapFitness(now: now)
            let fitnessWidgets = WidgetSnapshotPublisher.mapFitnessWidgets(now: now)
            let nutrition: WidgetSafeNutritionSummary
            if let mealStore = try? NutritionMealStore(), let goalStore = try? NutritionGoalStore() {
                nutrition = WidgetSnapshotPublisher.mapNutrition(mealStore: mealStore, goalStore: goalStore, on: now, calendar: .current)
            } else {
                nutrition = .unavailable()
            }

            await publisher.publish(
                finance: finance,
                fitness: fitness,
                fitnessWidgets: fitnessWidgets,
                nutrition: nutrition,
                privacyMode: .summaryAllowed,
                now: now
            )
        }
    }
}

struct LifeOSMacSceneState {
    let module: LifeOSModule
    let route: LifeOSDeepLink?
    let showingUsage: Bool
    let sidebarCollapsed: Bool
    let sidebarWidth: Double
}

private struct LifeOSMacSceneRoot: View {
    let calendarCoordinator: CalendarCoordinator
    let usageCoordinator: UsageCoordinator
    let financeCoordinator: FinanceCoordinator
    let clipperCoordinator: ClipperCoordinator
    let fitnessTrainingCoordinator: FitnessTrainingCoordinator
    let fitnessObservation: FitnessObservationEnvelope?
    let usesVisualFixtures: Bool
    @SceneStorage("LifeOS.mac.module.v1") private var restoredModuleIdentifier = LifeOSModule.home.rawValue
    @SceneStorage("LifeOS.mac.route.v1") private var restoredRouteIdentifier = ""
    @SceneStorage("LifeOS.mac.showingUsage.v1") private var restoredShowingUsage = false
    @SceneStorage("LifeOS.mac.sidebarCollapsed.v1") private var restoredSidebarCollapsed = false
    @SceneStorage("LifeOS.mac.sidebarWidth.v1") private var restoredSidebarWidth = 232.0

    var body: some View {
        let module = LifeOSModule(rawValue: restoredModuleIdentifier).flatMap {
            LifeOSModule.macPrimaryModules.contains($0) ? $0 : nil
        } ?? .home
        let moduleBinding = $restoredModuleIdentifier
        let routeBinding = $restoredRouteIdentifier
        let usageBinding = $restoredShowingUsage
        let collapsedBinding = $restoredSidebarCollapsed
        let widthBinding = $restoredSidebarWidth

        LifeOSMacRootView(
            calendarCoordinator: calendarCoordinator,
            usesVisualFixtures: usesVisualFixtures,
            usageCoordinator: usageCoordinator,
            financeCoordinator: financeCoordinator,
            clipperCoordinator: clipperCoordinator,
            fitnessTrainingCoordinator: fitnessTrainingCoordinator,
            fitnessObservation: fitnessObservation,
            initialModule: module,
            initialRoute: restoredRoute,
            initiallyShowingUsage: restoredShowingUsage && module == .home,
            initialSidebarCollapsed: restoredSidebarCollapsed,
            initialSidebarWidth: restoredSidebarWidth,
            onSceneStateChange: { state in
                moduleBinding.wrappedValue = state.module.rawValue
                routeBinding.wrappedValue = state.route?.restorationKey ?? ""
                usageBinding.wrappedValue = state.showingUsage
                collapsedBinding.wrappedValue = state.sidebarCollapsed
                widthBinding.wrappedValue = state.sidebarWidth
            }
        )
    }

    private var restoredRoute: LifeOSDeepLink? {
        guard case .existing(let route) = LifeOSNavigationRoute(restorationKey: restoredRouteIdentifier) else {
            return nil
        }
        return route == .newCalendarEvent ? .calendar : route
    }
}

/// The macOS shell keeps the primary navigation persistent. This is intentionally
/// a SwiftUI layout so snapshots and the actual app share the same structure.
@MainActor
struct LifeOSMacRootView: View {
    @ObservedObject private var calendarCoordinator: CalendarCoordinator
    @ObservedObject private var usageCoordinator: UsageCoordinator
    @ObservedObject private var financeCoordinator: FinanceCoordinator
    @ObservedObject private var clipperCoordinator: ClipperCoordinator
    @ObservedObject private var fitnessTrainingCoordinator: FitnessTrainingCoordinator
    private let usesVisualFixtures: Bool
    private let fitnessObservation: FitnessObservationEnvelope?
    @State private var routeState: LifeOSMacRouteState
    @State private var sidebarCollapsed = false
    @State private var sidebarWidth: Double = 232
    @State private var hoveredSidebarModule: LifeOSModule?
    @State private var showingCommandPalette = false
    @State private var sidebarResizeStart: CGFloat?
    @StateObject private var calendarPresentationState: CalendarPresentationState
    @StateObject private var financePresentationState: FinancePresentationState
    @StateObject private var fitnessPresentationState: FitnessPresentationState
    private let onSceneStateChange: ((LifeOSMacSceneState) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor
    init(
        calendarCoordinator: CalendarCoordinator,
        usesVisualFixtures: Bool = false,
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator? = nil,
        clipperCoordinator: ClipperCoordinator? = nil,
        fitnessTrainingCoordinator: FitnessTrainingCoordinator? = nil,
        fitnessObservation: FitnessObservationEnvelope? = nil,
        initialModule: LifeOSModule = .home,
        initialRoute: LifeOSDeepLink? = nil,
        initiallyShowingUsage: Bool = false,
        initialSidebarCollapsed: Bool = false,
        initialSidebarWidth: Double = 232,
        onSceneStateChange: ((LifeOSMacSceneState) -> Void)? = nil
    ) {
        self.calendarCoordinator = calendarCoordinator
        self.usesVisualFixtures = usesVisualFixtures
        self.usageCoordinator = usageCoordinator
        self.financeCoordinator = financeCoordinator ?? FinanceCoordinator(initialState: usesVisualFixtures ? .demo : .unavailable)
        self.clipperCoordinator = clipperCoordinator ?? ClipperCoordinator(initialState: usesVisualFixtures ? .demo : .unavailable)
        self.fitnessTrainingCoordinator = fitnessTrainingCoordinator
            ?? FitnessTrainingCoordinator(usesVisualFixtures: usesVisualFixtures)
        self.fitnessObservation = fitnessObservation
        _routeState = State(initialValue: LifeOSMacRouteState(
            initialModule: initialModule,
            initialRoute: initialRoute,
            initiallyShowingUsage: initiallyShowingUsage
        ))
        _sidebarCollapsed = State(initialValue: initialSidebarCollapsed)
        _sidebarWidth = State(initialValue: initialSidebarWidth)
        _calendarPresentationState = StateObject(wrappedValue: CalendarPresentationState())
        let financePresentationState = FinancePresentationState()
        let fitnessPresentationState = FitnessPresentationState()
        if let initialRoute {
            financePresentationState.receiveExternalRoute(Self.financeRoute(for: initialRoute))
            fitnessPresentationState.receiveExternalRoute(
                initialRoute.module == .fitness ? initialRoute : nil
            )
        }
        _financePresentationState = StateObject(wrappedValue: financePresentationState)
        _fitnessPresentationState = StateObject(wrappedValue: fitnessPresentationState)
        self.onSceneStateChange = onSceneStateChange
    }

    private func rootLayout(isCompact: Bool) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                sidebar(isCompact: isCompact)
                if !isCompact && !sidebarCollapsed {
                    sidebarResizeHandle
                }
            }
            .frame(width: effectiveSidebarWidth(isCompact: isCompact))
            Rectangle()
                .fill(LifeOSTokens.hairlineBorder)
                .frame(width: 1)
            VStack(spacing: 0) {
                topBar(isCompact: isCompact)
                Rectangle()
                    .fill(LifeOSTokens.hairlineBorder)
                    .frame(height: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var body: some View {
        Group {
            if usesVisualFixtures && !ProcessInfo.processInfo.arguments.contains("-LifeOSExternalURLTests") {
                // Snapshot hosts are AppKit views, not a SwiftUI Scene. Keep
                // external-event registration out of that fixture path so
                // tests stay offline and do not emit scene-lifecycle warnings.
                layoutWithResponsiveSidebar
            } else {
                layoutWithResponsiveSidebar
                    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                    .onOpenURL { url in
                        showingCommandPalette = false
                        switch LifeOSNavigationRoute(url: url) {
                        case .existing(let destination):
                            navigate(to: destination)
                        case .home:
                            select(.home)
                        case .destinationUnavailable:
                            applyRoute(.showDestinationUnavailable)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LifeOSTokens.screenCanvas)
        .onChange(of: routeState) { _, _ in reportSceneState() }
        .onChange(of: sidebarCollapsed) { _, _ in reportSceneState() }
        .onChange(of: sidebarWidth) { _, _ in reportSceneState() }
        .sheet(isPresented: $showingCommandPalette) {
            LifeOSMacCommandPalette(onSelect: { module in select(module) })
                .frame(width: 560, height: 420)
        }
    }

    private var layoutWithResponsiveSidebar: some View {
        GeometryReader { proxy in
            rootLayout(isCompact: proxy.size.width < 900)
        }
    }

    private var resolvedSidebarWidth: CGFloat {
        let value = CGFloat(sidebarWidth)
        guard value.isFinite else { return 232 }
        return min(max(value, 200), 260)
    }

    private func effectiveSidebarWidth(isCompact: Bool) -> CGFloat {
        sidebarCollapsed || isCompact ? 64 : resolvedSidebarWidth
    }

    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(LifeOSTokens.hairlineBorder.opacity(0.001))
            .frame(width: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = sidebarResizeStart ?? resolvedSidebarWidth
                        sidebarResizeStart = start
                        sidebarWidth = Double(min(max(start + value.translation.width, 200), 260))
                    }
                    .onEnded { _ in sidebarResizeStart = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue(Text("\(Int(resolvedSidebarWidth)) points"))
            .accessibilityHint("Drag to resize between 200 and 260 points")
            .accessibilityIdentifier("mac-sidebar-resize")
    }

    private var sidebarCollapseButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : LifeOSMotion.snappy) {
                sidebarCollapsed.toggle()
            }
        } label: {
            LifeOSIcon(
                sidebarCollapsed ? .chevronRight : .chevronLeft,
                context: .disclosure
            )
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(LifeOSTokens.tertiaryText)
        .accessibilityLabel(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityIdentifier("mac-sidebar-collapse")
    }

    private func sidebar(isCompact: Bool) -> some View {
        let collapsed = sidebarCollapsed || isCompact
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if sidebarCollapsed && !isCompact {
                    sidebarCollapseButton
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    HStack(spacing: 8) {
                        LifeOSIcon(.overview, context: .navigation)
                            .foregroundStyle(LifeOSTokens.accent)
                        if !collapsed {
                            Text("Life OS")
                                .lifeOSTypography(.label, weight: .semibold)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                        Spacer(minLength: 0)
                        if !isCompact {
                            sidebarCollapseButton
                        }
                    }
                }
            }
            .padding(.horizontal, collapsed ? 14 : 12)
            .padding(.top, 12)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(LifeOSModule.macPrimaryModules.filter { $0 != .settings }) { module in
                        sidebarButton(module, collapsed: collapsed)
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 12)
            sidebarButton(.settings, collapsed: collapsed)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
        }
        .frame(width: effectiveSidebarWidth(isCompact: isCompact))
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(LifeOSTokens.canvas)
        .accessibilityIdentifier("mac-persistent-sidebar")
    }

    private var moduleOwnsPageIdentity: Bool {
        switch routeState.module {
        case .home, .finance, .fitness, .tax:
            return true
        default:
            return false
        }
    }

    private func topBar(isCompact: Bool) -> some View {
        HStack(spacing: 10) {
            if isHomeDetail {
                Button { backHome() } label: {
                    LifeOSIcon(.chevronLeft)
                        .frame(width: 15, height: 15)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .accessibilityLabel("Back")
                .accessibilityIdentifier(routeState.showingUsage ? "mac-usage-back" : "mac-home-detail-back")
            }
            if !moduleOwnsPageIdentity {
                VStack(alignment: .leading, spacing: 2) {
                        Text(routeState.module.title)
                        .lifeOSTypography(.sectionTitle, weight: .bold)
                    if let section = routeState.route?.sectionTitle ?? (routeState.showingUsage ? "Usage" : nil) {
                        Text(section)
                            .lifeOSTypography(.body)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 16)

            Button { showingCommandPalette = true } label: {
                Group {
                    if isCompact {
                        LifeOSIcon(.search, context: .toolbar)
                            .frame(width: 32, height: 32)
                    } else {
                        HStack(spacing: 8) {
                            LifeOSIcon(.search, context: .toolbar)
                            Text("Search or jump").lifeOSTypography(.body)
                            Text("⌘K").lifeOSTypography(.body, weight: .semibold)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                }
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .padding(.horizontal, 11)
                .frame(minHeight: 32)
                .background(LifeOSTokens.surface, in: Capsule())
                .overlay(Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("Open command palette")
            .accessibilityIdentifier("mac-command-palette-trigger")
        }
        .padding(.horizontal, isCompact ? 12 : 24)
        .frame(height: 52)
        .background(LifeOSTokens.canvas)
        .accessibilityIdentifier("mac-global-top-bar")
    }

    private var detail: some View {
        detail(for: routeState, interactive: true)
            // The route snapshot changes frequently, but the module view owns
            // its lifecycle. A module-only identity lets scene-owned
            // presentation state handle route/detail changes in place.
            .id(routeState.mountedIdentity)
            // SwiftUI removes the already-mounted outgoing module when this
            // identity changes. That preserves its lifecycle history during
            // the fade without constructing a second live module tree.
            .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func detail(for route: LifeOSMacRouteState, interactive: Bool) -> some View {
        if route.showingDestinationUnavailable {
            destinationUnavailableDetail(interactive: interactive)
        } else {
            moduleDetail(for: route, interactive: interactive)
        }
    }

    @ViewBuilder
    private func destinationUnavailableDetail(interactive: Bool) -> some View {
        LifeOSDestinationUnavailableView(
            onBack: { if interactive { restoreUnavailableOrigin() } },
            onHome: { if interactive { select(.home) } }
        )
    }

    @ViewBuilder
    private func moduleDetail(for route: LifeOSMacRouteState, interactive: Bool) -> some View {
        switch route.module {
        case .home:
            homeDetail(for: route, interactive: interactive)
        case .calendar:
            let expectedMountGeneration = route.mountGeneration
            let expectedMountedIdentity = route.mountedIdentity
            CalendarView(
                coordinator: calendarCoordinator,
                requestNewEvent: .constant(false),
                requestNewEventID: interactive ? route.pendingCalendarEventID : nil,
                consumeNewEventRequest: interactive ? { id in
                    consumeCalendarEvent(id: id, expectedMountGeneration: route.mountGeneration)
                } : nil,
                isRouteActive: interactive ? {
                    isCalendarMountActive(
                        expectedMountGeneration: expectedMountGeneration,
                        expectedMountedIdentity: expectedMountedIdentity
                    )
                } : nil,
                presentationState: calendarPresentationState
            )
        case .finance:
            financeDetail(for: route, interactive: interactive)
        case .fitness:
            fitnessDetail(for: route, interactive: interactive)
        case .tax:
            TaxDocumentsView()
        case .settings:
            settingsDetail()
        default:
            LifeOSModuleLandingView(
                module: route.module,
                route: route.route,
                usesVisualFixtures: usesVisualFixtures
            )
        }
    }

    private func homeDetail(for route: LifeOSMacRouteState, interactive: Bool) -> some View {
        let mountGeneration = route.mountGeneration
        let pathBinding = Binding<[LifeOSHomeDestination]>(
            get: { routeState.homePath },
            set: { path in
                guard interactive else { return }
                applyRoute(.setHomePath(path, expectedMountGeneration: mountGeneration))
            }
        )

        return NavigationStack(path: pathBinding) {
            overviewDetail(for: route, interactive: interactive)
                .navigationDestination(for: LifeOSHomeDestination.self) { destination in
                    homeDestination(destination, interactive: interactive)
                }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
    }

    @ViewBuilder
    private func homeDestination(_ destination: LifeOSHomeDestination, interactive: Bool) -> some View {
        switch destination {
        case .usage:
            usageDetail(interactive: interactive)
        case .clipper:
            ClipperAnalyticsView(
                section: currentClipperSection,
                snapshot: currentOverviewSnapshot.clipperSnapshot,
                refreshAction: usesVisualFixtures ? nil : { await clipperCoordinator.refresh() },
                clipperState: usesVisualFixtures ? .demo : clipperCoordinator.state
            )
        case .financeWealth:
            OverviewFinanceWealthDetail(
                financeSummary: usesVisualFixtures ? nil : financeCoordinator.summary
            )
        }
    }

    private var currentOverviewSnapshot: OverviewSnapshot {
        usesVisualFixtures
            ? DemoDataProvider.overview
            : OverviewSnapshot.production(clipper: clipperCoordinator.snapshot)
    }

    private var currentClipperSection: OverviewSection {
        currentOverviewSnapshot.sections.first(where: { $0.kind == .clipper })
            ?? OverviewSnapshot.unavailable().sections.first(where: { $0.kind == .clipper })!
    }

    private func usageDetail(interactive: Bool) -> some View {
        let usagePacket = usageCoordinator.presentationPacket
        return UsageView(
            snapshots: usesVisualFixtures ? DemoDataProvider.providers : usagePacket.providers,
            analytics: usesVisualFixtures ? DemoUsageAnalytics.snapshots : usagePacket.analytics,
            state: usesVisualFixtures ? .demo : usagePacket.loadState,
            refreshAction: usesVisualFixtures ? nil : { await usageCoordinator.refresh() },
            onBack: interactive ? { backHome() } : nil,
            onOpenSettings: interactive ? { navigate(to: .settings) } : nil,
            presentationPacket: usesVisualFixtures ? nil : usagePacket
        )
    }

    private func overviewDetail(for route: LifeOSMacRouteState, interactive: Bool) -> some View {
        let usagePacket = usageCoordinator.presentationPacket
        let overviewSnapshot: OverviewSnapshot = usesVisualFixtures
            ? DemoDataProvider.overview
            : OverviewSnapshot.production(clipper: clipperCoordinator.snapshot)
        let usageSnapshots: [ProviderSnapshot] = usesVisualFixtures
            ? DemoDataProvider.providers
            : usagePacket.providers
        let usageAnalytics: [UsageAnalyticsSnapshot] = usesVisualFixtures
            ? DemoUsageAnalytics.snapshots
            : usagePacket.analytics
        let usageState: UsageLoadState = usesVisualFixtures ? .demo : usagePacket.loadState
        let clipperState: ClipperLoadState = usesVisualFixtures ? .demo : clipperCoordinator.state
        let financeSummary: FinanceSummary? = usesVisualFixtures ? nil : financeCoordinator.summary
        let financeState: FinanceLoadState = usesVisualFixtures ? .demo : financeCoordinator.state
        let refreshAction: (() async -> Void)? = usesVisualFixtures ? nil : {
            await calendarCoordinator.manualRefresh()
            await usageCoordinator.refresh()
            await financeCoordinator.refresh()
            await clipperCoordinator.refresh()
        }
        let clipperRefreshAction: (() async -> Void)? = usesVisualFixtures ? nil : {
            await clipperCoordinator.refresh()
        }
        let destination: ((LifeOSDeepLink) -> Void)? = interactive ? { link in
            navigate(to: link)
        } : nil
        return OverviewView(
            snapshot: overviewSnapshot,
            usageSnapshots: usageSnapshots,
            usageAnalytics: usageAnalytics,
            usageState: usageState,
            refreshAction: refreshAction,
            clipperRefreshAction: clipperRefreshAction,
            clipperState: clipperState,
            financeSummary: financeSummary,
            financeState: financeState,
            openDestination: destination,
            openHomeDestination: interactive ? { destination in
                openHomeDestination(destination)
            } : nil,
            isExternallyRouted: true
        )
    }

    private func financeDetail(for route: LifeOSMacRouteState, interactive: Bool) -> some View {
        FinanceView(
            summary: financeCoordinator.summary,
            usesVisualFixtures: usesVisualFixtures,
            initialDetail: Self.financeDetailRoute(for: route.route),
            onOpenConnections: interactive ? { navigate(to: .settings) } : nil,
            onRefresh: usesVisualFixtures ? nil : { await financeCoordinator.refresh() },
            observationState: usesVisualFixtures ? .demo : financeCoordinator.observationState,
            errorMessage: usesVisualFixtures ? nil : financeCoordinator.errorMessage,
            presentationState: financePresentationState
        )
    }

    private func fitnessDetail(for route: LifeOSMacRouteState, interactive: Bool) -> some View {
        FitnessView(
            snapshot: usesVisualFixtures ? .demo : .unavailable,
            snapshotProvider: usesVisualFixtures ? nil : { date in
                fitnessObservation?.snapshot(for: date) ?? .unavailable
            },
            initialSection: route.route?.fitnessSection,
            initialNutritionEntryPoint: route.route?.nutritionEntryPoint,
            initialFitnessEntryPoint: route.route?.fitnessEntryPoint,
            usesVisualFixtures: usesVisualFixtures,
            onSourceReview: interactive ? { navigate(to: .settings) } : nil,
            trainingCoordinator: fitnessTrainingCoordinator,
            presentationState: fitnessPresentationState
        )
    }

    private func settingsDetail() -> some View {
        NavigationStack {
            SettingsView(
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                clipperCoordinator: clipperCoordinator,
                usesVisualFixtures: usesVisualFixtures
            )
        }
    }

    private func sidebarButton(_ module: LifeOSModule, collapsed: Bool) -> some View {
        let selected = routeState.module == module
        let hovered = hoveredSidebarModule == module
        return Button {
            select(module)
        } label: {
            ZStack(alignment: .leading) {
                HStack(spacing: 10) {
                    LifeOSIcon(module.icon, context: .navigation)
                    if !collapsed {
                        Text(module.title)
                            .lifeOSTypography(.label, weight: selected ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                if selected {
                    Capsule(style: .continuous)
                        .fill(LifeOSTokens.accent)
                        .frame(width: 2, height: 18)
                }
            }
            .foregroundStyle(selected ? LifeOSTokens.selectedNavigationText : LifeOSTokens.secondaryText)
            .padding(.horizontal, collapsed ? 0 : 10)
            .frame(height: 34)
            .background(
                selected ? LifeOSTokens.selectedNavigationFill : (hovered ? LifeOSTokens.raised : .clear),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredSidebarModule = isHovered ? module : (hoveredSidebarModule == module ? nil : hoveredSidebarModule)
        }
        .animation(
            LifeOSMotion.curve(for: .hover, reduceMotion: reduceMotion)?.animation,
            value: hovered
        )
        .accessibilityLabel(module.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("mac-sidebar-\(module.rawValue)")
    }

    private var isHomeDetail: Bool {
        routeState.module == .home
            && !routeState.homePath.isEmpty
            && !routeState.showingDestinationUnavailable
    }

    private static func financeDetailRoute(for route: LifeOSDeepLink?) -> FinanceDetailRoute? {
        switch route {
        case .financeSpend: .spend
        case .financeCashFlow: .cashFlow
        default: nil
        }
    }

    private func reportSceneState() {
        onSceneStateChange?(LifeOSMacSceneState(
            module: routeState.module,
            route: routeState.route,
            showingUsage: routeState.showingUsage,
            sidebarCollapsed: sidebarCollapsed,
            sidebarWidth: sidebarWidth
        ))
    }

    private func restoreUnavailableOrigin() {
        applyRoute(.restoreUnavailableOrigin)
    }

    private func select(_ module: LifeOSModule) {
        applyRoute(.selectModule(module))
    }

    private func navigate(to destination: LifeOSDeepLink) {
        applyRoute(.navigate(destination))
    }

    private func openHomeDestination(_ destination: LifeOSHomeDestination) {
        applyRoute(.openHomeDestination(destination))
    }

    private func backHome() {
        applyRoute(.backHome)
    }

    @discardableResult
    private func consumeCalendarEvent(id: UUID, expectedMountGeneration: UInt64) -> Bool {
        var next = routeState
        let reduction = LifeOSMacRouteReducer.reduce(
            &next,
            action: .consumeCalendarEvent(id: id, expectedMountGeneration: expectedMountGeneration)
        )
        guard reduction.didChange else { return false }
        LifeOSMotion.withoutAnimation {
            routeState = next
        }
        return true
    }

    private func isCalendarMountActive(
        expectedMountGeneration: UInt64,
        expectedMountedIdentity: String
    ) -> Bool {
        routeState.module == .calendar
            && !routeState.showingDestinationUnavailable
            && routeState.mountGeneration == expectedMountGeneration
            && routeState.mountedIdentity == expectedMountedIdentity
    }

    private func applyRoute(_ action: LifeOSMacRouteAction) {
        var next = routeState
        let reduction = LifeOSMacRouteReducer.reduce(&next, action: action)
        guard reduction.didChange else { return }

        let update = {
            self.routeState = next
        }
        let homePathChanged = routeState.module == .home
            && next.module == .home
            && routeState.homePath != next.homePath
        if reduction.mountChanged || homePathChanged {
            withAnimation(LifeOSMotion.curve(for: .navigation, reduceMotion: reduceMotion)?.animation, update)
        } else {
            LifeOSMotion.withoutAnimation(update)
        }
        if reduction.routeChanged {
            recordModuleRouteIntent(next.route)
        }
    }

    private static func financeRoute(for destination: LifeOSDeepLink?) -> FinanceDetailRoute? {
        switch destination {
        case .financeSpend: .spend
        case .financeCashFlow: .cashFlow
        default: nil
        }
    }

    private func recordModuleRouteIntent(_ destination: LifeOSDeepLink?) {
        financePresentationState.receiveExternalRoute(Self.financeRoute(for: destination))
        fitnessPresentationState.receiveExternalRoute(
            destination?.module == .fitness ? destination : nil
        )
    }
}

private struct LifeOSMacCommandPalette: View {
    let onSelect: (LifeOSModule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var modules: [LifeOSModule] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return LifeOSModule.macPrimaryModules }
        return LifeOSModule.macPrimaryModules.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.subtitle.localizedCaseInsensitiveContains(normalized)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Command palette")
                    .lifeOSTypography(.sectionTitle, weight: .bold)
                Spacer()
                Text("ESC")
                    .lifeOSTypography(.body, weight: .semibold)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            TextField("Jump to a module…", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Command palette search")
                .accessibilityIdentifier("mac-command-palette-search")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(modules) { module in
                        Button {
                            onSelect(module)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                LifeOSIcon(module.icon)
                                    .foregroundStyle(module.accent)
                                    .frame(width: 17, height: 17)
                                Text(module.title)
                                    .lifeOSTypography(.label)
                                Spacer()
                                if !module.hasWorkingView {
                                    Text("Not connected")
                                        .lifeOSTypography(.metadata)
                                        .foregroundStyle(LifeOSTokens.tertiaryText)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(module.title)
                        .accessibilityIdentifier("command-palette-\(module.rawValue)")
                    }
                }
            }
        }
        .padding(20)
        .background(LifeOSTokens.screenCanvas)
    }
}
