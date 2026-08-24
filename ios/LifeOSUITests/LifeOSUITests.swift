import XCTest

final class LifeOSUITests: XCTestCase {
    private let deterministicDeepWorkID = "10000000-0000-0000-0000-000000000001"
    private let deterministicDesignReviewID = "10000000-0000-0000-0000-000000000002"
    private let exposedPointInElement = CGVector(dx: 0.12, dy: 0.15)
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceLightMode"]
        app.launch()
        dismissSystemPromptsIfPresent()
        let viewport = app.windows.firstMatch.frame
        XCTAssertGreaterThan(viewport.width, 375, "Viewport must support the primary iPhone layout width")
        XCTAssertGreaterThan(viewport.height, viewport.width, "Primary viewport assertions require portrait orientation")
    }

    func testPrimaryScreenshotsAndAccessibility() throws {
        capture("overview")
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["overview-screen"].waitForExistence(timeout: 5))

        XCTAssertFalse(app.buttons["Usage"].exists)
        let usageCard = app.buttons["account-usage-link"]
        XCTAssertTrue(usageCard.waitForExistence(timeout: 5))
        XCTAssertTrue(tap(usageCard, untilVisible: app.scrollViews["usage-screen"]))
        capture("usage")

        app.buttons["usage-back"].tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5), "Usage back must return to the Home route")
        XCTAssertTrue(app.scrollViews["overview-screen"].waitForExistence(timeout: 5), "Usage back must restore the Home overview before selecting Calendar")
        let calendarTab = app.buttons["Calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 5))
        XCTAssertTrue(tap(calendarTab, untilVisible: app.buttons["calendar-add"]))
        XCTAssertTrue(app.buttons["calendar-view-picker"].waitForExistence(timeout: 5), "Calendar route must expose its compact view-mode control")
        XCTAssertTrue(app.descendants(matching: .any)["calendar-pager"].waitForExistence(timeout: 5), "Calendar timeline route must expose the three-day pager")
        capture("calendar-three-day")
        let monthMenuItem = app.buttons["Month view"]
        XCTAssertTrue(tap(app.buttons["calendar-view-picker"], untilVisible: monthMenuItem), "Calendar view menu must expose its Month view item")
        monthMenuItem.tap()
        let monthCell = app.descendants(matching: .any)["calendar-month-cell-\(calendarISODate(Calendar.current.startOfDay(for: Date())))"]
        XCTAssertTrue(monthCell.waitForExistence(timeout: 5), "Month view must expose the current calendar month surface")
        capture("calendar-month")

        let moreTab = app.buttons["More"]
        XCTAssertTrue(moreTab.waitForExistence(timeout: 5))
        moreTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["more-modules-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["more-module-tax"].exists)
        XCTAssertTrue(app.buttons["more-module-settings"].exists)
        XCTAssertFalse(app.buttons["more-module-ai-usage"].exists)
        XCTAssertFalse(app.buttons["more-module-bank-connections"].exists)
        app.buttons["more-module-tax"].tap()
        XCTAssertTrue(app.staticTexts["Tax Documents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["import-tax-pdf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stored only on this device. Candidates are rule-based, not tax advice, and nothing is filed automatically."].waitForExistence(timeout: 5))
        capture("tax-documents")

        app.navigationBars.buttons["More"].tap()
        app.buttons["more-module-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings-category-providers"].waitForExistence(timeout: 5))
        capture("settings")
    }

    func testCompactTabBarSelectionAndRoutes() throws {
        let tabLabels = ["Home", "Calendar", "Finance", "Fitness", "More"]
        for label in tabLabels {
            XCTAssertTrue(
                app.buttons[label].waitForExistence(timeout: 5),
                "Compact tab bar must expose \(label)"
            )
        }

        let home = app.buttons["main-tab-home"]
        XCTAssertEqual(home.value as? String, "Selected", "Home must start selected")
        XCTAssertTrue(app.scrollViews["overview-screen"].waitForExistence(timeout: 5))

        // Repeating the current selection must leave the route and selected state intact.
        home.tap()
        XCTAssertTrue(app.scrollViews["overview-screen"].waitForExistence(timeout: 2))
        XCTAssertEqual(home.value as? String, "Selected")

        let finance = app.buttons["main-tab-finance"]
        finance.tap()
        XCTAssertTrue(app.descendants(matching: .any)["finance-view"].waitForExistence(timeout: 5))
        XCTAssertEqual(finance.value as? String, "Selected")

        home.tap()
        XCTAssertTrue(app.scrollViews["overview-screen"].waitForExistence(timeout: 5))
        XCTAssertEqual(home.value as? String, "Selected")

        // A repeated selected tap must not reset the Home route.
        home.tap()
        XCTAssertTrue(app.scrollViews["overview-screen"].waitForExistence(timeout: 2))
        XCTAssertEqual(home.value as? String, "Selected")
    }

    /// The shell gives the custom bar its own physical bottom row, so each
    /// route must end above the bar's live top edge rather than relying on a
    /// device-specific estimate.
    /// Passive endpoint surfaces use frame containment; actual buttons also
    /// prove hittability. The boundary comes from live accessibility frames,
    /// so this remains valid across supported portrait phone sizes.
    func testPrimaryRoutesReachTrailingContentAboveCustomTabBar() throws {
        assertTabBarFitsWindow()
        assertTrailingElementAboveTabBar(
            "overview-finance-link",
            route: "Home link",
            scrollView: app.scrollViews["overview-screen"],
            requiresHittable: true
        )

        app.buttons["main-tab-calendar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calendar-pager"].waitForExistence(timeout: 5))
        let calendarVerticalScrolls = app.scrollViews.matching(identifier: "calendar-vertical-timeline-scroll")
        let calendarVerticalScroll = calendarVerticalScrolls.firstMatch
        XCTAssertTrue(calendarVerticalScroll.waitForExistence(timeout: 5))
        XCTAssertEqual(
            calendarVerticalScrolls.count,
            1,
            "Calendar must expose exactly one active vertical timeline ScrollView"
        )
        let calendarEndpointMatches = app.staticTexts.matching(identifier: "calendar-timeline-end")
        XCTAssertTrue(calendarEndpointMatches.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(
            calendarEndpointMatches.count,
            1,
            "Calendar must expose exactly one active 24:00 endpoint"
        )
        attachCalendarDiagnostic(
            "Calendar vertical scroll diagnostics",
            "frame=\(String(describing: calendarVerticalScroll.frame))\n" +
                "hittable=\(calendarVerticalScroll.isHittable) enabled=\(calendarVerticalScroll.isEnabled)\n" +
                "value=\(String(describing: calendarVerticalScroll.value))\n" +
                "endpoint=\(String(describing: calendarEndpointMatches.firstMatch.frame))"
        )
        waitForStableFrame(of: calendarEndpointMatches.firstMatch)
        // 24:00 is a passive label; its complete frame proves the finite
        // Calendar timeline still reaches the trailing endpoint.
        assertTrailingElementAboveTabBar(
            "calendar-timeline-end",
            route: "Calendar 24:00",
            scrollView: calendarVerticalScroll,
            maxSwipes: 12,
            xFraction: 0.08
        )

        app.buttons["main-tab-finance"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["finance-view"].waitForExistence(timeout: 5))
        // The Accounts card is the final Finance surface and is passive.
        assertTrailingElementAboveTabBar(
            "finance-accounts",
            route: "Finance final card",
            scrollView: app.scrollViews["finance-view"]
        )

        app.buttons["main-tab-fitness"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["fitness-view"].waitForExistence(timeout: 5))
        // Health Monitor is the last relevant NavigationLink; prove it while
        // the route is at its natural top position before seeking the passive
        // final surface below it.
        assertTrailingElementAboveTabBar(
            "fitness-core-health-monitor-card",
            route: "Fitness final relevant button",
            maxSwipes: 14,
            requiresHittable: true
        )
        // Timeline is the final Fitness surface and is checked by complete
        // frame containment rather than hittability.
        assertTrailingElementAboveTabBar(
            "fitness-core-timeline",
            route: "Fitness final surface",
            maxSwipes: 14
        )

        app.buttons["main-tab-more"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["more-modules-screen"].waitForExistence(timeout: 5))
        assertTrailingElementAboveTabBar(
            "more-module-settings",
            route: "More Settings action",
            scrollView: app.scrollViews["more-modules-screen"],
            requiresHittable: true
        )

        app.buttons["more-module-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        assertTrailingElementAboveTabBar(
            "settings-category-privacy",
            route: "Settings final button",
            scrollView: app.scrollViews["settings-hub"],
            requiresHittable: true
        )
        assertTrailingElementAboveTabBar(
            "settings-provider-keys-disclaimer",
            route: "Settings provider-keys disclaimer",
            scrollView: app.scrollViews["settings-hub"]
        )
    }

    /// The Calendar pager keeps five page views mounted, but only the center
    /// page may own vertical scrolling. Prove one native swipe changes the
    /// active 24:00 frame before the route-wide endpoint assertion runs.
    func testCalendarVerticalTimelineSwipeMovesEndpoint() throws {
        app.buttons["main-tab-calendar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calendar-pager"].waitForExistence(timeout: 5))

        let scrollViews = app.scrollViews.matching(identifier: "calendar-vertical-timeline-scroll")
        let scrollView = scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        XCTAssertEqual(scrollViews.count, 1, "Only the active Calendar page may expose the vertical ScrollView")
        XCTAssertTrue(
            scrollView.isEnabled,
            "Calendar vertical ScrollView must be enabled; frame=\(String(describing: scrollView.frame)), value=\(String(describing: scrollView.value))"
        )
        XCTAssertGreaterThan(scrollView.frame.width, 0, "Calendar vertical ScrollView must have a live width")
        XCTAssertGreaterThan(scrollView.frame.height, 0, "Calendar vertical ScrollView must have a live height")

        let visibleAllDayLanes = app.descendants(matching: .any)
            .matching(identifier: "calendar-all-day-lane")
            .allElementsBoundByIndex
            .filter {
                let intersection = $0.frame.intersection(app.windows.firstMatch.frame)
                return !intersection.isNull && !intersection.isEmpty
            }
        XCTAssertEqual(visibleAllDayLanes.count, 1, "Only the active Calendar page may expose a visible all-day lane")
        let allDayLane = try XCTUnwrap(visibleAllDayLanes.first)
        XCTAssertLessThanOrEqual(
            allDayLane.frame.height,
            30,
            "An empty/single-row all-day lane must stay the height of one compact hourly-style row"
        )
        XCTAssertEqual(allDayLane.value as? String, "0 events, 1 row")

        let endpoint = app.staticTexts["calendar-timeline-end"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts.matching(identifier: "calendar-timeline-end").count,
            1,
            "Only the active Calendar page may expose the 24:00 endpoint"
        )
        attachCalendarDiagnostic(
            "Focused Calendar vertical scroll state",
            "frame=\(String(describing: scrollView.frame))\n" +
                "hittable=\(scrollView.isHittable) enabled=\(scrollView.isEnabled)\n" +
                "value=\(String(describing: scrollView.value))\n" +
                "endpoint=\(String(describing: endpoint.frame))"
        )
        waitForStableFrame(of: endpoint)
        let initialY = endpoint.frame.minY

        // Exercise native vertical ownership directly over both interactive
        // mutation surfaces while they are genuinely visible. Do not scroll
        // them offscreen and then clamp a stale frame into empty timeline
        // space, because that would not prove gesture arbitration.
        let deterministicResizeIdentifier = "calendar-event-resize-\(deterministicDeepWorkID)"
        let deterministicResize = visibleElement(identifier: deterministicResizeIdentifier)
        XCTAssertTrue(
            deterministicResize.waitForExistence(timeout: 5),
            "The deterministic resize handle must be available for the over-handle vertical pan proof"
        )
        swipeUp(overIdentifier: deterministicResizeIdentifier, in: scrollView)

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in endpoint.frame.minY < initialY - 1 },
            object: endpoint
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [moved], timeout: 2),
            .completed,
            "A vertical drag inside Calendar's live ScrollView must move 24:00 upward; " +
                "scroll=\(String(describing: scrollView.frame)), endpoint=\(String(describing: endpoint.frame))"
        )

        let afterResizeSwipeY = endpoint.frame.minY
        let deterministicEventIdentifier = "calendar-event-\(deterministicDeepWorkID)"
        let deterministicEvent = visibleElement(identifier: deterministicEventIdentifier)
        XCTAssertTrue(
            deterministicEvent.waitForExistence(timeout: 5),
            "The deterministic event must be available for the over-card vertical pan proof"
        )
        swipeUp(overIdentifier: deterministicEventIdentifier, in: scrollView)
        let movedAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in endpoint.frame.minY < afterResizeSwipeY - 1 },
            object: endpoint
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [movedAgain], timeout: 2),
            .completed,
            "A second vertical drag must continue moving 24:00 upward; " +
                "first=\(afterResizeSwipeY), endpoint=\(String(describing: endpoint.frame))"
        )
    }

    func testCalendarTimedSurfaceVerticalSwipeDoesNotPage() throws {
        app.buttons["main-tab-calendar"].tap()
        let pager = app.descendants(matching: .any)["calendar-pager"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let scrollView = app.scrollViews["calendar-vertical-timeline-scroll"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        let endpoint = app.staticTexts["calendar-timeline-end"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))

        let committedPage = try XCTUnwrap(pager.value as? String, "The calendar pager must expose a committed page value")
        let initialEndpointY = endpoint.frame.minY
        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.72))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.28))
        start.press(forDuration: 0.1, thenDragTo: end)

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in endpoint.frame.minY < initialEndpointY - 1 },
            object: endpoint
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [moved], timeout: 2),
            .completed,
            "A vertical drag starting on the timed surface must remain native vertical scrolling"
        )
        XCTAssertEqual(
            try XCTUnwrap(pager.value as? String),
            committedPage,
            "A vertical timed-surface drag must not commit a horizontal day"
        )
    }

    func testCalendarPagerUsesAllDayAndTimedSurfacesButNotTheGutter() throws {
        app.buttons["main-tab-calendar"].tap()
        let pager = app.descendants(matching: .any)["calendar-pager"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let today = calendarISODate(Calendar.current.startOfDay(for: Date()))
        XCTAssertTrue(waitForCalendarPagerCommittedDate(today, element: pager))

        let nextPage = calendarISODate(try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))))
        let allDayLane = app.descendants(matching: .any)["calendar-all-day-lane"]
        XCTAssertTrue(allDayLane.waitForExistence(timeout: 5))
        allDayLane.swipeLeft()
        XCTAssertTrue(
            waitForCalendarPagerCommittedDate(nextPage, element: pager),
            "A horizontal swipe beginning in the all-day surface must page"
        )

        app.buttons["calendar-today"].tap()
        XCTAssertTrue(waitForCalendarPagerCommittedDate(today, element: pager))
        let timeline = app.scrollViews["calendar-vertical-timeline-scroll"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let timedStart = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.78))
        let timedEnd = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.78))
        timedStart.press(forDuration: 0.1, thenDragTo: timedEnd)
        XCTAssertTrue(
            waitForCalendarPagerCommittedDate(nextPage, element: pager),
            "A horizontal swipe beginning in the timed surface must page"
        )

        app.buttons["calendar-today"].tap()
        XCTAssertTrue(waitForCalendarPagerCommittedDate(today, element: pager))
        let gutterStart = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let gutterEnd = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
        gutterStart.press(forDuration: 0.1, thenDragTo: gutterEnd)
        XCTAssertTrue(
            waitForCalendarPagerCommittedDate(today, element: pager),
            "A horizontal drag beginning in the 52pt gutter must not page"
        )
    }

    func testCalendarEmptyAllDayDoubleTapCreatesLocalDayEvent() throws {
        app.buttons["main-tab-calendar"].tap()
        let pager = app.descendants(matching: .any)["calendar-pager"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5))

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayValue = calendarISODate(today)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let nextDayValue = calendarISODate(nextDay)
        let emptyCell = app.descendants(matching: .any)["calendar-empty-all-day-\(todayValue)"]
        XCTAssertTrue(emptyCell.waitForExistence(timeout: 5), "The trailing all-day row must expose today's empty cell")
        emptyCell.doubleTap()

        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["calendar-event-all-day-summary"].waitForExistence(timeout: 5),
            "Double-tap creation must open an all-day editor, not a timed editor"
        )
        let title = app.textFields["calendar-event-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Phase 2A all-day")
        app.buttons["calendar-event-save"].tap()

        let lane = app.descendants(matching: .any)["calendar-all-day-lane"]
        XCTAssertTrue(lane.waitForExistence(timeout: 5))
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let lane = object as? XCUIElement else { return false }
                return (lane.value as? String) == "1 event, 2 rows"
            },
            object: lane
        )
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 5), .completed)

        let eventCandidates = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar-all-day-event-"))
            .allElementsBoundByIndex
        let created = try XCTUnwrap(
            eventCandidates.first { $0.label.contains("Phase 2A all-day") },
            "The saved all-day event must render in the all-day lane"
        )
        XCTAssertTrue(
            created.value as? String == "\(todayValue) to \(nextDayValue)",
            "The created event must use local midnight-to-next-midnight bounds"
        )
    }

    func testFitnessSourceReviewDismissesSheetAndReachesHealthSettings() throws {
        openFitnessRouteAndAssertTodaySurface()

        let sourceStatus = app.buttons["Health source status"]
        XCTAssertTrue(sourceStatus.waitForExistence(timeout: 5), "Fitness must expose the source status action")
        sourceStatus.tap()

        let sourceGate = app.descendants(matching: .any)["fitness-health-source-gate"]
        XCTAssertTrue(sourceGate.waitForExistence(timeout: 5), "The source explainer must open")
        let review = app.buttons["fitness-source-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "The source explainer action must be exposed")
        review.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8), "Source review must leave Fitness for the app Settings workflow")
        XCTAssertFalse(sourceGate.waitForExistence(timeout: 1), "Source review must dismiss the source explainer")
        let healthCategory = app.buttons["settings-category-health"]
        XCTAssertTrue(healthCategory.waitForExistence(timeout: 5), "Settings must expose the substantive Health & devices category")
        healthCategory.tap()
        XCTAssertTrue(app.navigationBars["Health & Devices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-health-connection-permission"].waitForExistence(timeout: 5))
    }

    /// Rendered iPhone evidence for the typed IMG_0402–IMG_0404 sleep tranche.
    /// This deliberately enters through the real Today card instead of a
    /// test-only detail initializer, then records the timeline and lower
    /// schedule/trend content in both appearances.
    func testFitnessSleepDetailLightDarkEvidence() throws {
        for appearance in ["light", "dark"] {
            app.terminate()
            app.launchArguments = baseLaunchArguments + [
                appearance == "dark" ? "-LifeOSForceDarkMode" : "-LifeOSForceLightMode"
            ]
            app.launch()
            dismissSystemPromptsIfPresent()

            openFitnessRouteAndAssertTodaySurface()

            let sleepCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Sleep")).firstMatch
            for _ in 0..<4 where !sleepCard.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(sleepCard.waitForExistence(timeout: 5), "Fitness Today must expose the source-aware Sleep card")
            sleepCard.tap()

            let timeline = app.descendants(matching: .any)["fitness-sleep-timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Sleep detail must render the typed observed-night timeline")
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "DEMO")).firstMatch.exists,
                "Sleep fixture evidence must remain visibly disclosed as demo data"
            )
            capture("\(appearance)-fitness-sleep-timeline")

            let trends = app.descendants(matching: .any)["fitness-sleep-trends"]
            for _ in 0..<8 where !trends.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(trends.waitForExistence(timeout: 5), "Sleep detail must expose explicit source history ranges")
            XCTAssertTrue(app.descendants(matching: .any)["fitness-sleep-schedule-card"].exists)
            capture("\(appearance)-fitness-sleep-schedule-trends")
        }
    }

    func testDarkModeScreenshots() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))
        capture("dark-overview")

        XCTAssertFalse(app.buttons["Usage"].exists)
        let usageCard = app.buttons["account-usage-link"]
        XCTAssertTrue(usageCard.waitForExistence(timeout: 5))
        XCTAssertTrue(tap(usageCard, untilVisible: app.scrollViews["usage-screen"]))
        capture("dark-usage")

        app.buttons["usage-back"].tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5), "Usage back must return to the Home route")
        XCTAssertTrue(app.scrollViews["overview-screen"].waitForExistence(timeout: 5), "Usage back must restore the Home overview before selecting Calendar")

        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        XCTAssertTrue(app.buttons["calendar-view-picker"].waitForExistence(timeout: 5), "Calendar route must expose its compact view-mode control")
        XCTAssertTrue(app.descendants(matching: .any)["calendar-pager"].waitForExistence(timeout: 5), "Calendar timeline route must expose the three-day pager")
        capture("dark-calendar-three-day")
        let monthMenuItem = app.buttons["Month view"]
        XCTAssertTrue(tap(app.buttons["calendar-view-picker"], untilVisible: monthMenuItem), "Calendar view menu must expose its Month view item")
        monthMenuItem.tap()
        let monthCell = app.descendants(matching: .any)["calendar-month-cell-\(calendarISODate(Calendar.current.startOfDay(for: Date())))"]
        XCTAssertTrue(monthCell.waitForExistence(timeout: 5), "Month view must expose the current calendar month surface")
        capture("dark-calendar-month")

        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["more-module-tax"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["more-module-settings"].exists)
        XCTAssertFalse(app.buttons["more-module-ai-usage"].exists)
        app.buttons["more-module-tax"].tap()
        XCTAssertTrue(app.buttons["import-tax-pdf"].waitForExistence(timeout: 5))
        capture("dark-tax-documents")

        app.navigationBars.buttons["More"].tap()
        app.buttons["more-module-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings-category-health"].waitForExistence(timeout: 5))
        capture("dark-settings")
    }

    /// The Helio Settings surface is a truth/accessibility contract, not a
    /// pixel fixture: the current build must expose the authority chain,
    /// permission state, capability inventory, and explicit battery boundary.
    func testHelioSettingsSurfaceExposesTruthfulStateAndAccessibility() throws {
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        let settings = app.buttons["more-module-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let health = app.buttons["settings-category-health"]
        XCTAssertTrue(health.waitForExistence(timeout: 5))
        health.tap()
        XCTAssertTrue(app.navigationBars["Health & Devices"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.descendants(matching: .any)["settings-health-authority-chain"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-health-connection-permission"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-health-capability-inventory"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-health-device-management"].waitForExistence(timeout: 5))

        let connection = app.descendants(matching: .any)["settings-status-current-connection"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertTrue(connection.label.localizedCaseInsensitiveContains("Not configured"))

        let battery = app.descendants(matching: .any)["settings-status-battery"]
        XCTAssertTrue(battery.waitForExistence(timeout: 5))
        XCTAssertTrue(battery.label.localizedCaseInsensitiveContains("Unavailable"))
        XCTAssertFalse(battery.label.localizedCaseInsensitiveContains("Observed"), "Unavailable battery must not be presented as observed")
    }

    func testCalendarPagerCommitsOneDaySlideAndCancelsShortDrag() throws {
        let calendarTab = app.buttons["Calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 5))

        let pager = app.descendants(matching: .any)["calendar-pager"]
        XCTAssertTrue(tap(calendarTab, untilVisible: pager))
        XCTAssertTrue(pager.waitForExistence(timeout: 5))

        let header = app.buttons["calendar-month-toggle"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let today = calendarISODate(Calendar.current.startOfDay(for: Date()))
        let initialHeaderSettled = waitForCalendarHeaderValue(today, element: header)
        if !initialHeaderSettled {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "calendar-pager-initial-header-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(
            initialHeaderSettled,
            "Initial calendar header should expose today's fixture anchor (value=\(String(describing: header.value).debugDescription), label=\(header.label.debugDescription), exists=\(header.exists), hittable=\(header.isHittable))"
        )
        XCTAssertTrue(
            waitForCalendarPagerCommittedDate(today, element: pager),
            "The pager must expose its committed page independently of the preview header"
        )

        let anchor = Calendar.current.startOfDay(for: Date())
        let nextPage = calendarISODate(Calendar.current.date(byAdding: .day, value: 1, to: anchor)!)
        pager.swipeLeft()
        XCTAssertTrue(
            waitForCalendarPagerCommittedDate(nextPage, element: pager),
            "A committed swipe must update the pager's settled page/content state"
        )
        XCTAssertTrue(waitForCalendarHeaderValue(nextPage, element: header), "A committed swipe must advance exactly one day")

        // A short horizontal drag should not cross the pager's paging threshold.
        let shortDragStart = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let shortDragTarget = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.5))
        shortDragStart.press(forDuration: 0.1, thenDragTo: shortDragTarget)
        XCTAssertTrue(
            waitForCalendarPagerCommittedDate(nextPage, element: pager, timeout: 2),
            "A cancelled short drag must preserve the committed pager content"
        )
        XCTAssertTrue(waitForCalendarHeaderValue(nextPage, element: header, timeout: 2), "A cancelled short drag must not drift the committed date")

        // A two-touch pinch belongs to the calendar's hour-spacing gesture;
        // it must never be interpreted as a one-page horizontal commit.
        pager.pinch(withScale: 1.12, velocity: 0.4)
        XCTAssertTrue(
            waitForCalendarPagerCommittedDate(nextPage, element: pager, timeout: 2),
            "Pinch/two-touch input must not page the calendar"
        )

        app.buttons["calendar-today"].tap()
        XCTAssertTrue(waitForCalendarPagerCommittedDate(today, element: pager), "Today must restore committed pager content")
        XCTAssertTrue(waitForCalendarHeaderValue(today, element: header), "Today must return to the fixture anchor")
    }

    func testCalendarExpandedMonthRendersDateCells() throws {
        let calendarTab = app.buttons["Calendar"]
        let pager = app.descendants(matching: .any)["calendar-pager"]
        XCTAssertTrue(tap(calendarTab, untilVisible: pager))

        let monthToggle = app.buttons["calendar-month-toggle"]
        XCTAssertTrue(monthToggle.waitForExistence(timeout: 5))
        monthToggle.tap()

        let todayID = "calendar-expanded-date-\(calendarISODate(Calendar.current.startOfDay(for: Date())))"
        let todayCell = app.descendants(matching: .any)[todayID]
        XCTAssertTrue(todayCell.waitForExistence(timeout: 5), "Expanded month must render the current date cell")

        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        let gridStart = Calendar.current.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let firstGridCell = app.descendants(matching: .any)[
            "calendar-expanded-date-\(calendarISODate(Calendar.current.startOfDay(for: gridStart)))"
        ]
        XCTAssertTrue(firstGridCell.waitForExistence(timeout: 5), "Expanded month must render leading out-of-month dates")
    }

    func testCalendarMonthEventDragTargetsNextCell() throws {
        let calendarTab = app.buttons["Calendar"]
        XCTAssertTrue(tap(calendarTab, untilVisible: app.buttons["calendar-add"]))
        selectCalendarMonthView()

        let source = app.descendants(matching: .any)["calendar-month-event-\(deterministicDeepWorkID)"]
        XCTAssertTrue(source.waitForExistence(timeout: 5), "Month view must expose the deterministic event chip")
        let targetDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let targetComponents = Calendar.current.dateComponents([.year, .month, .day], from: targetDay)
        let targetID = String(format: "calendar-month-cell-%04d-%02d-%02d", targetComponents.year ?? 0, targetComponents.month ?? 0, targetComponents.day ?? 0)
        let target = app.descendants(matching: .any)[targetID]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Month view must expose the next day cell")

        let sourcePoint = source.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.50))
        let targetPoint = target.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.42))
        let valueBefore = source.value as? String
        sourcePoint.press(forDuration: 0.65, thenDragTo: targetPoint)

        let destination = app.descendants(matching: .any)["calendar-month-event-\(deterministicDeepWorkID)"]
        XCTAssertTrue(destination.waitForExistence(timeout: 8), "The month event must remain exposed after a drop")
        XCTAssertTrue(waitForValueChange(of: destination, from: valueBefore, timeout: 8),
                      "The month drop must publish a changed local interval")
        let movedValue = destination.value as? String
        XCTAssertTrue(movedValue?.contains(calendarISODate(targetDay)) == true,
                      "The moved event must expose the target local date (value=\(String(describing: movedValue)))")

        // A month move is a local durable mutation, not only a transient view
        // preview. Relaunch without visual fixtures so the assertion exercises
        // CalendarCoordinator.load() and the persisted snapshot path.
        app.terminate()
        app.launchArguments = persistedLaunchArguments
        app.launch()
        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 8))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        selectCalendarMonthView()
        let persisted = app.descendants(matching: .any)["calendar-month-event-\(deterministicDeepWorkID)"]
        XCTAssertTrue(persisted.waitForExistence(timeout: 8), "The moved month event must survive relaunch")
        XCTAssertTrue((persisted.value as? String)?.contains(calendarISODate(targetDay)) == true,
                      "The persisted event must retain the target local date (value=\(String(describing: persisted.value)))")
    }

    func testCalendarMonthEventDropOutsideGridCancelsWithoutCommit() throws {
        let calendarTab = app.buttons["Calendar"]
        XCTAssertTrue(tap(calendarTab, untilVisible: app.buttons["calendar-add"]))
        selectCalendarMonthView()

        let source = app.descendants(matching: .any)["calendar-month-event-\(deterministicDeepWorkID)"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let valueBefore = source.value as? String
        let sourcePoint = source.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.50))
        // The month header is deliberately outside every day-cell frame while
        // remaining inside the app window, making this a stable invalid drop
        // target for the cancellation contract.
        let outsideGrid = app.buttons["calendar-month-toggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        sourcePoint.press(forDuration: 0.65, thenDragTo: outsideGrid)

        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertEqual(source.value as? String, valueBefore,
                       "Dropping outside the month cells must restore the original event and avoid a stale preview commit")
        XCTAssertFalse(app.descendants(matching: .any)["calendar-month-move-status"].exists,
                       "A cancelled outside-grid drop must not report a successful move")
    }

    func testCalendarDoubleTapCreationOpensEditorAndPagerStillWorks() throws {
        let calendarTab = app.buttons["Calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 5))
        let pager = app.descendants(matching: .any)["calendar-pager"]
        XCTAssertTrue(tap(calendarTab, untilVisible: pager))

        let today = Calendar.current.startOfDay(for: Date())
        let emptyGrid = visibleElement(identifier: "calendar-empty-timed-grid-\(calendarISODate(today))")
        XCTAssertTrue(emptyGrid.waitForExistence(timeout: 5), "The timed grid must expose a deliberate creation target")

        // The grid is taller than the visible vertical viewport. Use a point in
        // that viewport rather than a normalized point in the full-day child
        // frame; this avoids pressing an offscreen portion of the ScrollView.
        let creationPoint = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.76))
        creationPoint.tap()
        XCTAssertFalse(app.navigationBars["New event"].exists, "A single empty-grid tap must remain inert")
        creationPoint.doubleTap()
        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 5), "A double-tap on an empty grid must open the editor")
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-editor"].exists)
        let proposedStart = app.descendants(matching: .any)["calendar-event-start"]
        let proposedEnd = app.descendants(matching: .any)["calendar-event-end"]
        XCTAssertTrue(proposedStart.waitForExistence(timeout: 5))
        XCTAssertTrue(proposedEnd.waitForExistence(timeout: 5))
        let rawAXValue = String(describing: proposedStart.value)
        let rawAXLabel = proposedStart.label
        let rawAXStrings = accessibilityStrings(for: proposedStart)
        if let minutes = timeOfDayMinutes(from: rawAXStrings) {
            XCTAssertEqual(
                minutes % 15,
                0,
                "A deliberate creation must snap its proposed start to 15 minutes (AX value=\(rawAXValue.debugDescription), label=\(rawAXLabel.debugDescription), parsedMinutes=\(minutes), AX strings=\(rawAXStrings.map(\.debugDescription).joined(separator: ", ")))"
            )
        } else {
            XCTFail("Could not parse the proposed start time from DatePicker AX value=\(rawAXValue.debugDescription), label=\(rawAXLabel.debugDescription), AX strings=\(rawAXStrings.map(\.debugDescription).joined(separator: ", "))")
        }
        let startStrings = accessibilityStrings(for: proposedStart)
        let endStrings = accessibilityStrings(for: proposedEnd)
        if let startMinutes = timeOfDayMinutes(from: startStrings),
           let endMinutes = timeOfDayMinutes(from: endStrings) {
            XCTAssertEqual(
                (endMinutes - startMinutes + 24 * 60) % (24 * 60),
                30,
                "A stationary double-tap must prefill the exact 30-minute Notion-style selection"
            )
        } else {
            XCTFail("Could not parse the proposed 30-minute start/end range from AX strings")
        }
        app.buttons["Cancel"].tap()

        let header = app.buttons["calendar-month-toggle"]
        let anchor = today
        let nextPage = calendarISODate(Calendar.current.date(byAdding: .day, value: 1, to: anchor)!)
        pager.swipeLeft()
        let pagerAdvanced = waitForCalendarHeaderValue(nextPage, element: header)
        if !pagerAdvanced {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "calendar-pager-after-creation-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(
            pagerAdvanced,
            "Pager must remain usable after deliberate creation (header value=\(String(describing: header.value).debugDescription), label=\(header.label.debugDescription), pager exists=\(pager.exists), hittable=\(pager.isHittable), frame=\(pager.frame))"
        )
    }

    func testCalendarResizeHandleChangesEndWithoutMovingStart() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        let event = visibleElement(identifier: "calendar-event-\(deterministicDeepWorkID)")
        XCTAssertTrue(event.waitForExistence(timeout: 5), "The visible calendar page must expose an editable event")
        tapVisible(event)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-editor"].waitForExistence(timeout: 5))

        let startPicker = datePicker(identifier: "calendar-event-start")
        let endPicker = datePicker(identifier: "calendar-event-end")
        XCTAssertTrue(startPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(endPicker.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(event.waitForExistence(timeout: 5), "The event must reappear after cancelling the editor")

        let eventIdentifier = event.identifier
        let resizeIdentifier = eventIdentifier.replacingOccurrences(of: "calendar-event-", with: "calendar-event-resize-", options: .anchored)
        let resize = visibleElement(identifier: resizeIdentifier)
        XCTAssertTrue(resize.waitForExistence(timeout: 5), "Editable events must expose a resize affordance")
        let valueBeforeResize = event.value as? String
        attachCalendarDiagnostic("Calendar resize before", "value=\(String(describing: valueBeforeResize))\nframe=\(String(describing: event.frame))")
        let handlePoint = resize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handlePoint.press(forDuration: 0.65, thenDragTo: handlePoint.withOffset(CGVector(dx: 0, dy: 32)))

        XCTAssertTrue(waitForValueChange(of: event, from: valueBeforeResize, timeout: 5), "The resized event must publish a changed snapshot")
        let valueAfterResize = event.value as? String
        attachCalendarDiagnostic("Calendar resize after", "value=\(String(describing: valueAfterResize))\nframe=\(String(describing: event.frame))")
        let resizeBeforeRange = timeRangeMinutes(valueBeforeResize)
        let resizeAfterRange = timeRangeMinutes(valueAfterResize)
        XCTAssertNotNil(resizeBeforeRange, "Resize pre-value must expose start/end: \(String(describing: valueBeforeResize))")
        XCTAssertNotNil(resizeAfterRange, "Resize post-value must expose start/end: \(String(describing: valueAfterResize))")
        XCTAssertEqual(resizeAfterRange?.start, resizeBeforeRange?.start, "Resizing the bottom handle must preserve the event start")
        XCTAssertNotEqual(resizeAfterRange?.end, resizeBeforeRange?.end, "Resizing the bottom handle must change the event end")

        app.terminate()
        app.launchArguments = persistedLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()
        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        let persistedResizeEvent = visibleElement(identifier: "calendar-event-\(deterministicDeepWorkID)")
        XCTAssertTrue(persistedResizeEvent.waitForExistence(timeout: 5), "The resized event must persist after relaunch")
        let persistedResizeRange = timeRangeMinutes(persistedResizeEvent.value as? String)
        XCTAssertEqual(persistedResizeRange?.start, resizeAfterRange?.start, "Resized event start must persist after relaunch")
        XCTAssertEqual(persistedResizeRange?.end, resizeAfterRange?.end, "Resized event end must persist after relaunch")
    }

    func testCalendarMoveGestureChangesBothEndsAndPreservesDuration() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        let event = visibleElement(identifier: "calendar-event-\(deterministicDeepWorkID)")
        XCTAssertTrue(event.waitForExistence(timeout: 5), "The visible calendar page must expose an editable event")
        tapVisible(event)
        XCTAssertTrue(app.descendants(matching: .any)["calendar-event-editor"].waitForExistence(timeout: 5))

        let startPicker = datePicker(identifier: "calendar-event-start")
        let endPicker = datePicker(identifier: "calendar-event-end")
        XCTAssertTrue(startPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(endPicker.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        let valueBeforeMove = event.value as? String
        attachCalendarDiagnostic("Calendar move before", "value=\(String(describing: valueBeforeMove))\nframe=\(String(describing: event.frame))")
        let moveBeforeRange = timeRangeMinutes(valueBeforeMove)
        let durationBefore = moveBeforeRange.map { ($0.end - $0.start + 24 * 60) % (24 * 60) }
        let endpoint = app.staticTexts["calendar-timeline-end"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5), "Calendar must expose the active 24:00 endpoint before mutation")
        waitForStableFrame(of: endpoint)
        let endpointFrameBeforeMove = endpoint.frame
        let movePoint = exposedCoordinate(for: event)
        movePoint.press(forDuration: 0.65, thenDragTo: movePoint.withOffset(CGVector(dx: 0, dy: 32)))
        XCTAssertTrue(waitForValueChange(of: event, from: valueBeforeMove, timeout: 5), "The moved event must publish a changed snapshot")
        XCTAssertLessThan(
            abs(endpoint.frame.minY - endpointFrameBeforeMove.minY),
            2,
            "Once the long-press owns the event mutation, the timeline offset must remain frozen"
        )

        let valueAfterMove = event.value as? String
        attachCalendarDiagnostic("Calendar move after", "value=\(String(describing: valueAfterMove))\nframe=\(String(describing: event.frame))")
        let moveAfterRange = timeRangeMinutes(valueAfterMove)
        XCTAssertNotNil(moveBeforeRange, "Move pre-value must expose start/end: \(String(describing: valueBeforeMove))")
        XCTAssertNotNil(moveAfterRange, "Move post-value must expose start/end: \(String(describing: valueAfterMove))")
        XCTAssertNotEqual(moveAfterRange?.start, moveBeforeRange?.start, "Moving an event must change its start")
        XCTAssertNotEqual(moveAfterRange?.end, moveBeforeRange?.end, "Moving an event must change its end")
        let durationAfter = moveAfterRange.map { ($0.end - $0.start + 24 * 60) % (24 * 60) }
        XCTAssertEqual(durationAfter, durationBefore, "Moving an event must preserve its duration")

        app.terminate()
        app.launchArguments = persistedLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()
        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        let persistedMoveEvent = visibleElement(identifier: "calendar-event-\(deterministicDeepWorkID)")
        XCTAssertTrue(persistedMoveEvent.waitForExistence(timeout: 5), "The moved event must persist after relaunch")
        let persistedMoveRange = timeRangeMinutes(persistedMoveEvent.value as? String)
        XCTAssertEqual(persistedMoveRange?.start, moveAfterRange?.start, "Moved event start must persist after relaunch")
        XCTAssertEqual(persistedMoveRange?.end, moveAfterRange?.end, "Moved event end must persist after relaunch")
    }

    func testCalendarCrossDayMoveSnapsVerticallyAndPersistsWithoutPaging() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        let header = app.buttons["calendar-month-toggle"]
        let today = Calendar.current.startOfDay(for: Date())
        let todayValue = calendarISODate(today)
        XCTAssertTrue(waitForCalendarHeaderValue(todayValue, element: header))

        let event = visibleElement(identifier: "calendar-event-\(deterministicDeepWorkID)")
        XCTAssertTrue(event.waitForExistence(timeout: 5), "The deterministic event must be available for a cross-day move")
        let valueBefore = event.value as? String
        let beforeRange = timeRangeMinutes(valueBefore)
        let frameBefore = event.frame
        let targetDay = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let targetDateValue = calendarISODate(targetDay)
        attachCalendarDiagnostic("Calendar cross-day move before", "value=\(String(describing: valueBefore))\nframe=\(String(describing: event.frame))")

        let exposedPoint = exposedPoint(for: event)
        let windowFrame = app.windows.firstMatch.frame
        let timelineMatches = app.descendants(matching: .any).matching(identifier: "calendar-vertical-timeline")
        let timelineProbe = timelineMatches.firstMatch
        XCTAssertTrue(timelineProbe.waitForExistence(timeout: 5), "The active vertical timeline probe must exist before dragging")
        XCTAssertEqual(timelineMatches.count, 1, "The active vertical timeline probe must be unique before dragging")
        let timelineFrame = timelineMatches.count == 1 ? timelineProbe.frame : .zero
        XCTAssertTrue(event.frame.contains(exposedPoint), "The exposed drag point must lie inside the source event frame")
        XCTAssertTrue(windowFrame.contains(exposedPoint), "The exposed drag point must lie inside the app window")
        XCTAssertTrue(timelineFrame.contains(exposedPoint), "The exposed drag point must lie inside the active timeline viewport")
        let overlappingEvent = visibleElement(identifier: "calendar-event-\(deterministicDesignReviewID)")
        XCTAssertTrue(overlappingEvent.waitForExistence(timeout: 5), "The deterministic overlap card must be available")
        XCTAssertFalse(overlappingEvent.frame.contains(exposedPoint), "The exposed drag point must avoid the overlapping Design review card")

        let start = exposedCoordinate(for: event)
        let horizontalColumn = max(event.frame.width * 1.15, 100)
        start.press(
            forDuration: 0.65,
            thenDragTo: start.withOffset(CGVector(dx: horizontalColumn, dy: 32))
        )

        XCTAssertTrue(waitForValueChange(of: event, from: valueBefore, timeout: 5), "A cross-day move must publish an updated event")
        let valueAfter = event.value as? String
        attachCalendarDiagnostic("Calendar cross-day move after", "value=\(String(describing: valueAfter))\nframe=\(String(describing: event.frame))")
        XCTAssertTrue(
            waitForFrameShift(of: event, from: frameBefore, timeout: 3),
            "The committed cross-day event must settle into the destination column geometry"
        )
        let afterRange = timeRangeMinutes(valueAfter)
        XCTAssertNotNil(beforeRange, "Cross-day pre-value must expose start/end: \(String(describing: valueBefore))")
        XCTAssertNotNil(afterRange, "Cross-day post-value must expose start/end: \(String(describing: valueAfter))")
        XCTAssertEqual(afterRange.map { ($0.end - $0.start + 24 * 60) % (24 * 60) },
                       beforeRange.map { ($0.end - $0.start + 24 * 60) % (24 * 60) },
                       "Cross-day movement must preserve duration")
        XCTAssertTrue(valueAfter?.contains(targetDateValue) == true,
                      "Cross-day movement must use the next local calendar date: expected \(targetDateValue), value=\(String(describing: valueAfter))")
        XCTAssertTrue(waitForCalendarHeaderValue(todayValue, element: header),
                      "Moving an event between columns must not page the timeline header")

        app.terminate()
        app.launchArguments = persistedLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()
        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        let persistedEvent = visibleElement(identifier: "calendar-event-\(deterministicDeepWorkID)")
        XCTAssertTrue(persistedEvent.waitForExistence(timeout: 5), "The cross-day event must persist after relaunch")
        XCTAssertTrue((persistedEvent.value as? String)?.contains(targetDateValue) == true,
                      "The cross-day date must persist after relaunch: expected \(targetDateValue), value=\(String(describing: persistedEvent.value))")
    }

    func testCalendarEventEditorAndIconPickerOnIPhone17() throws {
        try runCalendarEventEditorAndIconPicker(appearance: "dark")
    }

    /// The picker contract is identical in both appearances; keep a separate
    /// entry point so visual attachments cannot be mislabeled by shell state.
    func testCalendarEventEditorAndIconPickerOnIPhone17LightMode() throws {
        try runCalendarEventEditorAndIconPicker(appearance: "light")
    }

    private func runCalendarEventEditorAndIconPicker(appearance: String) throws {
        app.terminate()
        let appearanceArgument = appearance == "light"
            ? "-LifeOSForceLightMode"
            : "-LifeOSForceDarkMode"
        app.launchArguments = baseLaunchArguments + [appearanceArgument]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))

        let event = visibleElement(identifier: "calendar-event-\(deterministicDeepWorkID)")
        XCTAssertTrue(event.waitForExistence(timeout: 5), "The visible deterministic calendar page should expose an editable event")
        tapVisible(event)

        let editor = app.descendants(matching: .any)["calendar-event-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar-event-icon-button"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["calendar-event-title"].value as? String, "Deep work")
        capture("\(appearance)-calendar-event-editor")
        app.buttons["calendar-event-icon-button"].tap()

        let picker = app.descendants(matching: .any)["calendar-icon-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar-icon-picker-emojis"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar-icon-picker-icons"].exists, "The picker must not expose a system Icons tab")
        XCTAssertTrue(app.buttons["calendar-icon-custom-add"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["calendar-any-apple-emoji-field"].exists,
                       "The picker must not expose a redundant Any Apple emoji field")
        capture("\(appearance)-calendar-event-emoji-custom-surface")
        app.buttons["calendar-icon-custom-add"].tap()
        XCTAssertTrue(app.buttons["calendar-icon-upload"].waitForExistence(timeout: 5))
        capture("\(appearance)-calendar-event-custom-icon-sheet")
        app.buttons["calendar-icon-cancel"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let emojiSearch = app.descendants(matching: .any)["calendar-icon-search"]
        XCTAssertTrue(emojiSearch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["calendar-emoji-curated-catalog"].exists,
                       "The picker must not expose a curated-catalog disclaimer")
        XCTAssertTrue(app.descendants(matching: .any)["calendar-emoji-category-People"].waitForExistence(timeout: 5))
        capture("\(appearance)-calendar-event-emoji-custom-search")
        app.buttons["calendar-icon-no-icon"].tap()
        XCTAssertTrue(app.buttons["calendar-event-icon-button"].waitForExistence(timeout: 5), "Remove icon should close the picker")
        capture("\(appearance)-calendar-event-editor-no-icon")
    }

    func testCalendarIconPickerPopulatedCustomFixtureOnIPhone17() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSCalendarIconLibraryFixture", "-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()
        XCTAssertTrue(app.buttons["Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(tap(app.buttons["Calendar"], untilVisible: app.buttons["calendar-add"]))
        tapVisible(visibleElement(identifier: "calendar-event-\(deterministicDeepWorkID)"))
        XCTAssertTrue(app.buttons["calendar-event-icon-button"].waitForExistence(timeout: 5))
        app.buttons["calendar-event-icon-button"].tap()
        XCTAssertTrue(app.buttons["calendar-icon-picker-emojis"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar-icon-picker-icons"].exists, "The picker must not expose a system Icons tab")
        XCTAssertTrue(app.buttons["Use custom icon Fixture mark"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["calendar-emoji-custom-icon-row"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use custom icon Fixture mark"].waitForExistence(timeout: 5))
        let customTile = app.buttons["Use custom icon Fixture mark"]
        let emojiTile = app.buttons["calendar-emoji-😀"]
        XCTAssertTrue(emojiTile.waitForExistence(timeout: 5), "The custom tile must share the emoji selection surface")
        XCTAssertEqual(customTile.frame.width, emojiTile.frame.width, accuracy: 1.0)
        XCTAssertEqual(customTile.frame.height, emojiTile.frame.height, accuracy: 1.0)
        capture("dark-calendar-event-emoji-custom")
    }

    /// Focused visual evidence for the matrix-driven Nutrition surface. The
    /// lower captures prove the scrollable detail content exists beyond the hero.
    func testNutritionLowerSurfaceEvidence() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Fitness"].waitForExistence(timeout: 5))
        app.buttons["Fitness"].tap()
        XCTAssertTrue(app.buttons["Nutrition"].waitForExistence(timeout: 5))
        app.buttons["Nutrition"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["fitness-nutrition-surface"].waitForExistence(timeout: 5))
        capture("nutrition-iphone17-dark-top")

        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
        capture("nutrition-iphone17-dark-lower-macros-energy")

        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
        capture("nutrition-iphone17-dark-lower-quality-meals-trends")
    }

    /// Focused visual/accessibility evidence for Bevel IMG_0391–0392's
    /// activity calendar, source states, and performance chart continuation.
    /// The launch fixture is explicit demo data; this test is not live-source
    /// or HealthKit proof.
    func testFitnessActivityPerformanceEvidenceOnIPhone17() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Fitness"].waitForExistence(timeout: 5))
        app.buttons["Fitness"].firstMatch.tap()

        let fitnessSectionButton = lastButton(matching: "Fitness")
        if fitnessSectionButton.waitForExistence(timeout: 2) {
            fitnessSectionButton.tap()
        }
        let activitySurface = app.descendants(matching: .any)["fitness-activity-performance"]
        XCTAssertTrue(activitySurface.waitForExistence(timeout: 5), "Fitness activity/performance surface must be reachable")
        XCTAssertTrue(
            fitnessElement(
                identifier: "fitness-activity-calendar",
                fallback: app.staticTexts["Activity calendar"],
                timeout: 5
            ).exists,
            "Activity calendar must be exposed in the Fitness surface"
        )
        XCTAssertTrue(app.descendants(matching: .any)["fitness-activity-summary-chart"].waitForExistence(timeout: 5))
        capture("fitness-activity-performance-iphone17-dark-top")

        let summaryChart = app.descendants(matching: .any)["fitness-activity-summary-chart"]
        XCTAssertTrue(accessibilityStrings(for: summaryChart).contains { $0.contains("Observed source points") || $0.contains("Selected") })
        app.swipeUp(velocity: .fast)
        capture("fitness-activity-performance-iphone17-dark-lower")
    }

    /// Focused evidence for Bevel IMG_0394–0395's source-aware Biology detail.
    /// The launch fixture is explicit demo data; biological age remains gated
    /// and this is not Helio/HealthKit proof.
    func testFitnessBiologyEvidenceOnIPhone17() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Fitness"].waitForExistence(timeout: 5))
        app.buttons["Fitness"].firstMatch.tap()
        let biologySectionButton = lastButton(matching: "Biology")
        XCTAssertTrue(biologySectionButton.waitForExistence(timeout: 5), "Biology section must be reachable")
        biologySectionButton.tap()

        let biologySurface = app.descendants(matching: .any)["fitness-biology"]
        XCTAssertTrue(biologySurface.waitForExistence(timeout: 5), "Biology surface must be reachable")
        XCTAssertTrue(app.descendants(matching: .any)["fitness-biology-age"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["fitness-biology-metric-weight"].waitForExistence(timeout: 5))
        capture("fitness-biology-img0394-iphone17-dark-top")

        let showAll = app.buttons["fitness-biology-show-all"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 5), "Biology show-all control must be reachable")
        showAll.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fitness-biology-metric-vo2Max"].waitForExistence(timeout: 5))
        capture("fitness-biology-img0395-iphone17-dark-all")

        let weightCard = app.descendants(matching: .any)["fitness-biology-metric-weight"]
        tapVisible(weightCard)
        XCTAssertTrue(app.descendants(matching: .any)["fitness-biology-detail-weight"].waitForExistence(timeout: 5), "Biology metric detail must open")
        capture("fitness-biology-img0395-iphone17-dark-detail")
    }

    /// Focused evidence for IMG_0393's source-aware Strength detail. The
    /// launch fixture is explicit demo data; this is not live workout proof.
    func testFitnessStrengthEvidenceOnIPhone17() throws {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-LifeOSForceDarkMode"]
        app.launch()
        dismissSystemPromptsIfPresent()

        XCTAssertTrue(app.buttons["Fitness"].waitForExistence(timeout: 5))
        app.buttons["Fitness"].firstMatch.tap()
        let fitnessSectionButton = lastButton(matching: "Fitness")
        if fitnessSectionButton.waitForExistence(timeout: 2) {
            fitnessSectionButton.tap()
        }

        let strengthCard = fitnessStrengthVolumeCard(timeout: 8)
        XCTAssertTrue(strengthCard.exists, "Strength volume card must be reachable")
        tapFitnessStrengthCard(strengthCard)

        let detail = app.descendants(matching: .any)["fitness-strength-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "Strength detail route must open")
        XCTAssertTrue(app.descendants(matching: .any)["fitness-strength-radial-diagram"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["fitness-strength-progress-card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["fitness-strength-templates"].waitForExistence(timeout: 5))
        XCTAssertTrue(accessibilityStrings(for: detail).contains { $0.contains("DEMO") }, "Fixture detail must remain labelled as demo")
        capture("fitness-strength-img0393-iphone17-dark")
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

    private func selectCalendarMonthView() {
        let picker = app.buttons["calendar-view-picker"]
        let monthMenuItem = app.buttons["Month view"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Calendar must expose its view-mode picker")
        XCTAssertTrue(tap(picker, untilVisible: monthMenuItem), "Calendar view menu must expose its Month view item")
        monthMenuItem.tap()
    }

    /// Select the real top-level Fitness tab and prove that the app replaced
    /// Home with the Fitness Today surface before entering the Sleep card.
    /// SwiftUI publishes each child button with the enclosing bar's
    /// accessibility identifier, so the exact visible label is part of the
    /// query. Re-query on every attempt to avoid retaining a pre-transition
    /// accessibility element.
    private func openFitnessRouteAndAssertTodaySurface() {
        let fitnessSurface = app.descendants(matching: .any)["fitness-view"]
        let todayComposition = app.descendants(matching: .any)["fitness-today-composition"]

        for attempt in 0..<3 {
            let fitnessTab = app.buttons["main-tab-fitness"]
            XCTAssertTrue(fitnessTab.waitForExistence(timeout: 5), "Fitness tab control must be present")

            if (fitnessTab.value as? String) == "Selected",
               fitnessSurface.waitForExistence(timeout: 1),
               todayComposition.waitForExistence(timeout: 5) {
                return
            }

            guard attempt < 2 else { break }
            guard fitnessTab.isHittable else { continue }
            fitnessTab.tap()

            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "Selected"),
                object: fitnessTab
            )
            _ = XCTWaiter().wait(for: [selected], timeout: 5)
        }

        let fitnessTab = app.buttons["main-tab-fitness"]
        let diagnostic = "Fitness tab value=\(String(describing: fitnessTab.value)); "
            + "fitness-view exists=\(fitnessSurface.exists); "
            + "today composition exists=\(todayComposition.exists)"
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = "Fitness route selection diagnostic"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("The synthesized tap must prove the selected Fitness tab and real Today surface. \(diagnostic)")
    }

    private func tapVisible(_ element: XCUIElement) {
        exposedCoordinate(for: element).tap()
    }

    /// Returns a Fitness element by its intended identifier, falling back to
    /// its user-visible semantic control when SwiftUI's parent accessibility
    /// grouping does not publish the child identifier. When a card is below
    /// the phone viewport, scroll the actual Fitness ScrollView one viewport
    /// at a time and re-query the live accessibility tree.
    private func fitnessElement(
        identifier: String,
        fallback: XCUIElement,
        timeout: TimeInterval,
        revealByScrolling: Bool = false
    ) -> XCUIElement {
        let byIdentifier = app.descendants(matching: .any)[identifier]
        let attempts = revealByScrolling ? 8 : 0

        for attempt in 0...attempts {
            if byIdentifier.waitForExistence(timeout: attempt == 0 ? timeout : 1), isVisibleOnPhone(byIdentifier) {
                return byIdentifier
            }
            if fallback.waitForExistence(timeout: attempt == 0 ? timeout : 1), isVisibleOnPhone(fallback) {
                return fallback
            }
            guard revealByScrolling, attempt < attempts else { break }
            // Fitness renders the horizontal section strip as the first
            // ScrollView, while the actual vertical content has no dedicated
            // accessibility identifier. Start below the strip so the gesture
            // is received by the vertical content viewport.
            let contentStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let contentEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            contentStart.press(forDuration: 0.1, thenDragTo: contentEnd)
        }

        XCTFail("Fitness element (\(identifier)) must be visible; fallback label was (\(fallback.label))")
        return byIdentifier.exists ? byIdentifier : fallback
    }

    /// Finds the source-backed Strength volume NavigationLink, not the
    /// accessibility container for the whole Activity surface. The card must
    /// be fully above the bottom tab bar before its center is tapped.
    private func fitnessStrengthVolumeCard(timeout: TimeInterval) -> XCUIElement {
        let identifierQuery = app.buttons.matching(identifier: "fitness-strength-volume-card")
        let semanticQuery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Strength volume"))

        for attempt in 0...8 {
            let wait = attempt == 0 ? timeout : 1
            _ = identifierQuery.firstMatch.waitForExistence(timeout: wait)
            _ = semanticQuery.firstMatch.waitForExistence(timeout: wait)

            let candidates = identifierQuery.allElementsBoundByIndex + semanticQuery.allElementsBoundByIndex
            if let card = candidates.first(where: { candidate in
                let hasStrengthIdentity = candidate.identifier == "fitness-strength-volume-card"
                    || candidate.label.localizedCaseInsensitiveContains("Strength volume")
                return hasStrengthIdentity && isSafelyVisibleAboveTabBar(candidate)
            }) {
                return card
            }

            guard attempt < 8 else { break }
            let contentStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let contentEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            contentStart.press(forDuration: 0.1, thenDragTo: contentEnd)
        }

        XCTFail("Strength volume button must be visible above the Fitness tab bar")
        return identifierQuery.firstMatch.exists ? identifierQuery.firstMatch : semanticQuery.firstMatch
    }

    private func tapFitnessStrengthCard(_ element: XCUIElement) {
        XCTAssertTrue(
            isSafelyVisibleAboveTabBar(element),
            "Strength volume card must be fully visible above the bottom tab bar before tapping"
        )
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Proves the element's complete accessibility frame is above the custom
    /// bar. The requiresHittable flag is reserved for controls; passive
    /// endpoint cards/labels intentionally use geometry only.
    private func assertTrailingElementAboveTabBar(
        _ identifier: String,
        route: String,
        scrollView: XCUIElement? = nil,
        maxSwipes: Int = 10,
        requiresHittable: Bool = false,
        xFraction: CGFloat = 0.5
    ) {
        let target = app.descendants(matching: .any)[identifier]
        for attempt in 0...maxSwipes {
            if target.waitForExistence(timeout: attempt == 0 ? 5 : 1),
               isSafelyVisibleAboveTabBar(target) {
                if requiresHittable {
                    XCTAssertTrue(target.isHittable, "\(route) trailing element \(identifier) must be hittable")
                }
                return
            }
            guard attempt < maxSwipes else { break }
            if let scrollView {
                swipeUp(in: scrollView, xFraction: xFraction)
            } else {
                swipeVerticalContent()
            }
        }

        XCTFail(
            "\(route) trailing element \(identifier) must be fully above the live custom tab bar; " +
                "target=\(String(describing: target.frame)), tabBarTop=\(String(describing: customTabBarTopY))"
        )
    }

    private func assertTabBarFitsWindow() {
        let window = app.windows.firstMatch.frame
        let identifiers = ["home", "calendar", "finance", "fitness", "more"]
        let tabButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "main-tab-"))
        XCTAssertEqual(tabButtons.count, identifiers.count, "Exactly one stable CompactTabBar may be mounted")
        let buttons = identifiers.map { app.buttons["main-tab-\($0)"] }
        for button in buttons {
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Tab bar item \(button.identifier) must exist")
            let frame = button.frame
            XCTAssertGreaterThan(frame.width, 0, "Tab bar item \(button.identifier) must have width")
            XCTAssertGreaterThan(frame.height, 0, "Tab bar item \(button.identifier) must have height")
            XCTAssertLessThanOrEqual(frame.maxY, window.maxY + 1, "Tab bar item \(button.identifier) is clipped by the window")
        }
    }

    private func swipeVerticalContent() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        start.press(forDuration: 0.08, thenDragTo: end)
    }

    private func swipeUp(in scrollView: XCUIElement, xFraction: CGFloat = 0.5) {
        let frame = scrollView.frame
        let window = app.windows.firstMatch.frame
        guard frame.width > 0, frame.height > 0, window.width > 0, window.height > 0 else { return }
        let normalizedPoint: (CGPoint) -> CGVector = { point in
            CGVector(
                dx: (point.x - window.minX) / window.width,
                dy: (point.y - window.minY) / window.height
            )
        }
        let start = app.coordinate(withNormalizedOffset: normalizedPoint(
            CGPoint(x: frame.minX + frame.width * xFraction, y: frame.minY + frame.height * 0.75)
        ))
        let end = app.coordinate(withNormalizedOffset: normalizedPoint(
            CGPoint(x: frame.minX + frame.width * xFraction, y: frame.minY + frame.height * 0.25)
        ))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func swipeUp(overIdentifier identifier: String, in scrollView: XCUIElement) {
        // Re-query immediately before the drag. A previous vertical pan can
        // move the same event's AX frame, and a stale offscreen frame must
        // never be clamped into an unrelated empty point in the timeline.
        let event = visibleElement(identifier: identifier)
        let frame = scrollView.frame
        let eventFrame = event.frame
        let window = app.windows.firstMatch.frame
        let visibleFrame = eventFrame.intersection(frame).intersection(window)
        XCTAssertFalse(visibleFrame.isNull || visibleFrame.isEmpty, "The over-scroll source must intersect the live timeline: \(identifier), frame=\(String(describing: eventFrame)), timeline=\(String(describing: frame))")
        guard frame.width > 0, frame.height > 0, window.width > 0, window.height > 0,
              !visibleFrame.isNull, !visibleFrame.isEmpty else { return }
        let startY = visibleFrame.midY
        // Keep the interactive source visible for the second arbitration
        // probe while still moving far enough to exceed UIKit's pan threshold.
        let endY = max(frame.minY + 24, startY - frame.height * 0.14)
        let normalizedPoint: (CGPoint) -> CGVector = { point in
            CGVector(
                dx: (point.x - window.minX) / window.width,
                dy: (point.y - window.minY) / window.height
            )
        }
        let start = app.coordinate(withNormalizedOffset: normalizedPoint(CGPoint(x: visibleFrame.midX, y: startY)))
        let end = app.coordinate(withNormalizedOffset: normalizedPoint(CGPoint(x: visibleFrame.midX, y: endY)))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func waitForStableFrame(of element: XCUIElement) {
        var previous = element.frame
        var stableSamples = 0
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, stableSamples < 3 {
            Thread.sleep(forTimeInterval: 0.15)
            let current = element.frame
            if abs(current.minY - previous.minY) < 0.5,
               abs(current.height - previous.height) < 0.5 {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            previous = current
        }
    }

    private var customTabBarTopY: CGFloat? {
        let identifiers = ["home", "calendar", "finance", "fitness", "more"]
        let frames = identifiers.compactMap { identifier -> CGRect? in
            let frame = app.buttons["main-tab-\(identifier)"].frame
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
        return frames.map(\.minY).min()
    }

    private func isSafelyVisibleAboveTabBar(_ element: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        guard let tabBarTopY = customTabBarTopY else { return false }
        let contentBottom = min(window.maxY, tabBarTopY)
        return frame.width > 0 && frame.height > 0
            && frame.minX >= window.minX
            && frame.maxX <= window.maxX
            && frame.minY >= window.minY + 8
            && frame.maxY <= contentBottom - 8
            && window.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func isVisibleOnPhone(_ element: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        return frame.width > 0 && frame.height > 0
            && frame.intersects(window)
            && window.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func lastButton(matching labelOrIdentifier: String) -> XCUIElement {
        let query = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            labelOrIdentifier,
            labelOrIdentifier
        ))
        return query.element(boundBy: max(query.count - 1, 0))
    }

    private func exposedCoordinate(for element: XCUIElement) -> XCUICoordinate {
        let frame = element.frame
        let windowFrame = app.windows.firstMatch.frame
        // Deep work is the base layer beneath the 09:30 Design review card.
        // Its leading/top segment is exposed; the geometric center is not.
        let pointInElement = exposedPointInElement
        let point = exposedPoint(for: element)
        let coordinate = app.coordinate(withNormalizedOffset: CGVector(
            dx: (point.x - windowFrame.minX) / max(1, windowFrame.width),
            dy: (point.y - windowFrame.minY) / max(1, windowFrame.height)
        ))
        let pointDescription = "frame=\(String(describing: frame)) point=\(String(describing: pointInElement))"
        let attachment = XCTAttachment(string: pointDescription)
        attachment.name = "Selected event tap point: \(element.identifier)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Select exposed point of visible event") { activity in
            activity.add(attachment)
        }
        return coordinate
    }

    private func exposedPoint(for element: XCUIElement) -> CGPoint {
        let frame = element.frame
        return CGPoint(
            x: frame.minX + frame.width * exposedPointInElement.dx,
            y: frame.minY + frame.height * exposedPointInElement.dy
        )
    }

    private func attachCalendarDiagnostic(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { activity in
            activity.add(attachment)
        }
    }

    private func visibleElement(identifier: String) -> XCUIElement {
        let matching = app.descendants(matching: .any).matching(identifier: identifier)
        let windowFrame = app.windows.firstMatch.frame
        let verticalTimelineMatches = app.descendants(matching: .any).matching(identifier: "calendar-vertical-timeline")
        let verticalTimeline = verticalTimelineMatches.firstMatch
        let hasVerticalTimeline = verticalTimeline.waitForExistence(timeout: 5)
        let verticalTimelineCount = verticalTimelineMatches.count
        XCTAssertEqual(
            verticalTimelineCount,
            1,
            "The active timeline viewport probe must be unique (count=\(verticalTimelineCount))"
        )
        let verticalTimelineFrame = hasVerticalTimeline && verticalTimelineCount == 1
            ? verticalTimeline.frame
            : .zero
        let requiresTimedViewport = identifier.hasPrefix("calendar-event-") ||
            identifier.hasPrefix("calendar-empty-timed-grid-")
        let candidates = matching.allElementsBoundByIndex.enumerated().map { index, element in
            let frame = element.frame
            let midpoint = CGPoint(x: frame.midX, y: frame.midY)
            let insideTimeline = !requiresTimedViewport || (
                verticalTimelineFrame.width > 0 && verticalTimelineFrame.height > 0 &&
                verticalTimelineFrame.contains(midpoint)
            )
            let visible = frame.width > 0 && frame.height > 0
                && frame.intersects(windowFrame)
                && windowFrame.contains(midpoint)
                && insideTimeline
            return (index: index, element: element, frame: frame, visible: visible, insideTimeline: insideTimeline)
        }
        let diagnostics = candidates.map { index, element, frame, visible, insideTimeline in
            "#\(index) id=\(element.identifier) frame=\(String(describing: frame)) visible=\(visible) insideTimeline=\(insideTimeline)"
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: diagnostics.isEmpty ? "No matching accessibility candidates" : diagnostics)
        attachment.name = "Accessibility candidates: \(identifier)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Select visible accessibility element \(identifier)") { activity in
            activity.add(attachment)
        }

        guard let candidate = candidates.first(where: { $0.visible }) else {
            XCTFail("No visible accessibility candidate for \(identifier). Window frame: \(String(describing: windowFrame))\n\(diagnostics)")
            return matching.firstMatch
        }
        XCTAssertTrue(
            candidate.frame.intersects(windowFrame)
                && windowFrame.contains(CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
                && candidate.insideTimeline,
            "Selected accessibility candidate must be visible inside the active timeline: \(String(describing: candidate.frame)), timeline=\(String(describing: verticalTimelineFrame))"
        )
        return candidate.element
    }

    private func datePicker(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func accessibilityStrings(for element: XCUIElement) -> [String] {
        let elements = [element] + element.descendants(matching: .any).allElementsBoundByIndex
        return elements.flatMap { candidate in
            [String(describing: candidate.value), candidate.label]
        }
    }

    private var baseLaunchArguments: [String] {
        ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-LifeOSVisualFixtures"]
    }

    private var persistedLaunchArguments: [String] {
        baseLaunchArguments.filter { $0 != "-LifeOSVisualFixtures" }
    }

    private func dismissSystemPromptsIfPresent() {
        for label in ["Allow", "OK", "Continue", "Don’t Allow", "Don't Allow"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 1) { button.tap() }
        }
    }

    private func waitForCalendarHeaderValue(_ expected: String, element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForCalendarPagerCommittedDate(
        _ expected: String,
        element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return (element.value as? String) == "Committed page \(expected)"
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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

    private func timeOfDayMinutes(from values: [String]) -> Int? {
        let twelveHourPattern = #"(?<!\d)(1[0-2]|[1-9]):([0-5]\d)\s*([AaPp][Mm])\b"#
        let twentyFourHourPattern = #"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\s*[AaPp][Mm])"#
        let twelveHourRegex = try? NSRegularExpression(pattern: twelveHourPattern)
        let twentyFourHourRegex = try? NSRegularExpression(pattern: twentyFourHourPattern)

        for value in values {
            let normalized = value
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)

            if let match = twelveHourRegex?.firstMatch(in: normalized, range: range),
               let hour = Int(normalized[Range(match.range(at: 1), in: normalized)!]),
               let minute = Int(normalized[Range(match.range(at: 2), in: normalized)!]),
               let meridiem = Range(match.range(at: 3), in: normalized).map({ normalized[$0].uppercased() }) {
                let normalizedHour = hour % 12 + (meridiem == "PM" ? 12 : 0)
                return normalizedHour * 60 + minute
            }

            if let match = twentyFourHourRegex?.firstMatch(in: normalized, range: range),
               let hour = Int(normalized[Range(match.range(at: 1), in: normalized)!]),
               let minute = Int(normalized[Range(match.range(at: 2), in: normalized)!]) {
                return hour * 60 + minute
            }
        }
        return nil
    }

    private func timeOfDayMinutes(_ value: String?) -> Int? {
        guard let value else { return nil }
        return timeOfDayMinutes(from: [value])
    }

    private func timeRangeMinutes(_ value: String?) -> (start: Int, end: Int)? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!\d)(?:1[0-2]|[1-9]|[01]?\d|2[0-3]):[0-5]\d(?:\s*[AaPp][Mm])?"#
        ) else { return nil }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let minutes = regex.matches(in: normalized, range: range).compactMap { match -> Int? in
            guard let tokenRange = Range(match.range, in: normalized) else { return nil }
            return timeOfDayMinutes(from: [String(normalized[tokenRange])])
        }
        guard minutes.count >= 2 else { return nil }
        return (minutes[0], minutes[1])
    }

    private func calendarISODate(_ date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return ""
        }

        func padded(_ value: Int, to width: Int) -> String {
            let raw = String(value)
            return String(repeating: "0", count: max(0, width - raw.count)) + raw
        }

        return "\(padded(year, to: 4))-\(padded(month, to: 2))-\(padded(day, to: 2))"
    }
}
