import SwiftUI

// MARK: - Solid surfaces

public enum LifeOSSurfaceLevel: String, CaseIterable, Sendable {
    case surface
    case raised
    case floating

    fileprivate var fill: Color {
        switch self {
        case .surface: LifeOSTokens.surface
        case .raised: LifeOSTokens.raised
        case .floating: LifeOSTokens.floatingOverlay
        }
    }

    fileprivate var usesShadow: Bool {
        self == .floating
    }
}

/// The default data-card recipe: solid neutral fill, one quiet border and no
/// decorative material, lift or shadow.
public struct LifeOSCard<Content: View>: View {
    private let level: LifeOSSurfaceLevel
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    public init(
        level: LifeOSSurfaceLevel = .surface,
        cornerRadius: CGFloat = LifeOSTokens.Radius.card,
        padding: CGFloat = LifeOSTokens.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.level = level
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .padding(padding)
            .background(level.fill, in: shape)
            .overlay(shape.stroke(LifeOSTokens.subtleBorder, lineWidth: 0.5))
            .shadow(
                color: level.usesShadow ? Color.black.opacity(0.35) : .clear,
                radius: level.usesShadow ? 16 : 0,
                x: 0,
                y: level.usesShadow ? 12 : 0
            )
            .contentShape(shape)
    }
}

private struct LifeOSSurfaceModifier: ViewModifier {
    let level: LifeOSSurfaceLevel
    let cornerRadius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        LifeOSCard(level: level, cornerRadius: cornerRadius, padding: padding) {
            content
        }
    }
}

public extension View {
    /// Applies the same solid surface recipe as `LifeOSCard` to an existing
    /// view hierarchy.
    func lifeOSSurface(
        level: LifeOSSurfaceLevel = .surface,
        cornerRadius: CGFloat = LifeOSTokens.Radius.card,
        padding: CGFloat = LifeOSTokens.cardPadding
    ) -> some View {
        modifier(LifeOSSurfaceModifier(level: level, cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Icon button

private struct LifeOSIconButtonStyle: ButtonStyle {
    let tint: Color
    let targetSize: CGFloat
    let isHovered: Bool
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let reducedMotion = reduceMotion || requestedReduceMotion
        let state = LifeOSInteractionState.resolve(
            pressed: pressed,
            hovered: isHovered,
            focused: isFocused,
            reduceMotion: reducedMotion
        )
        let appearance = LifeOSInteractionAppearance.resolve(for: state)
        let shouldScale = !reducedMotion

        configuration.label
            .frame(width: targetSize, height: targetSize)
            .foregroundStyle(tint)
            .background(
                LifeOSTokens.raised.opacity(appearance.fillOpacity),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                    .stroke(
                        isFocused ? LifeOSTokens.accent : LifeOSTokens.subtleBorder,
                        lineWidth: isFocused ? 2 : 0.5
                    )
            }
            .opacity(appearance.contentOpacity)
            .scaleEffect(shouldScale && pressed ? 0.98 : 1)
            .animation(
                LifeOSMotion.curve(
                    for: pressed ? .press : .release,
                    reduceMotion: reducedMotion
                )?.animation,
                value: pressed
            )
    }
}

/// A compact icon-only control with platform-appropriate target sizing and
/// independent hover/focus/pressed states.
public struct LifeOSIconButton: View {
    private let systemName: String
    private let label: String
    private let tint: Color
    private let requestedSize: CGFloat?
    private let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    public init(
        systemName: String,
        accessibilityLabel: String,
        size: CGFloat? = nil,
        tint: Color = LifeOSTokens.primaryText,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.label = accessibilityLabel
        self.requestedSize = size
        self.tint = tint
        self.action = action
    }

    private var targetSize: CGFloat {
        max(requestedSize ?? LifeOSTokens.Control.iconButton, LifeOSTokens.Control.minimumTarget)
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(
            LifeOSIconButtonStyle(
                tint: tint,
                targetSize: targetSize,
                isHovered: isHovered,
                isFocused: isFocused
            )
        )
        .onHover { isHovered = $0 }
        .focused($isFocused)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Headers and metadata

public struct LifeOSSectionHeader: View {
    private let title: String
    private let subtitle: String?
    private let trailing: AnyView

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(EmptyView())
    }

    public init<Trailing: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(title)
                .lifeOSTypography(.sectionTitle)
                .foregroundStyle(LifeOSTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var horizontalLayout: some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.md) {
            titleBlock
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            Spacer(minLength: LifeOSTokens.Space.sm)
            trailing
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            titleBlock
            trailing
        }
    }

    @ViewBuilder
    private var responsiveLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedLayout
        } else {
            ViewThatFits(in: .horizontal) {
                horizontalLayout
                stackedLayout
            }
        }
    }

    public var body: some View {
        responsiveLayout
            .accessibilityElement(children: .contain)
    }
}

public struct LifeOSMetricHeader: View {
    private let label: String
    private let value: String?
    private let unit: String?
    private let detail: String?
    private let compact: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        label: String,
        value: String?,
        unit: String? = nil,
        detail: String? = nil,
        compact: Bool = false
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.detail = detail
        self.compact = compact
    }

    private var valueText: some View {
        Text(value ?? "—")
            .lifeOSTypography(compact ? .metricCompact : .metric)
            .foregroundStyle(LifeOSTokens.primaryText)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var unitText: some View {
        if let unit, !unit.isEmpty {
            Text(unit)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
    }

    private var inlineMetric: some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xxs) {
            valueText
                .fixedSize(horizontal: true, vertical: false)
            unitText
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var stackedMetric: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            valueText
                .fixedSize(horizontal: false, vertical: true)
            unitText
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var responsiveMetric: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedMetric
        } else {
            ViewThatFits(in: .horizontal) {
                inlineMetric
                stackedMetric
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            responsiveMetric

            if let detail, !detail.isEmpty {
                Text(detail)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

public enum LifeOSStatusTone: String, CaseIterable, Sendable {
    case neutral
    case info
    case success
    case warning
    case danger
    case demo

    fileprivate var foreground: Color {
        switch self {
        case .neutral: LifeOSTokens.secondaryText
        case .info: LifeOSTokens.info
        case .success: LifeOSTokens.success
        case .warning, .demo: LifeOSTokens.warning
        case .danger: LifeOSTokens.danger
        }
    }

    fileprivate var background: Color {
        foreground.opacity(self == .neutral ? 0.08 : 0.14)
    }
}

public struct LifeOSStatusPill: View {
    private let label: String
    private let tone: LifeOSStatusTone
    private let systemImage: String?

    public init(
        label: String,
        tone: LifeOSStatusTone = .neutral,
        systemImage: String? = nil
    ) {
        self.label = label
        self.tone = tone
        self.systemImage = systemImage
    }

    public var body: some View {
        // Quiet Machine §4.2: semantic dot + overline text. No tinted
        // capsule, no stroke — pills are for true status selectors only.
        HStack(spacing: LifeOSTokens.Space.xxs) {
            Circle()
                .fill(tone.foreground)
                .frame(width: 6, height: 6)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(label)
                .lifeOSTypography(.label)
                .tracking(0.8)
                .textCase(.uppercase)
        }
        .foregroundStyle(tone.foreground)
        .accessibilityElement(children: .combine)
    }
}

public struct LifeOSMetadataItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String? = nil, label: String, value: String) {
        self.id = id ?? "\(label)·\(value)"
        self.label = label
        self.value = value
    }
}

public struct LifeOSMetadataRow: View {
    private let items: [LifeOSMetadataItem]

    public init(items: [LifeOSMetadataItem]) {
        self.items = items
    }

    public init(_ items: LifeOSMetadataItem...) {
        self.items = items
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.md) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                    Text(item.label)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.metadataText)
                    Text(item.value)
                        .lifeOSTypography(.button)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Provenance and truthful states

public enum LifeOSProvenanceKind: String, CaseIterable, Sendable {
    case observed
    case stale
    case estimated
    case partial
    case demo
    case unavailable

    public var label: String {
        switch self {
        case .observed: "Observed"
        case .stale: "Stale"
        case .estimated: "Estimated"
        case .partial: "Partial"
        case .demo: "DEMO · NOT LIVE"
        case .unavailable: "Unavailable"
        }
    }

    fileprivate var tone: LifeOSStatusTone {
        switch self {
        case .observed: .success
        case .stale, .estimated, .partial: .warning
        case .demo: .demo
        case .unavailable: .neutral
        }
    }
}

public struct LifeOSProvenanceNotice: View {
    private let kind: LifeOSProvenanceKind
    private let source: String?
    private let observedAt: Date?
    private let detail: String?

    public init(
        kind: LifeOSProvenanceKind,
        source: String? = nil,
        observedAt: Date? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.source = source
        self.observedAt = observedAt
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .top, spacing: LifeOSTokens.Space.xs) {
            Image(systemName: kind == .observed ? "checkmark.circle" : "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.tone.foreground)

            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text(kind.label)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(kind.tone.foreground)

                if let source, !source.isEmpty {
                    Text(source)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }

                if let observedAt {
                    Text("Observed \(observedAt.formatted(date: .abbreviated, time: .shortened))")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.metadataText)
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

public typealias LifeOSHonestyNotice = LifeOSProvenanceNotice

public enum LifeOSContentState: Equatable, Sendable {
    case loading
    case empty(reason: String)
    case stale(detail: String?)
    case error(message: String)
    case demo(detail: String?)
    case unavailable(reason: String)
    case partial(detail: String)

    fileprivate var title: String {
        switch self {
        case .loading: "Loading"
        case .empty: "No data"
        case .stale: "Stale data"
        case .error: "Could not load"
        case .demo: "Demo data"
        case .unavailable: "Unavailable"
        case .partial: "Partial data"
        }
    }

    fileprivate var message: String {
        switch self {
        case .loading: "Preparing this surface."
        case .empty(let reason): reason
        case .stale(let detail): detail ?? "The last observed value is retained until a fresh source observation is available."
        case .error(let message): message
        case .demo(let detail): detail ?? "DEMO · NOT LIVE"
        case .unavailable(let reason): reason
        case .partial(let detail): detail
        }
    }

    fileprivate var iconName: String {
        switch self {
        case .loading: "rectangle.3.group"
        case .empty: "tray"
        case .stale: "clock.arrow.circlepath"
        case .error: "exclamationmark.triangle"
        case .demo: "theatermasks"
        case .unavailable: "questionmark.circle"
        case .partial: "circle.lefthalf.filled"
        }
    }

    fileprivate var tone: LifeOSStatusTone {
        switch self {
        case .loading, .empty, .unavailable: .neutral
        case .stale, .demo, .partial: .warning
        case .error: .danger
        }
    }
}

/// A compact, truthful state surface. Loading is represented by a native
/// progress indicator rather than a delayed skeleton, so there is no timer,
/// shimmer, or fake chart geometry to reconcile.
public struct LifeOSStateView: View {
    private let state: LifeOSContentState
    private let retry: (() -> Void)?

    public init(state: LifeOSContentState, retry: (() -> Void)? = nil) {
        self.state = state
        self.retry = retry
    }

    public var body: some View {
        Group {
            if case .loading = state {
                HStack(spacing: LifeOSTokens.Space.xs) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LifeOSTokens.accent)
                    Text(state.title)
                        .lifeOSTypography(.cardTitle)
                        .foregroundStyle(LifeOSTokens.primaryText)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                    HStack(spacing: LifeOSTokens.Space.xs) {
                        Image(systemName: state.iconName)
                            .foregroundStyle(state.tone.foreground)
                        Text(state.title)
                            .lifeOSTypography(.cardTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                    }

                    Text(state.message)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .demo = state {
                        LifeOSStatusPill(label: "DEMO · NOT LIVE", tone: .demo)
                    }

                    if let retry {
                        Button("Try again", action: retry)
                            .lifeOSTypography(.button)
                            .foregroundStyle(LifeOSTokens.accent)
                            .frame(minHeight: LifeOSTokens.Control.minimumTarget)
                    }
                }
            }
        }
        .padding(.vertical, LifeOSTokens.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
