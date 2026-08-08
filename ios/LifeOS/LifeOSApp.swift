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
            Group {
                switch selection {
                case .overview:
                OverviewView(
                    snapshot: usesVisualFixtures ? DemoDataProvider.overview : .unavailable(),
                    usageSnapshots: usesVisualFixtures ? DemoDataProvider.providers : [],
                    usageAnalytics: usesVisualFixtures ? DemoUsageAnalytics.snapshots : [],
                    showingUsage: $showingUsage
                )
                case .calendar:
                CalendarView(coordinator: calendarCoordinator, requestNewEvent: $requestingNewCalendarEvent)
                case .tax:
                TaxDocumentsView()
                case .settings:
                NavigationStack { SettingsView() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !showingUsage {
                    CompactTabBar(selection: $selection)
                        .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                }
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

private struct CompactTabBar: View {
    @Binding var selection: LifeOSAppTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            item(.overview, title: "Overview", icon: .overview)
            item(.calendar, title: "Calendar", icon: .calendar)
            item(.tax, title: "Tax", icon: .tax)
            item(.settings, title: "Settings", icon: .settings)
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LifeOSTokens.hairlineBorder)
                .frame(height: 0.5)
        }
        .accessibilityIdentifier("main-tab-bar")
    }

    private func item(_ tab: LifeOSAppTab, title: String, icon: LifeOSIconName) -> some View {
        let selected = selection == tab
        return Button {
            withAnimation(reduceMotion ? nil : LifeOSMotion.springSnappy) {
                selection = tab
            }
        } label: {
            VStack(spacing: 2) {
                LifeOSIcon(icon)
                    .frame(width: 17, height: 17)
                Text(title)
                    .font(LifeOSFont.inter(9.5, weight: selected ? .semiBold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? LifeOSTokens.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
