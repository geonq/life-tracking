import Foundation

public struct PlanningUserSelectedDocument: Sendable {
    internal let url: URL

    internal init(pickerURL: URL) throws {
        guard pickerURL.isFileURL else {
            throw PlanningFilesystemError.invalid("selection.url")
        }
        self.url = pickerURL
    }
}

public enum PlanningDocumentDestination: Equatable, Sendable {
    case canvas(PlanningStoredPath)
    case markdown(PlanningStoredPath)
}

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

@MainActor
private final class PlanningNativeDocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private enum PresentationPhase: Equatable {
        case idle
        case presenting
        case presented
        case dismissing
        case finished
    }

    private var phase: PresentationPhase = .idle
    private var continuation: CheckedContinuation<URL?, Error>?
    private var picker: UIDocumentPickerViewController?
    private var pendingResult: Result<URL?, Error>?

    func select(
        from presenter: UIViewController,
        contentTypes: [UTType]
    ) async throws -> URL? {
        guard phase == .idle, continuation == nil, picker == nil else {
            throw PlanningFilesystemError.unavailable("pickerBusy")
        }
        guard !Task.isCancelled else { return nil }
        guard presenter.viewIfLoaded?.window != nil else {
            throw PlanningFilesystemError.unavailable("pickerPresenter")
        }
        guard presenter.presentedViewController == nil else {
            throw PlanningFilesystemError.unavailable("pickerPresenterBusy")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    self.phase = .finished
                    self.continuation = nil
                    continuation.resume(returning: nil)
                    return
                }
                let picker = UIDocumentPickerViewController(
                    forOpeningContentTypes: contentTypes,
                    asCopy: false
                )
                picker.delegate = self
                picker.allowsMultipleSelection = false
                self.picker = picker
                guard !Task.isCancelled else {
                    self.phase = .finished
                    self.continuation = nil
                    self.picker = nil
                    continuation.resume(returning: nil)
                    return
                }
                self.phase = .presenting
                presenter.present(picker, animated: true) { [weak self, weak picker] in
                    guard let self, let picker, self.picker === picker else { return }
                    guard self.phase != .finished else { return }
                    if self.phase == .presenting {
                        self.phase = .presented
                    }
                    self.dismissOwnedPickerIfNeeded()
                }
                picker.presentationController?.delegate = self
                if Task.isCancelled {
                    self.settle(.success(nil))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.settle(.success(nil))
            }
        }
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard controller === picker else { return }
        settle(.success(urls.count == 1 ? urls[0] : nil))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === picker else { return }
        settle(.success(nil))
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let picker, picker.presentationController === presentationController else { return }
        if pendingResult == nil {
            pendingResult = .success(nil)
        }
        finalizeAfterDismissal()
    }

    private func settle(_ result: Result<URL?, Error>) {
        guard phase != .finished, pendingResult == nil else { return }
        pendingResult = result
        dismissOwnedPickerIfNeeded()
    }

    private func dismissOwnedPickerIfNeeded() {
        guard phase != .finished, pendingResult != nil else { return }
        guard phase != .presenting else { return }

        phase = .dismissing
        guard let picker, picker.presentingViewController != nil else {
            finalizeAfterDismissal()
            return
        }

        picker.dismiss(animated: true) { [weak self, weak picker] in
            guard let self, let picker, self.picker === picker else { return }
            self.finalizeAfterDismissal()
        }
    }

    private func finalizeAfterDismissal() {
        guard phase != .finished,
              let pendingResult,
              let continuation else { return }
        phase = .finished
        self.pendingResult = nil
        self.continuation = nil
        self.picker = nil
        continuation.resume(with: pendingResult)
    }
}

@MainActor
extension PlanningVaultSelectionBroker {
    /// Presents the native folder picker for the production iOS flow. The
    /// synchronous adapter remains available for tests and host integrations.
    public static func selectDirectory(
        from presenter: UIViewController
    ) async throws -> PlanningUserSelectedDirectory? {
        let coordinator = PlanningNativeDocumentPickerCoordinator()
        return try await PlanningNativeDocumentPickerLifetime.shared.withCoordinator(coordinator) {
            let url = try await coordinator.select(from: presenter, contentTypes: [.folder])
            guard let url else { return nil }
            return try PlanningUserSelectedDirectory.picker(url: url)
        }
    }

    public static func selectDocument(
        from presenter: UIViewController
    ) async throws -> PlanningUserSelectedDocument? {
        let coordinator = PlanningNativeDocumentPickerCoordinator()
        return try await PlanningNativeDocumentPickerLifetime.shared.withCoordinator(coordinator) {
            let contentTypes = [
                UTType(filenameExtension: "canvas") ?? .data,
                UTType(filenameExtension: "md") ?? .data
            ]
            let url = try await coordinator.select(
                from: presenter,
                contentTypes: contentTypes
            )
            guard let url else { return nil }
            return try PlanningUserSelectedDocument(pickerURL: url)
        }
    }
}

@MainActor
private final class PlanningNativeDocumentPickerLifetime {
    static let shared = PlanningNativeDocumentPickerLifetime()
    private var coordinator: PlanningNativeDocumentPickerCoordinator?

    func withCoordinator<T>(
        _ coordinator: PlanningNativeDocumentPickerCoordinator,
        operation: () async throws -> T
    ) async throws -> T {
        guard self.coordinator == nil else {
            throw PlanningFilesystemError.unavailable("pickerBusy")
        }
        self.coordinator = coordinator
        defer { self.coordinator = nil }
        return try await operation()
    }
}
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
private final class PlanningNativeDocumentPanelCoordinator {
    private enum PresentationPhase: Equatable {
        case idle
        case presenting
        case presented
        case dismissing
        case finished
    }

    private var phase: PresentationPhase = .idle
    private var continuation: CheckedContinuation<URL?, Error>?
    private weak var hostWindow: NSWindow?
    private var panel: NSOpenPanel?
    private var pendingResult: Result<URL?, Error>?
    private var hostWindowCloseObserver: NSObjectProtocol?
    private var sheetCompletionOutstanding = false

    func select(presenting window: NSWindow?) async throws -> URL? {
        guard phase == .idle, continuation == nil, panel == nil else {
            throw PlanningFilesystemError.unavailable("pickerBusy")
        }
        guard !Task.isCancelled else { return nil }
        guard let window, window.isVisible else {
            throw PlanningFilesystemError.unavailable("pickerPresenter")
        }
        guard window.attachedSheet == nil else {
            throw PlanningFilesystemError.unavailable("pickerPresenterBusy")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.hostWindow = window
                guard !Task.isCancelled else {
                    self.phase = .finished
                    self.continuation = nil
                    self.hostWindow = nil
                    self.sheetCompletionOutstanding = false
                    continuation.resume(returning: nil)
                    return
                }
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = false
                panel.allowedContentTypes = [
                    UTType(filenameExtension: "canvas") ?? .data,
                    UTType(filenameExtension: "md") ?? .data
                ]
                panel.prompt = "Choose document"
                guard !Task.isCancelled else {
                    self.phase = .finished
                    self.continuation = nil
                    self.hostWindow = nil
                    self.sheetCompletionOutstanding = false
                    continuation.resume(returning: nil)
                    return
                }
                self.panel = panel
                self.phase = .presenting
                self.observeHostWindowClosure(window)
                self.sheetCompletionOutstanding = true
                panel.beginSheetModal(for: window) { [weak self, weak panel] response in
                    guard let self, let panel, self.panel === panel else { return }
                    let url = response == .OK && panel.urls.count == 1 ? panel.urls[0] : nil
                    self.handleSheetCompletion(.success(url))
                }
                if self.phase == .presenting {
                    self.phase = .presented
                }
                if Task.isCancelled {
                    self.settle(.success(nil))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.settle(.success(nil))
            }
        }
    }

    private func observeHostWindowClosure(_ window: NSWindow) {
        hostWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settle(.success(nil))
            }
        }
    }

    private func handleSheetCompletion(_ result: Result<URL?, Error>) {
        guard phase != .finished else { return }
        if pendingResult == nil {
            pendingResult = result
        }
        sheetCompletionOutstanding = false
        finalizeAfterDismissal()
    }

    private func settle(_ result: Result<URL?, Error>) {
        guard phase != .finished, pendingResult == nil else { return }
        pendingResult = result
        phase = .dismissing

        guard sheetCompletionOutstanding else {
            finalizeAfterDismissal()
            return
        }

        guard let panel, let hostWindow, panel.sheetParent === hostWindow else {
            return
        }

        hostWindow.endSheet(panel, returnCode: .cancel)
    }

    private func finalizeAfterDismissal() {
        guard phase != .finished,
              let pendingResult,
              let continuation else { return }
        phase = .finished
        if let hostWindowCloseObserver {
            NotificationCenter.default.removeObserver(hostWindowCloseObserver)
        }
        self.hostWindowCloseObserver = nil
        self.sheetCompletionOutstanding = false
        self.pendingResult = nil
        self.continuation = nil
        self.panel = nil
        self.hostWindow = nil
        continuation.resume(with: pendingResult)
    }
}

@MainActor
private final class PlanningNativeDocumentPanelLifetime {
    static let shared = PlanningNativeDocumentPanelLifetime()
    private var coordinator: PlanningNativeDocumentPanelCoordinator?

    func withCoordinator<T>(
        _ coordinator: PlanningNativeDocumentPanelCoordinator,
        operation: () async throws -> T
    ) async throws -> T {
        guard self.coordinator == nil else {
            throw PlanningFilesystemError.unavailable("pickerBusy")
        }
        self.coordinator = coordinator
        defer { self.coordinator = nil }
        return try await operation()
    }
}

@MainActor
extension PlanningVaultSelectionBroker {
    public static func selectDocument(
        presenting window: NSWindow?
    ) async throws -> PlanningUserSelectedDocument? {
        let coordinator = PlanningNativeDocumentPanelCoordinator()
        return try await PlanningNativeDocumentPanelLifetime.shared.withCoordinator(coordinator) {
            let url = try await coordinator.select(presenting: window)
            guard let url else { return nil }
            return try PlanningUserSelectedDocument(pickerURL: url)
        }
    }
}
#endif
