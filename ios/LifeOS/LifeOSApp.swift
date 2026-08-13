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
    @State private var selection: LifeOSAppTab = .home
    @State private var showingUsage = false
    @State private var requestingNewCalendarEvent = false
    @State private var selectedModuleRoute: LifeOSDeepLink?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let usesVisualFixtures: Bool

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
        _healthKitController = StateObject(wrappedValue: HealthKitIntegrationController(
            client: enabled ? nil : HealthKitProductionClient(),
            usesVisualFixtures: enabled,
            initialExplicitRequestCompleted: promptCompleted
        ))
    }

    private var forcedColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-LifeOSForceDarkMode") { return .dark }
        if arguments.contains("-LifeOSForceLightMode") { return .light }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
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
                    initialSection: selectedModuleRoute?.fitnessSection ?? .today,
                    initialNutritionEntryPoint: selectedModuleRoute?.nutritionEntryPoint,
                    initialFitnessEntryPoint: selectedModuleRoute?.fitnessEntryPoint,
                    usesVisualFixtures: usesVisualFixtures
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
            // The small offset keeps the transition directional without moving a
            // complete screen in from off-canvas like a stock push navigation.
            .id(selection)
            .transition(reduceMotion ? .opacity : tabContentTransition)
            .animation(reduceMotion ? LifeOSMotion.ease : LifeOSMotion.primary, value: selection)
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                        .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
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
                    await healthKitController.refreshStatus()
                }
            }
            .onAppear {
                if scenePhase == .active { healthKitController.appActive() }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    healthKitController.appActive()
                    Task { await healthKitController.refreshStatus() }
                case .inactive:
                    healthKitController.appInactive()
                case .background:
                    healthKitController.applicationDidEnterBackground()
                @unknown default:
                    healthKitController.applicationDidEnterBackground()
                }
            }
        }
    }

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
            return AnyView(SettingsView(
                healthReadAccess: healthReadAccessSettings,
                requestHealthReadAccess: usesVisualFixtures ? nil : requestHealthReadAccess
            ))
        default:
            return AnyView(LifeOSModuleLandingView(
                module: module,
                route: route,
                usesVisualFixtures: usesVisualFixtures
            ))
        }
    }

    private var healthReadAccessSettings: HealthReadAccessSettings {
        let snapshot = healthKitController.snapshot
        let state: HealthReadAccessSettings.State
        if snapshot.isRequestInFlight {
            state = .requestPending
        } else {
            switch snapshot.authorizationState {
            case .unavailable: state = .unavailable
            case .restricted, .revoked: state = .restricted
            case .protectedDataUnavailable: state = .protectedDataUnavailable
            case .notRequested: state = .notRequested
            case .requestRequired: state = .requestRequired
            case .requestPending: state = .requestPending
            case .readIndeterminate: state = .readIndeterminate
            case .error: state = .error
            case .writeNotDetermined, .writeAuthorized, .writeDenied:
                state = .error
            }
        }
        return HealthReadAccessSettings(state: state, errorDescription: snapshot.errorDescription)
    }

    @MainActor
    private func requestHealthReadAccess() async {
        let report = await healthKitController.requestReadAuthorization()
        if report.promptCompleted == true {
            UserDefaults.standard.set(true, forKey: Self.healthReadPromptCompletedKey)
        }
    }
}

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
