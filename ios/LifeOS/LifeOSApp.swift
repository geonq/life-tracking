import SwiftUI

#if os(iOS)
import UIKit
#endif

private enum LifeOSAppTab: Hashable, CaseIterable {
    case home, calendar, finance, fitness, more

    var identifier: String {
        switch self {
        case .home: "home"
        case .calendar: "calendar"
        case .finance: "finance"
        case .fitness: "fitness"
        case .more: "more"
        }
    }

    /// Keep the compact nav on SF Symbols so each selected state has a genuine
    /// outline/filled pair, while the rest of the app continues to use LifeOSIcon.
    var outlineSymbol: String {
        switch self {
        case .home: "house"
        case .calendar: "calendar"
        case .finance: "creditcard"
        case .fitness: "figure.run"
        case .more: "ellipsis.circle"
        }
    }

    var filledSymbol: String {
        switch self {
        case .home: "house.fill"
        case .calendar: "calendar.circle.fill"
        case .finance: "creditcard.fill"
        case .fitness: "figure.run.circle.fill"
        case .more: "ellipsis.circle.fill"
        }
    }
}

@main
struct LifeOSApp: App {
    private static let healthReadPromptCompletedKey = "LifeOS.HealthKit.ReadPromptCompleted.v1"
    @StateObject private var calendarCoordinator: CalendarCoordinator
    @StateObject private var usageCoordinator: UsageCoordinator
    @StateObject private var financeCoordinator: FinanceCoordinator
    @StateObject private var clipperCoordinator: ClipperCoordinator
    @StateObject private var healthKitController: HealthKitIntegrationController
#if os(iOS)
    @StateObject private var healthKitFitnessRepository: HealthKitFitnessRepository
    @State private var homeFitnessSnapshot: FitnessSnapshot
#endif
    @State private var selection: LifeOSAppTab = .home
    @State private var showingUsage = false
    @State private var requestingNewCalendarEvent = false
    @State private var selectedModuleRoute: LifeOSDeepLink?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let usesVisualFixtures: Bool
    /// Coalescing state for the future-module widget snapshot publisher.
    /// `@State` so the struct's `lastPublished` dedupe value survives across
    /// the several call sites below without becoming a stored class.
    @State private var widgetSnapshotPublisher = WidgetSnapshotPublisher()

    init() {
        let enabled = ProcessInfo.processInfo.arguments.contains("-LifeOSVisualFixtures")
        usesVisualFixtures = enabled
#if os(iOS)
        if !enabled {
            // UserNotifications keeps only a weak delegate reference.  The
            // shared installer retains the production durable delegate and
            // makes action delivery valid after background/terminated launch.
            SupplementNotificationDelegate.install()
        }
#endif
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
        let promptCompleted = !enabled && UserDefaults.standard.bool(forKey: Self.healthReadPromptCompletedKey)
#if os(iOS)
        let healthKitClient: HealthKitProductionClient? = enabled ? nil : HealthKitProductionClient()
        let healthKitController = HealthKitIntegrationController(
            client: healthKitClient,
            usesVisualFixtures: enabled,
            initialExplicitRequestCompleted: promptCompleted
        )
        _healthKitController = StateObject(wrappedValue: healthKitController)
        _healthKitFitnessRepository = StateObject(wrappedValue: HealthKitFitnessRepository(
            client: healthKitClient,
            usesVisualFixtures: enabled
        ))
        _homeFitnessSnapshot = State(initialValue: enabled ? .demo : .unavailable)
        healthKitController.applicationLaunched()
#endif
    }

    private var forcedColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-LifeOSForceDarkMode") { return .dark }
        if arguments.contains("-LifeOSForceLightMode") { return .light }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    switch selection {
                    case .home:
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
                            fitnessSnapshot: usesVisualFixtures ? .demo : homeFitnessSnapshot,
                            financeSummary: usesVisualFixtures ? nil : financeCoordinator.summary,
                            financeState: usesVisualFixtures ? .demo : financeCoordinator.state,
                            openDestination: navigate,
                            showingUsage: $showingUsage
                        )
                    case .calendar:
                        CalendarView(coordinator: calendarCoordinator, requestNewEvent: $requestingNewCalendarEvent)
                    case .finance:
                        FinanceView(
                            summary: financeCoordinator.summary,
                            usesVisualFixtures: usesVisualFixtures,
                            initialDetail: financeDetailRoute
                        )
                    case .fitness:
                        FitnessView(
                            snapshot: usesVisualFixtures ? .demo : .unavailable,
                            snapshotProvider: fitnessSnapshotProvider,
                            initialSection: selectedModuleRoute?.fitnessSection ?? .today,
                            initialNutritionEntryPoint: selectedModuleRoute?.nutritionEntryPoint,
                            initialFitnessEntryPoint: selectedModuleRoute?.fitnessEntryPoint,
                            usesVisualFixtures: usesVisualFixtures,
                            onSourceReview: { navigate(.settings) }
                        )
                    case .more:
                        LifeOSMoreModulesView(
                            initialModule: secondaryModuleRoute,
                            initialRoute: selectedModuleRoute,
                            usesVisualFixtures: usesVisualFixtures,
                            destinationForModule: moreDestination
                        )
                    }
                }
                // Only route content participates in the tab transition. The
                // bar remains a single stable sibling, so an animated route
                // change cannot briefly install two bars or move its inset.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(selection)
                .transition(reduceMotion ? .opacity : tabContentTransition)
                .animation(reduceMotion ? nil : LifeOSMotion.primary, value: selection)

                if !showingUsage {
                    CompactTabBar(selection: $selection) { tab in
                        updateTabDirection(for: tab)
                        // A manual tab change starts a fresh top-level route.
                        // Deep links supply their own route context immediately
                        // before changing selection, so they do not pass here.
                        selectedModuleRoute = nil
                        showingUsage = false
                        requestingNewCalendarEvent = false
                    }
                    .background {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .tint(LifeOSTokens.accent)
            .preferredColorScheme(forcedColorScheme)
            .animation(reduceMotion ? nil : LifeOSMotion.ease, value: calendarCoordinator.snapshot.items.count)
            .onOpenURL { url in
                guard let destination = LifeOSDeepLink(url: url) else {
                    selectTab(.home)
                    selectedModuleRoute = nil
                    showingUsage = false
                    return
                }
                navigate(destination)
            }
            .task {
                if !usesVisualFixtures {
                    await calendarCoordinator.load()
                    calendarCoordinator.startSync()
                    await usageCoordinator.refresh()
                    await financeCoordinator.refresh()
                    await clipperCoordinator.refresh()
                    await healthKitFitnessRepository.refresh()
                    publishWidgetSnapshots()
                }
            }
            .onAppear {
                if scenePhase == .active { healthKitController.appActive() }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    healthKitController.appActive()
                    Task { @MainActor in
                        await healthKitController.refreshStatus()
                        await healthKitFitnessRepository.refresh()
                        publishWidgetSnapshots()
                    }
                case .inactive:
                    healthKitController.appInactive()
                case .background:
                    healthKitController.applicationDidEnterBackground()
                @unknown default:
                    healthKitController.applicationDidEnterBackground()
                }
            }
#if os(iOS)
            .onChange(of: healthKitFitnessRepository.projection, initial: true) { _, projection in
                updateHomeFitnessSnapshot(from: projection)
                publishWidgetSnapshots()
            }
            .onChange(of: healthKitController.snapshot.observerCompletionSequence) { _, _ in
                guard !usesVisualFixtures else { return }
                Task { @MainActor in
                    await healthKitFitnessRepository.refresh()
                    publishWidgetSnapshots()
                }
            }
#endif
            .onChange(of: financeCoordinator.summary) { _, _ in
                publishWidgetSnapshots()
            }
            .onChange(of: financeCoordinator.state) { _, _ in
                publishWidgetSnapshots()
            }
        }
    }

    /// Maps confirmed Finance/Fitness/Nutrition state into a
    /// `FutureWidgetSnapshot` and requests a coalesced widget reload. This is
    /// the single gate that decides whether real data may reach the widget
    /// store at all: it is a no-op whenever `usesVisualFixtures` is true, so
    /// a demo/fixture launch can never publish through this path (the
    /// `-LifeOSVisualFixtures` widget preview path, if any, is entirely
    /// separate from this production publisher). It is also a no-op when no
    /// App Group container is configured, mirroring
    /// `CalendarCoordinator.sharedStorageAvailable`'s existing gate, so a
    /// build without a provisioned App Group does not do wasted work on
    /// every state change.
    private func publishWidgetSnapshots() {
        guard !usesVisualFixtures,
              FutureWidgetSnapshotStore.url() != nil else { return }

        let financeSummary = financeCoordinator.summary
        let financeState = financeCoordinator.state
#if os(iOS)
        let fitnessProjection = healthKitFitnessRepository.projection
#endif
        let now = Date.now
        // Capture the `@State` binding's setter, not `self`, so the write
        // back on MainActor updates the live coalescing state regardless of
        // which struct copy this detached task was spawned from.
        let publisherBinding = $widgetSnapshotPublisher

        Task.detached(priority: .utility) { [widgetSnapshotPublisher] in
            var publisher = widgetSnapshotPublisher
            let finance = WidgetSnapshotPublisher.mapFinance(summary: financeSummary, state: financeState, now: now)
#if os(iOS)
            let fitness = WidgetSnapshotPublisher.mapFitness(projection: fitnessProjection, now: now)
            let fitnessWidgets = WidgetSnapshotPublisher.mapFitnessWidgets(
                projection: fitnessProjection,
                selectedDate: now,
                now: now
            )
#else
            let fitness = WidgetSnapshotPublisher.mapFitness(now: now)
            let fitnessWidgets = WidgetSnapshotPublisher.mapFitnessWidgets(now: now)
#endif
            let nutrition: WidgetSafeNutritionSummary
            if let mealStore = try? NutritionMealStore(), let goalStore = try? NutritionGoalStore() {
                nutrition = WidgetSnapshotPublisher.mapNutrition(mealStore: mealStore, goalStore: goalStore, on: now, calendar: .current)
            } else {
                nutrition = .unavailable()
            }

            publisher.publish(
                finance: finance,
                fitness: fitness,
                fitnessWidgets: fitnessWidgets,
                nutrition: nutrition,
                privacyMode: .summaryAllowed,
                now: now
            )
            await MainActor.run {
                publisherBinding.wrappedValue = publisher
            }
        }
    }

#if os(iOS)
    private func updateHomeFitnessSnapshot(from projection: HealthKitFitnessProjection?) {
        guard !usesVisualFixtures else {
            homeFitnessSnapshot = .demo
            return
        }
        guard let projection else {
            homeFitnessSnapshot = .unavailable
            return
        }
        homeFitnessSnapshot = HealthKitFitnessComposition.snapshot(from: projection, selectedDate: .now)
    }

    private var fitnessSnapshotProvider: ((Date) -> FitnessSnapshot)? {
        guard !usesVisualFixtures else { return nil }
        let repository = healthKitFitnessRepository
        return { date in
            guard let projection = repository.projection else { return .unavailable }
            return HealthKitFitnessComposition.snapshot(from: projection, selectedDate: date)
        }
    }

    private var retainedHealthDataSettings: RetainedHealthDataSettings {
        guard !usesVisualFixtures,
              let projection = healthKitFitnessRepository.projection else { return .unavailable }
        return RetainedHealthDataSettings.from(projection: projection)
    }
#endif

    private var tabContentTransition: AnyTransition {
        let offset = CGFloat(tabTransitionDirection * 18)
        return AnyTransition.asymmetric(
            insertion: .offset(x: offset).combined(with: .opacity),
            removal: .opacity
        )
    }

    @State private var tabTransitionDirection = 1

    private func updateTabDirection(for tab: LifeOSAppTab) {
        guard tab != selection else { return }
        let oldIndex = LifeOSAppTab.allCases.firstIndex(of: selection) ?? 0
        let newIndex = LifeOSAppTab.allCases.firstIndex(of: tab) ?? oldIndex
        tabTransitionDirection = newIndex >= oldIndex ? 1 : -1
    }

    private func navigate(_ destination: LifeOSDeepLink) {
        selectedModuleRoute = destination
        switch destination {
        case .usage:
            selectTab(.home)
            showingUsage = true
        case .newCalendarEvent:
            showingUsage = false
            selectTab(.calendar)
            requestingNewCalendarEvent = true
        case .calendar:
            showingUsage = false
            selectTab(.calendar)
        case .finance, .financeSpend, .financeCashFlow:
            showingUsage = false
            selectTab(.finance)
        case .fitness, .fitnessNutrition, .fitnessNutritionGoals, .fitnessNutritionImport,
             .fitnessNutritionCamera, .fitnessNutritionBarcode, .fitnessNutritionAIProposal,
             .fitnessNutritionSearch, .fitnessNetEnergy, .fitnessDailyOverview,
             .fitnessStrain, .fitnessRecovery, .fitnessSleep, .fitnessRespiration,
             .fitnessHealthMonitor,
             .fitnessHeartRate, .fitnessHRV, .fitnessSpO2, .fitnessTemperature,
             .fitnessSleepDuration, .fitnessStress, .fitnessEnergyReserve:
            showingUsage = false
            selectTab(.fitness)
        case .tasks:
            showingUsage = false
            // Tasks has no standalone product surface yet; keep old links
            // useful by landing on the calendar where time-based work lives.
            selectTab(.calendar)
        case .tax, .settings:
            // More remains the only iOS entry point for secondary modules.
            // Their existing views are pushed by `moreDestination`.
            showingUsage = false
            selectTab(.more)
        }
    }

    private func selectTab(_ tab: LifeOSAppTab) {
        updateTabDirection(for: tab)
        selection = tab
    }

    private var secondaryModuleRoute: LifeOSModule? {
        switch selectedModuleRoute?.module {
        case .tax, .settings: selectedModuleRoute?.module
        default: nil
        }
    }

    private var financeDetailRoute: FinanceDetailRoute? {
        switch selectedModuleRoute {
        case .financeSpend: .spend
        case .financeCashFlow: .cashFlow
        default: nil
        }
    }

    private func moreDestination(_ module: LifeOSModule, route: LifeOSDeepLink?) -> AnyView {
        switch module {
        case .aiUsage:
            return AnyView(
                UsageView(
                    snapshots: usesVisualFixtures ? DemoDataProvider.providers : usageCoordinator.providers,
                    analytics: usesVisualFixtures ? DemoUsageAnalytics.snapshots : usageCoordinator.analytics,
                    state: usesVisualFixtures ? .demo : usageCoordinator.state,
                    refreshAction: usesVisualFixtures ? nil : { await usageCoordinator.refresh() }
                )
            )
        case .tax:
            return AnyView(TaxDocumentsView())
        case .settings:
#if os(iOS)
            return AnyView(HealthKitSettingsDestination(
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                healthKitController: healthKitController,
                healthKitFitnessRepository: healthKitFitnessRepository,
                requestHealthReadAccess: usesVisualFixtures ? nil : requestHealthReadAccess
            ))
#else
            return AnyView(SettingsView(
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                healthReadAccess: healthReadAccessSettings,
                requestHealthReadAccess: usesVisualFixtures ? nil : requestHealthReadAccess,
                retainedHealthData: retainedHealthDataSettings
            ))
#endif
        default:
            return AnyView(LifeOSModuleLandingView(
                module: module,
                route: route,
                usesVisualFixtures: usesVisualFixtures
            ))
        }
    }

    private var healthReadAccessSettings: HealthReadAccessSettings {
        HealthReadAccessSettings.from(snapshot: healthKitController.snapshot)
    }

    @MainActor
    private func requestHealthReadAccess() async {
        let report = await healthKitController.requestReadAuthorization()
        if report.promptCompleted == true {
            UserDefaults.standard.set(true, forKey: Self.healthReadPromptCompletedKey)
        }
    }
}

#if os(iOS)
/// Settings is pushed by the More navigation stack while HealthKit startup is
/// still asynchronous. Observing the controller and repository here prevents
/// a destination opened during that window from retaining the initial
/// `.unavailable` value after reconciliation has published durable state.
private struct HealthKitSettingsDestination: View {
    @ObservedObject private var usageCoordinator: UsageCoordinator
    @ObservedObject private var financeCoordinator: FinanceCoordinator
    @ObservedObject private var healthKitController: HealthKitIntegrationController
    @ObservedObject private var healthKitFitnessRepository: HealthKitFitnessRepository
    private let requestHealthReadAccess: (@MainActor () async -> Void)?

    init(
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator,
        healthKitController: HealthKitIntegrationController,
        healthKitFitnessRepository: HealthKitFitnessRepository,
        requestHealthReadAccess: (@MainActor () async -> Void)?
    ) {
        _usageCoordinator = ObservedObject(wrappedValue: usageCoordinator)
        _financeCoordinator = ObservedObject(wrappedValue: financeCoordinator)
        _healthKitController = ObservedObject(wrappedValue: healthKitController)
        _healthKitFitnessRepository = ObservedObject(wrappedValue: healthKitFitnessRepository)
        self.requestHealthReadAccess = requestHealthReadAccess
    }

    var body: some View {
        SettingsView(
            usageCoordinator: usageCoordinator,
            financeCoordinator: financeCoordinator,
            healthReadAccess: HealthReadAccessSettings.from(snapshot: healthKitController.snapshot),
            requestHealthReadAccess: requestHealthReadAccess,
            retainedHealthData: retainedHealthData,
            healthKitController: healthKitController,
            healthKitFitnessRepository: healthKitFitnessRepository
        )
    }

    private var retainedHealthData: RetainedHealthDataSettings {
        guard let projection = healthKitFitnessRepository.projection else { return .unavailable }
        return .from(projection: projection)
    }
}
#endif

private struct CompactTabBar: View {
    @Binding var selection: LifeOSAppTab
    private let onSelect: (LifeOSAppTab) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<LifeOSAppTab>, onSelect: @escaping (LifeOSAppTab) -> Void = { _ in }) {
        _selection = selection
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 0) {
            item(.home, title: "Home")
            item(.calendar, title: "Calendar")
            item(.finance, title: "Finance")
            item(.fitness, title: "Fitness")
            item(.more, title: "More")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LifeOSTokens.hairlineBorder)
                .frame(height: 0.5)
        }
        // Do not assign an identifier to this containing HStack. SwiftUI
        // propagates a container identifier to its button descendants on iOS,
        // which erases the unique `main-tab-*` identifiers below and makes the
        // five tabs ambiguous to Voice Control and UI automation.
    }

    private func item(_ tab: LifeOSAppTab, title: String) -> some View {
        CompactTabBarItem(
            tab: tab,
            title: title,
            isSelected: selection == tab,
            reduceMotion: reduceMotion,
            namespace: namespace
        ) {
            guard selection != tab else { return }

#if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif

            if reduceMotion {
                onSelect(tab)
                selection = tab
            } else {
                withAnimation(LifeOSMotion.snappy) {
                    onSelect(tab)
                    selection = tab
                }
            }
        }
    }

    @Namespace private var namespace
}

private struct CompactTabBarItem: View {
    let tab: LifeOSAppTab
    let title: String
    let isSelected: Bool
    let reduceMotion: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isPulsing = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: isSelected ? tab.filledSymbol : tab.outlineSymbol)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .symbolRenderingMode(.hierarchical)
                    .modifier(CompactTabSymbolTransition(enabled: !reduceMotion))
                    .scaleEffect(isPulsing ? 0.78 : 1)
                    .frame(width: 20, height: 19)
                Text(title)
                    .font(LifeOSFont.inter(9.5, weight: isSelected ? .semiBold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? LifeOSTokens.accent : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    let indicator = Capsule()
                        .fill(LifeOSTokens.surface)
                        .overlay(Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
                    if reduceMotion {
                        indicator
                    } else {
                        indicator.matchedGeometryEffect(id: "main-tab-indicator", in: namespace)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("main-tab-\(tab.identifier)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "Selected" : "")
        .onChange(of: isSelected) { _, selected in
            guard selected, !reduceMotion else {
                isPulsing = false
                return
            }
            // Set the compressed state immediately, then let the snappy token
            // settle it back to rest for a restrained Instagram-like tap cue.
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                isPulsing = true
            }
            withAnimation(LifeOSMotion.snappy) {
                isPulsing = false
            }
        }
    }
}

private struct CompactTabSymbolTransition: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}
