import Foundation
import UserNotifications

// MARK: - Native UserNotifications boundary

/// The notification authorization state exposed by the adapter.  Provisional
/// and ephemeral authorization are kept distinct from full authorization so
/// callers can present the exact system state without claiming more access
/// than the system granted.
public enum SupplementNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown(Int)

    public var canSchedule: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unknown:
            return false
        }
    }
}

/// A small protocol around UserNotifications.  It keeps the adapter
/// deterministic in unit tests while the production implementation remains a
/// thin pass-through to UNUserNotificationCenter.
public protocol SupplementNotificationCenter: AnyObject {
    func getAuthorizationStatus(
        completion: @escaping (SupplementNotificationAuthorizationStatus) -> Void
    )
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completion: @escaping (Result<Bool, Error>) -> Void
    )
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func getPendingNotificationRequests(
        completion: @escaping (Result<[UNNotificationRequest], Error>) -> Void
    )
    func add(
        _ request: UNNotificationRequest,
        completion: @escaping (Error?) -> Void
    )
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

/// Production UserNotifications wrapper.  The system API does not report an
/// error for settings, category registration, pending-request reads, or
/// removal, so those operations are represented as successful protocol calls.
/// Authorization and add failures cross this boundary as errors; the adapter
/// reduces them to stable public outcomes before presentation.
public final class SystemSupplementNotificationCenter: SupplementNotificationCenter {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func getAuthorizationStatus(
        completion: @escaping (SupplementNotificationAuthorizationStatus) -> Void
    ) {
        center.getNotificationSettings { settings in
            completion(Self.map(settings.authorizationStatus))
        }
    }

    public func requestAuthorization(
        options: UNAuthorizationOptions,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        center.requestAuthorization(options: options) { granted, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(granted))
            }
        }
    }

    public func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    public func getPendingNotificationRequests(
        completion: @escaping (Result<[UNNotificationRequest], Error>) -> Void
    ) {
        center.getPendingNotificationRequests { requests in
            completion(.success(requests))
        }
    }

    public func add(
        _ request: UNNotificationRequest,
        completion: @escaping (Error?) -> Void
    ) {
        center.add(request, withCompletionHandler: completion)
    }

    public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private static func map(
        _ status: UNAuthorizationStatus
    ) -> SupplementNotificationAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
#if os(iOS)
        case .ephemeral: return .ephemeral
#endif
        @unknown default: return .unknown(status.rawValue)
        }
    }
}

public enum SupplementNotificationPendingOutcome: Equatable, Sendable {
    /// Authorization did not permit scheduling, so no pending requests were
    /// added or removed.
    case notScheduled
    /// The requested set already matched the managed pending requests.
    case unchanged
    /// Reconciliation completed without add failures.
    case reconciled
    /// Some additions succeeded and at least one addition failed.  This is a
    /// pending-request result, never a delivery claim.
    case partialFailure
}

public struct SupplementNotificationReconciliation: Equatable, Sendable {
    public let authorizationStatus: SupplementNotificationAuthorizationStatus
    public let pendingOutcome: SupplementNotificationPendingOutcome
    public let addedIdentifiers: [String]
    public let removedIdentifiers: [String]
    public let unchangedIdentifiers: [String]
    public let failedIdentifiers: [String]
    public let errorMessages: [String]

    public init(
        authorizationStatus: SupplementNotificationAuthorizationStatus,
        pendingOutcome: SupplementNotificationPendingOutcome,
        addedIdentifiers: [String] = [],
        removedIdentifiers: [String] = [],
        unchangedIdentifiers: [String] = [],
        failedIdentifiers: [String] = [],
        errorMessages: [String] = []
    ) {
        self.authorizationStatus = authorizationStatus
        self.pendingOutcome = pendingOutcome
        self.addedIdentifiers = addedIdentifiers
        self.removedIdentifiers = removedIdentifiers
        self.unchangedIdentifiers = unchangedIdentifiers
        self.failedIdentifiers = failedIdentifiers
        self.errorMessages = errorMessages
    }
}

public enum SupplementNotificationAdapterError: Error, Equatable, Sendable {
    case invalidPlan(String)
    case invalidIntent(String)
    case pendingRequestsFailed
    case authorizationRequestFailed
    /// A UserNotifications callback did not arrive within the adapter's
    /// bounded operation window.  Durable state remains authoritative and a
    /// reconciliation timeout is never reported as success.
    case operationTimedOut
}

/// The delegate uses this small boundary instead of depending directly on
/// `UNUserNotificationCenter`.  It makes the durable-action-before-schedule
/// ordering testable without constructing `UNNotificationResponse` values on
/// platforms where those initializers are unavailable.
public protocol SupplementNotificationReconciler: AnyObject {
    func reconcile(
        snapshot: SupplementSnapshot,
        now: Date,
        completion: @escaping (Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void
    )
}

/// A thread-safe one-shot callback guard for UserNotifications operations.
/// The platform may deliver a late callback after the adapter's timeout; the
/// first terminal result wins and late callbacks become no-ops.
private final class SupplementNotificationOnceGate: @unchecked Sendable {
    // The center fakes and some UserNotifications implementations can invoke
    // a callback synchronously.  A recursive lock lets the callback inspect
    // or claim the same gate while the initial operation is still inside the
    // permit, without reopening the check/mutation race.
    private let lock = NSRecursiveLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !claimed
    }

    /// Starts one platform operation only while this reconciliation is still
    /// open.  The gate remains locked through the synchronous center call, so
    /// a timeout cannot claim the operation between the check and the center
    /// mutation; synchronous callbacks are safe because the lock is recursive.
    @discardableResult
    func performIfOpen(
        before deadline: SupplementNotificationDeadline,
        _ operation: () -> Void
    ) -> Bool {
        lock.lock()
        guard !claimed, !deadline.isExpired else {
            lock.unlock()
            return false
        }
        operation()
        lock.unlock()
        return true
    }
}

/// A monotonic wall-clock deadline shared by every stage of one
/// reconciliation.  Dispatch timers are still used as the lost-callback
/// wake-up, but callbacks also consult this value so a delayed timer cannot
/// turn an already-expired operation into a success.
private struct SupplementNotificationDeadline: Sendable {
    let dispatchTime: DispatchTime

    init(timeout: TimeInterval) {
        dispatchTime = .now() + timeout
    }

    var isExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= dispatchTime.uptimeNanoseconds
    }
}

public final class SupplementNotificationAdapter: SupplementNotificationReconciler {
    public static let maxPendingIntents = 64
    public static let defaultOperationTimeout: TimeInterval = 5
    public static let minimumOperationTimeout: TimeInterval = 0.001
    /// Hard input bound for callers constructing a plan outside the planner.
    /// It bounds validation and duplicate tracking as well as UserNotifications
    /// work; the pending request cap remains `maxPendingIntents`.
    public static let maxInputIntents = 4_096

    private let center: SupplementNotificationCenter
    private let operationTimeout: TimeInterval

    public init(
        center: SupplementNotificationCenter = SystemSupplementNotificationCenter(),
        operationTimeout: TimeInterval = 5
    ) {
        self.center = center
        guard operationTimeout.isFinite else {
            self.operationTimeout = Self.defaultOperationTimeout
            return
        }
        self.operationTimeout = operationTimeout > 0
            ? max(Self.minimumOperationTimeout, operationTimeout)
            : Self.defaultOperationTimeout
    }

    /// Registers the one category used by supplement reminders.  Repeating
    /// this call is harmless and is appropriate after boot, foregrounding, or
    /// a timezone change.
    public func registerActionsAndCategory() {
        center.setNotificationCategories([Self.category])
    }

    public func authorizationStatus(
        completion: @escaping (SupplementNotificationAuthorizationStatus) -> Void
    ) {
        let deadline = SupplementNotificationDeadline(timeout: operationTimeout)
        let gate = SupplementNotificationOnceGate()
        guard !deadline.isExpired else {
            completion(.unknown(-1))
            return
        }
        center.getAuthorizationStatus { status in
            guard gate.claim() else { return }
            completion(deadline.isExpired ? .unknown(-1) : status)
        }
        armTimeout(gate, deadline: deadline) {
            // Unknown is deliberately not schedulable; callers must not
            // claim permission when the platform callback was lost.
            completion(.unknown(-1))
        }
    }

    /// Requests only the permission needed for local supplement reminders.
    /// The boundary intentionally excludes badge authorization and reduces any
    /// system error to a stable public failure; callers must not display a
    /// private or localized system error description.
    public func requestAuthorization(
        completion: @escaping (Result<Bool, SupplementNotificationAdapterError>) -> Void
    ) {
        let deadline = SupplementNotificationDeadline(timeout: operationTimeout)
        let gate = SupplementNotificationOnceGate()
        guard !deadline.isExpired else {
            completion(.failure(.operationTimedOut))
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { result in
            guard gate.claim() else { return }
            guard !deadline.isExpired else {
                completion(.failure(.operationTimedOut))
                return
            }
            switch result {
            case .success(let granted):
                completion(.success(granted))
            case .failure:
                completion(.failure(.authorizationRequestFailed))
            }
        }
        armTimeout(gate, deadline: deadline) {
            completion(.failure(.operationTimedOut))
        }
    }

    /// Reconciles only the planner's bounded pending set.  The adapter does
    /// not own a supplement store, create demo plans, or mutate occurrences;
    /// callers provide the current planner result on every reconciliation.
    public func reconcile(
        plan: SupplementNotificationPlan,
        now: Date = .now,
        completion: @escaping (Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void
    ) {
        let deadline = SupplementNotificationDeadline(timeout: operationTimeout)
        reconcile(
            plan: plan,
            now: now,
            deadline: deadline,
            completion: completion
        )
    }

    private func reconcile(
        plan: SupplementNotificationPlan,
        now: Date,
        deadline: SupplementNotificationDeadline,
        completion: @escaping (Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void
    ) {
        let prepared: [(intent: SupplementNotificationIntent, request: UNNotificationRequest)]
        do {
            prepared = try prepare(plan: plan, now: now)
        } catch let error as SupplementNotificationAdapterError {
            completion(.failure(error))
            return
        } catch {
            completion(.failure(.invalidIntent("validation")))
            return
        }

        guard !deadline.isExpired else {
            completion(.failure(.operationTimedOut))
            return
        }

        let finishGate = SupplementNotificationOnceGate()
        let finish: (Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void = { result in
            guard finishGate.claim() else { return }
            completion(result)
        }
        // This is intentionally armed before the first center call.  The
        // per-operation timers below still make each lost callback progress,
        // but this gate bounds the entire reconciliation wall clock rather
        // than multiplying the timeout by the number of additions.
        armTimeout(finishGate, deadline: deadline) {
            completion(.failure(.operationTimedOut))
        }
        guard !deadline.isExpired else {
            finish(.failure(.operationTimedOut))
            return
        }
        let registered = finishGate.performIfOpen(before: deadline) {
            registerActionsAndCategory()
        }
        guard registered else {
            finish(.failure(.operationTimedOut))
            return
        }
        let authorizationGate = SupplementNotificationOnceGate()
        let authorizationStarted = finishGate.performIfOpen(before: deadline) {
            center.getAuthorizationStatus { status in
                guard authorizationGate.claim() else { return }
                guard finishGate.isOpen else { return }
                guard !deadline.isExpired else {
                    finish(.failure(.operationTimedOut))
                    return
                }
                guard status.canSchedule else {
                    finish(.success(SupplementNotificationReconciliation(
                        authorizationStatus: status,
                        pendingOutcome: .notScheduled
                    )))
                    return
                }

                let pendingGate = SupplementNotificationOnceGate()
                let pendingStarted = finishGate.performIfOpen(before: deadline) {
                    self.center.getPendingNotificationRequests { result in
                        guard pendingGate.claim() else { return }
                        guard finishGate.isOpen else { return }
                        guard !deadline.isExpired else {
                            finish(.failure(.operationTimedOut))
                            return
                        }
                        switch result {
                        case .failure(let error):
                            // Center errors are intentionally reduced to a stable
                            // public code.  System error descriptions can contain
                            // arbitrary/private text; callers still get the truthful
                            // failed operation and no scheduling result is claimed.
                            _ = error
                            finish(.failure(.pendingRequestsFailed))
                        case .success(let pending):
                            self.reconcilePrepared(
                                prepared,
                                pending: pending,
                                authorizationStatus: status,
                                finishGate: finishGate,
                                deadline: deadline,
                                completion: finish
                            )
                        }
                    }
                }
                guard pendingStarted else {
                    finish(.failure(.operationTimedOut))
                    return
                }
                self.armTimeout(pendingGate, deadline: deadline) {
                    finish(.failure(.operationTimedOut))
                }
            }
        }
        guard authorizationStarted else {
            finish(.failure(.operationTimedOut))
            return
        }
        armTimeout(authorizationGate, deadline: deadline) {
            finish(.failure(.operationTimedOut))
        }
    }

    /// Builds the planner output from the supplied durable snapshot and then
    /// reconciles the platform pending set.  The planner is deliberately
    /// strict: if the session/store did not materialize a matching occurrence,
    /// no request is created.
    public func reconcile(
        snapshot: SupplementSnapshot,
        now: Date,
        completion: @escaping (Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void
    ) {
        let deadline = SupplementNotificationDeadline(timeout: operationTimeout)
        do {
            let plan = try SupplementNotificationPlanner(
                now: now,
                lookAheadDays: SupplementNotificationPlanner.defaultLookAheadDays,
                maxPendingIntents: Self.maxPendingIntents
            ).plan(
                plans: snapshot.plans,
                occurrences: snapshot.occurrences,
                now: now
            )
            guard !deadline.isExpired else {
                completion(.failure(.operationTimedOut))
                return
            }
            reconcile(plan: plan, now: now, deadline: deadline, completion: completion)
        } catch {
            completion(.failure(.invalidPlan("snapshot")))
        }
    }

    public static let category: UNNotificationCategory = {
        let actions = [
            UNNotificationAction(
                identifier: SupplementNotificationActionIdentifier.taken,
                title: "Taken",
                options: [.authenticationRequired]
            ),
            UNNotificationAction(
                identifier: SupplementNotificationActionIdentifier.snooze,
                title: "Snooze",
                options: [.authenticationRequired]
            ),
            UNNotificationAction(
                identifier: SupplementNotificationActionIdentifier.skip,
                title: "Skip",
                options: [.authenticationRequired]
            ),
        ]
        return UNNotificationCategory(
            identifier: SupplementNotificationActionIdentifier.category,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }()

    private func prepare(
        plan: SupplementNotificationPlan,
        now: Date
    ) throws -> [(intent: SupplementNotificationIntent, request: UNNotificationRequest)] {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw SupplementNotificationAdapterError.invalidPlan("planner.now")
        }
        guard plan.maxPendingIntents >= 0 else {
            throw SupplementNotificationAdapterError.invalidPlan("maxPendingIntents")
        }
        guard plan.intents.count <= Self.maxInputIntents else {
            throw SupplementNotificationAdapterError.invalidPlan("intentCount")
        }
        do {
            try SupplementValidation.validateObserved(
                plan.evaluatedAt,
                field: "planner.evaluatedAt",
                now: now
            )
        } catch {
            throw SupplementNotificationAdapterError.invalidPlan("evaluatedAt")
        }

        var seenIdentifiers = Set<String>()
        // Validate every externally supplied intent before selecting the
        // bounded pending set.  Selection retains at most 64 values, so a
        // malformed value cannot hide behind the cap, while request creation
        // and subsequent center work remain bounded.
        for intent in plan.intents {
            do {
                try intent.validate()
            } catch {
                throw SupplementNotificationAdapterError.invalidIntent("validation")
            }
            guard intent.fireDate > now else {
                throw SupplementNotificationAdapterError.invalidIntent("fireDate must be in the future")
            }
            guard intent.identifier == SupplementNotificationPlanner.occurrenceRequestIdentifier(
                occurrenceID: intent.occurrenceIdentifier
            ) else {
                throw SupplementNotificationAdapterError.invalidIntent("occurrence request identifier")
            }
            guard intent.scheduleIdentifier == SupplementNotificationPlanner.scheduleIdentifier(
                planID: intent.planID
            ) else {
                throw SupplementNotificationAdapterError.invalidIntent("schedule identifier")
            }
            guard seenIdentifiers.insert(intent.identifier).inserted else {
                throw SupplementNotificationAdapterError.invalidIntent("duplicate identifier")
            }
        }

        let cap = min(Self.maxPendingIntents, plan.maxPendingIntents)
        guard cap > 0 else { return [] }

        // Planner output is already sorted, but this boundary is also safe
        // for callers constructing a plan directly.  Keep only the best cap
        // entries as we scan, rather than allocating or building requests for
        // unbounded input.
        var selected: [SupplementNotificationIntent] = []
        selected.reserveCapacity(cap)
        for intent in plan.intents {
            let insertionIndex = selected.firstIndex { isBefore(intent, $0) } ?? selected.endIndex
            selected.insert(intent, at: insertionIndex)
            if selected.count > cap {
                selected.removeLast()
            }
        }

        return try selected.map { intent in
            (intent: intent, request: try makeRequest(for: intent))
        }
    }

    private func isBefore(
        _ lhs: SupplementNotificationIntent,
        _ rhs: SupplementNotificationIntent
    ) -> Bool {
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        return lhs.identifier < rhs.identifier
    }

    private func reconcilePrepared(
        _ prepared: [(intent: SupplementNotificationIntent, request: UNNotificationRequest)],
        pending: [UNNotificationRequest],
        authorizationStatus: SupplementNotificationAuthorizationStatus,
        finishGate: SupplementNotificationOnceGate,
        deadline: SupplementNotificationDeadline,
        completion: @escaping (Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void
    ) {
        guard finishGate.isOpen else { return }
        guard !deadline.isExpired else {
            completion(.failure(.operationTimedOut))
            return
        }
        let desiredByID = Dictionary(uniqueKeysWithValues: prepared.map { ($0.intent.identifier, $0) })
        let managedPending = pending.filter { Self.isManagedIdentifier($0.identifier) }
        let pendingByID = Dictionary(uniqueKeysWithValues: managedPending.map { ($0.identifier, $0) })
        let desiredIdentifiers = Set(desiredByID.keys)
        let staleIdentifiers = pendingByID.keys
            .filter { !desiredIdentifiers.contains($0) }
            .sorted()

        let replacementIdentifiers = prepared.compactMap { item -> String? in
            guard let existing = pendingByID[item.intent.identifier],
                  !requestsMatch(existing, item.request) else {
                return nil
            }
            return item.intent.identifier
        }
        let identifiersToRemove = (staleIdentifiers + replacementIdentifiers).sorted()
        if !identifiersToRemove.isEmpty {
            // Removing a mismatched request first makes a snooze replacement
            // deterministic across UserNotifications implementations.  The
            // durable snooze already exists; a later add failure therefore
            // leaves truth intact and launch reconciliation can retry it.
            let removalStarted = finishGate.performIfOpen(before: deadline) {
                center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
            }
            guard removalStarted else {
                completion(.failure(.operationTimedOut))
                return
            }
        }

        let additions = prepared.compactMap { item -> (String, UNNotificationRequest)? in
            guard let existing = pendingByID[item.intent.identifier] else {
                return (item.intent.identifier, item.request)
            }
            return requestsMatch(existing, item.request) ? nil : (item.intent.identifier, item.request)
        }
        let unchanged = prepared.compactMap { item -> String? in
            guard let existing = pendingByID[item.intent.identifier], requestsMatch(existing, item.request) else {
                return nil
            }
            return item.intent.identifier
        }

        addSequentially(
            additions,
            index: 0,
            added: [],
            failed: [],
            errors: [],
            authorizationStatus: authorizationStatus,
            removedIdentifiers: identifiersToRemove,
            unchangedIdentifiers: unchanged,
            finishGate: finishGate,
            deadline: deadline,
            completion: completion
        )
    }

    private func addSequentially(
        _ additions: [(String, UNNotificationRequest)],
        index: Int,
        added: [String],
        failed: [String],
        errors: [String],
        authorizationStatus: SupplementNotificationAuthorizationStatus,
        removedIdentifiers: [String],
        unchangedIdentifiers: [String],
        finishGate: SupplementNotificationOnceGate,
        deadline: SupplementNotificationDeadline,
        timedOut: Bool = false,
        completion: @escaping (Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void
    ) {
        guard finishGate.isOpen else { return }
        guard !deadline.isExpired else {
            completion(.failure(.operationTimedOut))
            return
        }
        guard index < additions.count else {
            if timedOut {
                completion(.failure(.operationTimedOut))
                return
            }
            let outcome: SupplementNotificationPendingOutcome
            if !failed.isEmpty {
                outcome = .partialFailure
            } else if added.isEmpty && removedIdentifiers.isEmpty {
                outcome = .unchanged
            } else {
                outcome = .reconciled
            }
            completion(.success(SupplementNotificationReconciliation(
                authorizationStatus: authorizationStatus,
                pendingOutcome: outcome,
                addedIdentifiers: added,
                removedIdentifiers: removedIdentifiers,
                unchangedIdentifiers: unchangedIdentifiers,
                failedIdentifiers: failed,
                errorMessages: errors
            )))
            return
        }

        let (identifier, request) = additions[index]
        let addGate = SupplementNotificationOnceGate()
        let addStarted = finishGate.performIfOpen(before: deadline) {
            center.add(request) { error in
                guard addGate.claim() else { return }
                guard finishGate.isOpen else { return }
                guard !deadline.isExpired else {
                    completion(.failure(.operationTimedOut))
                    return
                }
                if error != nil {
                    self.addSequentially(
                        additions,
                        index: index + 1,
                        added: added,
                        failed: failed + [identifier],
                        errors: errors + ["addFailed"],
                        authorizationStatus: authorizationStatus,
                        removedIdentifiers: removedIdentifiers,
                        unchangedIdentifiers: unchangedIdentifiers,
                        finishGate: finishGate,
                        deadline: deadline,
                        timedOut: timedOut,
                        completion: completion
                    )
                } else {
                    self.addSequentially(
                        additions,
                        index: index + 1,
                        added: added + [identifier],
                        failed: failed,
                        errors: errors,
                        authorizationStatus: authorizationStatus,
                        removedIdentifiers: removedIdentifiers,
                        unchangedIdentifiers: unchangedIdentifiers,
                        finishGate: finishGate,
                        deadline: deadline,
                        timedOut: timedOut,
                        completion: completion
                    )
                }
            }
        }
        guard addStarted else {
            completion(.failure(.operationTimedOut))
            return
        }
        armTimeout(addGate, deadline: deadline) {
            guard finishGate.isOpen else { return }
            guard !deadline.isExpired else {
                completion(.failure(.operationTimedOut))
                return
            }
            self.addSequentially(
                additions,
                index: index + 1,
                added: added,
                failed: failed + [identifier],
                errors: errors + ["operationTimedOut"],
                authorizationStatus: authorizationStatus,
                removedIdentifiers: removedIdentifiers,
                unchangedIdentifiers: unchangedIdentifiers,
                finishGate: finishGate,
                deadline: deadline,
                timedOut: true,
                completion: completion
            )
        }
    }

    private func makeRequest(
        for intent: SupplementNotificationIntent
    ) throws -> UNNotificationRequest {
        guard let timeZone = TimeZone(identifier: intent.timeZoneIdentifier) else {
            throw SupplementNotificationAdapterError.invalidIntent("timeZoneIdentifier")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: intent.fireDate
        )
        components.timeZone = timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let content = UNMutableNotificationContent()
        content.title = intent.title
        content.body = intent.body
        content.categoryIdentifier = SupplementNotificationActionIdentifier.category
        content.userInfo = [
            SupplementNotificationActionIdentifier.planIDKey: intent.planID,
            SupplementNotificationActionIdentifier.occurrenceIDKey: intent.occurrenceIdentifier,
            SupplementNotificationActionIdentifier.actionTokenKey:
                try SupplementNotificationActionToken.make(
                    occurrenceID: intent.occurrenceIdentifier,
                    fireDate: intent.fireDate
                ),
            SupplementNotificationActionIdentifier.generationKey:
                try SupplementNotificationActionToken.make(
                    occurrenceID: intent.occurrenceIdentifier,
                    fireDate: intent.fireDate
                ),
            SupplementNotificationActionIdentifier.fireDateKey:
                SupplementNotificationActionToken.wireDate(intent.fireDate),
        ]
        content.sound = .default
        return UNNotificationRequest(identifier: intent.identifier, content: content, trigger: trigger)
    }

    private func armTimeout(
        _ gate: SupplementNotificationOnceGate,
        deadline: SupplementNotificationDeadline,
        action: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline.dispatchTime) {
            guard gate.claim() else { return }
            action()
        }
    }

    private func requestsMatch(
        _ existing: UNNotificationRequest,
        _ expected: UNNotificationRequest
    ) -> Bool {
        guard existing.identifier == expected.identifier,
              existing.content.title == expected.content.title,
              existing.content.body == expected.content.body,
              existing.content.categoryIdentifier == expected.content.categoryIdentifier,
              existing.content.userInfo.count == expected.content.userInfo.count,
              existing.content.userInfo[SupplementNotificationActionIdentifier.planIDKey] as? String ==
                expected.content.userInfo[SupplementNotificationActionIdentifier.planIDKey] as? String,
              existing.content.userInfo[SupplementNotificationActionIdentifier.occurrenceIDKey] as? String ==
                expected.content.userInfo[SupplementNotificationActionIdentifier.occurrenceIDKey] as? String,
              existing.content.userInfo[SupplementNotificationActionIdentifier.actionTokenKey] as? String ==
                expected.content.userInfo[SupplementNotificationActionIdentifier.actionTokenKey] as? String,
              existing.content.userInfo[SupplementNotificationActionIdentifier.generationKey] as? String ==
                expected.content.userInfo[SupplementNotificationActionIdentifier.generationKey] as? String,
              existing.content.userInfo[SupplementNotificationActionIdentifier.fireDateKey] as? String ==
                expected.content.userInfo[SupplementNotificationActionIdentifier.fireDateKey] as? String else {
            return false
        }
        guard let existingTrigger = existing.trigger as? UNCalendarNotificationTrigger,
              let expectedTrigger = expected.trigger as? UNCalendarNotificationTrigger else {
            return false
        }
        return existingTrigger.repeats == expectedTrigger.repeats &&
            existingTrigger.dateComponents == expectedTrigger.dateComponents
    }

    private static func isManagedIdentifier(_ identifier: String) -> Bool {
        let prefixes = [
            "lifeos.supplement.occurrence.",
            "lifeos.supplement.schedule.",
        ]
        guard let prefix = prefixes.first(where: { identifier.hasPrefix($0) }) else {
            return false
        }
        let suffix = String(identifier.dropFirst(prefix.count))
        guard !suffix.isEmpty else { return false }
        return (try? SupplementValidation.validateOpaqueID(suffix)) != nil
    }
}
