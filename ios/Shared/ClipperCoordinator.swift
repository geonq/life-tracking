import Foundation
import Combine

public enum ClipperLoadState: Equatable, Sendable {
    case demo
    case loading
    case observed
    case stale
    case unavailable
}

/// Error/status detail kept beside the legacy load-state enum so Settings and
/// Overview can continue to compile their exhaustive state presentation while
/// a detail surface can distinguish transport, payload, stale, and revoke
/// failures.
public enum ClipperFailureState: String, Codable, Equatable, Sendable {
    case none
    case transport
    case invalidPayload
    case sourceUnavailable
    case stale
    case revoked
    case storage
}

public protocol ClipperRevocationPersistence {
    func isRevoked() -> Bool
    func setRevoked(_ revoked: Bool) throws
}

public final class UserDefaultsClipperRevocationPersistence: ClipperRevocationPersistence {
    public static let defaultKey = "LifeOS.Clipper.locallyRevoked.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func isRevoked() -> Bool { defaults.bool(forKey: key) }

    public func setRevoked(_ revoked: Bool) throws {
        defaults.set(revoked, forKey: key)
    }
}

public protocol ClipperSnapshotFetching: Sendable {
    func fetchClipperSnapshot() async throws -> ClipperSnapshot
}

extension TailscaleSyncClient: ClipperSnapshotFetching {}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class ClipperCoordinator: ObservableObject {
    @Published public private(set) var snapshot: ClipperSnapshot
    @Published public private(set) var state: ClipperLoadState
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var failure: ClipperFailureState
    @Published public private(set) var isLocallyRevoked: Bool

    private let fetchSnapshot: @Sendable () async throws -> ClipperSnapshot
    private let staleAfter: TimeInterval
    private let revocationPersistence: ClipperRevocationPersistence
    private let sourceApproval: ClipperSourceApproval?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    public init(
        client: ClipperSnapshotFetching = TailscaleSyncClient(),
        staleAfter: TimeInterval = 15 * 60,
        initialSnapshot: ClipperSnapshot? = nil,
        initialState: ClipperLoadState? = nil,
        revocationPersistence: ClipperRevocationPersistence = UserDefaultsClipperRevocationPersistence(),
        sourceApproval: ClipperSourceApproval? = nil
    ) {
        self.fetchSnapshot = { try await client.fetchClipperSnapshot() }
        self.staleAfter = staleAfter
        self.revocationPersistence = revocationPersistence
        self.sourceApproval = sourceApproval
        let persistedRevocation = revocationPersistence.isRevoked()
        let suppliedSnapshot = initialSnapshot ?? .unavailable()
        let canPresentInitial = suppliedSnapshot.availability == .unavailable
            || sourceApproval?.permits(suppliedSnapshot) == true
        let blockedByApproval = !persistedRevocation
            && suppliedSnapshot.availability == .observed && !canPresentInitial
        let snapshot = persistedRevocation || blockedByApproval ? .unavailable() : suppliedSnapshot
        self.snapshot = snapshot
        self.lastUpdated = snapshot.generatedAt
        self.isLocallyRevoked = persistedRevocation
        self.failure = persistedRevocation ? .revoked : (blockedByApproval ? .sourceUnavailable : .none)
        self.errorMessage = persistedRevocation
            ? "Clipper is revoked locally; reconnect only after an approved source is available"
            : blockedByApproval
            ? Self.approvalRequiredMessage
            : nil
        self.state = persistedRevocation || blockedByApproval
            ? .unavailable
            : Self.initialState(for: snapshot, requested: initialState, staleAfter: staleAfter)
    }

    public init(
        fetch: @escaping @Sendable () async throws -> ClipperSnapshot,
        staleAfter: TimeInterval = 15 * 60,
        initialSnapshot: ClipperSnapshot? = nil,
        initialState: ClipperLoadState? = nil,
        revocationPersistence: ClipperRevocationPersistence = UserDefaultsClipperRevocationPersistence(),
        sourceApproval: ClipperSourceApproval? = nil
    ) {
        self.fetchSnapshot = fetch
        self.staleAfter = staleAfter
        self.revocationPersistence = revocationPersistence
        self.sourceApproval = sourceApproval
        let persistedRevocation = revocationPersistence.isRevoked()
        let suppliedSnapshot = initialSnapshot ?? .unavailable()
        let canPresentInitial = suppliedSnapshot.availability == .unavailable
            || sourceApproval?.permits(suppliedSnapshot) == true
        let blockedByApproval = !persistedRevocation
            && suppliedSnapshot.availability == .observed && !canPresentInitial
        let snapshot = persistedRevocation || blockedByApproval ? .unavailable() : suppliedSnapshot
        self.snapshot = snapshot
        self.lastUpdated = snapshot.generatedAt
        self.isLocallyRevoked = persistedRevocation
        self.failure = persistedRevocation ? .revoked : (blockedByApproval ? .sourceUnavailable : .none)
        self.errorMessage = persistedRevocation
            ? "Clipper is revoked locally; reconnect only after an approved source is available"
            : blockedByApproval
            ? Self.approvalRequiredMessage
            : nil
        self.state = persistedRevocation || blockedByApproval
            ? .unavailable
            : Self.initialState(for: snapshot, requested: initialState, staleAfter: staleAfter)
    }

    public func refresh() async {
        guard state != .demo else { return }
        guard !isLocallyRevoked else {
            state = .unavailable
            failure = .revoked
            errorMessage = "Clipper is revoked locally; reconnect only after an approved source is available"
            return
        }
        guard sourceApproval?.isUsable == true else {
            state = .unavailable
            failure = .sourceUnavailable
            errorMessage = Self.approvalRequiredMessage
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration

        if let previous = refreshTask {
            previous.cancel()
            await previous.value
        }
        guard generation == refreshGeneration else { return }

        let operation = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.state = .loading
                self.failure = .none
                self.errorMessage = nil
            }
            do {
                try Task.checkCancellation()
                let fetched = try await self.fetchSnapshot()
                try Task.checkCancellation()
                await MainActor.run {
                    guard generation == self.refreshGeneration else { return }
                    self.apply(fetched)
                }
            } catch is CancellationError {
                // A newer refresh or lifecycle cancellation owns the next truthful state.
            } catch {
                await MainActor.run {
                    guard generation == self.refreshGeneration else { return }
                    self.fail(error)
                }
            }
        }
        refreshTask = operation
        await operation.value
        if generation == refreshGeneration {
            refreshTask = nil
        }
    }

    public func cancel() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        if !isLocallyRevoked { errorMessage = nil }

        if state == .demo || isLocallyRevoked { return }
        state = hasObservedSnapshot ? .stale : .unavailable
    }

    public func retry() async {
        await refresh()
    }

    /// Revokes the local client connection marker and clears the local
    /// snapshot. This does not claim that a remote provider was revoked; a
    /// remote revoke remains an operator/API action outside the current
    /// approved Clipper source boundary.
    public func revokeLocally() {
        do {
            try revocationPersistence.setRevoked(true)
        } catch {
            failure = .storage
            errorMessage = "Clipper revoke state could not be stored"
            return
        }
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isLocallyRevoked = true
        snapshot = .unavailable()
        lastUpdated = snapshot.generatedAt
        state = .unavailable
        failure = .revoked
        errorMessage = "Clipper is revoked locally; reconnect only after an approved source is available"
    }

    /// Clears only the local revoke marker. It intentionally leaves the
    /// coordinator unavailable until a later refresh returns a validated,
    /// approved-source snapshot.
    public func clearLocalRevocation() {
        do {
            try revocationPersistence.setRevoked(false)
        } catch {
            failure = .storage
            errorMessage = "Clipper revoke state could not be cleared"
            return
        }
        isLocallyRevoked = false
        snapshot = .unavailable()
        lastUpdated = snapshot.generatedAt
        state = .unavailable
        failure = .sourceUnavailable
        errorMessage = Self.approvalRequiredMessage
    }

    private func apply(_ fetched: ClipperSnapshot) {
        guard !isLocallyRevoked else { return }
        if fetched.availability == .observed,
           sourceApproval?.permits(fetched) != true {
            snapshot = .unavailable()
            lastUpdated = snapshot.generatedAt
            state = .unavailable
            failure = .sourceUnavailable
            errorMessage = Self.approvalRequiredMessage
            return
        }
        snapshot = fetched
        lastUpdated = fetched.generatedAt
        state = Self.observationState(for: fetched, now: .now, staleAfter: staleAfter)
        if fetched.availability == .unavailable {
            failure = .sourceUnavailable
            errorMessage = "Clipper source unavailable; no approved provider data is connected"
        } else if state == .stale {
            failure = .stale
            errorMessage = "Clipper data is stale; retry the connector"
        } else {
            failure = .none
            errorMessage = nil
        }
    }

    private func fail(_ error: Error) {
        if error is ClipperPayloadError || error is DecodingError {
            failure = .invalidPayload
            errorMessage = "Clipper payload unavailable"
        } else {
            failure = .transport
            errorMessage = "Clipper source unavailable; retry the connector"
        }
        state = hasObservedSnapshot ? .stale : .unavailable
    }

    private static let approvalRequiredMessage =
        "Clipper unavailable until its authoritative source and fields are approved"

    private var hasObservedSnapshot: Bool {
        snapshot.availability == .observed
    }

    private static func initialState(
        for snapshot: ClipperSnapshot,
        requested: ClipperLoadState?,
        staleAfter: TimeInterval
    ) -> ClipperLoadState {
        if requested == .demo { return .demo }
        return observationState(for: snapshot, now: .now, staleAfter: staleAfter)
    }

    private static func observationState(
        for snapshot: ClipperSnapshot,
        now: Date,
        staleAfter: TimeInterval
    ) -> ClipperLoadState {
        guard snapshot.availability == .observed else { return .unavailable }
        let stale = snapshot.provenance.freshness == .stale
            || now.timeIntervalSince(snapshot.generatedAt) >= staleAfter
            || now.timeIntervalSince(snapshot.provenance.observedAt) >= staleAfter
        return stale ? .stale : .observed
    }
}
