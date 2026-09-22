import CoreGraphics
import Foundation

/// The affine viewport used by the planning canvas.
///
/// The transform is intentionally small and value typed so navigation can be
/// updated independently from document persistence. Screen coordinates are
/// expressed as `translation + scale * world`.
public struct PlanningCanvasViewport: Equatable, Sendable {
    public static let minimumScale: CGFloat = 0.25
    public static let maximumScale: CGFloat = 2.0

    public private(set) var translation: CGSize
    public private(set) var scale: CGFloat

    public init(translation: CGSize = .zero, scale: CGFloat = 1) {
        self.translation = .zero
        self.scale = 1
        guard Self.isFinite(translation), scale.isFinite else { return }
        self.translation = translation
        self.scale = Self.clampedScale(scale)
    }

    /// Converts a point from the screen coordinate space into world space.
    /// Invalid inputs return the origin and never mutate the viewport.
    public func worldPoint(screen: CGPoint) -> CGPoint {
        guard Self.isFinite(screen), scale.isFinite, scale > 0 else { return .zero }
        let x = (screen.x - translation.width) / scale
        let y = (screen.y - translation.height) / scale
        guard x.isFinite, y.isFinite else { return .zero }
        return CGPoint(x: x, y: y)
    }

    /// Converts a point from world space into the screen coordinate space.
    /// Invalid inputs return the origin and never mutate the viewport.
    public func screenPoint(world: CGPoint) -> CGPoint {
        guard Self.isFinite(world), scale.isFinite, scale > 0 else { return .zero }
        let x = translation.width + world.x * scale
        let y = translation.height + world.y * scale
        guard x.isFinite, y.isFinite else { return .zero }
        return CGPoint(x: x, y: y)
    }

    /// Translates the viewport without touching document state.
    public mutating func pan(by delta: CGSize) {
        guard Self.isFinite(delta), translation.width.isFinite, translation.height.isFinite else { return }
        let x = translation.width + delta.width
        let y = translation.height + delta.height
        guard x.isFinite, y.isFinite else { return }
        translation = CGSize(width: x, height: y)
    }

    /// Changes scale around a screen-space focal point while keeping the
    /// world-space point below that focal point fixed.
    public mutating func zoom(to requestedScale: CGFloat, around focal: CGPoint) {
        guard requestedScale.isFinite, Self.isFinite(focal), scale.isFinite, scale > 0 else { return }
        let nextScale = Self.clampedScale(requestedScale)
        let worldFocal = worldPoint(screen: focal)
        guard Self.isFinite(worldFocal) else { return }
        let nextX = focal.x - worldFocal.x * nextScale
        let nextY = focal.y - worldFocal.y * nextScale
        guard nextX.isFinite, nextY.isFinite else { return }
        scale = nextScale
        translation = CGSize(width: nextX, height: nextY)
    }

    /// Fits finite content into a finite viewport. Empty content resets to the
    /// identity transform; invalid viewport dimensions are ignored.
    public mutating func fit(bounds: CGRect, in size: CGSize, padding: CGFloat = 32) {
        if bounds.isNull {
            // CoreGraphics can mark malformed rectangles with an infinite
            // component as null as well. Only the canonical CGRect.null value
            // is the empty-content sentinel; malformed input remains a no-op.
            guard bounds == .null else { return }
            translation = .zero
            scale = 1
            return
        }
        guard Self.isFinite(bounds) else { return }
        guard Self.isFinite(size), size.width > 0, size.height > 0,
              padding.isFinite, padding >= 0 else { return }
        guard bounds.width > 0, bounds.height > 0 else {
            translation = .zero
            scale = 1
            return
        }

        let availableWidth = size.width - padding * 2
        let availableHeight = size.height - padding * 2
        guard availableWidth.isFinite, availableHeight.isFinite,
              availableWidth > 0, availableHeight > 0 else { return }

        let candidate = min(availableWidth / bounds.width, availableHeight / bounds.height)
        guard candidate.isFinite, candidate > 0 else { return }
        let fittedScale = Self.clampedScale(candidate)
        let centerX = size.width / 2 - bounds.midX * fittedScale
        let centerY = size.height / 2 - bounds.midY * fittedScale
        guard centerX.isFinite, centerY.isFinite else { return }
        scale = fittedScale
        translation = CGSize(width: centerX, height: centerY)
    }

    /// Returns the world rectangle visible in a screen viewport, expanded by
    /// an optional screen-space overscan.
    public func visibleWorldRect(in size: CGSize, overscan: CGFloat = 64) -> CGRect {
        guard Self.isFinite(size), size.width > 0, size.height > 0,
              overscan.isFinite, overscan >= 0 else { return .null }
        let topLeft = worldPoint(screen: CGPoint(x: -overscan, y: -overscan))
        let bottomRight = worldPoint(screen: CGPoint(
            x: size.width + overscan,
            y: size.height + overscan
        ))
        guard Self.isFinite(topLeft), Self.isFinite(bottomRight) else { return .null }
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    private static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumScale), maximumScale)
    }

    private static func isFinite(_ value: CGSize) -> Bool {
        value.width.isFinite && value.height.isFinite
    }

    private static func isFinite(_ value: CGPoint) -> Bool {
        value.x.isFinite && value.y.isFinite
    }

    private static func isFinite(_ value: CGRect) -> Bool {
        value.minX.isFinite && value.minY.isFinite
            && value.maxX.isFinite && value.maxY.isFinite
            && value.width.isFinite && value.height.isFinite
    }
}
