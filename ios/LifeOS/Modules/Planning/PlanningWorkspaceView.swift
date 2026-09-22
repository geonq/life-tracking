import SwiftUI

#if os(macOS)
import AppKit
private typealias PlanningWorkspaceNativePresenter = NSWindow
#elseif os(iOS)
import UIKit
private typealias PlanningWorkspaceNativePresenter = UIViewController
#endif

/// Holds the native picker presenter without publishing SwiftUI state changes.
/// The owner token prevents stale representable teardown from clearing a newer
/// representable instance's presenter.
@MainActor
internal final class PlanningWorkspacePresenterReference<Object: AnyObject> {
    private(set) weak var value: Object?
    private(set) var ownerID: UUID?

    @discardableResult
    internal func attach(_ value: Object, ownerID: UUID) -> Bool {
        guard self.ownerID != ownerID || self.value !== value else { return false }
        self.value = value
        self.ownerID = ownerID
        return true
    }

    @discardableResult
    internal func detach(ownerID: UUID) -> Bool {
        guard self.ownerID == ownerID else { return false }
        value = nil
        self.ownerID = nil
        return true
    }
}

#if DEBUG
/// Instance-scoped control and observation for mounted workspace evidence.
///
/// The probe owns no workspace state. It only invokes the view's existing
/// action and records lifecycle transitions emitted by that view instance.
@MainActor
internal final class PlanningWorkspacePresentationProbe {
#if os(iOS)
    internal typealias DocumentSelectionHandler =
        (UIViewController) async throws -> PlanningUserSelectedDocument?
#elseif os(macOS)
    internal typealias DocumentSelectionHandler =
        (NSWindow?) async throws -> PlanningUserSelectedDocument?
#endif

    internal let viewportProbe: PlanningCanvasViewportProbe?
    internal var controlledDocumentSelection: DocumentSelectionHandler?

    internal private(set) var isMounted = false
    internal private(set) var isPickerTaskActive = false
    internal private(set) var activePickerGeneration: UUID?
    internal private(set) var currentPickerError: String?
    internal private(set) var isPresenterReady = false
    internal private(set) var isInspectorPresented = false
    internal private(set) var mountCount = 0
    internal private(set) var unmountCount = 0

    internal var onMount: (() -> Void)?
    internal var onUnmount: (() -> Void)?
    internal var onPickerTaskStart: ((UUID) -> Void)?
    internal var onPickerTaskFinish: ((UUID) -> Void)?
    internal var onPickerErrorChange: ((String?) -> Void)?
    internal var onPresenterReadyChange: ((Bool) -> Void)?
    internal var onInspectorPresentedChange: ((Bool) -> Void)?

    private var ownerID: UUID?
    private var chooseDocumentAction: (() -> Void)?

    internal init(viewportProbe: PlanningCanvasViewportProbe? = nil) {
        self.viewportProbe = viewportProbe
    }

    internal func chooseDocument() {
        chooseDocumentAction?()
    }

    internal func bind(
        ownerID: UUID,
        currentPickerError: String?,
        presenterReady: Bool,
        inspectorPresented: Bool,
        chooseDocument: @escaping () -> Void
    ) {
        let ownerChanged = self.ownerID != ownerID
        let wasMounted = isMounted
        self.ownerID = ownerID
        self.chooseDocumentAction = chooseDocument
        self.currentPickerError = currentPickerError
        self.isPresenterReady = presenterReady
        self.isInspectorPresented = inspectorPresented
        if ownerChanged {
            isPickerTaskActive = false
            activePickerGeneration = nil
        }
        isMounted = true
        if !wasMounted || ownerChanged {
            mountCount += 1
            onMount?()
        }
    }

    internal func unbind(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        self.ownerID = nil
        chooseDocumentAction = nil
        let wasMounted = isMounted
        isMounted = false
        currentPickerError = nil
        isPresenterReady = false
        isInspectorPresented = false
        if wasMounted {
            unmountCount += 1
            onUnmount?()
        }
    }

    internal func updatePickerError(_ error: String?, ownerID: UUID) {
        guard self.ownerID == ownerID, currentPickerError != error else { return }
        currentPickerError = error
        onPickerErrorChange?(error)
    }

    internal func updatePresenterReady(_ ready: Bool, ownerID: UUID) {
        guard self.ownerID == ownerID, isPresenterReady != ready else { return }
        isPresenterReady = ready
        onPresenterReadyChange?(ready)
    }

    internal func updateInspectorPresented(_ presented: Bool, ownerID: UUID) {
        guard self.ownerID == ownerID, isInspectorPresented != presented else { return }
        isInspectorPresented = presented
        onInspectorPresentedChange?(presented)
    }

    internal func pickerTaskDidStart(_ generation: UUID, ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        isPickerTaskActive = true
        activePickerGeneration = generation
        onPickerTaskStart?(generation)
    }

    internal func pickerTaskDidFinish(_ generation: UUID, ownerID: UUID) {
        guard activePickerGeneration == generation,
              self.ownerID == ownerID || self.ownerID == nil else { return }
        isPickerTaskActive = false
        activePickerGeneration = nil
        onPickerTaskFinish?(generation)
    }
}
#endif

/// Native entry surface for an existing Obsidian-backed Canvas. This view
/// never creates a vault or writes a Canvas; those capabilities remain behind
/// the separately reviewed storage boundary.
public struct PlanningWorkspaceView: View {
    @ObservedObject private var coordinator: PlanningWorkspaceCoordinator
    private let onDone: (() -> Void)?

    @State private var pickerError: String?
    @State private var pickerTask: Task<Void, Never>?
    @State private var pickerGeneration = UUID()
    @State private var activeDocumentTicket: PlanningDocumentSelectionTicket?
#if DEBUG
    private let presentationProbe: PlanningWorkspacePresentationProbe?
    @State private var presentationProbeOwnerID = UUID()
#endif
    @State private var presenterReference =
        PlanningWorkspacePresenterReference<PlanningWorkspaceNativePresenter>()

    public init(
        coordinator: PlanningWorkspaceCoordinator,
        onDone: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.onDone = onDone
#if DEBUG
        self.presentationProbe = nil
#endif
    }

#if DEBUG
    internal init(
        coordinator: PlanningWorkspaceCoordinator,
        onDone: (() -> Void)? = nil,
        presentationProbe: PlanningWorkspacePresentationProbe?
    ) {
        self.coordinator = coordinator
        self.onDone = onDone
        self.presentationProbe = presentationProbe
    }
#endif

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(LifeOSTokens.canvas)
#if os(iOS)
        .background {
            PlanningWorkspacePresenterBridge { presenter, ownerID in
                updateNativePresenter(presenter, ownerID: ownerID)
            }
            .frame(width: 0, height: 0)
        }
#elseif os(macOS)
        .background {
            PlanningWorkspaceWindowBridge { window, ownerID in
                updateNativePresenter(window, ownerID: ownerID)
            }
            .frame(width: 0, height: 0)
        }
#endif
        .onChange(of: coordinator.isInspectorPresented) { _, presented in
#if DEBUG
            presentationProbe?.updateInspectorPresented(
                presented,
                ownerID: presentationProbeOwnerID
            )
#endif
        }
        .onAppear {
#if DEBUG
            presentationProbe?.bind(
                ownerID: presentationProbeOwnerID,
                currentPickerError: pickerError,
                presenterReady: presenterReference.value != nil,
                inspectorPresented: coordinator.isInspectorPresented,
                chooseDocument: { chooseDocument() }
            )
#endif
            coordinator.requestMount()
        }
        .onDisappear {
            cancelPickerPresentation()
#if DEBUG
            presentationProbe?.unbind(ownerID: presentationProbeOwnerID)
#endif
            coordinator.requestUnmount()
        }
    }

    private var header: some View {
        HStack(spacing: LifeOSTokens.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Planning")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text(coordinator.openedPath.map { "LifeOS/\($0.value)" } ?? "Obsidian Canvas")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: LifeOSTokens.Space.sm)
            if coordinator.phase == .showingCanvas {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(LifeOSTokens.surface, in: Capsule())
            }
            Button("Done") {
                cancelPickerPresentation()
                coordinator.closeDocument()
                onDone?()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("planning-done")
        }
        .padding(.horizontal, LifeOSTokens.Space.lg)
        .padding(.vertical, LifeOSTokens.Space.sm)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle, .restoring, .attaching, .opening:
            progressState
        case .unselected:
            vaultSelectionState(
                title: "Choose Obsidian vault",
                message: "Select an existing LifeOS-enabled vault to open a Canvas.",
                buttonTitle: "Choose vault"
            )
        case .needsReselection:
            vaultSelectionState(
                title: "Choose vault again",
                message: "The previous vault grant is unavailable or changed.",
                buttonTitle: "Choose another vault"
            )
        case .ready:
            if coordinator.isInspectorPresented {
                PlanningWorkspaceInspectorView(workspace: coordinator)
            } else {
                canvasPathState
            }
        case .showingCanvas:
            canvasState
        case .unavailable:
            failureState(
                title: "Planning unavailable",
                message: coordinator.lastError ?? "The selected Canvas is temporarily unavailable."
            )
        case .failed:
            failureState(
                title: "Canvas could not be opened",
                message: coordinator.lastError ?? "Choose another Canvas or try again."
            )
        }
    }

    private var progressState: some View {
        VStack(spacing: LifeOSTokens.Space.sm) {
            ProgressView()
            Text(coordinator.phase == .opening ? "Opening Canvas…" : "Checking planning access…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("planning-progress")
    }

    private func vaultSelectionState(
        title: String,
        message: String,
        buttonTitle: String
    ) -> some View {
        VStack(spacing: LifeOSTokens.Space.md) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(LifeOSTokens.accent)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LifeOSTokens.primaryText)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(LifeOSTokens.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(buttonTitle, action: chooseVault)
                .buttonStyle(.borderedProminent)
                .disabled(pickerTask != nil)
                .accessibilityIdentifier("planning-choose-vault")
            if let pickerError = pickerError ?? coordinator.lastError {
                Text(pickerError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("planning-picker-error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LifeOSTokens.Space.xl)
    }

    private var canvasPathState: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Open a Canvas")
                    .font(.system(size: 20, weight: .semibold))
                Text("Choose a relative path inside LifeOS/. Existing files open read-only.")
                    .font(.system(size: 14))
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }

            HStack(spacing: 0) {
                Text("LifeOS/")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .padding(.leading, 12)
                TextField("Projects/Personal.canvas", text: $coordinator.pathInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("planning-canvas-path")
            }
            .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
            }

            HStack(spacing: LifeOSTokens.Space.sm) {
                Button("Open Canvas") {
                    Task { await coordinator.openCanvas(relativePath: coordinator.pathInput) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    pickerTask != nil ||
                    coordinator.pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("planning-open-canvas")

                Button("Choose document", action: chooseDocument)
                    .buttonStyle(.bordered)
                    .disabled(pickerTask != nil)
                    .accessibilityIdentifier("planning-choose-document")

                Button("Change vault", action: chooseVault)
                    .buttonStyle(.bordered)
                    .disabled(pickerTask != nil)
                    .accessibilityIdentifier("planning-change-vault")
            }

            if let pickerError = pickerError ?? coordinator.lastError {
                Text(pickerError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.danger)
                    .accessibilityIdentifier("planning-picker-error")
                if coordinator.canRetryDocumentSelection {
                    Button("Retry") { Task { await coordinator.retry() } }
                        .disabled(pickerTask != nil)
                        .accessibilityIdentifier("planning-document-retry")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(LifeOSTokens.Space.xl)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var canvasState: some View {
        if let project = coordinator.project {
            VStack(spacing: 0) {
                HStack(spacing: LifeOSTokens.Space.sm) {
                    Text(coordinator.openedPath.map { "LifeOS/\($0.value)" } ?? "Canvas")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    if project.status == .unavailable {
                        Label("Stale or unavailable", systemImage: "icloud.slash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LifeOSTokens.warning)
                    }
                    Button("Choose document", action: chooseDocument)
                        .buttonStyle(.borderless)
                        .disabled(pickerTask != nil)
                        .accessibilityIdentifier("planning-change-document")
                }
                .padding(.horizontal, LifeOSTokens.Space.md)
                .padding(.vertical, LifeOSTokens.Space.xs)
                if let error = pickerError ?? coordinator.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(LifeOSTokens.danger)
                        .accessibilityIdentifier("planning-picker-error")
                    if coordinator.canRetryDocumentSelection {
                        Button("Retry") { Task { await coordinator.retry() } }
                            .disabled(pickerTask != nil)
                            .accessibilityIdentifier("planning-document-retry")
                    }
                }
                canvasContent(for: project)
                    .accessibilityIdentifier("planning-workspace-canvas")
            }
        } else {
            progressState
        }
    }

    private func failureState(title: String, message: String) -> some View {
        VStack(spacing: LifeOSTokens.Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(LifeOSTokens.warning)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(LifeOSTokens.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let pickerError {
                Text(pickerError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .accessibilityIdentifier("planning-picker-error")
            }
            HStack(spacing: 0) {
                Text("LifeOS/")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .padding(.leading, 12)
                TextField("Projects/Personal.canvas", text: $coordinator.pathInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("planning-failure-canvas-path")
            }
            .frame(maxWidth: 440)
            .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
            }
            HStack(spacing: LifeOSTokens.Space.sm) {
                Button("Try again") {
                    Task { await coordinator.retry() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pickerTask != nil)
                Button("Choose vault", action: chooseVault)
                    .buttonStyle(.bordered)
                    .disabled(pickerTask != nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LifeOSTokens.Space.xl)
    }

    private func canvasContent(
        for project: PlanningProjectCoordinator
    ) -> PlanningWorkspaceCanvasContent {
#if DEBUG
        return PlanningWorkspaceCanvasContent(
            workspace: coordinator,
            project: project,
            viewportProbe: presentationProbe?.viewportProbe
        )
#else
        return PlanningWorkspaceCanvasContent(workspace: coordinator, project: project)
#endif
    }

    private func updateNativePresenter(
        _ presenter: PlanningWorkspaceNativePresenter?,
        ownerID: UUID
    ) {
        let changed: Bool
        if let presenter {
            changed = presenterReference.attach(presenter, ownerID: ownerID)
        } else {
            changed = presenterReference.detach(ownerID: ownerID)
        }
#if DEBUG
        if changed {
            presentationProbe?.updatePresenterReady(
                presenterReference.value != nil,
                ownerID: presentationProbeOwnerID
            )
        }
#endif
    }

    private func cancelPickerPresentation() {
        pickerGeneration = UUID()
        pickerTask?.cancel()
        pickerTask = nil
        if let activeDocumentTicket {
            coordinator.cancelDocumentSelection(activeDocumentTicket)
            self.activeDocumentTicket = nil
        }
    }

    private func setPickerError(_ error: String?) {
        pickerError = error
#if DEBUG
        presentationProbe?.updatePickerError(error, ownerID: presentationProbeOwnerID)
#endif
    }

    private func assignPickerTask(
        _ task: Task<Void, Never>,
        generation: UUID
    ) {
        pickerTask = task
#if DEBUG
        presentationProbe?.pickerTaskDidStart(generation, ownerID: presentationProbeOwnerID)
#endif
    }

    private func finishPickerTask(
        generation: UUID,
        ticket: PlanningDocumentSelectionTicket? = nil
    ) {
        if pickerGeneration == generation {
            pickerTask = nil
            if let ticket, activeDocumentTicket == ticket {
                activeDocumentTicket = nil
            }
        }
        if let ticket {
            coordinator.cancelDocumentSelection(ticket)
        }
#if DEBUG
        presentationProbe?.pickerTaskDidFinish(generation, ownerID: presentationProbeOwnerID)
#endif
    }

    private func pickerErrorDescription(_ error: Error) -> String {
        guard let planningError = error as? PlanningFilesystemError else {
            return "The selected planning item could not be opened."
        }
        return planningError.localizedDescription
    }

    private func chooseVault() {
        guard pickerTask == nil else { return }
        setPickerError(nil)
        let generation = UUID()
        pickerGeneration = generation
#if os(iOS)
        guard let presenter = presenterReference.value else {
            setPickerError(PlanningFilesystemError.unavailable("pickerPresenter").localizedDescription)
            return
        }
        let task = Task { @MainActor in
            defer {
                finishPickerTask(generation: generation)
            }
            do {
                if let selection = try await PlanningVaultSelectionBroker.selectDirectory(from: presenter) {
                    guard !Task.isCancelled, pickerGeneration == generation else { return }
                    await coordinator.attach(selection)
                }
            } catch {
                guard !Task.isCancelled, pickerGeneration == generation else { return }
                setPickerError(pickerErrorDescription(error))
            }
        }
        assignPickerTask(task, generation: generation)
#elseif os(macOS)
        let window = presenterReference.value
        let task = Task { @MainActor in
            defer {
                finishPickerTask(generation: generation)
            }
            do {
                if let selection = try PlanningVaultSelectionBroker.selectDirectory(presenting: window) {
                    guard !Task.isCancelled, pickerGeneration == generation else { return }
                    await coordinator.attach(selection)
                }
            } catch {
                guard !Task.isCancelled, pickerGeneration == generation else { return }
                setPickerError(pickerErrorDescription(error))
            }
        }
        assignPickerTask(task, generation: generation)
#endif
    }

    private func chooseDocument() {
        guard pickerTask == nil else { return }
        setPickerError(nil)
        let generation = UUID()
        pickerGeneration = generation
        guard let ticket = coordinator.beginDocumentSelection() else {
            setPickerError("Choose a ready planning workspace before selecting a document.")
            return
        }
        activeDocumentTicket = ticket

#if os(iOS)
        guard let presenter = presenterReference.value else {
            coordinator.cancelDocumentSelection(ticket)
            activeDocumentTicket = nil
            setPickerError(PlanningFilesystemError.unavailable("pickerPresenter").localizedDescription)
            return
        }
#if DEBUG
        let controlledDocumentSelection = presentationProbe?.controlledDocumentSelection
#endif
        let selectDocument: () async throws -> PlanningUserSelectedDocument? = {
#if DEBUG
            if let controlledDocumentSelection {
                return try await controlledDocumentSelection(presenter)
            }
#endif
            return try await PlanningVaultSelectionBroker.selectDocument(from: presenter)
        }
        let task = Task { @MainActor in
            defer {
                finishPickerTask(generation: generation, ticket: ticket)
            }
            do {
                if let selection = try await selectDocument() {
                    guard !Task.isCancelled, pickerGeneration == generation else { return }
                    await coordinator.openSelectedDocument(selection, ticket: ticket)
                }
            } catch {
                guard !Task.isCancelled, pickerGeneration == generation else { return }
                setPickerError(pickerErrorDescription(error))
            }
        }
        assignPickerTask(task, generation: generation)
#elseif os(macOS)
        guard let window = presenterReference.value else {
            coordinator.cancelDocumentSelection(ticket)
            activeDocumentTicket = nil
            setPickerError(PlanningFilesystemError.unavailable("pickerPresenter").localizedDescription)
            return
        }
#if DEBUG
        let controlledDocumentSelection = presentationProbe?.controlledDocumentSelection
#endif
        let selectDocument: () async throws -> PlanningUserSelectedDocument? = {
#if DEBUG
            if let controlledDocumentSelection {
                return try await controlledDocumentSelection(window)
            }
#endif
            return try await PlanningVaultSelectionBroker.selectDocument(presenting: window)
        }
        let task = Task { @MainActor in
            defer {
                finishPickerTask(generation: generation, ticket: ticket)
            }
            do {
                if let selection = try await selectDocument() {
                    guard !Task.isCancelled, pickerGeneration == generation else { return }
                    await coordinator.openSelectedDocument(selection, ticket: ticket)
                }
            } catch {
                guard !Task.isCancelled, pickerGeneration == generation else { return }
                setPickerError(pickerErrorDescription(error))
            }
        }
        assignPickerTask(task, generation: generation)
#endif
    }
}

private struct PlanningWorkspaceCanvasContent: View {
    @ObservedObject var workspace: PlanningWorkspaceCoordinator
    @ObservedObject var project: PlanningProjectCoordinator
#if DEBUG
    let viewportProbe: PlanningCanvasViewportProbe?
#endif

    var body: some View {
        canvasSurface
    }

    private var canvas: PlanningCanvasView {
#if DEBUG
        PlanningCanvasView(
            coordinator: project,
            onInspect: inspectSelectedNode,
            viewportProbe: viewportProbe
        )
#else
        PlanningCanvasView(coordinator: project, onInspect: inspectSelectedNode)
#endif
    }

    @ViewBuilder
    private var canvasSurface: some View {
#if os(macOS)
        HStack(spacing: 0) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if workspace.isInspectorPresented {
                Divider()
                PlanningWorkspaceInspectorView(workspace: workspace)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
#elseif os(iOS)
        canvas
            .sheet(
                isPresented: Binding(
                    get: { workspace.isInspectorPresented },
                    set: { presented in
                        if !presented {
                            workspace.closeInspector()
                        }
                    }
                )
            ) {
                PlanningWorkspaceInspectorView(workspace: workspace)
                    .presentationDetents([.medium, .large])
            }
#else
        canvas
#endif
    }

    private func inspectSelectedNode() {
        guard let selectedNodeID = project.selectedNodeID else { return }
        workspace.inspectNode(id: selectedNodeID)
    }
}

private struct PlanningWorkspaceInspectorView: View {
    @ObservedObject var workspace: PlanningWorkspaceCoordinator

    var body: some View {
        Group {
            if workspace.isInspectorNotePresented {
                notePreview
            } else {
                metadata
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LifeOSTokens.surface)
    }

    private var metadata: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                inspectorHeader(title: "Inspect node", leadingTitle: nil) {
                    workspace.closeInspector()
                }

                if let node = workspace.inspectorNode {
                    metadataRow("Type", node.type.rawValue.capitalized)
                    metadataRow("Node ID", node.id)

                    if let text = node.text {
                        metadataRow("Text", text)
                    }
                    if let label = node.label {
                        metadataRow("Label", label)
                    }
                    if let background = node.background {
                        metadataRow("Background", background)
                    }
                    if let backgroundStyle = node.backgroundStyle {
                        metadataRow("Background style", backgroundStyle)
                    }
                    if let reference = workspace.inspectorReference {
                        metadataRow("File reference", reference)
                    }
                    if let path = workspace.inspectorReferencePath {
                        metadataRow("Relative path", path.value)
                    }
                    if let fragment = workspace.inspectorReferenceFragment {
                        metadataRow("Fragment", "#\(fragment)")
                    }
                    if let url = node.url {
                        metadataRow("URL", url)
                    }

                    if workspace.inspectorNotePath != nil {
                        Button("Open note") {
                            Task { await workspace.openSelectedNodeNote() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("planning-inspector-open-note")
                    } else if workspace.inspectorReference != nil {
                        Text("This reference is metadata only.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LifeOSTokens.secondaryText)
                    }
                } else {
                    Text("No node selected")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }
            }
            .padding(LifeOSTokens.Space.lg)
        }
    }

    private var notePreview: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
            inspectorHeader(title: "Note preview", leadingTitle: "Back") {
                workspace.closeInspectorNote()
            }

            if let path = workspace.inspectorNotePath {
                Text("LifeOS/\(path.value)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .textSelection(.enabled)
            }
            if let fragment = workspace.inspectorReferenceFragment {
                Text("Reference fragment: #\(fragment) (display only)")
                    .font(.system(size: 12))
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }

            inspectorNoteStatus

            if let source = workspace.inspectorNoteSource {
                ScrollView([.vertical, .horizontal]) {
                    Text(source)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LifeOSTokens.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(LifeOSTokens.Space.sm)
                        .accessibilityIdentifier("planning-note-source")
                }
                .background(LifeOSTokens.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
                }
            } else {
                Spacer(minLength: 0)
            }

            Button("Refresh") {
                Task { await workspace.refreshInspectorNote() }
            }
            .buttonStyle(.bordered)
            .disabled(workspace.inspectorNoteStatus == .loading || workspace.inspectorNoteStatus == .unavailable)
            .accessibilityIdentifier("planning-inspector-refresh")
        }
        .padding(LifeOSTokens.Space.lg)
    }

    private var inspectorNoteStatus: some View {
        HStack(spacing: LifeOSTokens.Space.xs) {
            switch workspace.inspectorNoteStatus {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Loading note…")
            case .ready:
                Label("Current read", systemImage: "checkmark.circle")
            case .stale:
                Label("Stale preview", systemImage: "exclamationmark.triangle")
            case .failed:
                Label("Could not read note", systemImage: "xmark.circle")
            case .unavailable:
                Label("Note access unavailable", systemImage: "icloud.slash")
            case .idle, .unsupported:
                EmptyView()
            }
            if let error = workspace.inspectorError,
               workspace.inspectorNoteStatus != .loading {
                Text(error)
                    .lineLimit(2)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(noteStatusColor)
    }

    private var noteStatusColor: Color {
        switch workspace.inspectorNoteStatus {
        case .ready: return LifeOSTokens.success
        case .stale, .loading: return LifeOSTokens.warning
        case .failed, .unavailable: return LifeOSTokens.danger
        case .idle, .unsupported: return LifeOSTokens.secondaryText
        }
    }

    private func inspectorHeader(
        title: String,
        leadingTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: LifeOSTokens.Space.sm) {
            if let leadingTitle {
                Button(leadingTitle, action: action)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("planning-inspector-back")
            }
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LifeOSTokens.primaryText)
            Spacer(minLength: LifeOSTokens.Space.xs)
            if leadingTitle == nil {
                Button("Close", action: action)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("planning-inspector-close")
            }
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LifeOSTokens.metadataText)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(LifeOSTokens.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if os(iOS)
private final class PlanningWorkspacePresenterController: UIViewController {
    var onAppear: ((UIViewController) -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?(self)
    }

    func clearCallbacks() {
        onAppear = nil
    }
}

private struct PlanningWorkspacePresenterBridge: UIViewControllerRepresentable {
    let onMount: (UIViewController?, UUID) -> Void

    final class Coordinator {
        let ownerID = UUID()
        var onMount: (UIViewController?, UUID) -> Void
        weak var currentPresenter: UIViewController?

        init(onMount: @escaping (UIViewController?, UUID) -> Void) {
            self.onMount = onMount
        }

        func mount(_ presenter: UIViewController) {
            currentPresenter = presenter
            onMount(presenter, ownerID)
        }

        func dismantle(_ presenter: UIViewController) {
            guard currentPresenter == nil || currentPresenter === presenter else { return }
            currentPresenter = nil
            onMount(nil, ownerID)
        }

        func clearCallbacks() {
            currentPresenter = nil
            onMount = { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onMount: onMount)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = PlanningWorkspacePresenterController()
        controller.view.backgroundColor = .clear
        controller.onAppear = { [weak coordinator = context.coordinator] presenter in
            coordinator?.mount(presenter)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.onMount = onMount
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.dismantle(uiViewController)
        (uiViewController as? PlanningWorkspacePresenterController)?.clearCallbacks()
        coordinator.clearCallbacks()
    }
}
#elseif os(macOS)
private final class PlanningWorkspaceWindowView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    func clearCallbacks() {
        onWindowChange = nil
    }
}

private struct PlanningWorkspaceWindowBridge: NSViewRepresentable {
    let onWindow: (NSWindow?, UUID) -> Void

    final class Coordinator {
        let ownerID = UUID()
        var onWindow: (NSWindow?, UUID) -> Void
        weak var currentWindow: NSWindow?
        weak var currentView: NSView?

        init(onWindow: @escaping (NSWindow?, UUID) -> Void) {
            self.onWindow = onWindow
        }

        func mount(_ window: NSWindow?) {
            currentWindow = window
            onWindow(window, ownerID)
        }

        func dismantle(_ view: NSView) {
            guard currentView == nil || currentView === view else { return }
            currentView = nil
            currentWindow = nil
            onWindow(nil, ownerID)
        }

        func clearCallbacks() {
            currentView = nil
            currentWindow = nil
            onWindow = { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onWindow: onWindow)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PlanningWorkspaceWindowView(frame: .zero)
        context.coordinator.currentView = view
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.mount(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onWindow = onWindow
        context.coordinator.currentView = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismantle(nsView)
        (nsView as? PlanningWorkspaceWindowView)?.clearCallbacks()
        coordinator.clearCallbacks()
    }
}
#endif
