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
