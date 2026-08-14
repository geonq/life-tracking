import Foundation

// MARK: - User-entered supplement presentation record

/// The presentation record used by the Fitness screen.
///
/// This remains a user-entered/session-facing model.  The validated domain and
/// optional local store are owned by FitnessSupplementSession; this record
/// does not itself perform persistence or schedule notifications.
public struct FitnessSupplement: Identifiable, Equatable, Sendable {
    public enum Form: String, CaseIterable, Equatable, Sendable {
        case capsule = "Capsule"
        case tablet = "Tablet"
        case powder = "Powder"
        case liquid = "Liquid"
        case softgel = "Softgel"
        case other = "Other"

        var inventoryUnit: String {
            switch self {
            case .capsule: "capsule"
            case .tablet: "tablet"
            case .powder: "serving"
            case .liquid: "ml"
            case .softgel: "softgel"
            case .other: "unit"
            }
        }
    }

    public enum ReminderStatus: String, Equatable, Sendable {
        case localOnly = "Local schedule"
        case permissionRequired = "Permission needed"
        case scheduled = "Scheduled locally"
        case paused = "Paused"
    }

    public let id: String
    public let name: String
    public let brand: String
    public let productIdentifier: String?
    public let form: Form
    public let strength: String
    public let servingUnit: String
    public let userDose: String?
    /// Number of inventory units consumed by one confirmed Taken occurrence.
    public let inventoryUnitsPerDose: Int
    public let timing: String
    /// Optional context attached to an explicit clock time (for example,
    /// “Before lunch”).  It is not parsed as a clock and never invents one.
    public let timingNote: String?
    public let timeZoneIdentifier: String
    public let reminderStatus: ReminderStatus
    public let scheduledDays: Set<Int>
    public let stockUnits: Int
    public let reorderThreshold: Int
    public let expectedLeadTimeDays: Int?
    public let expiryDate: Date?
    public let supplier: String?
    /// Visual fixtures are never connected to the production local store.
    /// Production records leave this false.
    public let isVisualFixture: Bool
    public let adherence7: Double?
    public let adherence30: Double?
    public let adherence90: Double?

    public init(
        id: String,
        name: String,
        brand: String,
        productIdentifier: String? = nil,
        form: Form,
        strength: String,
        servingUnit: String,
        userDose: String?,
        inventoryUnitsPerDose: Int = 1,
        timing: String,
        timingNote: String? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        reminderStatus: ReminderStatus = .localOnly,
        scheduledDays: Set<Int> = Set(1...7),
        stockUnits: Int,
        reorderThreshold: Int,
        expectedLeadTimeDays: Int? = nil,
        expiryDate: Date? = nil,
        supplier: String? = nil,
        isVisualFixture: Bool = false,
        adherence7: Double? = nil,
        adherence30: Double? = nil,
        adherence90: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.productIdentifier = productIdentifier
        self.form = form
        self.strength = strength
        self.servingUnit = servingUnit
        self.userDose = userDose
        self.inventoryUnitsPerDose = max(1, inventoryUnitsPerDose)
        self.timing = timing
        self.timingNote = timingNote
        self.timeZoneIdentifier = timeZoneIdentifier
        self.reminderStatus = reminderStatus
        self.scheduledDays = scheduledDays
        self.stockUnits = max(0, stockUnits)
        self.reorderThreshold = max(0, reorderThreshold)
        self.expectedLeadTimeDays = expectedLeadTimeDays
        self.expiryDate = expiryDate
        self.supplier = supplier
        self.isVisualFixture = isVisualFixture
        self.adherence7 = adherence7
        self.adherence30 = adherence30
        self.adherence90 = adherence90
    }

    private static let demoTimeZoneIdentifier: String = {
        let candidate = "Europe/Berlin"
        guard SupplementValidation.isIANATimeZone(candidate),
              TimeZone(identifier: candidate) != nil else {
            return "UTC"
        }
        return candidate
    }()

    public static let demo: [FitnessSupplement] = {
        let now = Date.now
        return [
            FitnessSupplement(
                id: "demo-magnesium",
                name: "Magnesium",
                brand: "User-entered product",
                productIdentifier: "Batch A",
                form: .capsule,
                strength: "200 mg",
                servingUnit: "capsule",
                userDose: "1 capsule",
                timing: "Before lunch",
                timeZoneIdentifier: demoTimeZoneIdentifier,
                reminderStatus: .permissionRequired,
                stockUnits: 18,
                reorderThreshold: 10,
                expectedLeadTimeDays: 7,
                expiryDate: now.addingTimeInterval(86_400 * 74),
                supplier: "User-entered supplier",
                isVisualFixture: true,
                adherence7: 0.86,
                adherence30: 0.80,
                adherence90: 0.76
            ),
            FitnessSupplement(
                id: "demo-omega",
                name: "Omega-3",
                brand: "Label record",
                productIdentifier: "Batch B",
                form: .softgel,
                strength: "1,000 mg",
                servingUnit: "softgel",
                userDose: "2 softgels",
                inventoryUnitsPerDose: 2,
                timing: "With breakfast",
                timeZoneIdentifier: demoTimeZoneIdentifier,
                reminderStatus: .localOnly,
                stockUnits: 4,
                reorderThreshold: 8,
                expectedLeadTimeDays: 10,
                expiryDate: now.addingTimeInterval(-86_400 * 4),
                supplier: "Label / user record",
                isVisualFixture: true,
                adherence7: 0.71,
                adherence30: 0.63,
                adherence90: 0.60
            )
        ]
    }()
}

// MARK: - Session/domain bridge

public enum FitnessSupplementSessionError: Error, Equatable, Sendable {
    case duplicateIdentifier(String)
    case invalidRecord(id: String, reason: String)
    case missingOccurrence(String)
    case actionIDCollision(String)
    case visualFixturePersistenceForbidden
    case persistenceFailed
}

extension FitnessSupplementSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let id):
            return "Supplement record \(id) is duplicated."
        case .invalidRecord(let id, let reason):
            return "Supplement record \(id) is not available in the session: \(reason)."
        case .missingOccurrence(let id):
            return "No session occurrence exists for supplement \(id)."
        case .actionIDCollision(let id):
            return "Supplement action ID \(id) was reused with a different payload."
        case .visualFixturePersistenceForbidden:
            return "Visual fixture records cannot be written to the production supplement store."
        case .persistenceFailed:
            return "The supplement change could not be saved locally."
        }
    }
}

/// The bridge between Fitness presentation records and the validated
/// supplement domain.  When a store is supplied, every successful add/action
/// is durably written before the new snapshot becomes visible to the caller.
public struct FitnessSupplementSession: Equatable, Sendable {
    public static let defaultSnoozeInterval: TimeInterval = 5 * 60
    /// Notification reconciliation keeps a bounded durable horizon.  The
    /// horizon is deliberately shared with the planner so the planner never
    /// asks UserNotifications to schedule a future occurrence that has not
    /// first been written to the local snapshot.
    public static let notificationLookAheadDays = SupplementNotificationPlanner.defaultLookAheadDays
    /// A planned dose remains actionable for 24 hours after its scheduled
    /// instant.  Reconciliation then marks only that planned occurrence as
    /// missed.  Snoozed occurrences are explicit user state and are never
    /// aged by this rule; they remain snoozed until the user acts on them.
    public static let plannedOccurrenceGraceInterval: TimeInterval = 24 * 60 * 60

    public private(set) var selectedDate: Date
    public let sourceDeviceID: String
    public private(set) var selectedLocalDate: String
    public private(set) var selectedWeekday: Int
    public private(set) var records: [FitnessSupplement]
    public private(set) var snapshot: SupplementSnapshot

    private var ledger: SupplementActionLedger
    private var actionReceiptsByID: [String: SupplementActionReceipt]
    private let persistence: SupplementStore?

    public init(
        supplements: [FitnessSupplement],
        selectedDate: Date,
        sourceDeviceID: String = "lifeos-session",
        store: SupplementStore? = nil,
        now: Date = .now
    ) throws {
        if store != nil, supplements.contains(where: { $0.isVisualFixture }) {
            throw FitnessSupplementSessionError.visualFixturePersistenceForbidden
        }
        if let store {
            do {
                // The factory is evaluated under the store's transaction lock
                // only when the file is genuinely absent.  A second session
                // cannot race a first session's create-and-save boundary.
                _ = try store.loadOrCreate(now: now) {
                    let initial = try Self.initialState(
                        supplements: supplements,
                        selectedDate: selectedDate,
                        sourceDeviceID: sourceDeviceID,
                        now: now
                    )
                    // The first durable envelope must already contain the
                    // complete bounded notification horizon.  Otherwise a
                    // concurrent planner could observe a valid store with
                    // only the selected-day occurrence and fail closed.
                    let initialState = try initial.makeStoreState(now: now)
                    return try Self.reconciledState(
                        initialState,
                        selectedDate: selectedDate,
                        now: now,
                        lookAheadDays: Self.notificationLookAheadDays
                    )
                }
                let reconciled = try store.mutate(now: now) { state in
                    // Reconciliation must mutate the inout value.  Returning
                    // a replacement alone is invisible to SupplementStore's
                    // durable change detector.
                    state = try Self.reconciledState(
                        state,
                        selectedDate: selectedDate,
                        now: now,
                        lookAheadDays: Self.notificationLookAheadDays
                    )
                    return state
                }
                try self.init(
                    persistedState: reconciled,
                    selectedDate: selectedDate,
                    sourceDeviceID: sourceDeviceID,
                    store: store,
                    now: now
                )
            } catch let error as FitnessSupplementSessionError {
                throw error
            } catch is SupplementStoreError {
                throw FitnessSupplementSessionError.persistenceFailed
            }
        } else {
            try self.init(
                sessionSupplements: supplements,
                selectedDate: selectedDate,
                sourceDeviceID: sourceDeviceID,
                store: store,
                now: now
            )
        }
    }

    private init(
        sessionSupplements supplements: [FitnessSupplement],
        selectedDate: Date,
        sourceDeviceID: String,
        store: SupplementStore?,
        now: Date
    ) throws {
        let initial = try Self.initialState(
            supplements: supplements,
            selectedDate: selectedDate,
            sourceDeviceID: sourceDeviceID,
            now: now
        )
        let initialStoreState = try SupplementStoreState(
            snapshot: initial.snapshot,
            now: now
        )
        let reconciled = try Self.reconciledState(
            initialStoreState,
            selectedDate: selectedDate,
            now: now,
            lookAheadDays: Self.notificationLookAheadDays
        )
        self.selectedDate = selectedDate
        self.sourceDeviceID = sourceDeviceID
        self.selectedLocalDate = initial.localDate
        self.selectedWeekday = initial.weekday
        self.records = supplements
        self.snapshot = reconciled.snapshot
        self.ledger = SupplementActionLedger()
        self.actionReceiptsByID = [:]
        self.persistence = store
    }

    private struct InitialState {
        let snapshot: SupplementSnapshot
        let localDate: String
        let weekday: Int

        func makeStoreState(now: Date) throws -> SupplementStoreState {
            try SupplementStoreState(snapshot: snapshot, now: now)
        }
    }

    private static func initialState(
        supplements: [FitnessSupplement],
        selectedDate: Date,
        sourceDeviceID: String,
        now: Date
    ) throws -> InitialState {
        guard selectedDate.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessSupplementSessionError.invalidRecord(id: "session", reason: "selected date is invalid")
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessSupplementSessionError.invalidRecord(id: "session", reason: "session time is invalid")
        }
        do {
            try SupplementValidation.validateOpaqueID(sourceDeviceID, field: "sourceDeviceID")
        } catch {
            throw FitnessSupplementSessionError.invalidRecord(id: "session", reason: String(describing: error))
        }

        var seen = Set<String>()
        var plans: [SupplementPlan] = []
        var occurrences: [SupplementOccurrence] = []
        var localDate: String?
        var weekday: Int?
        for record in supplements {
            guard seen.insert(record.id).inserted else {
                throw FitnessSupplementSessionError.duplicateIdentifier(record.id)
            }
            let mapped = try Self.map(record: record, selectedDate: selectedDate, now: now)
            plans.append(mapped.plan)
            if let occurrence = mapped.occurrence {
                occurrences.append(occurrence)
            }
            if localDate == nil {
                localDate = mapped.localDate
                weekday = mapped.weekday
            }
        }

        // Empty sessions still expose a deterministic date boundary using the
        // current timezone.  Every non-empty record retains its own timezone
        // in its validated schedule.
        let fallback = Self.dateContext(selectedDate, timeZone: .current)
        let snapshot = try SupplementSnapshot(
            generatedAt: now,
            revision: 0,
            plans: plans,
            occurrences: occurrences
        )
        return InitialState(
            snapshot: snapshot,
            localDate: localDate ?? fallback.date,
            weekday: weekday ?? fallback.weekday
        )
    }

    private init(
        persistedState: SupplementStoreState,
        selectedDate: Date,
        sourceDeviceID: String,
        store: SupplementStore,
        now: Date
    ) throws {
        guard selectedDate.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessSupplementSessionError.invalidRecord(id: "session", reason: "selected date is invalid")
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessSupplementSessionError.invalidRecord(id: "session", reason: "session time is invalid")
        }
        do {
            try SupplementValidation.validateOpaqueID(sourceDeviceID, field: "sourceDeviceID")
        } catch {
            throw FitnessSupplementSessionError.invalidRecord(id: "session", reason: String(describing: error))
        }
        let reconciled = try Self.reconciledState(
            persistedState,
            selectedDate: selectedDate,
            now: now
        )
        let nextSnapshot = reconciled.snapshot

        let fallback = Self.dateContext(selectedDate, timeZone: .current)
        let persistedContext: (date: String, weekday: Int)
        if let plan = nextSnapshot.plans.first,
           let timeZone = TimeZone(identifier: plan.schedule.timeZoneIdentifier) {
            persistedContext = Self.dateContext(selectedDate, timeZone: timeZone)
        } else {
            persistedContext = fallback
        }
        self.selectedDate = selectedDate
        self.sourceDeviceID = sourceDeviceID
        self.selectedLocalDate = persistedContext.date
        self.selectedWeekday = persistedContext.weekday
        self.records = nextSnapshot.plans.map(Self.presentationRecord)
        self.snapshot = nextSnapshot
        self.ledger = SupplementActionLedger()
        self.actionReceiptsByID = Dictionary(
            uniqueKeysWithValues: reconciled.actionReceipts.map { ($0.actionID, $0) }
        )
        self.persistence = store
    }

    public var actionReceipts: [SupplementActionReceipt] {
        actionReceiptsByID.values.sorted { $0.actionID < $1.actionID }
    }

    public static func == (
        lhs: FitnessSupplementSession,
        rhs: FitnessSupplementSession
    ) -> Bool {
        lhs.selectedDate == rhs.selectedDate &&
            lhs.sourceDeviceID == rhs.sourceDeviceID &&
            lhs.selectedLocalDate == rhs.selectedLocalDate &&
            lhs.selectedWeekday == rhs.selectedWeekday &&
            lhs.records == rhs.records &&
            lhs.snapshot == rhs.snapshot &&
            lhs.actionReceiptsByID == rhs.actionReceiptsByID
    }

    /// Adds a record.  Existing reducer state is preserved; when persistence
    /// is enabled, the candidate snapshot is saved before publication.
    public mutating func add(_ record: FitnessSupplement, now: Date = .now) throws {
        if persistence != nil, record.isVisualFixture {
            throw FitnessSupplementSessionError.visualFixturePersistenceForbidden
        }
        guard !records.contains(where: { $0.id == record.id }) else {
            throw FitnessSupplementSessionError.duplicateIdentifier(record.id)
        }
        let mapped = try Self.map(record: record, selectedDate: selectedDate, now: now)
        do {
            if let persistence {
                let nextState = try persistence.mutate(now: now) { state in
                    guard !state.snapshot.plans.contains(where: { $0.id == record.id }) else {
                        throw FitnessSupplementSessionError.duplicateIdentifier(record.id)
                    }
                    state.snapshot.plans.append(mapped.plan)
                    if let occurrence = mapped.occurrence {
                        state.snapshot.occurrences.append(occurrence)
                    }
                    state.snapshot.generatedAt = now
                    // Materialize the complete horizon before this locked
                    // transaction publishes the add.  Assign the replacement
                    // back into the inout transaction; returning it alone
                    // would leave SupplementStore's durable change detector
                    // with only the selected-day occurrence.
                    state = try Self.reconciledState(
                        state,
                        selectedDate: selectedDate,
                        now: now,
                        lookAheadDays: Self.notificationLookAheadDays
                    )
                    return state
                }
                try adopt(nextState, selectedDate: selectedDate, now: now)
            } else {
                var nextState = try SupplementStoreState(
                    snapshot: snapshot,
                    actionReceipts: actionReceipts,
                    now: now
                )
                guard !nextState.snapshot.plans.contains(where: { $0.id == record.id }) else {
                    throw FitnessSupplementSessionError.duplicateIdentifier(record.id)
                }
                nextState.snapshot.plans.append(mapped.plan)
                if let occurrence = mapped.occurrence {
                    nextState.snapshot.occurrences.append(occurrence)
                }
                nextState.snapshot.generatedAt = now
                nextState = try Self.reconciledState(
                    nextState,
                    selectedDate: selectedDate,
                    now: now,
                    lookAheadDays: Self.notificationLookAheadDays
                )
                try adopt(nextState, selectedDate: selectedDate, now: now)
            }
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            }
        } catch is SupplementStoreError {
            throw FitnessSupplementSessionError.persistenceFailed
        }
    }

    /// Applies an occurrence action through `SupplementReducer` and commits
    /// only after the reducer succeeds.  Reducer errors therefore cannot
    /// partially mutate this session.
    @discardableResult
    public mutating func apply(
        _ action: SupplementAction,
        to supplementID: String,
        actionID: String? = nil,
        occurredAt: Date? = nil,
        snoozeUntil: Date? = nil,
        now: Date = .now
    ) throws -> SupplementOccurrenceActionResponse {
        do {
            if let persistence {
                let result = try persistence.mutate(now: now) { state in
                    let response = try Self.apply(
                        action,
                        to: supplementID,
                        actionID: actionID,
                        occurredAt: occurredAt,
                        snoozeUntil: snoozeUntil,
                        sourceDeviceID: sourceDeviceID,
                        selectedDate: selectedDate,
                        now: now,
                        state: &state
                    )
                    return (response, state)
                }
                try adopt(result.1, selectedDate: selectedDate, now: now)
                return result.0
            }

            var state = try SupplementStoreState(
                snapshot: snapshot,
                actionReceipts: actionReceipts,
                now: now
            )
            let response = try Self.apply(
                action,
                to: supplementID,
                actionID: actionID,
                occurredAt: occurredAt,
                snoozeUntil: snoozeUntil,
                sourceDeviceID: sourceDeviceID,
                selectedDate: selectedDate,
                now: now,
                state: &state
            )
            try adopt(state, selectedDate: selectedDate, now: now)
            return response
        } catch is SupplementStoreError {
            throw FitnessSupplementSessionError.persistenceFailed
        }
    }

    /// Rebuilds this session's selected-day view from the latest durable
    /// snapshot.  A date change therefore cannot silently act on the first
    /// historical occurrence for a plan.
    public mutating func reconcile(
        selectedDate: Date,
        now: Date = .now,
        lookAheadDays: Int = Self.notificationLookAheadDays
    ) throws {
        guard selectedDate.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessSupplementSessionError.invalidRecord(id: "session", reason: "selected date is invalid")
        }
        do {
            let nextState: SupplementStoreState
            if let persistence {
                nextState = try persistence.mutate(now: now) { state in
                    // Assign the replacement into the inout transaction so
                    // SupplementStore persists newly materialized occurrences.
                    state = try Self.reconciledState(
                        state,
                        selectedDate: selectedDate,
                        now: now,
                        lookAheadDays: lookAheadDays
                    )
                    return state
                }
            } else {
                let current = try SupplementStoreState(
                    snapshot: snapshot,
                    actionReceipts: actionReceipts,
                    now: now
                )
                nextState = try Self.reconciledState(
                    current,
                    selectedDate: selectedDate,
                    now: now,
                    lookAheadDays: lookAheadDays
                )
            }
            try adopt(nextState, selectedDate: selectedDate, now: now)
        } catch is SupplementStoreError {
            throw FitnessSupplementSessionError.persistenceFailed
        }
    }

    public func plan(for supplementID: String) -> SupplementPlan? {
        snapshot.plans.first(where: { $0.id == supplementID })
    }

    public func occurrence(for supplementID: String) -> SupplementOccurrence? {
        guard let plan = plan(for: supplementID) else { return nil }
        return Self.selectedOccurrence(for: plan, snapshot: snapshot, selectedDate: selectedDate)
    }

    public func stock(for supplementID: String) -> Int {
        plan(for: supplementID)?.stockUnits ?? 0
    }

    public func state(for supplementID: String) -> SupplementOccurrenceState? {
        occurrence(for: supplementID)?.state
    }

    public var stocks: [String: Int] {
        Dictionary(uniqueKeysWithValues: snapshot.plans.map { ($0.id, $0.stockUnits) })
    }

    public var states: [String: SupplementOccurrenceState] {
        Dictionary(uniqueKeysWithValues: snapshot.plans.compactMap { plan in
            guard let occurrence = Self.selectedOccurrence(
                for: plan,
                snapshot: snapshot,
                selectedDate: selectedDate
            ) else { return nil }
            return (plan.id, occurrence.state)
        })
    }

    private static func apply(
        _ action: SupplementAction,
        to supplementID: String,
        actionID: String?,
        occurredAt: Date?,
        snoozeUntil: Date?,
        sourceDeviceID: String,
        selectedDate: Date,
        now: Date,
        state: inout SupplementStoreState
    ) throws -> SupplementOccurrenceActionResponse {
        guard let plan = state.snapshot.plans.first(where: { $0.id == supplementID }),
              let occurrence = selectedOccurrence(
                  for: plan,
                  snapshot: state.snapshot,
                  selectedDate: selectedDate
              ) else {
            throw FitnessSupplementSessionError.missingOccurrence(supplementID)
        }

        let eventTime = occurredAt ?? now
        let resolvedSnooze: Date?
        if action == .snooze {
            resolvedSnooze = snoozeUntil ?? eventTime.addingTimeInterval(Self.defaultSnoozeInterval)
        } else {
            resolvedSnooze = snoozeUntil
        }
        let resolvedActionID = actionID ?? Self.defaultActionID(
            action: action,
            occurrenceID: occurrence.id,
            occurrenceRevision: occurrence.revision
        )
        let existingReceipt = state.actionReceipts.first {
            $0.actionID == resolvedActionID
        }
        let requestBaseRevision = existingReceipt?.baseRevision ?? state.snapshot.revision
        let rawRequest = try SupplementOccurrenceActionRequest(
            actionID: resolvedActionID,
            occurrenceID: occurrence.id,
            planID: supplementID,
            action: action,
            occurredAt: eventTime,
            snoozeUntil: resolvedSnooze,
            baseRevision: requestBaseRevision,
            sourceDeviceID: sourceDeviceID
        )
        let request = try SupplementActionReceipt.canonicalizedRequest(rawRequest)

        if let receipt = existingReceipt {
            guard receipt.matches(request) else {
                throw FitnessSupplementSessionError.actionIDCollision(request.actionID)
            }
            guard let currentOccurrence = state.snapshot.occurrences.first(where: {
                $0.id == request.occurrenceID
            }) else {
                throw FitnessSupplementSessionError.missingOccurrence(request.occurrenceID)
            }
            return try SupplementOccurrenceActionResponse(
                occurrence: currentOccurrence,
                inventoryDelta: 0,
                idempotent: true,
                serverRevision: state.snapshot.revision,
                now: now
            )
        }

        var nextSnapshot = state.snapshot
        var nextLedger = SupplementActionLedger()
        let response = try SupplementReducer.reduce(
            request,
            in: &nextSnapshot,
            ledger: &nextLedger,
            now: now
        )
        let receipt = try SupplementActionReceipt(request: request, now: now)
        state = try SupplementStoreState(
            snapshot: nextSnapshot,
            actionReceipts: state.actionReceipts + [receipt],
            now: now
        )
        return response
    }

    /// Reconciles the durable occurrence set before any notification planner
    /// is called.  The selected day is always considered for in-app history;
    /// the bounded horizon is anchored at the current local day and is what
    /// makes notification scheduling durable across relaunches.
    static func reconciledState(
        _ state: SupplementStoreState,
        selectedDate: Date,
        now: Date,
        lookAheadDays: Int = Self.notificationLookAheadDays
    ) throws -> SupplementStoreState {
        var nextSnapshot = state.snapshot
        var changed = false

        let boundedLookAhead = min(max(0, lookAheadDays), 366)
        for plan in nextSnapshot.plans {
            var candidateDays: [Date] = [selectedDate]
            candidateDays.append(contentsOf: horizonDays(
                for: plan,
                now: now,
                lookAheadDays: boundedLookAhead
            ))

            var seenOccurrenceIDs = Set<String>()
            for day in candidateDays {
                guard let occurrence = try Self.occurrence(
                    for: plan,
                    selectedDate: day,
                    now: now
                ), seenOccurrenceIDs.insert(occurrence.id).inserted else {
                    continue
                }
                guard !nextSnapshot.occurrences.contains(where: { $0.id == occurrence.id }) else {
                    continue
                }
                nextSnapshot.occurrences.append(occurrence)
                changed = true
            }
        }

        // Age only planned occurrences.  This is intentionally not a reducer
        // action: it is an atomic local clock reconciliation with no inventory
        // effect and no user receipt.  Keeping the occurrence revision and
        // receipt chain unchanged is what allows the durable envelope to
        // distinguish an untouched/missed occurrence from a user action.  It
        // runs after materialization so opening a historical day cannot leave
        // a newly created, already-expired occurrence falsely planned.
        let cutoff = now.addingTimeInterval(-Self.plannedOccurrenceGraceInterval)
        for index in nextSnapshot.occurrences.indices {
            guard nextSnapshot.occurrences[index].state == .planned,
                  nextSnapshot.occurrences[index].scheduledFor <= cutoff else {
                continue
            }
            nextSnapshot.occurrences[index].state = .missed
            nextSnapshot.occurrences[index].updatedAt = now
            changed = true
        }
        if changed {
            nextSnapshot.generatedAt = now
        }
        return try SupplementStoreState(
            snapshot: nextSnapshot,
            actionReceipts: state.actionReceipts,
            now: now
        )
    }

    /// Returns local-calendar days from today through the bounded notification
    /// horizon.  Iteration uses noon anchors so a DST transition cannot make
    /// a day repeat or disappear; the actual schedule clock is resolved later
    /// by `SupplementNotificationTimeResolver`.
    private static func horizonDays(
        for plan: SupplementPlan,
        now: Date,
        lookAheadDays: Int
    ) -> [Date] {
        guard let timeZone = TimeZone(identifier: plan.schedule.timeZoneIdentifier) else {
            return []
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        var noon = components
        noon.hour = 12
        noon.minute = 0
        noon.second = 0
        guard let start = calendar.date(from: noon) else { return [] }
        var values: [Date] = []
        values.reserveCapacity(lookAheadDays + 1)
        var day = start
        var iterations = 0
        while iterations <= lookAheadDays {
            values.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                break
            }
            day = next
            iterations += 1
        }
        return values
    }

    private mutating func adopt(
        _ state: SupplementStoreState,
        selectedDate: Date,
        now: Date
    ) throws {
        let fallback = Self.dateContext(selectedDate, timeZone: .current)
        let context: (date: String, weekday: Int)
        if let plan = state.snapshot.plans.first,
           let timeZone = TimeZone(identifier: plan.schedule.timeZoneIdentifier) {
            context = Self.dateContext(selectedDate, timeZone: timeZone)
        } else {
            context = fallback
        }
        let existingRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        self.selectedDate = selectedDate
        self.selectedLocalDate = context.date
        self.selectedWeekday = context.weekday
        self.records = state.snapshot.plans.map {
            existingRecords[$0.id] ?? Self.presentationRecord($0)
        }
        self.snapshot = state.snapshot
        self.actionReceiptsByID = Dictionary(
            uniqueKeysWithValues: state.actionReceipts.map { ($0.actionID, $0) }
        )
        self.ledger = SupplementActionLedger()
        _ = now
    }

    private static func selectedOccurrence(
        for plan: SupplementPlan,
        snapshot: SupplementSnapshot,
        selectedDate: Date
    ) -> SupplementOccurrence? {
        guard TimeZone(identifier: plan.schedule.timeZoneIdentifier) != nil else {
            return nil
        }
        let context = dateContext(
            selectedDate,
            timeZone: TimeZone(identifier: plan.schedule.timeZoneIdentifier)!
        )
        let occurrenceID = SupplementNotificationPlanner.occurrenceIdentifier(
            planID: plan.id,
            localDate: context.date,
            localTime: plan.schedule.localTime
        )
        return snapshot.occurrences.first(where: { $0.id == occurrenceID })
    }

    private static func occurrence(
        for plan: SupplementPlan,
        selectedDate: Date,
        now: Date
    ) throws -> SupplementOccurrence? {
        guard let timeZone = TimeZone(identifier: plan.schedule.timeZoneIdentifier) else {
            throw FitnessSupplementSessionError.invalidRecord(
                id: plan.id,
                reason: "time zone \(plan.schedule.timeZoneIdentifier) is invalid"
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let context = dateContext(selectedDate, timeZone: timeZone)
        guard context.date >= plan.schedule.startDate,
              plan.schedule.endDate.map({ context.date <= $0 }) ?? true,
              plan.schedule.weekdays.contains(context.weekday),
              !plan.schedule.pauseRanges.contains(where: {
                  $0.startDate <= context.date && context.date <= $0.endDate
              }) else {
            return nil
        }
        let components = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        let scheduledFor: Date
        if plan.schedule.notificationPreference == .disabled && plan.schedule.localTime == "00:00" {
            // Free-form notes retain the deterministic noon anchor used by
            // the initial session mapping; the note is never a claimed clock.
            scheduledFor = calendar.date(
                from: DateComponents(
                    calendar: calendar,
                    timeZone: timeZone,
                    year: components.year,
                    month: components.month,
                    day: components.day,
                    hour: 12,
                    minute: 0
                )
            ) ?? selectedDate
        } else {
            guard let resolved = try SupplementNotificationTimeResolver.resolve(
                plan.schedule.localTime,
                on: components,
                calendar: calendar
            ) else {
                throw FitnessSupplementSessionError.invalidRecord(
                    id: plan.id,
                    reason: "stored clock schedule cannot be resolved on selected day"
                )
            }
            scheduledFor = resolved.date
        }
        let id = SupplementNotificationPlanner.occurrenceIdentifier(
            planID: plan.id,
            localDate: context.date,
            localTime: plan.schedule.localTime
        )
        return try SupplementOccurrence(
            id: id,
            planID: plan.id,
            scheduledFor: scheduledFor,
            revision: 0,
            updatedAt: now
        )
    }

    private static func presentationRecord(_ plan: SupplementPlan) -> FitnessSupplement {
        let timing = plan.schedule.timingNote ?? plan.schedule.localTime
        let dose: String? = plan.userDose.map { dose in
            let amount = String(format: "%.3f", dose.amount)
                .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            return "\(amount) \(dose.unit)"
        }
        let form: FitnessSupplement.Form
        switch plan.form {
        case .capsule: form = .capsule
        case .tablet: form = .tablet
        case .powder: form = .powder
        case .liquid: form = .liquid
        case .softgel: form = .softgel
        case .other: form = .other
        }
        return FitnessSupplement(
            id: plan.id,
            name: plan.name,
            brand: plan.brand,
            productIdentifier: plan.productIdentifier,
            form: form,
            strength: plan.strength,
            servingUnit: plan.servingUnit,
            userDose: dose,
            inventoryUnitsPerDose: plan.inventoryUnitsPerDose,
            timing: timing,
            timingNote: plan.schedule.timingNote,
            timeZoneIdentifier: plan.schedule.timeZoneIdentifier,
            // An actionable clock schedule is not proof that UserNotifications
            // permission was granted or that reconciliation succeeded.
            // The permission coordinator owns that status after rehydration.
            reminderStatus: .localOnly,
            scheduledDays: Set(plan.schedule.weekdays),
            stockUnits: plan.stockUnits,
            reorderThreshold: plan.reorderThreshold,
            expectedLeadTimeDays: plan.expectedLeadTimeDays,
            expiryDate: plan.expiryDate,
            supplier: plan.supplier
        )
    }

    private struct Mapping {
        let plan: SupplementPlan
        let occurrence: SupplementOccurrence?
        let localDate: String
        let weekday: Int
    }

    private static func map(
        record: FitnessSupplement,
        selectedDate: Date,
        now: Date
    ) throws -> Mapping {
        let timeZone = TimeZone(identifier: record.timeZoneIdentifier)
        guard let timeZone else {
            throw FitnessSupplementSessionError.invalidRecord(
                id: record.id,
                reason: "time zone \(record.timeZoneIdentifier) is invalid"
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let context = dateContext(selectedDate, timeZone: timeZone)
        guard let components = calendar.dateComponents([.year, .month, .day], from: selectedDate) as DateComponents? else {
            throw FitnessSupplementSessionError.invalidRecord(id: record.id, reason: "selected date has no local date")
        }
        let localTime = try resolvedLocalTime(from: record.timing, recordID: record.id)
        let timingNote = record.timingNote ?? localTime.note
        let schedule = try SupplementSchedule(
            weekdays: record.scheduledDays.sorted(),
            localTime: localTime.value,
            timeZoneIdentifier: record.timeZoneIdentifier,
            timingNote: timingNote,
            startDate: context.date,
            pauseRanges: [],
            // A free-form timing note is not an actionable clock schedule.
            // Keep the note in the validated plan, but fail closed for any
            // future caller that might hand this session snapshot to a
            // notification planner.
            notificationPreference: localTime.isExplicitClock ? .productAndTiming : .disabled,
            calendarOverlayEnabled: true
        )
        let dose = try resolvedDose(record.userDose, recordID: record.id)
        let plan: SupplementPlan
        do {
            plan = try SupplementPlan(
                id: record.id,
                name: record.name,
                brand: record.brand,
                productIdentifier: record.productIdentifier,
                form: SupplementForm(rawValue: record.form.rawValue.lowercased()) ?? .other,
                strength: record.strength,
                servingUnit: record.servingUnit,
                userDose: dose,
                inventoryUnitsPerDose: record.inventoryUnitsPerDose,
                schedule: schedule,
                source: .manual,
                // The durable record is a user-entered LifeOS product.  Do not
                // persist the old “session-only” claim once a store is used.
                notes: nil,
                stockUnits: record.stockUnits,
                reorderThreshold: record.reorderThreshold,
                expectedLeadTimeDays: record.expectedLeadTimeDays,
                expiryDate: record.expiryDate,
                supplier: record.supplier,
                reminderEnabled: localTime.isExplicitClock && record.reminderStatus != .paused,
                lockScreenRedacted: true,
                revision: 0,
                updatedAt: now
            )
        } catch {
            throw FitnessSupplementSessionError.invalidRecord(id: record.id, reason: String(describing: error))
        }

        // Materialize an occurrence only for the selected local schedule day.
        // A plan can exist outside its weekday/start/end/pause window without
        // manufacturing an actionable occurrence for the UI or reducer.
        let occurrence: SupplementOccurrence?
        if record.scheduledDays.contains(context.weekday) {
            let scheduledFor: Date
            if localTime.isExplicitClock {
                guard let resolved = try SupplementNotificationTimeResolver.resolve(
                    localTime.value,
                    on: components,
                    calendar: calendar
                ) else {
                    throw FitnessSupplementSessionError.invalidRecord(
                        id: record.id,
                        reason: "schedule time cannot be resolved on the selected local day"
                    )
                }
                scheduledFor = resolved.date
            } else {
                // Free-form legacy notes remain visible facts but are never
                // treated as a claimed notification time.
                scheduledFor = calendar.date(
                    from: DateComponents(
                        calendar: calendar,
                        timeZone: timeZone,
                        year: components.year,
                        month: components.month,
                        day: components.day,
                        hour: 12,
                        minute: 0
                    )
                ) ?? selectedDate
            }
            let occurrenceID = SupplementNotificationPlanner.occurrenceIdentifier(
                planID: record.id,
                localDate: context.date,
                localTime: localTime.value
            )
            do {
                occurrence = try SupplementOccurrence(
                    id: occurrenceID,
                    planID: record.id,
                    scheduledFor: scheduledFor,
                    revision: 0,
                    updatedAt: now
                )
            } catch {
                throw FitnessSupplementSessionError.invalidRecord(id: record.id, reason: String(describing: error))
            }
        } else {
            occurrence = nil
        }
        return Mapping(plan: plan, occurrence: occurrence, localDate: context.date, weekday: context.weekday)
    }

    private static func resolvedDose(_ raw: String?, recordID: String) throws -> SupplementDose? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let pieces = value.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard pieces.count == 2,
              let amount = Double(String(pieces[0]).replacingOccurrences(of: ",", with: ".")) else {
            throw FitnessSupplementSessionError.invalidRecord(
                id: recordID,
                reason: "dose must contain a numeric amount and unit, or be left blank"
            )
        }
        do {
            return try SupplementDose(amount: amount, unit: String(pieces[1]))
        } catch {
            throw FitnessSupplementSessionError.invalidRecord(id: recordID, reason: String(describing: error))
        }
    }

    private static func resolvedLocalTime(
        from raw: String,
        recordID: String
    ) throws -> (value: String, note: String?, hour: Int, minute: Int, isExplicitClock: Bool) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return ("00:00", nil, 12, 0, false) }
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 2,
           let hour = Int(pieces[0]),
           let minute = Int(pieces[1]) {
            guard (0...23).contains(hour), (0...59).contains(minute) else {
                throw FitnessSupplementSessionError.invalidRecord(id: recordID, reason: "timing clock is invalid")
            }
            return (String(format: "%02d:%02d", hour, minute), nil, hour, minute, true)
        }
        return ("00:00", value, 12, 0, false)
    }

    private static func dateContext(_ date: Date, timeZone: TimeZone) -> (date: String, weekday: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let dateString = String(format: "%04d-%02d-%02d", year, month, day)
        return (dateString, calendar.component(.weekday, from: date))
    }

    private static func defaultActionID(
        action: SupplementAction,
        occurrenceID: String,
        occurrenceRevision: Int
    ) -> String {
        let readable = "session-\(action.rawValue)-\(occurrenceRevision)-\(occurrenceID)"
        guard readable.utf8.count > 128 else { return readable }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in readable.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "session-\(String(hash, radix: 16))"
    }
}
