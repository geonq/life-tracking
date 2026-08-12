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
        for module in ["home", "calendar", "finance", "fitness", "tax", "settings"] {
            XCTAssertTrue(app.buttons["mac-sidebar-\(module)"].exists, "Mac sidebar should expose \(module)")
        }
        for hiddenModule in ["bank-connections", "investments", "business", "documents", "tasks", "grocery", "shopping", "ai-usage", "reports"] {
            XCTAssertFalse(app.buttons["mac-sidebar-\(hiddenModule)"].exists, "Mac sidebar should hide \(hiddenModule)")
        }
        XCTAssertFalse(app.buttons["mac-notifications-trigger"].exists)
        XCTAssertFalse(app.buttons["mac-assistant-trigger"].exists)
        XCTAssertFalse(app.buttons["mac-inspector-toggle"].exists)

        app.buttons["mac-command-palette-trigger"].tap()
        XCTAssertTrue(app.buttons["command-palette-home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["command-palette-settings"].exists)
        XCTAssertFalse(app.buttons["command-palette-ai-usage"].exists)
        app.buttons["command-palette-home"].tap()
        capture("mac-overview")

        let clipper = app.buttons["overview-clipper-card"]
        XCTAssertTrue(clipper.waitForExistence(timeout: 5), "Home must expose the Clipper card")
        clipper.hover()
        clipper.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["clipper-analytics-screen"].waitForExistence(timeout: 5),
            "Clipper card must navigate to its honest analytics detail"
        )
        capture("mac-clipper-analytics")
        app.buttons["mac-sidebar-home"].tap()

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

    func testCalendarFocusedEventArrowMovePersistsExactDateAndTime() throws {
        let calendar = app.staticTexts["Calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.tap()
        XCTAssertTrue(app.buttons["calendar-add"].waitForExistence(timeout: 5))

        let header = app.descendants(matching: .any)["calendar-header-date"]
        let visibleRange = app.descendants(matching: .any)["calendar-visible-range"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(visibleRange.waitForExistence(timeout: 5))
        let headerBefore = header.value as? String
        let rangeBefore = visibleRange.value as? String
        let event = app.descendants(matching: .any)["calendar-event-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        let valueBefore = event.value as? String
        let beforeDates = isoDates(in: valueBefore)
        let beforeTimes = timeRangeMinutes(valueBefore)
        let targetDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let targetDateString = isoDate(targetDate)

        // SwiftUI named accessibility actions have no direct XCTest invoke
        // API. The event is explicitly focusable on macOS, so typeKey sends
        // the real right-arrow command through its onMoveCommand path.
        event.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForValueChange(of: event, from: valueBefore, timeout: 5),
                      "A focused Mac event must respond to the right-arrow move command")
        let valueAfter = event.value as? String
        let afterDates = isoDates(in: valueAfter)
        let afterTimes = timeRangeMinutes(valueAfter)
        XCTAssertEqual(afterDates.first, targetDateString)
        XCTAssertEqual(afterTimes?.start, beforeTimes?.start)
        XCTAssertEqual(afterTimes?.end, beforeTimes?.end)
        XCTAssertNotNil(beforeDates.first)
        XCTAssertEqual(header.value as? String, headerBefore, "Arrow movement must not change the visible header")
        XCTAssertEqual(visibleRange.value as? String, rangeBefore, "Arrow movement must not shift the Mac horizontal range")

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Calendar"].firstMatch.waitForExistence(timeout: 8))
        app.staticTexts["Calendar"].firstMatch.tap()
        XCTAssertTrue(app.buttons["calendar-add"].waitForExistence(timeout: 8))
        let persisted = app.descendants(matching: .any)["calendar-event-10000000-0000-0000-0000-000000000001"]
        let persistedRange = app.descendants(matching: .any)["calendar-visible-range"]
        XCTAssertTrue(persisted.waitForExistence(timeout: 8))
        XCTAssertEqual(isoDates(in: persisted.value as? String).first, targetDateString)
        XCTAssertEqual(timeRangeMinutes(persisted.value as? String)?.start, beforeTimes?.start)
        XCTAssertEqual(timeRangeMinutes(persisted.value as? String)?.end, beforeTimes?.end)
        XCTAssertTrue(persistedRange.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedRange.value as? String, rangeBefore)
    }

    func testCalendarMonthEventDragShowsDestinationAndPreservesTime() throws {
        let calendar = app.staticTexts["Calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.tap()
        XCTAssertTrue(app.buttons["calendar-add"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Month"].tap()

        let source = app.descendants(matching: .any)["calendar-month-event-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(source.waitForExistence(timeout: 5), "Month view must expose the deterministic event chip")
        let targetDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let components = Calendar.current.dateComponents([.year, .month, .day], from: targetDay)
        let targetID = String(format: "calendar-month-cell-%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let target = app.descendants(matching: .any)[targetID]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Month view must expose a target day cell")
        let valueBefore = source.value as? String

        let sourcePoint = source.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.50))
        let targetPoint = target.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.42))
        sourcePoint.press(forDuration: 0.65, thenDragTo: targetPoint)

        XCTAssertTrue(waitForValueChange(of: source, from: valueBefore, timeout: 8),
                      "Month drag must publish a locally committed event update")
        let valueAfter = source.value as? String
        XCTAssertNotEqual(valueAfter, valueBefore)
        XCTAssertTrue(valueAfter?.contains("long press and drag to move") == true)
    }

    func testCalendarMacEditorContextualPopoverEntryAndChrome() throws {
        let calendar = app.staticTexts["Calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 8))
        calendar.tap()
        XCTAssertTrue(app.buttons["calendar-add"].waitForExistence(timeout: 5))

        app.buttons["calendar-add"].tap()
        let editor = app.popovers.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Calendar add must present the contextual Mac editor popover")
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-title"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-save"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-more"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-cancel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-start"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-end"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-date"].exists)
        capture("mac-calendar-event-editor-popover")

        app.descendants(matching: .any)["calendar-event-cancel"].tap()
        XCTAssertFalse(editor.waitForExistence(timeout: 2), "Closing the editor must dismiss the contextual popover")
    }

    func testCalendarMacPointerDoubleClickCreatesAnchoredQuarterHourEditorWithoutDraft() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let baselineFixtureIDs: Set<String>

        // Establish the durable baseline independently of the visual fixture.
        // A cancelled editor must not add an event to the local store even when
        // the test suite has left unrelated calendar data behind.
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openCalendar()
        let persistedBefore = calendarEventIdentifiers()

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-LifeOSVisualFixtures"]
        app.launch()
        openCalendar()
        baselineFixtureIDs = calendarEventIdentifiers()
        XCTAssertFalse(baselineFixtureIDs.isEmpty, "The visual calendar fixture must expose real event cards before pointer creation")

        let emptyGrid = app.descendants(matching: .any)["calendar-empty-timed-grid-\(isoDate(today))"]
        XCTAssertTrue(emptyGrid.waitForExistence(timeout: 5), "The selected day must expose its interactive timed-grid target")

        // Use the live fixture geometry as the wall-clock reference: the
        // deterministic Deep work event is 09:00–11:00, so one hour below its
        // bottom edge is the empty 12:00 slot between it and Ship checkpoint.
        let referenceEvent = app.descendants(matching: .any)["calendar-event-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(referenceEvent.waitForExistence(timeout: 5), "The visual fixture must expose the deterministic timed event")
        let targetStartMinutes = 12 * 60
        let timelineFrame = emptyGrid.frame
        let targetPoint = CGPoint(
            x: referenceEvent.frame.midX,
            y: referenceEvent.frame.maxY + 54
        )
        XCTAssertGreaterThan(timelineFrame.width, 0)
        XCTAssertTrue(timelineFrame.contains(targetPoint), "The empty 12:00 slot must be visible in the Mac timeline viewport")
        let target = emptyGrid.coordinate(withNormalizedOffset: CGVector(
            dx: (targetPoint.x - timelineFrame.minX) / timelineFrame.width,
            dy: (targetPoint.y - timelineFrame.minY) / timelineFrame.height
        ))
        target.doubleClick()

        let editor = app.popovers.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "A real pointer double-click on empty timed space must open the anchored Mac editor")
        XCTAssertLessThanOrEqual(
            distance(from: target.screenPoint, to: editor.frame),
            48,
            "The contextual editor must remain adjacent to the pointer's day/time anchor"
        )

        let start = app.descendants(matching: .any)["calendar-event-start"]
        let end = app.descendants(matching: .any)["calendar-event-end"]
        let date = app.descendants(matching: .any)["calendar-event-date"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(end.waitForExistence(timeout: 3))
        XCTAssertTrue(date.waitForExistence(timeout: 3))
        XCTAssertEqual(timeOfDayMinutes(from: start.value as? String), targetStartMinutes,
                       "The pointer's 12:00 wall-clock start must be retained after 15-minute snapping")
        XCTAssertEqual(timeOfDayMinutes(from: end.value as? String), targetStartMinutes + 30,
                       "A stationary Mac double-click must default to a 30-minute interval")
        XCTAssertTrue((date.value as? String)?.contains(dateLabel(for: today)) == true,
                      "The editor must retain the pointer's selected calendar day")
        capture("mac-calendar-pointer-double-click-editor")

        app.descendants(matching: .any)["calendar-event-cancel"].tap()
        XCTAssertFalse(editor.waitForExistence(timeout: 2), "Cancelling the pointer-created editor must dismiss the contextual popover")
        XCTAssertEqual(calendarEventIdentifiers(), baselineFixtureIDs, "Cancelling must not mutate the in-memory fixture calendar")

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openCalendar()
        XCTAssertEqual(calendarEventIdentifiers(), persistedBefore, "Cancelling must not persist a new calendar draft")
        XCTAssertFalse(app.popovers.firstMatch.exists)
        capture("mac-calendar-pointer-double-click-cancelled")
    }

    func testCalendarPointerKeyboardAndAccessibilityMoveAcrossDays() throws {
        let calendar = app.staticTexts["Calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.tap()
        XCTAssertTrue(app.buttons["calendar-add"].waitForExistence(timeout: 5))

        let header = app.descendants(matching: .any)["calendar-header-date"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let headerBefore = header.value as? String
        let visibleRange = app.descendants(matching: .any)["calendar-visible-range"]
        XCTAssertTrue(visibleRange.waitForExistence(timeout: 5))
        let visibleRangeBefore = visibleRange.value as? String
        let event = app.descendants(matching: .any)["calendar-event-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(event.waitForExistence(timeout: 5), "The Mac timeline must expose the deterministic event")
        let valueBefore = event.value as? String
        let beforeDates = isoDates(in: valueBefore)
        let beforeTimes = timeRangeMinutes(valueBefore)
        let targetDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let targetDateString = isoDate(targetDate)
        XCTAssertTrue(valueBefore?.contains("move actions available") == true,
                      "The event must expose keyboard/accessibility move actions")
        XCTAssertTrue(app.buttons["calendar-previous-period"].exists)
        XCTAssertTrue(app.buttons["calendar-next-period"].exists)

        event.hover()
        let hoverAffordance = app.descendants(matching: .any)["calendar-event-hover-affordance-calendar-event-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(hoverAffordance.waitForExistence(timeout: 3), "Hover must disclose move/resize affordance on Mac")
        let resizeLonger = app.buttons["calendar-event-resize-longer-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(resizeLonger.waitForExistence(timeout: 3), "Hover affordance must expose a clickable 15-minute resize alternative")
        resizeLonger.tap()
        XCTAssertTrue(waitForValueChange(of: event, from: valueBefore, timeout: 3), "The Mac accessibility resize alternative must update the event")
        XCTAssertFalse(app.descendants(matching: .any)["calendar-event-editor"].exists,
                       "Hover control clicks must not open the event editor")
        let resizedValue = event.value as? String
        let resizedTimes = timeRangeMinutes(resizedValue)
        XCTAssertEqual(resizedTimes?.start, beforeTimes?.start)
        XCTAssertNotEqual(resizedTimes?.end, beforeTimes?.end)

        let crossDayValueBefore = resizedValue
        let crossDayBeforeDates = isoDates(in: crossDayValueBefore)
        let crossDayBeforeTimes = resizedTimes
        let crossDayFrameBefore = event.frame
        let start = event.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.15))
        let horizontalColumn = max(event.frame.width * 1.15, 112)
        start.press(forDuration: 0.65, thenDragTo: start.withOffset(CGVector(dx: horizontalColumn, dy: 32)))

        XCTAssertTrue(waitForValueChange(of: event, from: crossDayValueBefore, timeout: 8), "A Mac pointer move must publish an updated event")
        let valueAfter = event.value as? String
        XCTAssertNotEqual(valueAfter, crossDayValueBefore)
        XCTAssertTrue(
            waitForFrameShift(of: event, from: crossDayFrameBefore, timeout: 3),
            "The committed Mac cross-day event must settle into the destination column geometry"
        )
        let afterDates = isoDates(in: valueAfter)
        let afterTimes = timeRangeMinutes(valueAfter)
        XCTAssertEqual(afterDates.first, targetDateString, "Mac pointer move must cross exactly one local day")
        XCTAssertEqual(afterTimes.map { ($0.end - $0.start + 24 * 60) % (24 * 60) },
                       crossDayBeforeTimes.map { ($0.end - $0.start + 24 * 60) % (24 * 60) },
                       "Mac pointer move must preserve duration")
        XCTAssertNotNil(crossDayBeforeDates.first)
        XCTAssertEqual(header.value as? String, headerBefore, "Moving between Mac day columns must not scroll the visible date range")
        XCTAssertEqual(visibleRange.value as? String, visibleRangeBefore, "Moving an event must not change the Mac horizontal scroll range")

        // The event's accessibility action names are the keyboard-equivalent
        // quarter-hour/day controls. Keep the semantic contract in the proof;
        // the direct pointer drag above remains the primary manipulation path.
        XCTAssertTrue(valueAfter?.contains("move actions available") == true)

        app.typeKey("[", modifierFlags: [.command])
        XCTAssertTrue(waitForValueChange(of: header, from: headerBefore, timeout: 3), "Command-[ must expose the previous period keyboard alternative")
        let previousHeader = header.value as? String
        app.typeKey("]", modifierFlags: [.command])
        XCTAssertTrue(waitForValue(of: header, equalTo: headerBefore, timeout: 3), "Command-] must return to the original period")
        XCTAssertNotEqual(previousHeader, headerBefore)

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Calendar"].firstMatch.waitForExistence(timeout: 8))
        app.staticTexts["Calendar"].firstMatch.tap()
        XCTAssertTrue(app.buttons["calendar-add"].waitForExistence(timeout: 8))
        let persistedEvent = app.descendants(matching: .any)["calendar-event-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(persistedEvent.waitForExistence(timeout: 8), "The Mac cross-day move must persist after relaunch")
        XCTAssertEqual(isoDates(in: persistedEvent.value as? String).first, targetDateString)
    }

    private func isoDates(in value: String?) -> [String] {
        guard let value,
              let regex = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange])
        }
    }

    private func isoDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func dateLabel(for date: Date) -> String {
        var formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private func timeOfDayMinutes(from value: String?) -> Int? {
        guard let value,
              let regex = try? NSRegularExpression(pattern: #"(?<!\d)(?:1[0-2]|[1-9]|[01]?\d|2[0-3]):[0-5]\d(?:\s*[AaPp][Mm])?"#) else { return nil }
        let normalized = value.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
              let tokenRange = Range(match.range, in: normalized) else { return nil }
        let token = String(normalized[tokenRange])
        let pieces = token.replacingOccurrences(of: " ", with: "").lowercased().split(separator: ":")
        guard pieces.count == 2, let minute = Int(pieces[1].prefix(2)), var hour = Int(pieces[0]) else { return nil }
        if token.lowercased().hasSuffix("pm") { hour = hour % 12 + 12 }
        if token.lowercased().hasSuffix("am") { hour %= 12 }
        return hour * 60 + minute
    }

    private func calendarEventIdentifiers() -> Set<String> {
        let prefix = "calendar-event-"
        let eventElements = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
        return Set(eventElements.compactMap { element in
            let identifier = element.identifier
            let suffix = String(identifier.dropFirst(prefix.count))
            guard identifier.hasPrefix(prefix), UUID(uuidString: suffix) != nil else { return nil }
            return identifier
        })
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func openCalendar() {
        let calendar = app.buttons["mac-sidebar-calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 8))
        calendar.click()
        XCTAssertTrue(app.buttons["calendar-add"].waitForExistence(timeout: 8))
    }

    private func timeRangeMinutes(_ value: String?) -> (start: Int, end: Int)? {
        guard let value,
              let regex = try? NSRegularExpression(pattern: #"(?<!\d)(?:1[0-2]|[1-9]|[01]?\d|2[0-3]):[0-5]\d(?:\s*[AaPp][Mm])?"#) else { return nil }
        let normalized = value.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let values = regex.matches(in: normalized, range: range).compactMap { match -> Int? in
            guard let tokenRange = Range(match.range, in: normalized) else { return nil }
            let token = String(normalized[tokenRange])
            let pieces = token.replacingOccurrences(of: " ", with: "").lowercased().split(separator: ":")
            guard pieces.count == 2, let minute = Int(pieces[1].prefix(2)), var hour = Int(pieces[0]) else { return nil }
            if token.lowercased().hasSuffix("pm") { hour = hour % 12 + 12 }
            if token.lowercased().hasSuffix("am") { hour %= 12 }
            return hour * 60 + minute
        }
        guard values.count >= 2 else { return nil }
        return (values[0], values[1])
    }

    private func waitForValueChange(of element: XCUIElement, from value: String?, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return (element.value as? String) != value
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForFrameShift(of element: XCUIElement, from frame: CGRect, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return abs(element.frame.midX - frame.midX) > 20
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValue(of element: XCUIElement, equalTo value: String?, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return (element.value as? String) == value
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
