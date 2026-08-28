import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    // Calendar module color — RETIRED for app chrome and widget surfaces
    // (today is marked by primary-text inversion per the Quiet Machine plan
    // §5.6). Remaining consumers are inside CalendarView.swift editor/status
    // UI, which is outside the Phase 2 header-chrome boundary.
    static let lifeOSCalendarRed = Color(hex: 0xE5433D)

    // Brand canvases
    /// Neutral dark canvas #000000 (reserved for the tab-bar underlay).
    static let lifeOSDarkCanvas = Color(hex: 0x000000)
    /// Neutral light canvas #FAFAFA.
    static let lifeOSLightCanvas = Color(hex: 0xFAFAFA)

    /// Neutral structural roles used by the shared foundation.
    static let lifeOSDarkSurface = Color(hex: 0x131315)
    static let lifeOSLightSurface = Color(hex: 0xFFFFFF)
    static let lifeOSDarkRaised = Color(hex: 0x1B1B1E)
    static let lifeOSLightRaised = Color(hex: 0xF4F4F5)
    static let lifeOSDarkFloatingOverlay = Color(hex: 0x232327)
    static let lifeOSLightFloatingOverlay = Color(hex: 0xFFFFFF)

    static let lifeOSPrimaryText = lifeOSAdaptiveColor(
        darkRed: 0xF7/255, darkGreen: 0xF7/255, darkBlue: 0xF8/255,
        lightRed: 0x10/255, lightGreen: 0x10/255, lightBlue: 0x12/255
    )

    static let lifeOSSecondaryText = lifeOSAdaptiveColor(
        darkRed: 0xA1/255, darkGreen: 0xA1/255, darkBlue: 0xAA/255,
        lightRed: 0x52/255, lightGreen: 0x52/255, lightBlue: 0x5B/255
    )

    /// One value for both appearances — the reference surfaces do this.
    static let lifeOSMetadataText = Color(red: 0x71/255, green: 0x71/255, blue: 0x7A/255)

    /// Disabled text only.
    static let lifeOSQuaternaryText = lifeOSAdaptiveColor(
        darkRed: 0x52/255, darkGreen: 0x52/255, darkBlue: 0x5B/255,
        lightRed: 0xA1/255, lightGreen: 0xA1/255, lightBlue: 0xAA/255
    )

    /// THE hairline border (#232329 / #E4E4E7), solid, drawn at 1pt.
    static let lifeOSSubtleBorder = lifeOSAdaptiveColor(
        darkRed: 0x23/255, darkGreen: 0x23/255, darkBlue: 0x29/255,
        lightRed: 0xE4/255, lightGreen: 0xE4/255, lightBlue: 0xE7/255
    )

    /// Pressed/selected edges only.
    static let lifeOSStrongBorder = lifeOSAdaptiveColor(
        darkRed: 0x30/255, darkGreen: 0x30/255, darkBlue: 0x38/255,
        lightRed: 0xD4/255, lightGreen: 0xD4/255, lightBlue: 0xD8/255
    )

    /// Observed chart blue: #3085FD in dark mode and #0253C4 in light mode.
    static let lifeOSObservedBlue = lifeOSAdaptiveColor(
        darkRed: 0x30/255, darkGreen: 0x85/255, darkBlue: 0xFD/255,
        lightRed: 0x02/255, lightGreen: 0x53/255, lightBlue: 0xC4/255
    )

    /// Focus blue: #5DA0FD in dark mode and #0253C4 in light mode.
    static let lifeOSFocusBlue = lifeOSAdaptiveColor(
        darkRed: 0x5D/255, darkGreen: 0xA0/255, darkBlue: 0xFD/255,
        lightRed: 0x02/255, lightGreen: 0x53/255, lightBlue: 0xC4/255
    )

    static let lifeOSNeutralCanvas = lifeOSAdaptiveColor(
        darkRed: 0x0A/255, darkGreen: 0x0A/255, darkBlue: 0x0B/255,
        lightRed: 0xFA/255, lightGreen: 0xFA/255, lightBlue: 0xFA/255
    )

    static let lifeOSNeutralSurface = lifeOSAdaptiveColor(
        darkRed: 0x13/255, darkGreen: 0x13/255, darkBlue: 0x15/255,
        lightRed: 0xFF/255, lightGreen: 0xFF/255, lightBlue: 0xFF/255
    )

    static let lifeOSNeutralRaised = lifeOSAdaptiveColor(
        darkRed: 0x1B/255, darkGreen: 0x1B/255, darkBlue: 0x1E/255,
        lightRed: 0xF4/255, lightGreen: 0xF4/255, lightBlue: 0xF5/255
    )

    static let lifeOSNeutralFloatingOverlay = lifeOSAdaptiveColor(
        darkRed: 0x23/255, darkGreen: 0x23/255, darkBlue: 0x27/255,
        lightRed: 0xFF/255, lightGreen: 0xFF/255, lightBlue: 0xFF/255
    )

    /// Accent hover: lighter on dark, darker on light (inverted direction).
    static let lifeOSAccentHover = lifeOSAdaptiveColor(
        darkRed: 0x7A/255, darkGreen: 0xB2/255, darkBlue: 0xFF/255,
        lightRed: 0x02/255, lightGreen: 0x47/255, lightBlue: 0xA8/255
    )
    static let lifeOSAccentPressed = lifeOSAdaptiveColor(
        darkRed: 0x93/255, darkGreen: 0xC3/255, darkBlue: 0xFF/255,
        lightRed: 0x01/255, lightGreen: 0x3C/255, lightBlue: 0x8C/255
    )
    /// Apple-dark green; calmer light green.
    static let lifeOSSuccess = lifeOSAdaptiveColor(
        darkRed: 0x30/255, darkGreen: 0xD1/255, darkBlue: 0x58/255,
        lightRed: 0x1B/255, lightGreen: 0x9E/255, lightBlue: 0x52/255
    )
    /// Readable amber in both appearances.
    static let lifeOSWarning = lifeOSAdaptiveColor(
        darkRed: 0xFF/255, darkGreen: 0xB2/255, darkBlue: 0x24/255,
        lightRed: 0xC2/255, lightGreen: 0x74/255, lightBlue: 0x03/255
    )
    static let lifeOSDanger = lifeOSAdaptiveColor(
        darkRed: 0xFF/255, darkGreen: 0x45/255, darkBlue: 0x3A/255,
        lightRed: 0xDC/255, lightGreen: 0x26/255, lightBlue: 0x26/255
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
        public static let lg: CGFloat = 20
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 40
    }

    /// Allowed corner radii. Capsules are used for status/selectors.
    public enum Radius {
        public static let control: CGFloat = 8
        public static let card: CGFloat = 12
        public static let hero: CGFloat = 16
    }

    /// Platform minimums for interactive controls and pointer targets.
    public enum Control {
#if os(macOS)
        public static let minimumTarget: CGFloat = 28
        public static let standardHeight: CGFloat = 32
        public static let iconButton: CGFloat = 32
#else
        public static let minimumTarget: CGFloat = 44
        public static let standardHeight: CGFloat = 44
        public static let iconButton: CGFloat = 44
#endif
    }

#if os(macOS)
    /// macOS page gutter; wider windows use the 32pt breakpoint in the responsive metrics.
    public static let pageGutter: CGFloat = 24
#else
    /// iPhone page gutter.
    public static let pageGutter: CGFloat = 16
#endif

    public static let contentMaxWidth: CGFloat = 1240
    public static let chartMaxWidth: CGFloat = 1440

    // MARK: Legacy geometry aliases

    public static let pagePadding: CGFloat = 20
    public static let grid: CGFloat = 4
    public static let spacing: CGFloat = grid * 3
    public static let corner: CGFloat = Radius.card
    public static let smallCorner: CGFloat = Radius.control
    public static let cardPadding: CGFloat = 16
    public static let iconFrame: CGFloat = 32
    public static let overviewContentInset: CGFloat = 40
    public static let overviewCardHeight: CGFloat = 80
    public static let overviewCardGap: CGFloat = Space.md
    public static let overviewCardCorner: CGFloat = Radius.card
    public static let overviewIconTile: CGFloat = 36

    // MARK: Canvas & Surface (theme-aware)

    public static let canvas = Color.lifeOSNeutralCanvas
    public static let surface = Color.lifeOSNeutralSurface
    public static let raised = Color.lifeOSNeutralRaised
    public static let floatingOverlay = Color.lifeOSNeutralFloatingOverlay

    public static let darkCanvas = Color.lifeOSDarkCanvas
    public static let lightCanvas = Color.lifeOSLightCanvas

    // Exact branded light/dark canvas, selected by the platform appearance.
    public static var screenCanvas: Color { canvas }

    // MARK: Semantic Colors

    /// Used for focus and primary data, never as structural chrome.
    public static let accent = Color.lifeOSFocusBlue
    /// Pressed reads lighter on dark, darker on light (inverted direction).
    public static let accentHover = Color.lifeOSAccentHover
    public static let accentPressed = Color.lifeOSAccentPressed
    public static let accentLight = Color.lifeOSBlue50

    public static let chartObserved = Color.lifeOSObservedBlue
    public static let primaryText = Color.lifeOSPrimaryText
    public static let secondaryText = Color.lifeOSSecondaryText
    public static let metadataText = Color.lifeOSMetadataText
    public static let subtleBorder = Color.lifeOSSubtleBorder
    public static let strongBorder = Color.lifeOSStrongBorder
    /// Disabled text only — never for readable content.
    public static let quaternaryText = Color.lifeOSQuaternaryText

    /// success / positive / income / target-met → Apple-dark green (calmer light green)
    public static let success = Color.lifeOSSuccess
    /// warning / near-limit / estimate → readable amber in both modes
    public static let warning = Color.lifeOSWarning
    /// danger / negative / over-limit / failed
    public static let danger  = Color.lifeOSDanger
    /// Retired teal — one accent only. Alias of `accent` kept for compile;
    /// call sites migrate to `accent` (or a semantic) in the Phase 2 sweep.
    /// Deliberately NOT `@available(deprecated)` yet: that would emit warnings
    /// at every un-migrated call site and break the zero-new-warnings gate.
    public static let info = accent

    // MARK: Series colors (Usage view: Target / Actual / Estimate / History)

    public enum Series {
        /// Observed — accent blue, solid.
        public static let actual = LifeOSTokens.chartObserved
        /// Descriptive alias for new chart call sites. `actual` remains for compatibility.
        public static let observed = LifeOSTokens.chartObserved
        /// Target pace — success green, dashed [6,4] at 1.25pt.
        public static let target = LifeOSTokens.success
        /// Current estimate — warning amber, dashed [3,3] at 1.5pt.
        public static let estimate = LifeOSTokens.warning
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
    // RETIRED for chrome and widget surfaces — today markers invert primary
    // text instead. Alias kept for the CalendarView.swift editor/status call
    // sites that sit outside the Phase 2 boundary.
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
    // MARK: Canonical micro interactions

    /// Press feedback: short, user-triggered and never a decorative reveal.
    public static let press = Animation.easeOut(duration: 0.08)

    /// Release feedback: lets controls settle without a lift or scale effect.
    public static let release = Animation.easeOut(duration: 0.18)

    /// Pointer hover/focus feedback.
    public static let hover = Animation.easeOut(duration: 0.12)

    /// Named aliases make intent explicit at call sites while preserving the
    /// existing canonical primitives below.
    public static let selector = Animation.spring(response: 0.30, dampingFraction: 0.86)
    public static let card = Animation.spring(response: 0.42, dampingFraction: 0.82)
    public static let fingerTracking = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.86)

    // MARK: Canonical tokens (03-motion-revolut.md "Canonical spring tokens")

    /// Primary — screen & card transitions. Smooth settle, barely-there life.
    public static let primary = Animation.spring(response: 0.42, dampingFraction: 0.82)

    /// Snappy — pills, toggles, small controls.
    public static let snappy = Animation.spring(response: 0.30, dampingFraction: 0.86)

    /// Hero morph — card→detail expansion (paired with matchedGeometryEffect).
    public static let heroMorph = Animation.spring(response: 0.50, dampingFraction: 0.85)

    /// Finger tracking — scrub bubble, drag-follow. No response lag.
    public static let track = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.86)

    /// Chart draw-on — the ONE longer, one-shot reveal. Never loops.
    public static let chartDraw = Animation.easeOut(duration: 0.72)

    /// One-shot ring reveal on appear. Any optional halo is removed when the reveal settles;
    /// Reduce Motion renders the final ring without a halo.
    public static let ringReveal = Animation.spring(response: 0.7, dampingFraction: 0.9)

    /// Horizontal calendar pager settle (snap-back and page-commit). Snappy, non-bouncy —
    /// matches the native paging deceleration feel without overshoot.
    public static let pagerSettle = Animation.easeOut(duration: 0.2)

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

// MARK: - Branded Modifier Helpers

extension View {
    /// Apply a quiet content surface with a neutral hairline and no decorative shadow.
    func lifeOSCard() -> some View {
        modifier(LifeOSCardModifier())
    }

    /// Status indicator (Quiet Machine §4.2): a 6pt semantic dot plus
    /// overline-style text in the same semantic color. No background, no
    /// stroke — tinted capsules are retired. Uppercase per the overline role.
    func lifeOSStatusPill(color: Color, text: String) -> some View {
        self.overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(text)
                    .font(LifeOSFont.overline())
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The Quiet Machine card: one flat surface fill + ONE solid hairline
    /// border. No gradient, no material, no second stroke, no shadow, and no
    /// reduce-transparency branch (the surface is opaque).
    func flatCard(cornerRadius: CGFloat = LifeOSTokens.overviewCardCorner, featured: Bool = false) -> some View {
        modifier(LifeOSFlatCardModifier(cornerRadius: cornerRadius, featured: featured))
    }

    /// DEPRECATED alias of `flatCard` (Quiet Machine §4.1). All call sites are
    /// migrated; new code must use `flatCard` directly.
    @available(*, deprecated, renamed: "flatCard")
    func glassCard(cornerRadius: CGFloat = LifeOSTokens.overviewCardCorner, featured: Bool = false) -> some View {
        flatCard(cornerRadius: cornerRadius, featured: featured)
    }
}

private struct LifeOSCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(LifeOSTokens.cardPadding)
            .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
            .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
    }
}

private struct LifeOSFlatCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let featured: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(featured ? LifeOSTokens.raised : LifeOSTokens.surface, in: shape)
            .overlay(shape.stroke(LifeOSTokens.hairlineBorder, lineWidth: 1))
            .contentShape(shape)
    }
}

// MARK: - Button recipe (Quiet Machine §4.3)

/// The three sanctioned button variants.
///
/// Primary   — accent fill, no border, white label in both appearances.
/// Secondary — clear fill with a 1pt hairline border, primaryText label.
/// Destructive — clear fill, no border, danger label.
///
/// Pressed state fills `strongBorder` (secondary) / `accentPressed` (primary).
public struct LifeOSButtonStyle: ButtonStyle {
    public enum Variant { case primary, secondary, destructive }

    public let variant: Variant
    @Environment(\.isEnabled) private var isEnabled

    public init(_ variant: Variant = .secondary) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(LifeOSFont.control())
            .foregroundStyle(labelColor(pressed: pressed))
            .padding(.horizontal, LifeOSTokens.Space.md)
            .frame(minHeight: LifeOSTokens.Control.standardHeight)
            .background(
                fillColor(pressed: pressed),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .overlay {
                if variant == .secondary {
                    RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                        .stroke(LifeOSTokens.hairlineBorder, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(LifeOSMotion.press, value: pressed)
    }

    private func fillColor(pressed: Bool) -> Color {
        switch variant {
        case .primary:
            if pressed { return LifeOSTokens.accentPressed }
            return isEnabled ? LifeOSTokens.accent : LifeOSTokens.strongBorder
        case .secondary:
            return pressed ? LifeOSTokens.strongBorder : .clear
        case .destructive:
            return pressed ? LifeOSTokens.strongBorder : .clear
        }
    }

    private func labelColor(pressed: Bool) -> Color {
        switch variant {
        case .primary:
            return .white
        case .secondary:
            return LifeOSTokens.primaryText
        case .destructive:
            return LifeOSTokens.danger
        }
    }
}
