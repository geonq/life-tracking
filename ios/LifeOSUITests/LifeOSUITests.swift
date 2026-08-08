import XCTest

final class LifeOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceLightMode"]
        app.launch()
        dismissSystemPromptsIfPresent()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 375, "App must use the full modern iPhone viewport")
    }

    func testPrimaryScreenshotsAndAccessibility() throws {
        capture("overview")
        XCTAssertTrue(app.buttons["Overview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["overview-screen"].waitForExistence(timeout: 5))

        XCTAssertFalse(app.buttons["Usage"].exists)
        let usageCard = app.buttons["account-usage-link"]
        XCTAssertTrue(usageCard.waitForExistence(timeout: 5))
        XCTAssertTrue(tap(usageCard, untilVisible: app.scrollViews["usage-screen"]))
        capture("usage")

        app.buttons["usage-back"].tap()
        let calendarTab = app.buttons["Calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 5))
        XCTAssertTrue(tap(calendarTab, untilVisible: app.buttons["calendar-add"]))
        XCTAssertTrue(app.buttons["3 Days"].waitForExistence(timeout: 5))
        capture("calendar-three-day")
        app.buttons["Month"].tap()
        capture("calendar-month")

        let taxTab = app.buttons["Tax"]
        XCTAssertTrue(taxTab.waitForExistence(timeout: 5))
        taxTab.tap()
        XCTAssertTrue(app.staticTexts["Tax Documents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["import-tax-pdf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stored only on this device. Candidates are rule-based, not tax advice, and nothing is filed automatically."].waitForExistence(timeout: 5))
        capture("tax-documents")

        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture("settings")
    }

    func testDarkModeScreenshots() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Overview"].waitForExistence(timeout: 5))
        capture("dark-overview")

        XCTAssertFalse(app.buttons["Usage"].exists)
        let usageCard = app.buttons["account-usage-link"]
        XCTAssertTrue(usageCard.waitForExistence(timeout: 5))
        XCTAssertTrue(tap(usageCard, untilVisible: app.scrollViews["usage-screen"]))
        capture("dark-usage")

        app.buttons["usage-back"].tap()

        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        XCTAssertTrue(app.buttons["3 Days"].waitForExistence(timeout: 5))
        capture("dark-calendar-three-day")
        app.buttons["Month"].tap()
        capture("dark-calendar-month")

        app.buttons["Tax"].tap()
        XCTAssertTrue(app.buttons["import-tax-pdf"].waitForExistence(timeout: 5))
        capture("dark-tax-documents")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture("dark-settings")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ element: XCUIElement, untilVisible target: XCUIElement, attempts: Int = 2) -> Bool {
        for _ in 0..<attempts {
            element.tap()
            if target.waitForExistence(timeout: 5) { return true }
        }
        return false
    }

    private var baseLaunchArguments: [String] {
        ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-LifeOSVisualFixtures"]
    }

    private func dismissSystemPromptsIfPresent() {
        for label in ["Allow", "OK", "Continue", "Don’t Allow", "Don't Allow"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 1) { button.tap() }
        }
    }
}
