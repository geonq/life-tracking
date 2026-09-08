import XCTest
import SwiftUI
import UIKit
@testable import LifeOS

final class LifeOSDesignSystemTests: XCTestCase {
    func testTypographyFacadeExposesEveryContractRole() {
        let roles: [Font] = [
            LifeOSTypography.pageTitle(),
            LifeOSTypography.sectionTitle(),
            LifeOSTypography.cardTitle(),
            LifeOSTypography.body(),
            LifeOSTypography.label(),
            LifeOSTypography.metadata(),
            LifeOSTypography.metric(),
            LifeOSTypography.metricCompact(),
            LifeOSTypography.button(),
        ]

        XCTAssertEqual(roles.count, 9)
    }

    func testTypographyRolesUseExactSystemSizesWeightsAndMetricDigits() {
        let contracts: [(String, Font, Font)] = [
            ("pageTitle", LifeOSTypography.pageTitle(), .system(size: 28, weight: .bold, design: .default)),
            ("sectionTitle", LifeOSTypography.sectionTitle(), .system(size: 20, weight: .semibold, design: .default)),
            ("cardTitle", LifeOSTypography.cardTitle(), .system(size: 17, weight: .semibold, design: .default)),
            ("body", LifeOSTypography.body(), .system(size: 17, weight: .regular, design: .default)),
            ("label", LifeOSTypography.label(), .system(size: 15, weight: .medium, design: .default)),
            ("metadata", LifeOSTypography.metadata(), .system(size: 13, weight: .regular, design: .default)),
            ("metric", LifeOSTypography.metric(), .system(size: 36, weight: .semibold, design: .default).monospacedDigit()),
            ("metricCompact", LifeOSTypography.metricCompact(), .system(size: 24, weight: .semibold, design: .default).monospacedDigit()),
            ("button", LifeOSTypography.button(), .system(size: 15, weight: .semibold, design: .default)),
        ]

        for (role, actual, expected) in contracts {
            XCTAssertEqual(actual, expected, "Typography role \(role) does not match its contract")
        }
    }

    @MainActor
    func testDynamicTypographyRolesKeepBaseSizesAnchorsAndMetricPolicy() {
        let contracts: [(LifeOSTypography.Role, CGFloat, Font.TextStyle, Font.Weight, CGFloat, CGFloat, Bool)] = [
            (.pageTitle, 28, .title, .bold, -0.4, 0, false),
            (.sectionTitle, 20, .title2, .semibold, -0.2, 0, false),
            (.cardTitle, 17, .headline, .semibold, 0, 0, false),
            (.body, 17, .body, .regular, 0, 3, false),
            (.label, 15, .subheadline, .medium, 0, 0, false),
            (.metadata, 13, .footnote, .regular, 0, 0, false),
            (.metric, 36, .largeTitle, .semibold, -0.6, 0, true),
            (.metricCompact, 24, .title2, .semibold, -0.3, 0, true),
            (.button, 15, .headline, .semibold, 0, 0, false),
        ]

        XCTAssertEqual(Set(LifeOSTypography.Role.allCases), Set(contracts.map(\.0)))
        for (role, size, anchor, weight, tracking, lineSpacing, monospacedDigits) in contracts {
            XCTAssertEqual(role.baseSize, size, "Unexpected base size for \(role)")
            XCTAssertEqual(role.dynamicTypeAnchor, anchor, "Unexpected Dynamic Type anchor for \(role)")
            XCTAssertEqual(role.defaultWeight, weight, "Unexpected default weight for \(role)")
            XCTAssertEqual(role.tracking, tracking, "Unexpected tracking for \(role)")
            XCTAssertEqual(role.lineSpacing, lineSpacing, "Unexpected line spacing for \(role)")
            XCTAssertEqual(role.usesMonospacedDigits, monospacedDigits, "Unexpected digit policy for \(role)")
        }
    }

    @MainActor
    func testDynamicTypographyModifierActuallyScalesAtAccessibilitySize() {
        func measuredWidth(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
            let rootView = Text("MMMMMMMM")
                .lifeOSTypography(.pageTitle)
                .fixedSize()
                .environment(\.dynamicTypeSize, dynamicTypeSize)
            let controller = UIHostingController(rootView: rootView)
            controller.view.frame = CGRect(x: 0, y: 0, width: 1_000, height: 200)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return controller.sizeThatFits(in: CGSize(width: 1_000, height: 200)).width
        }

        let defaultWidth = measuredWidth(for: .large)
        let accessibilityWidth = measuredWidth(for: .accessibility3)
        XCTAssertGreaterThan(
            accessibilityWidth,
            defaultWidth,
            "The ScaledMetric-backed role modifier must respond to Dynamic Type"
        )
    }

    func testDynamicTypographyModifierUsesTheDeclaredEnvironmentScalePath() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Shared/Typography.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@ScaledMetric private var scaledSize: CGFloat"))
        XCTAssertTrue(source.contains("relativeTo: role.dynamicTypeAnchor"))
        XCTAssertTrue(source.contains(".font(.system(size: scaledSize, weight: weight, design: .default))"))
        XCTAssertFalse(source.contains("Font.system(."), "The role modifier must retain its custom base sizes")
    }

    func testOwnedTypographyProductSourcesUseOnlyTheSystemDefaultDesign() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ownedProductFiles = [
            "Shared/Typography.swift",
            "LifeOS/OverviewView.swift",
            "LifeOSMacSnapshotTests/LifeOSMacSnapshotTests.swift",
        ]
        let roundedDesign = "design: " + "." + "rounded"
        let customFont = "Font" + "." + "custom"
        let legacyFontFacade = "LifeOS" + "Font" + "."

        for relativePath in ownedProductFiles {
            let source = try String(
                contentsOf: iosRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains(roundedDesign), "Rounded design remains in \(relativePath)")
            XCTAssertFalse(source.contains(customFont), "Custom font remains in \(relativePath)")
            XCTAssertFalse(source.contains(legacyFontFacade), "Legacy font facade remains in \(relativePath)")
        }
    }

    func testSelectedNavigationColorsMatchBothAppearancePairs() {
        XCTAssertEqual(LifeOSSelectedNavigationPalette.darkForegroundHex, 0xB8D5FE)
        XCTAssertEqual(LifeOSSelectedNavigationPalette.darkBackgroundHex, 0x011E47)
        XCTAssertEqual(LifeOSSelectedNavigationPalette.lightForegroundHex, 0x0244A2)
        XCTAssertEqual(LifeOSSelectedNavigationPalette.lightBackgroundHex, 0xE6F0FF)

        XCTAssertNotEqual(
            LifeOSSelectedNavigationPalette.darkForegroundHex,
            LifeOSSelectedNavigationPalette.darkBackgroundHex
        )
        XCTAssertNotEqual(
            LifeOSSelectedNavigationPalette.lightForegroundHex,
            LifeOSSelectedNavigationPalette.lightBackgroundHex
        )
        XCTAssertNotEqual(
            LifeOSSelectedNavigationPalette.darkForegroundHex,
            0x5DA0FD
        )
    }

    func testSharedSpacingRadiiAndTargetsUseTheFoundationContract() {
        XCTAssertEqual(
            [
                LifeOSTokens.Space.xxs,
                LifeOSTokens.Space.xs,
                LifeOSTokens.Space.sm,
                LifeOSTokens.Space.md,
                LifeOSTokens.Space.lg,
                LifeOSTokens.Space.xl,
                LifeOSTokens.Space.xxl,
                LifeOSTokens.Space.xxxl,
            ],
            [4, 8, 12, 16, 20, 24, 32, 40]
        )
        XCTAssertEqual([LifeOSTokens.Radius.control, LifeOSTokens.Radius.card, LifeOSTokens.Radius.hero], [10, 16, 24])
        XCTAssertEqual(LifeOSTokens.Control.minimumTarget, 44)
    }

    /// Quiet Machine §2.5/§4.1: no shadows at rest and exactly one hairline
    /// border identity shared by every border alias.
    func testVisualOverhaulShadowPolicyAndHairlineContract() {
        XCTAssertEqual(LifeOSTokens.cardShadowRadius, 0)
        XCTAssertEqual(LifeOSTokens.cardShadowX, 0)
        XCTAssertEqual(LifeOSTokens.cardShadowY, 0)

        // quietBorder/chartGrid are aliases of THE hairline; the retired
        // opacity variants are gone (same instance ⇒ equal).
        XCTAssertEqual(LifeOSTokens.quietBorder, LifeOSTokens.hairlineBorder)
        XCTAssertEqual(LifeOSTokens.chartGrid, LifeOSTokens.hairlineBorder)
        XCTAssertEqual(LifeOSTokens.hairlineBorder, LifeOSTokens.subtleBorder)

        // One accent: teal `info` is retired as an alias of accent.
        XCTAssertEqual(LifeOSTokens.info, LifeOSTokens.accent)

        // Chart series semantics per §2.4.
        // Estimates are vivid green by current product decision, deliberately
        // distinct from the amber `warning` semantic and target token.
        XCTAssertEqual(LifeOSTokens.Series.estimate, Color.lifeOSSeriesEstimate)
        XCTAssertNotEqual(LifeOSTokens.Series.estimate, LifeOSTokens.warning)
        XCTAssertNotEqual(LifeOSTokens.Series.estimate, LifeOSTokens.Series.target)
        XCTAssertEqual(LifeOSTokens.Series.target, LifeOSTokens.success)
        XCTAssertEqual(LifeOSTokens.Series.history, LifeOSTokens.metadataText)
    }

    func testResponsiveMetricsKeepMobileAndWideDesktopContracts() {
        let phone = LifeOSResponsiveMetrics(width: 390)
        XCTAssertTrue(phone.isCompact)
        XCTAssertEqual(phone.horizontalGutter, 16)
        XCTAssertEqual(phone.sectionSpacing, 32)
        XCTAssertFalse(phone.supportsTwoColumnLayout)

        let regularSingleColumn = LifeOSResponsiveMetrics(width: 600)
        XCTAssertFalse(regularSingleColumn.isCompact)
        XCTAssertFalse(regularSingleColumn.supportsTwoColumnLayout)

        let justBelow = LifeOSResponsiveMetrics(width: 719)
        XCTAssertFalse(justBelow.isCompact)
        XCTAssertFalse(justBelow.supportsTwoColumnLayout)

        let atBreakpoint = LifeOSResponsiveMetrics(width: 720)
        XCTAssertFalse(atBreakpoint.isCompact)
        XCTAssertTrue(atBreakpoint.supportsTwoColumnLayout)

        let justAbove = LifeOSResponsiveMetrics(width: 721)
        XCTAssertFalse(justAbove.isCompact)
        XCTAssertTrue(justAbove.supportsTwoColumnLayout)

        let wideMac = LifeOSResponsiveMetrics(width: 1_600)
        XCTAssertEqual(wideMac.horizontalGutter, 32)
        XCTAssertEqual(wideMac.sectionSpacing, 40)
        XCTAssertEqual(wideMac.maxContentWidth, 1_120)
        XCTAssertEqual(wideMac.maxChartWidth, 1_440)
    }

    func testResponsiveMetricsClampStandardPageWidthAtEveryWidthClass() {
        XCTAssertEqual(LifeOSResponsiveMetrics.compactBreakpoint, 600)
        XCTAssertEqual(LifeOSResponsiveMetrics.twoColumnBreakpoint, 720)
        XCTAssertEqual(LifeOSTokens.contentMaxWidth, 1_120)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 320).maxContentWidth, 320)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 719).maxContentWidth, 719)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 720).maxContentWidth, 720)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 1_119).maxContentWidth, 1_119)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 1_120).maxContentWidth, 1_120)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 1_600).maxContentWidth, 1_120)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: -.infinity).maxContentWidth, 0)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: .infinity).maxContentWidth, 1_120)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: .nan).maxContentWidth, 0)
    }

    func testFinanceResponsiveLayoutStacksAt720AndAccessibilitySizes() {
        XCTAssertTrue(FinanceResponsiveLayoutContract.usesStackedLayout(
            contentWidth: 343,
            accessibilitySize: false
        ))
        XCTAssertTrue(FinanceResponsiveLayoutContract.usesStackedLayout(
            contentWidth: 719,
            accessibilitySize: false
        ))
        XCTAssertFalse(FinanceResponsiveLayoutContract.usesStackedLayout(
            contentWidth: 720,
            accessibilitySize: false
        ))
        XCTAssertTrue(FinanceResponsiveLayoutContract.usesStackedLayout(
            contentWidth: 1_120,
            accessibilitySize: true
        ))
        XCTAssertTrue(FinanceResponsiveLayoutContract.usesStackedChartAndCategories(
            contentWidth: 959,
            accessibilitySize: false
        ))
        XCTAssertFalse(FinanceResponsiveLayoutContract.usesStackedChartAndCategories(
            contentWidth: 960,
            accessibilitySize: false
        ))
        XCTAssertTrue(FinanceResponsiveLayoutContract.usesStackedChartAndCategories(
            contentWidth: 1_120,
            accessibilitySize: true
        ))

        XCTAssertEqual(
            FinanceResponsiveLayoutContract.metricColumnCount(contentWidth: 343, accessibilitySize: false),
            1
        )
        XCTAssertEqual(
            FinanceResponsiveLayoutContract.metricColumnCount(contentWidth: 720, accessibilitySize: false),
            2
        )
        XCTAssertEqual(
            FinanceResponsiveLayoutContract.metricColumnCount(contentWidth: 1_120, accessibilitySize: false),
            3
        )
        XCTAssertEqual(
            FinanceResponsiveLayoutContract.metricColumnCount(contentWidth: 1_120, accessibilitySize: true),
            1
        )
    }

    func testFinanceDetailSelectorUsesMeasuredMenuFallbackBeforePillsCanOverflow() {
        XCTAssertEqual(
            FinanceDetail.allCases.map(\.title),
            ["Spend", "Income", "Cash flow", "Net worth"],
            "The fallback must retain the same four detail identities and labels"
        )
        XCTAssertTrue(
            FinanceDetailSelectorLayoutContract.usesMenu(
                availableWidth: 343,
                accessibilitySize: false
            )
        )
        XCTAssertTrue(
            FinanceDetailSelectorLayoutContract.usesMenu(
                availableWidth: 359.9,
                accessibilitySize: false
            )
        )
        XCTAssertFalse(
            FinanceDetailSelectorLayoutContract.usesMenu(
                availableWidth: 360,
                accessibilitySize: false
            )
        )
        XCTAssertTrue(
            FinanceDetailSelectorLayoutContract.usesMenu(
                availableWidth: 520,
                accessibilitySize: true
            )
        )
        XCTAssertTrue(
            FinanceDetailSelectorLayoutContract.usesMenu(
                availableWidth: 520,
                accessibilitySize: false,
                pillIntrinsicWidth: 521
            )
        )
        XCTAssertTrue(
            FinanceDetailSelectorLayoutContract.usesMenu(
                availableWidth: .nan,
                accessibilitySize: false
            )
        )
    }

    func testRecoveryHeroStacksAtInsufficientWidthAndAccessibilitySizes() {
        XCTAssertTrue(
            FitnessReadinessHeroLayoutPolicy.usesStackedLayout(
                contentWidth: 339,
                accessibilitySize: false
            )
        )
        XCTAssertFalse(
            FitnessReadinessHeroLayoutPolicy.usesStackedLayout(
                contentWidth: 340,
                accessibilitySize: false
            )
        )
        XCTAssertTrue(
            FitnessReadinessHeroLayoutPolicy.usesStackedLayout(
                contentWidth: 1_120,
                accessibilitySize: true
            )
        )
        XCTAssertTrue(
            FitnessReadinessHeroLayoutPolicy.usesStackedLayout(
                contentWidth: .infinity,
                accessibilitySize: false
            )
        )
    }

    func testSelectorMotionIsScopedToHighlightAndPreservesReduceMotion() throws {
        XCTAssertNil(LifeOSMotion.curve(for: .selection, reduceMotion: true))
        XCTAssertEqual(
            LifeOSMotion.curve(for: .selection, reduceMotion: false),
            LifeOSMotion.Timing.snappy
        )

        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let motionSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Shared/LifeOSMotionKit.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(motionSource.contains("withAnimation(LifeOSMotion.selector) { selection = option }"))
        XCTAssertTrue(motionSource.contains("LifeOSMotion.withoutAnimation { selection = option }"))
        XCTAssertTrue(motionSource.contains(".matchedGeometryEffect(id: highlightID"))
        XCTAssertTrue(motionSource.contains("transaction.animation = nil"))
        XCTAssertFalse(
            motionSource.contains(".animation(LifeOSMotion.curve(for: .selection, reduceMotion: reduceMotion)?.animation, value: selection)"),
            "The selector must not animate its entire subtree from a selection value change"
        )
    }

    func testRetiredCardAliasesHaveNoOwnedDefinitionsAfterCallSiteAudit() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tokensSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Shared/DesignTokens.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(tokensSource.contains("func lifeOSCard()"))
        XCTAssertFalse(tokensSource.contains("func glassCard("))
        XCTAssertFalse(tokensSource.contains("LifeOSCardModifier"))
    }

    func testFitnessCoreColumnsHonorSharedBreakpointAndAccessibilityFallback() {
        XCTAssertEqual(
            FitnessCoreColumnsPolicy.columnCount(
                for: 611,
                minColumnWidth: 300,
                spacing: 12,
                subviewCount: 2
            ),
            1
        )
        XCTAssertEqual(
            FitnessCoreColumnsPolicy.columnCount(
                for: LifeOSResponsiveMetrics.twoColumnBreakpoint,
                minColumnWidth: 300,
                spacing: 12,
                subviewCount: 2
            ),
            2
        )
        XCTAssertEqual(
            FitnessCoreColumnsPolicy.columnCount(
                for: 1_120,
                minColumnWidth: 300,
                spacing: 12,
                subviewCount: 3
            ),
            3
        )
        XCTAssertEqual(
            FitnessCoreColumnsPolicy.columnCount(
                for: 1_120,
                minColumnWidth: 300,
                spacing: 12,
                subviewCount: 2,
                forceSingleColumn: true
            ),
            1
        )
    }

    func testInteractionStateRespectsReduceMotionWithoutDisablingUserMotion() {
        let state = LifeOSInteractionState.resolve(
            pressed: true,
            hovered: true,
            focused: false,
            reduceMotion: true
        )

        XCTAssertEqual(state.phase, .pressed)
        XCTAssertFalse(state.allowsDecorativeMotion)
        XCTAssertTrue(state.allowsUserDrivenMotion)
        XCTAssertEqual(
            LifeOSInteractionAppearance.resolve(for: state).contentOpacity,
            0.78,
            accuracy: 0.0001
        )
    }

    func testDirectionalClassifierWaitsForDistanceAndDominance() {
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 7, height: 0)), .undecided)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 8, height: 0)), .horizontal)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 20, height: 10)), .horizontal)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 10, height: 20)), .vertical)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 10, height: 9)), .undecided)
    }

    func testCancellationIsExplicitAndDoesNotInventACommit() {
        let cancellation = LifeOSInteractionCancellation.cancelled(reason: "Vertical intent")

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(cancellation.reason, "Vertical intent")
        XCTAssertFalse(LifeOSInteractionCancellation.active.isCancelled)
    }
    func testCanonicalMotionTimingsAndCompatibilityAliases() {
        XCTAssertEqual(LifeOSMotion.Timing.press, .easeOut(0.08))
        XCTAssertEqual(LifeOSMotion.Timing.release, .easeOut(0.14))
        XCTAssertEqual(LifeOSMotion.Timing.hover, .easeOut(0.12))
        XCTAssertEqual(LifeOSMotion.Timing.primary, .spring(response: 0.42, damping: 0.86))
        XCTAssertEqual(LifeOSMotion.Timing.snappy, .spring(response: 0.24, damping: 0.90))
        XCTAssertEqual(LifeOSMotion.Timing.hero, .spring(response: 0.32, damping: 0.92))
        XCTAssertEqual(LifeOSMotion.Timing.ring, .easeOut(0.42))
        XCTAssertEqual(LifeOSMotion.Timing.tracking, .interactive(response: 0.18, damping: 0.90))
        XCTAssertEqual(LifeOSMotion.Timing.chart, .easeOut(0.36))
        XCTAssertEqual(LifeOSMotion.spring, LifeOSMotion.primary)
        XCTAssertEqual(LifeOSMotion.springSnappy, LifeOSMotion.snappy)
        XCTAssertEqual(LifeOSMotion.selector, LifeOSMotion.snappy)
        XCTAssertEqual(LifeOSMotion.card, LifeOSMotion.primary)
        XCTAssertEqual(LifeOSMotion.fingerTracking, LifeOSMotion.track)
        XCTAssertEqual(LifeOSMotion.chartReveal, LifeOSMotion.chartDraw)
    }

    func testMotionPolicyRetainsFeedbackAndDirectManipulation() {
        for reduced in [false, true] {
            XCTAssertNil(LifeOSMotion.curve(for: .scrub, reduceMotion: reduced))
            XCTAssertEqual(
                LifeOSMotion.curve(for: .press, reduceMotion: reduced),
                reduced ? nil : .easeOut(0.08)
            )
            XCTAssertEqual(
                LifeOSMotion.curve(for: .hover, reduceMotion: reduced),
                reduced ? nil : .easeOut(0.12)
            )
        }
        XCTAssertNil(LifeOSMotion.curve(for: .reveal, reduceMotion: true))
        XCTAssertNil(LifeOSMotion.curve(for: .cancel, reduceMotion: true))
        XCTAssertNil(LifeOSMotion.curve(for: .selection, reduceMotion: true))
        XCTAssertEqual(LifeOSMotion.curve(for: .navigation, reduceMotion: true), .easeOut(0.12))
        XCTAssertNil(LifeOSMotion.curve(for: .release, reduceMotion: true))
        XCTAssertEqual(LifeOSMotion.curve(for: .selection, reduceMotion: false), LifeOSMotion.Timing.snappy)
        XCTAssertEqual(LifeOSMotion.curve(for: .navigation, reduceMotion: false), LifeOSMotion.Timing.hero)
        XCTAssertEqual(LifeOSMotion.curve(for: .release, reduceMotion: false), LifeOSMotion.Timing.release)
        XCTAssertEqual(LifeOSMotion.curve(for: .cancel, reduceMotion: false), LifeOSMotion.Timing.snappy)
        XCTAssertEqual(LifeOSMotion.curve(for: .reveal, reduceMotion: false), LifeOSMotion.Timing.chart)
    }

    func testGestureCommitsOnceAndSettlesBackToFocusOverHover() throws {
        var state = LifeOSMotionLifecycle()
        state.send(.hover(true))
        XCTAssertEqual(state.phase, .hover)
        state.send(.focus(true))
        XCTAssertEqual(state.phase, .focus)
        state.send(.press)
        XCTAssertEqual(state.phase, .pressed)
        state.send(.hover(false))
        XCTAssertEqual(state.phase, .pressed)
        state.send(.drag)
        XCTAssertEqual(state.phase, .dragging)
        XCTAssertEqual(state.send(.end), .commit)
        XCTAssertEqual(state.phase, .settling)
        let id = try XCTUnwrap(state.settlementID)
        XCTAssertEqual(state.send(.end), .none)
        state.send(.settled(id))
        XCTAssertEqual(state.phase, .focus)
        XCTAssertNil(state.settlementID)
        state.send(.focus(false))
        XCTAssertEqual(state.phase, .idle)
    }

    func testNewGestureInvalidatesOldCompletionAndCancellationCannotCommit() throws {
        var state = LifeOSMotionLifecycle()
        state.send(.drag)
        state.send(.end)
        let previous = try XCTUnwrap(state.settlementID)
        state.send(.scrub)
        state.send(.settled(previous))
        XCTAssertEqual(state.phase, .scrubbing)
        XCTAssertNil(state.settlementID)
        XCTAssertEqual(state.send(.cancel), .discard)
        let cancellation = try XCTUnwrap(state.settlementID)
        XCTAssertEqual(state.send(.end), .none)
        XCTAssertEqual(state.send(.cancel), .none)
        XCTAssertEqual(state.phase, .cancelled)
        state.send(.hover(true))
        XCTAssertEqual(state.phase, .cancelled)
        state.send(.settled(cancellation))
        XCTAssertEqual(state.phase, .hover)
        state.send(.settled(previous))
        XCTAssertEqual(state.phase, .hover)
    }

    func testDisableDiscardsDraftAndRejectsLateEvents() throws {
        var state = LifeOSMotionLifecycle()
        state.send(.press)
        XCTAssertEqual(state.send(.enabled(false)), .discard)
        for event in [LifeOSMotionLifecycle.Event.end, .drag, .scrub, .press, .hover(true), .focus(true)] {
            XCTAssertEqual(state.send(event), .none)
            XCTAssertEqual(state.phase, .idle)
        }
        state.send(.enabled(true))
        state.send(.drag)
        state.send(.end)
        let completion = try XCTUnwrap(state.settlementID)
        XCTAssertEqual(state.send(.enabled(false)), .none) // already committed, no second discard
        state.send(.settled(completion))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.settlementID)
    }

    func testCancelDuringSettlementDoesNotUndoAlreadyCommittedData() throws {
        var state = LifeOSMotionLifecycle()
        XCTAssertEqual(state.send(.cancel), .none)
        XCTAssertEqual(state.send(.end), .none)
        state.send(.press)
        state.send(.end)
        let old = try XCTUnwrap(state.settlementID)
        XCTAssertEqual(state.send(.cancel), .none)
        state.send(.settled(old))
        XCTAssertEqual(state.phase, .cancelled)
        state.send(.press)
        XCTAssertEqual(state.phase, .pressed)
        XCTAssertNil(state.settlementID)
    }

    func testChartRevealPolicyNeverHidesRefreshOrScrubAndSanitizesProgress() {
        for presented in [false, true] {
            for interacting in [false, true] {
                for reduced in [false, true] {
                    XCTAssertEqual(LifeOSChartMotionPolicy.shouldReveal(
                        hasPresented: presented, interacting: interacting, reduceMotion: reduced),
                        !presented && !interacting && !reduced)
                }
            }
        }
        XCTAssertEqual(LifeOSChartMotionPolicy.progress(-1), 0)
        XCTAssertEqual(LifeOSChartMotionPolicy.progress(0.5), 0.5)
        XCTAssertEqual(LifeOSChartMotionPolicy.progress(2), 1)
        XCTAssertEqual(LifeOSChartMotionPolicy.progress(.nan), 1)
        XCTAssertEqual(LifeOSChartMotionPolicy.progress(.infinity), 1)
    }

    func testUsageViewportResetsAcrossObservationLossAndWindowSwitchWhileEmpty() {
        var viewport = UsageChartViewport()
        viewport.pinnedRangeStart = Date(timeIntervalSince1970: 1_780_000_000)
        viewport.zoomFactor = 0.25
        viewport.reconcile(windowChanged: false, hasObservations: true)
        XCTAssertNotNil(viewport.pinnedRangeStart)
        XCTAssertEqual(viewport.zoomFactor, 0.25)
        // Populated A → empty/loading A → empty B → populated B.
        for transition in [(false, false), (true, false), (false, true)] {
            viewport.reconcile(windowChanged: transition.0, hasObservations: transition.1)
            XCTAssertNil(viewport.pinnedRangeStart)
            XCTAssertEqual(viewport.zoomFactor, 1)
        }
        viewport.zoomFactor = 0.6
        viewport.reconcile(windowChanged: true, hasObservations: true)
        XCTAssertEqual(viewport.zoomFactor, 1)
    }

    func testChartPresentationSurvivesEmptyLoadingFailureWithoutReplayOrSpaceLoss() {
        var firstLoad = LifeOSChartPresentationState()
        firstLoad.recordHeight(280, isEmpty: true)
        XCTAssertFalse(firstLoad.hasRecordedContent)
        XCTAssertEqual(firstLoad.reservedHeight, 0)

        for reduced in [false, true] {
            var presentation = LifeOSChartPresentationState()
            XCTAssertEqual(presentation.reveal(interacting: false, reduceMotion: reduced), !reduced)
            presentation.recordHeight(280, isEmpty: false)
            // Empty, loading, failure, then a real populated observation again.
            for empty in [true, true, true, false] {
                let policy = LifeOSChartAvailabilityPolicy(isEmpty: empty)
                XCTAssertEqual(policy.allowsInspection, !empty)
                XCTAssertEqual(policy.contentOpacity, empty ? 0 : 1)
                presentation.recordHeight(empty ? 136 : 280, isEmpty: empty)
                XCTAssertEqual(presentation.reservedHeight, 280)
                XCTAssertFalse(presentation.reveal(interacting: false, reduceMotion: reduced))
            }
            presentation.recordHeight(.nan, isEmpty: false)
            XCTAssertEqual(presentation.reservedHeight, 280)
        }
        var interacting = LifeOSChartPresentationState()
        XCTAssertFalse(interacting.reveal(interacting: true, reduceMotion: false))
        XCTAssertFalse(interacting.reveal(interacting: false, reduceMotion: false))
    }

    func testChartPresentationSettlesInterruptedRevealWithoutReplay() {
        var presentation = LifeOSChartPresentationState()
        XCTAssertTrue(presentation.reveal(interacting: false, reduceMotion: false))

        presentation.settle()

        XCTAssertFalse(presentation.reveal(interacting: false, reduceMotion: false))
        XCTAssertTrue(presentation.hasPresented)
    }

}
