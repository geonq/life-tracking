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

public protocol FinanceReadbackFetching: Sendable {
    func fetchFinanceReadback() async throws -> FinanceReadbackResult
}

extension TailscaleSyncClient: FinanceSummaryFetching {}
extension TailscaleSyncClient: FinanceReadbackFetching {}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class FinanceCoordinator: ObservableObject {
    @Published public private(set) var state: FinanceLoadState
    /// Finance-only detail state. The app-wide `state` intentionally keeps its
    /// existing cases so unrelated views do not need to change.
    @Published public private(set) var observationState: FinanceObservationState
    @Published public private(set) var summary: FinanceSummary?
    @Published public private(set) var readback: FinanceReadback?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastUpdated: Date?

    private let fetchSummary: @Sendable () async throws -> FinanceSummary
    private let fetchReadback: (@Sendable () async throws -> FinanceReadbackResult)?
    private let staleAfter: TimeInterval
    private let clock: @Sendable () -> Date
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var lastSettledRefreshFailureMessage: String?

    public init(
        client: FinanceSummaryFetching = TailscaleSyncClient(),
        staleAfter: TimeInterval = 15 * 60,
        initialSummary: FinanceSummary? = nil,
        initialState: FinanceLoadState? = nil,
        initialReadback: FinanceReadback? = nil,
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fetchSummary = { try await client.fetchFinanceSummary() }
        if let readbackClient = client as? any FinanceReadbackFetching {
            self.fetchReadback = { try await readbackClient.fetchFinanceReadback() }
        } else {
            self.fetchReadback = nil
        }
        self.staleAfter = staleAfter
        self.clock = clock
        self.summary = initialSummary
        self.readback = initialReadback
        self.lastUpdated = initialSummary?.generatedAt
        self.lastSettledRefreshFailureMessage = nil
        let initialNow = clock()
        self.state = Self.initialState(
            for: initialSummary,
            readback: initialReadback,
            requested: initialState,
            now: initialNow,
            staleAfter: staleAfter
        )
        self.observationState = Self.initialObservationState(
            for: initialSummary,
            readback: initialReadback,
            requested: initialState,
            now: initialNow,
            staleAfter: staleAfter
        )
    }

    public init(
        fetch: @escaping @Sendable () async throws -> FinanceSummary,
        staleAfter: TimeInterval = 15 * 60,
        initialSummary: FinanceSummary? = nil,
        initialState: FinanceLoadState? = nil,
        initialReadback: FinanceReadback? = nil,
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fetchSummary = fetch
        self.fetchReadback = nil
        self.staleAfter = staleAfter
        self.clock = clock
        self.summary = initialSummary
        self.readback = initialReadback
        self.lastUpdated = initialSummary?.generatedAt
        self.lastSettledRefreshFailureMessage = nil
        let initialNow = clock()
        self.state = Self.initialState(
            for: initialSummary,
            readback: initialReadback,
            requested: initialState,
            now: initialNow,
            staleAfter: staleAfter
        )
        self.observationState = Self.initialObservationState(
            for: initialSummary,
            readback: initialReadback,
            requested: initialState,
            now: initialNow,
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
                self.observationState = .loading
                self.errorMessage = nil
            }
            do {
                try Task.checkCancellation()
                let fetched: FinanceSummary
                let fetchedReadback: FinanceReadback?
                if let fetchReadback = self.fetchReadback {
                    let result = try await fetchReadback()
                    fetched = result.summary
                    fetchedReadback = result.readback
                } else {
                    fetched = try await self.fetchSummary()
                    fetchedReadback = nil
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard generation == self.refreshGeneration else { return }
                    self.apply(fetched, readback: fetchedReadback)
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

        // A failed refresh is already a published observation. Cancellation
        // must not turn that failure into a quiet cached state. Keep this
        // separate from the transient loading state because a retry clears
        // the published error before the next request settles.
        let settledFailureMessage = lastSettledRefreshFailureMessage
            ?? (observationState == .error ? "Finance data unavailable" : nil)

        if state == .demo {
            return
        }
        state = hasObservedSummary ? .stale : .unavailable
        if let settledFailureMessage {
            errorMessage = settledFailureMessage
            observationState = .error
            return
        }

        errorMessage = nil
        let now = clock()
        observationState = summary.map {
            Self.reconciledObservationState(
                for: $0,
                readback: readback,
                now: now,
                staleAfter: staleAfter
            )
        } ?? .unavailable
    }

    public func retry() async {
        await refresh()
    }

    private func apply(_ fetched: FinanceSummary, readback: FinanceReadback?) {
        lastSettledRefreshFailureMessage = nil
        summary = fetched
        self.readback = readback
        lastUpdated = fetched.generatedAt
        let now = clock()
        let summaryState = Self.observationState(for: fetched, now: now, staleAfter: staleAfter)
        let currentObservationState = Self.reconciledObservationState(
            for: fetched,
            readback: readback,
            now: now,
            staleAfter: staleAfter
        )
        state = Self.loadState(for: currentObservationState, fallback: summaryState)
        observationState = currentObservationState
        errorMessage = state == .unavailable ? "Finance data unavailable" : nil
    }

    private func fail() {
        let message = "Finance data unavailable"
        lastSettledRefreshFailureMessage = message
        errorMessage = message
        observationState = .error
        state = hasObservedSummary ? .stale : .unavailable
    }

    private var hasObservedSummary: Bool {
        guard let summary else { return false }
        return Self.hasObservedValue(in: summary)
    }

    private static func initialState(
        for summary: FinanceSummary?,
        readback: FinanceReadback?,
        requested: FinanceLoadState?,
        now: Date,
        staleAfter: TimeInterval
    ) -> FinanceLoadState {
        if requested == .demo { return .demo }
        guard let summary else { return requested == .loading ? .loading : .unavailable }
        let fallback = observationState(for: summary, now: now, staleAfter: staleAfter)
        let currentObservationState = reconciledObservationState(
            for: summary,
            readback: readback,
            now: now,
            staleAfter: staleAfter
        )
        return loadState(for: currentObservationState, fallback: fallback)
    }

    private static func initialObservationState(
        for summary: FinanceSummary?,
        readback: FinanceReadback?,
        requested: FinanceLoadState?,
        now: Date,
        staleAfter: TimeInterval
    ) -> FinanceObservationState {
        if requested == .demo { return .demo }
        guard let summary else { return requested == .loading ? .loading : .unavailable }
        return reconciledObservationState(
            for: summary,
            readback: readback,
            now: now,
            staleAfter: staleAfter
        )
    }

    /// Re-evaluates a cached readback against the current summary timestamps.
    /// The readback's consent/unavailable and stale decisions remain explicit;
    /// observed and partial values are downgraded when the summary or any
    /// source provenance has crossed the coordinator's freshness boundary.
    private static func reconciledObservationState(
        for summary: FinanceSummary,
        readback: FinanceReadback?,
        now: Date,
        staleAfter: TimeInterval
    ) -> FinanceObservationState {
        let assessmentState = summary.financeAssessment(now: now, staleAfter: staleAfter).state
        let timestampState = observationState(for: summary, now: now, staleAfter: staleAfter)

        func applyingTimestampState(to state: FinanceObservationState) -> FinanceObservationState {
            switch timestampState {
            case .stale:
                return .stale
            case .unavailable:
                return .unavailable
            case .observed:
                return state
            case .demo, .loading:
                return state
            }
        }

        guard let readback else {
            return applyingTimestampState(to: assessmentState)
        }

        switch readback.assessment.availability {
        case .unavailable:
            return .unavailable
        case .stale:
            return .stale
        case .partial:
            return applyingTimestampState(to: assessmentState == .stale ? .stale : .partial)
        case .observed:
            switch assessmentState {
            case .observed: return applyingTimestampState(to: .observed)
            case .partial: return applyingTimestampState(to: .partial)
            case .stale: return .stale
            case .unavailable: return .unavailable
            case .demo, .loading, .error:
                // FinanceSummary.financeAssessment does not produce these
                // transient states, but never let an unavailable timestamp
                // state turn a cached summary into an observed value.
                return applyingTimestampState(to: .unavailable)
            }
        }
    }

    private static func loadState(
        for observationState: FinanceObservationState?,
        fallback: FinanceLoadState
    ) -> FinanceLoadState {
        switch observationState {
        case .some(.stale): return .stale
        case .some(.unavailable): return .unavailable
        case .some(.loading): return .loading
        case .some(.demo): return .demo
        case .some(.partial), .some(.observed): return fallback == .stale ? .stale : .observed
        case .some(.error): return fallback == .unavailable ? .unavailable : .stale
        case .none: return fallback
        }
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
                    || ($0.transactions ?? []).contains(where: { row in
                        provenanceIsStale(row.provenance, now: now, staleAfter: staleAfter)
                    })
            } ?? false)
            || (summary.accounts.map {
                guard hasObservedAccounts(in: summary) else { return false }
                return provenanceIsStale($0.provenance, now: now, staleAfter: staleAfter)
                    || ($0.accounts ?? []).contains {
                        $0.availability == .observed
                            && provenanceIsStale($0.provenance, now: now, staleAfter: staleAfter)
                    }
            } ?? false)
            || (summary.wealth.map {
                guard $0.availability == .observed, $0.observedValueCents != nil else { return false }
                return provenanceIsStale($0.provenance, now: now, staleAfter: staleAfter)
                    || ($0.holdings ?? []).contains {
                        $0.availability == .observed
                            && provenanceIsStale($0.provenance, now: now, staleAfter: staleAfter)
                    }
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
            || hasObservedAccounts(in: summary)
            || (summary.wealth.map {
                $0.availability == .observed && $0.observedValueCents != nil
            } ?? false)
    }

    /// Accounts are a first-class observation source. A summary containing no
    /// metric totals can still be truthful when its account envelope and every
    /// account row carry observed, source-backed provenance.
    private static func hasObservedAccounts(in summary: FinanceSummary) -> Bool {
        guard let snapshot = summary.accounts,
              snapshot.availability == .observed,
              isUsableObservedProvenance(snapshot.provenance),
              let accounts = snapshot.accounts,
              !accounts.isEmpty else {
            return false
        }
        return accounts.contains {
            $0.availability == .observed
                && $0.balanceCents != nil
                && isUsableObservedProvenance($0.provenance)
        }
    }

    private static func isUsableObservedProvenance(_ provenance: FinancePayloadProvenance) -> Bool {
        provenance.quality == .observed
            && provenance.freshness != .unknown
            && (provenance.connectorState == .healthy || provenance.connectorState == .refreshDue)
    }

    private static func provenanceIsStale(
        _ provenance: FinancePayloadProvenance,
        now: Date,
        staleAfter: TimeInterval
    ) -> Bool {
        provenance.freshness == .stale
            || provenance.connectorState == .refreshDue
            || now.timeIntervalSince(provenance.observedAt) >= staleAfter
    }
}
