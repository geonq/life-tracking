import Foundation

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

public enum CalendarValidationError: Error, Equatable, Sendable {
    case blankTitle
    case invalidInterval
    case invalidIconAsset
}

public struct CalendarItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var icon: String
    public var iconAsset: CalendarIconAsset?
    public var status: CalendarProgress
    public var start: Date
    public var end: Date
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(id: UUID = UUID(), title: String, icon: String = "📅", iconAsset: CalendarIconAsset? = nil, status: CalendarProgress = .planned,
                start: Date, end: Date, createdAt: Date = .now, updatedAt: Date? = nil, deletedAt: Date? = nil) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarValidationError.blankTitle }
        guard end > start else { throw CalendarValidationError.invalidInterval }
        self.id = id; self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.icon = CalendarItem.validIcon(icon) ? icon : "📅"
        self.iconAsset = iconAsset
        self.status = status; self.start = start; self.end = end; self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt; self.deletedAt = deletedAt
    }

    private static func validIcon(_ value: String) -> Bool {
        guard value.count == 1 else { return false }
        return value.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        }
    }

    fileprivate var conflictKey: String {
        [
            isDeleted ? "1" : "0",
            title,
            icon,
            iconAsset?.deterministicKey ?? "",
            status.rawValue,
            String(start.timeIntervalSince1970),
            String(end.timeIntervalSince1970),
            String(deletedAt?.timeIntervalSince1970 ?? 0)
        ].joined(separator: "|")
    }

    public func updatingProgress(_ status: CalendarProgress, at: Date) throws -> CalendarItem {
        try updating(status: status, at: at)
    }

    public func updating(title: String? = nil, icon: String? = nil, iconAsset: CalendarIconAsset? = nil,
                         clearIconAsset: Bool = false, status: CalendarProgress? = nil,
                         start: Date? = nil, end: Date? = nil, at: Date) throws -> CalendarItem {
        try CalendarItem(id: id, title: title ?? self.title, icon: icon ?? self.icon,
                         iconAsset: clearIconAsset ? nil : (iconAsset ?? self.iconAsset), status: status ?? self.status,
                         start: start ?? self.start, end: end ?? self.end, createdAt: createdAt, updatedAt: at, deletedAt: deletedAt)
    }

    public func deleting(at: Date) -> CalendarItem {
        var copy = self; copy.deletedAt = at; copy.updatedAt = at; return copy
    }
}

public struct CalendarSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var items: [CalendarItem]
    public init(items: [CalendarItem] = []) { self.items = items.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start } }

    public func items(on day: Date, calendar: Calendar = .current) -> [CalendarItem] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return items.filter { !$0.isDeleted && $0.start < dayEnd && $0.end > dayStart }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }

    public func merged(with other: CalendarSnapshot) -> CalendarSnapshot {
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for candidate in other.items {
            guard let current = byID[candidate.id] else { byID[candidate.id] = candidate; continue }
            if candidate.updatedAt > current.updatedAt ||
                (candidate.updatedAt == current.updatedAt && candidate.conflictKey > current.conflictKey) {
                byID[candidate.id] = candidate
            }
        }
        return CalendarSnapshot(items: Array(byID.values))
    }
}
