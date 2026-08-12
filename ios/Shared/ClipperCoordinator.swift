import Foundation
import Combine

public enum ClipperLoadState: Equatable, Sendable {
    case demo
    case loading
    case observed
    case stale
    case unavailable
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

    private let fetchSnapshot: @Sendable () async throws -> ClipperSnapshot
    private let staleAfter: TimeInterval
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    public init(
        client: ClipperSnapshotFetching = TailscaleSyncClient(),
        staleAfter: TimeInterval = 15 * 60,
        initialSnapshot: ClipperSnapshot? = nil,
        initialState: ClipperLoadState? = nil
    ) {
        self.fetchSnapshot = { try await client.fetchClipperSnapshot() }
        self.staleAfter = staleAfter
        let snapshot = initialSnapshot ?? .unavailable()
        self.snapshot = snapshot
        self.lastUpdated = snapshot.generatedAt
        self.state = Self.initialState(for: snapshot, requested: initialState, staleAfter: staleAfter)
    }

    public init(
        fetch: @escaping @Sendable () async throws -> ClipperSnapshot,
        staleAfter: TimeInterval = 15 * 60,
        initialSnapshot: ClipperSnapshot? = nil,
        initialState: ClipperLoadState? = nil
    ) {
        self.fetchSnapshot = fetch
        self.staleAfter = staleAfter
        let snapshot = initialSnapshot ?? .unavailable()
        self.snapshot = snapshot
        self.lastUpdated = snapshot.generatedAt
        self.state = Self.initialState(for: snapshot, requested: initialState, staleAfter: staleAfter)
    }

    public func refresh() async {
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
                    self.fail()
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
        errorMessage = nil

        if state == .demo { return }
        state = hasObservedSnapshot ? .stale : .unavailable
    }

    public func retry() async {
        await refresh()
    }

    private func apply(_ fetched: ClipperSnapshot) {
        snapshot = fetched
        lastUpdated = fetched.generatedAt
        state = Self.observationState(for: fetched, now: .now, staleAfter: staleAfter)
        errorMessage = state == .unavailable ? "Clipper data unavailable" : nil
    }

    private func fail() {
        errorMessage = "Clipper data unavailable"
        state = hasObservedSnapshot ? .stale : .unavailable
    }

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
