import Foundation
import Combine

public enum FinanceLoadState: Equatable, Sendable {
    case demo
    case loading
    case observed
    case stale
    case unavailable
}

public protocol FinanceSummaryFetching: Sendable {
    func fetchFinanceSummary() async throws -> FinanceSummary
}

extension TailscaleSyncClient: FinanceSummaryFetching {}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class FinanceCoordinator: ObservableObject {
    @Published public private(set) var state: FinanceLoadState
    @Published public private(set) var summary: FinanceSummary?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastUpdated: Date?

    private let fetchSummary: @Sendable () async throws -> FinanceSummary
    private let staleAfter: TimeInterval
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    public init(
        client: FinanceSummaryFetching = TailscaleSyncClient(),
        staleAfter: TimeInterval = 15 * 60,
        initialSummary: FinanceSummary? = nil,
        initialState: FinanceLoadState? = nil
    ) {
        self.fetchSummary = { try await client.fetchFinanceSummary() }
        self.staleAfter = staleAfter
        self.summary = initialSummary
        self.lastUpdated = initialSummary?.generatedAt
        self.state = Self.initialState(
            for: initialSummary,
            requested: initialState,
            staleAfter: staleAfter
        )
    }

    public init(
        fetch: @escaping @Sendable () async throws -> FinanceSummary,
        staleAfter: TimeInterval = 15 * 60,
        initialSummary: FinanceSummary? = nil,
        initialState: FinanceLoadState? = nil
    ) {
        self.fetchSummary = fetch
        self.staleAfter = staleAfter
        self.summary = initialSummary
        self.lastUpdated = initialSummary?.generatedAt
        self.state = Self.initialState(
            for: initialSummary,
            requested: initialState,
            staleAfter: staleAfter
        )
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
                let fetched = try await self.fetchSummary()
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

        if state == .demo {
            return
        }
        state = hasObservedSummary ? .stale : .unavailable
    }

    public func retry() async {
        await refresh()
    }

    private func apply(_ fetched: FinanceSummary) {
        summary = fetched
        lastUpdated = fetched.generatedAt
        state = Self.observationState(for: fetched, now: .now, staleAfter: staleAfter)
        errorMessage = state == .unavailable ? "Finance data unavailable" : nil
    }

    private func fail() {
        errorMessage = "Finance data unavailable"
        state = hasObservedSummary ? .stale : .unavailable
    }

    private var hasObservedSummary: Bool {
        guard let summary else { return false }
        return Self.hasObservedValue(in: summary)
    }

    private static func initialState(
        for summary: FinanceSummary?,
        requested: FinanceLoadState?,
        staleAfter: TimeInterval
    ) -> FinanceLoadState {
        if requested == .demo { return .demo }
        guard let summary else { return requested == .loading ? .loading : .unavailable }
        return observationState(for: summary, now: .now, staleAfter: staleAfter)
    }

    private static func observationState(
        for summary: FinanceSummary,
        now: Date,
        staleAfter: TimeInterval
    ) -> FinanceLoadState {
        guard hasObservedValue(in: summary) else { return .unavailable }
        let metrics = [
            summary.monthlyIncome,
            summary.fixedCosts,
            summary.discretionaryBuffer,
            summary.spent,
            summary.savingsGoal,
            summary.saved
        ]
        let stale = now.timeIntervalSince(summary.generatedAt) >= staleAfter
            || metrics.contains {
                guard $0.availability == .observed else { return false }
                return $0.provenance.freshness == .stale
                    || now.timeIntervalSince($0.provenance.observedAt) >= staleAfter
            }
            || (summary.transactions.map {
                guard $0.availability == .observed else { return false }
                return $0.provenance.freshness == .stale
                    || $0.provenance.connectorState == .refreshDue
                    || now.timeIntervalSince($0.provenance.observedAt) >= staleAfter
            } ?? false)
        return stale ? .stale : .observed
    }

    private static func hasObservedValue(in summary: FinanceSummary) -> Bool {
        [
            summary.monthlyIncome,
            summary.fixedCosts,
            summary.discretionaryBuffer,
            summary.spent,
            summary.savingsGoal,
            summary.saved
        ].contains { $0.availability == .observed && $0.amountCents != nil }
            || (summary.transactions.map {
                $0.availability == .observed && $0.transactions != nil
            } ?? false)
    }
}
