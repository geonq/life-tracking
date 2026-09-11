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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

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
        let hairlineWidth = displayScale.isFinite && displayScale > 0 ? 1 / displayScale : 1
        let shadowOpacity = colorScheme == .dark ? 0.35 : 0.18

        content
            .padding(padding)
            .background(level.fill, in: shape)
            .overlay(shape.stroke(LifeOSTokens.subtleBorder, lineWidth: hairlineWidth))
            .shadow(
                color: level.usesShadow ? Color.black.opacity(shadowOpacity) : .clear,
                radius: level.usesShadow ? 32 : 0,
                x: 0,
                y: level.usesShadow ? 12 : 0
            )
            .contentShape(shape)
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
        configuration.label
            .frame(width: targetSize, height: targetSize)
            .foregroundStyle(tint)
            .background(
                LifeOSTokens.primaryText.opacity(appearance.fillOpacity),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                    .stroke(
                        isFocused ? LifeOSTokens.focusStroke : LifeOSTokens.essentialBorder,
                        lineWidth: isFocused ? 2 : 1
                    )
                    .opacity(isFocused ? 1 : max(0.45, appearance.borderOpacity))
                    .padding(isFocused ? -3 : 0)
            }
            .opacity(appearance.contentOpacity)
            .animation(
                LifeOSMotion.curve(
                    for: pressed ? .press : .release,
                    reduceMotion: reducedMotion
                )?.animation,
                value: pressed
            )
            .animation(
                LifeOSMotion.curve(
                    for: .hover,
                    reduceMotion: reducedMotion
                )?.animation,
                value: isHovered
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

    /// Uses the shared semantic icon catalog while retaining the string-based
    /// initializer for existing controls that are not yet migrated.
    public init(
        icon: LifeOSIconName,
        accessibilityLabel: String? = nil,
        size: CGFloat? = nil,
        tint: Color = LifeOSTokens.primaryText,
        action: @escaping () -> Void
    ) {
        self.init(
            systemName: icon.systemImageName,
            accessibilityLabel: accessibilityLabel ?? icon.accessibilityLabel,
            size: size,
            tint: tint,
            action: action
        )
    }

    private var targetSize: CGFloat {
        LifeOSHitTarget.resolve(requestedSize ?? LifeOSTokens.Control.iconButton)
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: LifeOSTokens.Icon.glyph, weight: .medium, design: .default))
                .frame(width: LifeOSTokens.Icon.box, height: LifeOSTokens.Icon.box)
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
        .contentShape(Rectangle())
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Canonical button

/// A single-action button recipe. The label is kept outside the style so a
/// busy state can reserve the same 16pt leading slot as an icon and avoid
/// shifting the action text while a write is in flight.
public struct LifeOSButton: View {
    public enum Variant: Equatable {
        case primary
        case secondary
        case tertiary
        case destructive

        fileprivate var styleVariant: LifeOSButtonStyle.Variant {
            switch self {
            case .primary: .primary
            case .secondary: .secondary
            case .tertiary: .tertiary
            case .destructive: .destructive
            }
        }
    }

    private let title: String
    private let variant: Variant
    private let systemImage: String?
    private let isEnabled: Bool
    private let isBusy: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        variant: Variant = .secondary,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: LifeOSTokens.Space.xs) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LifeOSTokens.disabledForeground)
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 15, weight: .medium, design: .default))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 16)

                Text(title)
                    .lifeOSTypography(.button)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: LifeOSTokens.Control.minimumTarget)
        }
        .buttonStyle(LifeOSButtonStyle(variant.styleVariant))
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(Text(title))
        .accessibilityValue(isBusy ? Text("In progress") : Text(""))
    }
}

// MARK: - Selector

public struct LifeOSSelectorOption<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public let isEnabled: Bool
    public let unavailableReason: String?

    public init(
        id: ID,
        title: String,
        isEnabled: Bool = true,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.unavailableReason = unavailableReason
    }
}

private struct LifeOSSelectorAvailableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LifeOSSelectorMeasuredWidthsKey: PreferenceKey {
    static var defaultValue: [CGFloat] = []

    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
        value.append(contentsOf: nextValue())
    }
}

enum LifeOSSelectorLayout {
    static let minimumCellWidth: CGFloat = 64

    static func usesMenu(
        availableWidth: CGFloat,
        intrinsicPillWidth: CGFloat,
        accessibilitySize: Bool = false
    ) -> Bool {
        guard availableWidth.isFinite, intrinsicPillWidth.isFinite else { return true }
        return accessibilitySize || intrinsicPillWidth > max(0, availableWidth)
    }
}

/// A selector that keeps the pill treatment when all labels fit and falls
/// back to a labeled menu before the row can clip or become horizontally
/// scrollable. Each option owns at most one action.
public struct LifeOSSelector<ID: Hashable>: View {
    private let options: [LifeOSSelectorOption<ID>]
    @Binding private var selection: ID

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var hoveredOption: ID?
    @State private var availableWidth: CGFloat = 0
    @State private var measuredIntrinsicPillWidth: CGFloat = 0
    @FocusState private var focusedOption: ID?
    @ScaledMetric(relativeTo: .headline) private var selectorTextSize: CGFloat = 15

    public init(
        options: [LifeOSSelectorOption<ID>],
        selection: Binding<ID>
    ) {
        self.options = options
        self._selection = selection
    }

    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }

    private var selectedOption: LifeOSSelectorOption<ID>? {
        options.first { $0.id == selection }
    }

    private func select(_ option: LifeOSSelectorOption<ID>) {
        guard option.isEnabled, option.id != selection else { return }
        if reduceMotion {
            LifeOSMotion.withoutAnimation { selection = option.id }
        } else {
            selection = option.id
        }
    }

    private var intrinsicPillWidth: CGFloat {
        let cellWidths = options.map { option in
            max(
                LifeOSSelectorLayout.minimumCellWidth,
                CGFloat(option.title.count) * selectorTextSize * 0.62 + LifeOSTokens.Space.xl
            )
        }
        let gap = CGFloat(max(0, options.count - 1)) * LifeOSTokens.Space.xxs
        return cellWidths.reduce(0, +) + gap
    }

    /// Measures the actual system font once per layout pass. The fallback
    /// estimate only covers the first pass before the preference arrives;
    /// `ViewThatFits` remains the final guard against a narrow proposal.
    private var intrinsicMeasurement: some View {
        HStack(spacing: LifeOSTokens.Space.xxs) {
            ForEach(options) { option in
                Text(option.title)
                    .lifeOSTypography(.button)
                    .padding(.horizontal, LifeOSTokens.Space.sm)
                    .frame(minWidth: LifeOSSelectorLayout.minimumCellWidth)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: LifeOSSelectorMeasuredWidthsKey.self,
                                value: [proxy.size.width]
                            )
                        }
                    }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var shouldUseMenu: Bool {
        let measuredWidth = measuredIntrinsicPillWidth > 0
            ? measuredIntrinsicPillWidth
            : intrinsicPillWidth
        return LifeOSSelectorLayout.usesMenu(
            availableWidth: availableWidth > 0 ? availableWidth : measuredWidth,
            intrinsicPillWidth: measuredWidth,
            accessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    private var pillRow: some View {
        HStack(spacing: LifeOSTokens.Space.xxs) {
            ForEach(options) { option in
                Button {
                    select(option)
                } label: {
                    Text(option.title)
                        .lifeOSTypography(.button)
                        .foregroundStyle(
                            option.isEnabled
                                ? (option.id == selection ? LifeOSTokens.primaryText : LifeOSTokens.secondaryText)
                                : LifeOSTokens.disabledForeground
                        )
                        .padding(.horizontal, LifeOSTokens.Space.sm)
                        .frame(
                            minWidth: LifeOSSelectorLayout.minimumCellWidth,
                            maxWidth: .infinity,
                            minHeight: LifeOSTokens.Control.standardHeight
                        )
                        .background { optionBackground(for: option) }
                        .overlay {
                            if focusedOption == option.id {
                                RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                                    .stroke(LifeOSTokens.focusStroke, lineWidth: 2)
                                    .padding(-3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!option.isEnabled)
                .focused($focusedOption, equals: option.id)
                .onHover { isInside in
                    if isInside {
                        hoveredOption = option.id
                    } else if hoveredOption == option.id {
                        hoveredOption = nil
                    }
                }
                .accessibilityAddTraits(option.id == selection ? .isSelected : [])
                .accessibilityHint(option.unavailableReason.map { Text($0) } ?? Text(""))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func optionBackground(for option: LifeOSSelectorOption<ID>) -> some View {
        let isSelected = option.id == selection
        let isHovered = hoveredOption == option.id
        let fillOpacity: Double = isSelected ? 0.08 : (isHovered ? 0.05 : 0)
        let fill = option.isEnabled
            ? LifeOSTokens.primaryText.opacity(fillOpacity)
            : LifeOSTokens.disabledFill
        let shape = RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)

        return shape
            .fill(fill)
            .overlay {
                if option.isEnabled && isSelected {
                    shape.stroke(LifeOSTokens.essentialBorder, lineWidth: 1)
                }
            }
            // Only the highlight surface animates. The option label and its
            // measured geometry remain stationary during selection.
            .animation(reduceMotion ? nil : LifeOSMotion.selector, value: isSelected)
            .animation(reduceMotion ? nil : LifeOSMotion.hover, value: isHovered)
    }

    private var menu: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    select(option)
                } label: {
                    Text(option.unavailableReason.map { "\(option.title) · \($0)" } ?? option.title)
                }
                .disabled(!option.isEnabled)
                .accessibilityHint(option.unavailableReason.map { Text($0) } ?? Text(""))
            }
        } label: {
            HStack(spacing: LifeOSTokens.Space.xs) {
                Text(selectedOption?.title ?? "Select")
                    .lifeOSTypography(.button)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LifeOSTokens.Space.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: .medium, design: .default))
            }
            .padding(.horizontal, LifeOSTokens.Space.sm)
            .frame(minWidth: LifeOSSelectorLayout.minimumCellWidth, minHeight: LifeOSTokens.Control.standardHeight)
            .background(
                LifeOSTokens.primaryText.opacity(0.06),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                    .stroke(LifeOSTokens.essentialBorder, lineWidth: 1)
            }
        }
        .accessibilityLabel(Text("Select option"))
    }

    public var body: some View {
        Group {
            if shouldUseMenu {
                menu
            } else {
                ViewThatFits(in: .horizontal) {
                    pillRow
                    menu
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: LifeOSSelectorAvailableWidthKey.self, value: proxy.size.width)
            }
        }
        .background(intrinsicMeasurement)
        .onPreferenceChange(LifeOSSelectorAvailableWidthKey.self) { width in
            guard width.isFinite, width > 0, abs(width - availableWidth) > 0.5 else { return }
            availableWidth = width
        }
        .onPreferenceChange(LifeOSSelectorMeasuredWidthsKey.self) { widths in
            let validWidths = widths.filter({ $0.isFinite && $0 > 0 })
            guard !validWidths.isEmpty else { return }
            let gap = CGFloat(max(0, options.count - 1)) * LifeOSTokens.Space.xxs
            let measured = validWidths.reduce(0, +) + gap
            guard measured.isFinite, abs(measured - measuredIntrinsicPillWidth) > 0.5 else { return }
            measuredIntrinsicPillWidth = measured
        }
        .frame(minHeight: LifeOSTokens.Control.standardHeight)
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
        case .success: LifeOSTokens.successText
        case .warning, .demo: LifeOSTokens.warningText
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
        case .stale, .partial: .warning
        case .estimated: .success
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
    case redacted(reason: String)

    fileprivate var title: String {
        switch self {
        case .loading: "Loading"
        case .empty: "No data"
        case .stale: "Stale data"
        case .error: "Could not load"
        case .demo: "Demo data"
        case .unavailable: "Unavailable"
        case .partial: "Partial data"
        case .redacted: "Hidden"
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
        case .redacted(let reason): reason
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
        case .redacted: "lock"
        }
    }

    fileprivate var tone: LifeOSStatusTone {
        switch self {
        case .loading, .empty, .unavailable: .neutral
        case .stale, .demo, .partial: .warning
        case .error: .danger
        case .redacted: .neutral
        }
    }
}

// MARK: - Canonical status row

/// A compact state row that keeps the cause and its one valid recovery action
/// together without turning the whole row into a button. It is safe to place
/// inside a card or above retained content; it never creates chart geometry.
public struct LifeOSStatusRow: View {
    private let state: LifeOSContentState
    private let observedAt: Date?
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        state: LifeOSContentState,
        observedAt: Date? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.state = state
        self.observedAt = observedAt
        self.actionTitle = actionTitle ?? (action == nil ? nil : "Try again")
        self.action = action
    }

    private var messageBlock: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.labelHelperGap) {
            Text(state.title)
                .lifeOSTypography(.cardTitle)
                .foregroundStyle(LifeOSTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(state.message)
                .lifeOSTypography(.body)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let observedAt {
                Text("Last observed \(observedAt.formatted(date: .abbreviated, time: .shortened))")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .demo = state {
                LifeOSStatusPill(label: "DEMO · NOT LIVE", tone: .demo)
            }
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        if case .loading = state {
            ProgressView()
                .controlSize(.small)
                .tint(LifeOSTokens.accent)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: state.iconName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15, weight: .medium, design: .default))
                .foregroundStyle(state.tone.foreground)
                .frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private var recoveryAction: some View {
        if let action, let actionTitle, !actionTitle.isEmpty {
            LifeOSButton(
                actionTitle,
                variant: .tertiary,
                action: action
            )
        }
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: LifeOSTokens.Space.sm) {
            stateIcon
            messageBlock
                .layoutPriority(1)
            recoveryAction
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
                stateIcon
                messageBlock
            }
            recoveryAction
        }
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            stackedLayout
        }
        .padding(.horizontal, LifeOSTokens.Space.sm)
        .padding(.vertical, LifeOSTokens.Space.sm)
        .frame(minHeight: LifeOSTokens.statusRowMinHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
        LifeOSStatusRow(
            state: state,
            actionTitle: retry == nil ? nil : "Try again",
            action: retry
        )
    }
}

// MARK: - Canonical sheet surface

#if os(macOS)
private struct LifeOSSheetPresentationLayout: Layout {
    let maxHeight: CGFloat
    let availableHeightInset: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count >= 3 else { return .zero }

        let width = proposal.width.flatMap { value in
            value.isFinite ? max(0, value) : nil
        }
        let childProposal = ProposedViewSize(width: width, height: nil)
        let scrollSize = subviews[0].sizeThatFits(childProposal)
        let dividerSize = subviews[1].sizeThatFits(childProposal)
        let footerSize = subviews[2].sizeThatFits(childProposal)
        let naturalHeight = scrollSize.height + dividerSize.height + footerSize.height
        let safeNaturalHeight = naturalHeight.isFinite ? max(0, naturalHeight) : maxHeight
        let availableBound = proposal.height.flatMap { value in
            guard value.isFinite, value > 0 else { return nil }
            return max(0, value - availableHeightInset)
        } ?? maxHeight
        let height = min(safeNaturalHeight, maxHeight, availableBound)
        let naturalWidth = max(scrollSize.width, max(dividerSize.width, footerSize.width))
        return CGSize(width: width ?? max(0, naturalWidth), height: max(0, height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 3 else { return }

        let childWidth = max(0, bounds.width)
        let footerSize = subviews[2].sizeThatFits(
            ProposedViewSize(width: childWidth, height: nil)
        )
        let footerHeight = min(max(0, footerSize.height), max(0, bounds.height))
        let dividerHeight = min(1, max(0, bounds.height - footerHeight))
        let scrollHeight = max(0, bounds.height - footerHeight - dividerHeight)

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: childWidth, height: scrollHeight)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + scrollHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: childWidth, height: dividerHeight)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - footerHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: childWidth, height: footerHeight)
        )
    }
}
#endif

/// A sheet body with one scroll owner and a footer that remains visible while
/// long forms grow. Each platform supplies a bounded presentation while the
/// body remains scrollable.
public struct LifeOSSheet<Content: View, Footer: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content
    private let footer: Footer
    private let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    public init(
        title: String,
        subtitle: String? = nil,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
        self.onDismiss = onDismiss
    }

    public var body: some View {
#if os(macOS)
        LifeOSSheetPresentationLayout(maxHeight: 760, availableHeightInset: 48) {
            scrollContent
            Divider()
            footerContent
        }
        .frame(
            minWidth: 420,
            idealWidth: 560,
            maxWidth: 640
        )
#elseif os(iOS)
        sheetStack
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
#else
        sheetStack
#endif
    }

    @ViewBuilder
    private var sheetStack: some View {
        VStack(spacing: 0) {
            scrollContent
            Divider()
            footerContent
        }
    }

    private var scrollContent: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xl) {
                header

                content
            }
            .frame(maxWidth: LifeOSTokens.proseMaxWidth, alignment: .topLeading)
            .padding(.horizontal, LifeOSTokens.pageGutter)
            .padding(.vertical, LifeOSTokens.Space.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    private var footerContent: some View {
        footer
            .frame(maxWidth: LifeOSTokens.proseMaxWidth, alignment: .trailing)
            .padding(.horizontal, LifeOSTokens.pageGutter)
            .padding(.vertical, LifeOSTokens.Space.sm)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.labelHelperGap) {
                Text(title)
                    .lifeOSTypography(.sectionTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: LifeOSTokens.Space.sm)

            LifeOSIconButton(
                icon: .close,
                action: dismissSheet
            )
        }
    }

    private func dismissSheet() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

public extension LifeOSSheet where Footer == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            content: content,
            footer: { EmptyView() }
        )
    }
}
