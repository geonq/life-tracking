import SwiftUI

#if os(macOS)
import AppKit
import CoreText
#else
import UIKit
#endif

// MARK: - Brand Typography
//
// Logo: Manrope (bold wordmark)
// Headers: Space Grotesk (section titles, large numbers, nav titles)
// Body / UI / data: Inter (default text, list rows, captions)
//
// All three are variable fonts. Each ships a handful of named weight
// instances (verified via the fvar/name tables — see project notes),
// and Core Text synthesizes a PostScript name of `<Family>-<Instance>`
// for named instances that don't carry an explicit postScriptNameID.
// The names below match what Core Text actually registers for these
// specific font files, not an assumed convention.

public enum LifeOSFont {

    // MARK: Manrope (logo / wordmark)

    public enum Manrope: String {
        case extraLight = "Manrope-ExtraLight"
        case light = "Manrope-Light"
        case regular = "Manrope-Regular"
        case medium = "Manrope-Medium"
        case semiBold = "Manrope-SemiBold"
        case bold = "Manrope-Bold"
        case extraBold = "Manrope-ExtraBold"
    }

    public static func manrope(_ size: CGFloat, weight: Manrope = .bold) -> Font {
        .custom(weight.rawValue, size: size)
    }

    /// The app wordmark/logo style.
    public static func logo(_ size: CGFloat = 28) -> Font {
        manrope(size, weight: .extraBold)
    }

    // MARK: Space Grotesk (headers, large numbers, section titles)
    //
    // This file's default named instance is "Light", so Core Text (lacking
    // an explicit postScriptNameID per instance in this font) synthesizes
    // PostScript names as "SpaceGrotesk-Light_<Instance>" for every instance
    // other than the default itself. Verified via CTFontCreateWithName at
    // runtime against the actual bundled .ttf — do not "clean up" these to
    // "SpaceGrotesk-Bold" etc., that name does not resolve in this font.

    public enum SpaceGrotesk: String {
        case light = "SpaceGrotesk-Light"
        case regular = "SpaceGrotesk-Light_Regular"
        case medium = "SpaceGrotesk-Light_Medium"
        case bold = "SpaceGrotesk-Light_Bold"
    }

    public static func spaceGrotesk(_ size: CGFloat, weight: SpaceGrotesk = .medium) -> Font {
        .custom(weight.rawValue, size: size)
    }

    /// Large page/section titles (e.g. "Life OS", "LLM usage").
    public static func headerLarge(_ size: CGFloat = 28) -> Font {
        spaceGrotesk(size, weight: .bold)
    }

    /// Standard section headers / card titles.
    public static func header(_ size: CGFloat = 16) -> Font {
        spaceGrotesk(size, weight: .medium)
    }

    // MARK: Inter (body, UI, data)
    //
    // Same Core Text synthesis behavior as Space Grotesk above: this file's
    // default named instance is "Regular", so every other weight resolves
    // as "Inter-Regular_<Instance>". Verified via CTFontCreateWithName
    // against the actual bundled .ttf.

    public enum Inter: String {
        case thin = "Inter-Regular_Thin"
        case extraLight = "Inter-Regular_ExtraLight"
        case light = "Inter-Regular_Light"
        case regular = "Inter-Regular"
        case medium = "Inter-Regular_Medium"
        case semiBold = "Inter-Regular_SemiBold"
        case bold = "Inter-Regular_Bold"
        case extraBold = "Inter-Regular_ExtraBold"
        case black = "Inter-Regular_Black"
    }

    public static func inter(_ size: CGFloat, weight: Inter = .regular) -> Font {
        .custom(weight.rawValue, size: size)
    }

    /// Default body text.
    public static func body(_ size: CGFloat = 13) -> Font {
        inter(size, weight: .regular)
    }

    /// Captions / secondary metadata text.
    public static func caption(_ size: CGFloat = 11) -> Font {
        inter(size, weight: .medium)
    }

    // MARK: Semantic role aliases
    //
    // These aliases preserve the registered font families above while giving
    // new surfaces a stable role vocabulary. `relativeTo` keeps the roles
    // responsive to Dynamic Type without changing existing call sites.

    private static func roleFont(
        _ name: String,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle
    ) -> Font {
        .custom(name, size: size, relativeTo: textStyle)
    }

    /// KPI/display value. Space Grotesk remains the display face.
    /// Quiet Machine §3: 40 iOS / 48 macOS, Bold, −0.3 tracking at call site,
    /// `.monospacedDigit()` mandatory.
    public static func kpi(_ size: CGFloat = {
#if os(macOS)
        48
#else
        40
#endif
    }()) -> Font {
        roleFont(SpaceGrotesk.bold.rawValue, size: size, relativeTo: .largeTitle)
            .monospacedDigit()
    }

    /// Screen titles ("Overview", "Fitness"). SG Bold 34 / 30; apply
    /// `.tracking(-0.5)` at the call site per §3.
    public static func display(_ size: CGFloat = {
#if os(macOS)
        30
#else
        34
#endif
    }()) -> Font {
        roleFont(SpaceGrotesk.bold.rawValue, size: size, relativeTo: .largeTitle)
    }

    /// Sheet and navigation headers. SG Medium 22 / 20; apply `.tracking(-0.2)`.
    public static func title(_ size: CGFloat = {
#if os(macOS)
        20
#else
        22
#endif
    }()) -> Font {
        roleFont(SpaceGrotesk.medium.rawValue, size: size, relativeTo: .title2)
    }

    /// Descriptions, secondary rows. Inter Regular 13 both platforms.
    public static func callout(_ size: CGFloat = 13) -> Font {
        roleFont(Inter.regular.rawValue, size: size, relativeTo: .subheadline)
    }

    /// Micro labels that replace tinted pills (§4.2). Inter SemiBold 10,
    /// +0.8 tracking, uppercase — apply `.tracking(0.8)` + `.textCase(.uppercase)`
    /// at the call site (Font cannot carry tracking).
    public static func overline(_ size: CGFloat = 10) -> Font {
        roleFont(Inter.semiBold.rawValue, size: size, relativeTo: .caption2)
    }

    /// Large page title.
    public static func pageTitle(_ size: CGFloat = {
#if os(macOS)
        28
#else
        32
#endif
    }()) -> Font {
        roleFont(SpaceGrotesk.bold.rawValue, size: size, relativeTo: .largeTitle)
    }

    /// Section heading.
    public static func sectionTitle(_ size: CGFloat = 20) -> Font {
        roleFont(SpaceGrotesk.medium.rawValue, size: size, relativeTo: .title2)
    }

    /// Card heading.
    public static func cardTitle(_ size: CGFloat = {
#if os(macOS)
        15
#else
        16
#endif
    }()) -> Font {
        roleFont(SpaceGrotesk.medium.rawValue, size: size, relativeTo: .headline)
    }

    /// Body copy.
    public static func bodyText(_ size: CGFloat = {
#if os(macOS)
        14
#else
        15
#endif
    }()) -> Font {
        roleFont(Inter.regular.rawValue, size: size, relativeTo: .body)
    }

    /// Control label.
    public static func control(_ size: CGFloat = 13) -> Font {
        roleFont(Inter.semiBold.rawValue, size: size, relativeTo: .subheadline)
    }

    /// Metadata and source labels.
    public static func metadata(_ size: CGFloat = 12) -> Font {
        roleFont(Inter.medium.rawValue, size: size, relativeTo: .caption)
    }

    /// Axis and micro labels.
    public static func axis(_ size: CGFloat = 11) -> Font {
        roleFont(Inter.medium.rawValue, size: size, relativeTo: .caption2)
    }
}

// MARK: - Runtime Font Registration
//
// iOS registers fonts declared under `UIAppFonts` in Info.plist
// automatically at process launch — no extra code needed there.
//
// macOS (AppKit/SwiftUI) does not auto-register bundled font files from
// an app's Resources directory the way iOS does; it must be done at
// launch via Core Text. This is safe to call multiple times (Core Text
// no-ops on already-registered URLs) and safe to call on iOS too, so a
// single call site works for both platforms without #if branching at
// the call site.

public enum LifeOSFontRegistrar {
    private static var didRegister = false

    /// Registers the bundled brand fonts with Core Text. Call once at
    /// app/widget launch, before any `Font.custom` usage renders.
    public static func registerBundledFonts() {
        guard !didRegister else { return }
        didRegister = true

        let names = [
            "Manrope-VariableFont_wght",
            "SpaceGrotesk-VariableFont_wght",
            "Inter-VariableFont",
        ]

        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                continue
            }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }
}
