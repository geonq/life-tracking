import CryptoKit
import Foundation

// MARK: - Separate investment ledger contract

/// Investment records are deliberately not bank transactions. This contract
/// owns the Robinhood activity ledger and the evidence needed before a value
/// can enter net worth. It never derives a holding or cash balance from an
/// activity row.
public enum FinanceInvestmentContract {
    public static let schemaVersion = 1
    public static let importerVersion = "robinhood-activity-csv-v1"
    public static let maximumImportBytes = 8 * 1024 * 1024
    public static let maximumRows = 20_000
    public static let maximumFieldBytes = 16 * 1024
    public static let maximumAccountIDBytes = 128
    public static let maximumInstrumentBytes = 256
    public static let maximumSourceTextBytes = 256
    public static let maximumComponentIdentityBytes = 512
    public static let maximumActivityCount = 20_000
    public static let maximumSnapshotCount = 1_000
    public static let maximumReceiptCount = 1_000
    public static let maximumRevision = 1_000_000

    /// This is the exact header observed in the local Robinhood export. The
    /// final empty column is part of the observed schema and is required so a
    /// future layout cannot be silently accepted as this one.
    public static let robinhoodActivityCSVHeader = [
        "Activity Date",
        "Transaction Type",
        "Instrument",
        "Instrument Quantity",
        "Instrument Price",
        "Fees",
        "Debit",
        "Credit",
        ""
    ]

    public static let observedRobinhoodTransactionTypes: Set<String> = [
        "Crypto Deposit",
        "Crypto Purchase",
        "Crypto Reward",
        "Crypto Sale",
        "SEPA Deposit",
        "Staking Earnings"
    ]

    public static var robinhoodActivityHeaderFingerprint: String {
        FinanceInvestmentHash.sha256(
            robinhoodActivityCSVHeader.joined(separator: "\u{1f}")
        )
    }
}

public enum FinanceInvestmentValidationError: Error, Equatable, Sendable {
    case invalidSource
    case invalidDecimal
    case invalidMoney
    case invalidActivity
    case invalidHolding
    case invalidSnapshot
    case invalidEvidence
    case invalidNetWorth
    case unsupportedVersion
    case duplicateIdentity
    case tooManyItems
}

extension FinanceInvestmentValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "The investment source identity is invalid."
        case .invalidDecimal: return "The investment value is not an exact decimal."
        case .invalidMoney: return "The investment amount or currency is invalid."
        case .invalidActivity: return "The investment activity is invalid."
        case .invalidHolding: return "The investment holding is invalid."
        case .invalidSnapshot: return "The investment account snapshot is invalid."
        case .invalidEvidence: return "The investment valuation evidence is invalid."
        case .invalidNetWorth: return "The net-worth breakdown could not be validated."
        case .unsupportedVersion: return "The investment schema version is unsupported."
        case .duplicateIdentity: return "The investment ledger contains duplicate identities."
        case .tooManyItems: return "The investment ledger exceeds its safe item limit."
        }
    }
}

public enum FinanceInvestmentProvider: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case robinhood
}

/// Account identity is supplied by the caller because the observed CSV does
/// not contain an account identifier. It is therefore never guessed from a
/// filename or an instrument row.
public struct FinanceInvestmentSourceIdentity: Codable, Equatable, Hashable, Sendable {
    public let provider: FinanceInvestmentProvider
    public let accountID: String
    public let schemaVersion: Int

    public var stableKey: String {
        "\(provider.rawValue)|\(accountID)|v\(schemaVersion)"
    }

    public init(
        provider: FinanceInvestmentProvider = .robinhood,
        accountID: String,
        schemaVersion: Int = FinanceInvestmentContract.schemaVersion
    ) throws {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard schemaVersion == FinanceInvestmentContract.schemaVersion,
              !trimmed.isEmpty,
              trimmed.utf8.count <= FinanceInvestmentContract.maximumAccountIDBytes,
              !trimmed.contains("\u{0}") else {
            throw FinanceInvestmentValidationError.invalidSource
        }
        self.provider = provider
        self.accountID = trimmed
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case provider, accountID, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceInvestmentValidationError.invalidSource
        }
        try self.init(
            provider: container.decode(FinanceInvestmentProvider.self, forKey: .provider),
            accountID: container.decode(String.self, forKey: .accountID),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}

/// Decimal values are stored as strings so quantities and amounts never pass
/// through binary floating point. `rawValue` preserves the source precision;
/// `canonicalValue` is used only for stable identities and comparisons.
public struct FinanceExactDecimal: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    private let decimalValueStorage: Decimal

    private static let maximumDigits = 28
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSyntax(value),
              let decimal = Decimal(string: value, locale: Self.posixLocale),
              Self.canonicalValue(for: value) == Self.canonicalDecimalValue(decimal) else {
            throw FinanceInvestmentValidationError.invalidDecimal
        }
        self.rawValue = value
        self.decimalValueStorage = decimal
    }

    public init(decimal: Decimal) throws {
        var value = decimal
        try self.init(NSDecimalString(&value, Self.posixLocale))
    }

    public var decimalValue: Decimal {
        decimalValueStorage
    }

    public var canonicalValue: String {
        Self.canonicalValue(for: rawValue)
    }

    private static func canonicalValue(for input: String) -> String {
        var value = input
        if value.first == "+" { value.removeFirst() }
        let negative = value.first == "-"
        if negative { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        var integer = String(parts[0]).drop { $0 == "0" }
        if integer.isEmpty { integer = "0" }
        var fractional = parts.count == 2 ? String(parts[1]) : ""
        while fractional.last == "0" { fractional.removeLast() }
        let joined = fractional.isEmpty ? String(integer) : "\(integer).\(fractional)"
        return negative && joined != "0" ? "-\(joined)" : joined
    }

    private static func canonicalDecimalValue(_ decimal: Decimal) -> String {
        var value = decimal
        return canonicalValue(for: NSDecimalString(&value, posixLocale))
    }

    public var isZero: Bool { canonicalValue == "0" }

    public static func adding(_ values: [FinanceExactDecimal]) throws -> FinanceExactDecimal {
        var total = Decimal.zero
        for value in values {
            var lhs = total
            var rhs = value.decimalValue
            var result = Decimal.zero
            guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError else {
                throw FinanceInvestmentValidationError.invalidNetWorth
            }
            total = result
        }
        return try FinanceExactDecimal(decimal: total)
    }

    public static func multiplying(
        _ lhs: FinanceExactDecimal,
        _ rhs: FinanceExactDecimal
    ) throws -> FinanceExactDecimal {
        var left = lhs.decimalValue
        var right = rhs.decimalValue
        var result = Decimal.zero
        guard NSDecimalMultiply(&result, &left, &right, .plain) == .noError else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        return try FinanceExactDecimal(decimal: result)
    }

    private static func isValidSyntax(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return false }
        var index = 0
        if bytes[index] == 43 || bytes[index] == 45 {
            index += 1
            guard index < bytes.count else { return false }
        }
        var integerDigits = 0
        while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
            integerDigits += 1
            index += 1
        }
        guard integerDigits > 0 else { return false }
        var fractionalDigits = 0
        if index < bytes.count {
            guard bytes[index] == 46 else { return false }
            index += 1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fractionalDigits += 1
                index += 1
            }
            guard fractionalDigits > 0 else { return false }
        }
        return index == bytes.count && integerDigits + fractionalDigits <= maximumDigits
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [CodingKeys.rawValue.stringValue])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

public struct FinanceInvestmentMoney: Codable, Equatable, Hashable, Sendable {
    public let amount: FinanceExactDecimal
    public let currency: String

    public init(amount: FinanceExactDecimal, currency: String) throws {
        let normalized = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.utf8.count == 3,
              normalized.unicodeScalars.allSatisfy({ ($0.value >= 65 && $0.value <= 90) }) else {
            throw FinanceInvestmentValidationError.invalidMoney
        }
        self.amount = amount
        self.currency = normalized
    }

    public init(amount: String, currency: String) throws {
        try self.init(amount: FinanceExactDecimal(amount), currency: currency)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case amount, currency }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceInvestmentValidationError.invalidMoney
        }
        try self.init(
            amount: container.decode(FinanceExactDecimal.self, forKey: .amount),
            currency: container.decode(String.self, forKey: .currency)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encode(currency, forKey: .currency)
    }
}

public enum FinanceInvestmentActivityKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case buy
    case sell
    case dividend
    case interest
    case fee
    case deposit
    case withdrawal
    case transfer
    case unknown
}

/// A source row is retained as an activity, but its cash movement is never a
/// valuation. Account snapshots are the only input accepted by net worth.
public struct FinanceInvestmentActivity: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let source: FinanceInvestmentSourceIdentity
    public let observedAt: Date
    public let kind: FinanceInvestmentActivityKind
    public let rawTransactionType: String
    public let instrument: String
    public let quantity: FinanceExactDecimal?
    public let instrumentPrice: FinanceInvestmentMoney?
    public let fees: FinanceInvestmentMoney?
    public let debit: FinanceInvestmentMoney?
    public let credit: FinanceInvestmentMoney?
    public let sourceRowNumber: Int

    public init(
        id: String,
        source: FinanceInvestmentSourceIdentity,
        observedAt: Date,
        kind: FinanceInvestmentActivityKind,
        rawTransactionType: String,
        instrument: String,
        quantity: FinanceExactDecimal?,
        instrumentPrice: FinanceInvestmentMoney?,
        fees: FinanceInvestmentMoney?,
        debit: FinanceInvestmentMoney?,
        credit: FinanceInvestmentMoney?,
        sourceRowNumber: Int
    ) throws {
        let type = rawTransactionType.trimmingCharacters(in: .whitespacesAndNewlines)
        let asset = instrument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FinanceInvestmentHash.isSHA256(id),
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              !type.isEmpty && type.utf8.count <= FinanceInvestmentContract.maximumSourceTextBytes,
              !asset.isEmpty && asset.utf8.count <= FinanceInvestmentContract.maximumInstrumentBytes,
              sourceRowNumber >= 2,
              sourceRowNumber <= FinanceInvestmentContract.maximumRows + 1,
              quantity.map({ $0.decimalValue > .zero }) ?? true,
              !(debit != nil && credit != nil),
              debit != nil || credit != nil else {
            throw FinanceInvestmentValidationError.invalidActivity
        }

        let monies = [instrumentPrice, fees, debit, credit].compactMap { $0 }
        guard monies.dropFirst().allSatisfy({ $0.currency == monies.first?.currency }),
              monies.allSatisfy({ $0.amount.decimalValue >= .zero }) else {
            throw FinanceInvestmentValidationError.invalidActivity
        }
        self.id = id.lowercased()
        self.source = source
        self.observedAt = observedAt
        self.kind = kind
        self.rawTransactionType = type
        self.instrument = asset
        self.quantity = quantity
        self.instrumentPrice = instrumentPrice
        self.fees = fees
        self.debit = debit
        self.credit = credit
        self.sourceRowNumber = sourceRowNumber
    }

    public static func == (lhs: FinanceInvestmentActivity, rhs: FinanceInvestmentActivity) -> Bool {
        lhs.id == rhs.id
            && lhs.source == rhs.source
            && lhs.observedAt == rhs.observedAt
            && lhs.kind == rhs.kind
            && lhs.rawTransactionType == rhs.rawTransactionType
            && lhs.instrument.uppercased() == rhs.instrument.uppercased()
            && semanticDecimal(lhs.quantity) == semanticDecimal(rhs.quantity)
            && semanticMoney(lhs.instrumentPrice) == semanticMoney(rhs.instrumentPrice)
            && semanticMoney(lhs.fees) == semanticMoney(rhs.fees)
            && semanticMoney(lhs.debit) == semanticMoney(rhs.debit)
            && semanticMoney(lhs.credit) == semanticMoney(rhs.credit)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(source)
        hasher.combine(observedAt)
        hasher.combine(kind)
        hasher.combine(rawTransactionType)
        hasher.combine(instrument.uppercased())
        hasher.combine(Self.semanticDecimal(quantity))
        hasher.combine(Self.semanticMoney(instrumentPrice))
        hasher.combine(Self.semanticMoney(fees))
        hasher.combine(Self.semanticMoney(debit))
        hasher.combine(Self.semanticMoney(credit))
    }

    private static func semanticDecimal(_ value: FinanceExactDecimal?) -> String? {
        value?.canonicalValue
    }

    private static func semanticMoney(_ value: FinanceInvestmentMoney?) -> String? {
        guard let value else { return nil }
        return "\(value.currency):\(value.amount.canonicalValue)"
    }

    public var cashMovement: FinanceInvestmentMoney? { debit ?? credit }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, source, observedAt, kind, rawTransactionType, instrument, quantity
        case instrumentPrice, fees, debit, credit, sourceRowNumber
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceInvestmentValidationError.invalidActivity
        }
        try self.init(
            id: container.decode(String.self, forKey: .id),
            source: container.decode(FinanceInvestmentSourceIdentity.self, forKey: .source),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            kind: container.decode(FinanceInvestmentActivityKind.self, forKey: .kind),
            rawTransactionType: container.decode(String.self, forKey: .rawTransactionType),
            instrument: container.decode(String.self, forKey: .instrument),
            quantity: container.decodeIfPresent(FinanceExactDecimal.self, forKey: .quantity),
            instrumentPrice: container.decodeIfPresent(FinanceInvestmentMoney.self, forKey: .instrumentPrice),
            fees: container.decodeIfPresent(FinanceInvestmentMoney.self, forKey: .fees),
            debit: container.decodeIfPresent(FinanceInvestmentMoney.self, forKey: .debit),
            credit: container.decodeIfPresent(FinanceInvestmentMoney.self, forKey: .credit),
            sourceRowNumber: container.decode(Int.self, forKey: .sourceRowNumber)
        )
        try FinanceRobinhoodImporter.validateDecodedActivity(self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(kind, forKey: .kind)
        try container.encode(rawTransactionType, forKey: .rawTransactionType)
        try container.encode(instrument, forKey: .instrument)
        try container.encodeIfPresent(quantity, forKey: .quantity)
        try container.encodeIfPresent(instrumentPrice, forKey: .instrumentPrice)
        try container.encodeIfPresent(fees, forKey: .fees)
        try container.encodeIfPresent(debit, forKey: .debit)
        try container.encodeIfPresent(credit, forKey: .credit)
        try container.encode(sourceRowNumber, forKey: .sourceRowNumber)
    }
}

public struct FinanceInvestmentImportEvidence: Codable, Equatable, Sendable {
    public let source: FinanceInvestmentSourceIdentity
    public let fileSHA256: String
    public let byteCount: Int
    public let headerFingerprint: String
    public let observedAt: Date
    public let dataRowCount: Int
    public let blankRowsSkipped: Int

    public init(
        source: FinanceInvestmentSourceIdentity,
        fileSHA256: String,
        byteCount: Int,
        headerFingerprint: String,
        observedAt: Date,
        dataRowCount: Int,
        blankRowsSkipped: Int
    ) throws {
        guard FinanceInvestmentHash.isSHA256(fileSHA256),
              FinanceInvestmentHash.isSHA256(headerFingerprint),
              byteCount >= 0,
              byteCount <= FinanceInvestmentContract.maximumImportBytes,
              dataRowCount >= 0,
              dataRowCount <= FinanceInvestmentContract.maximumRows,
              blankRowsSkipped >= 0,
              blankRowsSkipped <= FinanceInvestmentContract.maximumRows,
              observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FinanceInvestmentValidationError.invalidSource
        }
        self.source = source
        self.fileSHA256 = fileSHA256.lowercased()
        self.byteCount = byteCount
        self.headerFingerprint = headerFingerprint.lowercased()
        self.observedAt = observedAt
        self.dataRowCount = dataRowCount
        self.blankRowsSkipped = blankRowsSkipped
    }
}

public enum FinanceInvestmentDataCoverage: String, Codable, Equatable, Sendable {
    case activitiesOnly
}

public enum FinanceInvestmentAccountCoverage: String, Codable, Equatable, Sendable {
    case unknown
    case complete
}

public enum FinanceInvestmentProductionGate: String, Codable, Equatable, Sendable {
    /// The observed export has no holdings or verified cash snapshot and
    /// therefore cannot contribute to net worth by itself.
    case blockedMissingAccountSnapshotAndValuationEvidence
}

public struct FinanceInvestmentValuationEvidence: Codable, Equatable, Sendable {
    public let priceSource: String
    public let priceObservedAt: Date
    public let fxSource: String?
    public let fxObservedAt: Date?
    public let fxRate: FinanceExactDecimal?

    public init(
        priceSource: String,
        priceObservedAt: Date,
        fxSource: String? = nil,
        fxObservedAt: Date? = nil,
        fxRate: FinanceExactDecimal? = nil
    ) throws {
        let source = priceSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let fx = fxSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              source.utf8.count <= FinanceInvestmentContract.maximumSourceTextBytes,
              priceObservedAt.timeIntervalSinceReferenceDate.isFinite,
              (fx == nil) == (fxObservedAt == nil),
              (fx == nil) == (fxRate == nil),
              fx.map({ !$0.isEmpty && $0.utf8.count <= FinanceInvestmentContract.maximumSourceTextBytes }) ?? true,
              fxObservedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              fxRate.map({ $0.decimalValue > .zero }) ?? true else {
            throw FinanceInvestmentValidationError.invalidEvidence
        }
        self.priceSource = source
        self.priceObservedAt = priceObservedAt
        self.fxSource = fx
        self.fxObservedAt = fxObservedAt
        self.fxRate = fxRate
    }
}

public struct FinanceInvestmentHoldingValuation: Codable, Equatable, Sendable {
    public let nativeValue: FinanceInvestmentMoney
    public let eurValue: FinanceInvestmentMoney
    public let evidence: FinanceInvestmentValuationEvidence

    public init(
        nativeValue: FinanceInvestmentMoney,
        eurValue: FinanceInvestmentMoney,
        evidence: FinanceInvestmentValuationEvidence
    ) throws {
        guard nativeValue.amount.decimalValue >= .zero,
              eurValue.amount.decimalValue >= .zero,
              eurValue.currency == "EUR" else {
            throw FinanceInvestmentValidationError.invalidEvidence
        }
        if nativeValue.currency == "EUR" {
            guard evidence.fxSource == nil,
                  evidence.fxObservedAt == nil,
                  evidence.fxRate == nil,
                  nativeValue.amount.canonicalValue == eurValue.amount.canonicalValue else {
                throw FinanceInvestmentValidationError.invalidEvidence
            }
        } else {
            guard evidence.fxSource != nil,
                  evidence.fxObservedAt != nil,
                  let fxRate = evidence.fxRate,
                  (try? FinanceExactDecimal.multiplying(nativeValue.amount, fxRate))?.canonicalValue == eurValue.amount.canonicalValue else {
                throw FinanceInvestmentValidationError.invalidEvidence
            }
        }
        self.nativeValue = nativeValue
        self.eurValue = eurValue
        self.evidence = evidence
    }
}

public struct FinanceInvestmentHoldingObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let assetIdentifier: String
    public let quantity: FinanceExactDecimal
    public let assetCurrency: String
    public let valuation: FinanceInvestmentHoldingValuation?

    public init(
        id: String,
        assetIdentifier: String,
        quantity: FinanceExactDecimal,
        assetCurrency: String,
        valuation: FinanceInvestmentHoldingValuation? = nil
    ) throws {
        let asset = assetIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = assetCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !asset.isEmpty,
              asset.utf8.count <= FinanceInvestmentContract.maximumInstrumentBytes,
              quantity.decimalValue > .zero,
              currency.utf8.count == 3,
              currency.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }),
              valuation.map({ $0.nativeValue.currency == currency }) ?? true else {
            throw FinanceInvestmentValidationError.invalidHolding
        }
        self.id = id
        self.assetIdentifier = asset
        self.quantity = quantity
        self.assetCurrency = currency
        self.valuation = valuation
    }
}

public struct FinanceInvestmentCashObservation: Codable, Equatable, Sendable {
    public let amount: FinanceInvestmentMoney
    public let observedAt: Date
    public let source: String
    public let verificationID: String
    public let consolidationKey: String?

    public init(
        amount: FinanceInvestmentMoney,
        observedAt: Date,
        source: String,
        verificationID: String,
        consolidationKey: String? = nil
    ) throws {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVerification = verificationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConsolidation = consolidationKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              !normalizedSource.isEmpty,
              !normalizedVerification.isEmpty,
              normalizedSource.utf8.count <= FinanceInvestmentContract.maximumSourceTextBytes,
              normalizedVerification.utf8.count <= FinanceInvestmentContract.maximumSourceTextBytes,
              normalizedConsolidation.map({ !$0.isEmpty && $0.utf8.count <= FinanceInvestmentContract.maximumAccountIDBytes }) ?? true else {
            throw FinanceInvestmentValidationError.invalidEvidence
        }
        self.amount = amount
        self.observedAt = observedAt
        self.source = normalizedSource
        self.verificationID = normalizedVerification
        self.consolidationKey = normalizedConsolidation
    }
}

public struct FinanceInvestmentAccountValuation: Codable, Equatable, Sendable {
    public let eurValue: FinanceInvestmentMoney
    public let observedAt: Date
    public let source: String
    public let verificationID: String

    public init(
        eurValue: FinanceInvestmentMoney,
        observedAt: Date,
        source: String,
        verificationID: String
    ) throws {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVerification = verificationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eurValue.currency == "EUR",
              eurValue.amount.decimalValue >= .zero,
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              !normalizedSource.isEmpty,
              !normalizedVerification.isEmpty else {
            throw FinanceInvestmentValidationError.invalidEvidence
        }
        self.eurValue = eurValue
        self.observedAt = observedAt
        self.source = normalizedSource
        self.verificationID = normalizedVerification
    }
}

public struct FinanceInvestmentAccountSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let source: FinanceInvestmentSourceIdentity
    public let observedAt: Date
    public let verifiedCash: FinanceInvestmentCashObservation?
    public let holdings: [FinanceInvestmentHoldingObservation]
    public let cashCoverage: FinanceInvestmentAccountCoverage
    public let holdingsCoverage: FinanceInvestmentAccountCoverage
    public let totalValuation: FinanceInvestmentAccountValuation?

    public var id: String { source.stableKey }

    public init(
        source: FinanceInvestmentSourceIdentity,
        observedAt: Date,
        verifiedCash: FinanceInvestmentCashObservation? = nil,
        holdings: [FinanceInvestmentHoldingObservation] = [],
        cashCoverage: FinanceInvestmentAccountCoverage,
        holdingsCoverage: FinanceInvestmentAccountCoverage,
        totalValuation: FinanceInvestmentAccountValuation? = nil
    ) throws {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              holdings.count <= FinanceInvestmentContract.maximumSnapshotCount else {
            throw FinanceInvestmentValidationError.invalidSnapshot
        }
        let ids = holdings.map(\.id)
        guard Set(ids).count == ids.count,
              cashCoverage == .complete || verifiedCash == nil,
              holdingsCoverage == .complete || holdings.isEmpty,
              (verifiedCash?.observedAt).map({ $0 <= observedAt }) ?? true,
              holdings.allSatisfy({ holding in
                  holding.valuation.map {
                      $0.evidence.priceObservedAt <= observedAt
                          && ($0.evidence.fxObservedAt.map({ $0 <= observedAt }) ?? true)
                  } ?? true
              }),
              (totalValuation?.observedAt).map({ $0 <= observedAt }) ?? true else {
            throw FinanceInvestmentValidationError.invalidSnapshot
        }
        self.source = source
        self.observedAt = observedAt
        self.verifiedCash = verifiedCash
        self.holdings = holdings.sorted { $0.id < $1.id }
        self.cashCoverage = cashCoverage
        self.holdingsCoverage = holdingsCoverage
        self.totalValuation = totalValuation
    }
}

/// This input is intentionally a small neutral bridge. It does not import or
/// mutate bank transactions; a future coordinator may supply a verified bank
/// observation explicitly after live reconciliation. The amount is signed so
/// an overdraft remains a liability in net worth instead of being rejected or
/// silently converted to zero.
public struct FinanceVerifiedBankCashObservation: Codable, Equatable, Sendable {
    public let accountID: String
    public let amount: FinanceInvestmentMoney
    public let observedAt: Date
    public let source: String
    public let verificationID: String
    public let consolidationKey: String?

    public init(
        accountID: String,
        amount: FinanceInvestmentMoney,
        observedAt: Date,
        source: String,
        verificationID: String,
        consolidationKey: String? = nil
    ) throws {
        let id = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              !sourceText.isEmpty,
              !verificationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= FinanceInvestmentContract.maximumAccountIDBytes,
              sourceText.utf8.count <= FinanceInvestmentContract.maximumSourceTextBytes,
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              consolidationKey.map({
                  let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !value.isEmpty && value.utf8.count <= FinanceInvestmentContract.maximumAccountIDBytes
              }) ?? true else {
            throw FinanceInvestmentValidationError.invalidEvidence
        }
        self.accountID = id
        self.amount = amount
        self.observedAt = observedAt
        self.source = sourceText
        self.verificationID = verificationID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.consolidationKey = consolidationKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum FinanceNetWorthComponentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case bankCash
    case investmentCash
    case investmentHoldings
    case investmentAccountTotal
    case investmentActivity
}

public enum FinanceNetWorthComponentStatus: String, Codable, Equatable, Sendable {
    case included
    case excluded
}

private enum FinanceNetWorthIdentityKey {
    static func cash(
        kind: FinanceNetWorthComponentKind,
        accountID: String,
        source: String,
        consolidationKey: String?
    ) -> String {
        if let consolidationKey {
            return "cash|linked|\(consolidationKey)"
        }
        return "cash|unlinked|\(kind.rawValue)|\(accountID)|\(source)"
    }

    static func accountTotal(accountID: String, source: String) -> String {
        "account|\(accountID)|\(source)"
    }

    static func holding(accountID: String, source: String, holdingID: String) -> String {
        "holding|\(accountID)|\(source)|\(holdingID)"
    }

    static func validateIncluded(
        kind: FinanceNetWorthComponentKind,
        accountID: String,
        source: String,
        identityKey: String
    ) throws -> String {
        switch kind {
        case .bankCash, .investmentCash:
            let linkedPrefix = "cash|linked|"
            if identityKey.hasPrefix(linkedPrefix) {
                guard identityKey.utf8.count > linkedPrefix.utf8.count else {
                    throw FinanceInvestmentValidationError.invalidNetWorth
                }
                return identityKey
            }
            guard identityKey == cash(
                kind: kind,
                accountID: accountID,
                source: source,
                consolidationKey: nil
            ) else {
                throw FinanceInvestmentValidationError.invalidNetWorth
            }
        case .investmentAccountTotal:
            let expected = accountTotal(accountID: accountID, source: source)
            guard identityKey == expected else {
                throw FinanceInvestmentValidationError.invalidNetWorth
            }
        case .investmentHoldings:
            let prefix = "holding|\(accountID)|\(source)|"
            guard identityKey.hasPrefix(prefix),
                  identityKey.utf8.count > prefix.utf8.count else {
                throw FinanceInvestmentValidationError.invalidNetWorth
            }
        case .investmentActivity:
            guard !identityKey.isEmpty else {
                throw FinanceInvestmentValidationError.invalidNetWorth
            }
        }
        return identityKey
    }
}

public enum FinanceNetWorthExclusionReason: String, Codable, Equatable, Sendable {
    case activityDoesNotValueNetWorth
    case missingHoldingValuation
    case missingFXEvidence
    case unsupportedCurrency
    case accountTotalAlreadyIncludesComponents
    case supersededSnapshot
    case duplicateCashIdentity
    case ambiguousLinkedCash
    case ambiguousSnapshot
    case missingAccountSnapshot
    case missingValuationEvidence
    case incompleteAccountCoverage
    case staleObservation
    case futureObservation
}

public struct FinanceNetWorthComponent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let identityKey: String
    public let coveredCashIdentityKeys: [String]
    public let kind: FinanceNetWorthComponentKind
    public let accountID: String
    public let source: String
    public let observedAt: Date
    public let amountEUR: FinanceExactDecimal?
    public let status: FinanceNetWorthComponentStatus
    public let exclusionReason: FinanceNetWorthExclusionReason?

    fileprivate init(
        kind: FinanceNetWorthComponentKind,
        accountID: String,
        source: String,
        observedAt: Date,
        amountEUR: FinanceExactDecimal?,
        status: FinanceNetWorthComponentStatus,
        exclusionReason: FinanceNetWorthExclusionReason?,
        coveredCashIdentityKeys: [String] = [],
        identitySuffix: String = ""
    ) throws {
        guard !accountID.isEmpty,
              !source.isEmpty,
              identitySuffix.utf8.count <= FinanceInvestmentContract.maximumComponentIdentityBytes,
              !identitySuffix.contains("\u{0}"),
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              status == .included ? (amountEUR != nil && exclusionReason == nil) : (amountEUR == nil && exclusionReason != nil) else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        let normalizedCoveredCashIdentityKeys = coveredCashIdentityKeys.sorted()
        guard normalizedCoveredCashIdentityKeys.count <= 1,
              Set(normalizedCoveredCashIdentityKeys).count == normalizedCoveredCashIdentityKeys.count,
              normalizedCoveredCashIdentityKeys.allSatisfy({
                  !$0.isEmpty
                      && $0.utf8.count <= FinanceInvestmentContract.maximumComponentIdentityBytes
                      && !$0.contains("\u{0}")
              }) else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        let identityKey: String
        if status == .included {
            let suppliedIdentity = kind == .investmentAccountTotal && identitySuffix.isEmpty
                ? FinanceNetWorthIdentityKey.accountTotal(accountID: accountID, source: source)
                : identitySuffix
            identityKey = try FinanceNetWorthIdentityKey.validateIncluded(
                kind: kind,
                accountID: accountID,
                source: source,
                identityKey: suppliedIdentity
            )
        } else {
            identityKey = identitySuffix.isEmpty
                ? "excluded|\(kind.rawValue)|\(accountID)|\(source)"
                : identitySuffix
        }
        if kind == .investmentAccountTotal && status == .included {
            for coveredCashIdentityKey in normalizedCoveredCashIdentityKeys {
                _ = try FinanceNetWorthIdentityKey.validateIncluded(
                    kind: .investmentCash,
                    accountID: accountID,
                    source: source,
                    identityKey: coveredCashIdentityKey
                )
            }
        } else {
            guard normalizedCoveredCashIdentityKeys.isEmpty else {
                throw FinanceInvestmentValidationError.invalidNetWorth
            }
        }
        guard identityKey.utf8.count <= FinanceInvestmentContract.maximumComponentIdentityBytes,
              !identityKey.contains("\u{0}") else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        self.id = FinanceInvestmentHash.sha256(Self.canonicalID(
            kind: kind,
            accountID: accountID,
            source: source,
            observedAt: observedAt,
            amountEUR: amountEUR,
            status: status,
            exclusionReason: exclusionReason,
            identityKey: identityKey,
            coveredCashIdentityKeys: normalizedCoveredCashIdentityKeys
        ))
        self.identityKey = identityKey
        self.coveredCashIdentityKeys = normalizedCoveredCashIdentityKeys
        self.kind = kind
        self.accountID = accountID
        self.source = source
        self.observedAt = observedAt
        self.amountEUR = amountEUR
        self.status = status
        self.exclusionReason = exclusionReason
    }

    internal static func canonicalID(
        kind: FinanceNetWorthComponentKind,
        accountID: String,
        source: String,
        observedAt: Date,
        amountEUR: FinanceExactDecimal?,
        status: FinanceNetWorthComponentStatus,
        exclusionReason: FinanceNetWorthExclusionReason?,
        identityKey: String,
        coveredCashIdentityKeys: [String] = []
    ) -> String {
        let coveredSuffix = coveredCashIdentityKeys.isEmpty
            ? ""
            : "|coveredCash|\(coveredCashIdentityKeys.sorted().joined(separator: ","))"
        return "\(kind.rawValue)|\(accountID)|\(source)|\(observedAt.timeIntervalSinceReferenceDate)|\(status.rawValue)|\(exclusionReason?.rawValue ?? "included")|\(amountEUR?.canonicalValue ?? "")|\(identityKey)\(coveredSuffix)"
    }
}

public enum FinanceNetWorthAvailability: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case unavailable
}

public struct FinanceNetWorthBreakdown: Codable, Equatable, Sendable {
    public let components: [FinanceNetWorthComponent]
    public let includedTotalEUR: FinanceExactDecimal?
    public let availability: FinanceNetWorthAvailability
    public let activityCount: Int
    public let asOf: Date
    public let maximumObservationAge: TimeInterval

    public init(
        bankCash: [FinanceVerifiedBankCashObservation],
        investmentSnapshots: [FinanceInvestmentAccountSnapshot],
        activities: [FinanceInvestmentActivity] = [],
        asOf: Date,
        maximumObservationAge: TimeInterval = 90 * 24 * 60 * 60
    ) throws {
        guard asOf.timeIntervalSinceReferenceDate.isFinite,
              maximumObservationAge.isFinite,
              maximumObservationAge >= 0 else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        var components: [FinanceNetWorthComponent] = []
        components.reserveCapacity(bankCash.count + investmentSnapshots.count * 2 + activities.count)

        let latestBank = Self.latestBankObservations(bankCash)
        let selectedSnapshots = Self.latestSnapshots(investmentSnapshots)

        var cashCandidates: [FinanceCashCandidate] = []
        var coveredCashKeys = Set<String>()
        var validSnapshotSources = Set<String>()
        var ambiguousSnapshotSources = Set<String>()
        let freshAccountTotalCashIdentityKeys = selectedSnapshots.selected.compactMap { snapshot -> String? in
            guard let total = snapshot.totalValuation,
                  snapshot.verifiedCash != nil,
                  Self.freshnessReason(
                      total.observedAt,
                      asOf: asOf,
                      maximumObservationAge: maximumObservationAge
                  ) == nil else {
                return nil
            }
            return Self.investmentCashIdentityKey(for: snapshot)
        }
        let ambiguousAccountTotalCashIdentityKeys = Set(
            Dictionary(grouping: freshAccountTotalCashIdentityKeys, by: { $0 })
                .filter { $0.value.count > 1 }
                .map(\.key)
        )
        for observation in latestBank.ambiguous {
            components.append(try FinanceNetWorthComponent(
                kind: .bankCash,
                accountID: observation.accountID,
                source: observation.source,
                observedAt: observation.observedAt,
                amountEUR: nil,
                status: .excluded,
                exclusionReason: .ambiguousSnapshot,
                identitySuffix: "bank|\(observation.verificationID)"
            ))
        }
        for observation in latestBank.selected {
            if let reason = Self.freshnessReason(
                observation.observedAt,
                asOf: asOf,
                maximumObservationAge: maximumObservationAge
            ) {
                components.append(try FinanceNetWorthComponent(
                    kind: .bankCash,
                    accountID: observation.accountID,
                    source: observation.source,
                    observedAt: observation.observedAt,
                    amountEUR: nil,
                    status: .excluded,
                    exclusionReason: reason,
                    identitySuffix: "bank|\(observation.verificationID)"
                ))
                continue
            }
            cashCandidates.append(FinanceCashCandidate(
                kind: .bankCash,
                accountID: observation.accountID,
                source: observation.source,
                amount: observation.amount,
                observedAt: observation.observedAt,
                aggregationKey: observation.consolidationKey ?? "bank|\(observation.source)|\(observation.accountID)",
                verificationID: observation.verificationID,
                identityKey: FinanceNetWorthIdentityKey.cash(
                    kind: .bankCash,
                    accountID: observation.accountID,
                    source: observation.source,
                    consolidationKey: observation.consolidationKey
                )
            ))
        }
        for snapshot in selectedSnapshots.ambiguous {
            ambiguousSnapshotSources.insert(snapshot.source.stableKey)
            components.append(try FinanceNetWorthComponent(
                kind: .investmentAccountTotal,
                accountID: snapshot.source.accountID,
                source: snapshot.source.provider.rawValue,
                observedAt: snapshot.observedAt,
                amountEUR: nil,
                status: .excluded,
                exclusionReason: .ambiguousSnapshot,
                identitySuffix: Self.snapshotIdentitySuffix(snapshot)
            ))
        }
        for snapshot in selectedSnapshots.selected {
            if let reason = Self.freshnessReason(
                snapshot.observedAt,
                asOf: asOf,
                maximumObservationAge: maximumObservationAge
            ) {
                components.append(try FinanceNetWorthComponent(
                    kind: .investmentAccountTotal,
                    accountID: snapshot.source.accountID,
                    source: snapshot.source.provider.rawValue,
                    observedAt: snapshot.observedAt,
                    amountEUR: nil,
                    status: .excluded,
                    exclusionReason: reason,
                    identitySuffix: Self.snapshotIdentitySuffix(snapshot)
                ))
                continue
            }
            validSnapshotSources.insert(snapshot.source.stableKey)
            let totalFreshness = snapshot.totalValuation.flatMap {
                Self.freshnessReason(
                    $0.observedAt,
                    asOf: asOf,
                    maximumObservationAge: maximumObservationAge
                )
            }
            let totalSharesAmbiguousCash = totalFreshness == nil
                && Self.investmentCashIdentityKey(for: snapshot)
                    .map(ambiguousAccountTotalCashIdentityKeys.contains) == true
            let totalCountsComponents = snapshot.totalValuation != nil
                && totalFreshness == nil
                && !totalSharesAmbiguousCash
            let hasCompleteAccountCoverage = snapshot.cashCoverage == .complete
                && snapshot.holdingsCoverage == .complete

            if let total = snapshot.totalValuation, let reason = totalFreshness {
                components.append(try FinanceNetWorthComponent(
                    kind: .investmentAccountTotal,
                    accountID: snapshot.source.accountID,
                    source: snapshot.source.provider.rawValue,
                    observedAt: total.observedAt,
                    amountEUR: nil,
                    status: .excluded,
                    exclusionReason: reason,
                    identitySuffix: "total|\(total.verificationID)"
                ))
            } else if let total = snapshot.totalValuation, totalSharesAmbiguousCash {
                components.append(try FinanceNetWorthComponent(
                    kind: .investmentAccountTotal,
                    accountID: snapshot.source.accountID,
                    source: snapshot.source.provider.rawValue,
                    observedAt: total.observedAt,
                    amountEUR: nil,
                    status: .excluded,
                    exclusionReason: .ambiguousLinkedCash,
                    identitySuffix: "total|\(total.verificationID)"
                ))
            } else if let total = snapshot.totalValuation {
                components.append(try FinanceNetWorthComponent(
                    kind: .investmentAccountTotal,
                    accountID: snapshot.source.accountID,
                    source: snapshot.source.provider.rawValue,
                    observedAt: total.observedAt,
                    amountEUR: total.eurValue.amount,
                    status: .included,
                    exclusionReason: nil,
                    coveredCashIdentityKeys: snapshot.verifiedCash.map {
                        [FinanceNetWorthIdentityKey.cash(
                            kind: .investmentCash,
                            accountID: snapshot.source.accountID,
                            source: snapshot.source.provider.rawValue,
                            consolidationKey: $0.consolidationKey
                        )]
                    } ?? []
                ))
                if let cash = snapshot.verifiedCash {
                    coveredCashKeys.insert(cash.consolidationKey ?? "investment|\(snapshot.source.stableKey)")
                    components.append(try FinanceNetWorthComponent(
                        kind: .investmentCash,
                        accountID: snapshot.source.accountID,
                        source: snapshot.source.provider.rawValue,
                        observedAt: cash.observedAt,
                        amountEUR: nil,
                        status: .excluded,
                        exclusionReason: .accountTotalAlreadyIncludesComponents,
                        identitySuffix: "cash|\(cash.verificationID)"
                    ))
                }
                for holding in snapshot.holdings {
                    components.append(try FinanceNetWorthComponent(
                        kind: .investmentHoldings,
                        accountID: snapshot.source.accountID,
                        source: snapshot.source.provider.rawValue,
                        observedAt: snapshot.observedAt,
                        amountEUR: nil,
                        status: .excluded,
                        exclusionReason: .accountTotalAlreadyIncludesComponents,
                        identitySuffix: "holding|\(holding.id)"
                    ))
                }
            }

            if totalCountsComponents { continue }
            for holding in snapshot.holdings {
                if let valuation = holding.valuation {
                    if let failure = Self.valuationFreshnessFailure(
                        valuation,
                        asOf: asOf,
                        maximumObservationAge: maximumObservationAge
                    ) {
                        components.append(try FinanceNetWorthComponent(
                            kind: .investmentHoldings,
                            accountID: snapshot.source.accountID,
                            source: snapshot.source.provider.rawValue,
                            observedAt: failure.observedAt,
                            amountEUR: nil,
                            status: .excluded,
                            exclusionReason: failure.reason,
                            identitySuffix: "holding|\(holding.id)"
                        ))
                    } else {
                        components.append(try FinanceNetWorthComponent(
                            kind: .investmentHoldings,
                            accountID: snapshot.source.accountID,
                            source: snapshot.source.provider.rawValue,
                            observedAt: valuation.evidence.priceObservedAt,
                            amountEUR: valuation.eurValue.amount,
                            status: .included,
                            exclusionReason: nil,
                            identitySuffix: FinanceNetWorthIdentityKey.holding(
                                accountID: snapshot.source.accountID,
                                source: snapshot.source.provider.rawValue,
                                holdingID: holding.id
                            )
                        ))
                    }
                } else {
                    let reason: FinanceNetWorthExclusionReason = holding.assetCurrency == "EUR"
                        ? .missingHoldingValuation
                        : .missingFXEvidence
                    components.append(try FinanceNetWorthComponent(
                        kind: .investmentHoldings,
                        accountID: snapshot.source.accountID,
                        source: snapshot.source.provider.rawValue,
                        observedAt: snapshot.observedAt,
                        amountEUR: nil,
                        status: .excluded,
                        exclusionReason: reason,
                        identitySuffix: "holding|\(holding.id)"
                    ))
                }
            }
            if snapshot.cashCoverage == .complete, snapshot.verifiedCash == nil {
                components.append(try FinanceNetWorthComponent(
                    kind: .investmentCash,
                    accountID: snapshot.source.accountID,
                    source: snapshot.source.provider.rawValue,
                    observedAt: snapshot.observedAt,
                    amountEUR: try FinanceExactDecimal("0"),
                    status: .included,
                    exclusionReason: nil,
                    identitySuffix: FinanceNetWorthIdentityKey.cash(
                        kind: .investmentCash,
                        accountID: snapshot.source.accountID,
                        source: snapshot.source.provider.rawValue,
                        consolidationKey: nil
                    )
                ))
            }
            if let cash = snapshot.verifiedCash {
                if let reason = Self.freshnessReason(
                    cash.observedAt,
                    asOf: asOf,
                    maximumObservationAge: maximumObservationAge
                ) {
                    components.append(try FinanceNetWorthComponent(
                        kind: .investmentCash,
                        accountID: snapshot.source.accountID,
                        source: snapshot.source.provider.rawValue,
                        observedAt: cash.observedAt,
                        amountEUR: nil,
                        status: .excluded,
                        exclusionReason: reason,
                        identitySuffix: "cash|\(cash.verificationID)"
                    ))
                } else {
                    cashCandidates.append(FinanceCashCandidate(
                        kind: .investmentCash,
                        accountID: snapshot.source.accountID,
                        source: snapshot.source.provider.rawValue,
                        amount: cash.amount,
                        observedAt: cash.observedAt,
                        aggregationKey: cash.consolidationKey ?? "investment|\(snapshot.source.stableKey)",
                        verificationID: cash.verificationID,
                        identityKey: FinanceNetWorthIdentityKey.cash(
                            kind: .investmentCash,
                            accountID: snapshot.source.accountID,
                            source: snapshot.source.provider.rawValue,
                            consolidationKey: cash.consolidationKey
                        )
                    ))
                }
            }
            if !hasCompleteAccountCoverage {
                components.append(try FinanceNetWorthComponent(
                    kind: .investmentAccountTotal,
                    accountID: snapshot.source.accountID,
                    source: snapshot.source.provider.rawValue,
                    observedAt: snapshot.observedAt,
                    amountEUR: nil,
                    status: .excluded,
                    exclusionReason: snapshot.totalValuation == nil
                        && snapshot.verifiedCash == nil
                        && snapshot.holdings.isEmpty
                        ? .missingValuationEvidence
                        : .incompleteAccountCoverage,
                    identitySuffix: "snapshot|coverage"
                ))
            }
        }

        let cashGroups = Dictionary(grouping: cashCandidates, by: \.aggregationKey)
        for group in cashGroups.values {
            guard let firstCandidate = group.first else { continue }
            if coveredCashKeys.contains(firstCandidate.aggregationKey) {
                for candidate in group {
                    components.append(try FinanceNetWorthComponent(
                        kind: candidate.kind,
                        accountID: candidate.accountID,
                        source: candidate.source,
                        observedAt: candidate.observedAt,
                        amountEUR: nil,
                        status: .excluded,
                        exclusionReason: .accountTotalAlreadyIncludesComponents,
                        identitySuffix: "cash|\(candidate.verificationID)"
                    ))
                }
                continue
            }
            let latestDate = group.map(\.observedAt).max()!
            let latest = group.filter { $0.observedAt == latestDate }
            let older = group.filter { $0.observedAt < latestDate }
            let first = latest[0]
            let conflicting = latest.dropFirst().contains {
                $0.amount.currency != first.amount.currency
                    || $0.amount.amount.canonicalValue != first.amount.amount.canonicalValue
            }
            if conflicting {
                for candidate in latest {
                    components.append(try FinanceNetWorthComponent(
                        kind: candidate.kind,
                        accountID: candidate.accountID,
                        source: candidate.source,
                        observedAt: candidate.observedAt,
                        amountEUR: nil,
                        status: .excluded,
                        exclusionReason: .ambiguousLinkedCash,
                        identitySuffix: "cash|\(candidate.verificationID)"
                    ))
                }
            } else if first.amount.currency == "EUR" {
                components.append(try FinanceNetWorthComponent(
                    kind: first.kind,
                    accountID: first.accountID,
                    source: first.source,
                    observedAt: first.observedAt,
                    amountEUR: first.amount.amount,
                    status: .included,
                    exclusionReason: nil,
                    identitySuffix: first.identityKey
                ))
                for duplicate in latest.dropFirst() {
                    components.append(try FinanceNetWorthComponent(
                        kind: duplicate.kind,
                        accountID: duplicate.accountID,
                        source: duplicate.source,
                        observedAt: duplicate.observedAt,
                        amountEUR: nil,
                        status: .excluded,
                        exclusionReason: .duplicateCashIdentity,
                        identitySuffix: "cash|\(duplicate.verificationID)"
                    ))
                }
            } else {
                for candidate in latest {
                    components.append(try FinanceNetWorthComponent(
                        kind: candidate.kind,
                        accountID: candidate.accountID,
                        source: candidate.source,
                        observedAt: candidate.observedAt,
                        amountEUR: nil,
                        status: .excluded,
                        exclusionReason: .unsupportedCurrency,
                        identitySuffix: "cash|\(candidate.verificationID)"
                    ))
                }
            }
            for candidate in older {
                components.append(try FinanceNetWorthComponent(
                    kind: candidate.kind,
                    accountID: candidate.accountID,
                    source: candidate.source,
                    observedAt: candidate.observedAt,
                    amountEUR: nil,
                    status: .excluded,
                    exclusionReason: .supersededSnapshot,
                    identitySuffix: "cash|\(candidate.verificationID)"
                ))
            }
        }

        for observation in latestBank.superseded {
            components.append(try FinanceNetWorthComponent(
                kind: .bankCash,
                accountID: observation.accountID,
                source: observation.source,
                observedAt: observation.observedAt,
                amountEUR: nil,
                status: .excluded,
                exclusionReason: .supersededSnapshot,
                identitySuffix: "bank|\(observation.verificationID)"
            ))
        }
        for snapshot in selectedSnapshots.superseded {
            components.append(try FinanceNetWorthComponent(
                kind: .investmentAccountTotal,
                accountID: snapshot.source.accountID,
                source: snapshot.source.provider.rawValue,
                observedAt: snapshot.observedAt,
                amountEUR: nil,
                status: .excluded,
                exclusionReason: .supersededSnapshot,
                identitySuffix: Self.snapshotIdentitySuffix(snapshot)
            ))
        }

        let activityGroups = Dictionary(grouping: activities, by: { $0.source.stableKey })
        for group in activityGroups.values {
            guard let first = group.max(by: { $0.observedAt < $1.observedAt }) else { continue }
            let sourceKey = first.source.stableKey
            components.append(try FinanceNetWorthComponent(
                kind: .investmentActivity,
                accountID: first.source.accountID,
                source: first.source.provider.rawValue,
                observedAt: first.observedAt,
                amountEUR: nil,
                status: .excluded,
                exclusionReason: validSnapshotSources.contains(sourceKey)
                    ? .activityDoesNotValueNetWorth
                    : (ambiguousSnapshotSources.contains(sourceKey) ? .ambiguousSnapshot : .missingAccountSnapshot),
                identitySuffix: "activity|\(sourceKey)"
            ))
        }

        let included = components.compactMap { component -> FinanceExactDecimal? in
            component.status == .included ? component.amountEUR : nil
        }
        let total = included.isEmpty ? nil : try FinanceExactDecimal.adding(included)
        let hasBlockingExclusion = components.contains {
            guard $0.status == .excluded else { return false }
            switch $0.exclusionReason {
            case .activityDoesNotValueNetWorth, .accountTotalAlreadyIncludesComponents,
                 .supersededSnapshot, .duplicateCashIdentity:
                return false
            case .missingHoldingValuation, .missingFXEvidence, .unsupportedCurrency,
                 .ambiguousLinkedCash, .ambiguousSnapshot, .missingAccountSnapshot,
                 .missingValuationEvidence, .incompleteAccountCoverage,
                 .staleObservation, .futureObservation:
                return true
            case nil:
                return true
            }
        }
        self.components = components.sorted { $0.id < $1.id }
        self.includedTotalEUR = total
        self.activityCount = activities.count
        self.availability = total == nil
            ? .unavailable
            : hasBlockingExclusion ? .partial : .complete
        self.asOf = asOf
        self.maximumObservationAge = maximumObservationAge
    }

    private struct FinanceCashCandidate {
        let kind: FinanceNetWorthComponentKind
        let accountID: String
        let source: String
        let amount: FinanceInvestmentMoney
        let observedAt: Date
        let aggregationKey: String
        let verificationID: String
        let identityKey: String
    }

    private static func investmentCashIdentityKey(
        for snapshot: FinanceInvestmentAccountSnapshot
    ) -> String? {
        guard let cash = snapshot.verifiedCash else { return nil }
        return FinanceNetWorthIdentityKey.cash(
            kind: .investmentCash,
            accountID: snapshot.source.accountID,
            source: snapshot.source.provider.rawValue,
            consolidationKey: cash.consolidationKey
        )
    }

    private struct ObservationSelection<Selected> {
        let selected: [Selected]
        let superseded: [Selected]
        let ambiguous: [Selected]
    }

    private static func freshnessReason(
        _ observedAt: Date,
        asOf: Date,
        maximumObservationAge: TimeInterval
    ) -> FinanceNetWorthExclusionReason? {
        if observedAt > asOf { return .futureObservation }
        if asOf.timeIntervalSince(observedAt) > maximumObservationAge { return .staleObservation }
        return nil
    }

    private static func valuationFreshnessFailure(
        _ valuation: FinanceInvestmentHoldingValuation,
        asOf: Date,
        maximumObservationAge: TimeInterval
    ) -> (reason: FinanceNetWorthExclusionReason, observedAt: Date)? {
        if let reason = freshnessReason(
            valuation.evidence.priceObservedAt,
            asOf: asOf,
            maximumObservationAge: maximumObservationAge
        ) {
            return (reason, valuation.evidence.priceObservedAt)
        }
        if let fxObservedAt = valuation.evidence.fxObservedAt,
           let reason = freshnessReason(
               fxObservedAt,
               asOf: asOf,
               maximumObservationAge: maximumObservationAge
           ) {
            return (reason, fxObservedAt)
        }
        return nil
    }

    private static func snapshotIdentitySuffix(_ snapshot: FinanceInvestmentAccountSnapshot) -> String {
        let evidence = snapshot.totalValuation?.verificationID
            ?? snapshot.verifiedCash?.verificationID
            ?? snapshot.holdings.map(\.id).joined(separator: ",")
        return "snapshot|\(snapshot.source.stableKey)|\(snapshot.observedAt.timeIntervalSinceReferenceDate)|\(evidence)"
    }

    private static func latestBankObservations(
        _ observations: [FinanceVerifiedBankCashObservation]
    ) -> ObservationSelection<FinanceVerifiedBankCashObservation> {
        let groups = Dictionary(grouping: observations, by: { "\($0.source)|\($0.accountID)" })
        var selected: [FinanceVerifiedBankCashObservation] = []
        var superseded: [FinanceVerifiedBankCashObservation] = []
        var ambiguous: [FinanceVerifiedBankCashObservation] = []
        for group in groups.values {
            guard let latestDate = group.map(\.observedAt).max() else { continue }
            let latest = group.filter { $0.observedAt == latestDate }
            let first = latest[0]
            let conflicting = latest.dropFirst().contains {
                $0.amount.currency != first.amount.currency
                    || $0.amount.amount.canonicalValue != first.amount.amount.canonicalValue
                    || $0.consolidationKey != first.consolidationKey
            }
            if conflicting {
                ambiguous.append(contentsOf: latest)
            } else {
                selected.append(first)
                superseded.append(contentsOf: latest.dropFirst())
            }
            superseded.append(contentsOf: group.filter { $0.observedAt < latestDate })
        }
        return ObservationSelection(selected: selected, superseded: superseded, ambiguous: ambiguous)
    }

    private static func latestSnapshots(
        _ snapshots: [FinanceInvestmentAccountSnapshot]
    ) -> ObservationSelection<FinanceInvestmentAccountSnapshot> {
        let groups = Dictionary(grouping: snapshots, by: { $0.source.stableKey })
        var selected: [FinanceInvestmentAccountSnapshot] = []
        var superseded: [FinanceInvestmentAccountSnapshot] = []
        var ambiguous: [FinanceInvestmentAccountSnapshot] = []
        for group in groups.values {
            guard let latestDate = group.map(\.observedAt).max() else { continue }
            let latest = group.filter { $0.observedAt == latestDate }
            let first = latest[0]
            if latest.dropFirst().contains(where: { $0 != first }) {
                ambiguous.append(contentsOf: latest)
            } else {
                selected.append(first)
                superseded.append(contentsOf: latest.dropFirst())
            }
            superseded.append(contentsOf: group.filter { $0.observedAt < latestDate })
        }
        return ObservationSelection(selected: selected, superseded: superseded, ambiguous: ambiguous)
    }
}

public struct FinanceInvestmentLedger: Codable, Equatable, Sendable {
    public let activities: [FinanceInvestmentActivity]
    public let accountSnapshots: [FinanceInvestmentAccountSnapshot]
    public let importReceipts: [FinanceInvestmentImportReceipt]

    public init(
        activities: [FinanceInvestmentActivity] = [],
        accountSnapshots: [FinanceInvestmentAccountSnapshot] = [],
        importReceipts: [FinanceInvestmentImportReceipt] = []
    ) throws {
        guard activities.count <= FinanceInvestmentContract.maximumActivityCount,
              accountSnapshots.count <= FinanceInvestmentContract.maximumSnapshotCount,
              importReceipts.count <= FinanceInvestmentContract.maximumReceiptCount else {
            throw FinanceInvestmentValidationError.tooManyItems
        }
        let ids = activities.map(\.id)
        guard Set(ids).count == ids.count else { throw FinanceInvestmentValidationError.duplicateIdentity }
        let activityIDSet = Set(ids)
        let activitiesByID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        let snapshotIDs = accountSnapshots.map {
            "\($0.source.stableKey)|\($0.observedAt.timeIntervalSinceReferenceDate)"
        }
        guard Set(snapshotIDs).count == snapshotIDs.count else {
            throw FinanceInvestmentValidationError.duplicateIdentity
        }
        let receiptIDs = importReceipts.map(\.id)
        guard Set(receiptIDs).count == receiptIDs.count else {
            throw FinanceInvestmentValidationError.duplicateIdentity
        }
        for receipt in importReceipts {
            guard receipt.activityIDs.allSatisfy({ activityIDSet.contains($0) }),
                  receipt.activityIDs.allSatisfy({ activitiesByID[$0]?.source == receipt.source }) else {
                throw FinanceInvestmentValidationError.invalidSource
            }
        }
        self.activities = activities.sorted { $0.id < $1.id }
        self.accountSnapshots = accountSnapshots.sorted {
            if $0.source.stableKey != $1.source.stableKey { return $0.source.stableKey < $1.source.stableKey }
            return $0.observedAt < $1.observedAt
        }
        self.importReceipts = importReceipts.sorted { $0.id < $1.id }
    }
}

public struct FinanceInvestmentImportReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let source: FinanceInvestmentSourceIdentity
    public let fileSHA256: String
    public let observedAt: Date
    public let dataRowCount: Int
    public let activityIDs: [String]

    public init(evidence: FinanceInvestmentImportEvidence, activities: [FinanceInvestmentActivity]) throws {
        let activityIDs = activities.map(\.id)
        guard !activities.isEmpty,
              activities.count <= FinanceInvestmentContract.maximumRows,
              evidence.dataRowCount == activities.count,
              !evidence.dataRowCount.addingReportingOverflow(evidence.blankRowsSkipped).overflow,
              evidence.dataRowCount + evidence.blankRowsSkipped <= FinanceInvestmentContract.maximumRows,
              activities.allSatisfy({ $0.source == evidence.source }),
              activityIDs.allSatisfy(FinanceInvestmentHash.isSHA256),
              Set(activityIDs).count == activityIDs.count else {
            throw FinanceInvestmentValidationError.invalidSource
        }
        self.source = evidence.source
        self.fileSHA256 = evidence.fileSHA256
        self.observedAt = evidence.observedAt
        self.dataRowCount = evidence.dataRowCount
        self.activityIDs = activityIDs.sorted()
        self.id = FinanceInvestmentHash.sha256("\(evidence.source.stableKey)|\(evidence.fileSHA256)")
    }
}

enum FinanceInvestmentHash {
    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

private func rejectFinanceInvestmentKeys(_ decoder: Decoder, _ allowed: [String]) throws {
    try rejectUnknownLifeOSKeys(decoder, allowed: Set(allowed))
}

extension FinanceInvestmentImportEvidence {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, fileSHA256, byteCount, headerFingerprint, observedAt, dataRowCount, blankRowsSkipped
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(FinanceInvestmentSourceIdentity.self, forKey: .source),
            fileSHA256: container.decode(String.self, forKey: .fileSHA256),
            byteCount: container.decode(Int.self, forKey: .byteCount),
            headerFingerprint: container.decode(String.self, forKey: .headerFingerprint),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            dataRowCount: container.decode(Int.self, forKey: .dataRowCount),
            blankRowsSkipped: container.decode(Int.self, forKey: .blankRowsSkipped)
        )
    }
}

extension FinanceInvestmentValuationEvidence {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case priceSource, priceObservedAt, fxSource, fxObservedAt, fxRate
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            priceSource: container.decode(String.self, forKey: .priceSource),
            priceObservedAt: container.decode(Date.self, forKey: .priceObservedAt),
            fxSource: container.decodeIfPresent(String.self, forKey: .fxSource),
            fxObservedAt: container.decodeIfPresent(Date.self, forKey: .fxObservedAt),
            fxRate: container.decodeIfPresent(FinanceExactDecimal.self, forKey: .fxRate)
        )
    }
}

extension FinanceInvestmentHoldingValuation {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case nativeValue, eurValue, evidence
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nativeValue: container.decode(FinanceInvestmentMoney.self, forKey: .nativeValue),
            eurValue: container.decode(FinanceInvestmentMoney.self, forKey: .eurValue),
            evidence: container.decode(FinanceInvestmentValuationEvidence.self, forKey: .evidence)
        )
    }
}

extension FinanceInvestmentHoldingObservation {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, assetIdentifier, quantity, assetCurrency, valuation
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            assetIdentifier: container.decode(String.self, forKey: .assetIdentifier),
            quantity: container.decode(FinanceExactDecimal.self, forKey: .quantity),
            assetCurrency: container.decode(String.self, forKey: .assetCurrency),
            valuation: container.decodeIfPresent(FinanceInvestmentHoldingValuation.self, forKey: .valuation)
        )
    }
}

extension FinanceInvestmentCashObservation {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case amount, observedAt, source, verificationID, consolidationKey
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            amount: container.decode(FinanceInvestmentMoney.self, forKey: .amount),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            source: container.decode(String.self, forKey: .source),
            verificationID: container.decode(String.self, forKey: .verificationID),
            consolidationKey: container.decodeIfPresent(String.self, forKey: .consolidationKey)
        )
    }
}

extension FinanceInvestmentAccountValuation {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case eurValue, observedAt, source, verificationID
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eurValue: container.decode(FinanceInvestmentMoney.self, forKey: .eurValue),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            source: container.decode(String.self, forKey: .source),
            verificationID: container.decode(String.self, forKey: .verificationID)
        )
    }
}

extension FinanceInvestmentAccountSnapshot {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, observedAt, verifiedCash, holdings, cashCoverage, holdingsCoverage, totalValuation
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requiredKeys: Set<String> = [
            CodingKeys.source.stringValue,
            CodingKeys.observedAt.stringValue,
            CodingKeys.holdings.stringValue,
            CodingKeys.cashCoverage.stringValue,
            CodingKeys.holdingsCoverage.stringValue
        ]
        guard requiredKeys.isSubset(of: Set(container.allKeys.map(\.stringValue))) else {
            throw FinanceInvestmentValidationError.invalidSnapshot
        }
        try self.init(
            source: container.decode(FinanceInvestmentSourceIdentity.self, forKey: .source),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            verifiedCash: container.decodeIfPresent(FinanceInvestmentCashObservation.self, forKey: .verifiedCash),
            holdings: container.decode([FinanceInvestmentHoldingObservation].self, forKey: .holdings),
            cashCoverage: container.decode(FinanceInvestmentAccountCoverage.self, forKey: .cashCoverage),
            holdingsCoverage: container.decode(FinanceInvestmentAccountCoverage.self, forKey: .holdingsCoverage),
            totalValuation: container.decodeIfPresent(FinanceInvestmentAccountValuation.self, forKey: .totalValuation)
        )
    }
}

extension FinanceVerifiedBankCashObservation {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case accountID, amount, observedAt, source, verificationID, consolidationKey
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(String.self, forKey: .accountID),
            amount: container.decode(FinanceInvestmentMoney.self, forKey: .amount),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            source: container.decode(String.self, forKey: .source),
            verificationID: container.decode(String.self, forKey: .verificationID),
            consolidationKey: container.decodeIfPresent(String.self, forKey: .consolidationKey)
        )
    }
}

extension FinanceNetWorthComponent {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, identityKey, coveredCashIdentityKeys, kind, accountID, source, observedAt, amountEUR, status, exclusionReason
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requiredKeys: Set<String> = [
            CodingKeys.id.stringValue,
            CodingKeys.identityKey.stringValue,
            CodingKeys.coveredCashIdentityKeys.stringValue,
            CodingKeys.kind.stringValue,
            CodingKeys.accountID.stringValue,
            CodingKeys.source.stringValue,
            CodingKeys.observedAt.stringValue,
            CodingKeys.status.stringValue
        ]
        guard requiredKeys.isSubset(of: Set(container.allKeys.map(\.stringValue))) else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        let suppliedID = try container.decode(String.self, forKey: .id).lowercased()
        guard FinanceInvestmentHash.isSHA256(suppliedID) else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        let validated = try FinanceNetWorthComponent(
            kind: container.decode(FinanceNetWorthComponentKind.self, forKey: .kind),
            accountID: container.decode(String.self, forKey: .accountID),
            source: container.decode(String.self, forKey: .source),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            amountEUR: container.decodeIfPresent(FinanceExactDecimal.self, forKey: .amountEUR),
            status: container.decode(FinanceNetWorthComponentStatus.self, forKey: .status),
            exclusionReason: container.decodeIfPresent(FinanceNetWorthExclusionReason.self, forKey: .exclusionReason),
            coveredCashIdentityKeys: container.decode([String].self, forKey: .coveredCashIdentityKeys),
            identitySuffix: container.decode(String.self, forKey: .identityKey)
        )
        guard suppliedID == validated.id else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        self = validated
    }
}

extension FinanceNetWorthBreakdown {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case components, includedTotalEUR, availability, activityCount, asOf, maximumObservationAge
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let components = try container.decode([FinanceNetWorthComponent].self, forKey: .components)
        let includedTotalEUR = try container.decodeIfPresent(FinanceExactDecimal.self, forKey: .includedTotalEUR)
        let availability = try container.decode(FinanceNetWorthAvailability.self, forKey: .availability)
        let activityCount = try container.decode(Int.self, forKey: .activityCount)
        let asOf = try container.decode(Date.self, forKey: .asOf)
        let maximumObservationAge = try container.decode(TimeInterval.self, forKey: .maximumObservationAge)
        guard components.count <= FinanceInvestmentContract.maximumActivityCount + (FinanceInvestmentContract.maximumSnapshotCount * 2),
              Set(components.map(\.id)).count == components.count,
              activityCount >= 0,
              activityCount <= FinanceInvestmentContract.maximumActivityCount,
              asOf.timeIntervalSinceReferenceDate.isFinite,
              maximumObservationAge.isFinite,
              maximumObservationAge >= 0 else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        let includedComponents = components.filter { $0.status == .included }
        guard !includedComponents.contains(where: { $0.kind == .investmentActivity }) else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        var economicKeys = Set<String>()
        var cashIdentityKeys = Set<String>()
        var coveredCashIdentityKeys = Set<String>()
        for component in includedComponents {
            let economicKey: String
            switch component.kind {
            case .bankCash, .investmentCash:
                guard cashIdentityKeys.insert(component.identityKey).inserted else {
                    throw FinanceInvestmentValidationError.duplicateIdentity
                }
                economicKey = "\(component.kind.rawValue)|\(component.accountID)|\(component.source)"
            case .investmentAccountTotal:
                for coveredCashIdentityKey in component.coveredCashIdentityKeys {
                    guard coveredCashIdentityKeys.insert(coveredCashIdentityKey).inserted else {
                        throw FinanceInvestmentValidationError.duplicateIdentity
                    }
                }
                economicKey = "\(component.kind.rawValue)|\(component.accountID)|\(component.source)"
            case .investmentHoldings:
                economicKey = "\(component.kind.rawValue)|\(component.accountID)|\(component.source)|\(component.identityKey)"
            case .investmentActivity:
                throw FinanceInvestmentValidationError.invalidNetWorth
            }
            guard economicKeys.insert(economicKey).inserted else {
                throw FinanceInvestmentValidationError.duplicateIdentity
            }
        }
        guard !includedComponents.contains(where: { component in
            switch component.kind {
            case .bankCash, .investmentCash:
                return coveredCashIdentityKeys.contains(component.identityKey)
            default:
                return false
            }
        }) else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        let totalKeys = Set(includedComponents.compactMap { component -> String? in
            component.kind == .investmentAccountTotal
                ? "\(component.accountID)|\(component.source)"
                : nil
        })
        guard !includedComponents.contains(where: { component in
            switch component.kind {
            case .bankCash, .investmentCash, .investmentHoldings:
                return totalKeys.contains("\(component.accountID)|\(component.source)")
            default:
                return false
            }
        }),
        includedComponents.allSatisfy({
            Self.freshnessReason(
                $0.observedAt,
                asOf: asOf,
                maximumObservationAge: maximumObservationAge
            ) == nil
        }) else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        let included = includedComponents.compactMap(\.amountEUR)
        let expectedTotal = included.isEmpty ? nil : try FinanceExactDecimal.adding(included)
        guard expectedTotal?.canonicalValue == includedTotalEUR?.canonicalValue else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        let blocking = components.contains {
            guard $0.status == .excluded else { return false }
            switch $0.exclusionReason {
            case .activityDoesNotValueNetWorth, .accountTotalAlreadyIncludesComponents,
                 .supersededSnapshot, .duplicateCashIdentity:
                return false
            default:
                return true
            }
        }
        let expectedAvailability: FinanceNetWorthAvailability = expectedTotal == nil
            ? .unavailable
            : blocking ? .partial : .complete
        guard availability == expectedAvailability else {
            throw FinanceInvestmentValidationError.invalidNetWorth
        }
        self.components = components.sorted { $0.id < $1.id }
        self.includedTotalEUR = includedTotalEUR
        self.availability = availability
        self.activityCount = activityCount
        self.asOf = asOf
        self.maximumObservationAge = maximumObservationAge
    }
}

extension FinanceInvestmentLedger {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case activities, accountSnapshots, importReceipts
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            activities: container.decode([FinanceInvestmentActivity].self, forKey: .activities),
            accountSnapshots: container.decode([FinanceInvestmentAccountSnapshot].self, forKey: .accountSnapshots),
            importReceipts: container.decode([FinanceInvestmentImportReceipt].self, forKey: .importReceipts)
        )
    }
}

extension FinanceInvestmentImportReceipt {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, source, fileSHA256, observedAt, dataRowCount, activityIDs
    }

    public init(from decoder: Decoder) throws {
        try rejectFinanceInvestmentKeys(decoder, CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id).lowercased()
        let source = try container.decode(FinanceInvestmentSourceIdentity.self, forKey: .source)
        let fileSHA256 = try container.decode(String.self, forKey: .fileSHA256).lowercased()
        let observedAt = try container.decode(Date.self, forKey: .observedAt)
        let dataRowCount = try container.decode(Int.self, forKey: .dataRowCount)
        let activityIDs = try container.decode([String].self, forKey: .activityIDs).map { $0.lowercased() }
        guard FinanceInvestmentHash.isSHA256(id),
              FinanceInvestmentHash.isSHA256(fileSHA256),
              id == FinanceInvestmentHash.sha256("\(source.stableKey)|\(fileSHA256)"),
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              !activityIDs.isEmpty,
              dataRowCount == activityIDs.count,
              dataRowCount <= FinanceInvestmentContract.maximumRows,
              activityIDs.count <= FinanceInvestmentContract.maximumRows,
              Set(activityIDs).count == activityIDs.count,
              activityIDs.allSatisfy(FinanceInvestmentHash.isSHA256) else {
            throw FinanceInvestmentValidationError.invalidSource
        }
        self.id = id
        self.source = source
        self.fileSHA256 = fileSHA256
        self.observedAt = observedAt
        self.dataRowCount = dataRowCount
        self.activityIDs = activityIDs.sorted()
    }
}
