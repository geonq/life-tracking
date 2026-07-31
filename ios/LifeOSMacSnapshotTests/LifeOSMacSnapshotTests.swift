import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import LifeOSMac

@available(macOS 14.0, *)
@MainActor
final class LifeOSMacSnapshotTests: XCTestCase {
    private let frame = CGSize(width: 1512, height: 982)

    func testOverviewSnapshot() {
        let coordinator = CalendarCoordinator(initialSnapshot: CalendarVisualFixtures.snapshot())
        render(LifeOSMacRootView(calendarCoordinator: coordinator, usesVisualFixtures: true), named: "LifeOSMacRootView-overview")
    }

    func testCalendarSnapshot() {
        let anchor = visualFixtureAnchor
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(anchor: anchor, calendar: visualFixtureCalendar)
        )
        render(
            CalendarView(selectedDate: anchor, calendar: visualFixtureCalendar, coordinator: coordinator),
            named: "CalendarView"
        )
    }

    func testCalendarMonthSnapshot() {
        let anchor = visualFixtureAnchor
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(anchor: anchor, calendar: visualFixtureCalendar)
        )
        render(
            CalendarView(
                selectedDate: anchor,
                calendar: visualFixtureCalendar,
                coordinator: coordinator,
                startsInMonthMode: true
            ),
            named: "CalendarView-month",
            colorScheme: .dark
        )
    }

    func testUsageSnapshot() {
        render(UsageView(snapshots: DemoDataProvider.providers, analytics: DemoUsageAnalytics.snapshots), named: "UsageView", colorScheme: .light)
    }

    func testTaxDocumentsSnapshot() {
        render(TaxDocumentsView(), named: "TaxDocumentsView")
    }

    func testDarkModeSnapshots() {
        let anchor = visualFixtureAnchor
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(anchor: anchor, calendar: visualFixtureCalendar)
        )
        render(LifeOSMacRootView(calendarCoordinator: coordinator, usesVisualFixtures: true), named: "LifeOSMacRootView-overview-dark", colorScheme: .dark)
        render(UsageView(snapshots: DemoDataProvider.providers, analytics: DemoUsageAnalytics.snapshots), named: "UsageView-dark", colorScheme: .dark)
        render(CalendarView(selectedDate: anchor, calendar: visualFixtureCalendar, coordinator: coordinator), named: "CalendarView-dark", colorScheme: .dark)
        render(TaxDocumentsView(), named: "TaxDocumentsView-dark", colorScheme: .dark)
    }

    private var visualFixtureCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private var visualFixtureAnchor: Date {
        visualFixtureCalendar.date(from: DateComponents(year: 2026, month: 7, day: 27, hour: 9))!
    }

    private func render<V: View>(_ view: V, named name: String, colorScheme: ColorScheme? = nil) {
        let rootView: AnyView = if let colorScheme {
            AnyView(view.environment(\.colorScheme, colorScheme))
        } else {
            AnyView(view)
        }

        let hostingView = NSHostingView(
            rootView: rootView
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(width: frame.width, height: frame.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: frame)

        // Hosting the real view hierarchy in an off-screen AppKit window exercises
        // NavigationSplitView and other AppKit-backed SwiftUI containers that
        // ImageRenderer replaces with unsupported-content placeholders.
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        // Allow SwiftUI tasks and chart entrance animations to settle before
        // capturing; otherwise an off-screen host records their zero state.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Could not allocate a bitmap for \(name)")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0,
              let data = bitmap.representation(using: .png, properties: [:]),
              data.count > 1_024 else {
            XCTFail("Off-screen AppKit rendering produced an empty image for \(name)")
            return
        }

        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "\(name).png", payload: data)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
