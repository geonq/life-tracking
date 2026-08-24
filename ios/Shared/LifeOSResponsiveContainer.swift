import SwiftUI

/// Width-derived values shared by future screen migrations. The values are
/// pure so layout decisions can be unit-tested without instantiating a view.
public struct LifeOSResponsiveMetrics: Equatable, Sendable {
    public let width: CGFloat

    public init(width: CGFloat) {
        self.width = max(0, width)
    }

    public var isCompact: Bool { width < 600 }
    public var supportsTwoColumnLayout: Bool { width >= 600 }

    public var horizontalGutter: CGFloat {
        if width >= 1_512 { return 32 }
        if width >= 900 { return 24 }
        return 16
    }

    public var sectionSpacing: CGFloat {
        width >= 900 ? LifeOSTokens.Space.xxxl : LifeOSTokens.Space.xxl
    }

    public var maxContentWidth: CGFloat {
        min(width, LifeOSTokens.contentMaxWidth)
    }

    public var maxChartWidth: CGFloat {
        min(width, LifeOSTokens.chartMaxWidth)
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
/// Desktop dashboards should consume the available detail column. A readable
/// width can still be requested for setup prose and other text-first screens,
/// but it is never an accidental cap on a dashboard background or card grid.
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
        maxReadableWidth: CGFloat? = nil,
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
            .frame(maxWidth: maxReadableWidth ?? .infinity, alignment: .topLeading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
