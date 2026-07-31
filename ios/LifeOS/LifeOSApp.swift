import SwiftUI

private enum LifeOSAppTab: Hashable {
    case overview, calendar, tax, settings
}

@main
struct LifeOSApp: App {
    @StateObject private var calendarCoordinator: CalendarCoordinator
    @State private var selection: LifeOSAppTab = .overview
    @State private var showingUsage = false
    @State private var requestingNewCalendarEvent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let usesVisualFixtures: Bool

    init() {
        let enabled = ProcessInfo.processInfo.arguments.contains("-LifeOSVisualFixtures")
        usesVisualFixtures = enabled
        _calendarCoordinator = StateObject(
            wrappedValue: CalendarCoordinator(
                initialSnapshot: enabled ? CalendarVisualFixtures.snapshot() : CalendarSnapshot()
            )
        )
    }

    private var forcedColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-LifeOSForceDarkMode") { return .dark }
        if arguments.contains("-LifeOSForceLightMode") { return .light }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selection) {
                OverviewView(
                    snapshot: usesVisualFixtures ? DemoDataProvider.overview : .unavailable(),
                    usageSnapshots: usesVisualFixtures ? DemoDataProvider.providers : [],
                    usageAnalytics: usesVisualFixtures ? DemoUsageAnalytics.snapshots : [],
                    showingUsage: $showingUsage
                )
                    .tabItem {
                        Label { Text("Overview") } icon: { LifeOSIcon(.overview) }
                    }
                    .tag(LifeOSAppTab.overview)

                CalendarView(coordinator: calendarCoordinator, requestNewEvent: $requestingNewCalendarEvent)
                    .tabItem {
                        Label { Text("Calendar") } icon: { LifeOSIcon(.calendar) }
                    }
                    .tag(LifeOSAppTab.calendar)
                TaxDocumentsView()
                    .tabItem {
                        Label { Text("Tax") } icon: { LifeOSIcon(.tax) }
                    }
                    .tag(LifeOSAppTab.tax)
                NavigationStack { SettingsView() }
                    .tabItem {
                        Label { Text("Settings") } icon: { LifeOSIcon(.settings) }
                    }
                    .tag(LifeOSAppTab.settings)
            }
            .tint(LifeOSTokens.accent)
            .preferredColorScheme(forcedColorScheme)
            .animation(reduceMotion ? nil : LifeOSMotion.ease, value: calendarCoordinator.snapshot.items.count)
            .onOpenURL { url in
                switch LifeOSDeepLink(url: url) {
                case .usage:
                    selection = .overview
                    showingUsage = true
                case .newCalendarEvent:
                    selection = .calendar
                    requestingNewCalendarEvent = true
                case .calendar: selection = .calendar
                case .tax: selection = .tax
                case nil: selection = .overview
                }
            }
            .task {
                if !usesVisualFixtures {
                    await calendarCoordinator.load()
                    calendarCoordinator.startSync()
                }
            }
        }
    }
}
