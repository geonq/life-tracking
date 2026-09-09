import SwiftUI

@main
struct LifeOSMacApp: App {
    @StateObject private var calendarCoordinator: CalendarCoordinator
    @StateObject private var usageCoordinator: UsageCoordinator
    @StateObject private var financeCoordinator: FinanceCoordinator
    @StateObject private var clipperCoordinator: ClipperCoordinator
    @StateObject private var fitnessTrainingCoordinator: FitnessTrainingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let usesVisualFixtures: Bool
    /// Coalescing state for the future-module widget snapshot publisher.
    /// Mac has no HealthKit, so only Finance/Nutrition are mapped; Fitness
    /// stays permanently unavailable via `WidgetSnapshotPublisher`'s
    /// non-iOS mapping functions. `WidgetSnapshotPublisher` is an actor, so
    /// a plain `let` keeps one durable instance alive across the call sites
    /// below — its own mailbox serializes concurrent `publish` calls.
    private let widgetSnapshotPublisher = WidgetSnapshotPublisher()

    init() {
        let enabled = Self.visualFixturesEnabled
        usesVisualFixtures = enabled
        let cachedUsage = enabled ? nil : SharedSnapshotStore.read()
        _usageCoordinator = StateObject(wrappedValue: UsageCoordinator(
            initialProviders: cachedUsage?.providers ?? [],
            initialUpdatedAt: cachedUsage?.updatedAt
        ))
        _financeCoordinator = StateObject(wrappedValue: FinanceCoordinator(
            initialState: enabled ? .demo : .unavailable
        ))
        _clipperCoordinator = StateObject(wrappedValue: ClipperCoordinator(
            initialState: enabled ? .demo : .unavailable
        ))
        _calendarCoordinator = StateObject(
            wrappedValue: CalendarCoordinator(
                initialSnapshot: enabled ? CalendarVisualFixtures.snapshot() : CalendarSnapshot(),
                usesVisualFixtures: enabled
            )
        )
        _fitnessTrainingCoordinator = StateObject(wrappedValue: FitnessTrainingCoordinator())
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
            LifeOSMacRootView(
                calendarCoordinator: calendarCoordinator,
                usesVisualFixtures: usesVisualFixtures,
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                clipperCoordinator: clipperCoordinator,
                fitnessTrainingCoordinator: fitnessTrainingCoordinator
            )
                .frame(minWidth: 900, minHeight: 640)
                .tint(LifeOSTokens.accent)
                .animation(reduceMotion ? nil : LifeOSMotion.ease,
                           value: calendarCoordinator.snapshot.items.count)
                .task {
                    if !usesVisualFixtures {
                        await calendarCoordinator.load()
                        calendarCoordinator.startSync()
                        await usageCoordinator.refresh()
                        await financeCoordinator.refresh()
                        await clipperCoordinator.refresh()
                        publishWidgetSnapshots()
                    }
                }
                .onChange(of: financeCoordinator.summary) { _, _ in
                    publishWidgetSnapshots()
                }
                .onChange(of: financeCoordinator.state) { _, _ in
                    publishWidgetSnapshots()
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1512, height: 982)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task {
                        await calendarCoordinator.manualRefresh()
                        await usageCoordinator.refresh()
                        await financeCoordinator.refresh()
                        await clipperCoordinator.refresh()
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
                clipperCoordinator: clipperCoordinator
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
    @State private var selection: LifeOSModule
    @State private var selectedRoute: LifeOSDeepLink?
    @State private var showingUsage: Bool
    @State private var requestingNewCalendarEvent = false
    @State private var sidebarCollapsed = false
    @State private var hoveredSidebarModule: LifeOSModule?
    @State private var showingCommandPalette = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor
    init(
        calendarCoordinator: CalendarCoordinator,
        usesVisualFixtures: Bool = false,
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator? = nil,
        clipperCoordinator: ClipperCoordinator? = nil,
        fitnessTrainingCoordinator: FitnessTrainingCoordinator? = nil,
        initialModule: LifeOSModule = .home,
        initialRoute: LifeOSDeepLink? = nil,
        initiallyShowingUsage: Bool = false
    ) {
        self.calendarCoordinator = calendarCoordinator
        self.usesVisualFixtures = usesVisualFixtures
        self.usageCoordinator = usageCoordinator
        self.financeCoordinator = financeCoordinator ?? FinanceCoordinator(initialState: .demo)
        self.clipperCoordinator = clipperCoordinator ?? ClipperCoordinator(initialState: usesVisualFixtures ? .demo : .unavailable)
        self.fitnessTrainingCoordinator = fitnessTrainingCoordinator ?? FitnessTrainingCoordinator()
        _selection = State(initialValue: initialModule)
        _selectedRoute = State(initialValue: initialRoute)
        _showingUsage = State(initialValue: initiallyShowingUsage || initialRoute == .usage)
    }

    private func rootLayout(isCompact: Bool) -> some View {
        HStack(spacing: 0) {
            sidebar(isCompact: isCompact)
            Rectangle()
                .fill(LifeOSTokens.hairlineBorder)
                .frame(width: 1)
            VStack(spacing: 0) {
                topBar
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
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LifeOSTokens.screenCanvas)
        .animation(reduceMotion ? nil : LifeOSMotion.easeNavigate, value: selection)
        .sheet(isPresented: $showingCommandPalette) {
            LifeOSMacCommandPalette(selection: $selection, selectedRoute: $selectedRoute)
                .frame(width: 560, height: 420)
        }
    }

    private var layoutWithResponsiveSidebar: some View {
        GeometryReader { proxy in
            rootLayout(isCompact: proxy.size.width < 900)
        }
    }

    private func sidebar(isCompact: Bool) -> some View {
        let collapsed = sidebarCollapsed || isCompact
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LifeOSIcon(.home)
                    .foregroundStyle(LifeOSTokens.accent)
                    .frame(width: 18, height: 18)
                if !collapsed {
                    Text("LIFE OS")
                        .lifeOSTypography(.pageTitle, weight: .bold)
                        .tracking(0.8)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 0)
                if !isCompact {
                    Button {
                    withAnimation(reduceMotion ? nil : LifeOSMotion.snappy) {
                        sidebarCollapsed.toggle()
                    }
                    } label: {
                        LifeOSIcon(sidebarCollapsed ? .chevronRight : .chevronLeft)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .accessibilityLabel(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
                    .accessibilityIdentifier("mac-sidebar-collapse")
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
        .frame(width: collapsed ? 68 : 228)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(LifeOSTokens.canvas)
        .accessibilityIdentifier("mac-persistent-sidebar")
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.title)
                    .lifeOSTypography(.sectionTitle, weight: .bold)
                if let section = selectedRoute?.sectionTitle ?? (selectedRoute == .usage ? "Usage" : nil) {
                    Text(section)
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 16)

            Button { showingCommandPalette = true } label: {
                HStack(spacing: 8) {
                    LifeOSIcon(.search).frame(width: 15, height: 15)
                    Text("Search or jump").lifeOSTypography(.body)
                    Text("⌘K").lifeOSTypography(.body, weight: .semibold)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(LifeOSTokens.surface, in: Capsule())
                .overlay(Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("Open command palette")
            .accessibilityIdentifier("mac-command-palette-trigger")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(LifeOSTokens.canvas)
        .accessibilityIdentifier("mac-global-top-bar")
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            if showingUsage {
                UsageView(
                    snapshots: usesVisualFixtures ? DemoDataProvider.providers : usageCoordinator.providers,
                    analytics: usesVisualFixtures ? DemoUsageAnalytics.snapshots : usageCoordinator.analytics,
                    state: usesVisualFixtures ? .demo : usageCoordinator.state,
                    refreshAction: usesVisualFixtures ? nil : { await usageCoordinator.refresh() }
                )
                .transition(reduceMotion ? .identity : .opacity)
            } else {
                OverviewView(
                    snapshot: usesVisualFixtures
                        ? DemoDataProvider.overview
                        : OverviewSnapshot.production(clipper: clipperCoordinator.snapshot),
                    usageSnapshots: usesVisualFixtures ? DemoDataProvider.providers : usageCoordinator.providers,
                    usageAnalytics: usesVisualFixtures ? DemoUsageAnalytics.snapshots : usageCoordinator.analytics,
                    usageState: usesVisualFixtures ? .demo : usageCoordinator.state,
                    refreshAction: usesVisualFixtures ? nil : {
                        await calendarCoordinator.manualRefresh()
                        await usageCoordinator.refresh()
                        await financeCoordinator.refresh()
                        await clipperCoordinator.refresh()
                    },
                    clipperRefreshAction: usesVisualFixtures ? nil : { await clipperCoordinator.refresh() },
                    clipperState: usesVisualFixtures ? .demo : clipperCoordinator.state,
                    financeSummary: usesVisualFixtures ? nil : financeCoordinator.summary,
                    financeState: usesVisualFixtures ? .demo : financeCoordinator.state,
                    openDestination: navigate,
                    showingUsage: $showingUsage
                )
                .transition(reduceMotion ? .identity : .opacity)
            }
        case .calendar:
            CalendarView(coordinator: calendarCoordinator, requestNewEvent: $requestingNewCalendarEvent)
                .transition(reduceMotion ? .identity : .opacity)
        case .finance:
            FinanceView(
                summary: financeCoordinator.summary,
                usesVisualFixtures: usesVisualFixtures,
                initialDetail: financeDetailRoute
            )
                .transition(reduceMotion ? .identity : .opacity)
        case .fitness:
            FitnessView(
                snapshot: usesVisualFixtures ? .demo : .unavailable,
                initialSection: selectedRoute?.fitnessSection ?? .today,
                initialNutritionEntryPoint: selectedRoute?.nutritionEntryPoint,
                initialFitnessEntryPoint: selectedRoute?.fitnessEntryPoint,
                usesVisualFixtures: usesVisualFixtures,
                trainingCoordinator: fitnessTrainingCoordinator
            )
            .transition(reduceMotion ? .identity : .opacity)
        case .tax:
            TaxDocumentsView()
                .transition(reduceMotion ? .identity : .opacity)
        case .aiUsage:
            UsageView(
                snapshots: usesVisualFixtures ? DemoDataProvider.providers : usageCoordinator.providers,
                analytics: usesVisualFixtures ? DemoUsageAnalytics.snapshots : usageCoordinator.analytics,
                state: usesVisualFixtures ? .demo : usageCoordinator.state,
                refreshAction: usesVisualFixtures ? nil : { await usageCoordinator.refresh() }
            )
            .transition(reduceMotion ? .identity : .opacity)
        case .settings:
            NavigationStack {
                SettingsView(
                    usageCoordinator: usageCoordinator,
                    financeCoordinator: financeCoordinator,
                    clipperCoordinator: clipperCoordinator,
                    usesVisualFixtures: usesVisualFixtures
                )
            }
                .transition(reduceMotion ? .identity : .opacity)
        default:
            LifeOSModuleLandingView(
                module: selection,
                route: selectedRoute,
                usesVisualFixtures: usesVisualFixtures
            )
            .transition(reduceMotion ? .identity : .opacity)
        }
    }

    private func sidebarButton(_ module: LifeOSModule, collapsed: Bool) -> some View {
        let selected = selection == module
        let hovered = hoveredSidebarModule == module
        return Button {
            select(module)
        } label: {
            HStack(spacing: 12) {
                Capsule(style: .continuous)
                    .fill(selected ? LifeOSTokens.accent : .clear)
                    .frame(width: 3, height: 20)
                LifeOSIcon(module.icon).frame(width: 24, height: 24)
                if !collapsed {
                    Text(module.title)
                        .lifeOSTypography(.body, weight: selected ? .semibold : .regular)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(selected ? LifeOSTokens.selectedNavigationText : LifeOSTokens.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                selected ? LifeOSTokens.selectedNavigationFill : (hovered ? LifeOSTokens.raised : .clear),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
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

    private var financeDetailRoute: FinanceDetailRoute? {
        switch selectedRoute {
        case .financeSpend: .spend
        case .financeCashFlow: .cashFlow
        default: nil
        }
    }

    private func select(_ module: LifeOSModule) {
        selectedRoute = nil
        showingUsage = false
        requestingNewCalendarEvent = false
        selection = module
    }

    private func navigate(to destination: LifeOSDeepLink) {
        selectedRoute = destination
        switch destination {
        case .usage:
            selection = .home
            showingUsage = true
            requestingNewCalendarEvent = false
        case .newCalendarEvent:
            selection = .calendar
            showingUsage = false
            requestingNewCalendarEvent = true
        default:
            selection = destination.module
            showingUsage = false
            requestingNewCalendarEvent = false
        }
    }
}

private struct LifeOSMacCommandPalette: View {
    @Binding var selection: LifeOSModule
    @Binding var selectedRoute: LifeOSDeepLink?
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
                            selection = module
                            selectedRoute = nil
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
