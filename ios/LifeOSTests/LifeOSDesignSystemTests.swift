import XCTest
@testable import LifeOS

final class LifeOSDesignSystemTests: XCTestCase {
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
        XCTAssertEqual([LifeOSTokens.Radius.control, LifeOSTokens.Radius.card, LifeOSTokens.Radius.hero], [8, 12, 16])
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
        XCTAssertEqual(LifeOSTokens.Series.estimate, LifeOSTokens.warning)
        XCTAssertEqual(LifeOSTokens.Series.target, LifeOSTokens.success)
        XCTAssertEqual(LifeOSTokens.Series.history, LifeOSTokens.metadataText)
    }

    func testResponsiveMetricsKeepMobileAndWideDesktopContracts() {
        let phone = LifeOSResponsiveMetrics(width: 390)
        XCTAssertTrue(phone.isCompact)
        XCTAssertEqual(phone.horizontalGutter, 16)
        XCTAssertEqual(phone.sectionSpacing, 32)
        XCTAssertFalse(phone.supportsTwoColumnLayout)

        let wideMac = LifeOSResponsiveMetrics(width: 1_600)
        XCTAssertEqual(wideMac.horizontalGutter, 32)
        XCTAssertEqual(wideMac.sectionSpacing, 40)
        XCTAssertEqual(wideMac.maxContentWidth, 1_240)
        XCTAssertEqual(wideMac.maxChartWidth, 1_440)
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
}
