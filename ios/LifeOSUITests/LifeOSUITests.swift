import XCTest

final class LifeOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        dismissSystemPromptsIfPresent()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 375, "App must use the full modern iPhone viewport")
    }

    func testPrimaryScreenshotsAndAccessibility() throws {
        capture("overview")
        XCTAssertTrue(app.tabBars.buttons["Overview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Overview"].exists || app.staticTexts["Life OS"].exists)

        let usage = app.buttons["account-usage-link"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.tap()
        XCTAssertTrue(app.navigationBars["Usage"].waitForExistence(timeout: 5))
        capture("usage")
        let calendarTab = app.tabBars.buttons["Calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 5))
        calendarTab.tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 5))
        capture("calendar")

        let taxTab = app.tabBars.buttons["Tax"]
        XCTAssertTrue(taxTab.waitForExistence(timeout: 5))
        taxTab.tap()
        XCTAssertTrue(app.staticTexts["Tax Documents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["import-tax-pdf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stored only on this device. Candidates are rule-based, not tax advice, and nothing is filed automatically."].waitForExistence(timeout: 5))
        capture("tax-documents")

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture("settings")
    }

    func testDarkModeScreenshots() throws {
        app.terminate()
        app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.tabBars.buttons["Overview"].waitForExistence(timeout: 5))
        capture("dark-overview")

        let usage = app.buttons["account-usage-link"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.tap()
        XCTAssertTrue(app.navigationBars["Usage"].waitForExistence(timeout: 5))
        capture("dark-usage")

        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 5))
        capture("dark-calendar")

        app.tabBars.buttons["Tax"].tap()
        XCTAssertTrue(app.buttons["import-tax-pdf"].waitForExistence(timeout: 5))
        capture("dark-tax-documents")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture("dark-settings")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissSystemPromptsIfPresent() {
        for label in ["Allow", "OK", "Continue", "Don’t Allow", "Don't Allow"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 1) { button.tap() }
        }
    }
}
