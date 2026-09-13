import SwiftUI

/// Width-derived values shared by primary LifeOS surfaces. The values are
/// pure so column and viewport decisions can be unit-tested without
/// instantiating a view.
public struct LifeOSResponsiveMetrics: Equatable, Sendable {
    /// Compact controls remain appropriate below this width. This is
    /// independent from the two-column capability boundary.
    public static let compactBreakpoint: CGFloat = 600

    /// The usable content width at which a page may choose a two-column
    /// composition. Gutters and the sidebar are removed before this threshold
    /// is evaluated.
    public static let twoColumnBreakpoint: CGFloat = 720

    /// The Mac window width at which the page gutter grows from 24pt to 32pt.
    public static let wideMacGutterBreakpoint: CGFloat = 1_512

    /// The maximum width for a standard page frame. Keeping this in the
    /// shared metrics makes width decisions measurable without rendering a
    /// SwiftUI view.
    public static var standardPageMaxWidth: CGFloat { LifeOSTokens.contentMaxWidth }

    public let width: CGFloat
    public let sidebarWidth: CGFloat

    private static var nominalPageGutter: CGFloat { LifeOSTokens.pageGutter }

    public init(width: CGFloat, sidebarWidth: CGFloat = 0) {
        let requestedSidebar = sidebarWidth.isFinite ? max(0, sidebarWidth) : 0
        let normalizedWidth: CGFloat
        if width.isFinite {
            normalizedWidth = max(0, width)
        } else if width == .infinity {
            // An unbounded proposal still needs a finite, contract-sized
            // viewport so an ideal page frame can be measured safely.
            normalizedWidth = Self.standardPageMaxWidth
                + (Self.nominalPageGutter * 2)
                + requestedSidebar
        } else {
            normalizedWidth = 0
        }

        self.width = normalizedWidth
        self.sidebarWidth = min(requestedSidebar, normalizedWidth)
    }

    /// Width left after the sidebar, before page gutters.
    public var availableWidth: CGFloat {
        max(0, width - sidebarWidth)
    }

    public var isCompact: Bool { availableWidth < Self.compactBreakpoint }
    public var supportsTwoColumnLayout: Bool { contentWidth >= Self.twoColumnBreakpoint }

    public var nominalHorizontalGutter: CGFloat {
#if os(macOS)
        if width >= Self.wideMacGutterBreakpoint { return 32 }
#endif
        return LifeOSTokens.pageGutter
    }

    /// The rendered gutter is capped when an invalidly narrow proposal cannot
    /// physically hold both gutters. Normal iPhone/Mac widths retain the
    /// exact authored 16/24/32pt values.
    public var horizontalGutter: CGFloat {
        resolvedGutter(nominalHorizontalGutter)
    }

    public func resolvedGutter(_ requested: CGFloat) -> CGFloat {
        let safeRequested: CGFloat
        if requested.isFinite {
            safeRequested = max(0, requested)
        } else {
            safeRequested = requested == .infinity ? availableWidth / 2 : 0
        }
        return min(safeRequested, availableWidth / 2)
    }

    /// Width remaining after the outer page gutters. This is the width that
    /// screen composition may safely allocate to columns and controls.
    public var contentWidth: CGFloat {
        contentWidth(for: horizontalGutter)
    }

    public func contentWidth(for gutter: CGFloat) -> CGFloat {
        let safeGutter = resolvedGutter(gutter)
        return max(0, availableWidth - (safeGutter * 2))
    }

    public var sectionSpacing: CGFloat { LifeOSTokens.sectionGap }

    public var maxContentWidth: CGFloat {
        min(contentWidth, Self.standardPageMaxWidth)
    }

    public var maxChartWidth: CGFloat {
        min(contentWidth, LifeOSTokens.chartMaxWidth)
    }

    /// Pure metrics for the frame emitted by the responsive containers.
    public var contentOriginX: CGFloat { sidebarWidth + horizontalGutter }
    public var renderedContentWidth: CGFloat { maxContentWidth }
    public var renderedContentMaxX: CGFloat {
        min(width, contentOriginX + renderedContentWidth)
    }
    public var fitsWithinViewport: Bool {
        contentOriginX >= 0 && renderedContentMaxX <= width
    }
}

/// A geometry-aware container for new screen work. The outer frame is exactly
/// the proposed viewport; the child receives only the width left after the
/// optional sidebar and responsive gutters.
public struct LifeOSResponsiveContainer<Content: View>: View {
    private let sidebarWidth: CGFloat
    private let content: (LifeOSResponsiveMetrics) -> Content

    public init(
        sidebarWidth: CGFloat = 0,
        @ViewBuilder content: @escaping (LifeOSResponsiveMetrics) -> Content
    ) {
        self.sidebarWidth = sidebarWidth
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let metrics = LifeOSResponsiveMetrics(
                width: proxy.size.width,
                sidebarWidth: sidebarWidth
            )

            LifeOSResponsiveContentPayload(content: content(metrics))
                .frame(width: metrics.renderedContentWidth, alignment: .topLeading)
                .frame(width: metrics.contentWidth, alignment: .topLeading)
                .padding(.leading, metrics.horizontalGutter)
                .frame(width: metrics.availableWidth, alignment: .topLeading)
                .padding(.leading, metrics.sidebarWidth)
                .frame(width: metrics.width, alignment: .topLeading)
        }
    }
}

/// Keeps the complete result of a public `@ViewBuilder` invocation together
/// as one direct child of the custom layout. The payload may itself be a
/// `TupleView` or a `ForEach`; the explicit leading, zero-spacing `VStack`
/// owns that complete result so every builder child is measured and placed.
private struct LifeOSResponsiveContentPayload<Content: View>: View {
    let content: Content

    var body: some View {
        // `Content` can be a TupleView from sibling expressions or a ForEach
        // collection. Keep either expansion inside one layout-owning stack.
        VStack(alignment: .leading, spacing: 0) {
            content
        }
    }
}

/// Layout implementation for the existing page container. Keeping width
/// calculation in a Layout avoids a full-size GeometryReader inside a
/// vertical ScrollView and guarantees that padding cannot grow a child past
/// the viewport.
private struct LifeOSResponsiveContentLayout: Layout {
    let horizontalPadding: CGFloat?
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let maxReadableWidth: CGFloat?
    let sidebarWidth: CGFloat

    private func values(for width: CGFloat) -> (metrics: LifeOSResponsiveMetrics, gutter: CGFloat, childWidth: CGFloat) {
        let metrics = LifeOSResponsiveMetrics(width: width, sidebarWidth: sidebarWidth)
        let requestedGutter = horizontalPadding ?? metrics.horizontalGutter
        let gutter = metrics.resolvedGutter(requestedGutter)
        let availableAfterGutters = metrics.contentWidth(for: gutter)
        let readableLimit: CGFloat? = {
            guard let maxReadableWidth else { return nil }
            guard maxReadableWidth.isFinite else {
                return maxReadableWidth == .infinity
                    ? LifeOSResponsiveMetrics.standardPageMaxWidth
                    : 0
            }
            return max(0, maxReadableWidth)
        }()
        let childWidth = min(availableAfterGutters, readableLimit ?? .infinity)
        return (metrics, gutter, max(0, childWidth))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }

        let metrics = LifeOSResponsiveMetrics(
            width: proposal.width ?? .infinity,
            sidebarWidth: sidebarWidth
        )
        let layoutValues = values(for: metrics.width)
        let childSize = subview.sizeThatFits(
            ProposedViewSize(width: layoutValues.childWidth, height: nil)
        )
        let safeHeight = childSize.height.isFinite ? max(0, childSize.height) : 0

        let renderedWidth: CGFloat
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            renderedWidth = max(0, proposedWidth)
        } else {
            renderedWidth = layoutValues.metrics.sidebarWidth
                + (layoutValues.gutter * 2)
                + layoutValues.childWidth
        }

        return CGSize(
            width: renderedWidth,
            height: max(0, topPadding) + safeHeight + max(0, bottomPadding)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }

        let layoutValues = values(for: bounds.width)
        subview.place(
            at: CGPoint(
                x: bounds.minX + layoutValues.metrics.sidebarWidth + layoutValues.gutter,
                y: bounds.minY + max(0, topPadding)
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: layoutValues.childWidth, height: nil)
        )
    }
}

/// Shared page geometry for primary LifeOS surfaces.
///
/// Standard pages use the shared 1120-point content frame. A readable width
/// can still be requested for setup prose and other text-first screens, while
/// passing `nil` remains an explicit full-width escape hatch for viewport
/// surfaces such as Calendar.
public struct LifeOSResponsiveContentContainer<Content: View>: View {
    private let horizontalPadding: CGFloat?
    private let topPadding: CGFloat
    private let bottomPadding: CGFloat
    private let maxReadableWidth: CGFloat?
    private let sidebarWidth: CGFloat
    private let content: Content

    public init(
        horizontalPadding: CGFloat? = nil,
        topPadding: CGFloat = 0,
        bottomPadding: CGFloat = 0,
        maxReadableWidth: CGFloat? = LifeOSTokens.contentMaxWidth,
        sidebarWidth: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalPadding = horizontalPadding
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.maxReadableWidth = maxReadableWidth
        self.sidebarWidth = sidebarWidth
        self.content = content()
    }

    public var body: some View {
        AnyLayout(
            LifeOSResponsiveContentLayout(
                horizontalPadding: horizontalPadding,
                topPadding: topPadding,
                bottomPadding: bottomPadding,
                maxReadableWidth: maxReadableWidth,
                sidebarWidth: sidebarWidth
            )
        ) {
            LifeOSResponsiveContentPayload(content: content)
        }
    }
}
