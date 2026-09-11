import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Authored values that are shared by semantic color pairs, adaptive colors,
/// and deterministic design-system tests. Keeping the contract values in one
/// place prevents a light/dark token from drifting away from the palette.
enum LifeOSPalette {
    static let brandBlueHex: UInt32 = 0x0253C4
    static let observedBlueHex: UInt32 = 0x3085FD
    static let focusBlueHex: UInt32 = 0x5DA0FD
    static let targetGreenHex: UInt32 = 0x60D386
    static let targetGreenLightHex: UInt32 = 0x01773B
    static let estimateGreenHex: UInt32 = targetGreenHex
    static let calorieOrangeHex: UInt32 = 0xFFB06E
    static let proteinTealHex: UInt32 = 0x63D2D2
    static let warningAmberHex: UInt32 = 0xFBDD68
    static let warningAmberLightHex: UInt32 = 0x9E8405
    // The documented orange.700 sibling is used for small warning text in
    // light mode because amber.700 does not clear 4.5:1 on a white surface.
    static let warningTextLightHex: UInt32 = 0xA25A03
    static let dangerRedHex: UInt32 = 0xFC584F
    static let dangerRedLightHex: UInt32 = 0xB70112
    static let infoTealHex: UInt32 = 0x63D2D2
    static let infoTealLightHex: UInt32 = 0x067878
    static let primaryTextDarkHex: UInt32 = 0xF5F5F7
    static let primaryTextLightHex: UInt32 = 0x111113
    static let canvasDarkHex: UInt32 = 0x000000
    static let canvasLightHex: UInt32 = 0xF7F7F8
    static let surfaceDarkHex: UInt32 = 0x08080A
    static let surfaceLightHex: UInt32 = 0xFFFFFF
    static let borderDarkHex: UInt32 = 0x29292F
    static let borderLightHex: UInt32 = 0xD0D0D6
    static let transparentWidgetBackingOpacity: Double = 0.60
    static let transparentWidgetSupportingHex: UInt32 = 0xE6E6E6
}

/// A platform-independent color pair. SwiftUI's adaptive `Color` provider is
/// intentionally not introspectable in unit tests, so semantic pairs keep
/// their authored sRGB values here as well as in the rendered tokens.
struct LifeOSColorPair: Equatable, Sendable {
    let darkForegroundHex: UInt32
    let darkBackgroundHex: UInt32
    let lightForegroundHex: UInt32
    let lightBackgroundHex: UInt32

    init(
        darkForegroundHex: UInt32,
        darkBackgroundHex: UInt32,
        lightForegroundHex: UInt32,
        lightBackgroundHex: UInt32
    ) {
        self.darkForegroundHex = darkForegroundHex
        self.darkBackgroundHex = darkBackgroundHex
        self.lightForegroundHex = lightForegroundHex
        self.lightBackgroundHex = lightBackgroundHex
    }

    var darkContrastRatio: Double {
        LifeOSContrast.contrastRatio(
            foreground: darkForegroundHex,
            background: darkBackgroundHex
        )
    }

    var lightContrastRatio: Double {
        LifeOSContrast.contrastRatio(
            foreground: lightForegroundHex,
            background: lightBackgroundHex
        )
    }

    var meetsTextContrast: Bool {
        darkContrastRatio >= 4.5 && lightContrastRatio >= 4.5
    }

    var meetsGraphicContrast: Bool {
        darkContrastRatio >= 3 && lightContrastRatio >= 3
    }
}

/// WCAG contrast math for authored opaque sRGB pairs. Composited wallpaper
/// treatment is intentionally kept out of this helper; transparent widgets
/// use their opaque backing token before this calculation is applied.
enum LifeOSContrast {
    static func relativeLuminance(of hex: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        let red = linear((hex >> 16) & 0xFF)
        let green = linear((hex >> 8) & 0xFF)
        let blue = linear(hex & 0xFF)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    static func contrastRatio(foreground: UInt32, background: UInt32) -> Double {
        let foregroundLuminance = relativeLuminance(of: foreground)
        let backgroundLuminance = relativeLuminance(of: background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// The approved inner surface for full-color transparent widgets. WidgetKit
/// supplies the wallpaper, so the black backing is composited over the
/// wallpaper before contrast is evaluated. This keeps the policy deterministic
/// without pretending a preview can prove the system's final rendering.
enum LifeOSWidgetContrastPolicy {
    static let backingOpacity = LifeOSPalette.transparentWidgetBackingOpacity
    static let primaryForegroundHex: UInt32 = 0xFFFFFF
    static let supportingForegroundHex = LifeOSPalette.transparentWidgetSupportingHex
    static let reviewedGreyWallpapers: [UInt32] = [0x606060, 0x808080, 0xA0A0A0, 0xFFFFFF]

    static func compositedBackingHex(over wallpaperHex: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let wallpaper = Double((wallpaperHex >> shift) & 0xFF)
            let value = (wallpaper * (1 - backingOpacity)).rounded()
            return UInt32(min(max(value, 0), 255))
        }

        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }

    static func contrastRatio(foregroundHex: UInt32, over wallpaperHex: UInt32) -> Double {
        LifeOSContrast.contrastRatio(
            foreground: foregroundHex,
            background: compositedBackingHex(over: wallpaperHex)
        )
    }

    static func meetsTextContrast(over wallpaperHex: UInt32) -> Bool {
        contrastRatio(foregroundHex: primaryForegroundHex, over: wallpaperHex) >= 4.5
            && contrastRatio(foregroundHex: supportingForegroundHex, over: wallpaperHex) >= 4.5
    }
}

/// The selected-navigation colors are kept as named sRGB contract values so
/// tests can verify both appearance pairs without attempting to introspect a
/// platform-specific adaptive `Color` provider.
enum LifeOSSelectedNavigationPalette {
    static let darkForegroundHex: UInt32 = 0xB8D5FE
    static let darkBackgroundHex: UInt32 = 0x011E47
    static let lightForegroundHex: UInt32 = 0x0244A2
    static let lightBackgroundHex: UInt32 = 0xE6F0FF
}

/// Semantic pairs used by controls and data meaning. Keep these values in
/// lockstep with the adaptive Color roles below.
enum LifeOSSemanticColorPairs {
    static let primaryAction = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.canvasDarkHex,
        darkBackgroundHex: LifeOSPalette.primaryTextDarkHex,
        lightForegroundHex: LifeOSPalette.canvasLightHex,
        lightBackgroundHex: LifeOSPalette.primaryTextLightHex
    )
    static let primaryActionHover = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.canvasDarkHex,
        darkBackgroundHex: 0xD9D9DD,
        lightForegroundHex: LifeOSPalette.canvasLightHex,
        lightBackgroundHex: 0x303036
    )
    static let primaryActionPressed = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.canvasDarkHex,
        darkBackgroundHex: 0xC2C2C7,
        lightForegroundHex: LifeOSPalette.canvasLightHex,
        lightBackgroundHex: 0x50505A
    )
    static let selectedNavigation = LifeOSColorPair(
        darkForegroundHex: LifeOSSelectedNavigationPalette.darkForegroundHex,
        darkBackgroundHex: LifeOSSelectedNavigationPalette.darkBackgroundHex,
        lightForegroundHex: LifeOSSelectedNavigationPalette.lightForegroundHex,
        lightBackgroundHex: LifeOSSelectedNavigationPalette.lightBackgroundHex
    )
    static let focus = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.focusBlueHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: LifeOSPalette.brandBlueHex,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let neutralTarget = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.targetGreenHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: LifeOSPalette.targetGreenLightHex,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let target = neutralTarget
    static let estimate = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.targetGreenHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: LifeOSPalette.targetGreenLightHex,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let success = estimate
    static let warning = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.warningAmberHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: LifeOSPalette.warningAmberLightHex,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let warningText = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.warningAmberHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: LifeOSPalette.warningTextLightHex,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let danger = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.dangerRedHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: LifeOSPalette.dangerRedLightHex,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let info = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.infoTealHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: LifeOSPalette.infoTealLightHex,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let calories = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.calorieOrangeHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: 0xA25A03,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let protein = LifeOSColorPair(
        darkForegroundHex: LifeOSPalette.proteinTealHex,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: 0x067878,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let link = LifeOSColorPair(
        darkForegroundHex: 0xB8D5FE,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: 0x013174,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
    static let disabled = LifeOSColorPair(
        darkForegroundHex: 0xA1A1AA,
        darkBackgroundHex: LifeOSPalette.surfaceDarkHex,
        lightForegroundHex: 0x52525B,
        lightBackgroundHex: LifeOSPalette.surfaceLightHex
    )
}

// MARK: - Branded Color Palette

public extension Color {
    // Keep adaptive roles in this file so structural colors remain identical on
    // both Apple targets without making Shared depend on an app-specific theme.
#if os(macOS)
    private static func lifeOSAdaptiveColor(
        darkRed: Double,
        darkGreen: Double,
        darkBlue: Double,
        lightRed: Double,
        lightGreen: Double,
        lightBlue: Double
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: CGFloat(darkRed), green: CGFloat(darkGreen), blue: CGFloat(darkBlue), alpha: 1)
                : NSColor(srgbRed: CGFloat(lightRed), green: CGFloat(lightGreen), blue: CGFloat(lightBlue), alpha: 1)
        })
    }
#else
    private static func lifeOSAdaptiveColor(
        darkRed: Double,
        darkGreen: Double,
        darkBlue: Double,
        lightRed: Double,
        lightGreen: Double,
        lightBlue: Double
    ) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: CGFloat(darkRed), green: CGFloat(darkGreen), blue: CGFloat(darkBlue), alpha: 1)
                : UIColor(red: CGFloat(lightRed), green: CGFloat(lightGreen), blue: CGFloat(lightBlue), alpha: 1)
        })
    }
#endif

    private static func lifeOSAdaptiveHex(dark: UInt32, light: UInt32) -> Color {
        func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
            (
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }

        let darkComponents = components(dark)
        let lightComponents = components(light)
        return lifeOSAdaptiveColor(
            darkRed: darkComponents.red,
            darkGreen: darkComponents.green,
            darkBlue: darkComponents.blue,
            lightRed: lightComponents.red,
            lightGreen: lightComponents.green,
            lightBlue: lightComponents.blue
        )
    }

    /// Convenience initializer from a packed 24-bit hex value, e.g. `Color(hex: 0x036BFC)`.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Black #000000
    static let lifeOSBlack = Color(red: 0x00/255, green: 0x00/255, blue: 0x00/255)
    /// White #FFFFFF
    static let lifeOSWhite = Color(red: 0xFF/255, green: 0xFF/255, blue: 0xFF/255)

    // Blue scale (brand)
    static let lifeOSBlue50  = Color(red: 0xE6/255, green: 0xF0/255, blue: 0xFF/255)
    static let lifeOSBlue100 = Color(red: 0xB8/255, green: 0xD5/255, blue: 0xFE/255)
    static let lifeOSBlue200 = Color(red: 0x8B/255, green: 0xBB/255, blue: 0xFE/255)
    static let lifeOSBlue300 = Color(red: 0x5D/255, green: 0xA0/255, blue: 0xFD/255)
    static let lifeOSBlue400 = Color(red: 0x30/255, green: 0x85/255, blue: 0xFD/255)
    static let lifeOSBlue500 = Color(red: 0x03/255, green: 0x6B/255, blue: 0xFC/255)
    /// Main blue #0253C4
    static let lifeOSBlue600 = Color(red: 0x02/255, green: 0x53/255, blue: 0xC4/255)
    static let lifeOSBlue700 = Color(red: 0x02/255, green: 0x44/255, blue: 0xA2/255)
    static let lifeOSBlue800 = Color(red: 0x01/255, green: 0x31/255, blue: 0x74/255)
    static let lifeOSBlue900 = Color(red: 0x01/255, green: 0x1E/255, blue: 0x47/255)
    static let lifeOSBlue950 = Color(red: 0x00/255, green: 0x0B/255, blue: 0x19/255)

    // MARK: Vivid sibling hue ramps (OKLCH peak-chroma, matched to brand blue's energy)
    // Each hue: 400 (reveal/light) · 500 (base) · 600 · 700 (deep).
    // Source of truth: design-coordination/01-color-system-v2.md. Do not eyeball new values —
    // derive with the same OKLCH peak-chroma method noted there if a hue is ever added.

    static let lifeOSViolet400 = Color(hex: 0x8D74FE)
    static let lifeOSViolet500 = Color(hex: 0x7539FF)
    static let lifeOSViolet600 = Color(hex: 0x5E06DC)
    static let lifeOSViolet700 = Color(hex: 0x4502A5)

    static let lifeOSPurple400 = Color(hex: 0xC853E2)
    static let lifeOSPurple500 = Color(hex: 0xAF00CD)
    static let lifeOSPurple600 = Color(hex: 0x8903A1)
    static let lifeOSPurple700 = Color(hex: 0x650177)

    static let lifeOSPink400 = Color(hex: 0xFE6B95)
    static let lifeOSPink500 = Color(hex: 0xF30072)
    static let lifeOSPink600 = Color(hex: 0xC4085B)
    static let lifeOSPink700 = Color(hex: 0x990445)

    static let lifeOSRed400 = Color(hex: 0xFC584F)
    static let lifeOSRed500 = Color(hex: 0xE50019)
    static let lifeOSRed600 = Color(hex: 0xB70112)
    static let lifeOSRed700 = Color(hex: 0x8A030C)

    static let lifeOSOrange400 = Color(hex: 0xFFB06E)
    static let lifeOSOrange500 = Color(hex: 0xEF8600)
    static let lifeOSOrange600 = Color(hex: 0xC87004)
    static let lifeOSOrange700 = Color(hex: 0xA25A03)

    static let lifeOSAmber400 = Color(hex: 0xFBDD68)
    static let lifeOSAmber500 = Color(hex: 0xDFBB00)
    static let lifeOSAmber600 = Color(hex: 0xBE9F06)
    static let lifeOSAmber700 = Color(hex: 0x9E8405)

    static let lifeOSLime400 = Color(hex: 0xBCF469)
    static let lifeOSLime500 = Color(hex: 0x96D500)
    static let lifeOSLime600 = Color(hex: 0x80B606)
    static let lifeOSLime700 = Color(hex: 0x6A9706)

    static let lifeOSGreen400 = Color(hex: 0x60D386)
    static let lifeOSGreen500 = Color(hex: 0x00B65D)
    static let lifeOSGreen600 = Color(hex: 0x09964C)
    static let lifeOSGreen700 = Color(hex: 0x01773B)

    static let lifeOSTeal400 = Color(hex: 0x63D2D2)
    static let lifeOSTeal500 = Color(hex: 0x00B5B5)
    static let lifeOSTeal600 = Color(hex: 0x029696)
    static let lifeOSTeal700 = Color(hex: 0x067878)

    // MARK: Module identity
    // Calendar identity accent. The light-mode value uses the deeper ramp so
    // small labels and icons remain readable on a light surface; the dark
    // value keeps the vivid red visible without turning the whole surface red.
    static let lifeOSCalendarRed = lifeOSAdaptiveColor(
        darkRed: 0xFC/255, darkGreen: 0x58/255, darkBlue: 0x4F/255,
        lightRed: 0xB7/255, lightGreen: 0x01/255, lightBlue: 0x12/255
    )

    // Brand canvases
    /// Neutral dark canvas #000000 (reserved for the tab-bar underlay).
    static let lifeOSDarkCanvas = Color(hex: LifeOSPalette.canvasDarkHex)
    /// Neutral light canvas #FAFAFA.
    static let lifeOSLightCanvas = Color(hex: LifeOSPalette.canvasLightHex)

    /// Neutral structural roles used by the shared foundation.
    static let lifeOSDarkSurface = Color(hex: LifeOSPalette.surfaceDarkHex)
    static let lifeOSLightSurface = Color(hex: LifeOSPalette.surfaceLightHex)
    static let lifeOSDarkRaised = lifeOSDarkSurface
    static let lifeOSLightRaised = lifeOSLightSurface
    static let lifeOSDarkFloatingOverlay = lifeOSDarkSurface
    static let lifeOSLightFloatingOverlay = lifeOSLightSurface

    static let lifeOSPrimaryText = lifeOSAdaptiveColor(
        darkRed: 0xF5/255, darkGreen: 0xF5/255, darkBlue: 0xF7/255,
        lightRed: 0x11/255, lightGreen: 0x11/255, lightBlue: 0x13/255
    )

    static let lifeOSSecondaryText = lifeOSAdaptiveColor(
        darkRed: 0xAD/255, darkGreen: 0xAD/255, darkBlue: 0xB4/255,
        lightRed: 0x5C/255, lightGreen: 0x5C/255, lightBlue: 0x63/255
    )

    /// Adaptive metadata/tertiary text for normal-size supporting copy. These
    /// values preserve the quiet hierarchy while clearing the 4.5:1 small-text
    /// threshold on the dark card and light canvas surfaces.
    static let lifeOSMetadataText = lifeOSAdaptiveColor(
        darkRed: 0x84/255, darkGreen: 0x84/255, darkBlue: 0x8C/255,
        lightRed: 0x6D/255, lightGreen: 0x6D/255, lightBlue: 0x74/255
    )

    /// Disabled text only.
    static let lifeOSQuaternaryText = lifeOSAdaptiveColor(
        darkRed: 0x52/255, darkGreen: 0x52/255, darkBlue: 0x5B/255,
        lightRed: 0xA1/255, lightGreen: 0xA1/255, lightBlue: 0xAA/255
    )

    /// THE structural border (#29292F / #D0D0D6), solid, drawn at 1pt.
    static let lifeOSSubtleBorder = lifeOSAdaptiveColor(
        darkRed: Double((LifeOSPalette.borderDarkHex >> 16) & 0xFF)/255,
        darkGreen: Double((LifeOSPalette.borderDarkHex >> 8) & 0xFF)/255,
        darkBlue: Double(LifeOSPalette.borderDarkHex & 0xFF)/255,
        lightRed: Double((LifeOSPalette.borderLightHex >> 16) & 0xFF)/255,
        lightGreen: Double((LifeOSPalette.borderLightHex >> 8) & 0xFF)/255,
        lightBlue: Double(LifeOSPalette.borderLightHex & 0xFF)/255
    )

    /// Pressed/selected edges only.
    static let lifeOSStrongBorder = lifeOSAdaptiveColor(
        darkRed: 0x30/255, darkGreen: 0x30/255, darkBlue: 0x38/255,
        lightRed: 0xD4/255, lightGreen: 0xD4/255, lightBlue: 0xD8/255
    )

    /// Observed chart blue: #3085FD in dark mode and #0253C4 in light mode.
    static let lifeOSObservedBlue = lifeOSAdaptiveHex(
        dark: LifeOSPalette.observedBlueHex,
        light: LifeOSPalette.brandBlueHex
    )

    /// Focus uses the lighter blue 300 dark-mode pair while observed data uses
    /// blue 400; both resolve to the deeper brand blue in light mode.
    static let lifeOSFocusBlue = lifeOSAdaptiveHex(
        dark: LifeOSPalette.focusBlueHex,
        light: LifeOSPalette.brandBlueHex
    )

    // Explicit action, link, focus, and data-meaning roles. These are kept
    // separate from the general accent so a future screen cannot accidentally
    // make a chart series look like a button or a focus ring.
    static let lifeOSPrimaryActionFill = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.primaryAction.darkBackgroundHex,
        light: LifeOSSemanticColorPairs.primaryAction.lightBackgroundHex
    )
    static let lifeOSOnPrimaryAction = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.primaryAction.darkForegroundHex,
        light: LifeOSSemanticColorPairs.primaryAction.lightForegroundHex
    )
    // Primary action states keep the monochrome action role and change only
    // luminance. They are transient state colors, not a second accent family.
    static let lifeOSPrimaryActionHover = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.primaryActionHover.darkBackgroundHex,
        light: LifeOSSemanticColorPairs.primaryActionHover.lightBackgroundHex
    )
    static let lifeOSPrimaryActionPressed = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.primaryActionPressed.darkBackgroundHex,
        light: LifeOSSemanticColorPairs.primaryActionPressed.lightBackgroundHex
    )
    static let lifeOSLinkForeground = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.link.darkForegroundHex,
        light: LifeOSSemanticColorPairs.link.lightForegroundHex
    )
    static let lifeOSFocusStroke = lifeOSFocusBlue
    static let lifeOSNeutralTarget = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.neutralTarget.darkForegroundHex,
        light: LifeOSSemanticColorPairs.neutralTarget.lightForegroundHex
    )
    static let lifeOSEstimateGreen = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.estimate.darkForegroundHex,
        light: LifeOSSemanticColorPairs.estimate.lightForegroundHex
    )
    /// Compatibility alias retained for the existing widget snapshot target;
    /// new code should use the semantic estimate role above.
    static let lifeOSSeriesEstimate = lifeOSEstimateGreen
    static let lifeOSCalories = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.calories.darkForegroundHex,
        light: LifeOSSemanticColorPairs.calories.lightForegroundHex
    )
    static let lifeOSProtein = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.protein.darkForegroundHex,
        light: LifeOSSemanticColorPairs.protein.lightForegroundHex
    )
    static let lifeOSEssentialBorder = lifeOSAdaptiveHex(dark: 0x73737D, light: 0x767680)
    static let lifeOSDisabledFill = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.disabled.darkBackgroundHex,
        light: LifeOSSemanticColorPairs.disabled.lightBackgroundHex
    )
    static let lifeOSDisabledForeground = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.disabled.darkForegroundHex,
        light: LifeOSSemanticColorPairs.disabled.lightForegroundHex
    )

    /// The selected-navigation pair is deliberately distinct from focus
    /// blue: a row needs a stable filled surface and a text color that stays
    /// readable in both appearances.
    static let lifeOSSelectedNavigationFill = lifeOSAdaptiveHex(
        dark: LifeOSSelectedNavigationPalette.darkBackgroundHex,
        light: LifeOSSelectedNavigationPalette.lightBackgroundHex
    )
    static let lifeOSSelectedNavigationText = lifeOSAdaptiveHex(
        dark: LifeOSSelectedNavigationPalette.darkForegroundHex,
        light: LifeOSSelectedNavigationPalette.lightForegroundHex
    )

    // Module identity accents. These stay vivid on the dark canvas and move
    // to the deeper sibling ramp in light mode so labels remain readable.
    static let lifeOSFinanceGreen = lifeOSAdaptiveColor(
        darkRed: 0x00/255, darkGreen: 0xB6/255, darkBlue: 0x5D/255,
        lightRed: 0x09/255, lightGreen: 0x96/255, lightBlue: 0x4C/255
    )
    static let lifeOSFitnessViolet = lifeOSAdaptiveColor(
        darkRed: 0x8D/255, darkGreen: 0x74/255, darkBlue: 0xFE/255,
        lightRed: 0x5E/255, lightGreen: 0x06/255, lightBlue: 0xDC/255
    )
    /// Nutrition identity accent — pink keeps food surfaces distinct from
    /// Fitness violet while retaining a readable deeper light-mode ramp.
    static let lifeOSNutritionPink = lifeOSAdaptiveColor(
        darkRed: 0xFE/255, darkGreen: 0x6B/255, darkBlue: 0x95/255,
        lightRed: 0xC4/255, lightGreen: 0x08/255, lightBlue: 0x5B/255
    )
    static let lifeOSTasksOrange = lifeOSAdaptiveColor(
        darkRed: 0xFF/255, darkGreen: 0xB0/255, darkBlue: 0x6E/255,
        lightRed: 0xC8/255, lightGreen: 0x70/255, lightBlue: 0x04/255
    )
    static let lifeOSTealInfo = lifeOSAdaptiveColor(
        darkRed: 0x63/255, darkGreen: 0xD2/255, darkBlue: 0xD2/255,
        lightRed: 0x02/255, lightGreen: 0x96/255, lightBlue: 0x96/255
    )
    /// Tax identity uses the purple sibling ramp so it remains distinct from
    /// the teal Business/Info accent in navigation and supporting surfaces.
    static let lifeOSTaxPurple = lifeOSAdaptiveColor(
        darkRed: 0xAF/255, darkGreen: 0x00/255, darkBlue: 0xCD/255,
        lightRed: 0x89/255, lightGreen: 0x03/255, lightBlue: 0xA1/255
    )

    static let lifeOSNeutralCanvas = lifeOSAdaptiveHex(
        dark: LifeOSPalette.canvasDarkHex,
        light: LifeOSPalette.canvasLightHex
    )

    static let lifeOSNeutralSurface = lifeOSAdaptiveHex(
        dark: LifeOSPalette.surfaceDarkHex,
        light: LifeOSPalette.surfaceLightHex
    )

    /// Compatibility aliases intentionally resolve to the one structural
    /// surface. Interaction states add transient overlays at call sites.
    static let lifeOSNeutralRaised = lifeOSNeutralSurface
    static let lifeOSNeutralFloatingOverlay = lifeOSNeutralSurface

    /// Accent hover: lighter on dark, darker on light (inverted direction).
    static let lifeOSAccentHover = lifeOSAdaptiveColor(
        darkRed: 0x7A/255, darkGreen: 0xB2/255, darkBlue: 0xFF/255,
        lightRed: 0x02/255, lightGreen: 0x47/255, lightBlue: 0xA8/255
    )
    static let lifeOSAccentPressed = lifeOSAdaptiveColor(
        darkRed: 0x93/255, darkGreen: 0xC3/255, darkBlue: 0xFF/255,
        lightRed: 0x01/255, lightGreen: 0x3C/255, lightBlue: 0x8C/255
    )
    /// Success/income/completed/target/estimate green from the product palette.
    static let lifeOSSuccess = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.success.darkForegroundHex,
        light: LifeOSSemanticColorPairs.success.lightForegroundHex
    )
    /// Text-safe semantic green. Indicators may keep the more vivid `success`.
    static let lifeOSSuccessText = lifeOSSuccess
    /// Amber indicator role and a darker light-mode text role both come from
    /// the same authored sibling ramp.
    static let lifeOSWarning = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.warning.darkForegroundHex,
        light: LifeOSSemanticColorPairs.warning.lightForegroundHex
    )
    static let lifeOSWarningText = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.warningText.darkForegroundHex,
        light: LifeOSSemanticColorPairs.warningText.lightForegroundHex
    )
    static let lifeOSDanger = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.danger.darkForegroundHex,
        light: LifeOSSemanticColorPairs.danger.lightForegroundHex
    )
    static let lifeOSInfo = lifeOSAdaptiveHex(
        dark: LifeOSSemanticColorPairs.info.darkForegroundHex,
        light: LifeOSSemanticColorPairs.info.lightForegroundHex
    )
}

// MARK: - Design Tokens

public enum LifeOSTokens {
    // MARK: Spacing and geometry

    /// The only spacing steps used by the shared foundation.
    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        /// Compatibility name for the 24pt foundation step. New layout code
        /// should use `LifeOSTokens.sectionGap` when the relationship is a
        /// section boundary rather than a generic spacing value.
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        /// The 48pt page-level separation step.
        public static let xxxl: CGFloat = 48
        /// The 64pt page-end/major composition step.
        public static let xxxxl: CGFloat = 64
    }

    /// Allowed corner radii. Capsules are used for status/selectors.
    public enum Radius {
        public static let control: CGFloat = 8
        public static let card: CGFloat = 12
        public static let hero: CGFloat = 16
        public static let tooltip: CGFloat = 8
        public static let widget: CGFloat = 12
    }

    /// Platform minimums for interactive controls and pointer targets.
    public enum Control {
#if os(macOS)
        public static let minimumTarget: CGFloat = 32
        public static let standardHeight: CGFloat = 32
        public static let iconButton: CGFloat = 32
#else
        public static let minimumTarget: CGFloat = 44
        public static let standardHeight: CGFloat = 44
        public static let iconButton: CGFloat = 44
#endif
    }

    /// The canonical SF Symbol geometry. The visual glyph stays smaller than
    /// its hit target so adjacent controls never compete for space.
    public enum Icon {
        public static let box: CGFloat = 24
        public static let glyph: CGFloat = 17
        public static let statusBox: CGFloat = 20
    }

#if os(macOS)
    /// macOS page gutter; wider windows use the 32pt breakpoint in the responsive metrics.
    public static let pageGutter: CGFloat = 24
#else
    /// iPhone page gutter.
    public static let pageGutter: CGFloat = 16
#endif

    /// Standard page-frame content width. Viewport surfaces such as Calendar
    /// intentionally bypass the shared content container when they need the
    /// full available canvas.
    public static let contentMaxWidth: CGFloat = 1120
    public static let chartMaxWidth: CGFloat = 1440

    // MARK: Named layout relationships and compatibility aliases

    /// Existing screens still use this name while they migrate to
    /// `pageGutter`; it must not reintroduce the old 20pt drift.
    public static let pagePadding: CGFloat = pageGutter
    public static let spacing: CGFloat = Space.sm
    public static let corner: CGFloat = Radius.card
    public static let smallCorner: CGFloat = Radius.control
    public static let cardPadding: CGFloat = Space.md
    /// Existing overview callers now resolve to the canonical page gutter.
    public static let overviewContentInset: CGFloat = pageGutter
    public static let overviewCardGap: CGFloat = Space.md
    public static let overviewCardCorner: CGFloat = Radius.card

    public static let sectionGap: CGFloat = Space.xl
    public static let pageEndSpacing: CGFloat = Space.xxl
    public static let siblingGap: CGFloat = Space.md
    public static let labelValueGap: CGFloat = Space.xs
    public static let labelHelperGap: CGFloat = Space.xxs
    public static let proseMaxWidth: CGFloat = 640
    public static let statusRowMinHeight: CGFloat = 56

    // MARK: Canvas & Surface (theme-aware)

    public static let canvas = Color.lifeOSNeutralCanvas
    public static let surface = Color.lifeOSNeutralSurface
    public static let raised = Color.lifeOSNeutralRaised
    public static let floatingOverlay = Color.lifeOSNeutralFloatingOverlay

    public static let darkCanvas = Color.lifeOSDarkCanvas
    public static let lightCanvas = Color.lifeOSLightCanvas

    // MARK: Widget readability

    /// The approved inner contrast surface for clear/accented widgets. It is
    /// independent of the WidgetKit container so grey wallpapers cannot erase
    /// the text hierarchy.
    public static let widgetTransparentBacking = Color.lifeOSBlack.opacity(
        LifeOSWidgetContrastPolicy.backingOpacity
    )
    public static let widgetTransparentSupporting = Color(hex: LifeOSWidgetContrastPolicy.supportingForegroundHex)
    public static let widgetTransparentPanel = Color.lifeOSWhite.opacity(0.10)

    // Exact branded light/dark canvas, selected by the platform appearance.
    public static var screenCanvas: Color { canvas }

    // MARK: Semantic Colors

    /// Used for focus and primary data, never as structural chrome.
    public static let accent = Color.lifeOSFocusBlue
    /// The sole filled primary action role. It is deliberately distinct from
    /// the adaptive focus/data blue above.
    public static let primaryActionFill = Color.lifeOSPrimaryActionFill
    public static let onPrimaryAction = Color.lifeOSOnPrimaryAction
    public static let primaryActionHover = Color.lifeOSPrimaryActionHover
    public static let primaryActionPressed = Color.lifeOSPrimaryActionPressed
    public static let linkForeground = Color.lifeOSLinkForeground
    public static let focusStroke = Color.lifeOSFocusStroke
    /// Pressed reads lighter on dark, darker on light (inverted direction).
    public static let accentHover = Color.lifeOSAccentHover
    public static let accentPressed = Color.lifeOSAccentPressed
    public static let accentLight = Color.lifeOSBlue50
    public static let selectedNavigationFill = Color.lifeOSSelectedNavigationFill
    public static let selectedNavigationText = Color.lifeOSSelectedNavigationText

    public static let chartObserved = Color.lifeOSObservedBlue
    public static let primaryText = Color.lifeOSPrimaryText
    public static let secondaryText = Color.lifeOSSecondaryText
    public static let metadataText = Color.lifeOSMetadataText
    public static let subtleBorder = Color.lifeOSSubtleBorder
    public static let strongBorder = Color.lifeOSStrongBorder
    /// Essential unfilled-control edge; decorative separators keep the
    /// lighter `subtleBorder` role.
    public static let essentialBorder = Color.lifeOSEssentialBorder
    /// Disabled text only — never for readable content.
    public static let quaternaryText = Color.lifeOSQuaternaryText
    public static let disabledFill = Color.lifeOSDisabledFill
    public static let disabledForeground = Color.lifeOSDisabledForeground

    /// success / positive / income / target-met → Apple-dark green (calmer light green)
    public static let success = Color.lifeOSSuccess
    /// Text-safe success for normal-size labels; `success` stays vivid for dots,
    /// icons, and chart series.
    public static let successText = Color.lifeOSSuccessText
    /// warning / near-limit → readable amber in both modes
    public static let warning = Color.lifeOSWarning
    /// Text-safe warning for normal-size labels; `warning` stays vivid for dots,
    /// icons, and chart series.
    public static let warningText = Color.lifeOSWarningText
    /// danger / negative / over-limit / failed
    public static let danger  = Color.lifeOSDanger
    /// Green goal/reference mark, separated from estimate by line pattern and label.
    public static let neutralTarget = Color.lifeOSNeutralTarget
    /// Green estimated/projection mark; the estimate label uses this role too.
    public static let estimate = Color.lifeOSEstimateGreen
    /// Orange calorie meaning and teal protein meaning remain stable across
    /// modules, independent of the module identity accent.
    public static let calories = Color.lifeOSCalories
    public static let protein = Color.lifeOSProtein
    /// Teal information state, kept separate from blue focus/data roles.
    public static let info = Color.lifeOSInfo

    // MARK: Series colors (Usage view: Target / Actual / Estimate / History)

    public enum Series {
        /// Observed — accent blue, solid.
        public static let actual = LifeOSTokens.chartObserved
        /// Descriptive alias for new chart call sites. `actual` remains for compatibility.
        public static let observed = LifeOSTokens.chartObserved
        /// Current estimate — green, dashed [6,4] at 2pt.
        public static let estimate = LifeOSTokens.estimate
        /// Goal/reference line, green and dashed [2,4].
        public static let target = LifeOSTokens.neutralTarget
        /// Past estimate / account history — tertiary grey, dotted at 1.25pt.
        public static let history = LifeOSTokens.metadataText
    }

    // MARK: Ring tokens

    public enum Ring {
        /// The hairline border doubles as the ring track — no per-color tracks.
        public static let track = Color.lifeOSSubtleBorder

        /// The sanctioned arc colors: progress rings read accent; status rings
        /// read a semantic by threshold (FitnessView implements the bands;
        /// widget status rings mirror them via their local threshold helper).
        public static var progressArc: Color { LifeOSTokens.accent }
    }

    // MARK: Module identity
    /// Small, stable identity accents for module headers and cards. These are
    /// visual wayfinding, not status semantics.
    public enum Module {
        public static let usage = LifeOSTokens.accent
        public static let finance = Color.lifeOSFinanceGreen
        public static let calendar = Color.lifeOSCalendarRed
        public static let fitness = Color.lifeOSFitnessViolet
        public static let nutrition = Color.lifeOSNutritionPink
        public static let tasks = Color.lifeOSTasksOrange
        public static let business = Color.lifeOSTealInfo
        public static let tax = Color.lifeOSTaxPurple

        /// A restrained tint for selected navigation and module surfaces.
        /// The accent is still paired with a label, icon shape, or selection
        /// trait; color is never the only state channel.
        public static func surface(_ accent: Color, opacity: CGFloat = 0.12) -> Color {
            accent.opacity(opacity)
        }
    }

    public static let calendarRed = Color.lifeOSCalendarRed

    // Borders & quiescent states
    /// THE border: solid hairline, 1pt (0.5pt inside charts).
    public static let hairlineBorder = subtleBorder
    public static let quietBorder = hairlineBorder
    /// Chart gridlines: the same hairline, drawn at 0.5pt, horizontal only.
    public static let chartGrid = hairlineBorder
    public static let tertiaryText = metadataText

    // Card visual styling — shadow policy: NONE at rest. Sheets rely on the
    // system material; no `.shadow()` survives outside platform chrome.
    public static let cardShadowRadius: CGFloat = 0
    public static let cardShadowX: CGFloat = 0
    public static let cardShadowY: CGFloat = 0

    /// A named hue ramp from the vivid palette, used to key gradients/rings/charts by module or
    /// semantic meaning without repeating raw color literals at call sites.
    public enum Hue {
        case blue, violet, purple, pink, red, orange, amber, lime, green, teal

        /// The light/reveal stop (kept as `glow` for source compatibility). This is a
        /// gradient stop, not permission to render a persistent halo.
        public var glow: Color {
            switch self {
            case .blue: .lifeOSBlue400
            case .violet: .lifeOSViolet400
            case .purple: .lifeOSPurple400
            case .pink: .lifeOSPink400
            case .red: .lifeOSRed400
            case .orange: .lifeOSOrange400
            case .amber: .lifeOSAmber400
            case .lime: .lifeOSLime400
            case .green: .lifeOSGreen400
            case .teal: .lifeOSTeal400
            }
        }

        public var base: Color {
            switch self {
            case .blue: .lifeOSBlue500
            case .violet: .lifeOSViolet500
            case .purple: .lifeOSPurple500
            case .pink: .lifeOSPink500
            case .red: .lifeOSRed500
            case .orange: .lifeOSOrange500
            case .amber: .lifeOSAmber500
            case .lime: .lifeOSLime500
            case .green: .lifeOSGreen500
            case .teal: .lifeOSTeal500
            }
        }

        public var deep600: Color {
            switch self {
            case .blue: .lifeOSBlue600
            case .violet: .lifeOSViolet600
            case .purple: .lifeOSPurple600
            case .pink: .lifeOSPink600
            case .red: .lifeOSRed600
            case .orange: .lifeOSOrange600
            case .amber: .lifeOSAmber600
            case .lime: .lifeOSLime600
            case .green: .lifeOSGreen600
            case .teal: .lifeOSTeal600
            }
        }

        public var deep700: Color {
            switch self {
            case .blue: .lifeOSBlue700
            case .violet: .lifeOSViolet700
            case .purple: .lifeOSPurple700
            case .pink: .lifeOSPink700
            case .red: .lifeOSRed700
            case .orange: .lifeOSOrange700
            case .amber: .lifeOSAmber700
            case .lime: .lifeOSLime700
            case .green: .lifeOSGreen700
            case .teal: .lifeOSTeal700
            }
        }
    }

    // MARK: Convenience Shapes

    public static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    public static var smallCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: smallCorner, style: .continuous)
    }

    public static var heroShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
    }

    public static var pillShape: Capsule {
        Capsule()
    }
}

// MARK: - Motion (Reduce Motion aware)

public enum LifeOSMotion {

    /// Inspectable timing specifications. Spring response is not a completion deadline;
    /// gesture owners use animation completion callbacks, never delayed timers.
    public enum Curve: Equatable, Sendable {
        case easeOut(Double)
        case easeInOut(Double)
        case spring(response: Double, damping: Double)
        case interactive(response: Double, damping: Double)
        case direct

        public var animation: Animation {
            switch self {
            case let .easeOut(duration): return .easeOut(duration: duration)
            case let .easeInOut(duration): return .easeInOut(duration: duration)
            case let .spring(response, damping):
                return .spring(response: response, dampingFraction: damping)
            case let .interactive(response, damping):
                return .interactiveSpring(response: response, dampingFraction: damping)
            case .direct:
                return .linear(duration: 0)
            }
        }
    }

    public enum Timing {
        public static let press = Curve.easeOut(0.08)
        public static let release = Curve.easeOut(0.18)
        public static let hover = Curve.easeOut(0.12)
        public static let feedback = Curve.easeOut(0.10)
        public static let reducedNavigation = Curve.easeOut(0.12)
        public static let primary = Curve.spring(response: 0.42, damping: 0.82)
        public static let snappy = Curve.spring(response: 0.30, damping: 0.86)
        public static let hero = Curve.spring(response: 0.50, damping: 0.85)
        /// Direct manipulation has no interpolation. The compatibility name
        /// remains so existing callers cannot accidentally add spring lag.
        public static let tracking = Curve.direct
        public static let calendarSettle = Curve.spring(response: 0.28, damping: 0.92)
        public static let tooltip = Curve.easeOut(0.08)
        public static let sheet = Curve.easeOut(0.18)
        public static let refresh = Curve.easeOut(0.10)
        public static let chart = Curve.easeOut(0.72)
        public static let ring = Curve.spring(response: 0.70, damping: 0.90)
    }

    /// Feedback is opacity/fill only under Reduce Motion; geometry stays direct.
    public enum Intent: CaseIterable, Sendable {
        case press, release, hover, selection, navigation, reveal, scrub, cancel
    }

    public static func curve(for intent: Intent, reduceMotion: Bool) -> Curve? {
        switch intent {
        case .press: return reduceMotion ? nil : Timing.press
        case .release: return reduceMotion ? nil : Timing.release
        case .hover: return reduceMotion ? nil : Timing.hover
        case .selection: return reduceMotion ? nil : Timing.snappy
        case .navigation: return reduceMotion ? Timing.reducedNavigation : Timing.hero
        case .reveal: return reduceMotion ? nil : Timing.chart
        case .scrub: return nil // selection, marker and bubble follow the same sample
        case .cancel: return reduceMotion ? nil : Timing.snappy
        }
    }

    /// Explicitly clears inherited animation for direct tracking/reset/cancellation.
    public static func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    // MARK: Canonical micro interactions

    /// Press feedback: short, user-triggered and never a decorative reveal.
    public static let press = Timing.press.animation

    /// Release feedback: lets controls settle without a lift or scale effect.
    public static let release = Timing.release.animation

    /// Pointer hover/focus feedback.
    public static let hover = Timing.hover.animation

    /// Named aliases make intent explicit at call sites while preserving the
    /// existing canonical primitives below.
    public static let selector = Timing.snappy.animation
    public static let card = Timing.primary.animation
    public static let fingerTracking = Timing.tracking.animation

    // MARK: Canonical tokens (03-motion-revolut.md "Canonical spring tokens")

    /// Primary — screen & card transitions. Smooth settle, barely-there life.
    public static let primary = Timing.primary.animation

    /// Snappy — pills, toggles, small controls.
    public static let snappy = Timing.snappy.animation

    /// Hero morph — card→detail expansion (paired with matchedGeometryEffect).
    public static let heroMorph = Timing.hero.animation

    /// Finger tracking — scrub bubble, drag-follow. No response lag.
    public static let track = Timing.tracking.animation

    /// Chart draw-on — the ONE longer, one-shot reveal. Never loops.
    public static let chartDraw = Timing.chart.animation

    /// One-shot ring reveal on appear. Any optional halo is removed when the reveal settles;
    /// Reduce Motion renders the final ring without a halo.
    public static let ringReveal = Timing.ring.animation

    /// Horizontal calendar pager settle (snap-back and page-commit). Snappy, non-bouncy —
    /// matches the native paging deceleration feel without overshoot.
    public static let pagerSettle = Timing.calendarSettle.animation

    // MARK: Legacy aliases (call sites outside this workstream's file boundary still use
    // these names; see ios/LifeOS/CodexView.swift for migrated call sites). Prefer the
    // canonical tokens above at any new/migrated call site.

    /// Alias of `primary`. Was: `.spring(response: 0.46, dampingFraction: 0.90)`.
    public static let spring = primary

    /// Alias of `snappy`. Was: `.spring(response: 0.32, dampingFraction: 0.92)`.
    public static let springSnappy = snappy

    /// Smooth ease for opacity and offset transitions.
    public static let ease = Animation.easeInOut(duration: 0.24)

    /// Top-level tab changes use a short cross-fade; the tab bar itself remains
    /// mounted so navigation never produces duplicate or jumping chrome.
    public static let tabCrossfade = Animation.easeInOut(duration: 0.16)

    /// Slightly longer ease for push/navigation.
    public static let easeNavigate = Animation.easeInOut(duration: 0.34)

    /// Alias of `chartDraw`. Was: `.easeOut(duration: 0.62)`.
    public static let chartReveal = chartDraw

    public static var reduceMotion: Bool {
#if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#else
        UIAccessibility.isReduceMotionEnabled
#endif
    }

    /// Decorative reveals, morphs and loops are removed under Reduce Motion.
    /// User-driven drag/scrub/scroll motion must remain direct and should not
    /// be routed through this helper.
    public static func decorative(_ animation: Animation, reduceMotion: Bool? = nil) -> Animation? {
        (reduceMotion ?? Self.reduceMotion) ? nil : animation
    }
}

// MARK: - Compatibility card recipe

extension View {
    /// The Quiet Machine card: one flat surface fill + ONE solid hairline
    /// border. No gradient, no material, no second stroke, no shadow, and no
    /// reduce-transparency branch (the surface is opaque).
    func flatCard(cornerRadius: CGFloat = LifeOSTokens.overviewCardCorner, featured: Bool = false) -> some View {
        // Keep the compatibility modifier's historical zero-padding behavior
        // while routing its rendering through the canonical card primitive.
        LifeOSCard(
            level: featured ? .raised : .surface,
            cornerRadius: cornerRadius,
            padding: 0
        ) {
            self
        }
    }
}

// MARK: - Button recipe (Quiet Machine §4.3)

/// The four sanctioned button variants.
///
/// Primary   — primary-text fill with a canvas-colored label in both appearances.
/// Secondary — raised neutral fill with a 1pt hairline border, primaryText label.
/// Destructive — clear fill, no border, danger label.
///
/// Pressed state keeps the semantic role and changes luminance only.
public struct LifeOSButtonStyle: ButtonStyle {
    public enum Variant: Equatable {
        case primary
        case secondary
        case tertiary
        case destructive
    }

    public let variant: Variant

    public init(_ variant: Variant = .secondary) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        LifeOSButtonBody(configuration: configuration, variant: variant)
    }
}

private struct LifeOSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: LifeOSButtonStyle.Variant
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    @State private var hovered = false

    var body: some View {
        let pressed = isEnabled && configuration.isPressed
        let highlighted = isEnabled && (hovered || isFocused)
        let reduceMotion = systemReduceMotion || requestedReduceMotion
        return configuration.label
            .lifeOSTypography(.button)
            .foregroundStyle(labelColor)
            .padding(.horizontal, LifeOSTokens.Space.md)
            .frame(
                minWidth: LifeOSTokens.Control.minimumTarget,
                minHeight: LifeOSTokens.Control.standardHeight
            )
            .background(
                fillColor(pressed: pressed, highlighted: highlighted),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .overlay {
                if variant == .secondary {
                    RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                        .stroke(LifeOSTokens.essentialBorder, lineWidth: 1)
                }
            }
            .overlay {
                if isEnabled && isFocused {
                    RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                        .stroke(LifeOSTokens.focusStroke, lineWidth: 2)
                        .padding(-3)
                }
            }
            .onHover { hovered = $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovered = false }
            }
            .onDisappear { hovered = false }
            .animation(
                LifeOSMotion.curve(for: .hover, reduceMotion: reduceMotion)?.animation,
                value: hovered
            )
            .animation(
                LifeOSMotion.curve(for: pressed ? .press : .release,
                                   reduceMotion: reduceMotion)?.animation,
                value: pressed
            )
    }

    private func fillColor(pressed: Bool, highlighted: Bool) -> Color {
        guard isEnabled else { return LifeOSTokens.disabledFill }
        switch variant {
        case .primary:
            if pressed { return LifeOSTokens.primaryActionPressed }
            if highlighted { return LifeOSTokens.primaryActionHover }
            return LifeOSTokens.primaryActionFill
        case .secondary:
            return pressed ? LifeOSTokens.strongBorder : LifeOSTokens.raised
        case .tertiary:
            return highlighted || pressed ? LifeOSTokens.raised : .clear
        case .destructive:
            return pressed ? LifeOSTokens.strongBorder : (highlighted ? LifeOSTokens.raised : .clear)
        }
    }

    private var labelColor: Color {
        guard isEnabled else { return LifeOSTokens.disabledForeground }
        switch variant {
        case .primary:
            return LifeOSTokens.onPrimaryAction
        case .secondary:
            return LifeOSTokens.primaryText
        case .tertiary:
            return LifeOSTokens.linkForeground
        case .destructive:
            return LifeOSTokens.danger
        }
    }
}
