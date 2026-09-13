import XCTest

/// TEMPORARY evidence harness for the calendar overhaul (deleted after use).
/// Performs timed gestures while the host captures simctl screenshots.
final class CalOverhaulEvidenceUITests: XCTestCase {

    private func mark(_ path: String) {
        let value = String(format: "%.3f", Date().timeIntervalSince1970)
        try? value.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    func testCalendarOverhaulEvidenceSequence() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-LifeOSVisualFixtures"]
        app.launch()
        mark("/tmp/cal-overhaul-evidence-start")

        let calendarTab = app.buttons["main-tab-calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 15))
        calendarTab.tap()
        // Host captures the default state during this window (marker +0..+4s).
        sleep(4)

        // Slow left swipe toward later days: host captures MID-drag frames
        // between marker +4s and +8s, settled frame after.
        let swipeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.42))
        let swipeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.42))
        swipeStart.press(forDuration: 0.15, thenDragTo: swipeEnd, withVelocity: 150, thenHoldForDuration: 0.3)
        sleep(3)

        // Second swipe (marker +11..+15s).
        swipeStart.press(forDuration: 0.15, thenDragTo: swipeEnd, withVelocity: 150, thenHoldForDuration: 0.3)
        sleep(3)

        // Vertical reachability: four upward drags force maximum scroll.
        for _ in 0..<4 {
            let vStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.78))
            let vEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.22))
            vStart.press(forDuration: 0.1, thenDragTo: vEnd, withVelocity: 220, thenHoldForDuration: 0.1)
        }
        sleep(2)
        mark("/tmp/cal-overhaul-evidence-end")
    }
}
