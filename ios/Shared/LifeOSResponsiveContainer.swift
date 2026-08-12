import SwiftUI

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
        horizontalPadding: CGFloat = LifeOSTokens.pagePadding,
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
