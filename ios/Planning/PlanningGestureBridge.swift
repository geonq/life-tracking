import CoreGraphics
import Foundation

public enum PlanningGesturePlatform: String, Equatable, Sendable {
    case macOS
    case iOS

    public static var current: Self {
#if os(macOS)
        return .macOS
#else
        return .iOS
#endif
    }
}

/// The one owner allowed to interpret a pointer/touch sequence.
public enum PlanningGestureOwner: String, Equatable, Sendable {
    case idle
    case selection
    case pendingNodeLongPress
    case pan
    case spacePan
    case zoom
    case nodeDrag
    case cancelled
}

/// Normalizes platform input before it reaches the canvas coordinator. The
/// bridge is deliberately independent from SwiftUI/AppKit/UIKit recognizers:
/// platform wrappers feed it events, and this state machine decides which
/// operation owns the sequence.
public struct PlanningGestureBridge: Equatable, Sendable {
    public static let nodeLongPressDelay: TimeInterval = 0.18
    public static let preRecognitionMovement: CGFloat = 8

    public let platform: PlanningGesturePlatform
    public private(set) var owner: PlanningGestureOwner = .idle
    public private(set) var activeNodeID: String?
    public private(set) var startLocation: CGPoint?
    /// Monotonically increasing token for the physical input sequence that
    /// currently owns the bridge. Platform recognizers use it to ignore stale
    /// end/cancel callbacks from a recognizer that lost arbitration.
    public private(set) var sequenceID: UInt64 = 0
    private var startedAt: TimeInterval?

    public init(platform: PlanningGesturePlatform = .current) {
        self.platform = platform
    }

    public var isActive: Bool {
        owner != .idle && owner != .cancelled
    }

    public func owns(
        sequenceID: UInt64,
        owner expectedOwner: PlanningGestureOwner? = nil
    ) -> Bool {
        guard isActive, self.sequenceID == sequenceID else { return false }
        guard let expectedOwner else { return true }
        return owner == expectedOwner
    }

    /// Starts a pointer/touch sequence. A node drag begins immediately on
    /// macOS; iOS waits for the bounded long-press interval. Locked nodes stay
    /// selectable but never become movable owners.
    @discardableResult
    public mutating func beginPointer(
        at location: CGPoint,
        nodeID: String?,
        nodeLocked: Bool = false,
        touchCount: Int = 1,
        spacePressed: Bool = false,
        timestamp: TimeInterval = 0
    ) -> PlanningGestureOwner {
        guard Self.isFinite(location), touchCount > 0 else {
            cancel()
            return owner
        }
        guard owner == .idle || owner == .cancelled else { return owner }

        sequenceID &+= 1
        startLocation = location
        startedAt = timestamp
        activeNodeID = nodeID

        if touchCount >= 2 {
            owner = .zoom
        } else if platform == .macOS, spacePressed {
            // Space is a modal navigation modifier. It wins over node hit
            // testing so a space-drag over a node can never move that node.
            activeNodeID = nil
            owner = .spacePan
        } else if let nodeID {
            if nodeLocked {
                self.activeNodeID = nodeID
                owner = .selection
            } else if platform == .macOS {
                owner = .nodeDrag
            } else {
                owner = .pendingNodeLongPress
            }
        } else {
            owner = .pan
        }
        return owner
    }

    /// Advances the active pointer/touch sequence. Before iOS long-press
    /// recognition, movement beyond the threshold is intentionally promoted to
    /// navigation so a scroll never turns into a node move.
    @discardableResult
    public mutating func movePointer(
        to location: CGPoint,
        timestamp: TimeInterval = 0,
        touchCount: Int = 1
    ) -> PlanningGestureOwner {
        guard Self.isFinite(location), touchCount > 0 else { return owner }
        guard owner == .pendingNodeLongPress,
              let startLocation,
              let startedAt else { return owner }

        let distance = hypot(location.x - startLocation.x, location.y - startLocation.y)
        if distance > Self.preRecognitionMovement {
            owner = .pan
        } else if timestamp - startedAt >= Self.nodeLongPressDelay - 0.000_001 {
            owner = .nodeDrag
        }
        return owner
    }

    /// Claims a trackpad pinch or a two-finger touch sequence. Once another
    /// owner has claimed the sequence, the claim is ignored until end/cancel.
    @discardableResult
    public mutating func beginZoom(at focal: CGPoint, timestamp: TimeInterval = 0) -> PlanningGestureOwner {
        guard Self.isFinite(focal), owner == .idle || owner == .cancelled else { return owner }
        sequenceID &+= 1
        startLocation = focal
        startedAt = timestamp
        activeNodeID = nil
        owner = .zoom
        return owner
    }

    /// Claims a macOS scroll or an explicit space-drag pan while idle.
    @discardableResult
    public mutating func beginPan(
        at location: CGPoint = .zero,
        spacePressed: Bool = false,
        timestamp: TimeInterval = 0
    ) -> PlanningGestureOwner {
        guard Self.isFinite(location), owner == .idle || owner == .cancelled else { return owner }
        sequenceID &+= 1
        startLocation = location
        startedAt = timestamp
        activeNodeID = nil
        owner = platform == .macOS && spacePressed ? .spacePan : .pan
        return owner
    }

    /// Promotes the current one-finger sequence to a native two-finger zoom.
    /// This is the only legal owner transition after a sequence has started;
    /// it prevents a second touch from being treated as a second independent
    /// drag while retaining one token for all cancellation callbacks.
    @discardableResult
    public mutating func promoteToZoom(
        at focal: CGPoint,
        timestamp: TimeInterval = 0,
        sequenceID expectedSequenceID: UInt64? = nil
    ) -> PlanningGestureOwner {
        guard Self.isFinite(focal), isActive,
              expectedSequenceID.map({ $0 == sequenceID }) ?? true,
              owner == .pendingNodeLongPress || owner == .pan
                || owner == .spacePan || owner == .selection || owner == .nodeDrag else {
            return owner
        }
        startLocation = focal
        startedAt = timestamp
        activeNodeID = nil
        owner = .zoom
        return owner
    }

    /// Ends the current sequence and releases ownership for the next input.
    public mutating func end() {
        owner = .idle
        activeNodeID = nil
        startLocation = nil
        startedAt = nil
    }

    /// Finishes only the sequence/owner that supplied the callback.
    @discardableResult
    public mutating func finish(
        sequenceID expectedSequenceID: UInt64,
        owner expectedOwner: PlanningGestureOwner? = nil
    ) -> Bool {
        guard owns(sequenceID: expectedSequenceID, owner: expectedOwner) else { return false }
        end()
        return true
    }

    /// Escape, gesture cancellation, route disappearance, and context changes
    /// all use the same cancellation path.
    public mutating func cancel() {
        // Invalidate every callback captured by the cancelled physical
        // sequence. A subsequent begin call receives a new token immediately;
        // stale UIKit/AppKit end callbacks can therefore never close it.
        sequenceID &+= 1
        owner = .cancelled
        activeNodeID = nil
        startLocation = nil
        startedAt = nil
    }

    /// Cancels only the sequence/owner that supplied the callback.
    @discardableResult
    public mutating func cancel(
        sequenceID expectedSequenceID: UInt64,
        owner expectedOwner: PlanningGestureOwner? = nil
    ) -> Bool {
        guard owns(sequenceID: expectedSequenceID, owner: expectedOwner) else { return false }
        cancel()
        return true
    }

    /// Escape is a semantic alias kept for platform event bridges.
    public mutating func escape() {
        cancel()
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}
