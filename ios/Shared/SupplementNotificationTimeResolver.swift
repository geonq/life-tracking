import Foundation

/// The one local-clock resolver used by both occurrence materialization and
/// notification planning.  Foundation's default date construction silently
/// rolls a spring-forward gap and may choose either side of a fall-back fold;
/// this boundary makes those choices explicit and deterministic.
public enum SupplementNotificationTimeResolver {
    public static func resolve(
        _ value: String,
        on day: DateComponents,
        calendar: Calendar
    ) throws -> (date: Date, resolution: SupplementNotificationLocalTimeResolution)? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            throw SupplementValidationError.invalidSchedule("localTime")
        }

        var dayStartComponents = day
        dayStartComponents.hour = 0
        dayStartComponents.minute = 0
        dayStartComponents.second = 0
        dayStartComponents.nanosecond = 0
        dayStartComponents.timeZone = calendar.timeZone
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
        // on this date.  The date guard rejects a Foundation fallback that
        // would otherwise roll a gap into the following local day.
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
        if let first, isOnTargetDay(first) {
            let afterFirst = first.addingTimeInterval(0.001)
            // Some Foundation releases return nil after the first side of a
            // repeated time.  The setter is an equivalent same-day fallback.
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
            let resolution: SupplementNotificationLocalTimeResolution =
                repeatedCandidate.map(isSameLocalTimeOnTargetDay) == true && repeatedCandidate != first
                    ? .firstRepeatedTime
                    : .exactLocalTime
            return (first, resolution)
        }

        // A spring-forward gap resolves to the first valid instant after the
        // gap on the same local day.  It never creates a second occurrence.
        guard let next = calendar.nextDate(
            after: searchAnchor,
            matching: matching,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ), isOnTargetDay(next) else {
            return nil
        }
        return (next, .nextValidTime)
    }
}
