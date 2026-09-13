import Combine
import Foundation

// MARK: - Local notification permission presentation

/// UI-facing permission states.  `unknown` is intentionally distinct from
/// `error`: the system returned a status that this build does not recognize,
/// while `error` means the adapter could not complete an operation.
public enum SupplementNotificationPermissionState: Equatable, Sendable {
    case checking
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown
    case error
}

public enum SupplementNotificationPermissionStateMapper {
    public static func map(
        _ status: SupplementNotificationAuthorizationStatus
    ) -> SupplementNotificationPermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        case .unknown: return .unknown
        }
    }

    public static func canRequestPermission(
        for state: SupplementNotificationPermissionState,
        hasActionableSchedule: Bool
    ) -> Bool {
        state == .notDetermined && hasActionableSchedule
    }
}

/// The result of reconciling the bounded set of local pending requests.
///
/// These cases describe pending-request state only.  A reconciled request is
/// not a claim that the operating system delivered an alert.
public enum SupplementNotificationSchedulingState: Equatable, Sendable {
    case checking
    case notScheduled
    case unchanged(pendingCount: Int)
    case reconciled(addedCount: Int, removedCount: Int, pendingCount: Int)
    case partial(addedCount: Int, failedCount: Int, pendingCount: Int)
    case error
}

/// Main-actor coordinator for notification permission and local reminder
/// reconciliation.
///
/// The coordinator owns no persistence.  The current validated snapshot is
/// supplied by the Fitness session each time the screen appears or changes.
/// Every asynchronous callback carries a generation ID so an older status,
/// permission, or reconciliation result cannot overwrite newer UI state.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class SupplementNotificationPermissionCoordinator: ObservableObject {
    @Published public private(set) var state: SupplementNotificationPermissionState = .checking
    @Published public private(set) var schedulingState: SupplementNotificationSchedulingState = .checking

    private let adapter: SupplementNotificationAdapter
    private let planner: SupplementNotificationPlanner
    private let nowProvider: @Sendable () -> Date
    private var operationID = 0
    private var latestSnapshot: SupplementSnapshot?
    private var latestNow: Date?

    public init(
        adapter: SupplementNotificationAdapter = SupplementNotificationAdapter(),
        planner: SupplementNotificationPlanner = SupplementNotificationPlanner(),
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapter = adapter
        self.planner = planner
        self.nowProvider = nowProvider
    }

    /// Reads the current system setting and, when a snapshot is available,
    /// reconciles its explicit clock schedules if scheduling is authorized.
    public func refresh(
        snapshot: SupplementSnapshot? = nil,
        now: Date? = nil
    ) {
        if let snapshot {
            latestSnapshot = snapshot
        }
        let resolvedNow = now ?? nowProvider()
        latestNow = resolvedNow
        let operation = beginOperation()
        readAuthorization(for: operation, now: resolvedNow)
    }

    /// Re-reads authorization and reconciles the supplied validated snapshot.
    /// Unauthorized states return before the adapter can write any pending
    /// request.
    public func reconcile(
        snapshot: SupplementSnapshot,
        now: Date? = nil
    ) {
        latestSnapshot = snapshot
        let resolvedNow = now ?? nowProvider()
        latestNow = resolvedNow
        let operation = beginOperation()
        readAuthorization(for: operation, now: resolvedNow)
    }

    /// Starts the system prompt only when the current state is not determined.
    /// A successful grant registers the category/actions and immediately
    /// reconciles the latest snapshot.  It still reports pending requests,
    /// never delivery.
    public func requestPermission(
        snapshot: SupplementSnapshot? = nil,
        now: Date? = nil
    ) {
        if let snapshot {
            latestSnapshot = snapshot
        }
        let resolvedNow = now ?? nowProvider()
        latestNow = resolvedNow
        guard state == .notDetermined else { return }

        let operation = beginOperation()
        adapter.requestAuthorization { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operation else { return }

                switch result {
                case .failure:
                    self.state = .error
                    self.schedulingState = .error
                case .success(let granted):
                    guard granted else {
                        self.readAuthorization(for: operation, now: resolvedNow)
                        return
                    }
                    self.adapter.registerActionsAndCategory()
                    self.readAuthorization(for: operation, now: resolvedNow)
                }
            }
        }
    }

    private func readAuthorization(for operation: Int, now: Date) {
        adapter.authorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operation else { return }
                self.state = SupplementNotificationPermissionStateMapper.map(status)
                self.reconcileAfterAuthorization(status, operation: operation, now: now)
            }
        }
    }

    private func reconcileAfterAuthorization(
        _ status: SupplementNotificationAuthorizationStatus,
        operation: Int,
        now: Date
    ) {
        guard let snapshot = latestSnapshot else {
            schedulingState = .notScheduled
            return
        }
        guard status.canSchedule else {
            // Do not call adapter.reconcile here: even category registration
            // and pending-request reads are unnecessary while unauthorized.
            schedulingState = .notScheduled
            return
        }

        let plan: SupplementNotificationPlan
        do {
            plan = try planner.plan(
                plans: snapshot.plans,
                occurrences: snapshot.occurrences,
                now: now
            )
        } catch {
            schedulingState = .error
            return
        }

        adapter.reconcile(plan: plan, now: now) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operation else { return }
                self.apply(result)
            }
        }
    }

    private func apply(
        _ result: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>
    ) {
        switch result {
        case .failure:
            schedulingState = .error
        case .success(let reconciliation):
            state = SupplementNotificationPermissionStateMapper.map(reconciliation.authorizationStatus)
            switch reconciliation.pendingOutcome {
            case .notScheduled:
                schedulingState = .notScheduled
            case .unchanged:
                schedulingState = .unchanged(
                    pendingCount: reconciliation.unchangedIdentifiers.count
                )
            case .reconciled:
                schedulingState = .reconciled(
                    addedCount: reconciliation.addedIdentifiers.count,
                    removedCount: reconciliation.removedIdentifiers.count,
                    pendingCount: reconciliation.addedIdentifiers.count + reconciliation.unchangedIdentifiers.count
                )
            case .partialFailure:
                schedulingState = .partial(
                    addedCount: reconciliation.addedIdentifiers.count,
                    failedCount: reconciliation.failedIdentifiers.count,
                    pendingCount: reconciliation.addedIdentifiers.count + reconciliation.unchangedIdentifiers.count
                )
            }
        }
    }

    private func beginOperation() -> Int {
        operationID &+= 1
        state = .checking
        schedulingState = .checking
        return operationID
    }
}
