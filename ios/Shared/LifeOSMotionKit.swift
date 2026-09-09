import SwiftUI

#if os(iOS)
import UIKit
#endif

// MARK: - LifeOS Motion Kit
//
// Reusable, Reduce-Motion-aware motion primitives per
// `developers/design-coordination/03-motion-revolut.md`. These are building blocks —
// Usage/Finance widgets and screens adopt them; this file does not redesign any screen.
//
// Every primitive here reads `LifeOSMotion.reduceMotion` (or the environment key where a
// live SwiftUI environment is available) and degrades per the spec's Reduce-Motion table:
// morphs → cross-fade, ring sweeps → static, chart draw → instant, scrub still works but
// the bubble jumps (no follow spring), pills swap without slide.

// MARK: - Deterministic motion ownership

private struct LifeOSReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Additive app/preview override. `false` never defeats the system preference.
    public var lifeOSReduceMotion: Bool {
        get { self[LifeOSReduceMotionKey.self] }
        set { self[LifeOSReduceMotionKey.self] = newValue }
    }
}

/// A gesture owns presentation drafts only. Commit/discard effects are returned once;
/// the caller owns data mutation. Animation completion must carry the returned settle ID.
/// A new gesture invalidates that ID, so interrupted animations cannot finish a newer one.
public struct LifeOSMotionLifecycle: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case hover(Bool), focus(Bool), enabled(Bool)
        case press, drag, scrub, end, cancel
        case settled(UUID)
    }
    public enum Effect: Equatable, Sendable { case none, commit, discard }
    public private(set) var phase: LifeOSInteractionPhase = .idle
    public private(set) var settlementID: UUID?
    public private(set) var isEnabled = true
    private var hovered = false
    private var focused = false
    public init() {}

    private var restingPhase: LifeOSInteractionPhase {
        focused ? .focus : (hovered ? .hover : .idle)
    }
    private var ownsGesture: Bool {
        phase == .pressed || phase == .dragging || phase == .scrubbing
    }

    @discardableResult
    public mutating func send(_ event: Event) -> Effect {
        switch event {
        case let .enabled(enabled):
            guard isEnabled != enabled else { return .none }
            let effect: Effect = ownsGesture ? .discard : .none
            isEnabled = enabled
            hovered = false; focused = false; settlementID = nil; phase = .idle
            return effect
        case let .settled(id):
            guard settlementID == id else { return .none }
            settlementID = nil
            phase = isEnabled ? restingPhase : .idle
        default:
            guard isEnabled else { return .none }
            switch event {
            case let .hover(value):
                hovered = value
                if !ownsGesture && settlementID == nil { phase = restingPhase }
            case let .focus(value):
                focused = value
                if !ownsGesture && settlementID == nil { phase = restingPhase }
            case .press, .drag, .scrub:
                settlementID = nil
                phase = event == .press ? .pressed : (event == .drag ? .dragging : .scrubbing)
            case .end:
                guard ownsGesture else { return .none }
                phase = .settling; settlementID = UUID()
                return .commit
            case .cancel:
                guard ownsGesture || phase == .settling else { return .none }
                let effect: Effect = ownsGesture ? .discard : .none
                phase = .cancelled; settlementID = UUID()
                return effect
            case .enabled, .settled: break
            }
        }
        return .none
    }
}

/// Keeps an interaction transition local to its explicit owner. The transaction
/// reset also takes effect when Reduce Motion changes while a transition is in
/// flight, so the expanded/collapsed state settles without inheriting a stale
/// animation from an ancestor.
private struct LifeOSInteractionAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : animation, value: value)
            .transaction { transaction in
                guard reduceMotion else { return }
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

extension View {
    /// Applies an animation only to a user-owned value transition. Use this
    /// for disclosure/selection state; refreshes and source updates remain
    /// visually direct.
    public func lifeOSInteractionAnimation<Value: Equatable>(
        _ animation: Animation,
        value: Value,
        reduceMotion: Bool
    ) -> some View {
        modifier(LifeOSInteractionAnimationModifier(
            animation: animation,
            value: value,
            reduceMotion: reduceMotion
        ))
    }
}

public enum LifeOSChartMotionPolicy {
    /// Reveal only a newly mounted plot. Refresh/range changes keep existing data visible;
    /// never replay a hidden mask while the user is inspecting it.
    public static func shouldReveal(hasPresented: Bool, interacting: Bool, reduceMotion: Bool) -> Bool {
        !hasPresented && !interacting && !reduceMotion
    }
    public static func progress(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 1
    }
}

/// Lives with the presentation owner, including temporary unavailable states.
public struct LifeOSChartPresentationState {
    public private(set) var hasPresented = false
    public private(set) var reservedHeight: CGFloat = 0
    public private(set) var hasRecordedContent = false

    public mutating func reveal(interacting: Bool, reduceMotion: Bool) -> Bool {
        defer { hasPresented = true }
        return LifeOSChartMotionPolicy.shouldReveal(
            hasPresented: hasPresented, interacting: interacting, reduceMotion: reduceMotion)
    }

    /// Marks the current presentation as settled after an interaction,
    /// cancellation, or disappearance. A later data update may replace the
    /// pixels, but it cannot replay the entrance reveal for this owner.
    public mutating func settle() {
        hasPresented = true
    }

    public mutating func recordHeight(_ height: CGFloat, isEmpty: Bool) {
        guard !isEmpty, height.isFinite, height > 0 else { return }
        reservedHeight = height
        hasRecordedContent = true
    }
}

/// Owns a chart's one-shot reveal for the lifetime of a mounted detail route.
/// Mode views receive the same progress binding, so changing a line/bar/ring
/// renderer or its range cannot create a new animation owner. Interruption and
/// Reduce Motion settle the current presentation immediately.
public struct LifeOSChartRevealOwner<Content: View>: View {
    private let identity: AnyHashable
    private let interacting: Bool
    private let content: (Binding<CGFloat>) -> Content

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    @State private var progress: CGFloat = 0
    @State private var presentation = LifeOSChartPresentationState()

    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }

    public init<ID: Hashable>(
        identity: ID,
        interacting: Bool = false,
        @ViewBuilder content: @escaping (Binding<CGFloat>) -> Content
    ) {
        self.identity = AnyHashable(identity)
        self.interacting = interacting
        self.content = content
    }

    public var body: some View {
        content($progress)
            .environment(
                \.lifeOSChartDrawn,
                reduceMotion || interacting ? 1 : LifeOSChartMotionPolicy.progress(progress)
            )
            .task(id: identity) {
                let reveal = presentation.reveal(
                    interacting: interacting,
                    reduceMotion: reduceMotion
                )
                guard reveal else {
                    settle()
                    return
                }
                withAnimation(LifeOSMotion.chartDraw) { progress = 1 }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { settle() }
            }
            .onChange(of: interacting) { _, active in
                if active { settle() }
            }
            .onDisappear { settle() }
    }

    private func settle() {
        presentation.settle()
        LifeOSMotion.withoutAnimation { progress = 1 }
    }
}

// MARK: - A. Progress Ring

/// A progress ring that sweeps in once with `LifeOSMotion.ringReveal` and ends
/// crisp: no halo, no glow, no angular gradient (Quiet Machine §5.5/§2.4 —
/// solid accent arcs only; status rings resolve a semantic color upstream).
///
public struct GlowRing<Center: View>: View {
    public let progress: Double
    public let diameter: CGFloat
    public let lineWidth: CGFloat
    private let center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var animatedProgress: Double = 0
    @State private var presentation = LifeOSChartPresentationState()

    public init(
        progress: Double,
        diameter: CGFloat = 120,
        lineWidth: CGFloat = 8,
        @ViewBuilder center: @escaping () -> Center = { EmptyView() }
    ) {
        self.progress = progress
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.center = center
    }

    private var clampedTarget: Double {
        Double(LifeOSChartMotionPolicy.progress(CGFloat(progress)))
    }

    public var body: some View {
        ZStack {
            // Track — the shared hairline token.
            Circle()
                .stroke(LifeOSTokens.Ring.track, lineWidth: lineWidth)

            // Crisp progress arc — one flat color, round caps.
            Circle()
                .trim(from: 0, to: reduceMotion ? clampedTarget : animatedProgress)
                .stroke(
                    LifeOSTokens.Ring.progressArc,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
        }
        .rotationEffect(.degrees(-90))
        .frame(width: diameter, height: diameter)
        .overlay {
            center()
                .frame(width: diameter - lineWidth * 3, height: diameter - lineWidth * 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(clampedTarget, format: .percent.precision(.fractionLength(0))))
        .task(id: "\(clampedTarget)-\(reduceMotion)") {
            let reveal = presentation.reveal(
                interacting: false, reduceMotion: reduceMotion)
            if !reveal {
                LifeOSMotion.withoutAnimation { animatedProgress = clampedTarget }
                return
            }
            withAnimation(LifeOSMotion.ringReveal) { animatedProgress = clampedTarget }
        }
    }
}

// MARK: - B. Spring Pill Selector

/// A generic segmented control whose selected-pill background travels between options via
/// `matchedGeometryEffect`, animated with `LifeOSMotion.snappy` (`03-motion-revolut.md` §E).
/// Labels stay put; only the highlight moves. Reduce-Motion: highlight swaps without slide.
public struct SpringPillSelector<T: Hashable, Label: View>: View {
    public let options: [T]
    @Binding public var selection: T
    private let label: (T, Bool) -> Label

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @Namespace private var namespace
    private let highlightID = "lifeos.pillSelector.highlight"

    public init(
        options: [T],
        selection: Binding<T>,
        @ViewBuilder label: @escaping (T, Bool) -> Label
    ) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    guard selection != option else { return }
                    if reduceMotion {
                        LifeOSMotion.withoutAnimation { selection = option }
                    } else {
                        withAnimation(LifeOSMotion.selector) { selection = option }
                    }
                } label: {
                    label(option, isSelected)
                        // Selection changes update label styling, but label
                        // geometry must remain stationary. The highlight is
                        // the only element that receives the animated
                        // transaction through matchedGeometryEffect below.
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minWidth: LifeOSTokens.Control.minimumTarget)
                        .frame(minHeight: LifeOSTokens.Control.minimumTarget)
                        .background {
                            if isSelected {
                                // Monochrome selection: brightness, not hue —
                                // elevated fill only, no border stroke (§5.3).
                                if reduceMotion {
                                    Capsule().fill(LifeOSTokens.raised)
                                } else {
                                    Capsule().fill(LifeOSTokens.raised)
                                        .matchedGeometryEffect(id: highlightID, in: namespace)
                                }
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

// MARK: - C. Chart draw-on

/// Tracks a `drawn` progress value (0→1) that animates on appear with `LifeOSMotion.chartDraw`,
/// for driving `.trim(from:to:)` on chart strokes/masks. Instant under Reduce-Motion.
public struct DrawOnProgress: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var drawn: CGFloat = 0

    public init() {}

    public var value: CGFloat { reduceMotion ? 1 : drawn }

    /// Call once, e.g. from `.task { drawOn.start() }`.
    public func start() {
        if reduceMotion {
            LifeOSMotion.withoutAnimation { drawn = 1 }
        } else {
            withAnimation(LifeOSMotion.chartDraw) { drawn = 1 }
        }
    }

    /// Resets to 0 without animating (e.g. before re-running `start()` on new data).
    public func reset() {
        LifeOSMotion.withoutAnimation { drawn = reduceMotion ? 1 : 0 }
    }

    /// Call when interaction starts or its owner disappears; never leave a partial plot.
    public func cancel() {
        LifeOSMotion.withoutAnimation { drawn = 1 }
    }
}

private struct ChartDrawOnModifier<ID: Equatable>: ViewModifier {
    let id: ID
    let interacting: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var drawn: CGFloat = 0
    @State private var presentation = LifeOSChartPresentationState()

    func body(content: Content) -> some View {
        content
            .task(id: id) {
                let reveal = presentation.reveal(
                    interacting: interacting, reduceMotion: reduceMotion)
                if reveal {
                    withAnimation(LifeOSMotion.chartDraw) { drawn = 1 }
                } else {
                    LifeOSMotion.withoutAnimation { drawn = 1 }
                }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { LifeOSMotion.withoutAnimation { drawn = 1 } }
            }
            .onChange(of: interacting) { _, active in
                if active { LifeOSMotion.withoutAnimation { drawn = 1 } }
            }
            .onDisappear { LifeOSMotion.withoutAnimation { drawn = 1 } }
            .environment(\.lifeOSChartDrawn, reduceMotion || interacting ? 1 : drawn)
            .transaction { transaction in
                if reduceMotion || interacting {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

private struct LifeOSChartDrawnKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

/// Masks only the rendered chart subtree with the progress supplied by
/// `chartDrawOn(id:)`. Keeping the environment read inside this view matters:
/// a parent view must not capture a child-modified environment value while it
/// is building its body. Axes, labels, tooltips, and accessibility content can
/// therefore remain available while the plotted pixels reveal from left to
/// right.
public struct LifeOSChartDrawReveal<Content: View>: View {
    private let content: Content
    @Environment(\.lifeOSChartDrawn) private var drawn

    public init(content: Content) {
        self.content = content
    }

    public var body: some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.white)
                        .frame(
                            width: geometry.size.width * LifeOSChartMotionPolicy.progress(drawn),
                            height: geometry.size.height,
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
    }
}

extension EnvironmentValues {
    /// The current chart draw-on progress (0→1), set by `.chartDrawOn()`.
    public var lifeOSChartDrawn: CGFloat {
        get { self[LifeOSChartDrawnKey.self] }
        set { self[LifeOSChartDrawnKey.self] = newValue }
    }
}

extension View {
    /// Drives a one-shot 0→1 draw-on animation (`LifeOSMotion.chartDraw`) on appear, exposed to
    /// descendants via `\.lifeOSChartDrawn`. Instant under Reduce-Motion. See
    /// `03-motion-revolut.md` §C — animate the stroke/mask, not the underlying y-values.
    public func chartDrawOn() -> some View {
        chartDrawOn(id: true)
    }

    /// Stable data identity cancels an old reveal without blanking a refreshed plot.
    /// Pass gesture activity to interrupt the initial reveal on the very first scrub.
    public func chartDrawOn<ID: Equatable>(id: ID, interacting: Bool = false) -> some View {
        modifier(ChartDrawOnModifier(id: id, interacting: interacting))
    }

    /// Applies the current draw-on mask inside the view subtree. Use this on
    /// plotted marks/path content, not on the surrounding labels or tooltip.
    public func chartDrawReveal() -> some View {
        LifeOSChartDrawReveal(content: self)
    }
}

// MARK: - D. Scrub bubble

/// A bounded value bubble that tracks the selected sample directly in every motion mode.
/// Its position never lags behind its label or the chart crosshair.
public struct ScrubBubble<Content: View>: View {
    public let x: CGFloat
    public let y: CGFloat
    /// The plot bounds in the same coordinate space as `x`/`y`. When supplied,
    /// the bubble measures its rendered size and stays inside those bounds.
    public let bounds: CGRect?
    public let inset: CGFloat
    private let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var measuredSize: CGSize = .zero

    public init(
        x: CGFloat,
        y: CGFloat,
        bounds: CGRect? = nil,
        inset: CGFloat = 8,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.x = x
        self.y = y
        self.bounds = bounds
        self.inset = inset
        self.content = content
    }

    public var body: some View {
        content()
            .lifeOSTypography(.metadata).monospacedDigit()
            .padding(.horizontal, LifeOSTokens.Space.xs)
            .padding(.vertical, LifeOSTokens.Space.xs)
            .background(LifeOSTokens.floatingOverlay.opacity(0.96), in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ScrubBubbleSizeKey.self, value: geometry.size)
                }
            }
            .onPreferenceChange(ScrubBubbleSizeKey.self) { measuredSize = $0 }
            // The bounded frame is applied to the actual content, not only to
            // the position calculation. This keeps Dynamic Type and long
            // source labels from escaping the plot or the widget card.
            .frame(width: renderedFrame?.width, height: renderedFrame?.height)
            .clipped()
            .position(x: renderedPosition.x, y: renderedPosition.y)
            // The selected datum and its bubble must agree on every frame. Never
            // trail the crosshair with a second, independently retargeted spring.
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }

    private var renderedPosition: CGPoint {
        renderedFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: x, y: y)
    }

    private var renderedFrame: CGRect? {
        guard let bounds else { return nil }

        // A conservative first-frame estimate prevents a flash outside the
        // plot before the real content size preference arrives.
        let size = measuredSize == .zero ? CGSize(width: 120, height: 34) : measuredSize
        return LifeOSChartKit.boundedTooltipFrame(
            anchor: CGPoint(x: x, y: y),
            size: size,
            in: bounds,
            inset: inset
        )
    }

    /// Fires a light impact haptic when the scrubbed point changes. Call from `.onChange` of
    /// the snapped data point's identity. No-op on macOS.
    public static func snapHaptic() {
#if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
#endif
    }
}

private struct ScrubBubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

// MARK: - E. Numeric transitions

extension View {
    /// Applies `.contentTransition(.numericText())` (iOS 17+) for count-up number changes
    /// (`03-motion-revolut.md` §F). No-op fallback on platforms/OS versions without it.
    @ViewBuilder
    public func numericTransition() -> some View {
        if #available(iOS 17, macOS 14, *) {
            self.modifier(LifeOSNumericTransitionModifier())
        } else {
            self
        }
    }
}

// MARK: - F. Hero morph helper
//
// Usage: a parent view owns `@Namespace private var heroNamespace` and applies
// `.matchedCard(id:in:)` with the SAME id to both the source card and the destination
// detail header, then toggles a `@State` selection inside
// `withAnimation(LifeOSMotion.curve(for: .navigation, reduceMotion: reduced)?.animation)`.
// The helper reads the live environment and replaces geometry with opacity when reduced.
//
// This helper does not wire any cross-screen navigation morph; that requires the owning
// screen's redesign and is out of scope for the motion-system foundation.

extension View {
    /// Tags this view as one endpoint of a hero-morph transition. Apply the same `id` in the
    /// same `namespace` to both endpoints. Reduced motion uses opacity instead of geometry;
    /// the owner supplies `LifeOSMotion.curve(for: .navigation, reduceMotion:)` on selection.
    public func matchedCard(id: some Hashable, in namespace: Namespace.ID) -> some View {
        modifier(LifeOSMatchedCardModifier(id: id, namespace: namespace))
    }
}

private struct LifeOSMatchedCardModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if systemReduceMotion || requestedReduceMotion {
            content.transition(.opacity)
        } else {
            content.matchedGeometryEffect(id: id, in: namespace)
        }
    }
}

private struct LifeOSNumericTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    func body(content: Content) -> some View {
        content.contentTransition(systemReduceMotion || requestedReduceMotion ? .opacity : .numericText())
    }
}

/// Availability changes visibility, never the identity or layout ownership of a plot.
/// Hidden content receives current (possibly empty) data, not a cached/fake series.
public struct LifeOSChartAvailabilityPolicy: Equatable {
    public let isEmpty: Bool
    public var contentOpacity: Double { isEmpty ? 0 : 1 }
    public var allowsInspection: Bool { !isEmpty }
}

private struct ChartAvailabilityModifier<Placeholder: View>: ViewModifier {
    let isEmpty: Bool
    let identity: AnyHashable
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var presentation = LifeOSChartPresentationState()

    func body(content: Content) -> some View {
        let policy = LifeOSChartAvailabilityPolicy(isEmpty: isEmpty)
        ZStack {
            if !isEmpty || presentation.hasRecordedContent {
                content
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ChartPresentationHeightKey.self, value: geometry.size.height)
                        }
                    }
                    .opacity(policy.contentOpacity)
                    .allowsHitTesting(policy.allowsInspection)
                    .disabled(!policy.allowsInspection)
                    .accessibilityHidden(!policy.allowsInspection)
            }
            if isEmpty { placeholder() }
        }
        // A first-load/no-source state must stay compact. Once a real plot has
        // been presented, the owner keeps its geometry during a transient
        // refresh so the page does not jump while retained values remain on
        // screen.
        .frame(minHeight: isEmpty && presentation.hasRecordedContent ? presentation.reservedHeight : 0)
        .onPreferenceChange(ChartPresentationHeightKey.self) { height in
            presentation.recordHeight(height, isEmpty: isEmpty)
        }
        .onChange(of: identity) { _, _ in
            // A new source/window/mode owns a new plot geometry. Without an
            // explicit identity, an old populated chart can leave a large
            // empty reservation behind after a range or source change.
            presentation = LifeOSChartPresentationState()
        }
        .animation(nil, value: isEmpty)
    }
}

private struct ChartPresentationHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    public func chartAvailability<Placeholder: View>(
        isEmpty: Bool,
        identity: AnyHashable = "default",
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) -> some View {
        modifier(ChartAvailabilityModifier(isEmpty: isEmpty, identity: identity, placeholder: placeholder))
    }
}
