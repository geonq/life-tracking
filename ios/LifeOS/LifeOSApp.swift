import SwiftUI

@main
struct LifeOSApp: App {
    @StateObject private var calendarCoordinator = CalendarCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some Scene {
        WindowGroup {
            TabView {
                OverviewView()
                    .tabItem {
                        Label { Text("Overview") } icon: { LifeOSIcon(.overview) }
                    }
                CalendarView(coordinator: calendarCoordinator)
                    .tabItem {
                        Label { Text("Calendar") } icon: { LifeOSIcon(.calendar) }
                    }
                TaxDocumentsView()
                    .tabItem {
                        Label { Text("Tax") } icon: { LifeOSIcon(.tax) }
                    }
                NavigationStack { SettingsView() }
                    .tabItem {
                        Label { Text("Settings") } icon: { LifeOSIcon(.settings) }
                    }
            }
            .tint(LifeOSTokens.accent)
            .animation(reduceMotion ? nil : LifeOSMotion.ease, value: calendarCoordinator.snapshot.items.count)
            .task {
                await calendarCoordinator.load()
                calendarCoordinator.startSync()
            }
        }
    }
}
