import Combine
import Foundation

// MARK: - Local-only food photo preparation

public enum FoodPhotoPreparationState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case error
}

/// Stable, presentation-safe failures for the local preparation boundary.
/// The underlying ImageIO/Photos errors never leave the coordinator.
public enum FoodPhotoPreparationError: Error, Equatable, Sendable {
    case preparationFailed
    case manifestUnavailable
}

public typealias FoodPhotoSanitizingOperation = @Sendable (
    [FoodPhotoSanitizerInput]
) async throws -> [FoodPhotoImageDescriptor]

/// Main-actor owner for a single, in-memory photo selection.
///
/// The caller loads `FoodPhotoSanitizerInput` values locally and hands them to
/// `prepare`. The coordinator retains only sanitized descriptors after that
/// operation completes; it has no persistence, upload, logging, or provider
/// dependency. A manifest is constructed only after preparation succeeds and
/// the caller explicitly grants current consent.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class FoodPhotoPreparationCoordinator: ObservableObject {
    @Published public private(set) var state: FoodPhotoPreparationState = .idle
    @Published public private(set) var selectedImageCount = 0
    @Published public private(set) var selectedByteCount = 0
    @Published public private(set) var sanitizedImageCount = 0
    @Published public private(set) var sanitizedByteCount = 0
    @Published public private(set) var explicitConsent = false

    private let sanitize: FoodPhotoSanitizingOperation
    private var operationID: UInt64 = 0
    private var preparationTask: Task<Void, Never>?
    private var descriptors: [FoodPhotoImageDescriptor] = []

    public init(
        sanitize: @escaping FoodPhotoSanitizingOperation = { inputs in
            try FoodPhotoSanitizer().sanitize(inputs)
        }
    ) {
        self.sanitize = sanitize
    }

    /// Starts a new selection before PhotosPicker items are loaded. This
    /// revokes any previous consent and invalidates every older operation.
    public func beginSelection() {
        invalidateSelection(state: .preparing)
    }

    /// Sanitizes caller-loaded inputs off the main actor. Originals are held
    /// only by the in-flight operation and are not retained in coordinator
    /// state after the operation finishes.
    public func prepare(inputs: [FoodPhotoSanitizerInput]) {
        // Every prepare call gets a fresh generation. The detached worker may
        // still finish after cancellation, so state equality alone is not a
        // sufficient stale-result guard.
        operationID &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        descriptors = []
        selectedImageCount = 0
        selectedByteCount = 0
        sanitizedImageCount = 0
        sanitizedByteCount = 0
        explicitConsent = false
        state = .preparing

        let operation = operationID
        guard let byteCount = Self.totalInputBytes(inputs),
              !inputs.isEmpty,
              inputs.count <= FoodPhotoSanitizer.maximumImageCount,
              Set(inputs.map(\.imageID)).count == inputs.count,
              byteCount <= FoodPhotoSanitizer.maximumAggregateInputBytes else {
            failCurrentPreparation()
            return
        }
        selectedImageCount = inputs.count
        selectedByteCount = byteCount
        let expectedImageIDs = inputs.map(\.imageID)
        let expectedImageCount = inputs.count

        let sanitizer = sanitize
        let worker = Task.detached(priority: .userInitiated) { [inputs, sanitizer] () -> [FoodPhotoImageDescriptor]? in
            do {
                return try await sanitizer(inputs)
            } catch {
                return nil
            }
        }

        preparationTask = Task { @MainActor [weak self] in
            let output = await worker.value
            guard !Task.isCancelled,
                  let self,
                  self.operationID == operation else { return }

            self.preparationTask = nil
            guard let output,
                  output.count == expectedImageCount,
                  output.count <= FoodPhotoSanitizer.maximumImageCount,
                  output.enumerated().allSatisfy({ index, descriptor in
                      descriptor.sanitized && descriptor.imageID == expectedImageIDs[index]
                  }),
                  let outputByteCount = Self.totalBytes(output),
                  outputByteCount <= FoodPhotoSanitizer.maximumOutputBytes else {
                self.failCurrentPreparation()
                return
            }

            self.descriptors = output
            self.sanitizedImageCount = output.count
            self.sanitizedByteCount = outputByteCount
            self.explicitConsent = false
            self.state = .ready
        }
    }

    /// Records a generic local loading/validation failure and clears any
    /// descriptors or consent from the failed selection.
    public func failPreparation() {
        invalidateSelection(state: .error)
    }

    public func clear() {
        invalidateSelection(state: .idle)
    }

    public func setExplicitConsent(_ consent: Bool) {
        explicitConsent = consent && state == .ready && !descriptors.isEmpty
    }

    public func makeManifest(
        mealID: FoodMealID,
        requestID: FoodRequestID,
        capturedAt: String,
        clientTimeZone: FoodClientTimeZone,
        userContext: FoodPhotoUserContext? = nil
    ) throws -> FoodPhotoManifest {
        guard state == .ready, explicitConsent, !descriptors.isEmpty else {
            throw FoodPhotoPreparationError.manifestUnavailable
        }

        do {
            return try FoodPhotoManifest(
                mealID: mealID,
                requestID: requestID,
                capturedAt: capturedAt,
                clientTimeZone: clientTimeZone,
                inferenceConsent: true,
                images: descriptors,
                userContext: userContext
            )
        } catch {
            throw FoodPhotoPreparationError.manifestUnavailable
        }
    }

    private func invalidateSelection(state: FoodPhotoPreparationState) {
        operationID &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        descriptors = []
        selectedImageCount = 0
        selectedByteCount = 0
        sanitizedImageCount = 0
        sanitizedByteCount = 0
        explicitConsent = false
        self.state = state
    }

    private static func totalInputBytes(_ inputs: [FoodPhotoSanitizerInput]) -> Int? {
        var total = 0
        for input in inputs {
            let (next, overflow) = total.addingReportingOverflow(input.data.count)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func totalBytes(_ descriptors: [FoodPhotoImageDescriptor]) -> Int? {
        var total = 0
        for descriptor in descriptors {
            let (next, overflow) = total.addingReportingOverflow(descriptor.byteLength)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private func failCurrentPreparation() {
        descriptors = []
        selectedImageCount = 0
        selectedByteCount = 0
        sanitizedImageCount = 0
        sanitizedByteCount = 0
        explicitConsent = false
        state = .error
    }
}
