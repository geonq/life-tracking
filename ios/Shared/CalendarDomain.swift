import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum CalendarProgress: String, Codable, CaseIterable, Sendable {
    case planned
    case inProgress = "in_progress"
    case done
    case aborted

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "blocked" {
            self = .aborted
        } else if let progress = Self(rawValue: value) {
            self = progress
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown calendar progress: \(value)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The durable kind of a calendar item.  `event` is the legacy/default kind:
/// older calendar payloads did not carry a kind field and continue to decode
/// as ordinary events.
public enum CalendarItemKind: String, Codable, CaseIterable, Sendable {
    case event
    case todo
    case dailySchedule

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case Self.event.rawValue:
            self = .event
        case Self.todo.rawValue:
            self = .todo
        case Self.dailySchedule.rawValue, "daily_schedule":
            // Accept the snake-case spelling used by an early peer build.
            self = .dailySchedule
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown calendar item kind: \(value)")
            )
        }
    }

    public var label: String {
        switch self {
        case .event: "Event"
        case .todo: "To-do"
        case .dailySchedule: "Daily schedule"
        }
    }
}

public enum CalendarValidationError: Error, Equatable, Sendable {
    case blankTitle
    case titleTooLong
    case invalidInterval
    case invalidTimestamp
    case invalidIconAsset
}

/// How often a recurring item repeats.
public enum CalendarRecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly

    public var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    var stepUnit: Calendar.Component {
        switch self {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        case .yearly: .year
        }
    }
}

/// A recurrence schedule attached to a calendar item: every N units, with an
/// optional inclusive last-occurrence start boundary. The anchor instance is
/// the item itself; every later occurrence is derived, never stored.
public struct CalendarRecurrenceRule: Codable, Equatable, Sendable {
    public var frequency: CalendarRecurrenceFrequency
    public var interval: Int
    /// Inclusive upper bound for occurrence starts. `nil` repeats indefinitely
    /// subject to the engine's expansion cap.
    public var until: Date?

    public init(frequency: CalendarRecurrenceFrequency, interval: Int = 1, until: Date? = nil) throws {
        guard interval >= 1 else { throw CalendarValidationError.invalidInterval }
        guard until.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw CalendarValidationError.invalidTimestamp
        }
        self.frequency = frequency
        self.interval = interval
        self.until = until
    }

    private enum CodingKeys: String, CodingKey {
        case frequency, interval, until
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frequency = try container.decode(CalendarRecurrenceFrequency.self, forKey: .frequency)
        try self.init(
            frequency: frequency,
            interval: try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1,
            until: try container.decodeIfPresent(Date.self, forKey: .until)
        )
    }

    /// Human summary used by the editor row and accessibility labels.
    public var summary: String {
        switch (frequency, interval) {
        case (.daily, 1): return "Every day"
        case (.weekly, 1): return "Every week"
        case (.monthly, 1): return "Every month"
        case (.yearly, 1): return "Every year"
        case (_, let n):
            let unit: String
            switch frequency {
            case .daily: unit = n == 1 ? "day" : "days"
            case .weekly: unit = n == 1 ? "week" : "weeks"
            case .monthly: unit = n == 1 ? "month" : "months"
            case .yearly: unit = n == 1 ? "year" : "years"
            }
            return "Every \(n) \(unit)"
        }
    }
}

/// Pure expansion of recurring items into concrete occurrences. Wall-clock
/// time-of-day is preserved across DST transitions by stepping with calendar
/// arithmetic; month and year steps clamp to the last valid day (Jan 31
/// monthly lands on Feb 28). Occurrences are never persisted: each one is a
/// value copy of the anchor carrying its own identity in
/// `occurrenceSourceID`.
public enum CalendarRecurrence {
    /// Hard ceiling on generated occurrences per item regardless of window,
    /// so an open-ended daily rule can never explode rendering or sync work.
    public static let maximumOccurrencesPerItem = 400

    /// Recurrence math is expressed in the item's stored wall-clock zone. The
    /// caller's calendar still supplies locale/week rules, but a travel event
    /// must not jump from 09:00 to 08:00 merely because the device is elsewhere.
    private static func calendar(for item: CalendarItem, fallback: Calendar) -> Calendar {
        guard let identifier = item.timeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier) else { return fallback }
        var adjusted = fallback
        adjusted.timeZone = timeZone
        return adjusted
    }

    /// Returns the calendar-derived start for an occurrence index without
    /// allowing `step * interval` to overflow. Keeping this calculation
    /// anchored to the original item preserves wall-clock and month/year
    /// clamping semantics across DST and variable-length calendar units.
    private static func start(
        forStep step: Int,
        item: CalendarItem,
        rule: CalendarRecurrenceRule,
        calendar: Calendar
    ) -> Date? {
        guard step >= 0 else { return nil }
        let value: Int
        if step == 0 {
            value = 0
        } else {
            guard rule.interval <= Int.max / step else { return nil }
            value = step * rule.interval
        }
        return calendar.date(
            byAdding: rule.frequency.stepUnit,
            value: value,
            to: item.start
        )
    }

    /// Finds the first occurrence that can overlap a finite window. The
    /// overlap condition is `occurrenceStart + duration > window.start`, so
    /// all earlier starts can be skipped safely. Exponential probing followed
    /// by binary search makes the number of calendar evaluations logarithmic in
    /// the number of periods between the anchor and the query, rather than one
    /// evaluation per historical period. The doubling guard bounds the probe
    /// even for malformed/extreme dates or intervals.
    private static func firstPotentialStep(
        for item: CalendarItem,
        rule: CalendarRecurrenceRule,
        duration: TimeInterval,
        window: DateInterval?,
        calendar: Calendar
    ) -> Int? {
        guard let window else { return 0 }

        let overlapThreshold = window.start.addingTimeInterval(-duration)
        guard item.start <= overlapThreshold else { return 0 }

        // `until` is inclusive, but an occurrence ending exactly at the
        // window start does not overlap. Nothing can qualify when the last
        // permitted start is at or before that strict threshold.
        if let until = rule.until, until <= overlapThreshold {
            return nil
        }

        var lower = 0
        var upper = 1

        // upper doubles on every pass, so a signed Int can require at most
        // one probe per bit before the range is exhausted.
        var bracketFound = false
        for _ in 0..<Int.bitWidth {
            guard let upperStart = start(forStep: upper, item: item, rule: rule, calendar: calendar) else {
                return nil
            }
            if upperStart > overlapThreshold {
                bracketFound = true
                break
            }

            lower = upper
            if upper > Int.max / 2 {
                // There is no representable later step to search. If the
                // largest representable step is still before the threshold,
                // no occurrence can overlap the finite query window.
                upper = Int.max
                guard let maximumStart = start(forStep: upper, item: item, rule: rule, calendar: calendar),
                      maximumStart > overlapThreshold else {
                    return nil
                }
                bracketFound = true
                break
            }
            upper *= 2
        }
        guard bracketFound else { return nil }

        // Find the first step whose start is strictly after the overlap
        // threshold. A failed calendar conversion is beyond the representable
        // date range and therefore also acts as the upper side of the search.
        while upper - lower > 1 {
            let midpoint = lower + (upper - lower) / 2
            if let midpointStart = start(forStep: midpoint, item: item, rule: rule, calendar: calendar),
               midpointStart <= overlapThreshold {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return upper
    }

    /// Returns the anchor item plus every derived occurrence overlapping the
    /// window (anchor start inside the window counts as overlap). A nil
    /// window expands up to the until boundary and cap only. A non-recurring
    /// item expands to just itself.
    public static func occurrences(
        of item: CalendarItem,
        overlapping window: DateInterval?,
        calendar: Calendar
    ) -> [CalendarItem] {
        guard !item.isDeleted else { return [] }
        guard let rule = item.recurrence else { return [item] }

        let calendar = Self.calendar(for: item, fallback: calendar)

        let duration = item.end.timeIntervalSince(item.start)
        var results: [CalendarItem] = []
        guard var step = firstPotentialStep(
            for: item,
            rule: rule,
            duration: duration,
            window: window,
            calendar: calendar
        ) else {
            return results
        }

        while results.count < maximumOccurrencesPerItem {
            guard let start = start(forStep: step, item: item, rule: rule, calendar: calendar) else { break }
            // Starts are monotonically increasing; once past the inclusive
            // until boundary (or the window end) nothing later can qualify.
            if let until = rule.until, start > until { break }
            if let window, start >= window.end { break }

            let occurrenceEnd = start.addingTimeInterval(duration)
            let overlapsWindow = window.map { occurrenceEnd > $0.start } ?? true
            if overlapsWindow {
                if step == 0 {
                    results.append(item)
                } else if let occurrence = try? item.updating(start: start, end: occurrenceEnd, at: item.updatedAt) {
                    var copy = occurrence
                    copy.occurrenceSourceID = item.id
                    results.append(copy)
                }
            }
            guard step < Int.max else { break }
            step += 1
        }
        return results
    }
}

public enum CalendarSnapshotError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case tooManyItems
    case payloadTooLarge
    case duplicateItemID

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported calendar schema version \(version)."
        case .tooManyItems:
            return "The calendar contains too many items to load safely."
        case .payloadTooLarge:
            return "The calendar payload is too large to save safely."
        case .duplicateItemID:
            return "The calendar contains duplicate item identities."
        }
    }
}

/// Validates the single-grapheme emoji value accepted by the calendar icon
/// contract. Apple does not expose an enumerable installed emoji catalogue;
/// callers may still provide any emoji copied from the system keyboard.
public enum CalendarEmojiValidation {
    public static func validated(_ value: String?) -> String? {
        guard let value, value.count == 1 else { return nil }
        let scalars = Array(value.unicodeScalars)
        guard scalars.contains(where: { $0.properties.isEmojiPresentation }) ||
              (scalars.count > 1 && scalars.contains(where: { $0.properties.isEmoji })) else {
            return nil
        }
        return value
    }
}

/// SF Symbol names are persisted as names, never as a rendered image. The
/// domain boundary validates only the bounded name syntax. Availability is a
/// rendering concern because a valid symbol can be introduced by a newer OS;
/// the receiving UI must use its fallback when that symbol is unavailable.
public enum CalendarSystemIconSupport {
    public static func validatedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name == value,
              name.utf8.count <= 128,
              name.unicodeScalars.allSatisfy({ scalar in
                  (0x41...0x5A).contains(scalar.value)
                      || (0x61...0x7A).contains(scalar.value)
                      || (0x30...0x39).contains(scalar.value)
                      || scalar.value == 0x2E // .
                      || scalar.value == 0x2D // -
                      || scalar.value == 0x5F // _
              }) else {
            return nil
        }
        return name
    }

    public static func isAvailable(_ value: String) -> Bool {
        guard let name = validatedName(value) else { return false }
#if os(iOS)
        return UIImage(systemName: name) != nil
#elseif os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
#else
        return false
#endif
    }
}

public struct CalendarItem: Codable, Equatable, Identifiable, Sendable {
    public static let maximumTitleUTF8Bytes = 240
    public let id: UUID
    public var title: String
    public var kind: CalendarItemKind
    /// A missing value is a real no-icon choice, not an invisible placeholder
    /// glyph. `iconAsset` and `systemIconName` are alternate sources; the
    /// initializer enforces the precedence system symbol → custom asset → emoji.
    public var icon: String?
    public var iconAsset: CalendarIconAsset?
    public var systemIconName: String?
    public var status: CalendarProgress
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String?
    /// When present, this item generates derived occurrences. `nil` is a real
    /// no-recurrence choice.
    public var recurrence: CalendarRecurrenceRule?
    /// Transient identity of a derived occurrence (the anchor's id). Never
    /// persisted and never encoded; stored items always carry `nil`.
    public var occurrenceSourceID: UUID?
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }
    public var hasIcon: Bool { icon != nil || iconAsset != nil || systemIconName != nil }

    public init(id: UUID = UUID(), title: String, kind: CalendarItemKind = .event, icon: String? = nil, iconAsset: CalendarIconAsset? = nil,
                systemIconName: String? = nil, status: CalendarProgress = .planned,
                start: Date, end: Date, createdAt: Date = .now, updatedAt: Date? = nil, deletedAt: Date? = nil,
                timeZoneIdentifier: String? = nil, recurrence: CalendarRecurrenceRule? = nil) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw CalendarValidationError.blankTitle }
        guard trimmedTitle.utf8.count <= Self.maximumTitleUTF8Bytes else { throw CalendarValidationError.titleTooLong }
        guard end > start else { throw CalendarValidationError.invalidInterval }
        let effectiveUpdatedAt = updatedAt ?? createdAt
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              effectiveUpdatedAt.timeIntervalSinceReferenceDate.isFinite,
              deletedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              createdAt <= effectiveUpdatedAt,
              deletedAt.map({ $0 >= createdAt && $0 <= effectiveUpdatedAt }) ?? true else {
            throw CalendarValidationError.invalidTimestamp
        }
        self.id = id; self.title = trimmedTitle; self.kind = kind
        let validatedSystemIconName = CalendarSystemIconSupport.validatedName(systemIconName)
        self.systemIconName = validatedSystemIconName
        // A payload can come from a newer peer with more than one source. Keep
        // exactly one semantic source at the boundary so rendering, merges,
        // and conflict keys cannot disagree about which icon is selected.
        let retainedAsset = validatedSystemIconName == nil ? iconAsset : nil
        self.iconAsset = retainedAsset
        self.icon = validatedSystemIconName == nil && retainedAsset == nil
            ? CalendarEmojiValidation.validated(icon)
            : nil
        self.status = status; self.start = start; self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier.flatMap { TimeZone(identifier: $0)?.identifier }
        self.recurrence = recurrence
        self.occurrenceSourceID = nil
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt; self.deletedAt = deletedAt
    }

    /// Rechecks the mutable value before it crosses a durable or sync
    /// boundary. The throwing initializer protects decoded values; this
    /// method also protects callers that mutate a public field afterwards.
    public func validatedForPersistence() throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw CalendarValidationError.blankTitle }
        guard trimmedTitle.utf8.count <= Self.maximumTitleUTF8Bytes else {
            throw CalendarValidationError.titleTooLong
        }
        guard end > start,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt <= updatedAt,
              deletedAt.map({
                  $0.timeIntervalSinceReferenceDate.isFinite
                      && $0 >= createdAt
                      && $0 <= updatedAt
              }) ?? true else {
            throw CalendarValidationError.invalidTimestamp
        }
        guard icon.map({ CalendarEmojiValidation.validated($0) != nil }) ?? true,
              systemIconName.map({ CalendarSystemIconSupport.validatedName($0) != nil }) ?? true,
              timeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true else {
            throw CalendarValidationError.invalidIconAsset
        }
        guard (recurrence?.interval ?? 1) >= 1,
              recurrence?.until.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw CalendarValidationError.invalidInterval
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, icon, iconAsset, systemIconName, status, start, end, createdAt, updatedAt, deletedAt, timeZoneIdentifier, recurrence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawIcon = try container.decodeIfPresent(String.self, forKey: .icon)
        let rawSystemIconName = try container.decodeIfPresent(String.self, forKey: .systemIconName)
        let rawTimeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        guard rawIcon.map({ CalendarEmojiValidation.validated($0) == Optional($0) }) ?? true,
              rawSystemIconName.map({ CalendarSystemIconSupport.validatedName($0) == Optional($0) }) ?? true,
              rawTimeZoneIdentifier.map({
                  !$0.isEmpty
                      && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      && TimeZone(identifier: $0) != nil
              }) ?? true else {
            throw CalendarValidationError.invalidIconAsset
        }
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            title: container.decode(String.self, forKey: .title),
            kind: container.decodeIfPresent(CalendarItemKind.self, forKey: .kind) ?? .event,
            // Legacy payloads contain a string; new payloads may omit or
            // encode null to represent a deliberate no-icon selection.
            icon: rawIcon,
            iconAsset: container.decodeIfPresent(CalendarIconAsset.self, forKey: .iconAsset),
            systemIconName: rawSystemIconName,
            status: container.decode(CalendarProgress.self, forKey: .status),
            start: container.decode(Date.self, forKey: .start),
            end: container.decode(Date.self, forKey: .end),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt),
            timeZoneIdentifier: rawTimeZoneIdentifier,
            recurrence: container.decodeIfPresent(CalendarRecurrenceRule.self, forKey: .recurrence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        // Encode nil explicitly. Decoding still accepts a missing legacy key.
        try container.encode(icon, forKey: .icon)
        try container.encodeIfPresent(iconAsset, forKey: .iconAsset)
        try container.encodeIfPresent(systemIconName, forKey: .systemIconName)
        try container.encode(status, forKey: .status)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encodeIfPresent(recurrence, forKey: .recurrence)
    }

    fileprivate var conflictKey: String {
        // Length-prefix each component so a user-controlled title or icon
        // cannot create delimiter collisions. The resulting string is a
        // deterministic total tie-break over every persisted field.
        func component(_ value: String) -> String {
            "\(value.utf8.count):\(value)"
        }
        return [
            id.uuidString,
            isDeleted ? "1" : "0",
            title,
            icon ?? "",
            iconAsset?.deterministicKey ?? "",
            systemIconName ?? "",
            kind.rawValue,
            status.rawValue,
            String(start.timeIntervalSince1970),
            String(end.timeIntervalSince1970),
            String(createdAt.timeIntervalSince1970),
            String(updatedAt.timeIntervalSince1970),
            String(deletedAt?.timeIntervalSince1970 ?? 0),
            timeZoneIdentifier ?? "",
            recurrence.map {
                "present|\($0.frequency.rawValue)|\($0.interval)|until:\($0.until.map { String($0.timeIntervalSince1970) } ?? "nil")"
            } ?? "absent"
        ].map(component).joined()
    }

    public func updatingProgress(_ status: CalendarProgress, at: Date) throws -> CalendarItem {
        try updating(status: status, at: at)
    }

    public func updating(kind: CalendarItemKind? = nil, title: String? = nil, icon: String? = nil, clearIcon: Bool = false,
                         iconAsset: CalendarIconAsset? = nil,
                         clearIconAsset: Bool = false, systemIconName: String? = nil,
                         clearSystemIconName: Bool = false, status: CalendarProgress? = nil,
                         start: Date? = nil, end: Date? = nil, at: Date,
                         timeZoneIdentifier: String? = nil,
                         recurrence: CalendarRecurrenceRule? = nil, clearRecurrence: Bool = false) throws -> CalendarItem {
        try CalendarItem(id: id, title: title ?? self.title, kind: kind ?? self.kind, icon: clearIcon ? nil : (icon ?? self.icon),
                         iconAsset: clearIconAsset ? nil : (iconAsset ?? self.iconAsset),
                         systemIconName: clearSystemIconName ? nil : (systemIconName ?? self.systemIconName),
                         status: status ?? self.status,
                         start: start ?? self.start, end: end ?? self.end, createdAt: createdAt, updatedAt: at, deletedAt: deletedAt,
                         timeZoneIdentifier: timeZoneIdentifier ?? self.timeZoneIdentifier,
                         recurrence: clearRecurrence ? nil : (recurrence ?? self.recurrence))
    }

    /// A to-do is complete when its durable progress is `.done`; toggling the
    /// checkbox never changes its interval or kind.
    public func togglingDone(at date: Date) throws -> CalendarItem {
        guard kind == .todo else { return self }
        return try updating(status: status == .done ? .planned : .done, at: date)
    }

    public func deleting(at: Date) -> CalendarItem {
        var copy = self; copy.deletedAt = at; copy.updatedAt = at; return copy
    }
}

/// Pure title matching for calendar search. Kept out of SwiftUI so ranking,
/// folding, and deletion rules stay deterministic in unit tests.
public enum CalendarSearch {
    /// Case- and diacritic-insensitive substring match over non-deleted item
    /// titles. Upcoming matches lead in ascending start order; past matches
    /// follow, most recent first. A blank query yields no results.
    public static func results(
        matching query: String,
        in items: [CalendarItem],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [CalendarItem] {
        let needle = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        let today = calendar.startOfDay(for: now)
        let matches = items.filter { !$0.isDeleted && normalized($0.title).contains(needle) }
        let upcoming = matches
            .filter { $0.start >= today }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        let past = matches
            .filter { $0.start < today }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start > $1.start }
        return upcoming + past
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The blank-query landing list: the most recently touched items first
    /// (activity = the later of created/updated), capped at `limit`. Items
    /// without any usable activity timestamp fall back to the next upcoming
    /// starts so the section never lies about being "recent". Tombstones are
    /// excluded in both branches; ties break deterministically by id.
    public static func recentItems(
        in items: [CalendarItem],
        limit: Int = 5,
        now: Date = .now
    ) -> [CalendarItem] {
        let visible = items.filter { !$0.isDeleted }
        let boundedLimit = max(0, limit)
        let withActivity = visible.filter { $0.createdAt > .distantPast || $0.updatedAt > .distantPast }
        if !withActivity.isEmpty {
            return Array(
                withActivity
                    .sorted { lhs, rhs in
                        let lhsActivity = max(lhs.createdAt, lhs.updatedAt)
                        let rhsActivity = max(rhs.createdAt, rhs.updatedAt)
                        if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    .prefix(boundedLimit)
            )
        }
        return Array(
            visible
                .filter { $0.start >= now }
                .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
                .prefix(boundedLimit)
        )
    }

    /// The day the pager must show for a search result. Occurrence-aware
    /// callers pass the derived occurrence; the anchor's start maps identically
    /// because the pager operates on local calendar days.
    public static func navigationDay(for item: CalendarItem, calendar: Calendar) -> Date {
        calendar.startOfDay(for: item.start)
    }
}

public struct CalendarSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// This is a defensive item-count ceiling in addition to the byte ceiling
    /// enforced by the local store and remote client. It prevents a compact
    /// malformed payload from expanding into an unbounded merge/render pass.
    public static let maximumItemCount = 1_024
    public static let maximumEncodedBytes = 256 * 1_024

    public var schemaVersion: Int = CalendarSnapshot.currentSchemaVersion
    public var items: [CalendarItem]

    public init(items: [CalendarItem] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.items = Self.sortedItems(items)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        guard version == Self.currentSchemaVersion else {
            throw CalendarSnapshotError.unsupportedSchemaVersion(version)
        }
        let decodedItems: [CalendarItem]
        if !container.contains(.items) {
            decodedItems = []
        } else if try container.decodeNil(forKey: .items) {
            decodedItems = []
        } else {
            var itemContainer = try container.nestedUnkeyedContainer(forKey: .items)
            var boundedItems: [CalendarItem] = []
            boundedItems.reserveCapacity(min(itemContainer.count ?? Self.maximumItemCount, Self.maximumItemCount))
            while !itemContainer.isAtEnd {
                guard boundedItems.count < Self.maximumItemCount else {
                    throw CalendarSnapshotError.tooManyItems
                }
                boundedItems.append(try itemContainer.decode(CalendarItem.self))
            }
            decodedItems = boundedItems
        }
        var seenIDs = Set<UUID>()
        seenIDs.reserveCapacity(decodedItems.count)
        for item in decodedItems {
            guard seenIDs.insert(item.id).inserted else {
                throw CalendarSnapshotError.duplicateItemID
            }
        }
        schemaVersion = version
        items = Self.sortedItems(decodedItems)
        try validatedForPersistence()
    }

    private static func sortedItems(_ items: [CalendarItem]) -> [CalendarItem] {
        var byID: [UUID: CalendarItem] = [:]
        for item in items {
            guard let current = byID[item.id] else {
                byID[item.id] = item
                continue
            }
            if prefers(item, over: current) {
                byID[item.id] = item
            }
        }
        return byID.values.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
    }

    fileprivate static func prefers(_ candidate: CalendarItem, over current: CalendarItem) -> Bool {
        let candidateClock = mutationClock(for: candidate)
        let currentClock = mutationClock(for: current)
        return candidateClock > currentClock ||
            (candidateClock == currentClock && candidate.conflictKey > current.conflictKey)
    }

    /// A tombstone's deletion is the semantic mutation. Metadata updates that
    /// happen after deletion must not resurrect a deleted record's precedence
    /// over a later live edit merely because updatedAt is larger.
    fileprivate static func mutationClock(for item: CalendarItem) -> Date {
        item.deletedAt ?? item.updatedAt
    }

    /// Validates a snapshot immediately before it crosses a durable or sync
    /// boundary. No item is silently truncated: callers receive a truthful
    /// failure and can keep the last acknowledged snapshot visible.
    public func validatedForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CalendarSnapshotError.unsupportedSchemaVersion(schemaVersion)
        }
        guard items.count <= Self.maximumItemCount else {
            throw CalendarSnapshotError.tooManyItems
        }
        var ids = Set<UUID>()
        ids.reserveCapacity(items.count)
        for item in items {
            guard ids.insert(item.id).inserted else {
                throw CalendarSnapshotError.duplicateItemID
            }
            try item.validatedForPersistence()
        }
    }

    public func items(on day: Date, calendar: Calendar = .current) -> [CalendarItem] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return items.filter { !$0.isDeleted && $0.start < dayEnd && $0.end > dayStart }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }

    public func merged(with other: CalendarSnapshot) -> CalendarSnapshot {
        var byID: [UUID: CalendarItem] = [:]
        for item in items {
            if let current = byID[item.id] {
                if Self.prefers(item, over: current) { byID[item.id] = item }
            } else {
                byID[item.id] = item
            }
        }
        for candidate in other.items {
            guard let current = byID[candidate.id] else {
                byID[candidate.id] = candidate
                continue
            }
            if Self.prefers(candidate, over: current) { byID[candidate.id] = candidate }
        }
        // The dictionary merge is linear. One final O(n log n) sort is required
        // for deterministic start/id order used by rendering and persistence.
        return CalendarSnapshot(items: Array(byID.values))
    }
}

/// The result of validating an untrusted snapshot before it enters the local
/// store or is published to another peer. Invalid records are quarantined from
/// this merge; valid independent records can still make progress.
public struct CalendarRemoteMergeReport: Equatable, Sendable {
    public let snapshot: CalendarSnapshot
    public let rejectedItemCount: Int
    public let acceptedDeletionCount: Int
    public let rejectedDeletionCount: Int
    public let rejectedEnvelope: Bool

    public var warning: String? {
        var parts: [String] = []
        if rejectedEnvelope {
            parts.append("rejected a remote calendar payload with an invalid timestamp")
        }
        if rejectedDeletionCount > 0 {
            parts.append("rejected \(rejectedDeletionCount) remote deletion(s) and preserved local records")
        }
        let rejectedNonDeletionCount = rejectedItemCount - rejectedDeletionCount
        if rejectedNonDeletionCount > 0 {
            parts.append("ignored \(rejectedNonDeletionCount) remote change(s) with invalid timestamps or identity")
        }
        if acceptedDeletionCount > 0 {
            parts.append("accepted \(acceptedDeletionCount) remote deletion(s)")
        }
        guard !parts.isEmpty else { return nil }
        return "Calendar sync \(parts.joined(separator: "; "))."
    }
}

/// Trust policy for snapshots arriving from the server or a paired device.
/// CalendarItem's normal LWW merge remains useful for local data; remote data
/// must pass this boundary first because its clocks and tombstones are not
/// authoritative merely because the transport was authenticated.
public enum CalendarRemoteMergePolicy {
    public static let maximumClockSkew: TimeInterval = 5 * 60

    public static func sanitize(
        _ remote: CalendarSnapshot,
        against local: CalendarSnapshot,
        now: Date = .now,
        sentAt: Date? = nil
    ) -> CalendarRemoteMergeReport {
        guard acceptableTimestamp(now, now: now),
              sentAt.map({ acceptableEnvelopeTimestamp($0, now: now) }) ?? true else {
            return CalendarRemoteMergeReport(
                snapshot: CalendarSnapshot(),
                rejectedItemCount: remote.items.count,
                acceptedDeletionCount: 0,
                rejectedDeletionCount: remote.items.reduce(into: 0) { count, item in
                    if item.deletedAt != nil { count += 1 }
                },
                rejectedEnvelope: true
            )
        }

        var localByID: [UUID: CalendarItem] = [:]
        localByID.reserveCapacity(local.items.count)
        for item in local.items {
            localByID[item.id] = item
        }

        var accepted: [CalendarItem] = []
        accepted.reserveCapacity(remote.items.count)
        var rejectedItemCount = 0
        var acceptedDeletionCount = 0
        var rejectedDeletionCount = 0
        var seenRemoteIDs = Set<UUID>()
        seenRemoteIDs.reserveCapacity(remote.items.count)

        for candidate in remote.items {
            let isDeletion = candidate.deletedAt != nil
            guard seenRemoteIDs.insert(candidate.id).inserted else {
                rejectedItemCount += 1
                if isDeletion { rejectedDeletionCount += 1 }
                continue
            }
            guard validTimestampedItem(candidate, now: now) else {
                rejectedItemCount += 1
                if isDeletion { rejectedDeletionCount += 1 }
                continue
            }

            // Older remote mutations cannot outrank the durable local record.
            // Every equal-clock mutation uses the same deterministic conflict
            // key as CalendarSnapshot.merged so both devices converge even
            // when their wall clocks produce the same timestamp. A tombstone
            // participates using its deletion event clock, not a later metadata
            // update; its deletedAt value must still pass the causal check below.
            if let current = localByID[candidate.id], candidate != current {
                let candidateClock = CalendarSnapshot.mutationClock(for: candidate)
                let currentClock = CalendarSnapshot.mutationClock(for: current)
                let isOlder = candidateClock < currentClock
                let isEqualClockLoser = candidateClock == currentClock
                    && !CalendarSnapshot.prefers(candidate, over: current)
                if isOlder || isEqualClockLoser {
                    rejectedItemCount += 1
                    if isDeletion { rejectedDeletionCount += 1 }
                    continue
                }
            }

            if let current = localByID[candidate.id],
               !compatibleCreationIdentity(candidate.createdAt, current.createdAt) {
                rejectedItemCount += 1
                if isDeletion { rejectedDeletionCount += 1 }
                continue
            }

            if let deletedAt = candidate.deletedAt,
               let current = localByID[candidate.id] {
                // An identical tombstone is an idempotent replay. A different
                // tombstone must be newer than the local semantic mutation, or
                // must win the deterministic equal-clock conflict above. Its
                // deletion event must not predate that mutation.
                if candidate == current { continue }
                let candidateClock = CalendarSnapshot.mutationClock(for: candidate)
                let currentClock = CalendarSnapshot.mutationClock(for: current)
                guard (candidateClock > currentClock
                        || CalendarSnapshot.prefers(candidate, over: current)),
                      deletedAt >= currentClock else {
                    rejectedItemCount += 1
                    rejectedDeletionCount += 1
                    continue
                }
                acceptedDeletionCount += 1
            } else if isDeletion {
                // Keep an unseen tombstone so a device that missed the create
                // event does not resurrect it later. It cannot erase anything
                // locally because there is no matching local identity.
                acceptedDeletionCount += 1
            }

            accepted.append(candidate)
        }

        return CalendarRemoteMergeReport(
            snapshot: CalendarSnapshot(items: accepted),
            rejectedItemCount: rejectedItemCount,
            acceptedDeletionCount: acceptedDeletionCount,
            rejectedDeletionCount: rejectedDeletionCount,
            rejectedEnvelope: false
        )
    }

    private static func validTimestampedItem(_ item: CalendarItem, now: Date) -> Bool {
        acceptableTimestamp(item.createdAt, now: now)
            && acceptableTimestamp(item.updatedAt, now: now)
            && item.createdAt <= item.updatedAt
            && (item.deletedAt.map {
                acceptableTimestamp($0, now: now)
                    && $0 >= item.createdAt
                    && $0 <= item.updatedAt
            } ?? true)
    }

    /// Creation dates are immutable identity metadata, but version-1 peers
    /// historically serialized them at whole-second precision. Permit only
    /// that narrow legacy representation, plus sub-microsecond floating-point
    /// drift from the current fractional codec. Mutation clocks remain strict.
    private static func compatibleCreationIdentity(_ candidate: Date, _ current: Date) -> Bool {
        let candidateSeconds = candidate.timeIntervalSince1970
        let currentSeconds = current.timeIntervalSince1970
        guard candidateSeconds.isFinite, currentSeconds.isFinite else { return false }
        let tolerance = 0.000_001
        let difference = abs(candidateSeconds - currentSeconds)
        if difference <= tolerance { return true }

        let candidateIsWholeSecond = abs(candidateSeconds - candidateSeconds.rounded()) <= tolerance
        let currentIsWholeSecond = abs(currentSeconds - currentSeconds.rounded()) <= tolerance
        guard candidateIsWholeSecond != currentIsWholeSecond else { return false }
        return floor(candidateSeconds) == floor(currentSeconds)
    }

    /// Item mutation clocks are receiver-bounded. The envelope transport may
    /// tolerate five minutes of clock skew, but a remote created/updated/
    /// deleted timestamp in the future is quarantined instead of being used as
    /// an authoritative LWW clock. This preserves legitimate local edits even
    /// when a paired device has a fast clock; the peer can retry after its clock
    /// is corrected. Scheduled event start/end values remain independent and
    /// may of course be in the future.
    private static func acceptableTimestamp(_ date: Date, now: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else { return false }
        return date <= now
    }

    private static func acceptableEnvelopeTimestamp(_ date: Date, now: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else { return false }
        return abs(date.timeIntervalSince(now)) <= Self.maximumClockSkew
    }
}
