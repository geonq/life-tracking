import SwiftUI

// MARK: - Branded Color Palette

public extension Color {
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
    /// Deep dark blue canvas #000306.
    static let lifeOSDarkCanvas = Color(red: 0x00/255, green: 0x03/255, blue: 0x06/255)
    /// White with a super subtle blue tint #F0F6FF.
    static let lifeOSLightCanvas = Color(red: 0xF0/255, green: 0xF6/255, blue: 0xFF/255)
}

// MARK: - Design Tokens

public enum LifeOSTokens {
    public static let pagePadding: CGFloat = 20
    public static let grid: CGFloat = 4
    public static let spacing: CGFloat = grid * 3
    public static let corner: CGFloat = 12
    public static let smallCorner: CGFloat = 8
    public static let cardPadding: CGFloat = 16
    public static let iconFrame: CGFloat = 32
    public static let overviewContentInset: CGFloat = 40
    public static let overviewCardHeight: CGFloat = 80
    public static let overviewCardGap: CGFloat = 10
    public static let overviewCardCorner: CGFloat = 12
    public static let overviewIconTile: CGFloat = 36

    // MARK: Canvas & Surface (theme-aware)

#if os(macOS)
    public static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x00/255, green: 0x03/255, blue: 0x06/255, alpha: 1)
            : NSColor(srgbRed: 0xF0/255, green: 0xF6/255, blue: 0xFF/255, alpha: 1)
    })
    public static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x0B/255, green: 0x0E/255, blue: 0x13/255, alpha: 1)
            : .white
    })
#else
    public static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x00/255, green: 0x03/255, blue: 0x06/255, alpha: 1)
            : UIColor(red: 0xF0/255, green: 0xF6/255, blue: 0xFF/255, alpha: 1)
    })
    public static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x0B/255, green: 0x0E/255, blue: 0x13/255, alpha: 1)
            : .white
    })
#endif

    public static let darkCanvas = Color.lifeOSDarkCanvas
    public static let lightCanvas = Color.lifeOSLightCanvas

    // Exact branded light/dark canvas, selected by the platform appearance.
    public static var screenCanvas: Color { canvas }

    // MARK: Semantic Colors

    /// Used only for focus and primary data, never as structural chrome.
    public static let accent = Color.lifeOSBlue600
    public static let accentHover = Color.lifeOSBlue700
    public static let accentPressed = Color.lifeOSBlue800
    public static let accentLight = Color.lifeOSBlue50

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
        public static let actual = Color.lifeOSBlue500
        /// Target pace — green, dashed.
        public static let target = Color.lifeOSGreen500
        /// Current estimate — vivid orange, dashed.
        public static let estimate = Color.lifeOSOrange500
        /// Past estimate / account history — grey, dotted.
        public static let history = LifeOSTokens.tertiaryText
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

    // MARK: Provider identity
    // interim: full blue-lead + segment redesign is workstream 3 per 02-charts-rings-widgets.md
    // Providers are distinguished by label + segment, not loud per-provider hue; both are
    // drawn from the vivid palette (Usage view specifics, 01-color-system-v2.md).
    public static func providerColor(_ provider: Provider) -> Color {
        switch provider {
        case .codex: .lifeOSBlue500
        case .claude: .lifeOSTeal500
        // Provider identity stays restrained; labels and the switcher carry the
        // distinction while these tokens remain available to future accents.
        case .glm: .lifeOSBlue400
        case .deepseek: .lifeOSBlue600
        case .googleAIStudio: .lifeOSTeal400
        }
    }

    // Borders & quiescent states
    public static let quietBorder = Color.primary.opacity(0.11)
    public static let hairlineBorder = Color.primary.opacity(0.07)
    public static let chartGrid = Color.primary.opacity(0.075)
    public static let tertiaryText = Color.secondary.opacity(0.72)

    // Card visual styling
    public static let cardShadowRadius: CGFloat = 0
    public static let cardShadowX: CGFloat = 0
    public static let cardShadowY: CGFloat = 0

    // MARK: Convenience Shapes

    public static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    public static var smallCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: smallCorner, style: .continuous)
    }

    public static var pillShape: Capsule {
        Capsule()
    }
}

// MARK: - Motion (Reduce Motion aware)

public enum LifeOSMotion {
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
}

private struct LifeOSCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(LifeOSTokens.cardPadding)
            .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
            .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif
