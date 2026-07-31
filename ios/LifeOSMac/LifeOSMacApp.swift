import SwiftUI

@main
struct LifeOSMacApp: App {
    @StateObject private var calendarCoordinator: CalendarCoordinator
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

    var body: some Scene {
        WindowGroup {
            LifeOSMacRootView(
                calendarCoordinator: calendarCoordinator,
                usesVisualFixtures: usesVisualFixtures
            )
                .frame(minWidth: 900, minHeight: 640)
                .tint(LifeOSTokens.accent)
                .animation(reduceMotion ? nil : LifeOSMotion.ease,
                           value: calendarCoordinator.snapshot.items.count)
                .task {
                    if !usesVisualFixtures {
                        await calendarCoordinator.load()
                        calendarCoordinator.startSync()
                    }
                }
        }
        .defaultSize(width: 1512, height: 982)

        Settings {
            SettingsView()
                .frame(minWidth: 520, minHeight: 360)
                .tint(LifeOSTokens.accent)
        }
    }
}

/// macOS-native navigation using NavigationSplitView with branded sidebar.
struct LifeOSMacRootView: View {
    @ObservedObject private var calendarCoordinator: CalendarCoordinator
    private let usesVisualFixtures: Bool
    @State private var selection: SidebarItem = .overview
    @State private var showingUsage = false
    @State private var requestingNewCalendarEvent = false

    init(calendarCoordinator: CalendarCoordinator, usesVisualFixtures: Bool = false) {
        self.calendarCoordinator = calendarCoordinator
        self.usesVisualFixtures = usesVisualFixtures
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label { Text("Overview") } icon: { LifeOSIcon(.overview) }.tag(SidebarItem.overview)

                    Label { Text("Calendar") } icon: { LifeOSIcon(.calendar) }.tag(SidebarItem.calendar)
                    Label { Text("Tax Documents") } icon: { LifeOSIcon(.tax) }.tag(SidebarItem.tax)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Life OS")
            .navigationSplitViewColumnWidth(min: 234, ideal: 234, max: 234)
            .safeAreaPadding(.bottom)
        } detail: {
            switch selection {
            case .overview:
                OverviewView(
                    snapshot: usesVisualFixtures ? DemoDataProvider.overview : .unavailable(),
                    usageSnapshots: usesVisualFixtures ? DemoDataProvider.providers : [],
                    usageAnalytics: usesVisualFixtures ? DemoUsageAnalytics.snapshots : [],
                    showingUsage: $showingUsage
                )
                    .transition(reduceMotion ? .identity : .opacity)
            case .calendar:
                CalendarView(coordinator: calendarCoordinator, requestNewEvent: $requestingNewCalendarEvent)
                    .transition(reduceMotion ? .identity : .opacity)
            case .tax:
                TaxDocumentsView()
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : LifeOSMotion.easeNavigate, value: selection)
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
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    enum SidebarItem: Hashable { case overview, calendar, tax }
}
