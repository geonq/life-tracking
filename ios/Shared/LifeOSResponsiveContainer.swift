import SwiftUI

/// Width-derived values shared by future screen migrations. The values are
/// pure so layout decisions can be unit-tested without instantiating a view.
public struct LifeOSResponsiveMetrics: Equatable, Sendable {
    /// Compact controls remain appropriate below this width. This is
    /// independent from the two-column capability boundary.
    public static let compactBreakpoint: CGFloat = 600

    /// The usable content width at which a page may choose a two-column
    /// composition. Gutters are removed before this threshold is evaluated.
    public static let twoColumnBreakpoint: CGFloat = 720

    /// The maximum width for a standard page frame. Keeping this in the
    /// shared metrics makes width decisions measurable without rendering a
    /// SwiftUI view.
    public static var standardPageMaxWidth: CGFloat { LifeOSTokens.contentMaxWidth }

    public let width: CGFloat

    public init(width: CGFloat) {
        if width.isFinite {
            self.width = max(0, width)
        } else if width == .infinity {
            self.width = Self.standardPageMaxWidth
        } else {
            self.width = 0
        }
    }

    public var isCompact: Bool { width < Self.compactBreakpoint }
    public var supportsTwoColumnLayout: Bool { contentWidth >= Self.twoColumnBreakpoint }

    public var horizontalGutter: CGFloat {
#if os(macOS)
        if width >= 1_512 { return 32 }
#endif
        return LifeOSTokens.pageGutter
    }

    /// Width remaining after the outer page gutters. This is the width that
    /// screen composition may safely allocate to columns and controls.
    public var contentWidth: CGFloat {
        max(0, width - (horizontalGutter * 2))
    }

    public var sectionSpacing: CGFloat { LifeOSTokens.sectionGap }

    public var maxContentWidth: CGFloat {
        min(contentWidth, Self.standardPageMaxWidth)
    }

    public var maxChartWidth: CGFloat {
        min(contentWidth, LifeOSTokens.chartMaxWidth)
    }
}

/// A geometry-aware container for new screen work. Existing callers should
/// continue using `LifeOSResponsiveContentContainer`; this type adds the
/// metrics contract without changing any existing screen API.
public struct LifeOSResponsiveContainer<Content: View>: View {
    private let content: (LifeOSResponsiveMetrics) -> Content

    public init(
        @ViewBuilder content: @escaping (LifeOSResponsiveMetrics) -> Content
    ) {
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let metrics = LifeOSResponsiveMetrics(width: proxy.size.width)
            content(metrics)
                .frame(maxWidth: metrics.maxContentWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, metrics.horizontalGutter)
        }
    }
}

/// Shared page geometry for primary LifeOS surfaces.
///
/// Standard pages use the shared 1120-point content frame. A readable width
/// can still be requested for setup prose and other text-first screens, while
/// passing `nil` remains an explicit full-width escape hatch for viewport
/// surfaces such as Calendar.
public struct LifeOSResponsiveContentContainer<Content: View>: View {
    private let horizontalPadding: CGFloat
    private let topPadding: CGFloat
    private let bottomPadding: CGFloat
    private let maxReadableWidth: CGFloat?
    private let content: Content

    public init(
        horizontalPadding: CGFloat = LifeOSTokens.pageGutter,
        topPadding: CGFloat = 0,
        bottomPadding: CGFloat = 0,
        // `nil` remains the explicit escape hatch for viewport surfaces that
        // must consume the full proposal. Standard page callers are capped by
        // the shared 1120-point contract by default.
        maxReadableWidth: CGFloat? = LifeOSTokens.contentMaxWidth,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalPadding = horizontalPadding
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.maxReadableWidth = maxReadableWidth
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: effectiveMaxReadableWidth ?? .infinity, alignment: .topLeading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var effectiveMaxReadableWidth: CGFloat? {
        guard let maxReadableWidth else { return nil }
        guard maxReadableWidth.isFinite else {
            return maxReadableWidth == .infinity
                ? LifeOSResponsiveMetrics.standardPageMaxWidth
                : 0
        }
        return max(0, maxReadableWidth)
    }
}
