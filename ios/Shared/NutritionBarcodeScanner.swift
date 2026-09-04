#if os(iOS)
import AVFoundation
import Combine
import SwiftUI

/// Camera state is intentionally explicit so denied/unavailable devices keep
/// the manual barcode field as the reliable fallback.
public enum NutritionBarcodeScannerState: Equatable, Sendable {
    case permissionRequired
    case denied
    case unavailable
    case ready
    case scanning
    case captured(String)
    case failed
}

private final class NutritionBarcodeCaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

/// One-shot, metadata-only EAN scanner. It retains no frames or camera data;
/// a valid code is normalized and handed to the existing lookup flow.
@MainActor
public final class NutritionBarcodeScannerCoordinator: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    @Published public private(set) var state: NutritionBarcodeScannerState

    private let captureSessionBox = NutritionBarcodeCaptureSessionBox()
    public var session: AVCaptureSession { captureSessionBox.session }
    private var configured = false
    private var onCapture: ((String) -> Void)?

    public init(initialState: NutritionBarcodeScannerState? = nil) {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        self.state = initialState ?? (authorization == .authorized ? .ready : authorization == .denied || authorization == .restricted ? .denied : .permissionRequired)
        super.init()
    }

    public nonisolated static func normalizedCapture(_ value: String) -> String? {
        NutritionBarcodeNormalizer.normalize(value)
    }

    public func start(onCapture: @escaping (String) -> Void) {
        self.onCapture = onCapture
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            state = .permissionRequired
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted { self.configureAndRun() } else { self.state = .denied }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .unavailable
        }
    }

    public func stop() {
        guard session.isRunning else {
            if configured { state = .ready }
            return
        }
        let captureSessionBox = self.captureSessionBox
        DispatchQueue.global(qos: .userInitiated).async {
            captureSessionBox.session.stopRunning()
            Task { @MainActor [weak self] in
                guard let self, self.configured else { return }
                self.state = .ready
            }
        }
    }

    public func reset() {
        if session.isRunning { stop() }
        state = configured ? .ready : .permissionRequired
    }

    private func configureAndRun() {
        guard !configured else {
            runSession()
            return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            state = .unavailable
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                state = .unavailable
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            // UPC-A is reported by AVFoundation as EAN-13 with a leading zero;
            // UPC-E is intentionally excluded because expansion is not part of
            // this contract and must not be guessed.
            let supported: [AVMetadataObject.ObjectType] = [.ean8, .ean13]
            output.metadataObjectTypes = supported.filter { output.availableMetadataObjectTypes.contains($0) }
            guard !output.metadataObjectTypes.isEmpty else {
                session.commitConfiguration()
                state = .unavailable
                return
            }
            session.commitConfiguration()
            configured = true
            state = .ready
            runSession()
        } catch {
            state = .failed
        }
    }

    private func runSession() {
        guard configured, !session.isRunning else {
            if configured { state = .scanning }
            return
        }
        let captureSessionBox = self.captureSessionBox
        state = .ready
        DispatchQueue.global(qos: .userInitiated).async {
            captureSessionBox.session.startRunning()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = captureSessionBox.session.isRunning ? .scanning : .failed
            }
        }
    }

    public nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                           didOutput metadataObjects: [AVMetadataObject],
                                           from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
              let normalized = Self.normalizedCapture(code) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.state == .scanning else { return }
            self.state = .captured(normalized)
            self.stop()
            self.onCapture?(normalized)
        }
    }
}

public struct NutritionBarcodeCameraPreview: UIViewRepresentable {
    public let coordinator: NutritionBarcodeScannerCoordinator

    public init(coordinator: NutritionBarcodeScannerCoordinator) { self.coordinator = coordinator }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = coordinator.session
        return view
    }

    public func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = coordinator.session
    }

    public final class PreviewView: UIView {
        override public class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        public var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#endif
