import Foundation

// MARK: - Shared supplement contract helpers

/// Errors raised when supplement data does not satisfy the cross-platform
/// supplements contract.  The occurrence, correction, inventory, snapshot,
/// and action models use the same error type from their companion domain file.
public enum SupplementValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsafeIdentifier(String)
    case duplicateIdentifier(String)
    case danglingPlanReference(String)
    case invalidText(String)
    case invalidDate(String)
    case invalidSchedule(String)
    case invalidBounds(String)
    case invalidTimestamp(String)
    case contradictoryState(String)
    case invalidAction(String)
    case revisionConflict
    case insufficientInventory
}

struct SupplementAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Supplement objects are strict on the wire.  Keeping this helper internal
/// lets the occurrence/correction/inventory models share the exact rule.
func rejectUnknownSupplementKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: SupplementAnyCodingKey.self)
    let received = Set(container.allKeys.map(\.stringValue))
    guard received.isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath,
                 debugDescription: "Unknown supplement field")
        )
    }
}

/// Optional contract fields may be omitted, but an explicit JSON null is not
/// equivalent to omission (matching Zod's `.optional()` semantics).
func decodeSupplementOptional<T: Decodable, Key: CodingKey>(
    _ type: T.Type,
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>
) throws -> T? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw DecodingError.valueNotFound(
            type,
            .init(codingPath: container.codingPath + [key],
                  debugDescription: "Explicit null is not accepted")
        )
    }
    return try container.decode(type, forKey: key)
}

private let supplementTimestampPattern = try! NSRegularExpression(
    pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$"#,
    options: []
)

enum SupplementValidation {
    static let maximumClockSkew: TimeInterval = 5
    static let maximumRevision = 9_007_199_254_740_991
    static let maximumInventoryUnits = 1_000_000_000

    static func parseISO8601(_ value: String, field: String = "timestamp") throws -> Date {
        guard value.utf16.count <= 40,
              supplementTimestampPattern.firstMatch(
                in: value,
                options: [],
                range: NSRange(location: 0, length: value.utf16.count)
              ) != nil else {
            throw SupplementValidationError.invalidTimestamp(field)
        }

        // ISO8601DateFormatter is stricter than Zod about seconds and about
        // offsets without a colon.  Normalize those two wire forms after the
        // contract regex has accepted them.
        let body: String
        let zone: String
        if value.hasSuffix("Z") {
            body = String(value.dropLast())
            zone = "Z"
        } else if value.count >= 6 && value[value.index(value.endIndex, offsetBy: -3)] == ":" {
            body = String(value.dropLast(6))
            zone = String(value.suffix(6))
        } else {
            body = String(value.dropLast(5))
            let rawZone = String(value.suffix(5))
            zone = String(rawZone.prefix(3)) + ":" + rawZone.suffix(2)
        }
        let time = body.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false).last!
        let normalizedBody = time.utf8.count == 5 ? body + ":00" : body
        let normalized = normalizedBody + zone

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: normalized) ?? standard.date(from: normalized),
              date.timeIntervalSinceReferenceDate.isFinite else {
            throw SupplementValidationError.invalidTimestamp(field)
        }
        return date
    }

    static func validateObserved(_ date: Date, field: String, now: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              date <= now.addingTimeInterval(maximumClockSkew) else {
            throw SupplementValidationError.invalidTimestamp(field)
        }
    }

    static func validateTimestamp(_ date: Date, field: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw SupplementValidationError.invalidTimestamp(field)
        }
    }

    static func validateDateOnly(_ value: String, field: String) throws {
        guard isDateOnly(value) else { throw SupplementValidationError.invalidDate(field) }
    }

    static func isDateOnly(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 45, bytes[7] == 45,
              bytes[0...3].allSatisfy({ $0 >= 48 && $0 <= 57 }),
              bytes[5...6].allSatisfy({ $0 >= 48 && $0 <= 57 }),
              bytes[8...9].allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return false }

        let year = Int(bytes[0] - 48) * 1_000 + Int(bytes[1] - 48) * 100
            + Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
        let month = Int(bytes[5] - 48) * 10 + Int(bytes[6] - 48)
        let day = Int(bytes[8] - 48) * 10 + Int(bytes[9] - 48)
        // JavaScript Date.UTC (used by the TS contract) cannot represent
        // years 0000...0099 without its special 1900 offset, so those years
        // are intentionally rejected for wire compatibility.
        guard (100...9999).contains(year), (1...12).contains(month) else { return false }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        guard let date = components.calendar?.date(from: components) else { return false }
        let calendar = components.calendar!
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == year && result.month == month && result.day == day
    }

    static func isLocalTime(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 5, bytes[2] == 58,
              bytes[0] >= 48 && bytes[0] <= 50,
              bytes[1] >= 48 && bytes[1] <= 57,
              bytes[3] >= 48 && bytes[3] <= 53,
              bytes[4] >= 48 && bytes[4] <= 57 else { return false }
        return bytes[0] != 50 || bytes[1] <= 51
    }

    static func isIANATimeZone(_ value: String) -> Bool {
        guard value.utf16.count >= 1, value.utf16.count <= 64 else { return false }
        let range = NSRange(location: 0, length: value.utf16.count)
        guard let expression = try? NSRegularExpression(
            pattern: #"^(?:UTC|[A-Za-z][A-Za-z0-9+_-]{0,31}(?:/[A-Za-z0-9+_-]{1,31})+)$"#,
            options: []
        ), expression.firstMatch(in: value, options: [], range: range) != nil else { return false }
        return !value.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    static func validateOpaqueID(_ value: String, field: String = "id") throws {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count),
              bytes[0].isASCIISupplementLetterOrDigit,
              bytes.dropFirst().allSatisfy({ $0.isASCIISupplementLetterOrDigit || $0 == 45 || $0 == 95 }) else {
            throw SupplementValidationError.unsafeIdentifier(field)
        }
    }

    static func validateText(_ value: String, field: String, max: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf16.count <= max else {
            throw SupplementValidationError.invalidText(field)
        }
    }

    static func validateRevision(_ value: Int, field: String = "revision") throws {
        guard (0...maximumRevision).contains(value) else {
            throw SupplementValidationError.invalidBounds(field)
        }
    }

    static func validateInventoryUnits(_ value: Int, field: String) throws {
        guard (0...maximumInventoryUnits).contains(value) else {
            throw SupplementValidationError.invalidBounds(field)
        }
    }
}

private extension UInt8 {
    var isASCIISupplementLetterOrDigit: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }
}

func decodeSupplementISO8601Date<Key: CodingKey>(
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>,
    field: String
) throws -> Date {
    let raw = try container.decode(String.self, forKey: key)
    return try SupplementValidation.parseISO8601(raw, field: field)
}

func decodeSupplementOptionalISO8601Date<Key: CodingKey>(
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>,
    field: String
) throws -> Date? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw DecodingError.valueNotFound(
            Date.self,
            .init(codingPath: container.codingPath + [key], debugDescription: "Explicit null is not accepted")
        )
    }
    return try decodeSupplementISO8601Date(forKey: key, from: container, field: field)
}

// This overload keeps the date fields strict even when a caller uses the
// app-wide JSONDecoder.lifeOS rather than JSONDecoder.supplement.
func decodeSupplementOptional<Key: CodingKey>(
    _ type: Date.Type,
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>
) throws -> Date? {
    try decodeSupplementOptionalISO8601Date(forKey: key, from: container, field: key.stringValue)
}

private func supplementISO8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// JSON coders for supplement payloads.  The date strategy is strict enough
/// to preserve the TS timestamp contract, including an explicit timezone.
extension JSONDecoder {
    static var supplement: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { nestedDecoder in
            let container = try nestedDecoder.singleValueContainer()
            let value = try container.decode(String.self)
            do {
                return try SupplementValidation.parseISO8601(value)
            } catch {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 supplement timestamp")
            }
        }
        return decoder
    }

    static var lifeOSSupplement: JSONDecoder { supplement }
}

extension JSONEncoder {
    static var supplement: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, nestedEncoder in
            var container = nestedEncoder.singleValueContainer()
            try container.encode(supplementISO8601String(date))
        }
        return encoder
    }

    static var lifeOSSupplement: JSONEncoder { supplement }
}

// MARK: - Supplement core models

public enum SupplementForm: String, Codable, CaseIterable, Equatable, Sendable {
    case capsule, tablet, powder, liquid, softgel, other
}

public struct SupplementSchedulePauseRange: Codable, Equatable, Sendable {
    public let startDate: String
    public let endDate: String

    private enum CodingKeys: String, CodingKey { case startDate, endDate }

    public init(startDate: String, endDate: String) throws {
        self.startDate = startDate
        self.endDate = endDate
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: ["startDate", "endDate"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startDate = try container.decode(String.self, forKey: .startDate)
        endDate = try container.decode(String.self, forKey: .endDate)
        try validate()
    }

    public func validate(now: Date = .now) throws {
        _ = now
        try SupplementValidation.validateDateOnly(startDate, field: "pauseRanges.startDate")
        try SupplementValidation.validateDateOnly(endDate, field: "pauseRanges.endDate")
        guard endDate >= startDate else {
            throw SupplementValidationError.invalidSchedule("pauseRanges.endDate")
        }
    }
}

public enum SupplementNotificationPreference: String, Codable, CaseIterable, Equatable, Sendable {
    case productAndTiming = "product_and_timing"
    case genericPrivate = "generic_private"
    case disabled
}

public struct SupplementSchedule: Codable, Equatable, Sendable {
    public let weekdays: [Int]
    public let localTime: String
    public let timeZoneIdentifier: String
    public let timingNote: String?
    public let startDate: String
    public let endDate: String?
    public let pauseRanges: [SupplementSchedulePauseRange]
    public let notificationPreference: SupplementNotificationPreference
    public let calendarOverlayEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case weekdays, localTime, timeZoneIdentifier, timingNote, startDate, endDate,
             pauseRanges, notificationPreference, calendarOverlayEnabled
    }

    public init(
        weekdays: [Int],
        localTime: String,
        timeZoneIdentifier: String,
        timingNote: String? = nil,
        startDate: String,
        endDate: String? = nil,
        pauseRanges: [SupplementSchedulePauseRange],
        notificationPreference: SupplementNotificationPreference,
        calendarOverlayEnabled: Bool
    ) throws {
        self.weekdays = weekdays
        self.localTime = localTime
        self.timeZoneIdentifier = timeZoneIdentifier
        self.timingNote = timingNote
        self.startDate = startDate
        self.endDate = endDate
        self.pauseRanges = pauseRanges
        self.notificationPreference = notificationPreference
        self.calendarOverlayEnabled = calendarOverlayEnabled
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "weekdays", "localTime", "timeZoneIdentifier", "timingNote", "startDate", "endDate",
            "pauseRanges", "notificationPreference", "calendarOverlayEnabled"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekdays = try container.decode([Int].self, forKey: .weekdays)
        localTime = try container.decode(String.self, forKey: .localTime)
        timeZoneIdentifier = try container.decode(String.self, forKey: .timeZoneIdentifier)
        timingNote = try decodeSupplementOptional(String.self, forKey: .timingNote, from: container)
        startDate = try container.decode(String.self, forKey: .startDate)
        endDate = try decodeSupplementOptional(String.self, forKey: .endDate, from: container)
        pauseRanges = try container.decode([SupplementSchedulePauseRange].self, forKey: .pauseRanges)
        notificationPreference = try container.decode(SupplementNotificationPreference.self, forKey: .notificationPreference)
        calendarOverlayEnabled = try container.decode(Bool.self, forKey: .calendarOverlayEnabled)
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public func validate(now: Date = .now) throws {
        guard (1...7).contains(weekdays.count),
              weekdays.allSatisfy({ (1...7).contains($0) }),
              Set(weekdays).count == weekdays.count else {
            throw SupplementValidationError.invalidSchedule("weekdays")
        }
        guard SupplementValidation.isLocalTime(localTime) else {
            throw SupplementValidationError.invalidSchedule("localTime")
        }
        guard SupplementValidation.isIANATimeZone(timeZoneIdentifier) else {
            throw SupplementValidationError.invalidSchedule("timeZoneIdentifier")
        }
        if let timingNote {
            try SupplementValidation.validateText(timingNote, field: "timingNote", max: 120)
        }
        try SupplementValidation.validateDateOnly(startDate, field: "startDate")
        if let endDate {
            try SupplementValidation.validateDateOnly(endDate, field: "endDate")
            guard endDate >= startDate else {
                throw SupplementValidationError.invalidSchedule("endDate")
            }
        }
        guard pauseRanges.count <= 64 else {
            throw SupplementValidationError.invalidBounds("pauseRanges")
        }
        let sortedPauses = pauseRanges.sorted { $0.startDate < $1.startDate }
        for (index, pause) in sortedPauses.enumerated() {
            try pause.validate(now: now)
            guard pause.startDate >= startDate else {
                throw SupplementValidationError.invalidSchedule("pauseRanges[\(index)].startDate")
            }
            if let endDate {
                guard pause.endDate <= endDate else {
                    throw SupplementValidationError.invalidSchedule("pauseRanges[\(index)].endDate")
                }
            }
            if index > 0 {
                let previous = sortedPauses[index - 1]
                guard pause.startDate > previous.endDate else {
                    throw SupplementValidationError.invalidSchedule("pauseRanges[\(index)].startDate")
                }
            }
        }
    }
}

public struct SupplementDose: Codable, Equatable, Sendable {
    public let amount: Double
    public let unit: String

    private enum CodingKeys: String, CodingKey { case amount, unit }

    public init(amount: Double, unit: String) throws {
        self.amount = amount
        self.unit = unit
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: ["amount", "unit"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decode(Double.self, forKey: .amount)
        unit = try container.decode(String.self, forKey: .unit)
        try validate()
    }

    public func validate(now: Date = .now) throws {
        _ = now
        guard amount.isFinite, amount > 0, amount <= 1_000_000,
              (amount * 1_000).isFinite,
              (amount * 1_000).rounded() == amount * 1_000 else {
            throw SupplementValidationError.invalidBounds("dose.amount")
        }
        try SupplementValidation.validateText(unit, field: "dose.unit", max: 32)
    }
}

/// A user- or label-supplied nutrient fact normalized to one product unit.
/// `labelBasisUnits` preserves the label's daily-dose basis separately, e.g.
/// 800 mg calcium per 2 tablets becomes 400 mg per tablet with basis 2.
/// This is a tracking fact, never a dose recommendation.
public struct SupplementNutrientFact: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let nutrientID: String
    public let name: String
    public let amountPerUnit: Double
    public let unit: String
    public let labelBasisUnits: Int?
    public let nrvPercent: Double?

    public var id: String { nutrientID }

    private enum CodingKeys: String, CodingKey {
        case nutrientID, name, amountPerUnit, unit, labelBasisUnits, nrvPercent
    }

    public init(
        nutrientID: String,
        name: String,
        amountPerUnit: Double,
        unit: String,
        labelBasisUnits: Int? = nil,
        nrvPercent: Double? = nil
    ) throws {
        self.nutrientID = nutrientID
        self.name = name
        self.amountPerUnit = amountPerUnit
        self.unit = unit
        self.labelBasisUnits = labelBasisUnits
        self.nrvPercent = nrvPercent
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "nutrientID", "name", "amountPerUnit", "unit", "labelBasisUnits", "nrvPercent"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nutrientID = try container.decode(String.self, forKey: .nutrientID)
        name = try container.decode(String.self, forKey: .name)
        amountPerUnit = try container.decode(Double.self, forKey: .amountPerUnit)
        unit = try container.decode(String.self, forKey: .unit)
        labelBasisUnits = try decodeSupplementOptional(Int.self, forKey: .labelBasisUnits, from: container)
        nrvPercent = try decodeSupplementOptional(Double.self, forKey: .nrvPercent, from: container)
        try validate()
    }

    public func validate(now: Date = .now) throws {
        _ = now
        try SupplementValidation.validateOpaqueID(nutrientID, field: "nutrientID")
        try SupplementValidation.validateText(name, field: "nutrient.name", max: 120)
        guard amountPerUnit.isFinite, amountPerUnit > 0, amountPerUnit <= 1_000_000 else {
            throw SupplementValidationError.invalidBounds("nutrient.amountPerUnit")
        }
        guard ["g", "mg", "µg", "mcg", "ml", "IU", "kcal"].contains(unit) else {
            throw SupplementValidationError.invalidText("nutrient.unit")
        }
        if let labelBasisUnits {
            guard (1...1_000_000).contains(labelBasisUnits) else {
                throw SupplementValidationError.invalidBounds("nutrient.labelBasisUnits")
            }
        }
        if let nrvPercent {
            guard nrvPercent.isFinite, (0...10_000).contains(nrvPercent) else {
                throw SupplementValidationError.invalidBounds("nutrient.nrvPercent")
            }
        }
    }
}

public enum SupplementSource: String, Codable, CaseIterable, Equatable, Sendable {
    case manual
    case packageLabel = "package_label"
    case imported
}

public struct SupplementProductLabelNote: Codable, Equatable, Sendable {
    public let text: String
    public let sourceDate: String

    private enum CodingKeys: String, CodingKey { case text, sourceDate }

    public init(text: String, sourceDate: String) throws {
        self.text = text
        self.sourceDate = sourceDate
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: ["text", "sourceDate"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        sourceDate = try container.decode(String.self, forKey: .sourceDate)
        try validate()
    }

    public func validate(now: Date = .now) throws {
        _ = now
        try SupplementValidation.validateText(text, field: "productLabelNote.text", max: 1_000)
        try SupplementValidation.validateDateOnly(sourceDate, field: "productLabelNote.sourceDate")
    }
}

/// Reference-only result from the Windows catalog. The catalog is searchable
/// convenience data; selecting a row still requires the user to confirm what
/// belongs to their own product before it becomes a local plan.
public struct SupplementCatalogEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let brand: String
    public let productIdentifier: String?
    public let form: SupplementForm
    public let servingUnit: String
    public let source: SupplementSource
    public let sourceDate: String
    public let nutrients: [SupplementNutrientFact]

    private enum CodingKeys: String, CodingKey {
        case id, name, brand, productIdentifier, form, servingUnit, source, sourceDate, nutrients
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "id", "name", "brand", "productIdentifier", "form", "servingUnit", "source", "sourceDate", "nutrients"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        brand = try container.decode(String.self, forKey: .brand)
        productIdentifier = try decodeSupplementOptional(String.self, forKey: .productIdentifier, from: container)
        form = try container.decode(SupplementForm.self, forKey: .form)
        servingUnit = try container.decode(String.self, forKey: .servingUnit)
        source = try container.decode(SupplementSource.self, forKey: .source)
        sourceDate = try container.decode(String.self, forKey: .sourceDate)
        nutrients = try container.decode([SupplementNutrientFact].self, forKey: .nutrients)
        try validate()
    }

    public func validate(now: Date = .now) throws {
        _ = now
        try SupplementValidation.validateOpaqueID(id, field: "catalog.id")
        try SupplementValidation.validateText(name, field: "catalog.name", max: 160)
        try SupplementValidation.validateText(brand, field: "catalog.brand", max: 120)
        if let productIdentifier {
            try SupplementValidation.validateText(productIdentifier, field: "catalog.productIdentifier", max: 128)
        }
        try SupplementValidation.validateText(servingUnit, field: "catalog.servingUnit", max: 32)
        try SupplementValidation.validateDateOnly(sourceDate, field: "catalog.sourceDate")
        guard nutrients.count <= 64 else { throw SupplementValidationError.invalidBounds("catalog.nutrients") }
        guard Set(nutrients.map(\.nutrientID)).count == nutrients.count else {
            throw SupplementValidationError.duplicateIdentifier("catalog.nutrientID")
        }
        try nutrients.forEach { try $0.validate(now: now) }
    }
}

public struct SupplementCatalogResponse: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let query: String
    public let entries: [SupplementCatalogEntry]

    private enum CodingKeys: String, CodingKey { case schemaVersion, query, entries }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: ["schemaVersion", "query", "entries"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        query = try container.decode(String.self, forKey: .query)
        entries = try container.decode([SupplementCatalogEntry].self, forKey: .entries)
        try validate()
    }

    public func validate(now: Date = .now) throws {
        _ = now
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SupplementValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard query.utf16.count <= 120 else { throw SupplementValidationError.invalidText("catalog.query") }
        guard entries.count <= 20, Set(entries.map(\.id)).count == entries.count else {
            throw SupplementValidationError.invalidBounds("catalog.entries")
        }
        try entries.forEach { try $0.validate(now: now) }
    }
}

public struct SupplementPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let brand: String
    public let productIdentifier: String?
    public let form: SupplementForm
    public let strength: String
    public let servingUnit: String
    public let userDose: SupplementDose?
    public let nutrientFacts: [SupplementNutrientFact]
    public let inventoryUnitsPerDose: Int
    public let schedule: SupplementSchedule
    public let source: SupplementSource
    public let productLabelNote: SupplementProductLabelNote?
    public let notes: String?
    public var stockUnits: Int
    public let reorderThreshold: Int
    public let expectedLeadTimeDays: Int?
    public let expiryDate: Date?
    public let supplier: String?
    public let reminderEnabled: Bool
    public let lockScreenRedacted: Bool
    public var revision: Int
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, brand, productIdentifier, form, strength, servingUnit, userDose, nutrientFacts,
             inventoryUnitsPerDose, schedule, source, productLabelNote, notes, stockUnits,
             reorderThreshold, expectedLeadTimeDays, expiryDate, supplier, reminderEnabled,
             lockScreenRedacted, revision, updatedAt
    }

    public init(
        id: String,
        name: String,
        brand: String,
        productIdentifier: String? = nil,
        form: SupplementForm,
        strength: String,
        servingUnit: String,
        userDose: SupplementDose? = nil,
        nutrientFacts: [SupplementNutrientFact] = [],
        inventoryUnitsPerDose: Int,
        schedule: SupplementSchedule,
        source: SupplementSource,
        productLabelNote: SupplementProductLabelNote? = nil,
        notes: String? = nil,
        stockUnits: Int,
        reorderThreshold: Int,
        expectedLeadTimeDays: Int? = nil,
        expiryDate: Date? = nil,
        supplier: String? = nil,
        reminderEnabled: Bool,
        lockScreenRedacted: Bool,
        revision: Int,
        updatedAt: Date
    ) throws {
        self.id = id
        self.name = name
        self.brand = brand
        self.productIdentifier = productIdentifier
        self.form = form
        self.strength = strength
        self.servingUnit = servingUnit
        self.userDose = userDose
        self.nutrientFacts = nutrientFacts
        self.inventoryUnitsPerDose = inventoryUnitsPerDose
        self.schedule = schedule
        self.source = source
        self.productLabelNote = productLabelNote
        self.notes = notes
        self.stockUnits = stockUnits
        self.reorderThreshold = reorderThreshold
        self.expectedLeadTimeDays = expectedLeadTimeDays
        self.expiryDate = expiryDate
        self.supplier = supplier
        self.reminderEnabled = reminderEnabled
        self.lockScreenRedacted = lockScreenRedacted
        self.revision = revision
        self.updatedAt = updatedAt
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "id", "name", "brand", "productIdentifier", "form", "strength", "servingUnit", "userDose", "nutrientFacts",
            "inventoryUnitsPerDose", "schedule", "source", "productLabelNote", "notes", "stockUnits",
            "reorderThreshold", "expectedLeadTimeDays", "expiryDate", "supplier", "reminderEnabled",
            "lockScreenRedacted", "revision", "updatedAt"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        brand = try container.decode(String.self, forKey: .brand)
        productIdentifier = try decodeSupplementOptional(String.self, forKey: .productIdentifier, from: container)
        form = try container.decode(SupplementForm.self, forKey: .form)
        strength = try container.decode(String.self, forKey: .strength)
        servingUnit = try container.decode(String.self, forKey: .servingUnit)
        userDose = try decodeSupplementOptional(SupplementDose.self, forKey: .userDose, from: container)
        nutrientFacts = try decodeSupplementOptional([SupplementNutrientFact].self, forKey: .nutrientFacts, from: container) ?? []
        inventoryUnitsPerDose = try container.decode(Int.self, forKey: .inventoryUnitsPerDose)
        schedule = try container.decode(SupplementSchedule.self, forKey: .schedule)
        source = try container.decode(SupplementSource.self, forKey: .source)
        productLabelNote = try decodeSupplementOptional(SupplementProductLabelNote.self, forKey: .productLabelNote, from: container)
        notes = try decodeSupplementOptional(String.self, forKey: .notes, from: container)
        stockUnits = try container.decode(Int.self, forKey: .stockUnits)
        reorderThreshold = try container.decode(Int.self, forKey: .reorderThreshold)
        expectedLeadTimeDays = try decodeSupplementOptional(Int.self, forKey: .expectedLeadTimeDays, from: container)
        expiryDate = try decodeSupplementOptionalISO8601Date(forKey: .expiryDate, from: container, field: "expiryDate")
        supplier = try decodeSupplementOptional(String.self, forKey: .supplier, from: container)
        reminderEnabled = try container.decode(Bool.self, forKey: .reminderEnabled)
        lockScreenRedacted = try container.decode(Bool.self, forKey: .lockScreenRedacted)
        revision = try container.decode(Int.self, forKey: .revision)
        updatedAt = try decodeSupplementISO8601Date(forKey: .updatedAt, from: container, field: "updatedAt")
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public func validate(now: Date = .now) throws {
        try SupplementValidation.validateOpaqueID(id, field: "plan.id")
        try SupplementValidation.validateText(name, field: "name", max: 160)
        try SupplementValidation.validateText(brand, field: "brand", max: 120)
        if let productIdentifier {
            try SupplementValidation.validateText(productIdentifier, field: "productIdentifier", max: 128)
        }
        try SupplementValidation.validateText(strength, field: "strength", max: 80)
        try SupplementValidation.validateText(servingUnit, field: "servingUnit", max: 32)
        try userDose?.validate(now: now)
        guard nutrientFacts.count <= 64,
              Set(nutrientFacts.map(\.nutrientID)).count == nutrientFacts.count else {
            throw SupplementValidationError.duplicateIdentifier("nutrientFacts.nutrientID")
        }
        try nutrientFacts.forEach { try $0.validate(now: now) }
        guard (1...SupplementValidation.maximumInventoryUnits).contains(inventoryUnitsPerDose) else {
            throw SupplementValidationError.invalidBounds("inventoryUnitsPerDose")
        }
        try schedule.validate(now: now)
        try productLabelNote?.validate(now: now)
        if let notes {
            try SupplementValidation.validateText(notes, field: "notes", max: 1_000)
        }
        try SupplementValidation.validateInventoryUnits(stockUnits, field: "stockUnits")
        try SupplementValidation.validateInventoryUnits(reorderThreshold, field: "reorderThreshold")
        if let expectedLeadTimeDays, !(0...365).contains(expectedLeadTimeDays) {
            throw SupplementValidationError.invalidBounds("expectedLeadTimeDays")
        }
        if let expiryDate {
            try SupplementValidation.validateTimestamp(expiryDate, field: "expiryDate")
        }
        if let supplier {
            try SupplementValidation.validateText(supplier, field: "supplier", max: 160)
        }
        if schedule.notificationPreference == .disabled && reminderEnabled {
            throw SupplementValidationError.invalidSchedule("reminderEnabled")
        }
        try SupplementValidation.validateRevision(revision, field: "revision")
        try SupplementValidation.validateObserved(updatedAt, field: "updatedAt", now: now)
    }
}
