import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Tracks the identities that belong to a native touch sequence. UIKit may
/// deliver the end of an old multi-touch sequence after a later touch has
/// arrived, so cancelled live identities stay quarantined until their own end
/// or cancel callback is observed.
public struct PlanningCanvasTouchLifecycle: Equatable {
    public private(set) var activeTouchIDs: Set<ObjectIdentifier> = []
    public private(set) var sequenceTouchIDs: Set<ObjectIdentifier> = []
    public private(set) var quarantinedTouchIDs: Set<ObjectIdentifier> = []

    public init() {}

    public var isQuarantining: Bool { !quarantinedTouchIDs.isEmpty }

    public var canStartNewSequence: Bool {
        activeTouchIDs.isEmpty && sequenceTouchIDs.isEmpty && quarantinedTouchIDs.isEmpty
    }

    /// Admits new identities unless an older sequence is still draining. New
    /// identities arriving during that drain are tracked only in quarantine so
    /// they cannot accidentally become part of the next sequence.
    @discardableResult
    public mutating func begin(_ ids: Set<ObjectIdentifier>) -> Bool {
        guard !ids.isEmpty else { return false }
        guard !isQuarantining else {
            quarantinedTouchIDs.formUnion(ids)
            return false
        }
        activeTouchIDs.formUnion(ids)
        return true
    }

    public mutating func markSequence(_ ids: Set<ObjectIdentifier>) {
        activeTouchIDs.formUnion(ids)
        sequenceTouchIDs = ids
    }

    /// Ends only the identities delivered by UIKit. This must happen before
    /// any wrapper early return so a third touch that ends first can never be
    /// re-quarantined as if it were still live.
    public mutating func end(_ ids: Set<ObjectIdentifier>) {
        activeTouchIDs.subtract(ids)
        sequenceTouchIDs.subtract(ids)
        quarantinedTouchIDs.subtract(ids)
    }

    /// Cancels the current physical sequence and moves every still-live
    /// identity into the drain set. The wrapper can then clear its UIKit
    /// references without allowing a late callback to finish a new sequence.
    public mutating func cancelAndQuarantineLiveTouches() {
        quarantinedTouchIDs.formUnion(activeTouchIDs)
        activeTouchIDs.removeAll(keepingCapacity: false)
        sequenceTouchIDs.removeAll(keepingCapacity: false)
    }
}

/// Pure lifecycle state used by the AppKit input wrapper and its headless
/// regression tests. Window deactivation is equivalent to cancellation and
/// always clears a latched Space modifier.
public struct PlanningCanvasInputLifecycle: Equatable {
    public private(set) var isInputActive = false
    public private(set) var isSpacePressed = false

    public init() {}

    public mutating func beginInput() {
        isInputActive = true
    }

    public mutating func endInput() {
        isInputActive = false
    }

    public mutating func setSpacePressed(_ pressed: Bool) {
        isSpacePressed = pressed
    }

    public mutating func cancel(preservingSpace: Bool = false) {
        isInputActive = false
        if !preservingSpace {
            isSpacePressed = false
        }
    }

    public mutating func didResignKey() {
        cancel()
    }
}

/// Native SwiftUI Canvas surface for planning interactions.
/// Calendar/vault routing and node creation remain outside this component.
public struct PlanningCanvasView: View {
    @ObservedObject private var coordinator: PlanningProjectCoordinator
    @State private var viewport = PlanningCanvasViewport()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(coordinator: PlanningProjectCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        GeometryReader { proxy in
            let handlers = PlanningCanvasInputHandlers(
                nodeIDAtScreen: { screenPoint in
                    coordinator.nodeID(at: viewport.worldPoint(screen: screenPoint))
                },
                nodeIsLocked: { id in
                    coordinator.nodesByID[id]?.locked == true
                },
                onViewportChange: { nextViewport in
                    viewport = nextViewport
                },
                onBeginNodeDrag: { id, screenPoint in
                    coordinator.beginNodeDrag(
                        id: id,
                        at: viewport.worldPoint(screen: screenPoint),
                        scale: viewport.scale
                    )
                },
                onUpdateNodeDrag: { worldPoint in
                    coordinator.updateNodeDrag(to: worldPoint)
                },
                onCommitNodeDrag: {
                    commitNodeDrag()
                },
                onCancelNodeDrag: {
                    coordinator.cancelNodeDrag()
                },
                onSelectNode: { id in
                    coordinator.selectNode(id)
                }
            )

            ZStack(alignment: .topLeading) {
                canvas(in: proxy.size)
                PlanningCanvasInputOverlay(viewport: $viewport, handlers: handlers)
                    .accessibilityHidden(true)
                toolbar(in: proxy.size)
            }
            .background(LifeOSTokens.canvas)
            .onDisappear {
                coordinator.cancelNodeDrag()
            }
            .task {
                guard coordinator.document == nil else { return }
                do {
                    try await coordinator.open()
                } catch {
                    // open() records the error and failed state on the
                    // coordinator; the toolbar exposes the retry action.
                }
            }
        }
    }

    @ViewBuilder
    private func canvas(in size: CGSize) -> some View {
        let nodes = coordinator.visibleNodes(in: viewport, size: size)
        let edges = coordinator.visibleEdges(in: viewport, size: size)
        let hasDocument = coordinator.document != nil
        let hasNodes = coordinator.document?.nodes.isEmpty == false

        ZStack {
            Canvas { context, _ in
                context.translateBy(x: viewport.translation.width, y: viewport.translation.height)
                context.scaleBy(x: viewport.scale, y: viewport.scale)
                for edge in edges {
                    guard let first = edge.points.first, let last = edge.points.last else { continue }
                    var path = Path()
                    path.move(to: first)
                    path.addLine(to: last)
                    let edgeColor = canvasColor(edge.edge.color) ?? LifeOSTokens.metadataText
                    context.stroke(
                        path,
                        with: .color(edgeColor.opacity(edge.isIncidentToDraggedNode ? 0.95 : 0.72)),
                        lineWidth: max(1 / viewport.scale, 0.8)
                    )
                    if edge.edge.toEnd == "arrow" {
                        drawArrowHead(
                            in: &context,
                            at: last,
                            from: first,
                            color: edgeColor
                        )
                    }
                }
            }
            .allowsHitTesting(false)

            ForEach(nodes) { presentation in
                PlanningCanvasNodeCard(
                    presentation: presentation,
                    selected: coordinator.selectedNodeID == presentation.id,
                    scale: viewport.scale,
                    color: canvasColor(presentation.node.color)
                )
                .position(viewport.screenPoint(world: CGPoint(
                    x: presentation.bounds.midX,
                    y: presentation.bounds.midY
                )))
                .zIndex(
                    PlanningCanvasNodeGeometry.drawPriority(
                        for: presentation.node,
                        sourceIndex: presentation.sourceIndex
                    )
                )
            }

            if coordinator.document?.nodes.isEmpty == true, coordinator.status != .loading {
                emptyCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasDocument && hasNodes && nodes.isEmpty {
                offContentCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
    }

    private var emptyCanvas: some View {
        VStack(spacing: LifeOSTokens.Space.xs) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(LifeOSTokens.metadataText)
            Text(coordinator.status == .unavailable ? "Planning is unavailable" : "This canvas is empty")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LifeOSTokens.primaryText)
            Text(coordinator.status == .unavailable
                 ? "Select the vault again to continue."
                 : "Pan, pinch, or open a project to begin.")
                .font(.system(size: 13))
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
        .padding(LifeOSTokens.Space.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.card))
    }

    private var offContentCanvas: some View {
        Text("No nodes in this view")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LifeOSTokens.metadataText)
            .padding(.horizontal, LifeOSTokens.Space.sm)
            .padding(.vertical, LifeOSTokens.Space.xs)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func toolbar(in size: CGSize) -> some View {
        HStack(spacing: LifeOSTokens.Space.xs) {
            toolbarButton("arrow.up.left.and.arrow.down.right", label: "Fit") {
                fit(in: size)
            }
            toolbarButton("arrow.uturn.backward", label: "Undo") {
                runAsyncAction {
                    _ = try await coordinator.undo()
                }
            }
            toolbarButton("arrow.uturn.forward", label: "Redo") {
                runAsyncAction {
                    _ = try await coordinator.redo()
                }
            }
            if coordinator.retryMode != .none {
                toolbarButton(
                    "arrow.clockwise",
                    label: coordinator.retryMode == .open ? "Retry opening" : "Retry publication"
                ) {
                    runAsyncAction {
                        _ = try await coordinator.retry()
                    }
                }
            }
            Spacer(minLength: LifeOSTokens.Space.xs)
            statusView
        }
        .padding(.horizontal, LifeOSTokens.Space.sm)
        .padding(.vertical, LifeOSTokens.Space.xs)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(LifeOSTokens.Space.sm)
    }

    private var statusView: some View {
        HStack(spacing: LifeOSTokens.Space.xxs) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(coordinator.status.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LifeOSTokens.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(coordinator.lastError ?? "")
        .help(coordinator.lastError ?? coordinator.status.title)
    }

    private var statusColor: Color {
        switch coordinator.status {
        case .published, .savedLocally, .ready: return LifeOSTokens.success
        case .queued, .saving, .publishing: return LifeOSTokens.warning
        case .conflicted, .failed: return LifeOSTokens.danger
        case .unavailable, .loading, .idle: return LifeOSTokens.metadataText
        }
    }

    private func toolbarButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemName)
                .labelStyle(.iconOnly)
                .frame(width: LifeOSTokens.Control.iconButton, height: LifeOSTokens.Control.iconButton)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(LifeOSTokens.primaryText)
        .help(label)
        .accessibilityLabel(label)
    }

    private func fit(in size: CGSize) {
        var next = viewport
        next.fit(bounds: coordinator.fitBounds(), in: size, padding: 32)
        if reduceMotion {
            viewport = next
        } else {
            withAnimation(.snappy(duration: 0.22)) {
                viewport = next
            }
        }
    }

    private func commitNodeDrag() {
        runAsyncAction {
            _ = try await coordinator.commitNodeDrag()
        }
    }

    private func runAsyncAction(_ operation: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                // The coordinator has already retained the error, status, and
                // retry mode so the failure remains visible and actionable.
            }
        }
    }

    private func drawArrowHead(
        in context: inout GraphicsContext,
        at point: CGPoint,
        from previous: CGPoint,
        color: Color
    ) {
        let angle = atan2(point.y - previous.y, point.x - previous.x)
        let length: CGFloat = 8
        let spread: CGFloat = .pi / 7
        let first = CGPoint(
            x: point.x - cos(angle - spread) * length,
            y: point.y - sin(angle - spread) * length
        )
        let second = CGPoint(
            x: point.x - cos(angle + spread) * length,
            y: point.y - sin(angle + spread) * length
        )
        var arrow = Path()
        arrow.move(to: first)
        arrow.addLine(to: point)
        arrow.addLine(to: second)
        context.stroke(arrow, with: .color(color), lineWidth: 1.5)
    }

    private func canvasColor(_ raw: String?) -> Color? {
        guard let raw else { return nil }
        switch raw {
        case "1": return LifeOSTokens.danger
        case "2": return LifeOSTokens.warning
        case "3": return Color.lifeOSAmber400
        case "4": return LifeOSTokens.success
        case "5": return LifeOSTokens.info
        case "6": return Color.lifeOSViolet400
        default:
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard value.count == 6, let parsed = UInt32(value, radix: 16) else { return nil }
            return Color(hex: parsed)
        }
    }
}

private struct PlanningCanvasNodeCard: View {
    let presentation: PlanningCanvasNodePresentation
    let selected: Bool
    let scale: CGFloat
    let color: Color?

    var body: some View {
        let node = presentation.node
        let title = displayText(for: node)
        let fill = node.type == .group
            ? (color ?? LifeOSTokens.floatingOverlay).opacity(0.30)
            : (color ?? LifeOSTokens.surface)
        let border = selected ? LifeOSTokens.focusStroke : (color ?? LifeOSTokens.subtleBorder)
        let size = PlanningCanvasNodeGeometry.effectiveSize(for: node)
        let radius = min(12, min(size.width, size.height) * 0.18)

        VStack(alignment: .leading, spacing: 5) {
            if node.type == .file || node.type == .link {
                Image(systemName: node.type == .file ? "doc.text" : "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color ?? LifeOSTokens.accent)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LifeOSTokens.primaryText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(fill, in: RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(border.opacity(selected ? 1 : 0.7), lineWidth: selected ? 2 : 1)
        )
        .shadow(color: .black.opacity(node.type == .group ? 0 : 0.12), radius: 8, y: 3)
        .scaleEffect(scale)
        .opacity(presentation.isDragged ? 0.92 : 1)
    }

    private func displayText(for node: PlanningCanvasNode) -> String {
        let value = node.text ?? node.label ?? node.file ?? node.url ?? "Untitled"
        let bounded = String(value.prefix(240))
        return bounded.isEmpty ? "Untitled" : bounded
    }
}

private struct PlanningCanvasInputHandlers {
    let nodeIDAtScreen: (CGPoint) -> String?
    let nodeIsLocked: (String) -> Bool
    let onViewportChange: (PlanningCanvasViewport) -> Void
    let onBeginNodeDrag: (String, CGPoint) -> Bool
    let onUpdateNodeDrag: (CGPoint) -> Void
    let onCommitNodeDrag: () -> Void
    let onCancelNodeDrag: () -> Void
    let onSelectNode: (String) -> Void
}

private struct PlanningCanvasInputOverlay: View {
    @Binding var viewport: PlanningCanvasViewport
    let handlers: PlanningCanvasInputHandlers

    var body: some View {
#if os(macOS)
        PlanningCanvasMacInputRepresentable(viewport: viewport, handlers: handlers)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#elseif os(iOS)
        PlanningCanvasIOSInputRepresentable(viewport: viewport, handlers: handlers)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        Color.clear
#endif
    }
}

#if os(macOS)
private struct PlanningCanvasMacInputRepresentable: NSViewRepresentable {
    let viewport: PlanningCanvasViewport
    let handlers: PlanningCanvasInputHandlers

    func makeNSView(context: Context) -> PlanningCanvasMacInputView {
        PlanningCanvasMacInputView(viewport: viewport, handlers: handlers)
    }

    func updateNSView(_ nsView: PlanningCanvasMacInputView, context: Context) {
        nsView.apply(viewport: viewport, handlers: handlers)
    }

    static func dismantleNSView(_ nsView: PlanningCanvasMacInputView, coordinator: ()) {
        nsView.removeWindowResignKeyObserver()
        nsView.cancelActiveInput()
    }
}

private final class PlanningCanvasMacInputView: NSView {
    private var viewport: PlanningCanvasViewport
    private var handlers: PlanningCanvasInputHandlers
    private var gestureBridge = PlanningGestureBridge(platform: .macOS)
    private var pointerSequenceID: UInt64?
    private var pointerOwner: PlanningGestureOwner?
    private var scrollSequenceID: UInt64?
    private var magnifySequenceID: UInt64?
    private var lastPointerLocation: CGPoint?
    private var magnificationStartScale: CGFloat = 1
    private var magnificationFactor: CGFloat = 1
    private var magnificationFocalPoint: CGPoint = .zero
    private var inputLifecycle = PlanningCanvasInputLifecycle()
    private var windowResignKeyObserver: NSObjectProtocol?

    private var spaceIsPressed: Bool { inputLifecycle.isSpacePressed }

    init(viewport: PlanningCanvasViewport, handlers: PlanningCanvasInputHandlers) {
        self.viewport = viewport
        self.handlers = handlers
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    deinit {
        removeWindowResignKeyObserver()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func apply(viewport: PlanningCanvasViewport, handlers: PlanningCanvasInputHandlers) {
        self.viewport = viewport
        self.handlers = handlers
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A mouse-down is a sequence reset, not a focus-loss cancellation.
        // Preserve a Space key that is already held so Space+drag over a node
        // is always interpreted as navigation.
        let heldSpace = spaceIsPressed
        cancelActiveInput(preserveSpace: heldSpace)
        inputLifecycle.beginInput()
        let location = convert(event.locationInWindow, from: nil)
        let nodeID = handlers.nodeIDAtScreen(location)
        let owner = gestureBridge.beginPointer(
            at: location,
            nodeID: nodeID,
            nodeLocked: nodeID.map(handlers.nodeIsLocked) ?? false,
            spacePressed: spacePressed(in: event),
            timestamp: event.timestamp
        )
        pointerSequenceID = gestureBridge.sequenceID
        pointerOwner = owner
        lastPointerLocation = location

        switch owner {
        case .nodeDrag:
            guard let nodeID, handlers.onBeginNodeDrag(nodeID, location) else {
                handlers.onSelectNode(nodeID ?? "")
                cancelActiveInput()
                return
            }
        case .selection:
            if let nodeID { handlers.onSelectNode(nodeID) }
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let sequence = pointerSequenceID,
              let owner = pointerOwner,
              gestureBridge.owns(sequenceID: sequence, owner: owner) else { return }
        let location = convert(event.locationInWindow, from: nil)
        switch owner {
        case .nodeDrag:
            handlers.onUpdateNodeDrag(viewport.worldPoint(screen: location))
        case .pan, .spacePan:
            guard let previous = lastPointerLocation else {
                lastPointerLocation = location
                return
            }
            var nextViewport = viewport
            nextViewport.pan(by: CGSize(
                width: location.x - previous.x,
                height: location.y - previous.y
            ))
            viewport = nextViewport
            handlers.onViewportChange(nextViewport)
            lastPointerLocation = location
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        finishPointerSequence()
    }

    override func scrollWheel(with event: NSEvent) {
        // A wheel sequence is independent from a mouse sequence. Never let a
        // scroll event reuse or terminate a pointer-owned pan/drag.
        guard pointerSequenceID == nil, magnifySequenceID == nil else {
            return
        }
        if scrollSequenceID == nil {
            guard gestureBridge.owner == .idle || gestureBridge.owner == .cancelled else { return }
            let location = convert(event.locationInWindow, from: nil)
            guard gestureBridge.beginPan(at: location, timestamp: event.timestamp) == .pan else { return }
            scrollSequenceID = gestureBridge.sequenceID
            inputLifecycle.beginInput()
        }
        guard let sequence = scrollSequenceID,
              gestureBridge.owns(sequenceID: sequence, owner: .pan) else { return }

        var nextViewport = viewport
        nextViewport.pan(by: CGSize(
            width: event.scrollingDeltaX,
            height: event.scrollingDeltaY
        ))
        viewport = nextViewport
        handlers.onViewportChange(nextViewport)

        if event.phase.isEmpty || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            _ = gestureBridge.finish(sequenceID: sequence, owner: .pan)
            scrollSequenceID = nil
            inputLifecycle.endInput()
        }
    }

    override func magnify(with event: NSEvent) {
        // Magnification owns its own token. A mouse-up or wheel event can
        // never finish this sequence by observing shared active state.
        guard pointerSequenceID == nil, scrollSequenceID == nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        if magnifySequenceID == nil {
            guard gestureBridge.owner == .idle || gestureBridge.owner == .cancelled else { return }
            guard gestureBridge.beginZoom(at: location, timestamp: event.timestamp) == .zoom else { return }
            magnifySequenceID = gestureBridge.sequenceID
            inputLifecycle.beginInput()
            magnificationStartScale = viewport.scale
            magnificationFactor = 1
            magnificationFocalPoint = location
        }
        guard let sequence = magnifySequenceID,
              gestureBridge.owns(sequenceID: sequence, owner: .zoom) else { return }

        magnificationFactor *= max(0.01, 1 + event.magnification)
        var nextViewport = viewport
        nextViewport.zoom(
            to: magnificationStartScale * magnificationFactor,
            around: magnificationFocalPoint
        )
        viewport = nextViewport
        handlers.onViewportChange(nextViewport)

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            _ = gestureBridge.finish(sequenceID: sequence, owner: .zoom)
            magnifySequenceID = nil
            inputLifecycle.endInput()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelActiveInput()
            return
        }
        if event.keyCode == 49 {
            inputLifecycle.setSpacePressed(true)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            inputLifecycle.setSpacePressed(false)
            return
        }
        super.keyUp(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        cancelActiveInput()
    }

    override func viewDidMoveToWindow() {
        removeWindowResignKeyObserver()
        super.viewDidMoveToWindow()
        guard let window else {
            cancelActiveInput()
            return
        }
        windowResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowDidResignKey()
        }
    }

    override func resignFirstResponder() -> Bool {
        cancelActiveInput()
        return super.resignFirstResponder()
    }

    func cancelActiveInput(preserveSpace: Bool = false) {
        if pointerOwner == .nodeDrag {
            handlers.onCancelNodeDrag()
        }
        if gestureBridge.isActive {
            gestureBridge.cancel()
        }
        pointerSequenceID = nil
        pointerOwner = nil
        scrollSequenceID = nil
        magnifySequenceID = nil
        lastPointerLocation = nil
        inputLifecycle.cancel(preservingSpace: preserveSpace)
    }

    private func finishPointerSequence() {
        guard let owner = pointerOwner, let sequence = pointerSequenceID else { return }
        guard gestureBridge.owns(sequenceID: sequence, owner: owner) else {
            pointerSequenceID = nil
            pointerOwner = nil
            lastPointerLocation = nil
            inputLifecycle.endInput()
            return
        }
        _ = gestureBridge.finish(sequenceID: sequence, owner: owner)
        switch owner {
        case .nodeDrag:
            handlers.onCommitNodeDrag()
        case .selection:
            break
        default:
            break
        }
        pointerSequenceID = nil
        pointerOwner = nil
        lastPointerLocation = nil
        inputLifecycle.endInput()
    }

    private func spacePressed(in event: NSEvent) -> Bool {
        _ = event
        return spaceIsPressed
    }

    func removeWindowResignKeyObserver() {
        if let windowResignKeyObserver {
            NotificationCenter.default.removeObserver(windowResignKeyObserver)
            self.windowResignKeyObserver = nil
        }
    }

    private func handleWindowDidResignKey() {
        inputLifecycle.didResignKey()
        cancelActiveInput()
    }
}
#endif

#if os(iOS)
private struct PlanningCanvasIOSInputRepresentable: UIViewRepresentable {
    let viewport: PlanningCanvasViewport
    let handlers: PlanningCanvasInputHandlers

    func makeUIView(context: Context) -> PlanningCanvasIOSInputView {
        PlanningCanvasIOSInputView(viewport: viewport, handlers: handlers)
    }

    func updateUIView(_ uiView: PlanningCanvasIOSInputView, context: Context) {
        uiView.apply(viewport: viewport, handlers: handlers)
    }

    static func dismantleUIView(_ uiView: PlanningCanvasIOSInputView, coordinator: ()) {
        uiView.cancelActiveInput()
    }
}

private final class PlanningCanvasIOSInputView: UIView {
    private var viewport: PlanningCanvasViewport
    private var handlers: PlanningCanvasInputHandlers
    private var gestureBridge = PlanningGestureBridge(platform: .iOS)
    private var activeSequenceID: UInt64?
    private var activeOwner: PlanningGestureOwner?
    private var activeTouches: [ObjectIdentifier: UITouch] = [:]
    private var activeSequenceTouchIDs: Set<ObjectIdentifier> = []
    private var touchLifecycle = PlanningCanvasTouchLifecycle()
    private var firstTouchLocation: CGPoint = .zero
    private var lastSingleLocation: CGPoint = .zero
    private var longPressWork: DispatchWorkItem?
    private var twoFingerStartDistance: CGFloat = 0
    private var twoFingerStartScale: CGFloat = 1
    private var twoFingerLastCentroid: CGPoint = .zero

    init(viewport: PlanningCanvasViewport, handlers: PlanningCanvasInputHandlers) {
        self.viewport = viewport
        self.handlers = handlers
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(viewport: PlanningCanvasViewport, handlers: PlanningCanvasInputHandlers) {
        self.viewport = viewport
        self.handlers = handlers
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let incomingIDs = Set(touches.map(ObjectIdentifier.init))
        guard touchLifecycle.begin(incomingIDs) else { return }
        for touch in touches {
            activeTouches[ObjectIdentifier(touch)] = touch
        }
        if activeTouches.count > 2 {
            // An extra finger invalidates the current gesture. Quarantine all
            // identities that are still physically down, including the new
            // finger, so none can terminate a later sequence.
            cancelActiveInput()
            return
        }
        if activeTouches.count == 1, let touch = activeTouches.values.first {
            beginSingleTouch(touch)
        } else if activeTouches.count == 2 {
            activeSequenceTouchIDs = Set(activeTouches.keys)
            touchLifecycle.markSequence(activeSequenceTouchIDs)
            beginTwoFingerSequence()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.count >= 2 {
            updateTwoFingerSequence()
            return
        }
        guard let touch = activeTouches.values.first,
              let sequence = activeSequenceID,
              let owner = activeOwner,
              gestureBridge.owns(sequenceID: sequence, owner: owner) else { return }

        let location = touch.location(in: self)
        let timestamp = touch.timestamp
        let previousLocation = lastSingleLocation
        lastSingleLocation = location

        let previousOwner = gestureBridge.owner
        let nextOwner = gestureBridge.movePointer(
            to: location,
            timestamp: timestamp,
            touchCount: activeTouches.count
        )
        // The bridge transition and the wrapper’s cached owner form one
        // state transition. End/cancel callbacks must observe the new owner,
        // never the pending owner that caused the promotion.
        activeOwner = nextOwner
        if previousOwner == .pendingNodeLongPress && nextOwner == .pan {
            longPressWork?.cancel()
            handlers.onCancelNodeDrag()
        }
        if previousOwner == .pendingNodeLongPress && nextOwner == .nodeDrag {
            guard beginPendingNodeDrag(at: location) else { return }
        }

        guard activeOwner == nextOwner,
              gestureBridge.owns(sequenceID: sequence, owner: nextOwner) else { return }

        switch nextOwner {
        case .pan:
            applyPan(delta: CGSize(
                width: location.x - previousLocation.x,
                height: location.y - previousLocation.y
            ))
        case .nodeDrag:
            handlers.onUpdateNodeDrag(viewport.worldPoint(screen: location))
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let endedIDs = Set(touches.map(ObjectIdentifier.init))
        let endingCurrentIDs = endedIDs.intersection(activeSequenceTouchIDs)
        let hadMultipleTouches = activeSequenceTouchIDs.count >= 2
        for touch in touches {
            activeTouches.removeValue(forKey: ObjectIdentifier(touch))
        }
        activeSequenceTouchIDs.subtract(endedIDs)
        touchLifecycle.end(endedIDs)

        if touchLifecycle.isQuarantining { return }
        guard !endingCurrentIDs.isEmpty else { return }

        if hadMultipleTouches {
            touchLifecycle.cancelAndQuarantineLiveTouches()
            finishCurrentSequence()
            clearTouchState()
            return
        }

        guard let sequence = activeSequenceID,
              let owner = activeOwner,
              gestureBridge.owns(sequenceID: sequence, owner: owner) else {
            activeTouches.removeAll(keepingCapacity: false)
            return
        }

        longPressWork?.cancel()
        longPressWork = nil
        let selectedNodeID = gestureBridge.activeNodeID
        guard gestureBridge.finish(sequenceID: sequence, owner: owner) else {
            clearTouchState()
            return
        }
        switch owner {
        case .pendingNodeLongPress, .selection:
            if let selectedNodeID {
                handlers.onSelectNode(selectedNodeID)
            }
        case .nodeDrag:
            handlers.onCommitNodeDrag()
        default:
            break
        }
        activeSequenceID = nil
        activeOwner = nil
        clearTouchState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let cancelledIDs = Set(touches.map(ObjectIdentifier.init))
        cancelActiveInput()
        touchLifecycle.end(cancelledIDs)
        clearTouchState()
    }

    func cancelActiveInput() {
        longPressWork?.cancel()
        longPressWork = nil
        if let owner = activeOwner, let sequence = activeSequenceID {
            if owner == .nodeDrag {
                handlers.onCancelNodeDrag()
            }
            if !gestureBridge.cancel(sequenceID: sequence, owner: owner), gestureBridge.isActive {
                gestureBridge.cancel()
            }
        } else if gestureBridge.isActive {
            handlers.onCancelNodeDrag()
            gestureBridge.cancel()
        }
        activeSequenceID = nil
        activeOwner = nil
        touchLifecycle.cancelAndQuarantineLiveTouches()
        activeTouches.removeAll(keepingCapacity: false)
        activeSequenceTouchIDs.removeAll(keepingCapacity: false)
        twoFingerStartDistance = 0
        twoFingerLastCentroid = .zero
        lastSingleLocation = .zero
        firstTouchLocation = .zero
    }

    private func beginSingleTouch(_ touch: UITouch) {
        let location = touch.location(in: self)
        firstTouchLocation = location
        lastSingleLocation = location
        let nodeID = handlers.nodeIDAtScreen(location)
        let owner = gestureBridge.beginPointer(
            at: location,
            nodeID: nodeID,
            nodeLocked: nodeID.map(handlers.nodeIsLocked) ?? false,
            touchCount: 1,
            timestamp: touch.timestamp
        )
        activeSequenceID = gestureBridge.sequenceID
        activeOwner = owner
        activeSequenceTouchIDs = [ObjectIdentifier(touch)]
        touchLifecycle.markSequence(activeSequenceTouchIDs)

        if owner == .selection, let nodeID {
            handlers.onSelectNode(nodeID)
        }
        if owner == .pendingNodeLongPress {
            scheduleLongPress(for: touch)
        }
    }

    @discardableResult
    private func beginPendingNodeDrag(at location: CGPoint) -> Bool {
        guard let nodeID = gestureBridge.activeNodeID,
              handlers.onBeginNodeDrag(nodeID, firstTouchLocation) else {
            cancelActiveInput()
            return false
        }
        handlers.onUpdateNodeDrag(viewport.worldPoint(screen: location))
        return true
    }

    private func scheduleLongPress(for touch: UITouch) {
        let sequence = gestureBridge.sequenceID
        let touchID = ObjectIdentifier(touch)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeTouches.count == 1,
                  self.activeSequenceID == sequence,
                  self.activeOwner == .pendingNodeLongPress,
                  self.gestureBridge.owns(sequenceID: sequence, owner: .pendingNodeLongPress),
                  let currentTouch = self.activeTouches[touchID] else { return }
            let previousOwner = self.gestureBridge.owner
            let owner = self.gestureBridge.movePointer(
                to: currentTouch.location(in: self),
                timestamp: max(
                    currentTouch.timestamp,
                    touch.timestamp + PlanningGestureBridge.nodeLongPressDelay
                ),
                touchCount: 1
            )
            guard previousOwner == .pendingNodeLongPress, owner == .nodeDrag else { return }
            self.activeOwner = owner
            _ = self.beginPendingNodeDrag(at: currentTouch.location(in: self))
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + PlanningGestureBridge.nodeLongPressDelay,
            execute: work
        )
    }

    private func beginTwoFingerSequence() {
        longPressWork?.cancel()
        guard let pair = currentTouchPair() else { return }
        let focal = CGPoint(
            x: (pair.0.location.x + pair.1.location.x) / 2,
            y: (pair.0.location.y + pair.1.location.y) / 2
        )
        if activeOwner == .nodeDrag {
            handlers.onCancelNodeDrag()
        }
        let timestamp = max(pair.0.timestamp, pair.1.timestamp)
        let owner: PlanningGestureOwner
        if gestureBridge.isActive {
            owner = gestureBridge.promoteToZoom(
                at: focal,
                timestamp: timestamp,
                sequenceID: activeSequenceID
            )
        } else {
            owner = gestureBridge.beginZoom(at: focal, timestamp: timestamp)
            activeSequenceID = gestureBridge.sequenceID
        }
        guard owner == .zoom else { return }
        activeOwner = .zoom
        twoFingerStartDistance = max(pair.0.location.distance(to: pair.1.location), 0.001)
        twoFingerStartScale = viewport.scale
        twoFingerLastCentroid = focal
    }

    private func updateTwoFingerSequence() {
        guard let pair = currentTouchPair(),
              let sequence = activeSequenceID,
              gestureBridge.owns(sequenceID: sequence, owner: .zoom) else { return }
        let focal = CGPoint(
            x: (pair.0.location.x + pair.1.location.x) / 2,
            y: (pair.0.location.y + pair.1.location.y) / 2
        )
        let distance = max(pair.0.location.distance(to: pair.1.location), 0.001)
        let factor = distance / twoFingerStartDistance
        var nextViewport = viewport
        nextViewport.pan(by: CGSize(
            width: focal.x - twoFingerLastCentroid.x,
            height: focal.y - twoFingerLastCentroid.y
        ))
        nextViewport.zoom(
            to: twoFingerStartScale * factor,
            around: focal
        )
        viewport = nextViewport
        handlers.onViewportChange(nextViewport)
        twoFingerLastCentroid = focal
    }

    private func finishCurrentSequence() {
        longPressWork?.cancel()
        longPressWork = nil
        if let owner = activeOwner, let sequence = activeSequenceID {
            if owner == .nodeDrag {
                handlers.onCancelNodeDrag()
            }
            if !gestureBridge.finish(sequenceID: sequence, owner: owner), gestureBridge.isActive {
                gestureBridge.cancel()
            }
        }
        activeSequenceID = nil
        activeOwner = nil
        activeSequenceTouchIDs.removeAll(keepingCapacity: false)
        twoFingerStartDistance = 0
        twoFingerLastCentroid = .zero
    }

    private func applyPan(delta: CGSize) {
        var nextViewport = viewport
        nextViewport.pan(by: delta)
        viewport = nextViewport
        handlers.onViewportChange(nextViewport)
    }

    private func currentTouchPair() -> ((location: CGPoint, timestamp: TimeInterval), (location: CGPoint, timestamp: TimeInterval))? {
        guard activeTouches.count >= 2 else { return nil }
        let touches = activeTouches.values.prefix(2).map { touch in
            (location: touch.location(in: self), timestamp: touch.timestamp)
        }
        guard touches.count == 2 else { return nil }
        return (touches[0], touches[1])
    }

    private func clearTouchState() {
        activeTouches.removeAll(keepingCapacity: false)
        activeSequenceTouchIDs.removeAll(keepingCapacity: false)
        firstTouchLocation = .zero
        lastSingleLocation = .zero
    }
}
#endif

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
