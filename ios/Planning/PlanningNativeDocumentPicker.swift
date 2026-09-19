#if os(iOS)
import UIKit
import UniformTypeIdentifiers

@MainActor
private final class PlanningNativeDocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL?, Error>?
    private var picker: UIDocumentPickerViewController?

    func select(from presenter: UIViewController) async throws -> URL? {
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
                    forOpeningContentTypes: [.folder],
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
        finish(.success(urls.first))
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
            let url = try await coordinator.select(from: presenter)
            guard let url else { return nil }
            return try PlanningUserSelectedDirectory.picker(url: url)
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
#endif
