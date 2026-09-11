import XCTest
import SwiftUI
import UIKit
@testable import LifeOS

final class LifeOSDesignSystemTests: XCTestCase {
    @MainActor
    func testEmptyStatePanelKeepsCompactGeometryWithoutAction() {
        XCTAssertEqual(LifeOSEmptyStatePanel.Layout.outerInset, 24)
        XCTAssertEqual(LifeOSEmptyStatePanel.Layout.internalGap, 12)
        XCTAssertEqual(LifeOSEmptyStatePanel.Layout.cornerRadius, 12)
        XCTAssertEqual(LifeOSEmptyStatePanel.Layout.minimumHeight, 160)
        XCTAssertEqual(LifeOSEmptyStatePanel.Layout.explanationMaxWidth, 480)

        let panel = LifeOSEmptyStatePanel(
            icon: .settings,
            title: "No connected sources",
            explanation: "Connect a supported source in Settings to populate Home with observed data."
        )
        let controller = UIHostingController(rootView: panel)
        controller.view.frame = CGRect(x: 0, y: 0, width: 640, height: 1)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(
            controller.sizeThatFits(in: CGSize(width: 640, height: 1_000)).height,
            LifeOSEmptyStatePanel.Layout.minimumHeight
        )
    }

    func testDisconnectedRoutesUseTruthfulPanelsAndRetainTheirGates() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let components = try String(
            contentsOf: iosRoot.appendingPathComponent("Shared/LifeOSComponents.swift"),
            encoding: .utf8
        )
        let overview = try String(
            contentsOf: iosRoot.appendingPathComponent("LifeOS/OverviewView.swift"),
            encoding: .utf8
        )
        let usage = try String(
            contentsOf: iosRoot.appendingPathComponent("LifeOS/CodexView.swift"),
            encoding: .utf8
        )
        let iosApp = try String(
            contentsOf: iosRoot.appendingPathComponent("LifeOS/LifeOSApp.swift"),
            encoding: .utf8
        )
        let macApp = try String(
            contentsOf: iosRoot.appendingPathComponent("LifeOSMac/LifeOSMacApp.swift"),
            encoding: .utf8
        )
        let tax = try String(
            contentsOf: iosRoot.appendingPathComponent("LifeOS/TaxDocumentsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(components.contains("public struct LifeOSEmptyStatePanel"))
        XCTAssertTrue(components.contains("if let action, let actionTitle"))
        XCTAssertTrue(overview.contains("showsNoSourceDashboard"))
        XCTAssertTrue(overview.contains("OverviewSupportingLayout"))
        XCTAssertTrue(overview.contains("LifeOSEmptyStatePanel"))
        XCTAssertFalse(overview.contains(".frame(maxWidth: 720"))
        XCTAssertTrue(usage.contains("Connect a usage provider"))
        XCTAssertTrue(usage.contains("onOpenSettings"))
        XCTAssertFalse(usage.contains("Advisor"))
        XCTAssertTrue(iosApp.contains("onOpenSettings: { navigate(.settings) }"))
        XCTAssertTrue(macApp.contains("onOpenSettings: interactive ? { navigate(to: .settings) } : nil"))
        XCTAssertTrue(tax.contains("No documents yet"))
        XCTAssertTrue(tax.contains("model.documents.isEmpty"))
        XCTAssertTrue(tax.contains("if model.isWriteBlocked"))
        XCTAssertTrue(tax.contains("else if model.documents.isEmpty"))
        XCTAssertTrue(tax.contains("Saving and deleting are disabled"))
        XCTAssertTrue(tax.contains("it cannot be saved until storage is available"))
        XCTAssertLessThan(
            try XCTUnwrap(tax.range(of: "if model.isWriteBlocked")?.lowerBound),
            try XCTUnwrap(tax.range(of: "else if model.documents.isEmpty")?.lowerBound)
        )
    }

    func testTypographyFacadeExposesEveryContractRole() {
        XCTAssertEqual(LifeOSTypography.Role.allCases.count, 10)
        XCTAssertEqual(
            Set(LifeOSTypography.Role.allCases),
            Set([
                .pageTitle,
                .sectionTitle,
                .cardTitle,
                .body,
                .label,
                .metadata,
                .metric,
                .metricCompact,
                .inlineMonitoringValue,
                .button,
            ])
        )
    }

    func testTypographyRolesUseExactSystemSizesWeightsAndMetricDigits() {
#if os(macOS)
        XCTAssertEqual(LifeOSTypography.Role.pageTitle.baseSize, 22)
        XCTAssertEqual(LifeOSTypography.Role.sectionTitle.baseSize, 15)
        XCTAssertEqual(LifeOSTypography.Role.cardTitle.baseSize, 14)
        XCTAssertEqual(LifeOSTypography.Role.body.baseSize, 13)
        XCTAssertEqual(LifeOSTypography.Role.label.baseSize, 13)
        XCTAssertEqual(LifeOSTypography.Role.metadata.baseSize, 12)
        XCTAssertEqual(LifeOSTypography.Role.metric.baseSize, 28)
        XCTAssertEqual(LifeOSTypography.Role.metricCompact.baseSize, 22)
        XCTAssertEqual(LifeOSTypography.Role.inlineMonitoringValue.baseSize, 20)
        XCTAssertEqual(LifeOSTypography.Role.button.baseSize, 13)
#else
        XCTAssertEqual(LifeOSTypography.Role.pageTitle.baseSize, 24)
        XCTAssertEqual(LifeOSTypography.Role.sectionTitle.baseSize, 18)
        XCTAssertEqual(LifeOSTypography.Role.cardTitle.baseSize, 16)
        XCTAssertEqual(LifeOSTypography.Role.body.baseSize, 17)
        XCTAssertEqual(LifeOSTypography.Role.label.baseSize, 15)
        XCTAssertEqual(LifeOSTypography.Role.metadata.baseSize, 13)
        XCTAssertEqual(LifeOSTypography.Role.metric.baseSize, 30)
        XCTAssertEqual(LifeOSTypography.Role.metricCompact.baseSize, 24)
        XCTAssertEqual(LifeOSTypography.Role.inlineMonitoringValue.baseSize, 22)
        XCTAssertEqual(LifeOSTypography.Role.button.baseSize, 15)
#endif
        XCTAssertEqual(LifeOSTypography.Role.pageTitle.defaultWeight, .semibold)
        XCTAssertTrue(LifeOSTypography.Role.metric.usesMonospacedDigits)
        XCTAssertTrue(LifeOSTypography.Role.metricCompact.usesMonospacedDigits)
        XCTAssertTrue(LifeOSTypography.Role.inlineMonitoringValue.usesMonospacedDigits)
        XCTAssertFalse(LifeOSTypography.Role.body.usesMonospacedDigits)
    }

    func testCanonicalPaletteValuesStayDistinctAndSourcedFromOneContract() {
        XCTAssertEqual(LifeOSPalette.brandBlueHex, 0x0253C4)
        XCTAssertEqual(LifeOSPalette.observedBlueHex, 0x3085FD)
        XCTAssertEqual(LifeOSPalette.focusBlueHex, 0x5DA0FD)
        XCTAssertEqual(LifeOSPalette.estimateGreenHex, 0x60D386)
        XCTAssertEqual(LifeOSPalette.calorieOrangeHex, 0xFFB06E)
        XCTAssertEqual(LifeOSPalette.calorieOrangeLightHex, 0xA25A03)
        XCTAssertEqual(LifeOSPalette.proteinTealHex, 0x63D2D2)
        XCTAssertEqual(LifeOSPalette.warningAmberHex, 0xFBDD68)
        XCTAssertEqual(LifeOSPalette.warningAmberLightHex, 0x9E8405)
        XCTAssertEqual(LifeOSPalette.warningTextLightHex, LifeOSPalette.primaryTextLightHex)
        XCTAssertEqual(LifeOSPalette.fitnessVioletDarkHex, 0x8D74FE)
        XCTAssertEqual(LifeOSPalette.fitnessVioletLightHex, 0x4502A5)
        XCTAssertEqual(LifeOSPalette.taxPurpleDarkHex, 0xC853E2)
        XCTAssertEqual(LifeOSPalette.taxPurpleLightHex, 0x650177)
        XCTAssertEqual(LifeOSPalette.canvasDarkHex, 0x000000)
        XCTAssertEqual(LifeOSPalette.canvasLightHex, 0xF7F7F8)
        XCTAssertEqual(LifeOSPalette.surfaceDarkHex, 0x08080A)
        XCTAssertEqual(LifeOSPalette.surfaceLightHex, 0xFFFFFF)
        XCTAssertEqual(LifeOSPalette.borderDarkHex, 0x29292F)
        XCTAssertEqual(LifeOSPalette.borderLightHex, 0xD0D0D6)
        XCTAssertEqual(LifeOSPalette.transparentWidgetSupportingHex, 0xE6E6E6)

        XCTAssertEqual(
            LifeOSSemanticColorPairs.primaryAction.darkBackgroundHex,
            LifeOSPalette.primaryTextDarkHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.primaryAction.darkForegroundHex,
            LifeOSPalette.canvasDarkHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.focus.darkForegroundHex,
            LifeOSPalette.focusBlueHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.estimate.darkForegroundHex,
            LifeOSPalette.estimateGreenHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.target.darkForegroundHex,
            LifeOSPalette.targetGreenHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.calories.darkForegroundHex,
            LifeOSPalette.calorieOrangeHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.protein.darkForegroundHex,
            LifeOSPalette.proteinTealHex
        )
    }

    @MainActor
    func testDynamicTypographyRolesKeepBaseSizesAnchorsAndMetricPolicy() {
#if os(macOS)
        let pageTitleSize: CGFloat = 22
        let sectionTitleSize: CGFloat = 15
        let cardTitleSize: CGFloat = 14
        let bodySize: CGFloat = 13
        let labelSize: CGFloat = 13
        let metadataSize: CGFloat = 12
        let metricSize: CGFloat = 28
        let metricCompactSize: CGFloat = 22
        let inlineMonitoringValueSize: CGFloat = 20
        let buttonSize: CGFloat = 13
#else
        let pageTitleSize: CGFloat = 24
        let sectionTitleSize: CGFloat = 18
        let cardTitleSize: CGFloat = 16
        let bodySize: CGFloat = 17
        let labelSize: CGFloat = 15
        let metadataSize: CGFloat = 13
        let metricSize: CGFloat = 30
        let metricCompactSize: CGFloat = 24
        let inlineMonitoringValueSize: CGFloat = 22
        let buttonSize: CGFloat = 15
#endif
        let contracts: [(LifeOSTypography.Role, CGFloat, Font.TextStyle, Font.Weight, CGFloat, CGFloat, Bool)] = [
            (.pageTitle, pageTitleSize, .title, .semibold, -0.3, 0, false),
            (.sectionTitle, sectionTitleSize, .title2, .semibold, -0.2, 0, false),
            (.cardTitle, cardTitleSize, .headline, .semibold, 0, 0, false),
            (.body, bodySize, .body, .regular, 0, 0, false),
            (.label, labelSize, .subheadline, .medium, 0, 0, false),
            (.metadata, metadataSize, .footnote, .regular, 0, 0, false),
            (.metric, metricSize, .largeTitle, .semibold, -0.4, 0, true),
            (.metricCompact, metricCompactSize, .title2, .semibold, -0.3, 0, true),
            (.inlineMonitoringValue, inlineMonitoringValueSize, .title2, .semibold, 0, 0, true),
            (.button, buttonSize, .headline, .semibold, 0, 0, false),
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
        XCTAssertEqual(LifeOSSelectedNavigationPalette.overlayOpacity, 0.06, accuracy: 0.0001)
        XCTAssertEqual(
            LifeOSSelectedNavigationPalette.darkForegroundHex,
            LifeOSPalette.primaryTextDarkHex
        )
        XCTAssertEqual(
            LifeOSSelectedNavigationPalette.darkBackgroundHex,
            LifeOSPalette.surfaceDarkHex
        )
        XCTAssertEqual(
            LifeOSSelectedNavigationPalette.lightForegroundHex,
            LifeOSPalette.primaryTextLightHex
        )
        XCTAssertEqual(
            LifeOSSelectedNavigationPalette.lightBackgroundHex,
            LifeOSPalette.surfaceLightHex
        )
        XCTAssertEqual(LifeOSSelectedNavigationPalette.darkIndicatorHex, LifeOSPalette.focusBlueHex)
        XCTAssertEqual(LifeOSSelectedNavigationPalette.lightIndicatorHex, LifeOSPalette.brandBlueHex)

        XCTAssertNotEqual(
            LifeOSSelectedNavigationPalette.darkForegroundHex,
            LifeOSSelectedNavigationPalette.darkBackgroundHex
        )
        XCTAssertNotEqual(
            LifeOSSelectedNavigationPalette.lightForegroundHex,
            LifeOSSelectedNavigationPalette.lightBackgroundHex
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
                LifeOSTokens.Space.xxxxl,
            ],
            [4, 8, 12, 16, 24, 24, 32, 48, 64]
        )
        XCTAssertEqual([LifeOSTokens.Radius.control, LifeOSTokens.Radius.card, LifeOSTokens.Radius.hero], [8, 12, 16])
        XCTAssertEqual(LifeOSTokens.Control.minimumTarget, 44)
        XCTAssertEqual(LifeOSTokens.pagePadding, 16)
        XCTAssertEqual(LifeOSTokens.sectionGap, LifeOSTokens.Space.xl)
        XCTAssertEqual(LifeOSTokens.pageEndSpacing, LifeOSTokens.Space.xxl)
        XCTAssertEqual(LifeOSTokens.siblingGap, LifeOSTokens.Space.md)
        XCTAssertEqual(LifeOSTokens.labelValueGap, LifeOSTokens.Space.xs)
        XCTAssertEqual(LifeOSTokens.labelHelperGap, LifeOSTokens.Space.xxs)
        XCTAssertEqual(LifeOSTokens.proseMaxWidth, 640)
        XCTAssertEqual(LifeOSTokens.statusRowMinHeight, 56)
    }

    /// Quiet Machine §2.5/§4.1: no shadows at rest and exactly one hairline
    /// border identity shared by every border alias.
    func testVisualOverhaulShadowPolicyAndHairlineContract() {
        XCTAssertEqual(LifeOSTokens.cardShadowRadius, 0)
        XCTAssertEqual(LifeOSTokens.cardShadowX, 0)
        XCTAssertEqual(LifeOSTokens.cardShadowY, 0)

        // The border aliases share the authored neutral contract. Avoid
        // comparing independently constructed adaptive Color providers.
        XCTAssertEqual(LifeOSPalette.borderDarkHex, 0x29292F)
        XCTAssertEqual(LifeOSPalette.borderLightHex, 0xD0D0D6)

        // Information is a teal semantic distinct from blue focus/data roles.
        XCTAssertNotEqual(
            LifeOSSemanticColorPairs.info.darkForegroundHex,
            LifeOSSemanticColorPairs.focus.darkForegroundHex
        )

        // Chart series semantics per §2.4.
        // Target and estimate share the green semantic, while their line
        // patterns and labels remain distinct in the chart renderer.
        XCTAssertEqual(
            LifeOSSemanticColorPairs.estimate,
            LifeOSSemanticColorPairs.target
        )
        XCTAssertNotEqual(
            LifeOSSemanticColorPairs.estimate.darkForegroundHex,
            LifeOSSemanticColorPairs.warning.darkForegroundHex
        )
        XCTAssertEqual(LifeOSSemanticColorPairs.target, LifeOSSemanticColorPairs.neutralTarget)
        XCTAssertEqual(LifeOSPalette.metadataTextDarkHex, 0x84848C)
        XCTAssertEqual(LifeOSPalette.metadataTextLightHex, 0x6D6D74)
    }

    func testSemanticColorPairsMeetContrastAndPreserveDistinctRoles() {
        let pairs = [
            LifeOSSemanticColorPairs.primaryAction,
            LifeOSSemanticColorPairs.primaryActionHover,
            LifeOSSemanticColorPairs.primaryActionPressed,
            LifeOSSemanticColorPairs.selectedNavigation,
            LifeOSSemanticColorPairs.focus,
            LifeOSSemanticColorPairs.neutralTarget,
            LifeOSSemanticColorPairs.estimate,
            LifeOSSemanticColorPairs.warningText,
            LifeOSSemanticColorPairs.calories,
            LifeOSSemanticColorPairs.protein,
            LifeOSSemanticColorPairs.link,
        ]

        for pair in pairs {
            XCTAssertTrue(pair.meetsTextContrast, "Text contrast failed for \(pair)")
            XCTAssertTrue(pair.meetsGraphicContrast, "Graphic contrast failed for \(pair)")
        }

        XCTAssertTrue(LifeOSSemanticColorPairs.warning.meetsGraphicContrast)

        XCTAssertEqual(
            LifeOSSemanticColorPairs.neutralTarget.darkForegroundHex,
            LifeOSSemanticColorPairs.estimate.darkForegroundHex
        )
        XCTAssertNotEqual(
            LifeOSSemanticColorPairs.calories.darkForegroundHex,
            LifeOSSemanticColorPairs.protein.darkForegroundHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.primaryAction.darkForegroundHex,
            LifeOSPalette.canvasDarkHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.primaryAction.lightForegroundHex,
            LifeOSPalette.canvasLightHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.primaryAction.lightBackgroundHex,
            LifeOSPalette.primaryTextLightHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.primaryActionHover.darkBackgroundHex,
            0xD9D9DD
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.primaryActionPressed.lightBackgroundHex,
            0x50505A
        )
        XCTAssertGreaterThanOrEqual(
            LifeOSSemanticColorPairs.warningText.lightContrastRatio,
            4.5
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.warning.lightForegroundHex,
            LifeOSPalette.warningAmberLightHex
        )
        XCTAssertEqual(
            LifeOSSemanticColorPairs.warningText.lightForegroundHex,
            LifeOSPalette.primaryTextLightHex
        )
        XCTAssertEqual(
            LifeOSModuleColorPairs.fitness.darkForegroundHex,
            LifeOSPalette.fitnessVioletDarkHex
        )
        XCTAssertEqual(
            LifeOSModuleColorPairs.fitness.lightForegroundHex,
            LifeOSPalette.fitnessVioletLightHex
        )
        XCTAssertEqual(
            LifeOSModuleColorPairs.tax.darkForegroundHex,
            LifeOSPalette.taxPurpleDarkHex
        )
        XCTAssertEqual(
            LifeOSModuleColorPairs.tax.lightForegroundHex,
            LifeOSPalette.taxPurpleLightHex
        )
    }

    func testTransparentWidgetBackingRemainsReadableOnReviewedGreyWallpapers() {
        XCTAssertEqual(LifeOSWidgetContrastPolicy.backingOpacity, 0.60, accuracy: 0.0001)
        XCTAssertEqual(LifeOSTokens.Radius.widget, 12)

        for wallpaper in LifeOSWidgetContrastPolicy.reviewedGreyWallpapers {
            let backing = LifeOSWidgetContrastPolicy.compositedBackingHex(over: wallpaper)
            XCTAssertTrue(
                LifeOSWidgetContrastPolicy.meetsTextContrast(over: wallpaper),
                "Transparent widget text lost contrast over \(wallpaper) with backing \(backing)"
            )
            XCTAssertGreaterThanOrEqual(
                LifeOSWidgetContrastPolicy.contrastRatio(
                    foregroundHex: LifeOSWidgetContrastPolicy.supportingForegroundHex,
                    over: wallpaper
                ),
                4.5
            )
        }
    }

    func testHitTargetsAndSelectorFallbackStayBounded() {
        XCTAssertEqual(LifeOSHitTarget.resolve(), 44)
        XCTAssertEqual(LifeOSHitTarget.resolve(8), 44)
        XCTAssertEqual(LifeOSHitTarget.resolve(64), 64)
        XCTAssertEqual(LifeOSHitTarget.resolve(.infinity), 96)
        XCTAssertEqual(LifeOSHitTarget.resolve(-.infinity), 44)
        XCTAssertEqual(LifeOSHitTarget.resolve(.nan), 44)
        XCTAssertTrue(LifeOSSelectorLayout.usesMenu(availableWidth: 300, intrinsicPillWidth: 301))
        XCTAssertFalse(LifeOSSelectorLayout.usesMenu(availableWidth: 300, intrinsicPillWidth: 300))
        XCTAssertTrue(LifeOSSelectorLayout.usesMenu(availableWidth: 300, intrinsicPillWidth: 300, accessibilitySize: true))
    }

    func testIconCatalogUsesContractMappingsAndMonochromeRendering() throws {
        XCTAssertEqual(LifeOSIconName.home.systemImageName, "house")
        XCTAssertEqual(LifeOSIconName.finance.systemImageName, "creditcard")
        XCTAssertEqual(LifeOSIconName.fitness.systemImageName, "waveform.path.ecg")
        XCTAssertEqual(LifeOSIconName.reports.systemImageName, "chart.bar.doc")
        XCTAssertEqual(LifeOSIconName.calendarPlus.systemImageName, "calendar.badge.plus")
        XCTAssertEqual(LifeOSIconName.close.systemImageName, "xmark")
        XCTAssertEqual(LifeOSTokens.Icon.box, 24)
        XCTAssertEqual(LifeOSTokens.Icon.glyph, 17)
        XCTAssertEqual(LifeOSIconContext.standard.box, 24)
        XCTAssertEqual(LifeOSIconContext.standard.glyph, 17)
        XCTAssertLessThan(LifeOSIconContext.disclosure.glyph, LifeOSIconContext.disclosure.box)
#if os(macOS)
        XCTAssertEqual(LifeOSIconContext.navigation.box, 20)
        XCTAssertEqual(LifeOSIconContext.card.box, 20)
        XCTAssertEqual(LifeOSIconContext.toolbar.box, 20)
        XCTAssertEqual(LifeOSIconContext.navigation.glyph, 16)
        XCTAssertEqual(LifeOSIconContext.card.glyph, 16)
        XCTAssertEqual(LifeOSIconContext.toolbar.glyph, 16)
        XCTAssertEqual(LifeOSIconContext.disclosure.box, 16)
#else
        XCTAssertEqual(LifeOSIconContext.navigation.box, 24)
        XCTAssertEqual(LifeOSIconContext.card.box, 24)
        XCTAssertEqual(LifeOSIconContext.toolbar.box, 24)
        XCTAssertEqual(LifeOSIconContext.navigation.glyph, 20)
        XCTAssertEqual(LifeOSIconContext.card.glyph, 18)
        XCTAssertEqual(LifeOSIconContext.toolbar.glyph, 20)
        XCTAssertEqual(LifeOSIconContext.disclosure.box, 20)
#endif
#if os(macOS)
        XCTAssertEqual(LifeOSIconContext.disclosure.glyph, 12)
#else
        XCTAssertEqual(LifeOSIconContext.disclosure.glyph, 14)
#endif

        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Shared/LifeOSIcon.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".symbolRenderingMode(.monochrome)"))
        XCTAssertTrue(source.contains(".font(.system(size: context.glyph, weight: context.weight, design: .default))"))
        XCTAssertTrue(source.contains(".frame(width: context.box, height: context.box)"))
        XCTAssertTrue(source.contains("public enum LifeOSIconContext"))
        XCTAssertFalse(source.contains(".renderingMode(.template)"))
        XCTAssertFalse(source.contains("case .assistant"))
    }

    func testUsageSourceKeepsCompactTruthfulSelectionAndControlContract() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("LifeOS/CodexView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private func availableRangeOrder(for snapshot: ProviderSnapshot)"))
        XCTAssertTrue(source.contains("private func matchesQuality(_ candidate: UsageAnalyticsSnapshot"))
        XCTAssertTrue(source.contains(".onChange(of: snapshots)"))
        XCTAssertTrue(source.contains("@SceneStorage(\"LifeOS.usage.selectedProvider.v1\")"))
        XCTAssertTrue(source.contains("@SceneStorage(\"LifeOS.usage.selectedRange.v1\")"))
        XCTAssertTrue(source.contains("private var rangeControl: some View"))
        XCTAssertTrue(source.contains(".lifeOSTypography(.inlineMonitoringValue)"))
        XCTAssertTrue(source.contains("LifeOSTokens.estimate"))
        XCTAssertTrue(source.contains("weekday(.abbreviated)"))
        XCTAssertTrue(source.contains("LifeOSIcon(.chevronRight, context: .disclosure)"))
        XCTAssertTrue(source.contains("LifeOSIcon(providerIcon(selectedProvider), context: .toolbar)"))
        XCTAssertFalse(source.contains("private func preferredRange"))
        XCTAssertFalse(source.contains(".textCase(.uppercase)"))
        XCTAssertFalse(source.contains("enum UsageTab"))
        XCTAssertFalse(source.contains("UsageLimitsCard"))
        XCTAssertFalse(source.contains(".task(id: datasetID)"))
        XCTAssertFalse(source.contains("secondaryTextCompat"))
    }

    func testResponsiveMetricsKeepMobileAndWideDesktopContracts() {
        let phone = LifeOSResponsiveMetrics(width: 390)
        XCTAssertTrue(phone.isCompact)
        XCTAssertEqual(phone.horizontalGutter, LifeOSTokens.pageGutter)
        XCTAssertEqual(phone.sectionSpacing, 24)
        XCTAssertEqual(phone.contentWidth, 390 - (LifeOSTokens.pageGutter * 2))
        XCTAssertFalse(phone.supportsTwoColumnLayout)

        let regularSingleColumn = LifeOSResponsiveMetrics(width: 600)
        XCTAssertFalse(regularSingleColumn.isCompact)
        XCTAssertFalse(regularSingleColumn.supportsTwoColumnLayout)

        let justBelow = LifeOSResponsiveMetrics(width: 719)
        XCTAssertFalse(justBelow.isCompact)
        XCTAssertFalse(justBelow.supportsTwoColumnLayout)

        let atBreakpoint = LifeOSResponsiveMetrics(width: 720 + (LifeOSTokens.pageGutter * 2))
        XCTAssertFalse(atBreakpoint.isCompact)
        XCTAssertEqual(atBreakpoint.contentWidth, 720)
        XCTAssertTrue(atBreakpoint.supportsTwoColumnLayout)

        let justAbove = LifeOSResponsiveMetrics(width: 721 + (LifeOSTokens.pageGutter * 2))
        XCTAssertFalse(justAbove.isCompact)
        XCTAssertTrue(justAbove.supportsTwoColumnLayout)

        let wideWindow = LifeOSResponsiveMetrics(width: 1_600)
#if os(macOS)
        XCTAssertEqual(wideWindow.horizontalGutter, 32)
#else
        XCTAssertEqual(wideWindow.horizontalGutter, 16)
#endif
        XCTAssertEqual(wideWindow.sectionSpacing, 24)
        XCTAssertEqual(wideWindow.maxContentWidth, 1_120)
        XCTAssertEqual(wideWindow.maxChartWidth, 1_440)
    }

    func testResponsiveMetricsClampStandardPageWidthAtEveryWidthClass() {
        XCTAssertEqual(LifeOSResponsiveMetrics.compactBreakpoint, 600)
        XCTAssertEqual(LifeOSResponsiveMetrics.twoColumnBreakpoint, 720)
        XCTAssertEqual(LifeOSTokens.contentMaxWidth, 1_120)
        XCTAssertEqual(
            LifeOSResponsiveMetrics(width: 320).maxContentWidth,
            320 - (LifeOSTokens.pageGutter * 2)
        )
        XCTAssertEqual(
            LifeOSResponsiveMetrics(width: 719).maxContentWidth,
            719 - (LifeOSTokens.pageGutter * 2)
        )
        XCTAssertEqual(
            LifeOSResponsiveMetrics(width: 720).maxContentWidth,
            720 - (LifeOSTokens.pageGutter * 2)
        )
        XCTAssertEqual(
            LifeOSResponsiveMetrics(width: 1_119).maxContentWidth,
            1_119 - (LifeOSTokens.pageGutter * 2)
        )
        XCTAssertEqual(
            LifeOSResponsiveMetrics(width: 1_120).maxContentWidth,
            1_120 - (LifeOSTokens.pageGutter * 2)
        )
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 1_600).maxContentWidth, 1_120)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: -.infinity).maxContentWidth, 0)
        XCTAssertEqual(
            LifeOSResponsiveMetrics(width: .infinity).maxContentWidth,
            1_120
        )
        XCTAssertEqual(LifeOSResponsiveMetrics(width: .nan).maxContentWidth, 0)

        let withSidebar = LifeOSResponsiveMetrics(width: 1_600, sidebarWidth: 232)
        XCTAssertEqual(withSidebar.availableWidth, 1_368)
        XCTAssertEqual(withSidebar.maxContentWidth, 1_120)
        XCTAssertTrue(withSidebar.fitsWithinViewport)
        XCTAssertLessThanOrEqual(withSidebar.renderedContentMaxX, withSidebar.width)

#if os(macOS)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 1_511).horizontalGutter, 24)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 1_512).horizontalGutter, 32)
#else
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 1_511).horizontalGutter, 16)
        XCTAssertEqual(LifeOSResponsiveMetrics(width: 1_512).horizontalGutter, 16)
#endif
    }

    @MainActor
    func testResponsiveContainersRenderEveryBuilderChild() {
        let publicController = UIHostingController(
            rootView: LifeOSResponsiveContainer { _ in
                ResponsiveLayoutMarker(identifier: "responsive-public-first")
                    .frame(height: 24)
                ResponsiveLayoutMarker(identifier: "responsive-public-second")
                    .frame(height: 24)
            }
            .frame(width: 400, height: 200)
        )
        let publicFrames = hostedFrames(
            for: ["responsive-public-first", "responsive-public-second"],
            in: publicController
        )
        assertVerticallyStacked(publicFrames, in: publicController.view)

        let collectionController = UIHostingController(
            rootView: LifeOSResponsiveContentContainer(
                horizontalPadding: 0,
                maxReadableWidth: nil
            ) {
                ForEach(["first", "second"], id: \.self) { row in
                    ResponsiveLayoutMarker(identifier: "responsive-collection-\(row)")
                        .frame(height: 24)
                }
            }
            .frame(width: 400, height: 200)
        )
        let collectionFrames = hostedFrames(
            for: ["responsive-collection-first", "responsive-collection-second"],
            in: collectionController
        )
        assertVerticallyStacked(collectionFrames, in: collectionController.view)

        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = (try? String(
            contentsOf: iosRoot.appendingPathComponent("Shared/LifeOSResponsiveContainer.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            source.contains("LifeOSResponsiveContentPayload(content: content(metrics))"),
            "The public responsive container must use the same owning payload as the content container"
        )
        XCTAssertTrue(
            source.contains("VStack(alignment: .leading, spacing: 0)"),
            "The payload must own builder expansion in a leading, zero-spacing VStack"
        )
    }

    @MainActor
    private func hostedFrames(
        for identifiers: [String],
        in controller: UIHostingController<some View>
    ) -> [CGRect] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        let frames = identifiers.compactMap { identifier in
            findView(withAccessibilityIdentifier: identifier, in: controller.view).map {
                $0.convert($0.bounds, to: controller.view)
            }
        }
        window.isHidden = true
        window.rootViewController = nil
        return frames
    }

    private func findView(withAccessibilityIdentifier identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let match = findView(withAccessibilityIdentifier: identifier, in: child) {
                return match
            }
        }
        return nil
    }

    private func assertVerticallyStacked(_ frames: [CGRect], in rootView: UIView) {
        XCTAssertEqual(frames.count, 2, "Every responsive builder child must remain hosted")
        guard frames.count == 2 else { return }
        XCTAssertTrue(rootView.bounds.contains(frames[0]))
        XCTAssertTrue(rootView.bounds.contains(frames[1]))
        XCTAssertGreaterThan(frames[0].height, 0)
        XCTAssertGreaterThan(frames[1].height, 0)
        XCTAssertGreaterThanOrEqual(
            frames[1].minY,
            frames[0].maxY - 0.5,
            "Builder children must be laid out sequentially instead of overlapping"
        )
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

    }

    func testSheetGeometryIsBoundedAndKeepsNativeDetents() throws {
        XCTAssertEqual(LifeOSSheetGeometry.macStandardWidth, 520)
        XCTAssertEqual(LifeOSSheetGeometry.macMaximumHeightFraction, 0.80, accuracy: 0.0001)
        XCTAssertEqual(LifeOSSheetGeometry.macSafeHeightInset, 48)
        XCTAssertTrue(LifeOSSheetGeometry.macFallbackAvailableHeight.isFinite)
        XCTAssertEqual(
            LifeOSSheetGeometry.macAvailableHeight(for: nil),
            LifeOSSheetGeometry.macFallbackAvailableHeight
        )
        XCTAssertEqual(
            LifeOSSheetGeometry.macAvailableHeight(for: .infinity),
            LifeOSSheetGeometry.macFallbackAvailableHeight
        )
        XCTAssertEqual(
            LifeOSSheetGeometry.macAvailableHeight(for: .nan),
            LifeOSSheetGeometry.macFallbackAvailableHeight
        )
        XCTAssertEqual(LifeOSSheetGeometry.macWidth(for: 400), 400)
        XCTAssertEqual(LifeOSSheetGeometry.macWidth(for: 520), 520)
        XCTAssertEqual(LifeOSSheetGeometry.macWidth(for: 900), 520)
        XCTAssertEqual(LifeOSSheetGeometry.macWidth(for: .infinity), 520)
        XCTAssertEqual(LifeOSSheetGeometry.macWidth(for: .nan), 0)

        let safeMaximum = LifeOSSheetGeometry.macMaximumHeight(for: 900)
        XCTAssertEqual(safeMaximum, (900 - 48) * 0.80, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(safeMaximum, 900 * 0.80)
        let fallbackMaximum = LifeOSSheetGeometry.macMaximumHeight(
            for: .infinity
        )
        XCTAssertTrue(fallbackMaximum.isFinite)
        XCTAssertEqual(
            fallbackMaximum,
            (LifeOSSheetGeometry.macFallbackAvailableHeight - 48) * 0.80,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LifeOSSheetGeometry.macMaximumHeight(for: .nan),
            fallbackMaximum,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            LifeOSSheetGeometry.macMaximumHeight(for: 1_000),
            LifeOSSheetGeometry.macMaximumHeight(for: 700)
        )

        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Shared/LifeOSComponents.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("idealWidth: LifeOSSheetGeometry.macStandardWidth"))
        XCTAssertTrue(source.contains("maxWidth: LifeOSSheetGeometry.macStandardWidth"))
        XCTAssertTrue(source.contains("LifeOSSheetWindowHeightReader"))
        XCTAssertTrue(source.contains("window?.sheetParent ?? window"))
        XCTAssertTrue(source.contains("availableHeight: macAvailableHeight"))
        XCTAssertTrue(source.contains(".presentationDetents([.medium, .large])"))
        XCTAssertFalse(source.contains("LifeOSSheetPresentationLayout(maxHeight: 760"))
    }

    func testFinanceDetailSelectorKeepsTheSharedSelectorContract() {
        XCTAssertEqual(
            FinanceDetail.allCases.map(\.title),
            ["Spend", "Income", "Cash flow", "Net worth"]
        )
        XCTAssertEqual(
            LifeOSSelectorLayout.usesMenu(
                availableWidth: 359,
                intrinsicPillWidth: 360
            ),
            true
        )
        XCTAssertEqual(
            LifeOSSelectorLayout.usesMenu(
                availableWidth: 720,
                intrinsicPillWidth: 360
            ),
            false
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
        XCTAssertFalse(tokensSource.contains("LifeOSFlatCardModifier"))
        XCTAssertTrue(tokensSource.contains("padding: 0"))
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
        XCTAssertFalse(state.allowsAnimatedStateTransition)
        XCTAssertTrue(state.allowsUserDrivenMotion)
        XCTAssertEqual(
            LifeOSInteractionAppearance.resolve(for: state).contentOpacity,
            1,
            accuracy: 0.0001
        )

        let dragging = LifeOSInteractionState(phase: .dragging)
        XCTAssertTrue(dragging.allowsUserDrivenMotion)
        XCTAssertTrue(dragging.isDirectManipulation)
        XCTAssertFalse(dragging.allowsAnimatedStateTransition)

        let hovering = LifeOSInteractionState(phase: .hover)
        XCTAssertFalse(hovering.isDirectManipulation)
        XCTAssertTrue(hovering.allowsAnimatedStateTransition)
    }

    func testInteractionAppearanceUsesDistinctOverlayPhasesAndFocusSeparation() {
        let hover = LifeOSInteractionState.resolve(
            pressed: false,
            hovered: true,
            focused: false
        )
        let selected = LifeOSInteractionState.resolve(
            pressed: false,
            hovered: false,
            focused: false,
            selected: true
        )
        let selectedAndHovered = LifeOSInteractionState.resolve(
            pressed: false,
            hovered: true,
            focused: false,
            selected: true
        )
        let selectedAndPressed = LifeOSInteractionState.resolve(
            pressed: true,
            hovered: true,
            focused: false,
            selected: true
        )
        let pressedAndFocused = LifeOSInteractionState.resolve(
            pressed: true,
            hovered: true,
            focused: true,
            selected: true
        )

        XCTAssertEqual(
            LifeOSInteractionAppearance.resolve(for: hover).fillOpacity,
            LifeOSInteractionAppearance.hoverFillOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LifeOSInteractionAppearance.resolve(for: selected).fillOpacity,
            LifeOSInteractionAppearance.selectedFillOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LifeOSInteractionAppearance.resolve(for: selectedAndHovered).fillOpacity,
            LifeOSInteractionAppearance.selectedHoverFillOpacity,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            LifeOSInteractionAppearance.resolve(for: selectedAndHovered).fillOpacity,
            LifeOSInteractionAppearance.resolve(for: selected).fillOpacity
        )
        XCTAssertEqual(
            LifeOSInteractionAppearance.resolve(for: selectedAndPressed).fillOpacity,
            LifeOSInteractionAppearance.pressedFillOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LifeOSInteractionAppearance.resolve(for: pressedAndFocused).fillOpacity,
            LifeOSInteractionAppearance.pressedFillOpacity,
            accuracy: 0.0001
        )
        XCTAssertTrue(pressedAndFocused.isPressed)
        XCTAssertTrue(pressedAndFocused.isFocused)
        XCTAssertTrue(pressedAndFocused.isHovered)
        XCTAssertTrue(pressedAndFocused.isSelected)
        XCTAssertEqual(LifeOSInteractionAppearance.focusRingLineWidth, 2, accuracy: 0.0001)
        XCTAssertEqual(LifeOSInteractionAppearance.focusRingSeparation, 2, accuracy: 0.0001)
        XCTAssertEqual(
            LifeOSInteractionAppearance.resolve(for: pressedAndFocused).contentOpacity,
            1,
            accuracy: 0.0001
        )
    }

    func testDirectionalClassifierWaitsForDistanceAndDominance() {
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 7, height: 0)), .undecided)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 8, height: 0)), .horizontal)
        XCTAssertEqual(LifeOSDirectionalClassifier.dominanceRatio, 1.3, accuracy: 0.0001)
        XCTAssertEqual(LifeOSDirectionalClassifier.ambiguousVerticalDistance, 16)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 20, height: 10)), .horizontal)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 10, height: 20)), .vertical)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 12, height: 10)), .undecided)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 13, height: 13)), .vertical)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(CGSize(width: 10, height: 9)), .undecided)
        XCTAssertEqual(LifeOSDirectionalClassifier.classify(horizontal: .nan, vertical: 20), .undecided)
    }

    func testCancellationIsExplicitAndDoesNotInventACommit() {
        let cancellation = LifeOSInteractionCancellation.cancelled(reason: "Vertical intent")

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(cancellation.reason, "Vertical intent")
        XCTAssertFalse(LifeOSInteractionCancellation.active.isCancelled)
    }
    func testCanonicalMotionTimingsAndCompatibilityAliases() {
        XCTAssertEqual(LifeOSMotion.Timing.press, .easeOut(0.08))
        XCTAssertEqual(LifeOSMotion.Timing.release, .easeOut(0.18))
        XCTAssertEqual(LifeOSMotion.Timing.hover, .easeOut(0.12))
        XCTAssertEqual(LifeOSMotion.Timing.reducedNavigation, .easeOut(0.12))
        XCTAssertEqual(LifeOSMotion.Timing.primary, .spring(response: 0.42, damping: 0.82))
        XCTAssertEqual(LifeOSMotion.Timing.snappy, .spring(response: 0.30, damping: 0.86))
        XCTAssertEqual(LifeOSMotion.Timing.hero, .spring(response: 0.50, damping: 0.85))
        XCTAssertEqual(
            LifeOSMotion.Timing.calendarSettle,
            .interpolatingSpring(mass: 1, stiffness: 340, damping: 37, initialVelocity: 0)
        )
        XCTAssertEqual(LifeOSMotion.Timing.tooltip, .easeOut(0.08))
        XCTAssertEqual(LifeOSMotion.Timing.sheet, .easeOut(0.18))
        XCTAssertEqual(LifeOSMotion.Timing.refresh, .easeOut(0.10))
        XCTAssertEqual(LifeOSMotion.Timing.ring, .spring(response: 0.70, damping: 0.90))
        XCTAssertEqual(LifeOSMotion.Timing.tracking, .direct)
        XCTAssertEqual(LifeOSMotion.Timing.chart, .easeOut(0.72))
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

private struct ResponsiveLayoutMarker: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = identifier
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityIdentifier = identifier
    }
}
