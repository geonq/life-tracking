import Foundation

// MARK: - User-entered supplement presentation record

/// The presentation record used by the Fitness screen.
///
/// This remains a user-entered/session-facing model.  `FitnessSupplementSession`
/// below is the only bridge from these records into the validated supplement
/// domain; it does not persist them or schedule notifications.
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
    public let timeZoneIdentifier: String
    public let reminderStatus: ReminderStatus
    public let scheduledDays: Set<Int>
    public let stockUnits: Int
    public let reorderThreshold: Int
    public let expectedLeadTimeDays: Int?
    public let expiryDate: Date?
    public let supplier: String?
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
        timeZoneIdentifier: String = TimeZone.current.identifier,
        reminderStatus: ReminderStatus = .localOnly,
        scheduledDays: Set<Int> = Set(1...7),
        stockUnits: Int,
        reorderThreshold: Int,
        expectedLeadTimeDays: Int? = nil,
        expiryDate: Date? = nil,
        supplier: String? = nil,
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
        self.timeZoneIdentifier = timeZoneIdentifier
        self.reminderStatus = reminderStatus
        self.scheduledDays = scheduledDays
        self.stockUnits = max(0, stockUnits)
        self.reorderThreshold = max(0, reorderThreshold)
        self.expectedLeadTimeDays = expectedLeadTimeDays
        self.expiryDate = expiryDate
        self.supplier = supplier
        self.adherence7 = adherence7
        self.adherence30 = adherence30
        self.adherence90 = adherence90
    }

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
                timeZoneIdentifier: TimeZone.current.identifier,
                reminderStatus: .permissionRequired,
                stockUnits: 18,
                reorderThreshold: 10,
                expectedLeadTimeDays: 7,
                expiryDate: now.addingTimeInterval(86_400 * 74),
                supplier: "User-entered supplier",
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
                timeZoneIdentifier: TimeZone.current.identifier,
                reminderStatus: .localOnly,
                stockUnits: 4,
                reorderThreshold: 8,
                expectedLeadTimeDays: 10,
                expiryDate: now.addingTimeInterval(-86_400 * 4),
                supplier: "Label / user record",
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
        }
    }
}

/// A pure, in-memory adapter between the Fitness presentation records and the
/// validated supplement domain.
///
/// The snapshot and action ledger intentionally live only for the open screen
/// session.  No store, network writer, or notification adapter belongs here.
public struct FitnessSupplementSession: Equatable, Sendable {
    public static let defaultSnoozeInterval: TimeInterval = 5 * 60

    public let selectedDate: Date
    public let sourceDeviceID: String
    public let selectedLocalDate: String
    public let selectedWeekday: Int
    public private(set) var records: [FitnessSupplement]
    public private(set) var snapshot: SupplementSnapshot

    private var ledger: SupplementActionLedger

    public init(
        supplements: [FitnessSupplement],
        selectedDate: Date,
        sourceDeviceID: String = "lifeos-session",
        now: Date = .now
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
            occurrences.append(mapped.occurrence)
            if localDate == nil {
                localDate = mapped.localDate
                weekday = mapped.weekday
            }
        }

        // Empty sessions still expose a deterministic date boundary using the
        // current timezone.  Every non-empty record retains its own timezone
        // in its validated schedule.
        let fallback = Self.dateContext(selectedDate, timeZone: .current)
        self.selectedDate = selectedDate
        self.sourceDeviceID = sourceDeviceID
        self.selectedLocalDate = localDate ?? fallback.date
        self.selectedWeekday = weekday ?? fallback.weekday
        self.records = supplements
        self.snapshot = try SupplementSnapshot(
            generatedAt: now,
            revision: 0,
            plans: plans,
            occurrences: occurrences
        )
        try self.snapshot.validate(now: now)
        self.ledger = SupplementActionLedger()
    }

    /// Adds a record to this open session only.  Existing reducer state is
    /// preserved; a failed mapping leaves the session unchanged.
    public mutating func add(_ record: FitnessSupplement, now: Date = .now) throws {
        guard !records.contains(where: { $0.id == record.id }) else {
            throw FitnessSupplementSessionError.duplicateIdentifier(record.id)
        }
        let mapped = try Self.map(record: record, selectedDate: selectedDate, now: now)
        var nextSnapshot = snapshot
        nextSnapshot.plans.append(mapped.plan)
        nextSnapshot.occurrences.append(mapped.occurrence)
        nextSnapshot.generatedAt = now
        try nextSnapshot.validate(now: now)
        records.append(record)
        snapshot = nextSnapshot
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
        guard let occurrence = snapshot.occurrences.first(where: { $0.planID == supplementID }) else {
            throw FitnessSupplementSessionError.missingOccurrence(supplementID)
        }
        let eventTime = occurredAt ?? now
        let resolvedSnooze: Date?
        if action == .snooze {
            resolvedSnooze = snoozeUntil ?? eventTime.addingTimeInterval(Self.defaultSnoozeInterval)
        } else {
            resolvedSnooze = snoozeUntil
        }
        let request = try SupplementOccurrenceActionRequest(
            actionID: actionID ?? Self.defaultActionID(
                action: action,
                occurrenceID: occurrence.id,
                baseRevision: snapshot.revision
            ),
            occurrenceID: occurrence.id,
            planID: supplementID,
            action: action,
            occurredAt: eventTime,
            snoozeUntil: resolvedSnooze,
            baseRevision: snapshot.revision,
            sourceDeviceID: sourceDeviceID
        )

        var nextSnapshot = snapshot
        var nextLedger = ledger
        let response = try SupplementReducer.reduce(
            request,
            in: &nextSnapshot,
            ledger: &nextLedger,
            now: now
        )
        snapshot = nextSnapshot
        ledger = nextLedger
        return response
    }

    public func plan(for supplementID: String) -> SupplementPlan? {
        snapshot.plans.first(where: { $0.id == supplementID })
    }

    public func occurrence(for supplementID: String) -> SupplementOccurrence? {
        snapshot.occurrences.first(where: { $0.planID == supplementID })
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
        Dictionary(uniqueKeysWithValues: snapshot.occurrences.map { ($0.planID, $0.state) })
    }

    private struct Mapping {
        let plan: SupplementPlan
        let occurrence: SupplementOccurrence
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
        let timingNote = localTime.note
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
                notes: "Session-only user-entered Fitness record",
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

        // The presentation model has a free-form timing note rather than a
        // claimed clock time.  Keep a deterministic noon anchor for the
        // non-actionable occurrence; explicit clock times retain their local
        // hour/minute.  No notification is scheduled by this session bridge.
        let scheduledFor = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: components.year,
                month: components.month,
                day: components.day,
                hour: localTime.hour,
                minute: localTime.minute
            )
        ) ?? selectedDate
        let occurrenceID = SupplementNotificationPlanner.occurrenceIdentifier(
            planID: record.id,
            localDate: context.date,
            localTime: localTime.value
        )
        let occurrence: SupplementOccurrence
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
        baseRevision: Int
    ) -> String {
        let readable = "session-\(action.rawValue)-\(baseRevision)-\(occurrenceID)"
        guard readable.utf8.count > 128 else { return readable }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in readable.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "session-\(String(hash, radix: 16))"
    }
}
