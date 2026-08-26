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

// MARK: - A. Progress Ring

/// A progress ring that sweeps in once with `LifeOSMotion.ringReveal` and ends
/// crisp: no halo, no glow, no angular gradient (Quiet Machine §5.5/§2.4 —
/// solid accent arcs only; status rings resolve a semantic color upstream).
///
/// `hue` is retained for source compatibility with un-migrated call sites and
/// is IGNORED for rendering; new call sites should omit it via the convenience
/// initializer below.
public struct GlowRing<Center: View>: View {
    public let progress: Double
    public let hue: LifeOSTokens.Hue
    public let diameter: CGFloat
    public let lineWidth: CGFloat
    private let center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedProgress: Double = 0

    public init(
        progress: Double,
        hue: LifeOSTokens.Hue,
        diameter: CGFloat = 120,
        lineWidth: CGFloat = 8,
        @ViewBuilder center: @escaping () -> Center = { EmptyView() }
    ) {
        self.progress = progress
        self.hue = hue
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.center = center
    }

    /// Preferred initializer: the arc renders solid accent.
    public init(
        progress: Double,
        diameter: CGFloat = 120,
        lineWidth: CGFloat = 8,
        @ViewBuilder center: @escaping () -> Center = { EmptyView() }
    ) {
        self.progress = progress
        self.hue = .blue
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.center = center
    }

    private var clampedTarget: Double {
        min(max(progress, 0), 1)
    }

    public var body: some View {
        ZStack {
            // Track — the shared hairline token.
            Circle()
                .stroke(LifeOSTokens.Ring.track, lineWidth: lineWidth)

            // Crisp progress arc — one flat color, round caps.
            Circle()
                .trim(from: 0, to: animatedProgress)
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
            if reduceMotion {
                animatedProgress = clampedTarget
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    if reduceMotion {
                        selection = option
                    } else {
                        withAnimation(LifeOSMotion.snappy) { selection = option }
                    }
                } label: {
                    label(option, isSelected)
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
            }
        }
    }
}

// MARK: - C. Chart draw-on

/// Tracks a `drawn` progress value (0→1) that animates on appear with `LifeOSMotion.chartDraw`,
/// for driving `.trim(from:to:)` on chart strokes/masks. Instant under Reduce-Motion.
public struct DrawOnProgress: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    public init() {}

    public var value: CGFloat { drawn }

    /// Call once, e.g. from `.task { drawOn.start() }`.
    public func start() {
        if reduceMotion {
            drawn = 1
        } else {
            withAnimation(LifeOSMotion.chartDraw) { drawn = 1 }
        }
    }

    /// Resets to 0 without animating (e.g. before re-running `start()` on new data).
    public func reset() {
        drawn = 0
    }
}

private struct ChartDrawOnModifier<ID: Equatable>: ViewModifier {
    let id: ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .task(id: id) {
                // Reset synchronously before revealing a new dataset. The identity is supplied
                // by the chart's source data, so unrelated parent redraws do not restart motion.
                drawn = 0
                if reduceMotion {
                    drawn = 1
                } else {
                    withAnimation(LifeOSMotion.chartDraw) { drawn = 1 }
                }
            }
            .environment(\.lifeOSChartDrawn, drawn)
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
                            width: geometry.size.width * min(max(drawn, 0), 1),
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

    /// Drives the reveal once for each source-data identity. Pass a stable value derived from
    /// the plotted dataset so refreshes reset the mask, while parent redraws do not replay it.
    public func chartDrawOn<ID: Equatable>(id: ID) -> some View {
        modifier(ChartDrawOnModifier(id: id))
    }

    /// Applies the current draw-on mask inside the view subtree. Use this on
    /// plotted marks/path content, not on the surrounding labels or tooltip.
    public func chartDrawReveal() -> some View {
        LifeOSChartDrawReveal(content: self)
    }
}

// MARK: - D. Scrub bubble

/// A value bubble that follows an x-position with `LifeOSMotion.track`, for chart scrubbing
/// (`03-motion-revolut.md` §D). Elevation-3 surface. Reduce-Motion: bubble jumps to position
/// with no follow spring (scrub still works).
public struct ScrubBubble<Content: View>: View {
    public let x: CGFloat
    public let y: CGFloat
    private let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(x: CGFloat, y: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.x = x
        self.y = y
        self.content = content
    }

    public var body: some View {
        content()
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, LifeOSTokens.Space.xs)
            .padding(.vertical, LifeOSTokens.Space.xs)
            .background(LifeOSTokens.floatingOverlay.opacity(0.96), in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            .position(x: x, y: y)
            .animation(reduceMotion ? nil : LifeOSMotion.track, value: x)
            .animation(reduceMotion ? nil : LifeOSMotion.track, value: y)
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

// MARK: - E. Numeric transitions

extension View {
    /// Applies `.contentTransition(.numericText())` (iOS 17+) for count-up number changes
    /// (`03-motion-revolut.md` §F). No-op fallback on platforms/OS versions without it.
    @ViewBuilder
    public func numericTransition() -> some View {
        if #available(iOS 17, macOS 14, *) {
            self.contentTransition(.numericText())
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
// `withAnimation(LifeOSMotion.heroMorph) { ... }`. Under Reduce-Motion, skip the
// `matchedGeometryEffect` entirely and cross-fade with `.opacity` instead — do not call
// `.matchedCard` when `LifeOSMotion.reduceMotion` is true.
//
// This helper does not wire any cross-screen navigation morph; that requires the owning
// screen's redesign and is out of scope for the motion-system foundation.

extension View {
    /// Tags this view as one endpoint of a hero-morph transition. Apply the same `id` in the
    /// same `namespace` to both the source card and the destination detail header. Caller is
    /// responsible for skipping this (using a cross-fade instead) under Reduce-Motion.
    public func matchedCard(id: some Hashable, in namespace: Namespace.ID) -> some View {
        matchedGeometryEffect(id: id, in: namespace)
    }
}
