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
private final class PlanningNativeDocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL?, Error>?
    private var picker: UIDocumentPickerViewController?

    func select(
        from presenter: UIViewController,
        contentTypes: [UTType]
    ) async throws -> URL? {
        guard continuation == nil else {
            throw PlanningFilesystemError.unavailable("pickerBusy")
        }
        try Task.checkCancellation()
        guard presenter.viewIfLoaded?.window != nil else {
            throw PlanningFilesystemError.unavailable("pickerPresenter")
        }
        guard presenter.presentedViewController == nil else {
            throw PlanningFilesystemError.unavailable("pickerPresenterBusy")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let picker = UIDocumentPickerViewController(
                    forOpeningContentTypes: contentTypes,
                    asCopy: false
                )
                picker.delegate = self
                picker.allowsMultipleSelection = false
                self.picker = picker
                presenter.present(picker, animated: true)
                if Task.isCancelled {
                    self.finish(.success(nil))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.success(nil))
            }
        }
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        finish(.success(urls.count == 1 ? urls[0] : nil))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.success(nil))
    }

    private func finish(_ result: Result<URL?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let presentedPicker = picker
        guard let presentedPicker,
              presentedPicker.presentingViewController != nil else {
            picker = nil
            continuation.resume(with: result)
            return
        }
        presentedPicker.dismiss(animated: true) { [weak self] in
            self?.picker = nil
            continuation.resume(with: result)
        }
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
    private var continuation: CheckedContinuation<URL?, Error>?
    private var panel: NSOpenPanel?

    func select(presenting window: NSWindow) async throws -> URL? {
        guard continuation == nil else {
            throw PlanningFilesystemError.unavailable("pickerBusy")
        }
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
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
                self.panel = panel
                panel.beginSheetModal(for: window) { [weak self, weak panel] response in
                    guard let self else { return }
                    let url = response == .OK && panel?.urls.count == 1 ? panel?.urls[0] : nil
                    self.finish(.success(url))
                }
                if Task.isCancelled {
                    self.finish(.success(nil))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.success(nil))
            }
        }
    }

    private func finish(_ result: Result<URL?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let panel = self.panel
        self.panel = nil
        if let panel, let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: .cancel)
        }
        continuation.resume(with: result)
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
        guard let window else {
            throw PlanningFilesystemError.unavailable("pickerPresenter")
        }
        let coordinator = PlanningNativeDocumentPanelCoordinator()
        return try await PlanningNativeDocumentPanelLifetime.shared.withCoordinator(coordinator) {
            let url = try await coordinator.select(presenting: window)
            guard let url else { return nil }
            return try PlanningUserSelectedDocument(pickerURL: url)
        }
    }
}
#endif
