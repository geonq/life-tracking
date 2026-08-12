import Foundation

// MARK: - Storage-agnostic local supplement notifications

/// The notification planner deliberately has no persistence or network
/// dependency.  A caller can run it after launch, reboot, foregrounding, or a
/// timezone change and reconcile its result with whatever local adapter it
/// owns.
///
/// Weekdays use Foundation Calendar's `weekday` component: Sunday is 1,
/// Monday is 2, and Saturday is 7.  This is intentionally not ISO weekday
/// numbering; the choice is contained here at the schedule boundary.
public struct SupplementNotificationPlanner {
    public let lookAheadDays: Int
    public let maxPendingIntents: Int
    public let calendar: Calendar

    private let clock: @Sendable () -> Date

    /// Creates a planner with an injectable clock and calendar.  The default
    /// clock is intentionally evaluated when planning, not when this value is
    /// initialized.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = Calendar(identifier: .gregorian),
        lookAheadDays: Int = 30,
        maxPendingIntents: Int = 64
    ) {
        self.clock = clock
        self.calendar = calendar
        // A malformed caller must not be able to turn reconciliation into an
        // unbounded scheduling operation.  Zero is useful in deterministic
        // tests when only today's future occurrence should be considered.
        self.lookAheadDays = min(max(0, lookAheadDays), 366)
        // Apple documents a hard limit of 64 pending notification requests per
        // app.  Keep the contract bounded even when a caller supplies a larger
        // value, so planning can never produce an adapter-rejected batch.
        self.maxPendingIntents = min(max(0, maxPendingIntents), 64)
    }

    /// Convenience initializer for tests and callers that already have a
    /// fixed observation time.
    public init(
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian),
        lookAheadDays: Int = 30,
        maxPendingIntents: Int = 64
    ) {
        self.init(
            clock: { now },
            calendar: calendar,
            lookAheadDays: lookAheadDays,
            maxPendingIntents: maxPendingIntents
        )
    }

    /// Computes the bounded set of future notification intents.
    ///
    /// Existing occurrences are optional because a schedule can be planned
    /// before its first occurrence has been materialized.  When history is
    /// supplied, Taken/Skipped/Missed occurrences are terminal and never
    /// produce another dose.  A Snoozed occurrence reuses its original stable
    /// occurrence ID and moves that one reminder to `snoozedUntil`.
    public func plan(
        plans: [SupplementPlan],
        occurrences: [SupplementOccurrence] = [],
        now overrideNow: Date? = nil
    ) throws -> SupplementNotificationPlan {
        let now = overrideNow ?? clock()
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw SupplementValidationError.invalidTimestamp("planner.now")
        }

        // A valid snapshot cannot contain duplicates.  Defensive de-duplication
        // also makes this pure boundary safe when a caller is assembling plans
        // from several local views before validation.  A newer revision wins;
        // equal revisions keep the first value, which is deterministic for a
        // snapshot's ordered input.
        var uniquePlans: [String: SupplementPlan] = [:]
        for plan in plans {
            // SupplementPlan has mutable fields.  Validate every supplied
            // value at this boundary, including entries that will lose
            // duplicate resolution, against the exact planning instant.
            try plan.validate(now: now)
            guard let current = uniquePlans[plan.id] else {
                uniquePlans[plan.id] = plan
                continue
            }
            if plan.revision > current.revision ||
                (plan.revision == current.revision && plan.updatedAt > current.updatedAt) {
                uniquePlans[plan.id] = plan
            }
        }

        var occurrencesByID: [String: SupplementOccurrence] = [:]
        for occurrence in occurrences {
            // Occurrences are mutable too; validation must happen before
            // de-duplication so an invalid shadowed value cannot slip through.
            try occurrence.validate(now: now)
            guard let current = occurrencesByID[occurrence.id] else {
                occurrencesByID[occurrence.id] = occurrence
                continue
            }
            if occurrence.revision > current.revision ||
                (occurrence.revision == current.revision && occurrence.updatedAt > current.updatedAt) {
                occurrencesByID[occurrence.id] = occurrence
            }
        }

        var candidates: [SupplementNotificationIntent] = []
        for planID in uniquePlans.keys.sorted() {
            guard let plan = uniquePlans[planID], plan.reminderEnabled,
                  plan.schedule.notificationPreference != .disabled else {
                continue
            }

            let schedule = plan.schedule
            guard let timeZone = TimeZone(identifier: schedule.timeZoneIdentifier) else {
                throw SupplementValidationError.invalidSchedule("timeZoneIdentifier")
            }
            var planCalendar = calendar
            planCalendar.timeZone = timeZone

            let start = try localDateOnly(schedule.startDate, calendar: planCalendar)
            let nowLocal = try localDateOnly(
                planCalendar.dateComponents([.year, .month, .day], from: now),
                calendar: planCalendar,
                field: "planner.now"
            )
            let latestDate = planCalendar.date(
                byAdding: .day,
                value: lookAheadDays,
                to: nowLocal
            ) ?? nowLocal
            let requestedEnd = try schedule.endDate.map {
                try localDateOnly($0, calendar: planCalendar)
            }
            let end = minDateOnly(requestedEnd ?? latestDate, latestDate, calendar: planCalendar)
            var day = maxDateOnly(start, nowLocal, calendar: planCalendar)

            // The noon anchor avoids midnight DST transitions while iterating
            // date-only schedule facts.  The guard is an additional safety
            // bound if Foundation ever returns an unchanged date from adding a
            // day around an unusual timezone transition.
            var iterationCount = 0
            while day <= end && iterationCount <= lookAheadDays + 370 {
                iterationCount += 1
                let components = planCalendar.dateComponents([.year, .month, .day], from: day)
                let weekday = planCalendar.component(.weekday, from: day)
                let dateString = try dateOnlyString(from: components)

                if schedule.weekdays.contains(weekday),
                   !isPaused(dateString: dateString, in: schedule.pauseRanges),
                   let resolved = try resolveLocalTime(
                       schedule.localTime,
                       on: components,
                       calendar: planCalendar
                   ) {
                    let occurrenceID = Self.occurrenceIdentifier(
                        planID: plan.id,
                        localDate: dateString,
                        localTime: schedule.localTime
                    )
                    let existing = occurrencesByID[occurrenceID]
                    if let existing {
                        switch existing.state {
                        case .taken, .skipped, .missed:
                            // Missed remains missed.  There is no automatic
                            // doubling, catch-up, or extra dose.
                            break
                        case .snoozed:
                            guard let snoozedUntil = existing.snoozedUntil,
                                  snoozedUntil > now else {
                                break
                            }
                            candidates.append(
                                try makeIntent(
                                    plan: plan,
                                    scheduleIdentifier: Self.scheduleIdentifier(planID: plan.id),
                                    occurrenceID: occurrenceID,
                                    fireDate: snoozedUntil,
                                    timeZone: timeZone,
                                    timeZoneIdentifier: schedule.timeZoneIdentifier,
                                    resolution: .snoozed
                                )
                            )
                        case .planned:
                            if resolved.date > now {
                                candidates.append(
                                    try makeIntent(
                                        plan: plan,
                                        scheduleIdentifier: Self.scheduleIdentifier(planID: plan.id),
                                        occurrenceID: occurrenceID,
                                        fireDate: resolved.date,
                                        timeZone: timeZone,
                                        timeZoneIdentifier: schedule.timeZoneIdentifier,
                                        resolution: resolved.resolution
                                    )
                                )
                            }
                        }
                    } else if resolved.date > now {
                        candidates.append(
                            try makeIntent(
                                plan: plan,
                                scheduleIdentifier: Self.scheduleIdentifier(planID: plan.id),
                                occurrenceID: occurrenceID,
                                        fireDate: resolved.date,
                                        timeZone: timeZone,
                                        timeZoneIdentifier: schedule.timeZoneIdentifier,
                                        resolution: resolved.resolution
                            )
                        )
                    }
                }

                guard let next = planCalendar.date(byAdding: .day, value: 1, to: day), next > day else {
                    break
                }
                day = next
            }

            // A snooze is an explicit user action on an already materialized
            // occurrence.  It must survive the date-only iteration window (for
            // example, an occurrence from yesterday snoozed past midnight),
            // even when its original schedule day is no longer in `start...end`.
            // The occurrence ID remains the one domain identity; the final
            // identifier de-duplication below prevents a second dose if the
            // normal iteration also encountered it.
            for occurrence in occurrencesByID.values {
                guard occurrence.planID == plan.id,
                      occurrence.state == .snoozed,
                      let snoozedUntil = occurrence.snoozedUntil,
                      snoozedUntil > now else {
                    continue
                }
                candidates.append(
                    try makeIntent(
                        plan: plan,
                        scheduleIdentifier: Self.scheduleIdentifier(planID: plan.id),
                        occurrenceID: occurrence.id,
                        fireDate: snoozedUntil,
                        timeZone: timeZone,
                        timeZoneIdentifier: schedule.timeZoneIdentifier,
                        resolution: .snoozed
                    )
                )
            }
        }

        // A repeated weekday or duplicate input plan must never result in
        // duplicate request identifiers.  Sorting before truncation makes the
        // bounded result stable across input ordering and reboot/reconcile.
        var uniqueByIdentifier: [String: SupplementNotificationIntent] = [:]
        for candidate in candidates {
            if let previous = uniqueByIdentifier[candidate.identifier],
               previous.fireDate <= candidate.fireDate {
                continue
            }
            uniqueByIdentifier[candidate.identifier] = candidate
        }
        let intents = uniqueByIdentifier.values.sorted {
            if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
            return $0.identifier < $1.identifier
        }.prefix(maxPendingIntents)

        return SupplementNotificationPlan(
            evaluatedAt: now,
            intents: Array(intents),
            maxPendingIntents: maxPendingIntents
        )
    }

    /// Alias kept explicit for call sites that prefer a verb over `plan`.
    public func makePlan(
        plans: [SupplementPlan],
        occurrences: [SupplementOccurrence] = [],
        now overrideNow: Date? = nil
    ) throws -> SupplementNotificationPlan {
        try plan(plans: plans, occurrences: occurrences, now: overrideNow)
    }

    public static func scheduleIdentifier(planID: String) -> String {
        "lifeos.supplement.schedule.\(planID)"
    }

    /// Returns the bounded, validation-safe domain identity for one local
    /// schedule slot.  The readable form is used whenever it fits; a stable
    /// FNV-1a digest is used for long plan IDs so the result remains a valid
    /// opaque ID (ASCII alphanumeric plus `_`/`-`, at most 128 bytes).
    public static func occurrenceIdentifier(
        planID: String,
        localDate: String,
        localTime: String
    ) -> String {
        let compactTime = localTime.replacingOccurrences(of: ":", with: "-")
        let readable = "\(planID)_\(localDate)_\(compactTime)"
        if readable.utf8.count <= 128,
           readable.utf8.allSatisfy(Self.isSafeOccurrenceIdentifierByte) {
            return readable
        }

        let digest = stableDigest(readable)
        return "occ_\(digest)"
    }

    /// Returns the identifier used for the platform notification request.
    /// This namespace is intentionally separate from the opaque occurrence
    /// identity stored in SupplementOccurrence.
    public static func occurrenceRequestIdentifier(occurrenceID: String) -> String {
        "lifeos.supplement.occurrence.\(occurrenceID)"
    }

    public static func isLifeOSIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("lifeos.supplement.schedule.") ||
            identifier.hasPrefix("lifeos.supplement.occurrence.")
    }

    private func makeIntent(
        plan: SupplementPlan,
        scheduleIdentifier: String,
        occurrenceID: String,
        fireDate: Date,
        timeZone: TimeZone,
        timeZoneIdentifier: String,
        resolution: SupplementNotificationLocalTimeResolution
    ) throws -> SupplementNotificationIntent {
        let copy = SupplementNotificationCopy.make(for: plan)
        let local = localDateTimeString(fireDate, timeZone: timeZone)
        return try SupplementNotificationIntent(
            identifier: Self.occurrenceRequestIdentifier(occurrenceID: occurrenceID),
            scheduleIdentifier: scheduleIdentifier,
            occurrenceIdentifier: occurrenceID,
            planID: plan.id,
            fireDate: fireDate,
            localDate: local.date,
            localTime: local.time,
            timeZoneIdentifier: timeZoneIdentifier,
            title: copy.title,
            body: copy.body,
            isPrivate: copy.isPrivate,
            resolution: resolution
        )
    }

    private func isPaused(dateString: String, in pauses: [SupplementSchedulePauseRange]) -> Bool {
        pauses.contains { $0.startDate <= dateString && dateString <= $0.endDate }
    }

    private func localDateOnly(
        _ value: String,
        calendar: Calendar,
        field: String = "date"
    ) throws -> Date {
        guard let components = parseDateOnly(value) else {
            throw SupplementValidationError.invalidDate(field)
        }
        return try localDateOnly(components, calendar: calendar, field: field)
    }

    private func localDateOnly(
        _ components: DateComponents,
        calendar: Calendar,
        field: String
    ) throws -> Date {
        var noon = components
        noon.hour = 12
        noon.minute = 0
        noon.second = 0
        guard let date = calendar.date(from: noon) else {
            throw SupplementValidationError.invalidDate(field)
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == components.year,
              roundTrip.month == components.month,
              roundTrip.day == components.day else {
            throw SupplementValidationError.invalidDate(field)
        }
        return date
    }

    private func parseDateOnly(_ value: String) -> DateComponents? {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return nil }
        guard let year = Int(String(value.prefix(4))),
              let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.dropFirst(8).prefix(2)) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    private func dateOnlyString(from components: DateComponents) throws -> String {
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw SupplementValidationError.invalidDate("planner.date")
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func maxDateOnly(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Date {
        let l = calendar.dateComponents([.year, .month, .day], from: lhs)
        let r = calendar.dateComponents([.year, .month, .day], from: rhs)
        guard let ly = l.year, let lm = l.month, let ld = l.day,
              let ry = r.year, let rm = r.month, let rd = r.day else { return lhs }
        if (ly, lm, ld) >= (ry, rm, rd) { return lhs }
        return rhs
    }

    private func minDateOnly(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Date {
        let l = calendar.dateComponents([.year, .month, .day], from: lhs)
        let r = calendar.dateComponents([.year, .month, .day], from: rhs)
        guard let ly = l.year, let lm = l.month, let ld = l.day,
              let ry = r.year, let rm = r.month, let rd = r.day else { return lhs }
        if (ly, lm, ld) <= (ry, rm, rd) { return lhs }
        return rhs
    }

    private struct ResolvedLocalTime {
        let date: Date
        let resolution: SupplementNotificationLocalTimeResolution
    }

    private func resolveLocalTime(
        _ value: String,
        on day: DateComponents,
        calendar: Calendar
    ) throws -> ResolvedLocalTime? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            throw SupplementValidationError.invalidSchedule("localTime")
        }

        var dayStartComponents = day
        dayStartComponents.hour = 0
        dayStartComponents.minute = 0
        dayStartComponents.second = 0
        dayStartComponents.nanosecond = 0
        guard let dayStart = calendar.date(from: dayStartComponents),
              let searchAnchor = calendar.date(byAdding: .second, value: -1, to: dayStart) else {
            return nil
        }
        var matching = DateComponents()
        matching.hour = hour
        matching.minute = minute
        matching.second = 0
        matching.nanosecond = 0
        matching.timeZone = calendar.timeZone

        // Searching from just before the local day start keeps pre-noon times
        // on this date.  The date guard also rejects any Foundation fallback
        // that would otherwise roll a gap into the following local day.
        let targetComponents = calendar.dateComponents([.year, .month, .day], from: dayStart)
        func isOnTargetDay(_ date: Date) -> Bool {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return components.year == targetComponents.year &&
                components.month == targetComponents.month &&
                components.day == targetComponents.day
        }
        func isSameLocalTimeOnTargetDay(_ date: Date) -> Bool {
            guard isOnTargetDay(date) else { return false }
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: date
            )
            return components.hour == hour &&
                components.minute == minute &&
                components.second == 0
        }

        let first = calendar.nextDate(
            after: searchAnchor,
            matching: matching,
            matchingPolicy: .strict,
            repeatedTimePolicy: .first,
            direction: .forward
        )
        let resolved: Date
        let resolution: SupplementNotificationLocalTimeResolution
        if let first, isOnTargetDay(first) {
            resolved = first
            let afterFirst = first.addingTimeInterval(0.001)
            // On some iOS Foundation versions, nextDate's repeated-time
            // policy returns nil after the first match.  Keep the strict
            // nextDate probe, then use the equivalent same-day setter as a
            // compatibility fallback; the local-date/time guard below keeps
            // a normal day's next occurrence from being treated as repeated.
            let last = calendar.nextDate(
                after: afterFirst,
                matching: matching,
                matchingPolicy: .strict,
                repeatedTimePolicy: .last,
                direction: .forward
            )
            let fallbackLast = calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: afterFirst,
                matchingPolicy: .strict,
                repeatedTimePolicy: .last,
                direction: .forward
            )
            let repeatedCandidate = last ?? fallbackLast
            resolution = (repeatedCandidate.map(isSameLocalTimeOnTargetDay) == true && repeatedCandidate != first)
                ? .firstRepeatedTime
                : .exactLocalTime
        } else {
            // Spring-forward (or another timezone gap): Foundation's
            // nextTime policy intentionally moves to the first valid local
            // instant after the gap.  It never invents a second dose.
            guard let next = calendar.nextDate(
                after: searchAnchor,
                matching: matching,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ), isOnTargetDay(next) else {
                return nil
            }
            resolved = next
            resolution = .nextValidTime
        }

        return ResolvedLocalTime(date: resolved, resolution: resolution)
    }

    private func localDateTimeString(_ date: Date, timeZone: TimeZone) -> (date: String, time: String) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd|HH:mm"
        let parts = formatter.string(from: date).split(separator: "|", maxSplits: 1)
        return (String(parts[0]), parts.count == 2 ? String(parts[1]) : "00:00")
    }

    private static func isSafeOccurrenceIdentifierByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) ||
            (97...122).contains(byte) || byte == 45 || byte == 95
    }

    private static func stableDigest(_ value: String) -> String {
        // Swift's Hasher is deliberately randomized per process.  FNV-1a is
        // small, deterministic across launches, and sufficient as a compact
        // namespace digest because the readable form remains the common path.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16, uppercase: false)
    }
}

public struct SupplementNotificationPlan: Equatable, Sendable {
    public let evaluatedAt: Date
    public let intents: [SupplementNotificationIntent]
    public let maxPendingIntents: Int

    public init(
        evaluatedAt: Date,
        intents: [SupplementNotificationIntent],
        maxPendingIntents: Int
    ) {
        self.evaluatedAt = evaluatedAt
        self.intents = intents
        self.maxPendingIntents = maxPendingIntents
    }

    public var identifiers: Set<String> { Set(intents.map(\.identifier)) }
    public var scheduledCount: Int { intents.count }
}

public enum SupplementNotificationLocalTimeResolution: String, Equatable, Sendable {
    case exactLocalTime
    case nextValidTime
    case firstRepeatedTime
    case snoozed
}

public struct SupplementNotificationIntent: Equatable, Identifiable, Sendable {
    public let identifier: String
    public let scheduleIdentifier: String
    public let occurrenceIdentifier: String
    public let planID: String
    public let fireDate: Date
    public let localDate: String
    public let localTime: String
    public let timeZoneIdentifier: String
    public let title: String
    public let body: String
    public let isPrivate: Bool
    public let resolution: SupplementNotificationLocalTimeResolution

    public var id: String { identifier }

    public init(
        identifier: String,
        scheduleIdentifier: String,
        occurrenceIdentifier: String,
        planID: String,
        fireDate: Date,
        localDate: String,
        localTime: String,
        timeZoneIdentifier: String,
        title: String,
        body: String,
        isPrivate: Bool,
        resolution: SupplementNotificationLocalTimeResolution
    ) throws {
        self.identifier = identifier
        self.scheduleIdentifier = scheduleIdentifier
        self.occurrenceIdentifier = occurrenceIdentifier
        self.planID = planID
        self.fireDate = fireDate
        self.localDate = localDate
        self.localTime = localTime
        self.timeZoneIdentifier = timeZoneIdentifier
        self.title = title
        self.body = body
        self.isPrivate = isPrivate
        self.resolution = resolution
        try validate()
    }

    public func validate() throws {
        try SupplementValidation.validateOpaqueID(planID, field: "notification.planID")
        try SupplementValidation.validateOpaqueID(occurrenceIdentifier, field: "notification.occurrenceID")
        guard !identifier.isEmpty, !scheduleIdentifier.isEmpty, !occurrenceIdentifier.isEmpty,
              fireDate.timeIntervalSinceReferenceDate.isFinite,
              SupplementValidation.isDateOnly(localDate),
              SupplementValidation.isLocalTime(localTime),
              SupplementValidation.isIANATimeZone(timeZoneIdentifier) else {
            throw SupplementValidationError.invalidSchedule("notification intent")
        }
        try SupplementValidation.validateText(title, field: "notification.title", max: 160)
        try SupplementValidation.validateText(body, field: "notification.body", max: 1_000)
    }
}

public enum SupplementNotificationCopy: Equatable, Sendable {
    case privateReminder(title: String, body: String)
    case productAndTiming(title: String, body: String)

    public var title: String {
        switch self {
        case .privateReminder(let title, _), .productAndTiming(let title, _): return title
        }
    }

    public var body: String {
        switch self {
        case .privateReminder(_, let body), .productAndTiming(_, let body): return body
        }
    }

    public var isPrivate: Bool {
        if case .privateReminder = self { return true }
        return false
    }

    public static func make(for plan: SupplementPlan) -> SupplementNotificationCopy {
        let schedule = plan.schedule
        let privateCopy = schedule.notificationPreference == .genericPrivate || plan.lockScreenRedacted
        if privateCopy {
            return .privateReminder(
                title: "Supplement reminder",
                body: "Your private supplement reminder is scheduled for \(schedule.localTime)."
            )
        }

        let timing = schedule.timingNote.map { " \($0)" } ?? " at \(schedule.localTime)"
        return .productAndTiming(
            title: "\(plan.name) reminder",
            body: "You planned to take \(plan.name)\(timing)."
        )
    }

}

// MARK: - Stable action identifiers and typed decoding

public enum SupplementNotificationActionIdentifier {
    public static let category = "lifeos.supplement.actions.v1"
    public static let taken = "lifeos.supplement.action.taken.v1"
    public static let snooze = "lifeos.supplement.action.snooze.v1"
    public static let skip = "lifeos.supplement.action.skip.v1"
    public static let namespace = "lifeos.supplement"
    public static let planIDKey = "lifeos.supplement.planID"
    public static let occurrenceIDKey = "lifeos.supplement.occurrenceID"
}

public struct SupplementNotificationActionContext: Equatable, Sendable {
    public let planID: String
    public let occurrenceID: String

    public init(planID: String, occurrenceID: String) throws {
        try SupplementValidation.validateOpaqueID(planID, field: "notification.planID")
        try SupplementValidation.validateOpaqueID(occurrenceID, field: "notification.occurrenceID")
        self.planID = planID
        self.occurrenceID = occurrenceID
    }
}

public enum SupplementNotificationAction: Equatable, Sendable {
    case taken(SupplementNotificationActionContext)
    case snooze(SupplementNotificationActionContext)
    case skip(SupplementNotificationActionContext)
}

public enum SupplementNotificationActionDecoder {
    /// Decodes only LifeOS supplement action identifiers and their typed
    /// occurrence context.  It intentionally does not access or mutate a
    /// supplement store; a higher layer may turn this value into the existing
    /// `SupplementOccurrenceActionRequest` with its current revision/clock.
    public static func decode(
        actionIdentifier: String,
        userInfo: [String: String],
        categoryIdentifier: String? = nil
    ) throws -> SupplementNotificationAction {
        if let categoryIdentifier, categoryIdentifier != SupplementNotificationActionIdentifier.category {
            throw SupplementValidationError.invalidAction("unrelated notification category")
        }
        guard let planID = userInfo[SupplementNotificationActionIdentifier.planIDKey],
              let occurrenceID = userInfo[SupplementNotificationActionIdentifier.occurrenceIDKey] else {
            throw SupplementValidationError.invalidAction("notification action is missing occurrence context")
        }
        let context = try SupplementNotificationActionContext(planID: planID, occurrenceID: occurrenceID)
        switch actionIdentifier {
        case SupplementNotificationActionIdentifier.taken: return .taken(context)
        case SupplementNotificationActionIdentifier.snooze: return .snooze(context)
        case SupplementNotificationActionIdentifier.skip: return .skip(context)
        default:
            throw SupplementValidationError.invalidAction("unrelated notification action")
        }
    }

    public static func decode(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any],
        categoryIdentifier: String? = nil
    ) throws -> SupplementNotificationAction {
        let values = userInfo.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String, let value = entry.value as? String else { return }
            result[key] = value
        }
        return try decode(
            actionIdentifier: actionIdentifier,
            userInfo: values,
            categoryIdentifier: categoryIdentifier
        )
    }
}
