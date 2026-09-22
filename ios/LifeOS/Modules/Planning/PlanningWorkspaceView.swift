import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
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
#if os(iOS)
    @State private var pickerPresenter: UIViewController?
#elseif os(macOS)
    @State private var pickerWindow: NSWindow?
#endif

    public init(
        coordinator: PlanningWorkspaceCoordinator,
        onDone: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(LifeOSTokens.canvas)
#if os(iOS)
        .background {
            PlanningWorkspacePresenterBridge { presenter in
                pickerPresenter = presenter
            }
            .frame(width: 0, height: 0)
        }
#elseif os(macOS)
        .background {
            PlanningWorkspaceWindowBridge { window in
                pickerWindow = window
            }
            .frame(width: 0, height: 0)
        }
#endif
        .onAppear {
            coordinator.requestMount()
        }
        .onDisappear {
            pickerGeneration = UUID()
            pickerTask?.cancel()
            pickerTask = nil
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
                .accessibilityIdentifier("planning-choose-vault")
            if let pickerError = pickerError ?? coordinator.lastError {
                Text(pickerError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
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
                .disabled(coordinator.pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("planning-open-canvas")

                Button("Choose document", action: chooseDocument)
                    .buttonStyle(.bordered)
                    .disabled(pickerTask != nil)
                    .accessibilityIdentifier("planning-choose-document")

                Button("Change vault", action: chooseVault)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("planning-change-vault")
            }

            if let pickerError = pickerError ?? coordinator.lastError {
                Text(pickerError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.danger)
                if coordinator.canRetryDocumentSelection {
                    Button("Retry") { Task { await coordinator.retry() } }
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
                    Text(error).font(.caption).foregroundStyle(LifeOSTokens.danger)
                    if coordinator.canRetryDocumentSelection {
                        Button("Retry") { Task { await coordinator.retry() } }
                    }
                }
                PlanningWorkspaceCanvasContent(
                    workspace: coordinator,
                    project: project
                )
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
                Button("Choose vault", action: chooseVault)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LifeOSTokens.Space.xl)
    }

    private func chooseVault() {
        pickerError = nil
        pickerTask?.cancel()
        let generation = UUID()
        pickerGeneration = generation
#if os(iOS)
        guard let pickerPresenter else {
            pickerError = PlanningFilesystemError.unavailable("pickerPresenter").localizedDescription
            return
        }
        pickerTask = Task { @MainActor in
            defer {
                if pickerGeneration == generation {
                    pickerTask = nil
                }
            }
            do {
                if let selection = try await PlanningVaultSelectionBroker.selectDirectory(from: pickerPresenter) {
                    guard !Task.isCancelled, pickerGeneration == generation else { return }
                    await coordinator.attach(selection)
                }
            } catch {
                guard !Task.isCancelled, pickerGeneration == generation else { return }
                pickerError = error.localizedDescription
            }
        }
#elseif os(macOS)
        pickerTask = Task { @MainActor in
            defer {
                if pickerGeneration == generation {
                    pickerTask = nil
                }
            }
            do {
                if let selection = try PlanningVaultSelectionBroker.selectDirectory(presenting: pickerWindow) {
                    guard !Task.isCancelled, pickerGeneration == generation else { return }
                    await coordinator.attach(selection)
                }
            } catch {
                guard !Task.isCancelled, pickerGeneration == generation else { return }
                pickerError = error.localizedDescription
            }
        }
#endif
    }

    private func chooseDocument() {
        pickerError = nil
        pickerTask?.cancel()
        let generation = UUID()
        pickerGeneration = generation
        guard let ticket = coordinator.beginDocumentSelection() else {
            pickerError = "Choose a ready planning workspace before selecting a document."
            return
        }

#if os(iOS)
        guard let pickerPresenter else {
            coordinator.cancelDocumentSelection(ticket)
            pickerError = PlanningFilesystemError.unavailable("pickerPresenter").localizedDescription
            return
        }
        pickerTask = Task { @MainActor in
            defer {
                if pickerGeneration == generation {
                    pickerTask = nil
                }
                coordinator.cancelDocumentSelection(ticket)
            }
            do {
                if let selection = try await PlanningVaultSelectionBroker.selectDocument(from: pickerPresenter) {
                    guard !Task.isCancelled, pickerGeneration == generation else { return }
                    await coordinator.openSelectedDocument(selection, ticket: ticket)
                }
            } catch {
                guard !Task.isCancelled, pickerGeneration == generation else { return }
                pickerError = error.localizedDescription
            }
        }
#elseif os(macOS)
        guard let pickerWindow else {
            coordinator.cancelDocumentSelection(ticket)
            pickerError = PlanningFilesystemError.unavailable("pickerPresenter").localizedDescription
            return
        }
        pickerTask = Task { @MainActor in
            defer {
                if pickerGeneration == generation {
                    pickerTask = nil
                }
                coordinator.cancelDocumentSelection(ticket)
            }
            do {
                if let selection = try await PlanningVaultSelectionBroker.selectDocument(presenting: pickerWindow) {
                    guard !Task.isCancelled, pickerGeneration == generation else { return }
                    await coordinator.openSelectedDocument(selection, ticket: ticket)
                }
            } catch {
                guard !Task.isCancelled, pickerGeneration == generation else { return }
                pickerError = error.localizedDescription
            }
        }
#endif
    }
}

private struct PlanningWorkspaceCanvasContent: View {
    @ObservedObject var workspace: PlanningWorkspaceCoordinator
    @ObservedObject var project: PlanningProjectCoordinator

    var body: some View {
        canvasSurface
    }

    @ViewBuilder
    private var canvasSurface: some View {
#if os(macOS)
        HStack(spacing: 0) {
            PlanningCanvasView(coordinator: project, onInspect: inspectSelectedNode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if workspace.isInspectorPresented {
                Divider()
                PlanningWorkspaceInspectorView(workspace: workspace)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
#elseif os(iOS)
        PlanningCanvasView(coordinator: project, onInspect: inspectSelectedNode)
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
        PlanningCanvasView(coordinator: project, onInspect: inspectSelectedNode)
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
}

private struct PlanningWorkspacePresenterBridge: UIViewControllerRepresentable {
    let onMount: (UIViewController) -> Void

    final class Coordinator {
        var onMount: (UIViewController) -> Void

        init(onMount: @escaping (UIViewController) -> Void) {
            self.onMount = onMount
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onMount: onMount)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = PlanningWorkspacePresenterController()
        controller.view.backgroundColor = .clear
        controller.onAppear = { [weak coordinator = context.coordinator] presenter in
            coordinator?.onMount(presenter)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.onMount = onMount
    }
}
#elseif os(macOS)
private final class PlanningWorkspaceWindowView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private struct PlanningWorkspaceWindowBridge: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class Coordinator {
        var onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onWindow: onWindow)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PlanningWorkspaceWindowView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.onWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onWindow = onWindow
    }
}
#endif
