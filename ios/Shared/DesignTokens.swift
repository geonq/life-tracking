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
    // Calendar module color — sample exact value from Figma calendar frames (workstream 04/06).
    // Placeholder warm coral-red, distinct from semantic `danger` red, until sampled.
    static let lifeOSCalendarRed = Color(hex: 0xE5433D)

    // Brand canvases
    /// Neutral dark canvas #000000.
    static let lifeOSDarkCanvas = Color(hex: 0x000000)
    /// Neutral light canvas #F7F7F8.
    static let lifeOSLightCanvas = Color(hex: 0xF7F7F8)

    /// Neutral structural roles used by the shared foundation.
    static let lifeOSDarkSurface = Color(hex: 0x0B0B0C)
    static let lifeOSLightSurface = Color(hex: 0xFFFFFF)
    static let lifeOSDarkRaised = Color(hex: 0x151517)
    static let lifeOSLightRaised = Color(hex: 0xF0F0F2)
    static let lifeOSDarkFloatingOverlay = Color(hex: 0x1F1F22)
    static let lifeOSLightFloatingOverlay = Color(hex: 0xFFFFFF)

    static let lifeOSPrimaryText = lifeOSAdaptiveColor(
        darkRed: 0xF5/255, darkGreen: 0xF5/255, darkBlue: 0xF7/255,
        lightRed: 0x11/255, lightGreen: 0x11/255, lightBlue: 0x13/255
    )

    static let lifeOSSecondaryText = lifeOSAdaptiveColor(
        darkRed: 0xAD/255, darkGreen: 0xAD/255, darkBlue: 0xB4/255,
        lightRed: 0x5C/255, lightGreen: 0x5C/255, lightBlue: 0x63/255
    )

    static let lifeOSMetadataText = lifeOSAdaptiveColor(
        darkRed: 0x84/255, darkGreen: 0x84/255, darkBlue: 0x8C/255,
        lightRed: 0x6D/255, lightGreen: 0x6D/255, lightBlue: 0x74/255
    )

    static let lifeOSSubtleBorder = lifeOSAdaptiveColor(
        darkRed: 0x17/255, darkGreen: 0x17/255, darkBlue: 0x1B/255,
        lightRed: 0xE3/255, lightGreen: 0xE3/255, lightBlue: 0xE7/255
    )

    static let lifeOSStrongBorder = lifeOSAdaptiveColor(
        darkRed: 0x29/255, darkGreen: 0x29/255, darkBlue: 0x2F/255,
        lightRed: 0xD0/255, lightGreen: 0xD0/255, lightBlue: 0xD6/255
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
        darkRed: 0x00/255, darkGreen: 0x00/255, darkBlue: 0x00/255,
        lightRed: 0xF7/255, lightGreen: 0xF7/255, lightBlue: 0xF8/255
    )

    static let lifeOSNeutralSurface = lifeOSAdaptiveColor(
        darkRed: 0x0B/255, darkGreen: 0x0B/255, darkBlue: 0x0C/255,
        lightRed: 0xFF/255, lightGreen: 0xFF/255, lightBlue: 0xFF/255
    )

    static let lifeOSNeutralRaised = lifeOSAdaptiveColor(
        darkRed: 0x15/255, darkGreen: 0x15/255, darkBlue: 0x17/255,
        lightRed: 0xF0/255, lightGreen: 0xF0/255, lightBlue: 0xF2/255
    )

    static let lifeOSNeutralFloatingOverlay = lifeOSAdaptiveColor(
        darkRed: 0x1F/255, darkGreen: 0x1F/255, darkBlue: 0x22/255,
        lightRed: 0xFF/255, lightGreen: 0xFF/255, lightBlue: 0xFF/255
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
    public static let accentHover = Color.lifeOSBlue700
    public static let accentPressed = Color.lifeOSBlue800
    public static let accentLight = Color.lifeOSBlue50

    public static let chartObserved = Color.lifeOSObservedBlue
    public static let primaryText = Color.lifeOSPrimaryText
    public static let secondaryText = Color.lifeOSSecondaryText
    public static let metadataText = Color.lifeOSMetadataText
    public static let subtleBorder = Color.lifeOSSubtleBorder
    public static let strongBorder = Color.lifeOSStrongBorder

    /// success / positive / income / target-met → green 500 (#00B65D)
    public static let success = Color.lifeOSGreen500
    /// warning / near-limit / estimate → amber 500 (#DFBB00)
    public static let warning = Color.lifeOSAmber500
    /// danger / negative / over-limit / failed → red 500 (#E50019)
    public static let danger  = Color.lifeOSRed500
    /// info / secondary accent → teal 500 (#00B5B5)
    public static let info = Color.lifeOSTeal500

    // MARK: Status gradients (reveal → base), for rings (Bevel/Revolut signature)

    public static let statusGradientGood = LinearGradient(
        colors: [.lifeOSGreen400, .lifeOSGreen500],
        startPoint: .top, endPoint: .bottom
    )
    public static let statusGradientWarn = LinearGradient(
        colors: [.lifeOSAmber400, .lifeOSAmber500],
        startPoint: .top, endPoint: .bottom
    )
    public static let statusGradientOver = LinearGradient(
        colors: [.lifeOSRed400, .lifeOSRed500],
        startPoint: .top, endPoint: .bottom
    )

    // MARK: Series colors (Usage view: Target / Actual / Estimate / History)

    public enum Series {
        /// Observed — blue (brand), solid.
        public static let actual = LifeOSTokens.chartObserved
        /// Descriptive alias for new chart call sites. `actual` remains for compatibility.
        public static let observed = LifeOSTokens.chartObserved
        /// Target pace — green, dashed.
        public static let target = Color.lifeOSGreen500
        /// Current estimate — amber/orange, dashed.
        public static let estimate = Color.lifeOSOrange500
        /// Past estimate / account history — grey, dotted.
        public static let history = LifeOSTokens.metadataText
    }

    // MARK: Ring tokens

    public enum Ring {
        public static let track = Color.primary.opacity(0.08)

        /// Angular gradient (reveal 400 → base 500) for a ring's progress arc, keyed by hue.
        public static func progress(_ hue: Hue) -> AngularGradient {
            AngularGradient(colors: [hue.glow, hue.base], center: .center)
        }
    }

    // MARK: Transient reveal halo

    public enum Glow {
        /// Blur radius for the optional one-shot load/reveal cue. Never use this for a
        /// settled, static view or widget.
        public static let blurRadius: CGFloat = 18
        /// Peak opacity for the optional one-shot load/reveal cue. It is removed at rest.
        public static let opacity: Double = 0.55
    }

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

    // MARK: Module identity
    // Calendar's identity color — sample exact value from Figma in the calendar workstream.
    public static let calendarRed = Color.lifeOSCalendarRed

    // Borders & quiescent states
    public static let quietBorder = subtleBorder
    public static let hairlineBorder = subtleBorder.opacity(0.82)
    public static let chartGrid = subtleBorder.opacity(0.78)
    public static let tertiaryText = metadataText

    // Card visual styling
    public static let cardShadowRadius: CGFloat = 0
    public static let cardShadowX: CGFloat = 0
    public static let cardShadowY: CGFloat = 0

    // MARK: Liquid Glass (iOS 26-style card depth)
    //
    // Additive polish over the monochrome foundation: a soft top→bottom surface gradient,
    // a hairline edge-light stroke, a frosted material layer, and a quiet shadow. Peak-chroma
    // accents (Hue.base / semantic tokens) stay the only saturated color;
    // the glass layer itself is neutral so it reads as depth, not tint.
    public enum Glass {
        /// Low-contrast surface gradient, top (lighter) → bottom (deeper). Composited under
        /// the material so the frosted layer has a hint of directional light instead of a
        /// flat tone.
        public static func backgroundGradient(featured: Bool = false) -> LinearGradient {
            LinearGradient(
                colors: [
                    surface.opacity(featured ? 0.98 : 0.95),
                    surface.opacity(featured ? 0.88 : 0.84)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// Frosted material composited over the gradient. Callers must fall back to a solid
        /// surface (`fallbackFill`) when `accessibilityReduceTransparency` is true.
        public static var material: Material { .ultraThinMaterial }

        /// Solid replacement for `material` under Reduce Transparency — no blur, no
        /// translucency, same gradient tone so the layout doesn't shift.
        public static func fallbackFill(featured: Bool = false) -> LinearGradient {
            backgroundGradient(featured: featured)
        }

        /// Hairline edge-light stroke: a soft white-opacity line that reads as glass-edge
        /// catch-light in both appearances, layered above the neutral quietBorder tone.
        public static let edgeHighlight = Color.white.opacity(0.16)

        /// Combined stroke drawn on glass cards: a faint neutral border plus the edge
        /// highlight, both hairline weight.
        public static let strokeWidth: CGFloat = 0.5

        /// Soft ambient shadow — depth, not a drop-shadow effect. Kept very low opacity so it
        /// stays quiet on both light and dark canvases.
        public static let shadowColor = Color.black.opacity(0.16)
        public static let shadowRadius: CGFloat = 14
        public static let shadowX: CGFloat = 0
        public static let shadowY: CGFloat = 6

        /// Subtle gradient for small components (icon tiles, badges, ring tracks) — low
        /// contrast, never a loud fill. Neutral by default; pass a hue for a tinted tile.
        public static func tileGradient(hue: Hue? = nil) -> LinearGradient {
            if let hue {
                return LinearGradient(
                    colors: [hue.base.opacity(0.20), hue.base.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            return LinearGradient(
                colors: [Color.primary.opacity(0.07), Color.primary.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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

    /// Apply a branded pill badge style for status indicators.
    func lifeOSStatusPill(color: Color, text: String) -> some View {
        self.overlay {
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.14), in: LifeOSTokens.pillShape)
                .overlay(LifeOSTokens.pillShape.stroke(color.opacity(0.22)))
        }
    }

    /// iOS-26 "Liquid Glass" card surface: a soft top→bottom gradient, a frosted material
    /// layer, a hairline edge-light stroke, and a quiet ambient shadow. Reusable across
    /// screens — this is the one place the glass recipe lives.
    ///
    /// Falls back to a solid gradient fill (no material, no blur) when
    /// `accessibilityReduceTransparency` is enabled, so content never becomes harder to read.
    func glassCard(cornerRadius: CGFloat = LifeOSTokens.overviewCardCorner, featured: Bool = false) -> some View {
        modifier(LifeOSGlassCardModifier(cornerRadius: cornerRadius, featured: featured))
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

private struct LifeOSGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let featured: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(LifeOSTokens.Glass.fallbackFill(featured: featured))
                } else {
                    ZStack {
                        shape.fill(LifeOSTokens.Glass.backgroundGradient(featured: featured))
                        shape.fill(LifeOSTokens.Glass.material)
                    }
                }
            }
            .overlay(shape.stroke(LifeOSTokens.Glass.edgeHighlight, lineWidth: LifeOSTokens.Glass.strokeWidth))
            .overlay(shape.stroke(LifeOSTokens.quietBorder, lineWidth: LifeOSTokens.Glass.strokeWidth))
            .shadow(
                color: reduceTransparency ? .clear : LifeOSTokens.Glass.shadowColor,
                radius: LifeOSTokens.Glass.shadowRadius,
                x: LifeOSTokens.Glass.shadowX,
                y: LifeOSTokens.Glass.shadowY
            )
            .contentShape(shape)
    }
}
