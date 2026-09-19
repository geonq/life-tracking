import Foundation

private final class PlanningCoordinationResultBox<Value>: @unchecked Sendable {
    let lock = NSLock()
    var result: Result<Value, Error>?
}

private final class PlanningCoordinationOperationState: @unchecked Sendable {
    enum StopReason: Equatable {
        case none
        case cancelled
        case deadline
    }

    let id = UUID()
    let lock = NSLock()
    private var stopReason: StopReason = .none
    private var operation: Operation?
    private var coordinator: NSFileCoordinator?

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopReason != .none
    }

    func stop(_ reason: StopReason) -> (Operation?, NSFileCoordinator?) {
        lock.lock()
        if stopReason == .none { stopReason = reason }
        let values = (operation, coordinator)
        lock.unlock()
        return values
    }

    func failureIfStopped() -> PlanningFilesystemError? {
        lock.lock()
        let reason = stopReason
        lock.unlock()
        switch reason {
        case .none: return nil
        case .cancelled: return .cancelled
        case .deadline: return .unavailable("coordinationTimeout")
        }
    }

    func setOperation(_ operation: Operation) {
        lock.lock()
        self.operation = operation
        lock.unlock()
    }

    func clearOperation(_ operation: Operation) {
        lock.lock()
        if self.operation === operation { self.operation = nil }
        lock.unlock()
    }

    func setCoordinator(_ coordinator: NSFileCoordinator) {
        lock.lock()
        self.coordinator = coordinator
        lock.unlock()
    }

    func clearCoordinator(_ coordinator: NSFileCoordinator) {
        lock.lock()
        if self.coordinator === coordinator { self.coordinator = nil }
        lock.unlock()
    }
}

public final class PlanningCoordinationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledValue = false
    private var generationValue: UUID

    public init(generation: UUID = UUID()) {
        self.generationValue = generation
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledValue
    }

    public var generation: UUID {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    public func cancel() {
        lock.lock()
        cancelledValue = true
        lock.unlock()
    }

    public func replaceGeneration(_ generation: UUID) {
        lock.lock()
        generationValue = generation
        lock.unlock()
    }
}

public final class PlanningCoordinatedAccess: @unchecked Sendable {
    private let queue: OperationQueue
    private let stateLock = NSLock()
    private var activeStates: [UUID: PlanningCoordinationOperationState] = [:]
    private let deadlineInterval: TimeInterval = 5

    public init() {
        let queue = OperationQueue()
        queue.name = "com.lifeos.planning.filesystem-coordination"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.queue = queue
    }

    public func read<T>(
        targetURL: URL,
        namespaceURL: URL? = nil,
        token: PlanningCoordinationToken? = nil,
        accessor: @escaping (URL) throws -> T
    ) throws -> T {
        let expectedGeneration = token?.generation
        return try run(token: token, expectedGeneration: expectedGeneration) { state in
            try self.checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
            try self.validateFileURL(targetURL)
            let fallbackNamespace = namespaceURL ?? targetURL
            try self.validateFileURL(fallbackNamespace)
            let coordinationURL = FileManager.default.fileExists(atPath: targetURL.path)
                ? targetURL
                : fallbackNamespace
            let expectedTarget = coordinationURL.standardizedFileURL
            var coordinationError: NSError?
            var result: Result<T, Error>?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            self.register(coordinator, for: state)
            defer { self.unregister(coordinator, from: state) }
            coordinator.coordinate(
                readingItemAt: coordinationURL,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try self.checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
                    guard coordinatedURL.standardizedFileURL == expectedTarget,
                          coordinatedURL.pathComponents == expectedTarget.pathComponents else {
                        throw PlanningFilesystemError.identityChanged
                    }
                    let value = try accessor(coordinatedURL)
                    try self.checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
                    result = .success(value)
                } catch {
                    result = .failure(error)
                }
            }
            if let result { return try result.get() }
            try self.checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
            if let coordinationError { throw mapCoordinationError(coordinationError) }
            throw PlanningFilesystemError.unavailable("coordination")
        }
    }

    public func write<T>(
        parentURL: URL,
        targetURL: URL,
        deleting: Bool = false,
        token: PlanningCoordinationToken? = nil,
        accessor: @escaping (URL, URL) throws -> T
    ) throws -> T {
        try writeWithCancellationCheck(
            parentURL: parentURL,
            targetURL: targetURL,
            deleting: deleting,
            token: token
        ) { coordinatedParent, coordinatedTarget, _ in
            try accessor(coordinatedParent, coordinatedTarget)
        }
    }

    internal func writeWithCancellationCheck<T>(
        parentURL: URL,
        targetURL: URL,
        deleting: Bool = false,
        token: PlanningCoordinationToken? = nil,
        accessor: @escaping (URL, URL, @escaping () throws -> Void) throws -> T
    ) throws -> T {
        let expectedGeneration = token?.generation
        return try run(token: token, expectedGeneration: expectedGeneration) { state in
            try self.checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
            try self.validateFileURL(parentURL)
            try self.validateFileURL(targetURL)
            let expectedParent = parentURL.standardizedFileURL
            let expectedTarget = targetURL.standardizedFileURL
            guard self.isDescendant(expectedTarget, of: expectedParent) else {
                throw PlanningFilesystemError.invalid("coordination.target")
            }
            var coordinationError: NSError?
            var result: Result<T, Error>?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            self.register(coordinator, for: state)
            defer { self.unregister(coordinator, from: state) }
            let options: NSFileCoordinator.WritingOptions = deleting ? [.forDeleting] : [.forReplacing]
            coordinator.coordinate(
                writingItemAt: parentURL,
                options: [],
                writingItemAt: targetURL,
                options: options,
                error: &coordinationError
            ) { coordinatedParent, coordinatedTarget in
                do {
                    try self.checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
                    guard coordinatedParent.standardizedFileURL == expectedParent,
                          coordinatedParent.pathComponents == expectedParent.pathComponents,
                          coordinatedTarget.standardizedFileURL == expectedTarget,
                          coordinatedTarget.pathComponents == expectedTarget.pathComponents,
                          self.isDescendant(coordinatedTarget.standardizedFileURL, of: coordinatedParent.standardizedFileURL) else {
                        throw PlanningFilesystemError.identityChanged
                    }
                    let checkInAccessor: () throws -> Void = {
                        try self.checkCancellation(
                            state,
                            token: token,
                            expectedGeneration: expectedGeneration
                        )
                    }
                    try checkInAccessor()
                    let value = try accessor(coordinatedParent, coordinatedTarget, checkInAccessor)
                    try checkInAccessor()
                    result = .success(value)
                } catch {
                    result = .failure(error)
                }
            }
            if let result { return try result.get() }
            try self.checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
            if let coordinationError { throw mapCoordinationError(coordinationError) }
            throw PlanningFilesystemError.unavailable("coordination")
        }
    }

    public func cancel() {
        stateLock.lock()
        let states = Array(activeStates.values)
        stateLock.unlock()
        for state in states {
            let (operation, coordinator) = state.stop(.cancelled)
            coordinator?.cancel()
            operation?.cancel()
        }
    }

    private func run<T>(
        token: PlanningCoordinationToken?,
        expectedGeneration: UUID?,
        work: @escaping (PlanningCoordinationOperationState) throws -> T
    ) throws -> T {
        let state = PlanningCoordinationOperationState()
        let box = PlanningCoordinationResultBox<T>()
        let operation = BlockOperation {
            do {
                try self.checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
                let value = try work(state)
                box.lock.lock()
                box.result = .success(value)
                box.lock.unlock()
            } catch {
                box.lock.lock()
                box.result = .failure(error)
                box.lock.unlock()
            }
        }
        stateLock.lock()
        activeStates[state.id] = state
        stateLock.unlock()
        state.setOperation(operation)
        queue.addOperation(operation)
        let timeout = DispatchWorkItem { [weak operation, weak state] in
            guard let state, let operation else { return }
            let (ownedOperation, coordinator) = state.stop(.deadline)
            guard ownedOperation === operation else { return }
            coordinator?.cancel()
            operation.cancel()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + deadlineInterval,
            execute: timeout
        )
        operation.waitUntilFinished()
        timeout.cancel()
        state.clearOperation(operation)
        stateLock.lock()
        activeStates.removeValue(forKey: state.id)
        stateLock.unlock()
        box.lock.lock()
        let result = box.result
        box.lock.unlock()
        guard let result else {
            try checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
            throw PlanningFilesystemError.unavailable("coordination")
        }
        try checkCancellation(state, token: token, expectedGeneration: expectedGeneration)
        return try result.get()
    }

    private func register(
        _ coordinator: NSFileCoordinator,
        for state: PlanningCoordinationOperationState
    ) {
        state.setCoordinator(coordinator)
    }

    private func unregister(
        _ coordinator: NSFileCoordinator,
        from state: PlanningCoordinationOperationState
    ) {
        state.clearCoordinator(coordinator)
    }

    private func checkCancellation(
        _ state: PlanningCoordinationOperationState,
        token: PlanningCoordinationToken?,
        expectedGeneration: UUID?
    ) throws {
        if let failure = state.failureIfStopped() { throw failure }
        guard token?.isCancelled != true else { throw PlanningFilesystemError.cancelled }
        if let expectedGeneration, token?.generation != expectedGeneration {
            throw PlanningFilesystemError.identityChanged
        }
    }

    private func validateFileURL(_ url: URL) throws {
        guard url.isFileURL,
              !url.standardizedFileURL.pathComponents.contains("..") else {
            throw PlanningFilesystemError.invalid("coordination.url")
        }
    }

    private func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > parentComponents.count else { return false }
        return candidateComponents.prefix(parentComponents.count) == parentComponents[...]
    }
}

private func mapCoordinationError(_ error: NSError) -> PlanningFilesystemError {
    switch error.code {
    case NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError:
        return .diskFull
    case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
        return .permissionDenied
    case NSFileReadNoSuchFileError:
        return .notFound
    default:
        return .unavailable("coordinationError")
    }
}
