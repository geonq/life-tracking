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

/// Resolves requested control sizes to a platform minimum while rejecting
/// invalid/unbounded values. The maximum prevents an accidental layout value
/// from swallowing neighboring controls; callers can still choose a larger
/// visual surface around the target.
enum LifeOSHitTarget {
#if os(macOS)
    static let minimum: CGFloat = 32
#else
    static let minimum: CGFloat = 44
#endif
    static let maximum: CGFloat = 96

    static func resolve(_ requested: CGFloat? = nil) -> CGFloat {
        guard let requested else { return minimum }
        guard requested.isFinite else { return requested == .infinity ? maximum : minimum }
        return min(max(requested, minimum), maximum)
    }
}

/// Pure state resolution for pressed, hover, focus and cancellation handling.
public struct LifeOSInteractionState: Equatable, Sendable {
    public let phase: LifeOSInteractionPhase
    public let policy: LifeOSInteractionPolicy
    /// These flags stay independent so focus and hover are not lost while a
    /// button is pressed, and selection can be rendered alongside either.
    public let isPressed: Bool
    public let isHovered: Bool
    public let isFocused: Bool
    public let isSelected: Bool

    public init(
        phase: LifeOSInteractionPhase = .idle,
        reduceMotion: Bool = false,
        pressed: Bool? = nil,
        hovered: Bool? = nil,
        focused: Bool? = nil,
        selected: Bool = false
    ) {
        self.phase = phase
        self.policy = LifeOSInteractionPolicy(reduceMotion: reduceMotion)
        self.isPressed = pressed ?? (phase == .pressed)
        self.isHovered = hovered ?? (phase == .hover)
        self.isFocused = focused ?? (phase == .focus)
        self.isSelected = selected
    }

    public var isCancelled: Bool { phase == .cancelled }
    public var isDirectManipulation: Bool {
        phase == .dragging || phase == .scrubbing
    }
    public var allowsAnimatedStateTransition: Bool {
        policy.allowsDecorativeMotion && !isDirectManipulation
    }
    public var allowsDecorativeMotion: Bool { policy.allowsDecorativeMotion }
    public var allowsUserDrivenMotion: Bool { policy.allowsUserDrivenMotion }

    public static func resolve(
        pressed: Bool,
        hovered: Bool,
        focused: Bool,
        cancelled: Bool = false,
        reduceMotion: Bool = false,
        selected: Bool = false
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
        return LifeOSInteractionState(
            phase: phase,
            reduceMotion: reduceMotion,
            pressed: pressed,
            hovered: hovered,
            focused: focused,
            selected: selected
        )
    }
}

/// Presentation values for a stateful control. Hover/focus affect fill and
/// border only; the shared foundation does not lift or scale controls.
public struct LifeOSInteractionAppearance: Equatable, Sendable {
    public static let hoverFillOpacity = 0.04
    public static let selectedFillOpacity = 0.06
    public static let pressedFillOpacity = 0.08
    public static let selectedHoverFillOpacity = 0.10
    public static let focusRingLineWidth = 2.0
    public static let focusRingSeparation = 2.0

    public let fillOpacity: Double
    public let borderOpacity: Double
    public let contentOpacity: Double

    public init(fillOpacity: Double, borderOpacity: Double, contentOpacity: Double) {
        self.fillOpacity = fillOpacity
        self.borderOpacity = borderOpacity
        self.contentOpacity = contentOpacity
    }

    public static func resolve(for state: LifeOSInteractionState) -> LifeOSInteractionAppearance {
        let fillOpacity: Double
        if state.isPressed {
            fillOpacity = pressedFillOpacity
        } else if state.isSelected && state.isHovered {
            fillOpacity = selectedHoverFillOpacity
        } else if state.isSelected {
            fillOpacity = selectedFillOpacity
        } else if state.isHovered {
            fillOpacity = hoverFillOpacity
        } else {
            fillOpacity = 0
        }

        return LifeOSInteractionAppearance(
            fillOpacity: state.isCancelled ? 0 : fillOpacity,
            borderOpacity: state.isSelected ? 1 : 0,
            // Interaction feedback keeps labels fully readable. Disabled
            // controls own their separate readable foreground role.
            contentOpacity: 1
        )
    }
}

/// Axis intent for a competing horizontal/vertical gesture.
public enum LifeOSGestureDirection: String, CaseIterable, Sendable {
    case undecided
    case horizontal
    case vertical
}

/// Shared axis arbitration: movement must reach 8pt and one axis must be at
/// least 1.3× the other before an axis is claimed. Ambiguous movement defaults
/// to vertical after 16pt so a calendar/timeline scroll remains the safe owner.
public enum LifeOSDirectionalClassifier {
    public static let minimumDistance: CGFloat = 8
    public static let dominanceRatio: CGFloat = 1.3
    public static let ambiguousVerticalDistance: CGFloat = 16

    public static func classify(_ translation: CGSize) -> LifeOSGestureDirection {
        classify(horizontal: translation.width, vertical: translation.height)
    }

    public static func classify(horizontal: CGFloat, vertical: CGFloat) -> LifeOSGestureDirection {
        let horizontalDistance = abs(horizontal)
        let verticalDistance = abs(vertical)
        guard horizontalDistance.isFinite, verticalDistance.isFinite else {
            return .undecided
        }

        let travelDistance = hypot(horizontalDistance, verticalDistance)
        guard travelDistance >= minimumDistance else {
            return .undecided
        }

        if horizontalDistance >= verticalDistance * dominanceRatio {
            return .horizontal
        }
        if verticalDistance >= horizontalDistance * dominanceRatio {
            return .vertical
        }
        return travelDistance >= ambiguousVerticalDistance ? .vertical : .undecided
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
            reduceMotion: state.policy.reduceMotion || environmentReduceMotion,
            pressed: state.isPressed,
            hovered: state.isHovered,
            focused: state.isFocused,
            selected: state.isSelected
        )
        let appearance = LifeOSInteractionAppearance.resolve(for: effectiveState)

        content
            .opacity(appearance.contentOpacity)
            .background(
                LifeOSTokens.primaryText.opacity(appearance.fillOpacity),
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .overlay {
                if effectiveState.isFocused {
                    RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                        .stroke(LifeOSTokens.focusStroke, lineWidth: 2)
                        .padding(-3)
                }
            }
            .animation(
                LifeOSMotion.curve(
                    for: .hover,
                    reduceMotion: !effectiveState.allowsAnimatedStateTransition
                )?.animation,
                value: effectiveState.isHovered
            )
            .animation(
                LifeOSMotion.curve(
                    for: effectiveState.isPressed ? .press : .release,
                    reduceMotion: !effectiveState.allowsAnimatedStateTransition
                )?.animation,
                value: effectiveState.isPressed
            )
            .animation(
                effectiveState.allowsAnimatedStateTransition ? LifeOSMotion.selector : nil,
                value: effectiveState.isSelected
            )
        }
}

public extension View {
    func lifeOSInteractionState(
        pressed: Bool = false,
        hovered: Bool = false,
        focused: Bool = false,
        cancelled: Bool = false,
        reduceMotion: Bool = false,
        selected: Bool = false
    ) -> some View {
        modifier(
            LifeOSInteractionModifier(
                state: LifeOSInteractionState.resolve(
                    pressed: pressed,
                    hovered: hovered,
                    focused: focused,
                    cancelled: cancelled,
                    reduceMotion: reduceMotion,
                    selected: selected
                )
            )
        )
    }
}
