import SwiftUI

public enum LifeOSTokens {
    public static let pagePadding: CGFloat = 20
    public static let grid: CGFloat = 4
    public static let spacing: CGFloat = grid * 3
    public static let corner: CGFloat = 16
#if os(macOS)
    public static let canvas = Color(nsColor: .windowBackgroundColor)
    public static let surface = Color(nsColor: .controlBackgroundColor)
#else
    public static let canvas = Color(.systemGroupedBackground)
    public static let surface = Color(.secondarySystemGroupedBackground)
#endif
    public static let quietBorder = Color.primary.opacity(0.10)
    public static let accent = Color.indigo
    public static let success = Color.green
    public static let warning = Color.orange
    public static let danger = Color.red
}
