import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import LifeOSMac

@available(macOS 14.0, *)
@MainActor
final class LifeOSMacSnapshotTests: XCTestCase {
    private let frame = CGSize(width: 980, height: 700)

    func testOverviewSnapshot() {
        let coordinator = CalendarCoordinator()
        render(LifeOSMacRootView(calendarCoordinator: coordinator), named: "LifeOSMacRootView-overview")
    }

    func testCalendarSnapshot() {
        let coordinator = CalendarCoordinator()
        render(CalendarView(selectedDate: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian), coordinator: coordinator), named: "CalendarView")
    }

    func testTaxDocumentsSnapshot() {
        render(TaxDocumentsView(), named: "TaxDocumentsView")
    }

    func testDarkModeSnapshots() {
        let coordinator = CalendarCoordinator()
        render(LifeOSMacRootView(calendarCoordinator: coordinator), named: "LifeOSMacRootView-overview-dark", colorScheme: .dark)
        render(CalendarView(selectedDate: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian), coordinator: coordinator), named: "CalendarView-dark", colorScheme: .dark)
        render(TaxDocumentsView(), named: "TaxDocumentsView-dark", colorScheme: .dark)
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
