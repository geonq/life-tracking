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

public enum CalendarValidationError: Error, Equatable, Sendable {
    case blankTitle
    case invalidInterval
    case invalidIconAsset
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
/// availability check is intentionally performed at the boundary so an old,
/// unavailable, or malformed name is discarded at the domain boundary.
public enum CalendarSystemIconSupport {
    public static func validatedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
#if os(iOS)
        return UIImage(systemName: name) == nil ? nil : name
#elseif os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? nil : name
#else
        return nil
#endif
    }

    public static func isAvailable(_ value: String) -> Bool {
        validatedName(value) != nil
    }
}

public struct CalendarItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    /// A missing value is a real no-icon choice, not an invisible placeholder
    /// glyph. `iconAsset` and `systemIconName` are alternate sources; the
    /// initializer enforces the precedence system symbol → custom asset → emoji.
    public var icon: String?
    public var iconAsset: CalendarIconAsset?
    public var systemIconName: String?
    public var status: CalendarProgress
    public var start: Date
    public var end: Date
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }
    public var hasIcon: Bool { icon != nil || iconAsset != nil || systemIconName != nil }

    public init(id: UUID = UUID(), title: String, icon: String? = nil, iconAsset: CalendarIconAsset? = nil,
                systemIconName: String? = nil, status: CalendarProgress = .planned,
                start: Date, end: Date, createdAt: Date = .now, updatedAt: Date? = nil, deletedAt: Date? = nil) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarValidationError.blankTitle }
        guard end > start else { throw CalendarValidationError.invalidInterval }
        self.id = id; self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
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
        self.status = status; self.start = start; self.end = end; self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt; self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, icon, iconAsset, systemIconName, status, start, end, createdAt, updatedAt, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            title: container.decode(String.self, forKey: .title),
            // Legacy payloads contain a string; new payloads may omit or
            // encode null to represent a deliberate no-icon selection.
            icon: container.decodeIfPresent(String.self, forKey: .icon),
            iconAsset: container.decodeIfPresent(CalendarIconAsset.self, forKey: .iconAsset),
            systemIconName: container.decodeIfPresent(String.self, forKey: .systemIconName),
            status: container.decode(CalendarProgress.self, forKey: .status),
            start: container.decode(Date.self, forKey: .start),
            end: container.decode(Date.self, forKey: .end),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
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
    }

    fileprivate var conflictKey: String {
        [
            isDeleted ? "1" : "0",
            title,
            icon ?? "",
            iconAsset?.deterministicKey ?? "",
            systemIconName ?? "",
            status.rawValue,
            String(start.timeIntervalSince1970),
            String(end.timeIntervalSince1970),
            String(deletedAt?.timeIntervalSince1970 ?? 0)
        ].joined(separator: "|")
    }

    public func updatingProgress(_ status: CalendarProgress, at: Date) throws -> CalendarItem {
        try updating(status: status, at: at)
    }

    public func updating(title: String? = nil, icon: String? = nil, clearIcon: Bool = false,
                         iconAsset: CalendarIconAsset? = nil,
                         clearIconAsset: Bool = false, systemIconName: String? = nil,
                         clearSystemIconName: Bool = false, status: CalendarProgress? = nil,
                         start: Date? = nil, end: Date? = nil, at: Date) throws -> CalendarItem {
        try CalendarItem(id: id, title: title ?? self.title, icon: clearIcon ? nil : (icon ?? self.icon),
                         iconAsset: clearIconAsset ? nil : (iconAsset ?? self.iconAsset),
                         systemIconName: clearSystemIconName ? nil : (systemIconName ?? self.systemIconName),
                         status: status ?? self.status,
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
