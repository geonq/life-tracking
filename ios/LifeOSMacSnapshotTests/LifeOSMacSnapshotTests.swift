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

    func testOverviewSnapshot() {
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarVisualFixtures.snapshot(),
            usesVisualFixtures: true
        )
        render(LifeOSMacRootView(calendarCoordinator: coordinator, usesVisualFixtures: true, usageCoordinator: UsageCoordinator()), named: "LifeOSMacRootView-overview")
    }

    func testOverviewResponsiveLightDarkAndUnavailableEvidence() {
        for width in [900.0, 1_200.0, 1_512.0] {
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
            GlowRing(progress: 0.72, hue: .blue, diameter: 148, lineWidth: 8) {
                Text("72%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
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
            GlowRing(progress: 0.72, hue: .blue, diameter: 148, lineWidth: 8) {
                Text("72%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
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
