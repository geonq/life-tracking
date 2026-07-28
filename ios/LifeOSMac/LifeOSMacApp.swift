import SwiftUI

@main
struct LifeOSMacApp: App {
    @StateObject private var calendarCoordinator = CalendarCoordinator()
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
            .frame(minWidth: 760, minHeight: 540)
            .task {
                await calendarCoordinator.load()
                calendarCoordinator.startSync()
            }
        }
        .defaultSize(width: 980, height: 700)
    }
}
