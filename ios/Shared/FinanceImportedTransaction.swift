import Foundation

// MARK: - Manually imported bank-statement transactions

/// Where a `FinanceImportedTransaction` came from. This is a manual-import
/// provenance tag, distinct from `FinanceConnectorKind`: it never implies a
/// live connector and is always attached at parse time by
/// `FinanceStatementImporter`, never inferred later.
public enum FinanceImportSource: String, Codable, CaseIterable, Hashable, Sendable {
    case tradeRepublicCSV
    case genericCSV
}

/// A manual import row is either a cash movement or an investment order. An
/// investment order is still a cash ledger event, but it must never be
/// mistaken for a current holding or a wealth valuation.
public enum FinanceImportedTransactionKind: String, Codable, Equatable, Sendable {
    case cash
    case investmentOrder
}

/// Source fields that can be present on Trade Republic investment rows. The
/// importer keeps the source representation for quantity so no precision is
/// lost by converting it to a display-only floating-point value. A missing
/// field remains missing; it is never replaced with a holding estimate.
public struct FinanceImportedInvestmentDetails: Codable, Equatable, Sendable {
    public let symbol: String?
    public let assetClass: String?
    public let quantity: String?
    public let unitPriceCents: Int?
    public let tradeType: String?
    public let currency: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case symbol, assetClass, quantity, unitPriceCents, tradeType, currency
    }

    public init(
        symbol: String? = nil,
        assetClass: String? = nil,
        quantity: String? = nil,
        unitPriceCents: Int? = nil,
        tradeType: String? = nil,
        currency: String = "EUR"
    ) {
        self.symbol = symbol?.nilIfBlank
        self.assetClass = assetClass?.nilIfBlank
        self.quantity = quantity?.nilIfBlank
        self.unitPriceCents = unitPriceCents
        self.tradeType = tradeType?.nilIfBlank
        self.currency = currency.uppercased()
    }

    public var hasSourceFields: Bool {
        symbol != nil || assetClass != nil || quantity != nil || unitPriceCents != nil || tradeType != nil
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)),
              container.contains(.currency) else {
            throw DecodingError.dataCorruptedError(
                forKey: .currency,
                in: container,
                debugDescription: "unknown or missing investment fields"
            )
        }
        let currency = try container.decode(String.self, forKey: .currency)
        guard currency == "EUR" else {
            throw DecodingError.dataCorruptedError(
                forKey: .currency,
                in: container,
                debugDescription: "manual imported finance is EUR-only"
            )
        }
        self.init(
            symbol: try container.decodeIfPresent(String.self, forKey: .symbol),
            assetClass: try container.decodeIfPresent(String.self, forKey: .assetClass),
            quantity: try container.decodeIfPresent(String.self, forKey: .quantity),
            unitPriceCents: try container.decodeIfPresent(Int.self, forKey: .unitPriceCents),
            tradeType: try container.decodeIfPresent(String.self, forKey: .tradeType),
            currency: currency
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(assetClass, forKey: .assetClass)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(unitPriceCents, forKey: .unitPriceCents)
        try container.encode(tradeType, forKey: .tradeType)
        try container.encode(currency, forKey: .currency)
    }
}

/// A single transaction parsed from a user-selected CSV bank statement and
/// confirmed for import. Money is always integer EUR cents; the sign carries
/// direction (negative = outflow/spending, positive = inflow/income), the
/// same convention as `FinanceTransactionObservation.signedAmountCents`.
///
/// This type is deliberately separate from `FinanceTransactionObservation`:
/// it has no `FinancePayloadProvenance` (no connector, no freshness/staleness
/// concept applies to a one-time manual import) and is stored in its own
/// durable store rather than flowing through the live Finance snapshot
/// contract. Merging manually imported rows into the connector-backed ledger
/// is explicitly deferred.
public struct FinanceImportedTransaction: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The date the transaction posted, as parsed from the statement.
    public let bookedAt: Date
    /// Signed EUR cents. Negative is an outflow (spending), positive is an
    /// inflow (income). Integer only — money is never represented as a
    /// floating-point value anywhere in this type.
    public let amountCents: Int
    /// Merchant or memo text as found in the statement row.
    public let description: String
    /// Optional canonical user override. `nil` means the provider category (if
    /// present) or description should be used by the categorizer.
    public var category: String?
    /// Raw provider/CSV category, kept separately so clearing a user override
    /// restores the source category instead of losing it.
    public let sourceCategory: String?
    /// Raw provider category code (for example an MCC), retained as audit
    /// metadata. It participates in categorization precedence but not in the
    /// stable row identity, so unrelated provider enrichment cannot duplicate
    /// an existing import.
    public let providerCode: String?
    public let source: FinanceImportSource
    /// When this row was imported into LifeOS (not when it was booked).
    public let importedAt: Date
    public let kind: FinanceImportedTransactionKind
    public let investment: FinanceImportedInvestmentDetails?

    private enum CodingKeys: String, CodingKey {
        case id, bookedAt, amountCents, description, category, sourceCategory, providerCode, source, importedAt, kind, investment
    }

    public init(
        id: UUID = UUID(),
        bookedAt: Date,
        amountCents: Int,
        description: String,
        category: String? = nil,
        source: FinanceImportSource,
        importedAt: Date = .now,
        sourceCategory: String? = nil,
        providerCode: String? = nil,
        kind: FinanceImportedTransactionKind = .cash,
        investment: FinanceImportedInvestmentDetails? = nil
    ) {
        self.id = id
        self.bookedAt = bookedAt
        self.amountCents = amountCents
        self.description = description
        self.category = category
        self.sourceCategory = sourceCategory?.nilIfBlank
        self.providerCode = providerCode?.nilIfBlank
        self.source = source
        self.importedAt = importedAt
        self.kind = investment == nil ? kind : .investmentOrder
        self.investment = investment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bookedAt = try container.decode(Date.self, forKey: .bookedAt)
        amountCents = try container.decode(Int.self, forKey: .amountCents)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        sourceCategory = try container.decodeIfPresent(String.self, forKey: .sourceCategory)
        providerCode = try container.decodeIfPresent(String.self, forKey: .providerCode)
        source = try container.decode(FinanceImportSource.self, forKey: .source)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        investment = try container.decodeIfPresent(FinanceImportedInvestmentDetails.self, forKey: .investment)
        kind = try container.decodeIfPresent(FinanceImportedTransactionKind.self, forKey: .kind)
            ?? (investment == nil ? .cash : .investmentOrder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bookedAt, forKey: .bookedAt)
        try container.encode(amountCents, forKey: .amountCents)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(sourceCategory, forKey: .sourceCategory)
        try container.encodeIfPresent(providerCode, forKey: .providerCode)
        try container.encode(source, forKey: .source)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(investment, forKey: .investment)
    }

    public var isOutflow: Bool { amountCents < 0 }
    public var isInflow: Bool { amountCents > 0 }
    public var isInvestmentOrder: Bool { kind == .investmentOrder }

    /// Compares only source-observed fields. `importedAt` and the mutable
    /// LifeOS category override are intentionally excluded so a corrected
    /// re-import can reconcile the source row without erasing the user's
    /// classification or being treated as a duplicate merely because it was
    /// parsed at a different time.
    public func hasSameSourceObservation(as other: FinanceImportedTransaction) -> Bool {
        id == other.id
            && bookedAt == other.bookedAt
            && amountCents == other.amountCents
            && description == other.description
            && sourceCategory == other.sourceCategory
            && providerCode == other.providerCode
            && source == other.source
            && kind == other.kind
            && investment == other.investment
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private let financeImportedUnicodeWhitespace: Set<UInt32> = [
    0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x0085, 0x00A0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
    0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
]

private func hasNoFinanceImportedEdgeWhitespace(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first?.value,
          let last = value.unicodeScalars.last?.value else { return false }
    return !financeImportedUnicodeWhitespace.contains(first)
        && !financeImportedUnicodeWhitespace.contains(last)
}

// MARK: - Gateway-authoritative imported-finance synchronization contract

/// The wire contract is version 2. Source observations, category overrides,
/// deletion, and restore are separate operations so a stale category edit can
/// never overwrite a newer amount or description. Optional JSON fields remain
/// explicit nulls at this boundary.
private struct FinanceImportedSyncInvestment: Codable, Sendable {
    let symbol: String?
    let assetClass: String?
    let quantity: String?
    let unitPriceCents: Int?
    let tradeType: String?
    let currency: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case symbol, assetClass, quantity, unitPriceCents, tradeType, currency
    }

    init(_ details: FinanceImportedInvestmentDetails) {
        symbol = details.symbol
        assetClass = details.assetClass
        quantity = details.quantity
        unitPriceCents = details.unitPriceCents
        tradeType = details.tradeType
        currency = details.currency
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else { throw FinanceImportedSyncError.invalidResponse }
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        assetClass = try container.decodeIfPresent(String.self, forKey: .assetClass)
        quantity = try container.decodeIfPresent(String.self, forKey: .quantity)
        unitPriceCents = try container.decodeIfPresent(Int.self, forKey: .unitPriceCents)
        tradeType = try container.decodeIfPresent(String.self, forKey: .tradeType)
        currency = try container.decode(String.self, forKey: .currency)
        try validate()
    }

    var details: FinanceImportedInvestmentDetails {
        FinanceImportedInvestmentDetails(symbol: symbol, assetClass: assetClass, quantity: quantity,
                                         unitPriceCents: unitPriceCents, tradeType: tradeType, currency: currency)
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(assetClass, forKey: .assetClass)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(unitPriceCents, forKey: .unitPriceCents)
        try container.encode(tradeType, forKey: .tradeType)
        try container.encode(currency, forKey: .currency)
    }

    func validate() throws {
        guard currency == "EUR" else { throw FinanceImportedSyncError.invalidResponse }
        if let unitPriceCents {
            guard unitPriceCents != Int.min,
                  abs(unitPriceCents) <= FinanceImportedSyncRecord.maximumSafeCents else {
                throw FinanceImportedSyncError.invalidResponse
            }
        }
        try validateText(symbol, maximum: 64)
        try validateText(assetClass, maximum: 64)
        try validateText(quantity, maximum: 128)
        try validateText(tradeType, maximum: 64)
    }

    private func validateText(_ value: String?, maximum: Int) throws {
        guard let value else { return }
        guard !value.isEmpty,
              hasNoFinanceImportedEdgeWhitespace(value),
              value.utf8.count <= maximum else {
            throw FinanceImportedSyncError.invalidResponse
        }
    }
}

public struct FinanceImportedSyncRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let maximumDescriptionBytes = 512
    public static let maximumTextBytes = 128
    public static let maximumProviderCodeBytes = 64
    public static let maximumSafeCents = 9_007_199_254_740_991

    public let recordID: UUID
    /// The authority revision of the source observation. Zero is valid only
    /// while a new local write is waiting for its first authority revision.
    public let sourceRevision: Int
    public let bookedAt: Date
    public let amountCents: Int
    public let description: String
    public let categoryOverride: FinanceTransactionCategory?
    public let sourceCategory: String?
    public let providerCode: String?
    public let source: FinanceImportSource
    public let importedAt: Date
    public let kind: FinanceImportedTransactionKind
    public let investment: FinanceImportedInvestmentDetails?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case recordID, sourceRevision, bookedAt, amountCents, description, categoryOverride
        case sourceCategory, providerCode, source, importedAt, kind, investment
    }

    public init(transaction: FinanceImportedTransaction, sourceRevision: Int = 0) {
        self.recordID = transaction.id
        self.sourceRevision = sourceRevision
        self.bookedAt = transaction.bookedAt
        self.amountCents = transaction.amountCents
        self.description = transaction.description
        self.categoryOverride = transaction.category.flatMap(FinanceTransactionCategory.init(rawValue:))
        self.sourceCategory = transaction.sourceCategory
        self.providerCode = transaction.providerCode
        self.source = transaction.source
        self.importedAt = transaction.importedAt
        self.kind = transaction.kind
        self.investment = transaction.investment
    }

    public init(validating transaction: FinanceImportedTransaction, sourceRevision: Int = 0) throws {
        guard transaction.category == nil || FinanceTransactionCategory(rawValue: transaction.category!) != nil else {
            throw FinanceImportedSyncError.invalidRequest
        }
        self.init(transaction: transaction, sourceRevision: sourceRevision)
        try validate()
    }

    public init(
        recordID: UUID,
        sourceRevision: Int = 0,
        bookedAt: Date,
        amountCents: Int,
        description: String,
        categoryOverride: FinanceTransactionCategory?,
        sourceCategory: String?,
        providerCode: String?,
        source: FinanceImportSource,
        importedAt: Date,
        kind: FinanceImportedTransactionKind,
        investment: FinanceImportedInvestmentDetails?
    ) throws {
        self.recordID = recordID
        self.sourceRevision = sourceRevision
        self.bookedAt = bookedAt
        self.amountCents = amountCents
        self.description = description
        self.categoryOverride = categoryOverride
        self.sourceCategory = sourceCategory
        self.providerCode = providerCode
        self.source = source
        self.importedAt = importedAt
        self.kind = kind
        self.investment = investment
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceImportedSyncError.invalidResponse
        }
        recordID = try container.decode(UUID.self, forKey: .recordID)
        sourceRevision = try container.decode(Int.self, forKey: .sourceRevision)
        bookedAt = try container.decode(Date.self, forKey: .bookedAt)
        amountCents = try container.decode(Int.self, forKey: .amountCents)
        description = try container.decode(String.self, forKey: .description)
        let rawCategory = try container.decodeIfPresent(String.self, forKey: .categoryOverride)
        guard rawCategory == nil || FinanceTransactionCategory(rawValue: rawCategory!) != nil else {
            throw FinanceImportedSyncError.invalidResponse
        }
        categoryOverride = rawCategory.flatMap(FinanceTransactionCategory.init(rawValue:))
        sourceCategory = try container.decodeIfPresent(String.self, forKey: .sourceCategory)
        providerCode = try container.decodeIfPresent(String.self, forKey: .providerCode)
        source = try container.decode(FinanceImportSource.self, forKey: .source)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        kind = try container.decode(FinanceImportedTransactionKind.self, forKey: .kind)
        if try container.decodeNil(forKey: .investment) {
            investment = nil
        } else {
            investment = try container.decode(FinanceImportedSyncInvestment.self, forKey: .investment).details
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordID, forKey: .recordID)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(bookedAt, forKey: .bookedAt)
        try container.encode(amountCents, forKey: .amountCents)
        try container.encode(description, forKey: .description)
        try container.encode(categoryOverride?.rawValue, forKey: .categoryOverride)
        try container.encode(sourceCategory, forKey: .sourceCategory)
        try container.encode(providerCode, forKey: .providerCode)
        try container.encode(source, forKey: .source)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(kind, forKey: .kind)
        try container.encode(investment.map(FinanceImportedSyncInvestment.init), forKey: .investment)
    }

    public var transaction: FinanceImportedTransaction {
        FinanceImportedTransaction(id: recordID, bookedAt: bookedAt, amountCents: amountCents,
                                   description: description, category: categoryOverride?.rawValue,
                                   source: source, importedAt: importedAt, sourceCategory: sourceCategory,
                                   providerCode: providerCode, kind: kind, investment: investment)
    }

    public func withSourceRevision(_ revision: Int) throws -> FinanceImportedSyncRecord {
        try FinanceImportedSyncRecord(recordID: recordID, sourceRevision: revision, bookedAt: bookedAt,
                                      amountCents: amountCents, description: description,
                                      categoryOverride: categoryOverride, sourceCategory: sourceCategory,
                                      providerCode: providerCode, source: source, importedAt: importedAt,
                                      kind: kind, investment: investment)
    }

    private func validate() throws {
        guard sourceRevision >= 0, sourceRevision <= Self.maximumSafeCents,
              amountCents != Int.min, abs(amountCents) <= Self.maximumSafeCents,
              !description.isEmpty,
              hasNoFinanceImportedEdgeWhitespace(description),
              description.utf8.count <= Self.maximumDescriptionBytes else {
            throw FinanceImportedSyncError.invalidResponse
        }
        guard validateText(sourceCategory, maximum: Self.maximumTextBytes),
              validateText(providerCode, maximum: Self.maximumProviderCodeBytes),
              kind == .investmentOrder || investment == nil,
              bookedAt.timeIntervalSinceNow <= 5,
              importedAt.timeIntervalSinceNow <= 5 else {
            throw FinanceImportedSyncError.invalidResponse
        }
        if let investment { try FinanceImportedSyncInvestment(investment).validate() }
    }

    private func validateText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && hasNoFinanceImportedEdgeWhitespace(value)
            && value.utf8.count <= maximum
    }
}

/// Kept solely to decode the pre-v2 local outbox during an explicit migration.
/// It is never encodable as a v2 request.
public enum FinanceImportedCategoryOverrideAction: String, Codable, Equatable, Sendable {
    case preserve, set, clear
}

private struct FinanceImportedLegacySyncRecord: Codable, Sendable {
    let transaction: FinanceImportedTransaction

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case recordID, bookedAt, amountCents, description, categoryOverride
        case sourceCategory, providerCode, source, importedAt, kind, investment
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else { throw FinanceImportedSyncError.invalidResponse }
        let rawCategory = try container.decodeIfPresent(String.self, forKey: .categoryOverride)
        transaction = FinanceImportedTransaction(
            id: try container.decode(UUID.self, forKey: .recordID),
            bookedAt: try container.decode(Date.self, forKey: .bookedAt),
            amountCents: try container.decode(Int.self, forKey: .amountCents),
            description: try container.decode(String.self, forKey: .description),
            category: rawCategory,
            source: try container.decode(FinanceImportSource.self, forKey: .source),
            importedAt: try container.decode(Date.self, forKey: .importedAt),
            sourceCategory: try container.decodeIfPresent(String.self, forKey: .sourceCategory),
            providerCode: try container.decodeIfPresent(String.self, forKey: .providerCode),
            kind: try container.decode(FinanceImportedTransactionKind.self, forKey: .kind),
            investment: try container.decodeIfPresent(FinanceImportedInvestmentDetails.self, forKey: .investment)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transaction.id, forKey: .recordID)
        try container.encode(transaction.bookedAt, forKey: .bookedAt)
        try container.encode(transaction.amountCents, forKey: .amountCents)
        try container.encode(transaction.description, forKey: .description)
        try container.encode(transaction.category, forKey: .categoryOverride)
        try container.encode(transaction.sourceCategory, forKey: .sourceCategory)
        try container.encode(transaction.providerCode, forKey: .providerCode)
        try container.encode(transaction.source, forKey: .source)
        try container.encode(transaction.importedAt, forKey: .importedAt)
        try container.encode(transaction.kind, forKey: .kind)
        try container.encode(transaction.investment, forKey: .investment)
    }
}

public enum FinanceImportedSyncOperation: Codable, Equatable, Sendable {
    case upsert(record: FinanceImportedSyncRecord, expectedSourceRevision: Int)
    case categorySet(recordID: UUID, expectedSourceRevision: Int, categoryOverride: FinanceTransactionCategory)
    case categoryClear(recordID: UUID, expectedSourceRevision: Int)
    case delete(recordID: UUID, expectedSourceRevision: Int, deletedAt: Date)
    case restore(record: FinanceImportedSyncRecord, expectedTombstoneRevision: Int)
    case legacyUpsert(record: FinanceImportedSyncRecord, categoryOverrideAction: FinanceImportedCategoryOverrideAction)
    case legacyDelete(recordID: UUID, deletedAt: Date)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operation, record, recordID, expectedSourceRevision, categoryOverride, categoryOverrideAction, deletedAt, expectedTombstoneRevision
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let operation = try container.decodeIfPresent(String.self, forKey: .operation) else {
            throw FinanceImportedSyncError.invalidResponse
        }
        switch operation {
        case "upsert":
            if Set(container.allKeys) == Set([CodingKeys.operation, .record, .expectedSourceRevision]) {
                let record = try container.decode(FinanceImportedSyncRecord.self, forKey: .record)
                let expected = try container.decode(Int.self, forKey: .expectedSourceRevision)
                guard expected >= 0, expected <= FinanceImportedSyncRecord.maximumSafeCents,
                      record.sourceRevision == expected else { throw FinanceImportedSyncError.invalidResponse }
                self = .upsert(record: record, expectedSourceRevision: expected)
            } else if Set(container.allKeys) == Set([CodingKeys.operation, .record, .categoryOverrideAction]) {
                let legacyRecord = try container.decode(FinanceImportedLegacySyncRecord.self, forKey: .record)
                self = .legacyUpsert(
                    record: FinanceImportedSyncRecord(transaction: legacyRecord.transaction),
                    categoryOverrideAction: try container.decode(FinanceImportedCategoryOverrideAction.self, forKey: .categoryOverrideAction)
                )
            } else {
                throw FinanceImportedSyncError.invalidResponse
            }
        case "categorySet":
            guard Set(container.allKeys) == Set([CodingKeys.operation, .recordID, .expectedSourceRevision, .categoryOverride]) else { throw FinanceImportedSyncError.invalidResponse }
            let recordID = try container.decode(UUID.self, forKey: .recordID)
            let expected = try container.decode(Int.self, forKey: .expectedSourceRevision)
            guard expected >= 0, expected <= FinanceImportedSyncRecord.maximumSafeCents else { throw FinanceImportedSyncError.invalidResponse }
            self = .categorySet(recordID: recordID, expectedSourceRevision: expected,
                                categoryOverride: try container.decode(FinanceTransactionCategory.self, forKey: .categoryOverride))
        case "categoryClear":
            guard Set(container.allKeys) == Set([CodingKeys.operation, .recordID, .expectedSourceRevision]) else { throw FinanceImportedSyncError.invalidResponse }
            let recordID = try container.decode(UUID.self, forKey: .recordID)
            let expected = try container.decode(Int.self, forKey: .expectedSourceRevision)
            guard expected >= 0, expected <= FinanceImportedSyncRecord.maximumSafeCents else { throw FinanceImportedSyncError.invalidResponse }
            self = .categoryClear(recordID: recordID, expectedSourceRevision: expected)
        case "delete":
            if Set(container.allKeys) == Set([CodingKeys.operation, .recordID, .expectedSourceRevision, .deletedAt]) {
                let recordID = try container.decode(UUID.self, forKey: .recordID)
                let expected = try container.decode(Int.self, forKey: .expectedSourceRevision)
                let deletedAt = try container.decode(Date.self, forKey: .deletedAt)
                guard expected >= 0, expected <= FinanceImportedSyncRecord.maximumSafeCents,
                      deletedAt.timeIntervalSinceNow <= 5 else { throw FinanceImportedSyncError.invalidResponse }
                self = .delete(recordID: recordID, expectedSourceRevision: expected, deletedAt: deletedAt)
            } else if Set(container.allKeys) == Set([CodingKeys.operation, .recordID, .deletedAt]) {
                let recordID = try container.decode(UUID.self, forKey: .recordID)
                let deletedAt = try container.decode(Date.self, forKey: .deletedAt)
                guard deletedAt.timeIntervalSinceNow <= 5 else { throw FinanceImportedSyncError.invalidResponse }
                self = .legacyDelete(recordID: recordID, deletedAt: deletedAt)
            } else {
                throw FinanceImportedSyncError.invalidResponse
            }
        case "restore":
            guard Set(container.allKeys) == Set([CodingKeys.operation, .record, .expectedTombstoneRevision]) else { throw FinanceImportedSyncError.invalidResponse }
            let record = try container.decode(FinanceImportedSyncRecord.self, forKey: .record)
            let expected = try container.decode(Int.self, forKey: .expectedTombstoneRevision)
            guard expected > 0, expected <= FinanceImportedSyncRecord.maximumSafeCents,
                  record.sourceRevision == 0 else { throw FinanceImportedSyncError.invalidResponse }
            self = .restore(record: record, expectedTombstoneRevision: expected)
        default:
            throw FinanceImportedSyncError.invalidResponse
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsert(let record, let expected):
            guard expected >= 0, expected <= FinanceImportedSyncRecord.maximumSafeCents,
                  record.sourceRevision == expected else { throw FinanceImportedSyncError.invalidRequest }
            try container.encode("upsert", forKey: .operation)
            try container.encode(record, forKey: .record)
            try container.encode(expected, forKey: .expectedSourceRevision)
        case .categorySet(let recordID, let expected, let category):
            guard expected >= 0, expected <= FinanceImportedSyncRecord.maximumSafeCents else { throw FinanceImportedSyncError.invalidRequest }
            try container.encode("categorySet", forKey: .operation)
            try container.encode(recordID, forKey: .recordID)
            try container.encode(expected, forKey: .expectedSourceRevision)
            try container.encode(category, forKey: .categoryOverride)
        case .categoryClear(let recordID, let expected):
            guard expected >= 0, expected <= FinanceImportedSyncRecord.maximumSafeCents else { throw FinanceImportedSyncError.invalidRequest }
            try container.encode("categoryClear", forKey: .operation)
            try container.encode(recordID, forKey: .recordID)
            try container.encode(expected, forKey: .expectedSourceRevision)
        case .delete(let recordID, let expected, let deletedAt):
            guard expected >= 0, expected <= FinanceImportedSyncRecord.maximumSafeCents,
                  deletedAt.timeIntervalSinceNow <= 5 else { throw FinanceImportedSyncError.invalidRequest }
            try container.encode("delete", forKey: .operation)
            try container.encode(recordID, forKey: .recordID)
            try container.encode(expected, forKey: .expectedSourceRevision)
            try container.encode(deletedAt, forKey: .deletedAt)
        case .restore(let record, let expected):
            guard expected > 0, expected <= FinanceImportedSyncRecord.maximumSafeCents,
                  record.sourceRevision == 0 else { throw FinanceImportedSyncError.invalidRequest }
            try container.encode("restore", forKey: .operation)
            try container.encode(record, forKey: .record)
            try container.encode(expected, forKey: .expectedTombstoneRevision)
        case .legacyUpsert:
            throw FinanceImportedSyncError.invalidRequest
        case .legacyDelete:
            throw FinanceImportedSyncError.invalidRequest
        }
    }

    public var recordID: UUID {
        switch self {
        case .upsert(let record, _), .restore(let record, _), .legacyUpsert(let record, _): record.recordID
        case .categorySet(let recordID, _, _), .categoryClear(let recordID, _), .delete(let recordID, _, _): recordID
        case .legacyDelete(let recordID, _): recordID
        }
    }

    var isLegacy: Bool {
        if case .legacyUpsert = self { return true }
        if case .legacyDelete = self { return true }
        return false
    }
}

public struct FinanceImportedSyncRequest: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let maximumOperations = 512
    public static let maximumRequestBytes = 512 * 1024

    public let schemaVersion: Int
    public let baseRevision: Int
    public let operations: [FinanceImportedSyncOperation]

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, baseRevision, operations }

    public init(baseRevision: Int, operations: [FinanceImportedSyncOperation]) throws {
        guard baseRevision >= 0, baseRevision <= FinanceImportedSyncRecord.maximumSafeCents,
              operations.count <= Self.maximumOperations,
              Set(operations.map(\.recordID)).count == operations.count,
              operations.allSatisfy({ !$0.isLegacy }) else { throw FinanceImportedSyncError.invalidRequest }
        schemaVersion = Self.schemaVersion
        self.baseRevision = baseRevision
        self.operations = operations
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else { throw FinanceImportedSyncError.invalidResponse }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        baseRevision = try container.decode(Int.self, forKey: .baseRevision)
        operations = try container.decode([FinanceImportedSyncOperation].self, forKey: .operations)
        guard schemaVersion == Self.schemaVersion, baseRevision >= 0,
              baseRevision <= FinanceImportedSyncRecord.maximumSafeCents,
              operations.count <= Self.maximumOperations,
              Set(operations.map(\.recordID)).count == operations.count,
              operations.allSatisfy({ !$0.isLegacy }) else { throw FinanceImportedSyncError.invalidResponse }
    }

    public func encode(to encoder: Encoder) throws {
        guard schemaVersion == Self.schemaVersion, baseRevision >= 0,
              baseRevision <= FinanceImportedSyncRecord.maximumSafeCents,
              operations.count <= Self.maximumOperations,
              Set(operations.map(\.recordID)).count == operations.count else { throw FinanceImportedSyncError.invalidRequest }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(operations, forKey: .operations)
    }

    /// The outbox stores these exact bytes before a request is transmitted.
    /// Sorted keys make the first attempt deterministic, while later retries
    /// never call this method again for the same attempted entry.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder.lifeOS
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumRequestBytes else { throw FinanceImportedSyncError.requestTooLarge }
        return data
    }
}

public struct FinanceImportedSyncTombstone: Codable, Equatable, Sendable {
    public static let maximumSafeRevision = FinanceImportedSyncRecord.maximumSafeCents
    public let recordID: UUID
    public let revision: Int
    public let deletedAt: Date

    private enum CodingKeys: String, CodingKey, CaseIterable { case recordID, revision, deletedAt }

    public init(recordID: UUID, revision: Int, deletedAt: Date) throws {
        guard revision > 0, revision <= Self.maximumSafeRevision, deletedAt.timeIntervalSinceNow <= 5 else { throw FinanceImportedSyncError.invalidRequest }
        self.recordID = recordID
        self.revision = revision
        self.deletedAt = deletedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else { throw FinanceImportedSyncError.invalidResponse }
        recordID = try container.decode(UUID.self, forKey: .recordID)
        revision = try container.decode(Int.self, forKey: .revision)
        deletedAt = try container.decode(Date.self, forKey: .deletedAt)
        guard revision > 0, revision <= Self.maximumSafeRevision, deletedAt.timeIntervalSinceNow <= 5 else { throw FinanceImportedSyncError.invalidResponse }
    }

    public func encode(to encoder: Encoder) throws {
        guard revision > 0, revision <= Self.maximumSafeRevision, deletedAt.timeIntervalSinceNow <= 5 else { throw FinanceImportedSyncError.invalidRequest }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordID, forKey: .recordID)
        try container.encode(revision, forKey: .revision)
        try container.encode(deletedAt, forKey: .deletedAt)
    }
}

public struct FinanceImportedSyncSnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let maximumRecords = 10_000
    public static let maximumTombstones = 10_000

    public let schemaVersion: Int
    public let domain: String
    public let ledger: String
    public let authority: String
    public let revision: Int
    public let records: [FinanceImportedSyncRecord]
    public let tombstones: [FinanceImportedSyncTombstone]

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, domain, ledger, authority, revision, records, tombstones }

    public init(revision: Int, records: [FinanceImportedSyncRecord], tombstones: [FinanceImportedSyncTombstone]) throws {
        guard revision >= 0, revision <= FinanceImportedSyncRecord.maximumSafeCents,
              records.count <= Self.maximumRecords, tombstones.count <= Self.maximumTombstones,
              Set(records.map(\.recordID)).count == records.count,
              Set(tombstones.map(\.recordID)).count == tombstones.count,
              Set(records.map(\.recordID)).isDisjoint(with: tombstones.map(\.recordID)),
              tombstones.allSatisfy({ $0.revision <= revision }) else { throw FinanceImportedSyncError.invalidResponse }
        guard records.isEmpty || records.allSatisfy({ $0.sourceRevision > 0 && $0.sourceRevision <= revision }) else {
            throw FinanceImportedSyncError.invalidResponse
        }
        schemaVersion = Self.schemaVersion
        domain = "finance"
        ledger = "manual_import"
        authority = "gateway"
        self.revision = revision
        self.records = records.sorted { $0.recordID.uuidString.lowercased() < $1.recordID.uuidString.lowercased() }
        self.tombstones = tombstones.sorted { $0.recordID.uuidString.lowercased() < $1.recordID.uuidString.lowercased() }
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else { throw FinanceImportedSyncError.invalidResponse }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        domain = try container.decode(String.self, forKey: .domain)
        ledger = try container.decode(String.self, forKey: .ledger)
        authority = try container.decode(String.self, forKey: .authority)
        revision = try container.decode(Int.self, forKey: .revision)
        records = try container.decode([FinanceImportedSyncRecord].self, forKey: .records)
        tombstones = try container.decode([FinanceImportedSyncTombstone].self, forKey: .tombstones)
        guard schemaVersion == Self.schemaVersion, domain == "finance", ledger == "manual_import", authority == "gateway",
              revision >= 0, revision <= FinanceImportedSyncRecord.maximumSafeCents,
              records.count <= Self.maximumRecords, tombstones.count <= Self.maximumTombstones,
              Set(records.map(\.recordID)).count == records.count,
              Set(tombstones.map(\.recordID)).count == tombstones.count,
              Set(records.map(\.recordID)).isDisjoint(with: tombstones.map(\.recordID)),
              records.allSatisfy({ $0.sourceRevision > 0 && $0.sourceRevision <= revision }),
              tombstones.allSatisfy({ $0.revision <= revision }) else { throw FinanceImportedSyncError.invalidResponse }
    }

    public func encode(to encoder: Encoder) throws {
        guard schemaVersion == Self.schemaVersion, domain == "finance", ledger == "manual_import", authority == "gateway",
              revision >= 0, revision <= FinanceImportedSyncRecord.maximumSafeCents,
              records.count <= Self.maximumRecords, tombstones.count <= Self.maximumTombstones,
              Set(records.map(\.recordID)).count == records.count,
              Set(tombstones.map(\.recordID)).count == tombstones.count,
              Set(records.map(\.recordID)).isDisjoint(with: tombstones.map(\.recordID)),
              records.allSatisfy({ $0.sourceRevision > 0 && $0.sourceRevision <= revision }),
              tombstones.allSatisfy({ $0.revision <= revision }) else { throw FinanceImportedSyncError.invalidRequest }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(domain, forKey: .domain)
        try container.encode(ledger, forKey: .ledger)
        try container.encode(authority, forKey: .authority)
        try container.encode(revision, forKey: .revision)
        try container.encode(records, forKey: .records)
        try container.encode(tombstones, forKey: .tombstones)
    }
}

public struct FinanceImportedSyncResult: Equatable, Sendable {
    public let snapshot: FinanceImportedSyncSnapshot
    public let etag: String
    public let wasReplay: Bool

    public init(snapshot: FinanceImportedSyncSnapshot, etag: String, wasReplay: Bool = false) {
        self.snapshot = snapshot
        self.etag = etag
        self.wasReplay = wasReplay
    }
}

public enum FinanceImportedReceiptState: String, Codable, Equatable, Sendable {
    case committed
    case unknown
}

/// Proof that the gateway has seen one exact idempotency key. The receipt
/// intentionally carries only state and the gateway's global revision; it
/// never echoes the original request, fingerprint, or imported transaction.
public struct FinanceImportedCommitReceipt: Codable, Equatable, Sendable {
    public let state: FinanceImportedReceiptState
    public let revision: Int?

    private enum CodingKeys: String, CodingKey, CaseIterable { case state, revision }

    public init(state: FinanceImportedReceiptState, revision: Int?) throws {
        guard (state == .committed && revision != nil) || (state == .unknown && revision == nil),
              revision.map({ (0...FinanceImportedSyncRecord.maximumSafeCents).contains($0) }) ?? true else {
            throw FinanceImportedSyncError.invalidResponse
        }
        self.state = state
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases),
              let state = try? container.decode(FinanceImportedReceiptState.self, forKey: .state) else {
            throw FinanceImportedSyncError.invalidResponse
        }
        try self.init(state: state, revision: container.decodeIfPresent(Int.self, forKey: .revision))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(revision, forKey: .revision)
    }
}

public enum FinanceImportedSyncError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case missingIfMatch
    case missingETag
    case malformedETag
    case invalidContentType
    case invalidRevision
    case invalidIdempotencyKey
    case requestTooLarge
    case responseTooLarge
    case remoteSnapshotRewound
    case remoteSnapshotETagMismatch
    case conflict(snapshot: FinanceImportedSyncSnapshot, etag: String)
    case httpError(Int)
}
