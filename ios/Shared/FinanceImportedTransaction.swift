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
    /// Optional category, if the statement (or a future manual edit) supplies
    /// one. `nil` is honest "not categorized," not a fabricated default.
    public var category: String?
    public let source: FinanceImportSource
    /// When this row was imported into LifeOS (not when it was booked).
    public let importedAt: Date

    public init(
        id: UUID = UUID(),
        bookedAt: Date,
        amountCents: Int,
        description: String,
        category: String? = nil,
        source: FinanceImportSource,
        importedAt: Date = .now
    ) {
        self.id = id
        self.bookedAt = bookedAt
        self.amountCents = amountCents
        self.description = description
        self.category = category
        self.source = source
        self.importedAt = importedAt
    }

    public var isOutflow: Bool { amountCents < 0 }
    public var isInflow: Bool { amountCents > 0 }
}
