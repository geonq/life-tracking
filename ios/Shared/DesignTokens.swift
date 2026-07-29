import SwiftUI

// MARK: - Branded Color Palette

public extension Color {
    /// Black #000000
    static let lifeOSBlack = Color(red: 0x00/255, green: 0x00/255, blue: 0x00/255)
    /// White #FFFFFF
    static let lifeOSWhite = Color(red: 0xFF/255, green: 0xFF/255, blue: 0xFF/255)

    // Blue scale
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

    // Brand canvases
    /// Dark canvas #00060A
    static let lifeOSDarkCanvas = Color(red: 0x00/255, green: 0x06/255, blue: 0x0A/255)
    /// Light canvas #F0F6FF
    static let lifeOSLightCanvas = Color(red: 0xF0/255, green: 0xF6/255, blue: 0xFF/255)
}

// MARK: - Design Tokens

public enum LifeOSTokens {
    public static let pagePadding: CGFloat = 20
    public static let grid: CGFloat = 4
    public static let spacing: CGFloat = grid * 3
    public static let corner: CGFloat = 16
    public static let smallCorner: CGFloat = 10
    public static let cardPadding: CGFloat = 16
    public static let iconFrame: CGFloat = 32

    // MARK: Canvas & Surface (theme-aware)

#if os(macOS)
    public static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x00/255, green: 0x06/255, blue: 0x0A/255, alpha: 1)
            : NSColor(srgbRed: 0xF0/255, green: 0xF6/255, blue: 0xFF/255, alpha: 1)
    })
    public static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x00/255, green: 0x0B/255, blue: 0x19/255, alpha: 1)
            : .white
    })
#else
    public static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x00/255, green: 0x06/255, blue: 0x0A/255, alpha: 1)
            : UIColor(red: 0xF0/255, green: 0xF6/255, blue: 0xFF/255, alpha: 1)
    })
    public static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x00/255, green: 0x0B/255, blue: 0x19/255, alpha: 1)
            : .white
    })
#endif

    public static let darkCanvas = Color.lifeOSDarkCanvas
    public static let lightCanvas = Color.lifeOSLightCanvas

    // Exact branded light/dark canvas, selected by the platform appearance.
    public static var screenCanvas: Color { canvas }

    // MARK: Semantic Colors

    /// Main brand accent — #0253C4
    public static let accent = Color.lifeOSBlue600
    public static let accentHover = Color.lifeOSBlue700
    public static let accentPressed = Color.lifeOSBlue800
    public static let accentLight = Color.lifeOSBlue50

    public static let success = Color(red: 0x16/255, green: 0xA3/255, blue: 0x4A/255)
    public static let warning = Color(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255)
    public static let danger  = Color(red: 0xDC/255, green: 0x26/255, blue: 0x26/255)

    // Borders & quiescent states
    public static let quietBorder = Color.lifeOSBlue600.opacity(0.12)
    public static let hairlineBorder = Color.primary.opacity(0.06)

    // Card visual styling
    public static let cardShadowRadius: CGFloat = 3
    public static let cardShadowX: CGFloat = 0
    public static let cardShadowY: CGFloat = 2

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
    /// Standard spring — callers omit it entirely when Reduce Motion is enabled.
    public static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    /// Snappier spring for small UI elements.
    public static let springSnappy = Animation.spring(response: 0.25, dampingFraction: 0.85)

    /// Smooth ease for opacity and offset transitions.
    public static let ease = Animation.easeInOut(duration: 0.2)

    /// Slightly longer ease for push/navigation.
    public static let easeNavigate = Animation.easeInOut(duration: 0.25)

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
    /// Apply a branded card background: surface fill, subtle border, soft shadow.
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

    /// Branded icon container: rounded-square tinted background behind an SF Symbol.
    func lifeOSIconBadge(systemName: String, size: CGFloat = LifeOSTokens.iconFrame) -> some View {
        self.overlay {
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(LifeOSTokens.accent)
                .frame(width: size, height: size)
                .background(LifeOSTokens.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct LifeOSCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(LifeOSTokens.cardPadding)
            .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
            .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 1))
            .shadow(color: Color.lifeOSBlue950.opacity(0.08),
                    radius: LifeOSTokens.cardShadowRadius,
                    x: LifeOSTokens.cardShadowX,
                    y: LifeOSTokens.cardShadowY)
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif
