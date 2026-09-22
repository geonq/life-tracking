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
            canvasPathState
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
            if let pickerError {
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

                Button("Change vault", action: chooseVault)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("planning-change-vault")
            }

            if let pickerError {
                Text(pickerError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LifeOSTokens.danger)
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
                    Button("Change document") {
                        coordinator.closeDocument()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("planning-change-document")
                }
                .padding(.horizontal, LifeOSTokens.Space.md)
                .padding(.vertical, LifeOSTokens.Space.xs)
                PlanningCanvasView(coordinator: project)
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
