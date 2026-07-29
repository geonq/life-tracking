import SwiftUI

@main
struct LifeOSMacApp: App {
    @StateObject private var calendarCoordinator = CalendarCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some Scene {
        WindowGroup {
            LifeOSMacRootView(calendarCoordinator: calendarCoordinator)
                .frame(minWidth: 760, minHeight: 540)
                .tint(LifeOSTokens.accent)
                .animation(reduceMotion ? nil : LifeOSMotion.ease,
                           value: calendarCoordinator.snapshot.items.count)
                .task {
                    await calendarCoordinator.load()
                    calendarCoordinator.startSync()
                }
        }
        .defaultSize(width: 980, height: 700)

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
    @State private var selection: SidebarItem = .overview

    init(calendarCoordinator: CalendarCoordinator) {
        self.calendarCoordinator = calendarCoordinator
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.overview)
                    Label("Calendar", systemImage: "calendar").tag(SidebarItem.calendar)
                    Label("Tax Documents", systemImage: "doc.text.magnifyingglass").tag(SidebarItem.tax)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Life OS")
            .safeAreaPadding(.bottom)
        } detail: {
            switch selection {
            case .overview:
                OverviewView()
                    .transition(reduceMotion ? .identity : .opacity)
            case .calendar:
                CalendarView(coordinator: calendarCoordinator)
                    .transition(reduceMotion ? .identity : .opacity)
            case .tax:
                TaxDocumentsView()
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : LifeOSMotion.easeNavigate, value: selection)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    enum SidebarItem: Hashable { case overview, calendar, tax }
}
