import SwiftUI

@main
struct LifeOSApp: App {
    @StateObject private var calendarCoordinator = CalendarCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some Scene {
        WindowGroup {
            TabView {
                OverviewView()
                    .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
                CalendarView(coordinator: calendarCoordinator)
                    .tabItem { Label("Calendar", systemImage: "calendar") }
                TaxDocumentsView()
                    .tabItem { Label("Tax", systemImage: "doc.text.magnifyingglass") }
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
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
