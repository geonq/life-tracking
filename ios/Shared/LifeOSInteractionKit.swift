import SwiftUI

/// The shared interaction lifecycle used by controls, charts and future
/// screen-specific gestures.
public enum LifeOSInteractionPhase: String, CaseIterable, Sendable {
    case idle
    case hover
    case focus
    case pressed
    case dragging
    case scrubbing
    case settling
    case cancelled
}

/// Reduce Motion changes decorative presentation only. User-driven gestures
/// remain available so a scrub, drag or scroll never becomes inaccessible.
public struct LifeOSInteractionPolicy: Equatable, Sendable {
    public let reduceMotion: Bool

    public init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
    }

    public var allowsDecorativeMotion: Bool { !reduceMotion }
    public var allowsUserDrivenMotion: Bool { true }
}

/// Pure state resolution for pressed, hover, focus and cancellation handling.
public struct LifeOSInteractionState: Equatable, Sendable {
    public let phase: LifeOSInteractionPhase
    public let policy: LifeOSInteractionPolicy

    public init(
        phase: LifeOSInteractionPhase = .idle,
        reduceMotion: Bool = false
    ) {
        self.phase = phase
        self.policy = LifeOSInteractionPolicy(reduceMotion: reduceMotion)
    }

    public var isPressed: Bool { phase == .pressed }
    public var isHovered: Bool { phase == .hover }
    public var isFocused: Bool { phase == .focus }
    public var isCancelled: Bool { phase == .cancelled }
    public var allowsDecorativeMotion: Bool { policy.allowsDecorativeMotion }
    public var allowsUserDrivenMotion: Bool { policy.allowsUserDrivenMotion }

    public static func resolve(
        pressed: Bool,
        hovered: Bool,
        focused: Bool,
        cancelled: Bool = false,
        reduceMotion: Bool = false
    ) -> LifeOSInteractionState {
        let phase: LifeOSInteractionPhase
        if cancelled {
            phase = .cancelled
        } else if pressed {
            phase = .pressed
        } else if focused {
            phase = .focus
        } else if hovered {
            phase = .hover
        } else {
            phase = .idle
        }
        return LifeOSInteractionState(phase: phase, reduceMotion: reduceMotion)
    }
}

/// Presentation values for a stateful control. Hover/focus affect fill and
/// border only; the shared foundation does not lift or scale controls.
public struct LifeOSInteractionAppearance: Equatable, Sendable {
    public let fillOpacity: Double
    public let borderOpacity: Double
    public let contentOpacity: Double

    public init(fillOpacity: Double, borderOpacity: Double, contentOpacity: Double) {
        self.fillOpacity = fillOpacity
        self.borderOpacity = borderOpacity
        self.contentOpacity = contentOpacity
    }

    public static func resolve(for state: LifeOSInteractionState) -> LifeOSInteractionAppearance {
        switch state.phase {
        case .pressed:
            return LifeOSInteractionAppearance(fillOpacity: 0.16, borderOpacity: 0.30, contentOpacity: 0.78)
        case .hover:
            return LifeOSInteractionAppearance(fillOpacity: 0.08, borderOpacity: 0.18, contentOpacity: 1)
        case .focus:
            return LifeOSInteractionAppearance(fillOpacity: 0.06, borderOpacity: 1, contentOpacity: 1)
        case .cancelled:
            return LifeOSInteractionAppearance(fillOpacity: 0, borderOpacity: 0, contentOpacity: 1)
        case .idle, .dragging, .scrubbing, .settling:
            return LifeOSInteractionAppearance(fillOpacity: 0, borderOpacity: 0, contentOpacity: 1)
        }
    }
}

/// Axis intent for a competing horizontal/vertical gesture.
public enum LifeOSGestureDirection: String, CaseIterable, Sendable {
    case undecided
    case horizontal
    case vertical
}

/// Shared axis arbitration: movement must reach 8pt and one axis must be at
/// least 1.15× the other before an axis is claimed.
public enum LifeOSDirectionalClassifier {
    public static let minimumDistance: CGFloat = 8
    public static let dominanceRatio: CGFloat = 1.15

    public static func classify(_ translation: CGSize) -> LifeOSGestureDirection {
        classify(horizontal: translation.width, vertical: translation.height)
    }

    public static func classify(horizontal: CGFloat, vertical: CGFloat) -> LifeOSGestureDirection {
        let horizontalDistance = abs(horizontal)
        let verticalDistance = abs(vertical)
        guard hypot(horizontalDistance, verticalDistance) >= minimumDistance else {
            return .undecided
        }

        if horizontalDistance >= verticalDistance * dominanceRatio {
            return .horizontal
        }
        if verticalDistance >= horizontalDistance * dominanceRatio {
            return .vertical
        }
        return .undecided
    }
}

/// Explicit cancellation state for gesture owners. Cancellation never mutates
/// source data; the owner decides whether to discard its presentation draft.
public struct LifeOSInteractionCancellation: Equatable, Sendable {
    public let isCancelled: Bool
    public let reason: String?

    public init(isCancelled: Bool = false, reason: String? = nil) {
        self.isCancelled = isCancelled
        self.reason = isCancelled ? reason : nil
    }

    public static let active = LifeOSInteractionCancellation()

    public static func cancelled(reason: String? = nil) -> LifeOSInteractionCancellation {
        LifeOSInteractionCancellation(isCancelled: true, reason: reason)
    }
}

/// Optional visual helper for controls that need the shared focus/pressed
/// treatment outside `LifeOSIconButton`.
public struct LifeOSInteractionModifier: ViewModifier {
    private let state: LifeOSInteractionState
    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

    public init(state: LifeOSInteractionState) {
        self.state = state
    }

    public func body(content: Content) -> some View {
        let effectiveState = LifeOSInteractionState(
            phase: state.phase,
            reduceMotion: state.policy.reduceMotion || environmentReduceMotion
        )
        let appearance = LifeOSInteractionAppearance.resolve(for: effectiveState)

        content
            .opacity(appearance.contentOpacity)
            .background(
                LifeOSTokens.raised.opacity(appearance.fillOpacity),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .overlay {
                if effectiveState.isFocused {
                    RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                        .stroke(LifeOSTokens.accent, lineWidth: 2)
                        .padding(2)
                }
            }
            .animation(
                effectiveState.allowsDecorativeMotion ? LifeOSMotion.hover : nil,
                value: effectiveState.phase
            )
    }
}

public extension View {
    func lifeOSInteractionState(
        pressed: Bool = false,
        hovered: Bool = false,
        focused: Bool = false,
        cancelled: Bool = false,
        reduceMotion: Bool = false
    ) -> some View {
        modifier(
            LifeOSInteractionModifier(
                state: LifeOSInteractionState.resolve(
                    pressed: pressed,
                    hovered: hovered,
                    focused: focused,
                    cancelled: cancelled,
                    reduceMotion: reduceMotion
                )
            )
        )
    }
}
