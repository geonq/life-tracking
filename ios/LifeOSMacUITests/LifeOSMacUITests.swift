import XCTest

final class LifeOSMacUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-LifeOSVisualFixtures"]
        app.launch()
    }

    func testPrimaryScreenshotsAndAccessibility() throws {
        XCTAssertTrue(app.staticTexts["Life OS"].waitForExistence(timeout: 8))
        capture("mac-overview")

        let calendar = app.staticTexts["Calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.tap()
        XCTAssertTrue(app.buttons["calendar-add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Week"].waitForExistence(timeout: 5))
        capture("mac-calendar-week")
        app.segmentedControls.buttons["Month"].tap()
        capture("mac-calendar-month")

        let taxDocuments = app.staticTexts["Tax Documents"].firstMatch
        XCTAssertTrue(taxDocuments.waitForExistence(timeout: 5))
        taxDocuments.tap()
        XCTAssertTrue(app.buttons["Import PDF"].waitForExistence(timeout: 5))
        capture("mac-tax-documents")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
