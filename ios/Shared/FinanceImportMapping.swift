import CryptoKit
import Foundation

// MARK: - Explicit CSV mapping contract

/// Errors from the explicit mapping boundary. Cases are intentionally
/// content-free so they can be shown in diagnostics without retaining source
/// fields or account values.
public enum FinanceImportMappingError: Error, Equatable, Sendable {
    case invalidMapping
    case missingHeader
    case unsupportedProfile
    case mappingNotRequired
    case stalePreview
    case cancelled
    case invalidRow
    case invalidDate
    case invalidAmount
    case invalidCurrency
    case invalidAccount
    case ambiguousValue
    case duplicateColumn
    case outOfRangeColumn
    case metadataTooLarge
}

public enum FinanceImportDateFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case yearMonthDay = "yyyy-MM-dd"
    case dayMonthYearDot = "dd.MM.yyyy"
    case dayMonthYearSlash = "dd/MM/yyyy"
    case monthDayYearSlash = "MM/dd/yyyy"

    /// Strict date-only parsing. It consumes the entire string, constructs a
    /// Gregorian date in UTC, and round-trips its components before accepting
    /// the value. No DateFormatter leniency or locale inference is involved.
    public func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators: [Character]
        switch self {
        case .yearMonthDay: separators = ["-"]
        case .dayMonthYearDot: separators = ["."]
        case .dayMonthYearSlash, .monthDayYearSlash: separators = ["/"]
        }
        guard value.count == 10 else { return nil }
        let parts = value.split(separator: separators[0], omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        let yearPart: Substring
        let monthPart: Substring
        let dayPart: Substring
        switch self {
        case .yearMonthDay:
            guard parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return nil }
            yearPart = parts[0]; monthPart = parts[1]; dayPart = parts[2]
        case .dayMonthYearDot, .dayMonthYearSlash:
            guard parts[0].count == 2, parts[1].count == 2, parts[2].count == 4 else { return nil }
            yearPart = parts[2]; monthPart = parts[1]; dayPart = parts[0]
        case .monthDayYearSlash:
            guard parts[0].count == 2, parts[1].count == 2, parts[2].count == 4 else { return nil }
            yearPart = parts[2]; monthPart = parts[0]; dayPart = parts[1]
        }

        guard [yearPart, monthPart, dayPart].allSatisfy({ $0.allSatisfy { $0.isNumber && $0.isASCII } }),
              let year = Int(yearPart), let month = Int(monthPart), let day = Int(dayPart),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return date
    }
}

public enum FinanceImportDecimalSeparator: String, Codable, CaseIterable, Equatable, Sendable {
    case dot = "."
    case comma = ","

    var character: Character { Character(rawValue) }
}

public enum FinanceImportGroupingSeparator: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case dot = "."
    case comma = ","
    case space = " "
    case nonBreakingSpace = "\u{00A0}"
    case narrowNonBreakingSpace = "\u{202F}"

    var character: Character? {
        switch self {
        case .none: return nil
        default: return Character(rawValue)
        }
    }
}

public struct FinanceImportAmountFormat: Codable, Equatable, Sendable {
    public let decimalSeparator: FinanceImportDecimalSeparator
    public let groupingSeparator: FinanceImportGroupingSeparator

    public init(
        decimalSeparator: FinanceImportDecimalSeparator = .dot,
        groupingSeparator: FinanceImportGroupingSeparator = .none
    ) {
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case decimalSeparator, groupingSeparator }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requiredKeys: Set<CodingKeys> = [.decimalSeparator, .groupingSeparator]
        guard requiredKeys.isSubset(of: Set(container.allKeys)),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceImportMappingError.invalidMapping
        }
        let decimalSeparator = try container.decode(FinanceImportDecimalSeparator.self, forKey: .decimalSeparator)
        let groupingSeparator = try container.decode(FinanceImportGroupingSeparator.self, forKey: .groupingSeparator)
        guard decimalSeparator.rawValue != groupingSeparator.rawValue || groupingSeparator == .none else {
            throw FinanceImportMappingError.invalidMapping
        }
        self.init(decimalSeparator: decimalSeparator, groupingSeparator: groupingSeparator)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decimalSeparator, forKey: .decimalSeparator)
        try container.encode(groupingSeparator, forKey: .groupingSeparator)
    }
}

public enum FinanceImportSignConvention: String, Codable, CaseIterable, Equatable, Sendable {
    case signed
    case debitCredit
}

/// Direction selected by the user when an export has separate debit and
/// credit columns. The default preserves the conventional bank meaning:
/// debit is an outflow and credit is an inflow.
public enum FinanceImportDebitCreditConvention: String, Codable, CaseIterable, Equatable, Sendable {
    case debitIsNegative
    case creditIsNegative
}

public enum FinanceImportCurrencySelection: Codable, Equatable, Sendable {
    case column(index: Int)
    case constantEUR

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, index }
    private enum Kind: String, Codable { case column, constantEUR }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .column(let index):
            try container.encode(Kind.column, forKey: .kind)
            try container.encode(index, forKey: .index)
        case .constantEUR:
            try container.encode(Kind.constantEUR, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys).contains(.kind), Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceImportMappingError.invalidMapping
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .column:
            self = .column(index: try container.decode(Int.self, forKey: .index))
        case .constantEUR:
            guard !container.contains(.index) else { throw FinanceImportMappingError.invalidMapping }
            self = .constantEUR
        }
    }
}

public struct FinanceImportAccountIdentity: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    /// A private local label. It is persisted only as mapping configuration;
    /// batch diagnostics never copy it.
    public let label: String

    public init(id: UUID = UUID(), label: String) throws {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 128 else {
            throw FinanceImportMappingError.invalidAccount
        }
        self.id = id
        self.label = cleaned
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, label }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceImportMappingError.invalidAccount
        }
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            label: container.decode(String.self, forKey: .label)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
    }
}

public struct FinanceImportAccountSelection: Codable, Equatable, Sendable {
    public let identity: FinanceImportAccountIdentity
    /// When present, the mapped source column must be non-blank on every
    /// imported row. The value itself never enters provenance.
    public let sourceColumn: Int?

    public init(identity: FinanceImportAccountIdentity, sourceColumn: Int? = nil) {
        self.identity = identity
        self.sourceColumn = sourceColumn
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case identity, sourceColumn }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requiredKeys = Set([CodingKeys.identity])
        guard requiredKeys.isSubset(of: Set(container.allKeys)),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceImportMappingError.invalidMapping
        }
        let sourceColumn = try decodeStrictOptional(Int.self, forKey: .sourceColumn, from: container)
        guard sourceColumn.map({ $0 >= 0 }) ?? true else {
            throw FinanceImportMappingError.outOfRangeColumn
        }
        self.identity = try container.decode(FinanceImportAccountIdentity.self, forKey: .identity)
        self.sourceColumn = sourceColumn
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        if let sourceColumn {
            try container.encode(sourceColumn, forKey: .sourceColumn)
        }
    }
}

public struct FinanceImportAmountSelection: Codable, Equatable, Sendable {
    public let signConvention: FinanceImportSignConvention
    public let amountColumn: Int?
    public let debitColumn: Int?
    public let creditColumn: Int?
    public let debitCreditConvention: FinanceImportDebitCreditConvention
    public let format: FinanceImportAmountFormat

    public static func signed(
        column: Int,
        format: FinanceImportAmountFormat = .init()
    ) -> Self {
        Self(signConvention: .signed, amountColumn: column, debitColumn: nil, creditColumn: nil,
             debitCreditConvention: .debitIsNegative, format: format)
    }

    public static func debitCredit(
        debitColumn: Int,
        creditColumn: Int,
        convention: FinanceImportDebitCreditConvention = .debitIsNegative,
        format: FinanceImportAmountFormat = .init()
    ) -> Self {
        Self(signConvention: .debitCredit, amountColumn: nil, debitColumn: debitColumn, creditColumn: creditColumn,
             debitCreditConvention: convention, format: format)
    }

    public init(
        signConvention: FinanceImportSignConvention,
        amountColumn: Int?,
        debitColumn: Int?,
        creditColumn: Int?,
        debitCreditConvention: FinanceImportDebitCreditConvention = .debitIsNegative,
        format: FinanceImportAmountFormat
    ) {
        self.signConvention = signConvention
        self.amountColumn = amountColumn
        self.debitColumn = debitColumn
        self.creditColumn = creditColumn
        self.debitCreditConvention = debitCreditConvention
        self.format = format
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case signConvention, amountColumn, debitColumn, creditColumn
        case debitCreditConvention, format
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requiredKeys = Set([CodingKeys.signConvention, .format])
        guard requiredKeys.isSubset(of: Set(container.allKeys)),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceImportMappingError.invalidMapping
        }
        let signConvention = try container.decode(FinanceImportSignConvention.self, forKey: .signConvention)
        let amountColumn = try decodeStrictOptional(Int.self, forKey: .amountColumn, from: container)
        let debitColumn = try decodeStrictOptional(Int.self, forKey: .debitColumn, from: container)
        let creditColumn = try decodeStrictOptional(Int.self, forKey: .creditColumn, from: container)
        let debitCreditConvention = try container.decodeIfPresent(
            FinanceImportDebitCreditConvention.self,
            forKey: .debitCreditConvention
        ) ?? .debitIsNegative
        guard [amountColumn, debitColumn, creditColumn].compactMap({ value -> Int? in value }).allSatisfy({ $0 >= 0 }) else {
            throw FinanceImportMappingError.outOfRangeColumn
        }
        switch signConvention {
        case .signed:
            guard amountColumn != nil, debitColumn == nil, creditColumn == nil,
                  debitCreditConvention == .debitIsNegative else {
                throw FinanceImportMappingError.invalidMapping
            }
        case .debitCredit:
            guard amountColumn == nil, let debitColumn, let creditColumn, debitColumn != creditColumn else {
                throw FinanceImportMappingError.invalidMapping
            }
        }
        self.init(
            signConvention: signConvention,
            amountColumn: amountColumn,
            debitColumn: debitColumn,
            creditColumn: creditColumn,
            debitCreditConvention: debitCreditConvention,
            format: try container.decode(FinanceImportAmountFormat.self, forKey: .format)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signConvention, forKey: .signConvention)
        if let amountColumn {
            try container.encode(amountColumn, forKey: .amountColumn)
        }
        if let debitColumn {
            try container.encode(debitColumn, forKey: .debitColumn)
        }
        if let creditColumn {
            try container.encode(creditColumn, forKey: .creditColumn)
        }
        try container.encode(debitCreditConvention, forKey: .debitCreditConvention)
        try container.encode(format, forKey: .format)
    }
}

public enum FinanceImportDescriptionSelection: Codable, Equatable, Sendable {
    case column(index: Int)
    case none

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, index }
    private enum Kind: String, Codable { case column, none }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .column(let index):
            try container.encode(Kind.column, forKey: .kind)
            try container.encode(index, forKey: .index)
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.kind) else { throw FinanceImportMappingError.invalidMapping }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .column:
            self = .column(index: try container.decode(Int.self, forKey: .index))
        case .none:
            guard !container.contains(.index) else { throw FinanceImportMappingError.invalidMapping }
            self = .none
        }
    }
}

/// A user-editable, incomplete mapping. It is not accepted by the importer
/// until `FinanceImportMapping` validates every required choice.
public struct FinanceImportMappingDraft: Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var delimiter: FinanceCSVDelimiter?
    /// Zero-based record index in the bounded CSV record sequence.
    public var headerRecordIndex: Int?
    public var dateColumn: Int?
    public var dateFormat: FinanceImportDateFormat?
    public var amount: FinanceImportAmountSelection?
    public var currency: FinanceImportCurrencySelection?
    public var account: FinanceImportAccountSelection?
    public var description: FinanceImportDescriptionSelection?
    public var providerIDColumn: Int?
    public var merchantColumn: Int?

    public init(
        delimiter: FinanceCSVDelimiter? = nil,
        headerRecordIndex: Int? = nil,
        dateColumn: Int? = nil,
        dateFormat: FinanceImportDateFormat? = nil,
        amount: FinanceImportAmountSelection? = nil,
        currency: FinanceImportCurrencySelection? = nil,
        account: FinanceImportAccountSelection? = nil,
        description: FinanceImportDescriptionSelection? = nil,
        providerIDColumn: Int? = nil,
        merchantColumn: Int? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.delimiter = delimiter
        self.headerRecordIndex = headerRecordIndex
        self.dateColumn = dateColumn
        self.dateFormat = dateFormat
        self.amount = amount
        self.currency = currency
        self.account = account
        self.description = description
        self.providerIDColumn = providerIDColumn
        self.merchantColumn = merchantColumn
    }
}

/// The deterministic UUID input used by a reviewed mapping. This marker is
/// deliberately independent from the mapping schema: the mapping fields can
/// remain backward-compatible while the identity algorithm changes.
public enum FinanceImportIdentityScheme: String, Codable, Equatable, Sendable {
    case legacyV2 = "mapped-v2"
    case mappedV3 = "mapped-v3"
}

/// A validated mapping bound to the ordered normalized header fingerprint it
/// was reviewed against. It may be reused only when that fingerprint matches.
public struct FinanceImportMapping: Codable, Equatable, Identifiable, Sendable {
    public static let schemaVersion = 1
    internal static let maximumColumnCount = 512
    internal static let maximumHeaderRecordIndex = FinanceStatementImporter.maximumInputBytes

    public let id: UUID
    public let schemaVersion: Int
    public let delimiter: FinanceCSVDelimiter
    public let headerRecordIndex: Int
    public let headerFingerprint: String
    public let columnCount: Int
    /// Mappings written before the identity marker existed decode as
    /// `legacyV2`. The store can then reject or explicitly reconcile them
    /// instead of treating them as current mappings and duplicating rows.
    public let identityScheme: FinanceImportIdentityScheme
    public let dateColumn: Int
    public let dateFormat: FinanceImportDateFormat
    public let amount: FinanceImportAmountSelection
    public let currency: FinanceImportCurrencySelection
    public let account: FinanceImportAccountSelection
    public let description: FinanceImportDescriptionSelection
    public let providerIDColumn: Int?
    public let merchantColumn: Int?

    public init(
        id: UUID = UUID(),
        draft: FinanceImportMappingDraft,
        headerColumns: [String]
    ) throws {
        guard draft.schemaVersion == Self.schemaVersion,
              let delimiter = draft.delimiter,
              let headerRecordIndex = draft.headerRecordIndex,
              headerRecordIndex >= 0,
              headerRecordIndex <= FinanceImportMapping.maximumHeaderRecordIndex,
              !headerColumns.isEmpty,
              let dateColumn = draft.dateColumn,
              let dateFormat = draft.dateFormat,
              let amount = draft.amount,
              let currency = draft.currency,
              let account = draft.account,
              let description = draft.description else {
            throw FinanceImportMappingError.invalidMapping
        }
        let columnCount = headerColumns.count
        guard headerRecordIndex >= 0,
              headerRecordIndex <= Self.maximumHeaderRecordIndex,
              columnCount > 0,
              columnCount <= Self.maximumColumnCount,
              Self.allColumns([dateColumn], within: columnCount),
              Self.validAmountColumns(amount, within: columnCount),
              Self.validCurrencyColumns(currency, within: columnCount),
              Self.validAccountColumns(account, within: columnCount),
              Self.validDescriptionColumns(description, within: columnCount),
              Self.allColumns([draft.providerIDColumn, draft.merchantColumn].compactMap { value -> Int? in value }, within: columnCount) else {
            throw FinanceImportMappingError.outOfRangeColumn
        }

        var used = [dateColumn]
        used.append(contentsOf: Self.amountColumns(amount))
        used.append(contentsOf: Self.currencyColumns(currency))
        used.append(contentsOf: account.sourceColumn.map { [$0] } ?? [])
        used.append(contentsOf: Self.descriptionColumns(description))
        used.append(contentsOf: [draft.providerIDColumn, draft.merchantColumn].compactMap { value -> Int? in value })
        guard Set(used).count == used.count else { throw FinanceImportMappingError.duplicateColumn }
        if case .column(let index) = currency, index == dateColumn { throw FinanceImportMappingError.duplicateColumn }
        guard amount.format.decimalSeparator != .dot || amount.format.groupingSeparator != .dot,
              amount.format.decimalSeparator != .comma || amount.format.groupingSeparator != .comma else {
            throw FinanceImportMappingError.invalidMapping
        }

        self.id = id
        self.schemaVersion = Self.schemaVersion
        self.delimiter = delimiter
        self.headerRecordIndex = headerRecordIndex
        self.headerFingerprint = FinanceImportFingerprint.header(headerColumns)
        self.columnCount = columnCount
        self.identityScheme = .mappedV3
        self.dateColumn = dateColumn
        self.dateFormat = dateFormat
        self.amount = amount
        self.currency = currency
        self.account = account
        self.description = description
        self.providerIDColumn = draft.providerIDColumn
        self.merchantColumn = draft.merchantColumn
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, schemaVersion, delimiter, headerRecordIndex, headerFingerprint, columnCount
        case identityScheme
        case dateColumn, dateFormat, amount, currency, account, description
        case providerIDColumn, merchantColumn
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(delimiter, forKey: .delimiter)
        try container.encode(headerRecordIndex, forKey: .headerRecordIndex)
        try container.encode(headerFingerprint, forKey: .headerFingerprint)
        try container.encode(columnCount, forKey: .columnCount)
        try container.encode(identityScheme, forKey: .identityScheme)
        try container.encode(dateColumn, forKey: .dateColumn)
        try container.encode(dateFormat, forKey: .dateFormat)
        try container.encode(amount, forKey: .amount)
        try container.encode(currency, forKey: .currency)
        try container.encode(account, forKey: .account)
        try container.encode(description, forKey: .description)
        if let providerIDColumn {
            try container.encode(providerIDColumn, forKey: .providerIDColumn)
        }
        if let merchantColumn {
            try container.encode(merchantColumn, forKey: .merchantColumn)
        }
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requiredKeys = Set(CodingKeys.allCases).subtracting([.providerIDColumn, .merchantColumn, .identityScheme])
        guard requiredKeys.isSubset(of: Set(container.allKeys)),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceImportMappingError.invalidMapping
        }
        self.id = try container.decode(UUID.self, forKey: .id)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.delimiter = try container.decode(FinanceCSVDelimiter.self, forKey: .delimiter)
        self.headerRecordIndex = try container.decode(Int.self, forKey: .headerRecordIndex)
        self.headerFingerprint = try container.decode(String.self, forKey: .headerFingerprint)
        self.columnCount = try container.decode(Int.self, forKey: .columnCount)
        // The first mapped implementation had no marker. Preserve its bytes
        // and surface the legacy scheme so storage can fail closed.
        self.identityScheme = try container.decodeIfPresent(
            FinanceImportIdentityScheme.self,
            forKey: .identityScheme
        ) ?? .legacyV2
        self.dateColumn = try container.decode(Int.self, forKey: .dateColumn)
        self.dateFormat = try container.decode(FinanceImportDateFormat.self, forKey: .dateFormat)
        self.amount = try container.decode(FinanceImportAmountSelection.self, forKey: .amount)
        self.currency = try container.decode(FinanceImportCurrencySelection.self, forKey: .currency)
        self.account = try container.decode(FinanceImportAccountSelection.self, forKey: .account)
        self.description = try container.decode(FinanceImportDescriptionSelection.self, forKey: .description)
        self.providerIDColumn = try decodeStrictOptional(Int.self, forKey: .providerIDColumn, from: container)
        self.merchantColumn = try decodeStrictOptional(Int.self, forKey: .merchantColumn, from: container)
        let usedColumns = [dateColumn]
            + Self.amountColumns(amount)
            + Self.currencyColumns(currency)
            + (account.sourceColumn.map { [$0] } ?? [])
            + Self.descriptionColumns(description)
            + [providerIDColumn, merchantColumn].compactMap { value -> Int? in value }
        guard schemaVersion == Self.schemaVersion,
              headerRecordIndex >= 0,
              headerRecordIndex <= Self.maximumHeaderRecordIndex,
              columnCount > 0,
              columnCount <= Self.maximumColumnCount,
              headerFingerprint.count == 64,
              headerFingerprint.allSatisfy(\.isHexDigit),
              Self.allColumns([dateColumn], within: columnCount),
              Self.validAmountColumns(amount, within: columnCount),
              Self.validCurrencyColumns(currency, within: columnCount),
              Self.validAccountColumns(account, within: columnCount),
              Self.validDescriptionColumns(description, within: columnCount),
              Self.allColumns([providerIDColumn, merchantColumn].compactMap { $0 }, within: columnCount),
              Set(usedColumns).count == usedColumns.count,
              amount.format.decimalSeparator != .dot || amount.format.groupingSeparator != .dot,
              amount.format.decimalSeparator != .comma || amount.format.groupingSeparator != .comma else {
            throw FinanceImportMappingError.invalidMapping
        }
    }

    /// Validates a decoded mapping whose header labels are intentionally not
    /// retained. The source-bound header fingerprint is checked again by the
    /// importer before any mapped column is indexed.
    internal func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              headerRecordIndex >= 0,
              headerRecordIndex <= Self.maximumHeaderRecordIndex,
              columnCount > 0,
              columnCount <= Self.maximumColumnCount,
              headerFingerprint.count == 64,
              headerFingerprint.allSatisfy(\.isHexDigit),
              Self.allColumns([dateColumn], within: columnCount),
              Self.validAmountColumns(amount, within: columnCount),
              Self.validCurrencyColumns(currency, within: columnCount),
              Self.validAccountColumns(account, within: columnCount),
              Self.validDescriptionColumns(description, within: columnCount),
              Self.allColumns([providerIDColumn, merchantColumn].compactMap({ value -> Int? in value }), within: columnCount),
              Set([dateColumn] + Self.amountColumns(amount) + Self.currencyColumns(currency)
                  + (account.sourceColumn.map { [$0] } ?? []) + Self.descriptionColumns(description)
                  + [providerIDColumn, merchantColumn].compactMap({ value -> Int? in value })).count
                  == 1 + Self.amountColumns(amount).count + Self.currencyColumns(currency).count
                  + (account.sourceColumn == nil ? 0 : 1) + Self.descriptionColumns(description).count
                  + [providerIDColumn, merchantColumn].compactMap({ value -> Int? in value }).count,
              amount.format.decimalSeparator != .dot || amount.format.groupingSeparator != .dot,
              amount.format.decimalSeparator != .comma || amount.format.groupingSeparator != .comma else {
            throw FinanceImportMappingError.invalidMapping
        }
    }

    internal var usesLegacyIdentityScheme: Bool { identityScheme == .legacyV2 }

    /// Compares the source-layout choices without using either mapping UUID.
    /// Account identity is intentionally excluded here; callers can compare
    /// the complete configuration below when account separation matters.
    internal func hasSameLayout(as other: FinanceImportMapping) -> Bool {
        delimiter == other.delimiter
            && headerRecordIndex == other.headerRecordIndex
            && headerFingerprint == other.headerFingerprint
            && columnCount == other.columnCount
            && dateColumn == other.dateColumn
            && dateFormat == other.dateFormat
            && amount == other.amount
            && currency == other.currency
            && description == other.description
            && providerIDColumn == other.providerIDColumn
            && merchantColumn == other.merchantColumn
            && account.sourceColumn == other.account.sourceColumn
    }

    /// A decoded mapping only knows its declared width. Recheck the actual
    /// source header before any mapped column is indexed.
    internal func validate(actualHeaderColumns: [String]) throws {
        try validate()
        guard actualHeaderColumns.count == columnCount,
              FinanceImportFingerprint.header(actualHeaderColumns) == headerFingerprint else {
            throw FinanceImportMappingError.stalePreview
        }
    }

    internal func hasSameConfiguration(as other: FinanceImportMapping) -> Bool {
        identityScheme == other.identityScheme
            && hasSameLayout(as: other)
            && account.identity.id == other.account.identity.id
    }

    /// A content-free digest that lets another device compare the identity
    /// algorithm without receiving account labels or source values.
    internal var identityConfigurationDigest: String {
        let payload = FinanceImportIdentityConfigurationPayload(
            identityScheme: identityScheme,
            delimiter: delimiter,
            headerRecordIndex: headerRecordIndex,
            headerFingerprint: headerFingerprint,
            columnCount: columnCount,
            dateColumn: dateColumn,
            dateFormat: dateFormat,
            amount: amount,
            currency: currency,
            sourceColumn: account.sourceColumn,
            description: description,
            providerIDColumn: providerIDColumn,
            merchantColumn: merchantColumn
        )
        let encoder = JSONEncoder.lifeOS
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return FinanceImportFingerprint.bytes(data)
    }

    private static func allColumns(_ columns: [Int], within count: Int) -> Bool {
        columns.allSatisfy { (0..<count).contains($0) }
    }

    private static func validAmountColumns(_ amount: FinanceImportAmountSelection, within count: Int) -> Bool {
        switch amount.signConvention {
        case .signed:
            return amount.amountColumn.map { allColumns([$0], within: count) } ?? false
                && amount.debitColumn == nil && amount.creditColumn == nil
                && amount.debitCreditConvention == .debitIsNegative
        case .debitCredit:
            guard let debit = amount.debitColumn, let credit = amount.creditColumn else { return false }
            return allColumns([debit, credit], within: count)
                && debit != credit && amount.amountColumn == nil
        }
    }

    private static func validCurrencyColumns(_ currency: FinanceImportCurrencySelection, within count: Int) -> Bool {
        switch currency {
        case .column(let index): return allColumns([index], within: count)
        case .constantEUR: return true
        }
    }

    private static func validAccountColumns(_ account: FinanceImportAccountSelection, within count: Int) -> Bool {
        account.sourceColumn.map { allColumns([$0], within: count) } ?? true
    }

    private static func validDescriptionColumns(_ description: FinanceImportDescriptionSelection, within count: Int) -> Bool {
        switch description {
        case .column(let index): return allColumns([index], within: count)
        case .none: return true
        }
    }

    private static func amountColumns(_ amount: FinanceImportAmountSelection) -> [Int] {
        switch amount.signConvention {
        case .signed: return amount.amountColumn.map { [$0] } ?? []
        case .debitCredit: return [amount.debitColumn, amount.creditColumn].compactMap { $0 }
        }
    }

    private static func currencyColumns(_ currency: FinanceImportCurrencySelection) -> [Int] {
        if case .column(let index) = currency { return [index] }
        return []
    }

    private static func descriptionColumns(_ description: FinanceImportDescriptionSelection) -> [Int] {
        if case .column(let index) = description { return [index] }
        return []
    }
}

private struct FinanceImportIdentityConfigurationPayload: Codable {
    let identityScheme: FinanceImportIdentityScheme
    let delimiter: FinanceCSVDelimiter
    let headerRecordIndex: Int
    let headerFingerprint: String
    let columnCount: Int
    let dateColumn: Int
    let dateFormat: FinanceImportDateFormat
    let amount: FinanceImportAmountSelection
    let currency: FinanceImportCurrencySelection
    let sourceColumn: Int?
    let description: FinanceImportDescriptionSelection
    let providerIDColumn: Int?
    let merchantColumn: Int?
}

internal extension FinanceImportedMappedIdentity {
    init(mapping: FinanceImportMapping) throws {
        try self.init(
            accountID: mapping.account.identity.id,
            configurationDigest: mapping.identityConfigurationDigest
        )
    }
}

// MARK: - Detection gate and content-free local provenance

public enum FinanceImportMappingEligibilityState: String, Codable, Equatable, Sendable {
    case known
    case requiresMapping
    case blocked
}

public struct FinanceImportMappingEligibility: Equatable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let state: FinanceImportMappingEligibilityState
    public let originalDetection: FinanceInstitutionDetection
    public let reasonCodes: [FinanceInstitutionDetectionReasonCode]

    public init(
        state: FinanceImportMappingEligibilityState,
        originalDetection: FinanceInstitutionDetection,
        reasonCodes: [FinanceInstitutionDetectionReasonCode] = []
    ) {
        self.schemaVersion = Self.schemaVersion
        self.state = state
        self.originalDetection = originalDetection
        self.reasonCodes = reasonCodes
    }

    public var requiresExplicitMapping: Bool { state == .requiresMapping }
    public var isBlocked: Bool { state == .blocked }
}

/// A transient header choice for the mapping editor. Raw labels are exposed
/// only while the source bytes are present; `FinanceImportInspection` and
/// durable provenance retain the fingerprint and record index instead.
public struct FinanceImportHeaderCandidate: Equatable, Sendable {
    public let recordIndex: Int
    public let labels: [String]

    internal init(recordIndex: Int, labels: [String]) throws {
        let totalBytes = labels.reduce(into: 0) { $0 += $1.utf8.count }
        guard recordIndex >= 0,
              labels.count > 1,
              labels.count <= FinanceImportMapping.maximumColumnCount,
              totalBytes <= 16 * 1024,
              labels.allSatisfy({ $0.utf8.count <= 4096 }) else {
            throw FinanceImportMappingError.invalidMapping
        }
        self.recordIndex = recordIndex
        self.labels = labels
    }
}

public struct FinanceImportInspection: Equatable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let sourceDigest: String
    public let byteCount: Int
    public let headerFingerprint: String
    public let delimiter: FinanceCSVDelimiter
    public let headerRecordIndex: Int?
    public let candidateHeaderRecordIndices: [Int]
    public let columnCount: Int
    public let dataRowCount: Int
    public let originalDetection: FinanceInstitutionDetection
    public let mappingEligibility: FinanceImportMappingEligibility

    public init(
        sourceDigest: String,
        byteCount: Int,
        headerFingerprint: String,
        delimiter: FinanceCSVDelimiter,
        headerRecordIndex: Int?,
        candidateHeaderRecordIndices: [Int],
        columnCount: Int,
        dataRowCount: Int,
        originalDetection: FinanceInstitutionDetection,
        mappingEligibility: FinanceImportMappingEligibility
    ) throws {
        guard sourceDigest.count == 64, sourceDigest.allSatisfy(\.isHexDigit),
              byteCount >= 0, byteCount <= FinanceStatementImporter.maximumInputBytes,
              headerFingerprint.count == 64, headerFingerprint.allSatisfy(\.isHexDigit),
              candidateHeaderRecordIndices.count <= 256,
              candidateHeaderRecordIndices.allSatisfy({ $0 >= 0 }),
              Set(candidateHeaderRecordIndices).count == candidateHeaderRecordIndices.count,
              headerRecordIndex.map({ $0 >= 0 }) ?? true,
              headerRecordIndex.map({ candidateHeaderRecordIndices.contains($0) }) ?? true,
              columnCount >= 0, columnCount <= FinanceImportMapping.maximumColumnCount,
              dataRowCount >= 0 else {
            throw FinanceImportMappingError.invalidMapping
        }
        self.schemaVersion = Self.schemaVersion
        self.sourceDigest = sourceDigest
        self.byteCount = byteCount
        self.headerFingerprint = headerFingerprint
        self.delimiter = delimiter
        self.headerRecordIndex = headerRecordIndex
        self.candidateHeaderRecordIndices = candidateHeaderRecordIndices
        self.columnCount = columnCount
        self.dataRowCount = dataRowCount
        self.originalDetection = originalDetection
        self.mappingEligibility = mappingEligibility
    }
}

public struct FinanceImportPreviewToken: Equatable, Hashable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let sessionID: UUID
    public let revision: Int
    public let batchID: UUID
    public let sourceDigest: String

    public init(sessionID: UUID = UUID(), revision: Int, batchID: UUID = UUID(), sourceDigest: String) throws {
        guard revision >= 0, sourceDigest.count == 64, sourceDigest.allSatisfy(\.isHexDigit) else {
            throw FinanceImportMappingError.invalidMapping
        }
        self.schemaVersion = Self.schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.batchID = batchID
        self.sourceDigest = sourceDigest
    }
}

public struct FinanceImportCategoryEdit: Equatable, Sendable {
    public let transactionID: UUID
    public let category: FinanceTransactionCategory?

    public init(transactionID: UUID, category: FinanceTransactionCategory?) {
        self.transactionID = transactionID
        self.category = category
    }
}

public struct FinanceImportRowProvenance: Codable, Equatable, Sendable {
    public let batchID: UUID
    public let sourceRowNumber: Int
    public let transactionID: UUID

    public init(batchID: UUID, sourceRowNumber: Int, transactionID: UUID) throws {
        guard sourceRowNumber >= 1 else { throw FinanceImportMappingError.invalidMapping }
        self.batchID = batchID
        self.sourceRowNumber = sourceRowNumber
        self.transactionID = transactionID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case batchID, sourceRowNumber, transactionID }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceImportMappingError.invalidMapping
        }
        try self.init(
            batchID: container.decode(UUID.self, forKey: .batchID),
            sourceRowNumber: container.decode(Int.self, forKey: .sourceRowNumber),
            transactionID: container.decode(UUID.self, forKey: .transactionID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(batchID, forKey: .batchID)
        try container.encode(sourceRowNumber, forKey: .sourceRowNumber)
        try container.encode(transactionID, forKey: .transactionID)
    }
}

/// Durable, content-free metadata for one local import. It contains hashes,
/// versions and row links only; raw CSV/header/account values never enter it.
public struct FinanceImportBatchProvenance: Codable, Equatable, Identifiable, Sendable {
    public static let schemaVersion = 1
    public let id: UUID
    public let schemaVersion: Int
    public let importedAt: Date
    public let sourceDigest: String
    public let byteCount: Int
    public let headerFingerprint: String
    public let delimiter: FinanceCSVDelimiter
    public let headerRecordIndex: Int
    public let mappingID: UUID?
    public let registryVersion: String
    public let detectorVersion: String
    public let normalizationVersion: String
    public let originalDetection: FinanceInstitutionDetection
    public let effectiveDetection: FinanceInstitutionDetection
    public let rowLinks: [FinanceImportRowProvenance]

    public init(
        id: UUID,
        importedAt: Date,
        sourceDigest: String,
        byteCount: Int,
        headerFingerprint: String,
        delimiter: FinanceCSVDelimiter,
        headerRecordIndex: Int,
        mappingID: UUID?,
        originalDetection: FinanceInstitutionDetection,
        effectiveDetection: FinanceInstitutionDetection,
        rowLinks: [FinanceImportRowProvenance]
    ) throws {
        guard sourceDigest.count == 64, sourceDigest.allSatisfy(\.isHexDigit),
              headerFingerprint.count == 64, headerFingerprint.allSatisfy(\.isHexDigit),
              byteCount >= 0, byteCount <= FinanceStatementImporter.maximumInputBytes,
              headerRecordIndex >= 0,
              headerRecordIndex <= FinanceImportMapping.maximumHeaderRecordIndex,
              rowLinks.count <= FinanceImportedTransactionStore.maximumTransactions,
              Set(rowLinks.map(\.transactionID)).count == rowLinks.count,
              rowLinks.allSatisfy({ $0.batchID == id }),
              effectiveDetection.state == .known || (effectiveDetection.state == .userMapped && effectiveDetection.institution == nil),
              (effectiveDetection.state == .known && mappingID == nil)
                || (effectiveDetection.state == .userMapped && mappingID != nil) else {
            throw FinanceImportMappingError.invalidMapping
        }
        self.id = id
        self.schemaVersion = Self.schemaVersion
        guard importedAt.timeIntervalSince1970.isFinite else {
            throw FinanceImportMappingError.invalidMapping
        }
        self.importedAt = Self.canonicalImportedAt(importedAt)
        self.sourceDigest = sourceDigest
        self.byteCount = byteCount
        self.headerFingerprint = headerFingerprint
        self.delimiter = delimiter
        self.headerRecordIndex = headerRecordIndex
        self.mappingID = mappingID
        self.registryVersion = originalDetection.provenance.registryVersion
        self.detectorVersion = originalDetection.provenance.detectorVersion
        self.normalizationVersion = originalDetection.provenance.normalizationVersion
        self.originalDetection = originalDetection
        self.effectiveDetection = effectiveDetection
        self.rowLinks = rowLinks
    }

    /// `JSONEncoder.lifeOS` emits ISO-8601 timestamps without fractional
    /// seconds. Canonicalizing before a receipt is prepared makes the in-memory
    /// value equal to the value loaded by `JSONDecoder.lifeOS` after restart.
    internal static func canonicalImportedAt(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, schemaVersion, importedAt, sourceDigest, byteCount, headerFingerprint
        case delimiter, headerRecordIndex, mappingID, registryVersion, detectorVersion
        case normalizationVersion, originalDetection, effectiveDetection, rowLinks
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requiredKeys = Set(CodingKeys.allCases).subtracting([.mappingID])
        guard requiredKeys.isSubset(of: Set(container.allKeys)),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceImportMappingError.invalidMapping
        }
        let id = try container.decode(UUID.self, forKey: .id)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let importedAt = try container.decode(Date.self, forKey: .importedAt)
        let sourceDigest = try container.decode(String.self, forKey: .sourceDigest)
        let byteCount = try container.decode(Int.self, forKey: .byteCount)
        let headerFingerprint = try container.decode(String.self, forKey: .headerFingerprint)
        let delimiter = try container.decode(FinanceCSVDelimiter.self, forKey: .delimiter)
        let headerRecordIndex = try container.decode(Int.self, forKey: .headerRecordIndex)
        let mappingID = try container.decodeIfPresent(UUID.self, forKey: .mappingID)
        let registryVersion = try container.decode(String.self, forKey: .registryVersion)
        let detectorVersion = try container.decode(String.self, forKey: .detectorVersion)
        let normalizationVersion = try container.decode(String.self, forKey: .normalizationVersion)
        let originalDetection = try container.decode(FinanceInstitutionDetection.self, forKey: .originalDetection)
        let effectiveDetection = try container.decode(FinanceInstitutionDetection.self, forKey: .effectiveDetection)
        let rowLinks = try container.decode([FinanceImportRowProvenance].self, forKey: .rowLinks)
        guard schemaVersion == Self.schemaVersion,
              registryVersion == originalDetection.provenance.registryVersion,
              detectorVersion == originalDetection.provenance.detectorVersion,
              normalizationVersion == originalDetection.provenance.normalizationVersion else {
            throw FinanceImportMappingError.invalidMapping
        }
        try self.init(
            id: id,
            importedAt: importedAt,
            sourceDigest: sourceDigest,
            byteCount: byteCount,
            headerFingerprint: headerFingerprint,
            delimiter: delimiter,
            headerRecordIndex: headerRecordIndex,
            mappingID: mappingID,
            originalDetection: originalDetection,
            effectiveDetection: effectiveDetection,
            rowLinks: rowLinks
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(sourceDigest, forKey: .sourceDigest)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(headerFingerprint, forKey: .headerFingerprint)
        try container.encode(delimiter, forKey: .delimiter)
        try container.encode(headerRecordIndex, forKey: .headerRecordIndex)
        try container.encode(mappingID, forKey: .mappingID)
        try container.encode(registryVersion, forKey: .registryVersion)
        try container.encode(detectorVersion, forKey: .detectorVersion)
        try container.encode(normalizationVersion, forKey: .normalizationVersion)
        try container.encode(originalDetection, forKey: .originalDetection)
        try container.encode(effectiveDetection, forKey: .effectiveDetection)
        try container.encode(rowLinks, forKey: .rowLinks)
    }
}

/// A prepared preview is immutable source data produced by the importer. The
/// store accepts it only through the preview token, and the UI can add only
/// validated category edits at commit time.
public struct FinancePreparedImport: Equatable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let token: FinanceImportPreviewToken
    public let rows: [FinancePreparedImportRow]
    public let skippedRowCount: Int
    public let dataRowCount: Int
    public let diagnostics: [FinanceImportDiagnostic]
    public let originalDetection: FinanceInstitutionDetection
    public let effectiveDetection: FinanceInstitutionDetection
    public let mapping: FinanceImportMapping?
    public let batchProvenance: FinanceImportBatchProvenance

    internal init(
        token: FinanceImportPreviewToken,
        rows: [FinancePreparedImportRow],
        skippedRowCount: Int,
        dataRowCount: Int,
        diagnostics: [FinanceImportDiagnostic],
        originalDetection: FinanceInstitutionDetection,
        effectiveDetection: FinanceInstitutionDetection,
        mapping: FinanceImportMapping?,
        batchProvenance: FinanceImportBatchProvenance
    ) throws {
        guard token.batchID == batchProvenance.id,
              token.sourceDigest == batchProvenance.sourceDigest,
              rows.count == batchProvenance.rowLinks.count,
              skippedRowCount >= 0, dataRowCount >= rows.count + skippedRowCount,
              Set(rows.map(\.transaction.id)).count == rows.count,
              rows.map(\.transaction.id) == batchProvenance.rowLinks.map(\.transactionID) else {
            throw FinanceImportMappingError.invalidMapping
        }
        if effectiveDetection.state == .userMapped {
            guard effectiveDetection.institution == nil, mapping != nil else { throw FinanceImportMappingError.invalidMapping }
        } else if effectiveDetection.state == .known {
            guard effectiveDetection.institution != nil, mapping == nil else { throw FinanceImportMappingError.invalidMapping }
        } else {
            throw FinanceImportMappingError.invalidMapping
        }
        self.schemaVersion = Self.schemaVersion
        self.token = token
        self.rows = rows
        self.skippedRowCount = skippedRowCount
        self.dataRowCount = dataRowCount
        self.diagnostics = diagnostics
        self.originalDetection = originalDetection
        self.effectiveDetection = effectiveDetection
        self.mapping = mapping
        self.batchProvenance = batchProvenance
    }

    public var transactions: [FinanceImportedTransaction] { rows.map(\.transaction) }

    public var result: FinanceImportResult {
        FinanceImportResult(
            transactions: transactions,
            skippedRowCount: skippedRowCount,
            detectedSource: transactions.first?.source ?? .genericCSV,
            dataRowCount: dataRowCount,
            headerRecognized: true,
            diagnostics: diagnostics,
            institutionDetection: effectiveDetection,
            sourceRowNumbers: rows.map(\.sourceRowNumber)
        )
    }
}

public struct FinancePreparedImportRow: Equatable, Sendable {
    public let sourceRowNumber: Int
    public let transaction: FinanceImportedTransaction

    public init(sourceRowNumber: Int, transaction: FinanceImportedTransaction) throws {
        guard sourceRowNumber >= 1 else { throw FinanceImportMappingError.invalidMapping }
        self.sourceRowNumber = sourceRowNumber
        self.transaction = transaction
    }
}

public enum FinanceImportFingerprint {
    public static func bytes(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func header(_ headers: [String]) -> String {
        var encoded = Data()
        for header in headers {
            let normalized = FinanceInstitutionDetector.normalizeHeader(header)
            let bytes = Data(normalized.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        return bytes(encoded)
    }
}

// MARK: - Strict mapped scalar parsing

public enum FinanceImportStrictValueParser {
    public static func parseEUR(_ raw: String) -> Int? {
        parseCents(raw, format: .init(decimalSeparator: .dot, groupingSeparator: .none), allowSign: true)
    }

    public static func parseCents(
        _ raw: String,
        format: FinanceImportAmountFormat,
        allowSign: Bool
    ) -> Int? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var negative = false
        if value.first == "-" || value.first == "+" {
            guard allowSign, value.count > 1 else { return nil }
            negative = value.first == "-"
            value.removeFirst()
        }
        guard !value.isEmpty, !value.contains(where: { $0 == "-" || $0 == "+" || $0.isWhitespace && !isAllowedSpace($0, format: format) }) else {
            return nil
        }

        let decimal = format.decimalSeparator.character
        let grouping = format.groupingSeparator.character
        let decimalParts = value.split(separator: decimal, omittingEmptySubsequences: false)
        guard decimalParts.count <= 2 else { return nil }
        let integerPart = String(decimalParts[0])
        let fractionPart = decimalParts.count == 2 ? String(decimalParts[1]) : ""
        guard !integerPart.isEmpty,
              fractionPart.count <= 2,
              fractionPart.allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }

        let digits: String
        if let grouping {
            guard !integerPart.contains(where: { $0 == decimal }) else { return nil }
            let groups = integerPart.split(separator: grouping, omittingEmptySubsequences: false)
            guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber && $0.isASCII } }) else { return nil }
            if groups.count > 1 {
                guard groups[0].count <= 3, groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            }
            digits = groups.map(String.init).joined()
        } else {
            guard integerPart.allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }
            digits = integerPart
        }
        guard !digits.isEmpty else { return nil }
        var centsText = digits
        centsText += fractionPart.count == 0 ? "00" : fractionPart.count == 1 ? fractionPart + "0" : fractionPart
        guard centsText.allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }

        var magnitude = 0
        for scalar in centsText.unicodeScalars {
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            let digit = Int(scalar.value - 48)
            guard magnitude <= (FinanceImportedSyncRecord.maximumSafeCents - digit) / 10 else { return nil }
            magnitude = magnitude * 10 + digit
        }
        guard magnitude <= FinanceImportedSyncRecord.maximumSafeCents else { return nil }
        return negative ? -magnitude : magnitude
    }

    private static func isAllowedSpace(_ value: Character, format: FinanceImportAmountFormat) -> Bool {
        guard let grouping = format.groupingSeparator.character else { return false }
        return value == grouping
    }
}
