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

    init?(identifier: String) {
        switch identifier {
        case "home": self = .home
        case "calendar": self = .calendar
        case "finance": self = .finance
        case "fitness": self = .fitness
        case "more": self = .more
        default: return nil
        }
    }

    /// Keep the compact nav on one stable SF Symbol per route. Selection is
    /// expressed by weight, color, and the selected surface rather than by
    /// swapping the symbol's silhouette.
    var symbol: String {
        switch self {
        case .home: "house"
        case .calendar: "calendar"
        case .finance: "creditcard"
        case .fitness: "heart"
        case .more: "ellipsis"
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
    @StateObject private var fitnessTrainingCoordinator: FitnessTrainingCoordinator
    @StateObject private var healthKitController: HealthKitIntegrationController
#if os(iOS)
    @StateObject private var healthKitFitnessRepository: HealthKitFitnessRepository
    @State private var homeFitnessSnapshot: FitnessSnapshot
    private let fitnessObservationSyncClient: TailscaleSyncClient?
#endif
    @State private var initialLiveLoadFinished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let usesVisualFixtures: Bool
    /// Coalescing state for the future-module widget snapshot publisher.
    /// `WidgetSnapshotPublisher` is an actor, so a plain `let` is enough to
    /// keep one durable instance alive across the several call sites below —
    /// its own mailbox serializes concurrent `publish` calls, no `@State`
    /// write-back required.
    private let widgetSnapshotPublisher = WidgetSnapshotPublisher()

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
        let promptCompleted = !enabled && UserDefaults.standard.bool(forKey: Self.healthReadPromptCompletedKey)
#if os(iOS)
        self.fitnessObservationSyncClient = FitnessObservationSyncPolicy.allowsNetwork(usesVisualFixtures: enabled)
            ? TailscaleSyncClient()
            : nil
        let healthKitClient: HealthKitProductionClient? = enabled ? nil : HealthKitProductionClient()
        let healthKitController = HealthKitIntegrationController(
            client: healthKitClient,
            usesVisualFixtures: enabled,
            initialExplicitRequestCompleted: promptCompleted
        )
        _healthKitController = StateObject(wrappedValue: healthKitController)
        let healthKitFitnessRepository = HealthKitFitnessRepository(
            client: healthKitClient,
            usesVisualFixtures: enabled
        )
        _healthKitFitnessRepository = StateObject(wrappedValue: healthKitFitnessRepository)
        _homeFitnessSnapshot = State(initialValue: enabled ? .demo : .unavailable)
        LifeOSAutomationRefreshRegistry.shared.registerHealthRefresh { @MainActor in
            try Task.checkCancellation()
            let sequenceBefore = healthKitController.snapshot.observerCompletionSequence
            let snapshot = try await healthKitController.refreshAndAwait()
            try Task.checkCancellation()
            guard snapshot.authorizationState == .readIndeterminate else { return .unavailable }
            let projection = await healthKitFitnessRepository.refresh()
            try Task.checkCancellation()
            return LifeOSAutomationHealthRefreshState.evaluated(
                snapshot: snapshot,
                projection: projection,
                didCompleteRefresh: snapshot.observerCompletionSequence > sequenceBefore
            )
        }
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
            LifeOSIOSSceneRoot(
                calendarCoordinator: calendarCoordinator,
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                clipperCoordinator: clipperCoordinator,
                fitnessTrainingCoordinator: fitnessTrainingCoordinator,
                usesVisualFixtures: usesVisualFixtures,
                homeFitnessSnapshot: $homeFitnessSnapshot,
                fitnessSnapshotProvider: fitnessSnapshotProvider,
                destinationForModule: moreDestination
            )
            .frame(minWidth: 390, minHeight: 600)
            .tint(LifeOSTokens.accent)
            .preferredColorScheme(forcedColorScheme)
            .task {
                if !usesVisualFixtures {
                    await calendarCoordinator.load()
                    calendarCoordinator.startSync()
                    await usageCoordinator.refresh()
                    await financeCoordinator.refresh()
                    await clipperCoordinator.refresh()
                    await healthKitFitnessRepository.refresh()
                    await publishFitnessObservation()
                    await publishWidgetSnapshots()
#if os(iOS)
                    initialLiveLoadFinished = true
                    LifeOSBackgroundRefresh.schedule()
#endif
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
                        await refreshNetworkBackedDataAfterForeground()
#if os(iOS)
                        LifeOSBackgroundRefresh.schedule()
#endif
                    }
                case .inactive:
                    healthKitController.appInactive()
                case .background:
                    healthKitController.applicationDidEnterBackground()
#if os(iOS)
                    LifeOSBackgroundRefresh.schedule()
#endif
                @unknown default:
                    healthKitController.applicationDidEnterBackground()
#if os(iOS)
                    LifeOSBackgroundRefresh.schedule()
#endif
                }
            }
#if os(iOS)
            .onChange(of: healthKitFitnessRepository.projection, initial: true) { _, projection in
                updateHomeFitnessSnapshot(from: projection)
                Task { @MainActor in
                    await publishFitnessObservation()
                    await publishWidgetSnapshots()
                }
            }
            .onChange(of: healthKitController.snapshot) { _, _ in
                updateHomeFitnessSnapshot(from: healthKitFitnessRepository.projection)
                Task { @MainActor in
                    await publishFitnessObservation()
                    await publishWidgetSnapshots()
                }
            }
            .onChange(of: healthKitController.snapshot.observerCompletionSequence) { _, _ in
                guard !usesVisualFixtures else { return }
                Task { @MainActor in
                    await healthKitFitnessRepository.refresh()
                    await publishFitnessObservation()
                    await publishWidgetSnapshots()
                }
            }
#endif
            .onChange(of: financeCoordinator.summary) { _, _ in
                Task { @MainActor in await publishWidgetSnapshots() }
            }
            .onChange(of: financeCoordinator.state) { _, _ in
                Task { @MainActor in await publishWidgetSnapshots() }
            }
#if os(iOS)
            .environment(\.lifeOSHealthKitFitnessProjection, healthKitFitnessRepository.projection)
#endif
        }
#if os(iOS)
        .backgroundTask(.appRefresh(LifeOSBackgroundRefresh.identifier)) {
            await performBackgroundRefresh()
        }
#endif
    }

#if os(iOS)
    /// Reconcile all remote-backed projections whenever the app returns to the
    /// foreground. The initial scene task owns first load; this gate prevents
    /// an activation callback from racing that load and letting an empty local
    /// calendar overwrite a freshly pulled remote snapshot.
    @MainActor
    private func refreshNetworkBackedDataAfterForeground() async {
        guard !usesVisualFixtures, initialLiveLoadFinished else { return }

        async let calendar: Void = calendarCoordinator.manualRefresh()
        async let usage: Void = usageCoordinator.refresh()
        async let finance: Void = financeCoordinator.refresh()
        async let clipper: Void = clipperCoordinator.refresh()
        async let fitness = healthKitFitnessRepository.refresh()
        _ = await (calendar, usage, finance, clipper, fitness)
        await publishFitnessObservation()
        await publishWidgetSnapshots()
    }

    @MainActor
    private func performBackgroundRefresh() async {
        guard !usesVisualFixtures else { return }
        defer { LifeOSBackgroundRefresh.schedule() }

        // Keep the short app-refresh window useful by progressing the
        // independent network-backed coordinators together. Each coordinator
        // retains the last observed value and marks it stale on failure.
        async let calendar: Void = calendarCoordinator.manualRefresh()
        async let usage: Void = usageCoordinator.refresh()
        async let finance: Void = financeCoordinator.refresh()
        async let clipper: Void = clipperCoordinator.refresh()
        async let fitness = healthKitFitnessRepository.refresh()
        _ = await (calendar, usage, finance, clipper, fitness)
        await publishFitnessObservation()
        await publishWidgetSnapshots()
    }
#endif

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
    private func publishWidgetSnapshots() async {
        guard !usesVisualFixtures,
              FutureWidgetSnapshotStore.url() != nil else { return }

        let financeSummary = financeCoordinator.summary
        let financeState = financeCoordinator.state
#if os(iOS)
        let fitnessProjection = healthKitFitnessRepository.projection
#endif
        let now = Date.now
        let finance = WidgetSnapshotPublisher.mapFinance(summary: financeSummary, state: financeState, now: now)
#if os(iOS)
        let fitness = WidgetSnapshotPublisher.mapFitness(projection: fitnessProjection, now: now)
        let fitnessWidgets = WidgetSnapshotPublisher.mapFitnessWidgets(
            projection: fitnessProjection,
            integration: healthKitController.snapshot,
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

        await widgetSnapshotPublisher.publish(
            finance: finance,
            fitness: fitness,
            fitnessWidgets: fitnessWidgets,
            nutrition: nutrition,
            privacyMode: .summaryAllowed,
            now: now
        )
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
        homeFitnessSnapshot = HealthKitFitnessComposition.snapshot(from: projection, integration: healthKitController.snapshot, selectedDate: .now)
    }

    private var fitnessSnapshotProvider: ((Date) -> FitnessSnapshot)? {
        guard !usesVisualFixtures else { return nil }
        let repository = healthKitFitnessRepository
        let controller = healthKitController
        return { date in
            guard let projection = repository.projection else { return .unavailable }
            return HealthKitFitnessComposition.snapshot(from: projection, integration: controller.snapshot, selectedDate: date)
        }
    }

    /// Publishes only a successful, source-backed projection. The awaited
    /// request runs from an existing lifecycle task, so it never gates the
    /// HealthKit projection or the Fitness view's first render.
    private func publishFitnessObservation() async {
        guard FitnessObservationSyncPolicy.allowsNetwork(usesVisualFixtures: usesVisualFixtures),
              let client = fitnessObservationSyncClient,
              let projection = healthKitFitnessRepository.projection,
              projection.isValid,
              healthKitController.snapshot.permitsCurrentFitnessRendering,
              let observation = makeFitnessObservation(from: projection, now: .now) else { return }

        try? await client.publishFitnessObservation(observation)
    }

    /// Reduces the iPhone projection to the intentionally small cross-device
    /// contract. Every value below is copied from an observed HealthKit
    /// quantity or from the existing source-gated sleep duration helper;
    /// unsupported scores remain unavailable.
    private func makeFitnessObservation(
        from projection: HealthKitFitnessProjection,
        now: Date
    ) -> FitnessObservationEnvelope? {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }

        func isCurrent(_ date: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return date.timeIntervalSinceReferenceDate.isFinite
                && age >= 0
                && age <= FitnessObservationEnvelope.maximumCurrentMetricAge
        }

        func isHistorical(_ date: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return date.timeIntervalSinceReferenceDate.isFinite
                && age >= 0
                && age <= FitnessObservationEnvelope.maximumHistoryAge
        }

        let metricMappings: [(HealthKitMetricID, FitnessObservationMetricID)] = [
            (.heartRate, .heartRate),
            (.restingHeartRate, .restingHeartRate),
            (.heartRateVariabilitySDNN, .heartRateVariability),
            (.respiratoryRate, .respiratoryRate),
            (.oxygenSaturation, .oxygenSaturation)
        ]
        var metrics: [FitnessObservationValue] = []
        metrics.reserveCapacity(metricMappings.count)
        for (sourceMetric, targetMetric) in metricMappings {
            let projectionMetric = projection.metric(sourceMetric)
            guard projectionMetric.state == .observed,
                  let sample = projectionMetric.latest,
                  sample.state == .observed,
                  sample.quantity.metric == sourceMetric,
                  isCurrent(sample.endDate),
                  let value = try? FitnessObservationValue(
                      metric: targetMetric,
                      value: sample.quantity.value,
                      unit: targetMetric.unit,
                      observedAt: sample.endDate
                  ) else { continue }
            metrics.append(value)
        }

        var calendar = Calendar(identifier: projection.bucketCalendarIdentifier)
        calendar.timeZone = TimeZone(identifier: projection.bucketTimeZoneIdentifier) ?? .current
        var days: [FitnessObservationDay] = []
        if let sleep = HealthKitFitnessComposition.sourceDerivedSleepDurationHours(
            from: projection,
            selectedDate: now
        ), sleep.hours.isFinite, sleep.hours > 0,
           isHistorical(sleep.observedAt),
           let value = try? FitnessObservationValue(
               metric: .sleepDuration,
               value: sleep.hours * 3_600,
               unit: .seconds,
               observedAt: sleep.observedAt
           ) {
            days = [FitnessObservationDay(
                date: calendar.startOfDay(for: now),
                values: [value]
            )]
        }

        let workoutCandidates = projection.workouts.suffix(FitnessObservationEnvelope.maximumWorkouts)
        var workouts: [FitnessObservationWorkout] = []
        workouts.reserveCapacity(workoutCandidates.count)
        for workout in workoutCandidates {
            guard workout.state == .observed,
                  isHistorical(workout.startDate),
                  isHistorical(workout.endDate),
                  workout.endDate > workout.startDate,
                  workout.durationSeconds.isFinite,
                  workout.durationSeconds > 0,
                  workout.durationSeconds <= workout.endDate.timeIntervalSince(workout.startDate)
                    + FitnessObservationEnvelope.workoutDurationRoundingTolerance,
                  workout.activityTypeRawValue >= 0,
                  workout.activityTypeRawValue <= 1_000_000,
                  workout.activeEnergyKilocalories.map({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) ?? true else { continue }
            let mapped = FitnessObservationWorkout(
                activityTypeRawValue: workout.activityTypeRawValue,
                startAt: workout.startDate,
                endAt: workout.endDate,
                durationSeconds: workout.durationSeconds,
                activeEnergyKilocalories: workout.activeEnergyKilocalories
            )
            workouts.append(mapped)
        }

        let evidenceDates = metrics.map(\.observedAt)
            + days.flatMap { $0.values.map(\.observedAt) }
            + workouts.map(\.endAt)
        guard let observedAt = evidenceDates.max(),
              evidenceDates.contains(where: isCurrent) else { return nil }

        return try? FitnessObservationEnvelope(
            state: .observed,
            generatedAt: now,
            observedAt: observedAt,
            metrics: metrics,
            days: days,
            workouts: workouts
        )
    }

    private var retainedHealthDataSettings: RetainedHealthDataSettings {
        guard !usesVisualFixtures,
              let projection = healthKitFitnessRepository.projection else { return .unavailable }
        return RetainedHealthDataSettings.from(projection: projection)
    }
#endif

    private func moreDestination(_ module: LifeOSModule, route: LifeOSDeepLink?) -> AnyView {
        switch module {
        case .tax:
            return AnyView(TaxDocumentsView())
        case .settings:
#if os(iOS)
            return AnyView(HealthKitSettingsDestination(
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                clipperCoordinator: clipperCoordinator,
                healthKitController: healthKitController,
                healthKitFitnessRepository: healthKitFitnessRepository,
                requestHealthReadAccess: usesVisualFixtures ? nil : requestHealthReadAccess,
                requestHealthWriteAccess: usesVisualFixtures ? nil : requestHealthWriteAccess,
                usesVisualFixtures: usesVisualFixtures
            ))
#else
            return AnyView(SettingsView(
                usageCoordinator: usageCoordinator,
                financeCoordinator: financeCoordinator,
                clipperCoordinator: clipperCoordinator,
                healthReadAccess: healthReadAccessSettings,
                requestHealthReadAccess: usesVisualFixtures ? nil : requestHealthReadAccess,
                retainedHealthData: retainedHealthDataSettings,
                usesVisualFixtures: usesVisualFixtures
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

    @MainActor
    private func requestHealthWriteAccess() async {
        guard !usesVisualFixtures else { return }
        _ = await healthKitController.requestWriteAuthorization(userInitiated: true)
        // Refresh status after the explicit action so the row reflects the
        // typed per-metric sharing state observed by the controller.
        await healthKitController.refreshStatus()
    }
}

private struct LifeOSIOSSceneRoot: View {
    @ObservedObject private var calendarCoordinator: CalendarCoordinator
    @ObservedObject private var usageCoordinator: UsageCoordinator
    @ObservedObject private var financeCoordinator: FinanceCoordinator
    @ObservedObject private var clipperCoordinator: ClipperCoordinator
    @ObservedObject private var fitnessTrainingCoordinator: FitnessTrainingCoordinator
    @Binding private var homeFitnessSnapshot: FitnessSnapshot
    private let usesVisualFixtures: Bool
    private let fitnessSnapshotProvider: ((Date) -> FitnessSnapshot)?
    private let destinationForModule: (LifeOSModule, LifeOSDeepLink?) -> AnyView

    @State private var selection: LifeOSAppTab = .home
    @State private var showingUsage = false
    @State private var requestingNewCalendarEvent = false
    @State private var selectedModuleRoute: LifeOSDeepLink?
    @State private var showingDestinationUnavailable = false
    @State private var unavailableOriginTab: LifeOSAppTab = .home
    @State private var unavailableOriginRoute: LifeOSDeepLink?
    @State private var unavailableOriginShowingUsage = false
    @State private var didRestoreSceneState = false
    @SceneStorage("LifeOS.iOS.tab.v1") private var restoredTabIdentifier = LifeOSAppTab.home.identifier
    @SceneStorage("LifeOS.iOS.route.v1") private var restoredRouteIdentifier = ""
    @SceneStorage("LifeOS.iOS.showingUsage.v1") private var restoredShowingUsage = false
    @StateObject private var calendarPresentationState: CalendarPresentationState
    @StateObject private var financePresentationState: FinancePresentationState
    @StateObject private var fitnessPresentationState: FitnessPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var routeTransition: AnyTransition {
        reduceMotion ? .identity : .opacity
    }

    init(
        calendarCoordinator: CalendarCoordinator,
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator,
        clipperCoordinator: ClipperCoordinator,
        fitnessTrainingCoordinator: FitnessTrainingCoordinator,
        usesVisualFixtures: Bool,
        homeFitnessSnapshot: Binding<FitnessSnapshot>,
        fitnessSnapshotProvider: ((Date) -> FitnessSnapshot)?,
        destinationForModule: @escaping (LifeOSModule, LifeOSDeepLink?) -> AnyView
    ) {
        self.calendarCoordinator = calendarCoordinator
        self.usageCoordinator = usageCoordinator
        self.financeCoordinator = financeCoordinator
        self.clipperCoordinator = clipperCoordinator
        self.fitnessTrainingCoordinator = fitnessTrainingCoordinator
        self.usesVisualFixtures = usesVisualFixtures
        self._homeFitnessSnapshot = homeFitnessSnapshot
        self.fitnessSnapshotProvider = fitnessSnapshotProvider
        self.destinationForModule = destinationForModule
        _calendarPresentationState = StateObject(wrappedValue: CalendarPresentationState())
        _financePresentationState = StateObject(wrappedValue: FinancePresentationState())
        _fitnessPresentationState = StateObject(wrappedValue: FitnessPresentationState())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if showingDestinationUnavailable {
                    LifeOSDestinationUnavailableView(
                        onBack: restoreUnavailableOrigin,
                        onHome: {
                            showingDestinationUnavailable = false
                            clearSelectedModuleRoute()
                            showingUsage = false
                            requestingNewCalendarEvent = false
                            clearUnavailableOrigin()
                            selectTab(.home)
                        }
                    )
                    .transition(routeTransition)
                } else {
                    detail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : LifeOSMotion.tabCrossfade, value: selection)
            .animation(reduceMotion ? nil : LifeOSMotion.tabCrossfade, value: showingUsage)
            .animation(reduceMotion ? nil : LifeOSMotion.tabCrossfade, value: selectedModuleRoute)
            .animation(reduceMotion ? nil : LifeOSMotion.tabCrossfade, value: showingDestinationUnavailable)

            if !showingUsage {
                CompactTabBar(selection: $selection) { tab in
                    clearSelectedModuleRoute()
                    showingUsage = false
                    requestingNewCalendarEvent = false
                    showingDestinationUnavailable = false
                    clearUnavailableOrigin()
                    selection = tab
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
        .animation(reduceMotion ? nil : LifeOSMotion.ease, value: calendarCoordinator.snapshot.items.count)
        .onOpenURL { url in
            switch LifeOSNavigationRoute(url: url) {
            case .existing(let destination): navigate(destination)
            case .home:
                showingDestinationUnavailable = false
                clearUnavailableOrigin()
                selectTab(.home)
                clearSelectedModuleRoute()
                showingUsage = false
                requestingNewCalendarEvent = false
            case .destinationUnavailable:
                guard !showingDestinationUnavailable else { break }
                unavailableOriginTab = selection
                unavailableOriginRoute = selectedModuleRoute
                unavailableOriginShowingUsage = showingUsage
                clearSelectedModuleRoute()
                showingUsage = false
                requestingNewCalendarEvent = false
                showingDestinationUnavailable = true
            }
        }
        .onAppear { restoreSceneStateIfNeeded() }
        .onChange(of: selection) { _, _ in persistSceneState() }
        .onChange(of: selectedModuleRoute) { _, _ in persistSceneState() }
        .onChange(of: showingUsage) { _, _ in persistSceneState() }
        .onChange(of: requestingNewCalendarEvent) { _, requested in
            guard !requested, selectedModuleRoute == .newCalendarEvent else { return }
            // The calendar consumes this binding immediately. Replace the
            // transient command with its ordinary route before persistence so
            // relaunch cannot open another editor.
            selectedModuleRoute = .calendar
            persistSceneState()
        }
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
                    refreshAction: usesVisualFixtures ? nil : { await usageCoordinator.refresh() },
                    onBack: {
                        withAnimation(reduceMotion ? nil : LifeOSMotion.heroMorph) {
                            showingUsage = false
                            selectedModuleRoute = nil
                        }
                    },
                    onOpenSettings: { navigate(.settings) }
                )
                .transition(routeTransition)
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
                    fitnessSnapshot: usesVisualFixtures ? .demo : homeFitnessSnapshot,
                    financeSummary: usesVisualFixtures ? nil : financeCoordinator.summary,
                    financeState: usesVisualFixtures ? .demo : financeCoordinator.state,
                    openDestination: navigate,
                    showingUsage: $showingUsage
                )
                .transition(routeTransition)
            }
        case .calendar:
            CalendarView(
                coordinator: calendarCoordinator,
                requestNewEvent: $requestingNewCalendarEvent,
                presentationState: calendarPresentationState
            )
            .transition(routeTransition)
        case .finance:
            FinanceView(
                summary: financeCoordinator.summary,
                usesVisualFixtures: usesVisualFixtures,
                initialDetail: financeDetailRoute,
                onOpenConnections: { navigate(.settings) },
                onRefresh: usesVisualFixtures ? nil : { await financeCoordinator.refresh() },
                observationState: usesVisualFixtures ? .demo : financeCoordinator.observationState,
                errorMessage: usesVisualFixtures ? nil : financeCoordinator.errorMessage,
                presentationState: financePresentationState
            )
            .transition(routeTransition)
        case .fitness:
            FitnessView(
                snapshot: usesVisualFixtures ? .demo : .unavailable,
                snapshotProvider: fitnessSnapshotProvider,
                initialSection: selectedModuleRoute?.fitnessSection,
                initialNutritionEntryPoint: selectedModuleRoute?.nutritionEntryPoint,
                initialFitnessEntryPoint: selectedModuleRoute?.fitnessEntryPoint,
                usesVisualFixtures: usesVisualFixtures,
                onSourceReview: { navigate(.settings) },
                trainingCoordinator: fitnessTrainingCoordinator,
                presentationState: fitnessPresentationState
            )
            .transition(routeTransition)
        case .more:
            LifeOSMoreModulesView(
                initialModule: secondaryModuleRoute,
                initialRoute: selectedModuleRoute,
                usesVisualFixtures: usesVisualFixtures,
                destinationForModule: destinationForModule
            )
            .transition(routeTransition)
        }
    }

    private func restoreSceneStateIfNeeded() {
        guard !didRestoreSceneState else { return }
        didRestoreSceneState = true
        LifeOSMotion.withoutAnimation {
            guard let tab = LifeOSAppTab(identifier: restoredTabIdentifier) else { return }
            selection = tab
            selectedModuleRoute = nil
            showingUsage = restoredShowingUsage && tab == .home
            requestingNewCalendarEvent = false
            showingDestinationUnavailable = false
            guard let route = LifeOSNavigationRoute(restorationKey: restoredRouteIdentifier) else { return }
            switch route {
            case .home, .destinationUnavailable:
                break
            case .existing(let destination):
                let restoredDestination: LifeOSDeepLink = destination == .newCalendarEvent ? .calendar : destination
                selectedModuleRoute = restoredDestination
                recordModuleRouteIntent(restoredDestination)
                showingUsage = restoredDestination == .usage
                switch restoredDestination.module {
                case .home: selection = .home
                case .calendar: selection = .calendar
                case .finance: selection = .finance
                case .fitness: selection = .fitness
                case .tax, .settings: selection = .more
                default: selection = tab
                }
            }
        }
    }

    private func persistSceneState() {
        guard didRestoreSceneState else { return }
        restoredTabIdentifier = selection.identifier
        restoredRouteIdentifier = selectedModuleRoute?.restorationKey ?? ""
        restoredShowingUsage = showingUsage
    }

    private func restoreUnavailableOrigin() {
        let originTab = unavailableOriginTab
        let originRoute = unavailableOriginRoute
        let originShowingUsage = unavailableOriginShowingUsage
        showingDestinationUnavailable = false
        selection = originTab
        let restoredRoute = originRoute == .newCalendarEvent ? .calendar : originRoute
        selectedModuleRoute = restoredRoute
        recordModuleRouteIntent(restoredRoute)
        showingUsage = originShowingUsage
        requestingNewCalendarEvent = false
        clearUnavailableOrigin()
    }

    private func navigate(_ destination: LifeOSDeepLink) {
        showingDestinationUnavailable = false
        clearUnavailableOrigin()
        selectedModuleRoute = destination
        recordModuleRouteIntent(destination)
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
        case .fitness, .fitnessTraining, .fitnessNutrition, .fitnessNutritionGoals, .fitnessNutritionImport,
             .fitnessNutritionCamera, .fitnessNutritionBarcode, .fitnessNutritionAIProposal,
             .fitnessNutritionSearch, .fitnessNetEnergy, .fitnessDailyOverview,
             .fitnessStrain, .fitnessRecovery, .fitnessSleep, .fitnessRespiration,
             .fitnessHealthMonitor, .fitnessHeartRate, .fitnessHRV, .fitnessSpO2, .fitnessTemperature,
             .fitnessSleepDuration, .fitnessStress, .fitnessEnergyReserve:
            showingUsage = false
            selectTab(.fitness)
        case .tasks:
            showingUsage = false
            selectTab(.calendar)
        case .tax, .settings:
            showingUsage = false
            selectTab(.more)
        }
    }

    private func selectTab(_ tab: LifeOSAppTab) {
        showingDestinationUnavailable = false
        clearUnavailableOrigin()
        selection = tab
    }

    private func clearSelectedModuleRoute() {
        selectedModuleRoute = nil
        recordModuleRouteIntent(nil)
    }

    private func recordModuleRouteIntent(_ destination: LifeOSDeepLink?) {
        let financeRoute: FinanceDetailRoute?
        if destination?.module == .finance {
            switch destination {
            case .financeSpend: financeRoute = .spend
            case .financeCashFlow: financeRoute = .cashFlow
            default: financeRoute = nil
            }
        } else {
            financeRoute = nil
        }
        financePresentationState.receiveExternalRoute(financeRoute)
        fitnessPresentationState.receiveExternalRoute(
            destination?.module == .fitness ? destination : nil
        )
    }

    private func clearUnavailableOrigin() {
        unavailableOriginTab = .home
        unavailableOriginRoute = nil
        unavailableOriginShowingUsage = false
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
}

#if os(iOS)
/// Settings is pushed by the More navigation stack while HealthKit startup is
/// still asynchronous. Observing the controller and repository here prevents
/// a destination opened during that window from retaining the initial
/// `.unavailable` value after reconciliation has published durable state.
private struct HealthKitSettingsDestination: View {
    @ObservedObject private var usageCoordinator: UsageCoordinator
    @ObservedObject private var financeCoordinator: FinanceCoordinator
    @ObservedObject private var clipperCoordinator: ClipperCoordinator
    @ObservedObject private var healthKitController: HealthKitIntegrationController
    @ObservedObject private var healthKitFitnessRepository: HealthKitFitnessRepository
    private let requestHealthReadAccess: (@MainActor () async -> Void)?
    private let requestHealthWriteAccess: (@MainActor () async -> Void)?
    private let usesVisualFixtures: Bool

    init(
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator,
        clipperCoordinator: ClipperCoordinator,
        healthKitController: HealthKitIntegrationController,
        healthKitFitnessRepository: HealthKitFitnessRepository,
        requestHealthReadAccess: (@MainActor () async -> Void)?,
        requestHealthWriteAccess: (@MainActor () async -> Void)?,
        usesVisualFixtures: Bool
    ) {
        _usageCoordinator = ObservedObject(wrappedValue: usageCoordinator)
        _financeCoordinator = ObservedObject(wrappedValue: financeCoordinator)
        _clipperCoordinator = ObservedObject(wrappedValue: clipperCoordinator)
        _healthKitController = ObservedObject(wrappedValue: healthKitController)
        _healthKitFitnessRepository = ObservedObject(wrappedValue: healthKitFitnessRepository)
        self.requestHealthReadAccess = requestHealthReadAccess
        self.requestHealthWriteAccess = requestHealthWriteAccess
        self.usesVisualFixtures = usesVisualFixtures
    }

    var body: some View {
        SettingsView(
            usageCoordinator: usageCoordinator,
            financeCoordinator: financeCoordinator,
            clipperCoordinator: clipperCoordinator,
            healthReadAccess: HealthReadAccessSettings.from(snapshot: healthKitController.snapshot),
            requestHealthReadAccess: requestHealthReadAccess,
            retainedHealthData: retainedHealthData,
            healthKitController: healthKitController,
            healthKitFitnessRepository: healthKitFitnessRepository,
            requestHealthWriteAccess: requestHealthWriteAccess,
            healthWriteAccess: HealthWriteAccessSettings.from(snapshot: healthKitController.snapshot),
            usesVisualFixtures: usesVisualFixtures
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
            reduceMotion: reduceMotion
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

}

private struct CompactTabBarItem: View {
    let tab: LifeOSAppTab
    let title: String
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isSelected ? LifeOSTokens.selectedNavigationText : LifeOSTokens.tertiaryText)
                    .modifier(CompactTabSymbolTransition(enabled: !reduceMotion))
                    .frame(width: 20, height: 19)
                Text(title)
                    .lifeOSTypography(.label)
                    .foregroundStyle(isSelected ? LifeOSTokens.selectedNavigationText : LifeOSTokens.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? LifeOSTokens.selectedNavigationFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Switches to \(title)")
        .accessibilityIdentifier("main-tab-\(tab.identifier)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "Selected" : "")
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
