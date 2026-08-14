import Foundation
import UserNotifications

/// The production UserNotifications delegate for supplement reminders.
///
/// The delegate deliberately performs no UI work and has no in-memory session
/// authority.  It rereads the Application-Support snapshot for every response,
/// applies a reducer transaction, and only then returns to UserNotifications.
/// This makes the same code valid for foreground, background, and terminated
/// launches; relaunch installs a fresh delegate against the same durable file.
public final class SupplementNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private static let installationLock = NSLock()
    private static var installedDelegate: SupplementNotificationDelegate?

    private let store: SupplementStore?
    private let reconciler: SupplementNotificationReconciler?
    private let nowProvider: @Sendable () -> Date
    private let reconcilerTimeout: TimeInterval
    private let outcomeLock = NSLock()

    private let notificationDeviceID = "lifeos-notification"
    private let snoozeInterval: TimeInterval = 5 * 60

    /// This is intentionally an internal outcome, not a claim shown to the
    /// user.  UserNotifications has no error completion channel, so retaining
    /// the outcome gives tests and diagnostics a truthful distinction between
    /// durable-only and durable-plus-pending reconciliation.
    public enum ActionOutcome: Equatable, Sendable {
        case ignored
        case rejected
        case durableOnly
        /// The action is durable, but the adapter truthfully reported that
        /// no pending request could be scheduled (for example, permission was
        /// denied, unresolved, or otherwise not schedulable).
        case durableNotScheduled
        case durableAndReconciled
        case durableReconcileFailed
    }

    private var actionOutcome: ActionOutcome = .ignored

    public var lastActionOutcome: ActionOutcome {
        outcomeLock.lock()
        defer { outcomeLock.unlock() }
        return actionOutcome
    }

    public init(
        store: SupplementStore? = nil,
        reconciler: SupplementNotificationReconciler? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        reconcilerTimeout: TimeInterval = 5
    ) {
        self.store = store ?? (try? SupplementStore())
        self.reconciler = reconciler
        self.nowProvider = nowProvider
        self.reconcilerTimeout = max(0, reconcilerTimeout)
        super.init()
    }

    /// Installs the production delegate and retains it for the lifetime of the
    /// process.  `UNUserNotificationCenter.delegate` is weak; assigning a local
    /// object without retaining it would silently lose action delivery.
    public static func install(
        center: UNUserNotificationCenter = .current(),
        store: SupplementStore? = nil,
        reconciler: SupplementNotificationReconciler? = nil
    ) {
        let delegate = SupplementNotificationDelegate(
            store: store,
            reconciler: reconciler ?? SupplementNotificationAdapter(
                center: SystemSupplementNotificationCenter(center: center)
            )
        )
        installationLock.lock()
        installedDelegate = delegate
        installationLock.unlock()
        center.delegate = delegate
        delegate.reconcileAtLaunch()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        _ = center
        let content = notification.request.content
        let userInfo = content.userInfo.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String, let value = entry.value as? String else { return }
            result[key] = value
        }
        handleWillPresent(
            categoryIdentifier: content.categoryIdentifier,
            userInfo: userInfo,
            now: nowProvider(),
            completion: completion
        )
    }

    /// Testable foreground-presentation boundary.  Invalid or terminal
    /// envelopes are suppressed; valid current occurrences receive banner and
    /// sound without mutating durable state.
    public func handleWillPresent(
        categoryIdentifier: String,
        userInfo: [String: String],
        now: Date,
        completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        do {
            let envelope = try decodeEnvelope(
                categoryIdentifier: categoryIdentifier,
                userInfo: userInfo
            )
            try validateCurrentNotification(envelope, now: now)
            completion([.banner, .sound])
        } catch {
            completion([])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        _ = center
        let content = response.notification.request.content
        let userInfo = content.userInfo.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String, let value = entry.value as? String else { return }
            result[key] = value
        }
        handleAction(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: content.categoryIdentifier,
            userInfo: userInfo,
            completion: completion
        )
    }

    /// Testable action boundary used by the UN delegate and by integration
    /// tests.  The platform's `UNNotificationResponse` initializer is not
    /// available on every SDK, but the signed content/action envelope is the
    /// actual security boundary and can be exercised deterministically.
    public func handleAction(
        actionIdentifier: String,
        categoryIdentifier: String,
        userInfo: [String: String],
        completion: @escaping () -> Void
    ) {
        guard actionIdentifier != UNNotificationDefaultActionIdentifier,
              actionIdentifier != UNNotificationDismissActionIdentifier else {
            // Tapping or dismissing an alert has no occurrence mutation.  The
            // completion is still truthful and immediate.
            finishAction(.ignored, completion: completion)
            return
        }

        do {
            let envelope = try decodeEnvelope(
                categoryIdentifier: categoryIdentifier,
                userInfo: userInfo
            )
            let action = try SupplementNotificationActionDecoder.decode(
                actionIdentifier: actionIdentifier,
                userInfo: userInfo,
                categoryIdentifier: envelope.categoryIdentifier
            )
            let now = nowProvider()
            let state = try transact(action: action, envelope: envelope, now: now)
            guard case .snooze = action else {
                finishAction(.durableOnly, completion: completion)
                return
            }

            // The reducer transaction has completed before this callback is
            // entered.  Never block the notification delegate thread waiting
            // for a center callback: completion is delivered from the
            // injectable reconciler's completion, including failure.
            guard let reconciler else {
                finishAction(.durableReconcileFailed, completion: completion)
                return
            }

            let gate = SupplementNotificationCompletionGate()
            // UserNotifications does not provide a typed error if a platform
            // callback is lost.  Schedule the fallback before entering the
            // reconciler so even a synchronously blocked/misbehaving adapter
            // cannot hold the system delegate completion indefinitely.
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + reconcilerTimeout
            ) { [weak self] in
                guard gate.claim() else { return }
                self?.setActionOutcome(.durableReconcileFailed)
                completion()
            }
            reconciler.reconcile(snapshot: state.snapshot, now: now) { [weak self] result in
                guard gate.claim() else { return }
                switch result {
                case .success(let reconciliation):
                    switch reconciliation.pendingOutcome {
                    case .notScheduled:
                        self?.setActionOutcome(.durableNotScheduled)
                    case .partialFailure:
                        self?.setActionOutcome(.durableReconcileFailed)
                    case .unchanged, .reconciled:
                        self?.setActionOutcome(.durableAndReconciled)
                    }
                case .failure:
                    self?.setActionOutcome(.durableReconcileFailed)
                }
                completion()
            }
        } catch {
            // UserNotifications has no typed rejection channel.  Returning
            // after a truthful durable failure is safer than showing success,
            // rescheduling, or applying a best-effort in-memory mutation.
            finishAction(.rejected, completion: completion)
        }
    }

    private func setActionOutcome(_ outcome: ActionOutcome) {
        outcomeLock.lock()
        actionOutcome = outcome
        outcomeLock.unlock()
    }

    private func finishAction(
        _ outcome: ActionOutcome,
        completion: @escaping () -> Void
    ) {
        setActionOutcome(outcome)
        completion()
    }

    private struct Envelope {
        let categoryIdentifier: String
        let planID: String
        let occurrenceID: String
        let actionToken: String
        let generation: String
        let fireDate: String
    }

    private func decodeEnvelope(_ content: UNNotificationContent) throws -> Envelope {
        let values = content.userInfo.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String, let value = entry.value as? String else { return }
            result[key] = value
        }
        return try decodeEnvelope(
            categoryIdentifier: content.categoryIdentifier,
            userInfo: values
        )
    }

    private func decodeEnvelope(
        categoryIdentifier: String,
        userInfo: [String: String]
    ) throws -> Envelope {
        guard categoryIdentifier == SupplementNotificationActionIdentifier.category else {
            throw SupplementValidationError.invalidAction("unrelated notification category")
        }
        guard let planID = userInfo[SupplementNotificationActionIdentifier.planIDKey],
              let occurrenceID = userInfo[SupplementNotificationActionIdentifier.occurrenceIDKey],
              let actionToken = userInfo[SupplementNotificationActionIdentifier.actionTokenKey],
              let generation = userInfo[SupplementNotificationActionIdentifier.generationKey],
              let fireDate = userInfo[SupplementNotificationActionIdentifier.fireDateKey] else {
            throw SupplementValidationError.invalidAction("notification context is incomplete")
        }
        try SupplementValidation.validateOpaqueID(planID, field: "notification.planID")
        try SupplementValidation.validateOpaqueID(occurrenceID, field: "notification.occurrenceID")
        try SupplementValidation.validateOpaqueID(actionToken, field: "notification.actionToken")
        try SupplementValidation.validateOpaqueID(generation, field: "notification.generation")
        guard actionToken == generation else {
            throw SupplementValidationError.invalidAction("notification generation mismatch")
        }
        let fireDateValue = try SupplementValidation.parseISO8601(
            fireDate,
            field: "notification.fireDate"
        )
        let expectedToken: String
        do {
            expectedToken = try SupplementNotificationActionToken.make(
                occurrenceID: occurrenceID,
                fireDate: fireDateValue
            )
        } catch {
            throw SupplementValidationError.invalidAction("notification token does not match fire date")
        }
        guard actionToken == expectedToken else {
            throw SupplementValidationError.invalidAction("notification token does not match fire date")
        }
        return Envelope(
            categoryIdentifier: categoryIdentifier,
            planID: planID,
            occurrenceID: occurrenceID,
            actionToken: actionToken,
            generation: generation,
            fireDate: fireDate
        )
    }

    private func validateCurrentNotification(_ envelope: Envelope, now: Date) throws {
        guard let store,
              let state = try store.load(now: now),
              let plan = state.snapshot.plans.first(where: { $0.id == envelope.planID }),
              let occurrence = state.snapshot.occurrences.first(where: { $0.id == envelope.occurrenceID }) else {
            throw SupplementValidationError.danglingPlanReference(envelope.occurrenceID)
        }
        guard occurrence.planID == plan.id,
              plan.reminderEnabled,
              plan.schedule.notificationPreference != .disabled else {
            throw SupplementValidationError.invalidAction("notification plan is not actionable")
        }
        guard occurrence.state == .planned || occurrence.state == .snoozed else {
            throw SupplementValidationError.invalidAction("terminal or stale occurrence")
        }
        let expected = try expectedFireDate(for: occurrence)
        try validateActionFreshness(expectedFireDate: expected, now: now)
        try validateToken(envelope, occurrenceID: occurrence.id, expectedFireDate: expected)
        if occurrence.state == .planned {
            guard isScheduleActive(plan.schedule, at: expected) else {
                throw SupplementValidationError.invalidAction("notification schedule is outside its active window")
            }
        }
    }

    private func transact(
        action: SupplementNotificationAction,
        envelope: Envelope,
        now: Date
    ) throws -> SupplementStoreState {
        guard let store else {
            throw SupplementStoreError.applicationSupportUnavailable
        }
        return try store.mutate(now: now) { state in
            guard let plan = state.snapshot.plans.first(where: { $0.id == envelope.planID }),
                  let occurrenceIndex = state.snapshot.occurrences.firstIndex(where: {
                      $0.id == envelope.occurrenceID
                  }) else {
                throw SupplementValidationError.danglingPlanReference(envelope.occurrenceID)
            }
            let occurrence = state.snapshot.occurrences[occurrenceIndex]
            guard occurrence.planID == plan.id else {
                throw SupplementValidationError.contradictoryState("notification plan and occurrence differ")
            }

            let (supplementAction, context) = actionParts(action)
            guard context.planID == plan.id, context.occurrenceID == occurrence.id else {
                throw SupplementValidationError.invalidAction("notification action context mismatch")
            }
            let actionID = SupplementNotificationActionToken.actionID(
                action: supplementAction,
                token: envelope.actionToken
            )

            // A replay must remain idempotent even after the occurrence has
            // become terminal or its current notification generation changed.
            if let receipt = state.actionReceipts.first(where: { $0.actionID == actionID }) {
                guard receipt.planID == plan.id,
                      receipt.occurrenceID == occurrence.id,
                      receipt.action == supplementAction else {
                    throw SupplementValidationError.invalidAction("notification action ID collision")
                }
                // Reconstructing the persisted request verifies the complete
                // receipt identity without mutating state a second time.
                let request = try receipt.request()
                guard receipt.matches(request) else {
                    throw SupplementValidationError.invalidAction("notification replay payload mismatch")
                }
                return state
            }

            guard occurrence.state == .planned || occurrence.state == .snoozed else {
                throw SupplementValidationError.invalidAction("terminal or stale occurrence")
            }
            guard plan.reminderEnabled,
                  plan.schedule.notificationPreference != .disabled else {
                throw SupplementValidationError.invalidAction("notification plan is not actionable")
            }
            let expectedFireDate = try expectedFireDate(for: occurrence)
            // Keep this after the receipt lookup above.  An exact replay is
            // still idempotent even after the occurrence has aged out; only a
            // new action is subject to the expected-fire freshness window.
            try validateActionFreshness(expectedFireDate: expectedFireDate, now: now)
            try validateToken(envelope, occurrenceID: occurrence.id, expectedFireDate: expectedFireDate)
            if occurrence.state == .planned {
                guard isScheduleActive(plan.schedule, at: expectedFireDate) else {
                    throw SupplementValidationError.invalidAction("notification schedule is outside its active window")
                }
            }

            let snoozeUntil = supplementAction == .snooze
                ? now.addingTimeInterval(snoozeInterval)
                : nil
            let request = try SupplementOccurrenceActionRequest(
                actionID: actionID,
                occurrenceID: occurrence.id,
                planID: plan.id,
                action: supplementAction,
                occurredAt: now,
                snoozeUntil: snoozeUntil,
                baseRevision: state.snapshot.revision,
                sourceDeviceID: notificationDeviceID
            )
            var nextSnapshot = state.snapshot
            var ledger = SupplementActionLedger()
            _ = try SupplementReducer.reduce(
                request,
                in: &nextSnapshot,
                ledger: &ledger,
                now: now
            )
            let receipt = try SupplementActionReceipt(request: request, now: now)
            state = try SupplementStoreState(
                snapshot: nextSnapshot,
                actionReceipts: state.actionReceipts + [receipt],
                now: now
            )
            return state
        }
    }

    /// Rehydrates and materializes the durable notification horizon during
    /// launch.  A failed read or schedule attempt is swallowed here because
    /// the system delegate has no user-facing error channel; the next app
    /// foreground runs the same reconciliation through the Fitness view.
    private func reconcileAtLaunch() {
        guard let store, let reconciler else { return }
        let now = nowProvider()
        do {
            let state = try store.mutate(now: now) { state in
                state = try FitnessSupplementSession.reconciledState(
                    state,
                    selectedDate: now,
                    now: now,
                    lookAheadDays: SupplementNotificationPlanner.defaultLookAheadDays
                )
                return state
            }
            reconciler.reconcile(snapshot: state.snapshot, now: now) { _ in }
        } catch {
            // Durable truth remains untouched on failure; foreground
            // reconciliation is the eventual retry boundary.
        }
    }

    private func actionParts(
        _ action: SupplementNotificationAction
    ) -> (SupplementAction, SupplementNotificationActionContext) {
        switch action {
        case .taken(let context): return (.taken, context)
        case .snooze(let context): return (.snooze, context)
        case .skip(let context): return (.skip, context)
        }
    }

    private func expectedFireDate(for occurrence: SupplementOccurrence) throws -> Date {
        switch occurrence.state {
        case .planned: return occurrence.scheduledFor
        case .snoozed:
            guard let snoozedUntil = occurrence.snoozedUntil else {
                throw SupplementValidationError.contradictoryState("snoozed occurrence has no target")
            }
            return snoozedUntil
        case .taken, .skipped, .missed:
            throw SupplementValidationError.invalidAction("terminal occurrence")
        }
    }

    private func validateToken(
        _ envelope: Envelope,
        occurrenceID: String,
        expectedFireDate: Date
    ) throws {
        let expectedToken = try SupplementNotificationActionToken.make(
            occurrenceID: occurrenceID,
            fireDate: expectedFireDate
        )
        guard envelope.actionToken == expectedToken,
              envelope.generation == expectedToken,
              envelope.fireDate == SupplementNotificationActionToken.wireDate(expectedFireDate) else {
            throw SupplementValidationError.invalidAction("stale notification generation")
        }
    }

    /// Reconciliation normally materializes this transition at launch or
    /// foreground.  The notification delegate is also an independent action
    /// boundary, though, and can run while an already-open process has not
    /// foregrounded since a reminder became stale.  Reject a new action before
    /// its expected fire date or once the same grace window used by
    /// reconciliation has elapsed.  The expected date is the original
    /// schedule for Planned and the explicit snooze target for Snoozed.
    private func validateActionFreshness(
        expectedFireDate: Date,
        now: Date
    ) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              expectedFireDate.timeIntervalSinceReferenceDate.isFinite else {
            throw SupplementValidationError.invalidTimestamp("notification.now")
        }
        guard now >= expectedFireDate else {
            throw SupplementValidationError.invalidAction(
                "notification action is before expected fire date"
            )
        }
        guard now.timeIntervalSince(expectedFireDate) <
                FitnessSupplementSession.plannedOccurrenceGraceInterval else {
            throw SupplementValidationError.invalidAction("notification occurrence is stale")
        }
    }

    private func isScheduleActive(
        _ schedule: SupplementSchedule,
        at date: Date
    ) -> Bool {
        guard let timeZone = TimeZone(identifier: schedule.timeZoneIdentifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return false
        }
        let localDate = String(format: "%04d-%02d-%02d", year, month, day)
        return schedule.weekdays.contains(calendar.component(.weekday, from: date)) &&
            localDate >= schedule.startDate &&
            (schedule.endDate.map { localDate <= $0 } ?? true) &&
            !schedule.pauseRanges.contains { $0.startDate <= localDate && localDate <= $0.endDate }
    }
}

/// Thread-safe once gate for the UserNotifications completion handler.  The
/// system callback and the bounded reconciliation timeout can race; exactly
/// one of them is allowed to complete the action.
private final class SupplementNotificationCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}
