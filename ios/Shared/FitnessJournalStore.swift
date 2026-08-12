import Combine
import Foundation

/// The small, local-first record used by the Fitness Journal surface. It is
/// intentionally independent from HealthKit and does not contain any sensor
/// formulas. Automatic rows are accepted only when an importer supplies an
/// explicit observed/derived value and provenance.
public struct FitnessJournalRecord: Codable, Equatable, Hashable, Identifiable {
    public enum Section: String, Codable, CaseIterable, Sendable {
        case pinned
        case day
        case night
        case automatic
    }

    public enum Source: String, Codable, Sendable {
        case manual
        case healthKit
        case derived
        case inferred
        case unavailable
        case demo

        public var label: String {
            switch self {
            case .manual: "Manual"
            case .healthKit: "HealthKit"
            case .derived: "Derived"
            case .inferred: "Inferred"
            case .unavailable: "Not connected"
            case .demo: "Demo fixture"
            }
        }
    }

    public enum TagState: String, Codable, CaseIterable, Sendable {
        case yes
        case no
        case unknown

        public var label: String {
            switch self {
            case .yes: "Yes"
            case .no: "No"
            case .unknown: "Unknown"
            }
        }
    }

    public let id: String
    public var title: String
    public var emoji: String
    public var section: Section
    public var date: Date
    public var source: Source
    public var provenance: String
    public var tagState: TagState
    public var quantity: Double?
    public var unit: String?
    /// A value supplied by a reviewed importer or explicit visual fixture.
    /// This is display-only: the journal never derives or recalculates it.
    public var observedValue: String?
    /// Named source window supplied by the importer/fixture (for example,
    /// "selected day" or "overnight sample"). It is never inferred here.
    public var window: String?
    /// The original user-entered quantity text. Keeping this alongside the
    /// numeric value lets the durable boundary reject exponent notation or a
    /// malformed comma before it can be normalized into a plausible number.
    public var quantityInput: String?
    public var editable: Bool

    public init(
        id: String,
        title: String,
        emoji: String,
        section: Section,
        date: Date,
        source: Source = .manual,
        provenance: String = "Local journal entry",
        tagState: TagState = .unknown,
        quantity: Double? = nil,
        unit: String? = nil,
        observedValue: String? = nil,
        window: String? = nil,
        quantityInput: String? = nil,
        editable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.section = section
        self.date = date
        self.source = source
        self.provenance = provenance
        self.tagState = tagState
        self.quantity = quantity
        self.unit = unit
        self.observedValue = observedValue
        self.window = window
        self.quantityInput = quantityInput
        self.editable = editable
    }

    public var isAutomaticObservation: Bool { section == .automatic }
    public var hasUserValue: Bool {
        quantity != nil || tagState != .unknown || observedValue != nil
    }

    public var hasManualInput: Bool {
        quantity != nil || tagState != .unknown
    }
}

/// The display-only fixture path is explicit and cannot be enabled merely by
/// passing demo records to a durable store.
public enum FitnessJournalFixturePolicy {
    public static func isFixtureMode(usesVisualFixtures: Bool, sourceIsDemo: Bool) -> Bool {
        usesVisualFixtures || sourceIsDemo
    }
}

/// Calendar math for the Journal selector. The visible month may move into
/// history, but it never advances beyond the current month and future days
/// cannot be selected. Keeping this separate from SwiftUI makes the boundary
/// deterministic and keeps importer-only observations out of completion.
struct FitnessJournalCalendarModel {
    let calendar: Calendar
    let today: Date

    init(calendar: Calendar = .current, today: Date = Date()) {
        var calendar = calendar
        calendar.firstWeekday = 2 // Monday, matching the Journal week labels.
        self.calendar = calendar
        self.today = calendar.startOfDay(for: today)
    }

    var currentMonth: Date { monthStart(for: today) }

    func monthStart(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            ?? calendar.startOfDay(for: date)
    }

    func month(byAdding value: Int, to date: Date) -> Date {
        let start = monthStart(for: date)
        return calendar.date(byAdding: .month, value: value, to: start) ?? start
    }

    func canMoveMonth(from visibleMonth: Date, by value: Int) -> Bool {
        guard value != 0 else { return true }
        let target = month(byAdding: value, to: visibleMonth)
        return value < 0 || target <= currentMonth
    }

    func isSelectable(_ date: Date) -> Bool {
        calendar.startOfDay(for: date) <= today
    }

    /// Returns Monday-first cells, with empty leading/trailing slots so the
    /// grid remains stable at any month length.
    func cells(in month: Date) -> [Date?] {
        let start = monthStart(for: month)
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var cells = Array<Date?>(repeating: nil, count: leading)
        cells.append(contentsOf: (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
        })
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}

/// iOS journal JSON gets the strongest file protection available to the app;
/// macOS keeps the same atomic write semantics without importing an iOS-only
/// protection option.
public enum FitnessJournalStorageProtection {
    public static var writeOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtection]
#else
        [.atomic]
#endif
    }

    public static var label: String {
#if os(iOS)
        "Complete file protection"
#else
        "Atomic local file"
#endif
    }
}

/// Shared validation for manual hydration/caffeine/alcohol quantities. Values
/// are deliberately bounded and limited to two decimal places; the UI may
/// accept a comma decimal, but exponent syntax and locale grouping are not
/// accepted. The upper bound is a conservative 100,000 units per entry.
public enum FitnessJournalQuantity {
    public static let maximumValue: Double = 100_000
    public static let maximumFractionDigits = 2

    public static func parse(_ input: String) -> Double? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("e"), !text.contains("E") else { return nil }

        let separators = text.filter { $0 == "," || $0 == "." }
        guard separators.count <= 1 else { return nil }
        let decimalSeparator = separators.first
        let parts = decimalSeparator.map { text.split(separator: $0, omittingEmptySubsequences: false) } ?? [Substring(text)]
        guard parts.count <= 2 else { return nil }
        let integerPart = String(parts[0])
        let fractionPart = parts.count == 2 ? String(parts[1]) : ""
        guard !integerPart.isEmpty || !fractionPart.isEmpty else { return nil }
        if decimalSeparator != nil { guard parts.count == 2, !fractionPart.isEmpty else { return nil } }
        guard integerPart.allSatisfy(\.isNumber), fractionPart.allSatisfy(\.isNumber) else { return nil }
        guard fractionPart.count <= maximumFractionDigits else { return nil }

        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value >= 0, value <= maximumValue else { return nil }
        return value
    }

    public static func isValid(value: Double?, input: String?, unit: String?) -> Bool {
        guard let value else {
            return input?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        guard value.isFinite, value >= 0, value <= maximumValue, unit?.isEmpty == false else { return false }
        let rounded = (value * 100).rounded() / 100
        guard abs(rounded - value) < 0.0000001 else { return false }
        if let input {
            guard let parsed = parse(input), abs(parsed - value) < 0.0000001 else { return false }
        }
        return true
    }
}

/// A deliberately tiny persistence boundary keeps this tranche testable and
/// avoids introducing a second database. Pass `nil` for an in-memory store.
public final class FitnessJournalStore: ObservableObject {
    @Published public private(set) var records: [FitnessJournalRecord]
    @Published public private(set) var lastSaveError: String?
    @Published public private(set) var integrityWarning: String?

    private let persistenceURL: URL?
    private let calendar: Calendar
    private let fixtureOnly: Bool

    public init(
        initialRecords: [FitnessJournalRecord] = [],
        persistenceURL: URL? = FitnessJournalStore.defaultPersistenceURL,
        calendar: Calendar = .current,
        fixtureOnly: Bool = false
    ) {
        self.persistenceURL = persistenceURL
        self.calendar = calendar
        // Fixture relaxation is valid only for an explicitly nonpersistent
        // display store. A file URL always means durable/production rules.
        self.fixtureOnly = fixtureOnly && persistenceURL == nil
        self.lastSaveError = nil
        self.integrityWarning = nil
        var sourceRecords = initialRecords
        var storageCorruptionWarning: String?
        if let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) {
            do {
                let data = try Data(contentsOf: persistenceURL)
                sourceRecords = try JSONDecoder().decode([FitnessJournalRecord].self, from: data)
            } catch {
                storageCorruptionWarning = "Journal storage could not be read; showing the last valid local records."
            }
        }
        self.records = []
        self.records = validatedRecords(sourceRecords)
        if let storageCorruptionWarning { self.integrityWarning = storageCorruptionWarning }
    }

    public static var defaultPersistenceURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("fitness-journal.json")
    }

    public func records(on date: Date, includingAutomatic: Bool = true) -> [FitnessJournalRecord] {
        records.filter { record in
            calendar.isDate(record.date, inSameDayAs: date) && (includingAutomatic || !record.isAutomaticObservation)
        }.sorted(by: Self.sortRecords)
    }

    public func record(id: String) -> FitnessJournalRecord? {
        records.first { $0.id == id }
    }

    @discardableResult
    public func upsert(_ record: FitnessJournalRecord) -> Bool {
        guard validate(record) else {
            lastSaveError = "Journal entry is not valid for local storage."
            return false
        }
        let previous = records
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort(by: Self.sortRecords)
        guard persist() else {
            records = previous
            return false
        }
        return true
    }

    @discardableResult
    public func delete(id: String) -> Bool {
        let previous = records
        records.removeAll { $0.id == id }
        guard persist() else {
            records = previous
            return false
        }
        return true
    }

    @discardableResult
    public func setTagState(_ state: FitnessJournalRecord.TagState, for id: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].editable else { return false }
        let previous = records
        records[index].tagState = state
        guard persist() else {
            records = previous
            return false
        }
        return true
    }

    public func hasEntries(on date: Date) -> Bool {
        records(on: date, includingAutomatic: false).contains {
            $0.source == .manual && $0.hasManualInput
        }
    }

    public func reload() {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoded = try JSONDecoder().decode([FitnessJournalRecord].self, from: data)
            records = validatedRecords(decoded)
        } catch {
            integrityWarning = "Journal storage could not be read; showing the last valid local records."
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let persistenceURL else {
            lastSaveError = nil
            return true
        }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: persistenceURL, options: FitnessJournalStorageProtection.writeOptions)
            lastSaveError = nil
            return true
        } catch {
            // Keep the last durable state visible when persistence fails. A
            // caller can show this error and retry after the path is fixed.
            lastSaveError = "Journal could not be saved locally."
            return false
        }
    }

    private func validatedRecords(_ candidates: [FitnessJournalRecord]) -> [FitnessJournalRecord] {
        var invalidCount = 0
        let valid = candidates.filter { record in
            guard validate(record) else {
                invalidCount += 1
                return false
            }
            return true
        }
        if invalidCount > 0 {
            integrityWarning = "\(invalidCount) journal record\(invalidCount == 1 ? "" : "s") were unavailable because their source, window, or value was invalid."
        } else {
            integrityWarning = nil
        }
        return valid.sorted(by: Self.sortRecords)
    }

    private func validate(_ record: FitnessJournalRecord) -> Bool {
        guard FitnessJournalQuantity.isValid(value: record.quantity, input: record.quantityInput, unit: record.unit) else { return false }
        if record.isAutomaticObservation {
            let provenance = record.provenance.trimmingCharacters(in: .whitespacesAndNewlines)
            let window = record.window?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let observed = record.observedValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !provenance.isEmpty, !window.isEmpty, !record.editable else { return false }
            if fixtureOnly, record.source == .unavailable {
                return observed.isEmpty
            }
            guard record.source == .healthKit || record.source == .derived else { return false }
            return !observed.isEmpty
        }
        if record.source == .manual {
            let observed = record.observedValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let window = record.window?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard observed.isEmpty, window.isEmpty else { return false }
        }
        guard record.source != .demo, record.source != .unavailable else { return fixtureOnly }
        return true
    }

    private static func sortRecords(_ lhs: FitnessJournalRecord, _ rhs: FitnessJournalRecord) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id < rhs.id
    }
}
