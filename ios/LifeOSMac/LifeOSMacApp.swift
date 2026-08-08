import SwiftUI

@main
struct LifeOSMacApp: App {
    @StateObject private var calendarCoordinator: CalendarCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let usesVisualFixtures: Bool

    init() {
        LifeOSFontRegistrar.registerBundledFonts()
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
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await calendarCoordinator.manualRefresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .frame(minWidth: 520, minHeight: 360)
                .tint(LifeOSTokens.accent)
        }
    }
}

/// A compact, deterministic macOS split layout. Keeping the sidebar in SwiftUI
/// avoids AppKit material placeholders when the view is rendered off-screen.
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
        HStack(spacing: 0) {
            sidebar
                .frame(width: 218)
            Rectangle()
                .fill(LifeOSTokens.hairlineBorder)
                .frame(width: 1)
            ZStack {
                LifeOSTokens.screenCanvas
                detail
            }
        }
        .background(LifeOSTokens.screenCanvas)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIFE OS")
                .font(LifeOSFont.manrope(10, weight: .extraBold))
                .tracking(0.8)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)

            sidebarButton("Overview", icon: .overview, item: .overview)
            sidebarButton("Calendar", icon: .calendar, item: .calendar)
            sidebarButton("Tax Documents", icon: .tax, item: .tax)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LifeOSTokens.canvas)
    }

    @ViewBuilder
    private var detail: some View {
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

    private func sidebarButton(_ title: String, icon: LifeOSIconName, item: SidebarItem) -> some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 9) {
                LifeOSIcon(icon)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(LifeOSFont.inter(13, weight: selection == item ? .semiBold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selection == item ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                selection == item ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
