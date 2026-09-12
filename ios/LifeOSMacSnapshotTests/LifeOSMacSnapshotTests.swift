import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import LifeOSMac

@available(macOS 14.0, *)
@MainActor
final class LifeOSMacSnapshotTests: XCTestCase {
    private let frame = CGSize(width: 1512, height: 982)

    func testVisualFixtureHostCreatesZeroLiveNetworkTasks() {
        XCTAssertEqual(
            ProcessInfo.processInfo.environment["LIFEOS_VISUAL_FIXTURES"],
            "1",
            "LifeOSMac snapshot TestAction must pass LIFEOS_VISUAL_FIXTURES=1 to the hosted app."
        )
        XCTAssertTrue(
            ProcessInfo.processInfo.arguments.contains("-LifeOSVisualFixtures")
                || ProcessInfo.processInfo.environment["LIFEOS_VISUAL_FIXTURES"] == "1",
            "Snapshot test hosts must launch LifeOSMac in explicit visual-fixture mode."
        )
        XCTAssertEqual(
            LifeOSNetworkTaskAudit.shared.createdTaskCount,
            0,
            "Visual fixture startup must not create a Tailscale HTTP or WebSocket task."
        )

        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(),
            usesVisualFixtures: true
        )
        coordinator.startSync()
        coordinator.stopSync()
        XCTAssertEqual(
            LifeOSNetworkTaskAudit.shared.createdTaskCount,
            0,
            "Constructing or starting a fixture CalendarCoordinator must remain offline."
        )
    }

    func testFitnessRefreshCoalescesConcurrentCallersBeforePublishingOneResult() async throws {
        let gate = MacObservationGate()
        let now = Date()
        let metric = try FitnessObservationValue(
            metric: .heartRate,
            value: 62,
            unit: .beatsPerMinute,
            observedAt: now
        )
        let expected = try FitnessObservationEnvelope(
            state: .observed,
            generatedAt: now,
            observedAt: now,
            metrics: [metric]
        )
        let coordinator = FitnessObservationCoordinator(
            usesVisualFixtures: false,
            fetchObservation: {
                await gate.block()
                return expected
            }
        )

        let first = Task { @MainActor in await coordinator.refresh() }
        await gate.waitUntilStarted()
        let second = Task { @MainActor in await coordinator.refresh() }
        await Task.yield()
        let callsWhileBlocked = await gate.count()
        XCTAssertEqual(callsWhileBlocked, 1)

        await gate.release()
        await first.value
        await second.value

        XCTAssertEqual(coordinator.observation, expected)
    }

    func testOverviewSnapshot() {
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(),
            usesVisualFixtures: true
        )
        render(LifeOSMacRootView(calendarCoordinator: coordinator, usesVisualFixtures: true, usageCoordinator: UsageCoordinator()), named: "LifeOSMacRootView-overview")
    }

    func testMacRouteStateKeepsHomeMountStableAcrossNativePathChanges() {
        var state = LifeOSMacRouteState()
        let homeIdentity = state.mountedIdentity

        _ = LifeOSMacRouteReducer.reduce(&state, action: .openHomeDestination(.clipper))
        _ = LifeOSMacRouteReducer.reduce(&state, action: .openHomeDestination(.usage))

        XCTAssertEqual(state.homePath, [.clipper, .usage])
        XCTAssertEqual(state.mountedIdentity, homeIdentity)
        XCTAssertTrue(state.showingUsage)

        _ = LifeOSMacRouteReducer.reduce(&state, action: .backHome)
        XCTAssertEqual(state.homePath, [.clipper])
        XCTAssertEqual(state.mountedIdentity, homeIdentity)
    }

    func testMacRouteStateSeparatesCalendarCommandFromStableCalendarRoute() throws {
        var state = LifeOSMacRouteState()
        _ = LifeOSMacRouteReducer.reduce(&state, action: .navigate(.calendar))
        let calendarIdentity = state.mountedIdentity
        _ = LifeOSMacRouteReducer.reduce(&state, action: .navigate(.newCalendarEvent))
        let requestID = try XCTUnwrap(state.pendingCalendarEventID)

        XCTAssertEqual(state.route, .calendar)
        XCTAssertEqual(state.mountedIdentity, calendarIdentity)
        XCTAssertTrue(
            LifeOSMacRouteReducer.reduce(
                &state,
                action: .consumeCalendarEvent(id: requestID, expectedMountGeneration: state.mountGeneration)
            ).didChange
        )
        XCTAssertNil(state.pendingCalendarEventID)
    }

    func testOverviewResponsiveLightDarkAndUnavailableEvidence() {
        for width in [760.0, 800.0, 900.0, 1_200.0, 1_512.0] {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let appearance = scheme == .dark ? "dark" : "light"
                render(
                    OverviewView(
                        snapshot: DemoDataProvider.overview,
                        usageSnapshots: DemoDataProvider.providers,
                        usageAnalytics: DemoUsageAnalytics.snapshots,
                        usageState: .demo,
                        openDestination: { _ in }
                    ),
                    named: "Overview-\(Int(width))-\(appearance)",
                    frameSize: CGSize(width: width, height: frame.height),
                    colorScheme: scheme,
                    reduceMotion: scheme == .dark
                )
            }
        }

        render(
            OverviewView(snapshot: .unavailable(), usageSnapshots: [], openDestination: { _ in }),
            named: "Overview-production-unavailable-dark-reduce-motion",
            frameSize: CGSize(width: 1_200, height: frame.height),
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    func testOverviewMeasuredWidthContractAtMacReviewWidths() {
        let gutter = LifeOSTokens.overviewContentInset
        let expectedContentWidths: [(outer: CGFloat, content: CGFloat, columns: Int)] = [
            (800, 752, 2),
            (900, 852, 2),
            (1_200, 1_040, 2)
        ]

        for expected in expectedContentWidths {
            let contentWidth = OverviewLayoutContract.contentWidth(
                forOuterWidth: expected.outer,
                horizontalPadding: gutter
            )
            XCTAssertEqual(contentWidth, expected.content, accuracy: 0.001)
            XCTAssertEqual(OverviewLayoutContract.columnCount(for: contentWidth), expected.columns)
            XCTAssertLessThanOrEqual(
                OverviewLayoutContract.minimumRequiredWidth(for: contentWidth),
                contentWidth,
                "Two-column Home layout must fit inside the measured content width at \(expected.outer) pt."
            )
        }

        // The breakpoint is measured after the parent has supplied its actual
        // detail width. This catches the one-to-two-column transition without
        // coupling the test to a particular sidebar implementation.
        XCTAssertEqual(OverviewLayoutContract.columnCount(for: 719.99), 1)
        XCTAssertEqual(OverviewLayoutContract.columnCount(for: 720), 2)
        XCTAssertEqual(OverviewLayoutContract.maxContentWidth, 1_040)
    }

    /// RF-20: the Finance card's Wealth row shows the real observed wealth
    /// value (never derived from cash transactions/account balances — see
    /// `FinanceWealthSnapshot.observedValueCents`) and is the entry point
    /// into the same real wealth surface Finance's own screen renders.
    func testOverviewFinanceWealthRowSnapshot() throws {
        let summary = try wealthAllocationFinanceSummary(includeUnavailableHolding: false)
        render(
            OverviewView(
                snapshot: DemoDataProvider.overview,
                usageSnapshots: DemoDataProvider.providers,
                usageAnalytics: DemoUsageAnalytics.snapshots,
                usageState: .demo,
                financeSummary: summary,
                financeState: .observed,
                openDestination: { _ in }
            ),
            named: "Overview-finance-wealth-row",
            frameSize: CGSize(width: 1_200, height: frame.height)
        )
    }

    func testResponsivePrimarySurfacesAtReviewWidths() {
        let surfaces: [(String, AnyView)] = [
            ("home", rootSurface(module: .home)),
            ("usage", rootSurface(module: .home, route: .usage, showingUsage: true)),
            ("finance", rootSurface(module: .finance)),
            ("fitness", rootSurface(module: .fitness)),
            ("settings", rootSurface(module: .settings))
        ]
        for width in [900.0, 1_200.0, 1_512.0, 1_800.0] {
            for (name, surface) in surfaces {
                render(
                    surface,
                    named: "responsive-\(name)-\(Int(width))",
                    frameSize: CGSize(width: width, height: frame.height),
                    colorScheme: .light
                )
            }
        }
    }

    private func rootSurface(
        module: LifeOSModule,
        route: LifeOSDeepLink? = nil,
        showingUsage: Bool = false
    ) -> AnyView {
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(),
            usesVisualFixtures: true
        )
        return AnyView(LifeOSMacRootView(
            calendarCoordinator: coordinator,
            usesVisualFixtures: true,
            usageCoordinator: UsageCoordinator(),
            financeCoordinator: FinanceCoordinator(initialState: .demo),
            initialModule: module,
            initialRoute: route,
            initiallyShowingUsage: showingUsage
        ))
    }

    func testCalendarSnapshot() {
        let anchor = visualFixtureAnchor
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(anchor: anchor, calendar: visualFixtureCalendar),
            usesVisualFixtures: true
        )
        render(
            CalendarView(selectedDate: anchor, calendar: visualFixtureCalendar, coordinator: coordinator),
            named: "CalendarView"
        )
    }

    func testCalendarMonthSnapshot() {
        let anchor = visualFixtureAnchor
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(anchor: anchor, calendar: visualFixtureCalendar),
            usesVisualFixtures: true
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

    func testCalendarIconPickerEvidenceLightDark() throws {
        let anchor = visualFixtureAnchor
        let item = try XCTUnwrap(CalendarVisualFixtures.snapshot(anchor: anchor, calendar: visualFixtureCalendar).items.first)
        let reusable = try XCTUnwrap(CalendarVisualFixtures.reusableIcon)

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(
                CalendarEditor(
                    item: item,
                    date: anchor,
                    onSave: { _, completion in completion(.success) },
                    onDelete: { _, completion in completion(.success) }
                ),
                named: "CalendarEditorCompact-\(suffix)",
                colorScheme: scheme,
                reduceMotion: true,
                settleInterval: 0.2
            )
            render(
                CalendarIconPicker(
                    icon: .constant(item.icon),
                    systemIconName: .constant(nil),
                    iconAsset: .constant(nil),
                    initialTab: "emojis"
                ),
                named: "CalendarIconPicker-Emoji-\(suffix)",
                colorScheme: scheme
            )
            render(
                CalendarIconPicker(
                    icon: .constant(nil),
                    systemIconName: .constant(nil),
                    iconAsset: .constant(nil),
                    initialTab: "emojis",
                    customIcons: [reusable]
                ),
                named: "CalendarIconPicker-Emoji-Custom-\(suffix)",
                colorScheme: scheme
            )
            render(
                CalendarCustomIconSheet(onSave: { _ in }),
                named: "CalendarIconPicker-Add-Custom-\(suffix)",
                colorScheme: scheme
            )
        }
    }

    func testCalendarEditorCompactSurfaceEvidenceLightDark() throws {
        let anchor = visualFixtureAnchor
        let item = try XCTUnwrap(CalendarVisualFixtures.snapshot(anchor: anchor, calendar: visualFixtureCalendar).items.first)
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(
                CalendarEditor(
                    item: item,
                    date: anchor,
                    onSave: { _, completion in completion(.success) },
                    onDelete: { _, completion in completion(.success) }
                ),
                named: "CalendarEditorCompact-Surface-\(suffix)",
                colorScheme: scheme,
                reduceMotion: true,
                settleInterval: 0.2
            )
        }
    }

    func testFinanceSpendSnapshot() {
        render(
            FinanceView(summary: nil, usesVisualFixtures: true, initialDetail: .spend),
            named: "FinanceView-spend"
        )
    }

    func testFinanceCashFlowSnapshot() {
        render(
            FinanceView(summary: nil, usesVisualFixtures: true, initialDetail: .cashFlow),
            named: "FinanceView-cash-flow",
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    // MARK: - RF-08 bar mode (LifeOSBarChart wired into Finance)
    //
    // The demo fixture's income/spend transactions only span ~11 days, while
    // the default range is `.month` (31 days). `FinanceDisplaySnapshot
    // .barBuckets(for:range:)` anchors the display window on the latest
    // observed transaction and does NOT gate on the line chart's
    // `hasDistinctHistory` continuity check, so this combination reliably
    // produces, in one screen: several weeks before the fixture's observed
    // history (an honest gap — `totalCents == nil`), real observed weeks
    // (including a real zero if one occurs), and the still-accumulating
    // current week (`isComplete == false`). This is the closest thing to a
    // real device screenshot of the honesty contract without hand-built
    // fixtures.

    func testFinanceIncomeBarModeSnapshot() {
        render(
            FinanceView(
                summary: nil,
                usesVisualFixtures: true,
                initialDetail: .income,
                initialChartMode: .bar
            ),
            named: "FinanceView-income-bar-mode"
        )
    }

    func testFinanceIncomeBarModeReduceMotionSnapshot() {
        render(
            FinanceView(
                summary: nil,
                usesVisualFixtures: true,
                initialDetail: .income,
                initialChartMode: .bar
            ),
            named: "FinanceView-income-bar-mode-reduce-motion",
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    func testFinanceSpendRingModeSnapshot() {
        render(
            FinanceView(
                summary: nil,
                usesVisualFixtures: true,
                initialDetail: .spend,
                initialChartMode: .ring
            ),
            named: "FinanceView-spend-ring-mode"
        )
    }

    // MARK: - RF-07 wealth projection

    func testFinanceNetWorthProjectionSnapshot() {
        render(
            FinanceView(summary: nil, usesVisualFixtures: true, initialDetail: .netWorth),
            named: "FinanceView-net-worth-projection"
        )
    }

    // MARK: - RF-06 wealth allocation

    /// Builds a `FinanceSummary` with a wealth snapshot only (no accounts,
    /// income, or transactions), so the resulting screenshot is focused
    /// evidence for the allocation ring rather than a full dashboard.
    /// `includeUnavailableHolding` adds one holding whose value is
    /// unavailable, to render the partial-allocation disclosure.
    private func wealthAllocationFinanceSummary(includeUnavailableHolding: Bool) throws -> FinanceSummary {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = ISO8601DateFormatter().date(from: "2026-08-08T12:05:00Z")!
        let observedAt = formatter.string(from: now.addingTimeInterval(-60))

        let unavailableMetric: [String: Any] = [
            "availability": "unavailable",
            "provenance": [
                "source": "no-authorized-finance-source", "observedAt": observedAt,
                "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"
            ]
        ]
        let wealthProvenance: [String: Any] = [
            "source": "trade_republic", "observedAt": observedAt,
            "freshness": "fresh", "quality": "observed", "connectorState": "healthy"
        ]
        func observedHolding(id: String, name: String, assetClass: String, valueCents: Int) -> [String: Any] {
            [
                "availability": "observed", "id": id, "name": name, "assetClass": assetClass,
                "valueCents": valueCents, "currency": "EUR", "source": "trade_republic",
                "provenance": wealthProvenance
            ]
        }
        var holdings: [[String: Any]] = [
            observedHolding(id: "1", name: "Vanguard All-World", assetClass: "ETF", valueCents: 4_250_000),
            observedHolding(id: "2", name: "German Gov Bond 2030", assetClass: "Bonds", valueCents: 1_500_000),
            observedHolding(id: "3", name: "Apple Inc.", assetClass: "Stocks", valueCents: 900_000)
        ]
        if includeUnavailableHolding {
            holdings.append([
                "availability": "unavailable", "id": "4", "name": "Unpriced position",
                "assetClass": "Unknown", "currency": "EUR", "source": "trade_republic",
                "provenance": [
                    "source": "trade_republic", "observedAt": observedAt,
                    "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"
                ]
            ])
        }
        let payload: [String: Any] = [
            "generatedAt": formatter.string(from: now), "currency": "EUR",
            "monthlyIncome": unavailableMetric, "fixedCosts": unavailableMetric,
            "discretionaryBuffer": unavailableMetric, "spent": unavailableMetric,
            "savingsGoal": unavailableMetric, "saved": unavailableMetric,
            "wealth": [
                "availability": "observed", "holdings": holdings, "provenance": wealthProvenance
            ]
        ]
        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    }

    /// Taller than the standard `frame` -- the wealth card sits well below
    /// the fold in the Finance scroll view, and these snapshots need the
    /// allocation ring itself in frame, not just the top of the screen.
    private var financeWealthFrame: CGSize { CGSize(width: 1512, height: 2200) }

    func testFinanceWealthAllocationSnapshot() throws {
        let summary = try wealthAllocationFinanceSummary(includeUnavailableHolding: true)
        render(
            FinanceView(summary: summary, usesVisualFixtures: false),
            named: "FinanceView-wealth-allocation",
            frameSize: financeWealthFrame
        )
    }

    func testFinanceWealthAllocationReduceMotionSnapshot() throws {
        let summary = try wealthAllocationFinanceSummary(includeUnavailableHolding: true)
        render(
            FinanceView(summary: summary, usesVisualFixtures: false),
            named: "FinanceView-wealth-allocation-reduce-motion",
            frameSize: financeWealthFrame,
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    func testFinanceWealthHoldingsUnavailableSnapshot() {
        render(
            FinanceView(summary: nil, usesVisualFixtures: false),
            named: "FinanceView-wealth-unavailable",
            frameSize: financeWealthFrame
        )
    }

    // MARK: - RF-03/RF-02(honest half)/RF-20/RF-21 Analytics & Tools

    func testFinanceAnalyticsEntryListSnapshot() {
        render(
            FinanceAnalyticsView(
                snapshot: FinanceDisplaySnapshot(summary: nil, transactions: nil, usesVisualFixtures: true),
                onOpenConnections: nil,
                selectedRange: .constant(.month),
                selectedNetWorthPoint: .constant(nil),
                selectedEntry: .constant(nil),
                heroNamespace: nil,
                onClose: {}
            ),
            named: "FinanceAnalytics-entry-list"
        )
    }

    func testFinanceAnalyticsEntryListReduceMotionSnapshot() {
        render(
            FinanceAnalyticsView(
                snapshot: FinanceDisplaySnapshot(summary: nil, transactions: nil, usesVisualFixtures: true),
                onOpenConnections: nil,
                selectedRange: .constant(.month),
                selectedNetWorthPoint: .constant(nil),
                selectedEntry: .constant(nil),
                heroNamespace: nil,
                onClose: {}
            ),
            named: "FinanceAnalytics-entry-list-reduce-motion",
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    /// RF-03: Wealth is a real, working Analytics route — allocation
    /// breakdown, holdings, and the net-worth chart + linear projection, the
    /// exact same `FinanceWealthCard`/`FinanceDetailChartCard` the main
    /// Finance screen renders.
    func testFinanceAnalyticsWealthSnapshot() throws {
        let summary = try wealthAllocationFinanceSummary(includeUnavailableHolding: true)
        render(
            FinanceAnalyticsView(
                snapshot: FinanceDisplaySnapshot(summary: summary, transactions: nil, usesVisualFixtures: false),
                onOpenConnections: nil,
                selectedRange: .constant(.month),
                selectedNetWorthPoint: .constant(nil),
                selectedEntry: .constant(.wealth),
                heroNamespace: nil,
                onClose: {}
            ),
            named: "FinanceAnalytics-wealth",
            frameSize: financeWealthFrame
        )
    }

    /// RF-03: spending-abroad has no data source — `FinanceStatementImporter`
    /// rejects non-EUR rows at import — so this must render an honest
    /// unavailable state naming that reason, never a fabricated screen.
    func testFinanceAnalyticsSpendingAbroadUnavailableSnapshot() {
        render(
            FinanceAnalyticsView(
                snapshot: FinanceDisplaySnapshot(summary: nil, transactions: nil, usesVisualFixtures: true),
                onOpenConnections: nil,
                selectedRange: .constant(.month),
                selectedNetWorthPoint: .constant(nil),
                selectedEntry: .constant(.spendingAbroad),
                heroNamespace: nil,
                onClose: {}
            ),
            named: "FinanceAnalytics-spending-abroad-unavailable"
        )
    }

    /// RF-02 (honest-state half): no country/foreign-currency data is
    /// ingested, so Travel renders an honest unavailable state rather than a
    /// globe, map, or fabricated trip count. The feature half (trip model,
    /// map UI) is out of scope pending a product decision — see HANDOFF.
    func testFinanceAnalyticsTravelUnavailableSnapshot() {
        render(
            FinanceAnalyticsView(
                snapshot: FinanceDisplaySnapshot(summary: nil, transactions: nil, usesVisualFixtures: true),
                onOpenConnections: nil,
                selectedRange: .constant(.month),
                selectedNetWorthPoint: .constant(nil),
                selectedEntry: .constant(.travel),
                heroNamespace: nil,
                onClose: {}
            ),
            named: "FinanceAnalytics-travel-unavailable"
        )
    }

    /// RF-20/RF-21: `FinanceDetailRoute.wealth` opens Finance directly into
    /// the Analytics wealth route (not a bespoke wealth-only screen), and the
    /// range/asset selection this view starts with is the same `@State` the
    /// main detail panel uses — there is no parallel selection model to fall
    /// out of sync.
    func testFinanceViewWealthRouteOpensAnalyticsSnapshot() throws {
        let summary = try wealthAllocationFinanceSummary(includeUnavailableHolding: false)
        render(
            FinanceView(summary: summary, usesVisualFixtures: false, initialDetail: .wealth),
            named: "FinanceView-wealth-route",
            frameSize: financeWealthFrame
        )
    }

    func testFinanceAnalyticsEntryCardOnMainScreenSnapshot() {
        render(
            FinanceView(summary: nil, usesVisualFixtures: true, initialDetail: .spend),
            named: "FinanceView-analytics-entry-card",
            frameSize: financeWealthFrame
        )
    }

    func testFitnessTodaySnapshot() {
        render(
            FitnessView(
                snapshot: .demo,
                initialSection: .today,
                selectedDate: visualFixtureAnchor,
                usesVisualFixtures: true
            ),
            named: "FitnessView-today-dark",
            colorScheme: .dark
        )
    }

    func testFitnessTodayLightSnapshot() {
        render(
            FitnessView(
                snapshot: .demo,
                initialSection: .today,
                selectedDate: visualFixtureAnchor,
                usesVisualFixtures: true
            ),
            named: "FitnessView-today-light",
            colorScheme: .light
        )
    }

    /// Bevel IMG_0396–IMG_0401 core-detail tranche. The three entry points
    /// intentionally render the detail surface directly so the attachments
    /// are focused review evidence rather than a screenshot of a navigation
    /// side effect. Fixtures remain explicitly labelled by FitnessView.
    func testFitnessCoreDetailLoadRecoverySleepLightDarkReduceMotionSnapshots() {
        let entries: [(String, FitnessWidgetEntryPoint)] = [
            ("load", .strain),
            ("recovery", .recovery),
            ("sleep", .sleep)
        ]

        for (name, entryPoint) in entries {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let appearance = scheme == .dark ? "dark" : "light"
                render(
                    FitnessView(
                        snapshot: .demo,
                        initialSection: .today,
                        initialFitnessEntryPoint: entryPoint,
                        selectedDate: visualFixtureAnchor,
                        usesVisualFixtures: true
                    ),
                    named: "FitnessCoreDetail-\(name)-\(appearance)-reduce-motion",
                    colorScheme: scheme,
                    reduceMotion: true
                )
            }
        }
    }

    /// Bevel IMG_0405–IMG_0412 Stress detail: the fixture remains labelled,
    /// subtype tabs stay independent, and production-unavailable remains a
    /// truthful no-data surface. The wide frame exercises the responsive Mac
    /// layout while the same view is shared with iPhone.
    func testFitnessStressDetailLightDarkAndProductionUnavailableSnapshots() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let appearance = scheme == .dark ? "dark" : "light"
            render(
                FitnessStressDetailView(
                    snapshot: .demo(anchor: visualFixtureAnchor),
                    selectedDate: .constant(visualFixtureAnchor)
                ),
                named: "FitnessStressDetail-\(appearance)-reduce-motion",
                frameSize: CGSize(width: 1_200, height: frame.height),
                colorScheme: scheme,
                reduceMotion: true
            )
        }
        render(
            FitnessStressDetailView(
                snapshot: .unavailable,
                selectedDate: .constant(visualFixtureAnchor)
            ),
            named: "FitnessStressDetail-production-unavailable",
            frameSize: CGSize(width: 1_200, height: frame.height),
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    /// Production truth check for the Sleep detail: no fixture banner or
    /// fabricated stages/quality may appear when the source is unavailable.
    func testFitnessCoreDetailSleepProductionUnavailableSnapshot() {
        render(
            FitnessView(
                snapshot: .unavailable,
                initialSection: .today,
                initialFitnessEntryPoint: .sleep,
                selectedDate: visualFixtureAnchor
            ),
            named: "FitnessCoreDetail-sleep-production-unavailable",
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    func testFitnessJournalLightDarkSnapshots() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(
                FitnessView(
                    snapshot: .demo,
                    initialSection: .journal,
                    selectedDate: visualFixtureAnchor,
                    usesVisualFixtures: true
                ),
                named: "FitnessJournalView-\(suffix)",
                colorScheme: scheme,
                reduceMotion: true
            )
        }
    }

    func testFitnessJournalSaveErrorSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-journal-snapshot-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let failingStore = FitnessJournalStore(persistenceURL: root)
        _ = failingStore.upsert(FitnessJournalRecord(
            id: "snapshot-failure",
            title: "Hydration",
            emoji: "💧",
            section: .day,
            date: visualFixtureAnchor,
            quantity: 100,
            unit: "ml"
        ))
        XCTAssertNotNil(failingStore.lastSaveError)
        render(
            FitnessView(
                snapshot: .unavailable,
                initialSection: .journal,
                selectedDate: visualFixtureAnchor,
                journalStore: failingStore
            ),
            named: "FitnessJournalView-save-error",
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    func testFitnessActivityPerformanceLightDarkSnapshots() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(
                FitnessView(
                    snapshot: .demo,
                    initialSection: .fitness,
                    selectedDate: visualFixtureAnchor,
                    usesVisualFixtures: true
                ),
                named: "FitnessActivityPerformance-\(suffix)",
                colorScheme: scheme,
                reduceMotion: true
            )
        }
    }

    /// Bevel IMG_0394–0395 Biology surface. The explicit fixture contains
    /// source-labelled metric trends but intentionally keeps biological age
    /// unavailable until a reviewed model exists.
    func testFitnessBiologyLightDarkSnapshots() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(
                FitnessView(
                    snapshot: .demo,
                    initialSection: .biology,
                    selectedDate: visualFixtureAnchor,
                    usesVisualFixtures: true
                ),
                named: "FitnessBiology-\(suffix)",
                colorScheme: scheme,
                reduceMotion: true
            )
        }
    }

    /// IMG_0393 Strength detail uses the explicit visual fixture only for
    /// deterministic review; no live workout source is implied here.
    func testFitnessStrengthDetailLightDarkSnapshots() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            render(
                FitnessStrengthDetailView(
                    snapshot: FitnessStrengthSnapshot.demo(anchor: visualFixtureAnchor),
                    templateStore: FitnessStrengthTemplateStore(persistenceURL: nil)
                ),
                named: "FitnessStrengthDetail-\(suffix)",
                colorScheme: scheme,
                reduceMotion: true
            )
        }
    }

    func testFitnessNutritionSnapshot() {
        render(
            FitnessView(
                snapshot: .demo,
                initialSection: .nutrition,
                selectedDate: visualFixtureAnchor,
                usesVisualFixtures: true
            ),
            named: "FitnessView-nutrition",
            colorScheme: .dark
        )
    }

    func testFitnessNutritionLightSnapshot() {
        render(
            FitnessView(
                snapshot: .demo,
                initialSection: .nutrition,
                selectedDate: visualFixtureAnchor,
                usesVisualFixtures: true
            ),
            named: "FitnessView-nutrition-light",
            colorScheme: .light
        )
    }

    func testFitnessSupplementsSnapshot() {
        render(
            FitnessView(
                snapshot: .demo,
                initialSection: .supplements,
                selectedDate: visualFixtureAnchor,
                usesVisualFixtures: true
            ),
            named: "FitnessView-supplements",
            reduceMotion: true
        )
    }

    func testUsageSnapshot() {
        render(UsageView(snapshots: DemoDataProvider.providers, analytics: DemoUsageAnalytics.snapshots, state: .demo), named: "UsageView", colorScheme: .light)
    }

    func testUsageReduceMotionSnapshot() {
        render(
            UsageView(snapshots: DemoDataProvider.providers, analytics: DemoUsageAnalytics.snapshots, state: .demo),
            named: "UsageView-dark-reduce-motion",
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    func testUsageSettledSnapshot() {
        render(
            UsageView(snapshots: DemoDataProvider.providers, analytics: DemoUsageAnalytics.snapshots, state: .demo),
            named: "UsageView-dark-settled",
            colorScheme: .dark
        )
    }

    func testUsageEntranceMotionComparisonSnapshot() {
        render(
            UsageView(snapshots: DemoDataProvider.providers, analytics: DemoUsageAnalytics.snapshots, state: .demo),
            named: "UsageView-dark-entrance-normal",
            colorScheme: .dark,
            settleInterval: 0.12
        )
        render(
            UsageView(snapshots: DemoDataProvider.providers, analytics: DemoUsageAnalytics.snapshots, state: .demo),
            named: "UsageView-dark-entrance-reduce-motion",
            colorScheme: .dark,
            reduceMotion: true,
            settleInterval: 0.12
        )
    }

    func testGlowRingSettledNormalSnapshot() {
        render(
            GlowRing(progress: 0.72, diameter: 148, lineWidth: 8) {
                Text("72%")
                    .lifeOSTypography(.pageTitle)
            }
            .frame(width: 220, height: 220)
            .background(LifeOSTokens.canvas),
            named: "GlowRing-settled-normal-no-halo",
            colorScheme: .dark,
            settleInterval: 1.2
        )
    }

    func testGlowRingReduceMotionSnapshot() {
        render(
            GlowRing(progress: 0.72, diameter: 148, lineWidth: 8) {
                Text("72%")
                    .lifeOSTypography(.pageTitle)
            }
            .frame(width: 220, height: 220)
            .background(LifeOSTokens.canvas),
            named: "GlowRing-reduce-motion-no-halo",
            colorScheme: .dark,
            reduceMotion: true,
            settleInterval: 0.2
        )
    }

    func testUsageTokenActivityReduceMotionSelectedSnapshot() {
        guard let analytics = DemoUsageAnalytics.snapshots.first(where: { $0.provider == .codex }),
              let selectedDate = analytics.activity.last?.date else {
            XCTFail("Codex demo analytics must include a token-activity point")
            return
        }

        render(
            UsageTokenActivityView(
                provider: .codex,
                activity: analytics.activity,
                initialSelectedDate: selectedDate
            ),
            named: "UsageTokenActivity-dark-reduce-motion-selected",
            colorScheme: .dark,
            reduceMotion: true
        )
    }

    func testTaxDocumentsSnapshot() {
        render(TaxDocumentsView(), named: "TaxDocumentsView")
    }

    func testDarkModeSnapshots() {
        let anchor = visualFixtureAnchor
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(anchor: anchor, calendar: visualFixtureCalendar),
            usesVisualFixtures: true
        )
        render(LifeOSMacRootView(calendarCoordinator: coordinator, usesVisualFixtures: true, usageCoordinator: UsageCoordinator()), named: "LifeOSMacRootView-overview-dark", colorScheme: .dark)
        render(UsageView(snapshots: DemoDataProvider.providers, analytics: DemoUsageAnalytics.snapshots, state: .demo), named: "UsageView-dark", colorScheme: .dark)
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

    private func render<V: View>(
        _ view: V,
        named name: String,
        frameSize: CGSize? = nil,
        colorScheme: ColorScheme? = nil,
        reduceMotion: Bool = false,
        settleInterval: TimeInterval = 1.0
    ) {
        let renderSize = frameSize ?? frame
        let motionView = view.environment(\._accessibilityReduceMotion, reduceMotion)
        let rootView: AnyView = if let colorScheme {
            AnyView(motionView.environment(\.colorScheme, colorScheme))
        } else {
            AnyView(motionView)
        }

        let hostingView = NSHostingView(
            rootView: rootView
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(width: renderSize.width, height: renderSize.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: renderSize)

        // Hosting the real view hierarchy in an off-screen AppKit window exercises
        // NavigationSplitView and other AppKit-backed SwiftUI containers that
        // ImageRenderer replaces with unsupported-content placeholders.
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        if let colorScheme {
            window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        }
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        // Allow SwiftUI tasks and chart entrance animations to settle before
        // capturing; callers can use a short deterministic interval to inspect entrance state.
        RunLoop.main.run(until: Date().addingTimeInterval(settleInterval))
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

private actor MacObservationGate {
    private var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        calls += 1
        let pending = startedWaiters
        startedWaiters.removeAll()
        pending.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func count() -> Int { calls }

    func release() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
