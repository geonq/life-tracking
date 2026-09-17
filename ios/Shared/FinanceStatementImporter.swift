import CryptoKit
import Foundation

// MARK: - Local, offline bank-statement CSV parsing

/// The outcome of parsing a CSV bank statement. `transactions` never contains
/// fabricated rows: every entry was derived from a source row that yielded a
/// valid date and amount. Rows that could not be parsed are counted in
/// `skippedRowCount`, never silently dropped without a trace. Diagnostics carry
/// record numbers and stable reason codes, but never raw statement contents.
public enum FinanceImportSkipReason: String, Equatable, Sendable {
    case malformedRow
    case unsupportedCurrency
    case invalidDateOrAmount
    case unrecognizedHeader
}

/// Semantic information for a duplicate identity that was rejected from an
/// import. The public skip-reason enum intentionally remains unchanged because
/// the existing SwiftUI surface has an exhaustive switch over it. Callers
/// that need to distinguish duplicate handling should inspect this property on
/// `FinanceImportDiagnostic`.
public enum FinanceImportDuplicateDisposition: String, Equatable, Sendable {
    case exactRepeat
    case conflictingProviderID
}

public struct FinanceImportDiagnostic: Equatable, Sendable {
    public let rowNumber: Int
    public let reason: FinanceImportSkipReason
    /// Present when a valid row was rejected because its stable imported
    /// identity was already present in this source. The compatibility
    /// `reason` is `.malformedRow` for exact repeats and
    /// `.invalidDateOrAmount` for conflicts so untouched exhaustive UI code
    /// remains source-compatible; this field is the authoritative semantic
    /// classification.
    public let duplicateDisposition: FinanceImportDuplicateDisposition?

    public init(
        rowNumber: Int,
        reason: FinanceImportSkipReason,
        duplicateDisposition: FinanceImportDuplicateDisposition? = nil
    ) {
        self.rowNumber = max(rowNumber, 1)
        self.reason = reason
        self.duplicateDisposition = duplicateDisposition
    }
}

public struct FinanceImportResult: Equatable, Sendable {
    public let transactions: [FinanceImportedTransaction]
    /// Rows present in the file (excluding the header and blank lines) that
    /// were not imported because they were malformed, unsupported, invalid,
    /// or repeated observations.
    public let skippedRowCount: Int
    /// The detected source layout, used to label imported rows. `.genericCSV`
    /// when no specific known layout was recognized.
    public let detectedSource: FinanceImportSource
    /// Number of non-blank records after the selected header. This lets the
    /// import UI distinguish an empty statement from a statement whose rows
    /// were all malformed or unsupported.
    public let dataRowCount: Int
    /// Whether a date + amount header was recognized. `false` is a hard
    /// diagnostic: column order is unknown and no rows were guessed.
    public let headerRecognized: Bool
    /// Row-numbered, content-free diagnostics for skipped records.
    public let diagnostics: [FinanceImportDiagnostic]
    /// Non-persistent institution metadata. It is deliberately separate from
    /// imported transactions so detection can evolve without changing the
    /// stored transaction schema or row identity.
    public let institutionDetection: FinanceInstitutionDetection
    /// Source record numbers for valid transactions, in the same order as
    /// `transactions`. This is transient preview metadata used to create
    /// content-free local provenance and is never part of a sync record.
    public let sourceRowNumbers: [Int]

    public init(
        transactions: [FinanceImportedTransaction],
        skippedRowCount: Int,
        detectedSource: FinanceImportSource,
        dataRowCount: Int? = nil,
        headerRecognized: Bool = true,
        diagnostics: [FinanceImportDiagnostic] = [],
        institutionDetection: FinanceInstitutionDetection = .unknown,
        sourceRowNumbers: [Int] = []
    ) {
        self.transactions = transactions
        self.skippedRowCount = skippedRowCount
        self.detectedSource = detectedSource
        self.dataRowCount = max(dataRowCount ?? transactions.count + skippedRowCount, 0)
        self.headerRecognized = headerRecognized
        self.diagnostics = diagnostics
        self.institutionDetection = institutionDetection
        self.sourceRowNumbers = sourceRowNumbers
    }

    public static let empty = FinanceImportResult(
        transactions: [],
        skippedRowCount: 0,
        detectedSource: .genericCSV,
        dataRowCount: 0,
        headerRecognized: false
    )

    public var validRowCount: Int { transactions.count }
    public var investmentTransactionCount: Int { transactions.filter(\.isInvestmentOrder).count }
    public var detection: FinanceInstitutionDetection { institutionDetection }
}

/// Pure, offline CSV parser for bank statements. No network access, no
/// credentials, no fabricated data: it only ever emits rows it could
/// actually derive a date and amount for, and it never crashes on malformed
/// input — malformed rows are counted and skipped.
public enum FinanceStatementImporter {
    private struct CSVRecord {
        let raw: String
        let isMalformed: Bool
    }

    private struct CSVRow {
        let fields: [String]
        let isMalformed: Bool
    }

    private struct CSVRecoveryContext {
        let expectedColumnCount: Int
        let dateColumn: Int
        let amountColumn: Int
    }

    private enum CSVContinuationState: Equatable {
        case inQuotedField
        case afterClosingQuote
        case atFieldStart
        case inUnquotedField
        case malformed
    }

    private struct CSVRecoveryCandidate {
        let continuationState: CSVContinuationState
    }

    private struct CSVRecoveryBoundary {
        let replayIndex: Int
        let rawPrefix: String
    }

    private struct CSVScanMeter {
#if DEBUG
        var scanUnits = 0
#endif

        @inline(__always)
        mutating func record(_ units: Int = 1) {
#if DEBUG
            scanUnits += units
#endif
        }
    }

    private struct UniqueTransactionObservation {
        let transaction: FinanceImportedTransaction
        let sourceRowNumber: Int
    }

    /// Collects all valid observations before deciding which rows are safe to
    /// retain. If one stable identity has conflicting source observations, the
    /// whole identity is quarantined; accepting whichever row appeared first
    /// would make the ledger depend on export ordering.
    private struct UniqueTransactionCollector {
        private(set) var observations: [UniqueTransactionObservation] = []
        private var firstIndexByID: [UUID: Int] = [:]
        private var conflictingIDs: Set<UUID> = []

        mutating func append(_ transaction: FinanceImportedTransaction, sourceRowNumber: Int) {
            let index = observations.count
            observations.append(
                UniqueTransactionObservation(transaction: transaction, sourceRowNumber: sourceRowNumber)
            )
            guard let firstIndex = firstIndexByID[transaction.id] else {
                firstIndexByID[transaction.id] = index
                return
            }
            if !observations[firstIndex].transaction.hasSameSourceObservation(as: transaction) {
                conflictingIDs.insert(transaction.id)
            }
        }

        func finish() -> (
            transactions: [FinanceImportedTransaction],
            sourceRowNumbers: [Int],
            diagnostics: [FinanceImportDiagnostic],
            skippedCount: Int
        ) {
            var transactions: [FinanceImportedTransaction] = []
            var sourceRowNumbers: [Int] = []
            var diagnostics: [FinanceImportDiagnostic] = []
            transactions.reserveCapacity(observations.count)
            sourceRowNumbers.reserveCapacity(observations.count)

            var emittedFirstIndexByID: [UUID: Int] = [:]
            emittedFirstIndexByID.reserveCapacity(firstIndexByID.count)
            for (index, observation) in observations.enumerated() {
                let transaction = observation.transaction
                if conflictingIDs.contains(transaction.id) {
                    diagnostics.append(
                        FinanceImportDiagnostic(
                            rowNumber: observation.sourceRowNumber,
                            reason: .invalidDateOrAmount,
                            duplicateDisposition: .conflictingProviderID
                        )
                    )
                    continue
                }
                if emittedFirstIndexByID[transaction.id] == nil {
                    emittedFirstIndexByID[transaction.id] = index
                    transactions.append(transaction)
                    sourceRowNumbers.append(observation.sourceRowNumber)
                } else {
                    diagnostics.append(
                        FinanceImportDiagnostic(
                            rowNumber: observation.sourceRowNumber,
                            reason: .malformedRow,
                            duplicateDisposition: .exactRepeat
                        )
                    )
                }
            }
            return (transactions, sourceRowNumbers, diagnostics, diagnostics.count)
        }
    }

    public static let maximumInputBytes = 5 * 1024 * 1024
    private static let delimiterProbeMaximumCharacters = 128 * 1024
    private static let delimiterProbeMaximumPhysicalLines = 256

    public enum Error: Swift.Error, Equatable, Sendable {
        case inputTooLarge
        case unsupportedEncoding
    }

    private static func decodedText(from data: Data) throws -> String {
        guard data.count <= maximumInputBytes else { throw Error.inputTooLarge }
        for encoding in [
            String.Encoding.utf8,
            .utf16LittleEndian,
            .utf16BigEndian,
            .utf32LittleEndian,
            .utf32BigEndian
        ] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw Error.unsupportedEncoding
    }

    private static func appendMissingDuplicateDiagnostics(
        _ additions: [FinanceImportDiagnostic],
        to diagnostics: inout [FinanceImportDiagnostic]
    ) -> Int {
        var existingKeys = Set(diagnostics.compactMap { diagnostic -> String? in
            guard let disposition = diagnostic.duplicateDisposition else { return nil }
            return "\(diagnostic.rowNumber)|\(disposition.rawValue)"
        })
        var addedCount = 0
        for diagnostic in additions {
            guard let disposition = diagnostic.duplicateDisposition else { continue }
            let key = "\(diagnostic.rowNumber)|\(disposition.rawValue)"
            guard existingKeys.insert(key).inserted else { continue }
            diagnostics.append(diagnostic)
            addedCount += 1
        }
        return addedCount
    }

    private static func lexingText(_ text: String) -> String {
        let withoutLeadingBOM = text.hasPrefix("\u{FEFF}")
            ? String(text.dropFirst())
            : text
        return withoutLeadingBOM
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Decodes common bank-export encodings before parsing. Bank portals often
    /// emit UTF-16 with a BOM even when the file is named `.csv`.
    public static func parseCSV(data: Data) throws -> FinanceImportResult {
        return parseCSV(try decodedText(from: data))
    }

    /// Inspects a bounded file without retaining raw source text in the
    /// returned value. Header indexes and content-free detector metadata are
    /// enough for the mapping UI to request an explicit interpretation.
    internal static func inspectCSV(data: Data) throws -> FinanceImportInspection {
        let text = lexingText(try decodedText(from: data))
        var meter = CSVScanMeter()
        let delimiterCharacter = detectDelimiter(in: text, meter: &meter)
        let delimiter = FinanceCSVDelimiter(character: delimiterCharacter) ?? .comma
        let records = splitRecords(text, delimiter: delimiterCharacter, meter: &meter)
        let rows = records.map { record in
            splitRow(
                record.raw,
                delimiter: delimiterCharacter,
                recordMalformed: record.isMalformed,
                meter: &meter
            )
        }
        let recognizedHeaderIndices = rows.enumerated().compactMap { (index, row) -> Int? in
            guard isImporterHeaderRow(row, delimiter: delimiter) else { return nil }
            return index
        }
        let structuralHeaderIndices = rows.enumerated().compactMap { index, _ in
            isMappingHeaderCandidate(at: index, rows: rows, delimiter: delimiter) ? index : nil
        }
        // Prefer known or alias-recognized headers. For a completely
        // unfamiliar export, retain only structurally supported candidates;
        // this lets a real table header after an opaque preamble reach the
        // mapping editor without mistaking the preamble for the table.
        let candidateHeaderIndices = Array(
            (recognizedHeaderIndices.isEmpty ? structuralHeaderIndices : recognizedHeaderIndices)
                .prefix(256)
        )
        let headerIndex = recognizedHeaderIndices.first ?? candidateHeaderIndices.first
        let rawHeader = headerIndex.map { rows[$0].fields } ?? []
        let selectedEligibility = FinanceInstitutionDetector.mappingEligibility(
            headers: rawHeader,
            delimiter: delimiter
        )
        // A marker in another unmodified record must not be hidden by choosing
        // a different header row in the mapping UI. Header-like marker rows
        // are rare in ordinary data, so this scan stays conservative by only
        // considering rows with more than one field.
        let blockedEligibility = rows.enumerated().compactMap { index, row -> FinanceImportMappingEligibility? in
            guard index != headerIndex, !row.isMalformed, row.fields.count > 1 else { return nil }
            let eligibility = FinanceInstitutionDetector.mappingEligibility(
                headers: row.fields,
                delimiter: delimiter
            )
            return eligibility.isBlocked ? eligibility : nil
        }.first
        let eligibility = blockedEligibility ?? selectedEligibility
        let dataRowCount = headerIndex.map { max(rows.count - $0 - 1, 0) } ?? max(rows.count - 1, 0)
        return try FinanceImportInspection(
            sourceDigest: FinanceImportFingerprint.bytes(data),
            byteCount: data.count,
            headerFingerprint: FinanceImportFingerprint.header(rawHeader),
            delimiter: delimiter,
            headerRecordIndex: headerIndex,
            candidateHeaderRecordIndices: candidateHeaderIndices,
            columnCount: rawHeader.count,
            dataRowCount: dataRowCount,
            originalDetection: eligibility.originalDetection,
            mappingEligibility: eligibility
        )
    }

    /// Returns raw header labels only to the private mapping editor. They are
    /// never part of `FinanceImportInspection` or durable provenance.
    internal static func headerColumnNames(
        data: Data,
        inspection: FinanceImportInspection
    ) throws -> [String] {
        guard let headerIndex = inspection.headerRecordIndex else { return [] }
        guard let candidate = try headerCandidates(data: data, inspection: inspection)
            .first(where: { $0.recordIndex == headerIndex }) else {
            throw FinanceImportMappingError.missingHeader
        }
        return candidate.labels
    }

    /// Returns bounded raw labels for each candidate header. The labels are
    /// transient UI input only; callers must persist the fingerprint and
    /// selected index, never this value.
    internal static func headerCandidates(
        data: Data,
        inspection: FinanceImportInspection
    ) throws -> [FinanceImportHeaderCandidate] {
        guard FinanceImportFingerprint.bytes(data) == inspection.sourceDigest else {
            throw FinanceImportMappingError.stalePreview
        }
        let text = lexingText(try decodedText(from: data))
        var meter = CSVScanMeter()
        let records = splitRecords(text, delimiter: inspection.delimiter.character, meter: &meter)
        var candidates: [FinanceImportHeaderCandidate] = []
        candidates.reserveCapacity(inspection.candidateHeaderRecordIndices.count)
        for recordIndex in inspection.candidateHeaderRecordIndices {
            guard records.indices.contains(recordIndex) else { throw FinanceImportMappingError.stalePreview }
            let row = splitRow(
                records[recordIndex].raw,
                delimiter: inspection.delimiter.character,
                recordMalformed: records[recordIndex].isMalformed,
                meter: &meter
            )
            guard !row.isMalformed else { throw FinanceImportMappingError.stalePreview }
            candidates.append(try FinanceImportHeaderCandidate(recordIndex: recordIndex, labels: row.fields))
        }
        return candidates
    }

    /// Creates the immutable prepared preview for an already verified profile.
    /// The source rows and IDs originate from the parser result; the view never
    /// supplies source fields to the store.
    internal static func prepareKnownImport(
        result: FinanceImportResult,
        inspection: FinanceImportInspection,
        sessionID: UUID,
        revision: Int
    ) throws -> FinancePreparedImport {
        guard inspection.mappingEligibility.state == .known,
              result.institutionDetection.isKnown,
              !result.transactions.isEmpty,
              result.sourceRowNumbers.count == result.transactions.count else {
            throw FinanceImportMappingError.invalidMapping
        }
        let batchID = UUID()
        let token = try FinanceImportPreviewToken(
            sessionID: sessionID,
            revision: revision,
            batchID: batchID,
            sourceDigest: inspection.sourceDigest
        )
        var collector = UniqueTransactionCollector()
        var skippedRowCount = result.skippedRowCount
        var diagnostics = result.diagnostics
        for (sourceRowNumber, transaction) in zip(result.sourceRowNumbers, result.transactions) {
            collector.append(transaction, sourceRowNumber: sourceRowNumber)
        }
        let unique = collector.finish()
        let addedDiagnostics = appendMissingDuplicateDiagnostics(unique.diagnostics, to: &diagnostics)
        skippedRowCount += addedDiagnostics
        diagnostics.sort { $0.rowNumber < $1.rowNumber }
        let rows = try zip(unique.sourceRowNumbers, unique.transactions).map {
            try FinancePreparedImportRow(sourceRowNumber: $0.0, transaction: $0.1)
        }
        let links = try rows.map {
            try FinanceImportRowProvenance(
                batchID: batchID,
                sourceRowNumber: $0.sourceRowNumber,
                transactionID: $0.transaction.id
            )
        }
        let batch = try FinanceImportBatchProvenance(
            id: batchID,
            importedAt: Date(),
            sourceDigest: inspection.sourceDigest,
            byteCount: inspection.byteCount,
            headerFingerprint: inspection.headerFingerprint,
            delimiter: inspection.delimiter,
            headerRecordIndex: inspection.headerRecordIndex ?? 0,
            mappingID: nil,
            originalDetection: inspection.originalDetection,
            effectiveDetection: result.institutionDetection,
            rowLinks: links
        )
        return try FinancePreparedImport(
            token: token,
            rows: rows,
            skippedRowCount: skippedRowCount,
            dataRowCount: result.dataRowCount,
            diagnostics: diagnostics,
            originalDetection: inspection.originalDetection,
            effectiveDetection: result.institutionDetection,
            mapping: nil,
            batchProvenance: batch
        )
    }

    /// Re-parses through the existing bounded CSV lexer using the user's
    /// validated column choices. No CSV text is synthesized and no legacy
    /// generic column guess participates in mapped values.
    internal static func prepareMappedImport(
        data: Data,
        mapping: FinanceImportMapping,
        sessionID: UUID,
        revision: Int
    ) throws -> FinancePreparedImport {
        try prepareMappedImport(
            data: data,
            inspection: inspectCSV(data: data),
            mapping: mapping,
            sessionID: sessionID,
            revision: revision
        )
    }

    /// Re-evaluates the original bytes before applying a mapping. A mapping is
    /// never allowed to override a disabled or near-match profile discovered
    /// from the unmodified source.
    internal static func prepareMappedImport(
        data: Data,
        inspection: FinanceImportInspection,
        mapping: FinanceImportMapping,
        sessionID: UUID,
        revision: Int
    ) throws -> FinancePreparedImport {
        try mapping.validate()
        let derivedInspection = try inspectCSV(data: data)
        guard derivedInspection == inspection else { throw FinanceImportMappingError.stalePreview }
        guard inspection.mappingEligibility.state == .requiresMapping else {
            if inspection.mappingEligibility.isBlocked { throw FinanceImportMappingError.unsupportedProfile }
            throw FinanceImportMappingError.mappingNotRequired
        }
        guard inspection.delimiter == mapping.delimiter,
              inspection.candidateHeaderRecordIndices.contains(mapping.headerRecordIndex),
              inspection.headerRecordIndex != nil else {
            throw FinanceImportMappingError.stalePreview
        }
        let text = lexingText(try decodedText(from: data))
        var meter = CSVScanMeter()
        let delimiterCharacter = mapping.delimiter.character
        let records = splitRecords(text, delimiter: delimiterCharacter, meter: &meter)
        let rows = records.map { record in
            splitRow(
                record.raw,
                delimiter: delimiterCharacter,
                recordMalformed: record.isMalformed,
                meter: &meter
            )
        }
        guard rows.indices.contains(mapping.headerRecordIndex) else { throw FinanceImportMappingError.missingHeader }
        let headerRow = rows[mapping.headerRecordIndex]
        guard !headerRow.isMalformed,
              headerRow.fields.count == mapping.columnCount,
              FinanceImportFingerprint.header(headerRow.fields) == mapping.headerFingerprint else {
            throw FinanceImportMappingError.stalePreview
        }

        let headerEligibility = FinanceInstitutionDetector.mappingEligibility(
            headers: headerRow.fields,
            delimiter: mapping.delimiter
        )
        guard !headerEligibility.isBlocked else { throw FinanceImportMappingError.unsupportedProfile }
        guard headerEligibility.state == .requiresMapping else { throw FinanceImportMappingError.mappingNotRequired }

        // Re-evaluate every unmodified header-like record before extracting
        // mapped columns. This prevents a duplicate/alternate header choice
        // from concealing a recognizable unsupported export.
        for (index, row) in rows.enumerated() where index != mapping.headerRecordIndex && !row.isMalformed && row.fields.count > 1 {
            let eligibility = FinanceInstitutionDetector.mappingEligibility(
                headers: row.fields,
                delimiter: mapping.delimiter
            )
            if eligibility.isBlocked { throw FinanceImportMappingError.unsupportedProfile }
        }

        var diagnostics: [FinanceImportDiagnostic] = []
        let dataRows = Array(rows.dropFirst(mapping.headerRecordIndex + 1))
        var fallbackOrdinals: [String: Int] = [:]
        var collector = UniqueTransactionCollector()
        let importedAt = Date()

        for (offset, row) in dataRows.enumerated() {
            let rowNumber = mapping.headerRecordIndex + 2 + offset
            guard !row.isMalformed, row.fields.count == headerRow.fields.count else {
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .malformedRow))
                continue
            }
            let fields = row.fields
            guard let bookedAt = mapping.dateFormat.parse(normalizedField(fields[mapping.dateColumn])) else {
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .invalidDateOrAmount))
                continue
            }
            guard let amountCents = mappedAmountCents(mapping.amount, fields: fields) else {
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .invalidDateOrAmount))
                continue
            }
            switch mapping.currency {
            case .constantEUR:
                break
            case .column(let index):
                let currency = normalizedField(fields[index])
                guard !currency.isEmpty, currency.caseInsensitiveCompare("EUR") == .orderedSame else {
                    diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .unsupportedCurrency))
                    continue
                }
            }
            let sourceAccountValue: String?
            if let accountColumn = mapping.account.sourceColumn {
                let rawSourceAccountValue = normalizedField(fields[accountColumn])
                guard !rawSourceAccountValue.isEmpty else {
                    diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .invalidDateOrAmount))
                    continue
                }
                // This is an opaque identity component. Keep case and
                // interior whitespace exactly as parsed; only the parser's
                // safe outer-field trimming has happened above.
                sourceAccountValue = rawSourceAccountValue
            } else {
                sourceAccountValue = nil
            }

            let description: String
            switch mapping.description {
            case .none:
                description = "Imported transaction"
            case .column(let index):
                let value = normalizedField(fields[index])
                description = value.isEmpty ? "Imported transaction" : value
            }
            let merchant = mapping.merchantColumn.map { normalizedField(fields[$0]) }
            let resolvedDescription = merchant?.isEmpty == false ? merchant! : description
            guard resolvedDescription.utf8.count <= FinanceImportedSyncRecord.maximumDescriptionBytes else {
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .invalidDateOrAmount))
                continue
            }
            let providerID = mapping.providerIDColumn.flatMap { index -> String? in
                let value = normalizedField(fields[index])
                return value.isEmpty ? nil : value
            }
            guard providerID?.utf8.count ?? 0 <= FinanceImportedSyncRecord.maximumProviderCodeBytes * 4 else {
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .invalidDateOrAmount))
                continue
            }
            let currency = "EUR"
            let identity = mappedFallbackIdentity(
                bookedAt: bookedAt,
                amountCents: amountCents,
                description: resolvedDescription,
                currency: currency,
                accountID: mapping.account.identity.id,
                sourceAccountValue: sourceAccountValue
            )
            let ordinal: Int
            if providerID != nil {
                // Provider IDs are the identity. The collector handles
                // repeated IDs after all observations are available, so no
                // mutable row field or ordinal may be folded into this key.
                ordinal = 0
            } else {
                ordinal = fallbackOrdinals[identity, default: 0]
                fallbackOrdinals[identity] = ordinal + 1
            }
            let transaction = FinanceImportedTransaction(
                id: mappedStableID(
                    providerID: providerID,
                    identity: identity,
                    accountID: mapping.account.identity.id,
                    sourceAccountValue: sourceAccountValue,
                    ordinal: ordinal
                ),
                bookedAt: bookedAt,
                amountCents: amountCents,
                description: resolvedDescription,
                source: .genericCSV,
                identityScheme: .mappedV3,
                mappedIdentity: try FinanceImportedMappedIdentity(mapping: mapping),
                importedAt: importedAt
            )
            do {
                _ = try FinanceImportedSyncRecord(validating: transaction)
            } catch {
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .invalidDateOrAmount))
                continue
            }
            collector.append(transaction, sourceRowNumber: rowNumber)
        }

        let unique = collector.finish()
        diagnostics.append(contentsOf: unique.diagnostics)
        diagnostics.sort { $0.rowNumber < $1.rowNumber }
        let originalDetection = headerEligibility.originalDetection
        let effectiveDetection = userMappedDetection(from: originalDetection, delimiter: mapping.delimiter)
        let batchID = UUID()
        let token = try FinanceImportPreviewToken(
            sessionID: sessionID,
            revision: revision,
            batchID: batchID,
            sourceDigest: FinanceImportFingerprint.bytes(data)
        )
        let preparedRows = try zip(unique.sourceRowNumbers, unique.transactions).map {
            try FinancePreparedImportRow(sourceRowNumber: $0.0, transaction: $0.1)
        }
        let links = try preparedRows.map {
            try FinanceImportRowProvenance(batchID: batchID, sourceRowNumber: $0.sourceRowNumber, transactionID: $0.transaction.id)
        }
        let batch = try FinanceImportBatchProvenance(
            id: batchID,
            importedAt: importedAt,
            sourceDigest: FinanceImportFingerprint.bytes(data),
            byteCount: data.count,
            headerFingerprint: mapping.headerFingerprint,
            delimiter: mapping.delimiter,
            headerRecordIndex: mapping.headerRecordIndex,
            mappingID: mapping.id,
            originalDetection: originalDetection,
            effectiveDetection: effectiveDetection,
            rowLinks: links
        )
        return try FinancePreparedImport(
            token: token,
            rows: preparedRows,
            skippedRowCount: diagnostics.count,
            dataRowCount: dataRows.count,
            diagnostics: diagnostics,
            originalDetection: originalDetection,
            effectiveDetection: effectiveDetection,
            mapping: mapping,
            batchProvenance: batch
        )
    }

    /// Column header names (lowercased) recognized for each logical field.
    /// Trade Republic's own CSV export uses German headers ("Datum",
    /// "Beschreibung", "Betrag"); other exports commonly use English ones.
    private static let dateHeaders: Set<String> = Set([
        "date", "datum", "buchungsdatum", "booking date", "wertstellung", "booking_date",
        "timestamp", "datetime", "posted", "posted_at", "posted on", "transaction_date",
        "transaction date", "settled_at", "settled date", "value date"
    ].map(FinanceInstitutionDetector.normalizeHeader))
    private static let amountHeaders: Set<String> = Set([
        "amount", "betrag", "wert", "value", "netto", "net amount", "debit", "credit",
        "withdrawal", "deposit", "gross amount"
    ]
        .map(FinanceInstitutionDetector.normalizeHeader))
    private static let descriptionHeaders: Set<String> = Set([
        "description", "beschreibung", "memo", "merchant", "verwendungszweck", "text", "empfänger/zahlungspflichtiger", "empfaenger"
    ].map(FinanceInstitutionDetector.normalizeHeader))
    /// Merchant-name columns, checked BEFORE the generic description column.
    /// Trade Republic's own export (23-column `name,...,description,...`
    /// layout) puts the actual merchant in `name` and leaves `description`
    /// generic ("TR Card Transaction") for card purchases, while transfers
    /// leave `name` empty and put the meaningful text in `description` (or
    /// `counterparty_name`). Preferring these columns when non-empty is what
    /// makes card-purchase rows categorizable by `FinanceCategorizer`.
    private static let merchantHeaders: Set<String> = Set(["name", "counterparty_name", "counterparty", "payee", "merchant"]
        .map(FinanceInstitutionDetector.normalizeHeader))
    private static let categoryHeaders: Set<String> = Set(["category", "kategorie", "typ", "type"]
        .map(FinanceInstitutionDetector.normalizeHeader))
    private static let typeHeaders: Set<String> = Set([
        "type", "transaction_type", "transaction type", "order_type", "order type",
        "transaktionstyp", "transaktionstyp", "buchungstyp"
    ].map(FinanceInstitutionDetector.normalizeHeader))
    private static let assetClassHeaders: Set<String> = Set([
        "asset_class", "asset class", "assetklasse", "asset", "security_type", "security type",
        "wertpapierart", "instrument_type"
    ].map(FinanceInstitutionDetector.normalizeHeader))
    private static let symbolHeaders: Set<String> = Set(["symbol", "ticker", "isin", "wkn"]
        .map(FinanceInstitutionDetector.normalizeHeader))
    private static let quantityHeaders: Set<String> = Set(["shares", "share", "quantity", "units", "anzahl", "stück", "stueck"]
        .map(FinanceInstitutionDetector.normalizeHeader))
    private static let priceHeaders: Set<String> = Set([
        "price", "unit_price", "unit price", "execution_price", "execution price", "kurs"
    ].map(FinanceInstitutionDetector.normalizeHeader))
    private static let providerCodeHeaders: Set<String> = Set([
        "mcc", "mcc_code", "mcc code", "merchant_category_code", "merchant category code",
        "category_code", "category code"
    ].map(FinanceInstitutionDetector.normalizeHeader))
    private static let currencyHeaders: Set<String> = Set(["currency", "waehrung", "währung", "curr"]
        .map(FinanceInstitutionDetector.normalizeHeader))

    // These exact, pre-detector header sets are kept solely for the UUID
    // compatibility path. Detection and display may become stricter or learn
    // aliases, but an already importable export must retain its old identity
    // inputs and therefore its old IDs.
    private static let legacyDescriptionHeaders: Set<String> = [
        "description", "beschreibung", "memo", "merchant", "verwendungszweck", "text", "empfänger/zahlungspflichtiger", "empfaenger"
    ]
    private static let legacyMerchantHeaders: Set<String> = ["name", "counterparty_name", "counterparty", "payee", "merchant"]
    private static let legacyProviderIDHeaders: Set<String> = [
        "transaction_id", "transaction id", "transactionid", "entry_reference", "entry reference",
        "reference", "referenz", "transaktions-id", "transaktionsid"
    ]
    private static let legacyAccountHeaders: Set<String> = ["account", "account_id", "konto", "kontonummer", "iban"]
    private static let legacyCurrencyHeaders: Set<String> = ["currency", "waehrung", "währung", "curr"]
    private static let legacyDateHeaders: Set<String> = [
        "date", "datum", "buchungsdatum", "booking date", "wertstellung", "booking_date",
        "timestamp", "datetime"
    ]
    private static let legacyAmountHeaders: Set<String> = ["amount", "betrag", "wert", "value", "netto"]

    public static func parseCSV(_ text: String) -> FinanceImportResult {
        var meter = CSVScanMeter()
        return parseCSV(text, meter: &meter)
    }

#if DEBUG
    internal static func parseCSVForTesting(_ text: String) -> (result: FinanceImportResult, scanUnits: Int) {
        var meter = CSVScanMeter()
        let result = parseCSV(text, meter: &meter)
        return (result: result, scanUnits: meter.scanUnits)
    }
#endif

    private static func parseCSV(_ text: String, meter: inout CSVScanMeter) -> FinanceImportResult {
        // Strip an optional text BOM before lexing. A BOM immediately before a
        // quoted first header would otherwise make the quote look like text
        // in the first field rather than an opening quote.
        let withoutLeadingBOM = text.hasPrefix("\u{FEFF}")
            ? String(text.dropFirst())
            : text
        // Swift may represent CRLF as one extended grapheme cluster. Normalize
        // line endings once so record splitting is deterministic for LF, CRLF,
        // and legacy CR exports, including multiline quoted fields.
        let lexingText = withoutLeadingBOM
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let delimiter = detectDelimiter(in: lexingText, meter: &meter)
        let records = splitRecords(lexingText, delimiter: delimiter, meter: &meter)
        guard !records.isEmpty else { return .empty }

        // Do not assume the first physical record is the header. Some bank
        // exports put a comma-separated account/preamble line before a
        // semicolon- or tab-delimited table. Choose the delimiter that
        // actually produces a recognizable date+amount header, then fall
        // back to the cheap first-line heuristic for a headerless file.
        let csvDelimiter = FinanceCSVDelimiter(character: delimiter) ?? .comma
        var rows: [CSVRow] = []
        rows.reserveCapacity(records.count)
        for record in records {
            rows.append(splitRow(
                record.raw,
                delimiter: delimiter,
                recordMalformed: record.isMalformed,
                meter: &meter
            ))
        }

        guard let headerIndex = rows.firstIndex(where: { isImporterHeaderRow($0, delimiter: csvDelimiter) }) else {
            // No recognizable header: cannot map columns, so every row is
            // reported as skipped rather than guessing column order.
            return FinanceImportResult(
                transactions: [],
                skippedRowCount: rows.count,
                detectedSource: .genericCSV,
                dataRowCount: rows.count,
                headerRecognized: false,
                diagnostics: rows.indices.map {
                    FinanceImportDiagnostic(rowNumber: $0 + 1, reason: .unrecognizedHeader)
                }
            )
        }

        let rawHeader = rows[headerIndex].fields
        let header = rawHeader.map(FinanceInstitutionDetector.normalizeHeader)
        // Preserve the pre-detector column precedence for historical files.
        // New normalization can recognize additional aliases, but it must
        // never silently replace an older matching column that was used to
        // derive a stored transaction ID.
        let legacyHeader = rawHeader.map { normalizedField($0).lowercased() }
        let legacyDateColumn = firstIndex(of: legacyDateHeaders, in: legacyHeader)
        let legacyAmountColumn = firstIndex(of: legacyAmountHeaders, in: legacyHeader)
        let preliminaryDetection = FinanceInstitutionDetector.detect(
            headers: rawHeader,
            delimiter: csvDelimiter
        )
        let dateColumn = legacyDateColumn ?? firstIndex(of: dateHeaders, in: header)
        let amountColumn = legacyAmountColumn ?? firstIndex(of: amountHeaders, in: header)
        guard let dateColumn, let amountColumn else {
            let dataRowCount = rows.count - headerIndex - 1
            let safeDataRowCount = max(dataRowCount, 0)
            return FinanceImportResult(
                transactions: [],
                skippedRowCount: safeDataRowCount,
                detectedSource: .genericCSV,
                dataRowCount: safeDataRowCount,
                diagnostics: (0..<safeDataRowCount).map {
                    FinanceImportDiagnostic(rowNumber: headerIndex + 2 + $0, reason: .unrecognizedHeader)
                },
                institutionDetection: preliminaryDetection
            )
        }
        let dataRows = Array(rows.dropFirst(headerIndex + 1))

        // Duplicate normalized headers make column selection ambiguous. Do
        // not let the generic fallback guess a column in this case.
        if preliminaryDetection.provenance.reasonCodes.contains(.duplicateNormalizedHeader) {
            return FinanceImportResult(
                transactions: [],
                skippedRowCount: dataRows.count,
                detectedSource: .genericCSV,
                dataRowCount: dataRows.count,
                headerRecognized: false,
                diagnostics: dataRows.indices.map {
                    FinanceImportDiagnostic(rowNumber: headerIndex + 2 + $0, reason: .unrecognizedHeader)
                },
                institutionDetection: preliminaryDetection
            )
        }

        // A recognized but disabled broker profile must not fall through to
        // the generic EUR default. This is especially important for USD
        // brokerage activity whose export has no EUR cash meaning.
        if preliminaryDetection.provenance.reasonCodes.contains(.disabledProfile) {
            return FinanceImportResult(
                transactions: [],
                skippedRowCount: dataRows.count,
                detectedSource: .genericCSV,
                dataRowCount: dataRows.count,
                headerRecognized: true,
                diagnostics: dataRows.indices.map {
                    FinanceImportDiagnostic(rowNumber: headerIndex + 2 + $0, reason: .unrecognizedHeader)
                },
                institutionDetection: preliminaryDetection
            )
        }
        if preliminaryDetection.provenance.reasonCodes.contains(.unsupportedNearMatch) {
            return FinanceImportResult(
                transactions: [],
                skippedRowCount: dataRows.count,
                detectedSource: .genericCSV,
                dataRowCount: dataRows.count,
                headerRecognized: true,
                diagnostics: dataRows.indices.map {
                    FinanceImportDiagnostic(rowNumber: headerIndex + 2 + $0, reason: .unrecognizedHeader)
                },
                institutionDetection: preliminaryDetection
            )
        }
        let descriptionColumn = firstIndex(of: descriptionHeaders, in: header)
        let merchantColumn = firstIndex(of: merchantHeaders, in: header)
        let categoryColumn = firstIndex(of: categoryHeaders, in: header)
        let currencyColumn = firstIndex(of: currencyHeaders, in: header)
        let providerCodeColumn = firstIndex(of: providerCodeHeaders, in: header)
        let typeColumn = firstIndex(of: typeHeaders, in: header)
        let assetClassColumn = firstIndex(of: assetClassHeaders, in: header)
        let symbolColumn = firstIndex(of: symbolHeaders, in: header)
        let quantityColumn = firstIndex(of: quantityHeaders, in: header)
        let priceColumn = firstIndex(of: priceHeaders, in: header)
        let isEnglishTradeRepublicProfile = preliminaryDetection.isKnown
            && preliminaryDetection.institution == .tradeRepublic
            && preliminaryDetection.profileID == "trade-republic-english-v1"
        let candidateSource: FinanceImportSource = preliminaryDetection.isKnown
            && preliminaryDetection.institution == .tradeRepublic
            ? .tradeRepublicCSV
            : .genericCSV
        let oldIdentitySource = historicalIdentitySource(for: rawHeader)
        let legacyDescriptionColumn = firstIndex(of: legacyDescriptionHeaders, in: legacyHeader)
        let legacyMerchantColumn = firstIndex(of: legacyMerchantHeaders, in: legacyHeader)
        let legacyProviderIDColumn = firstIndex(of: legacyProviderIDHeaders, in: legacyHeader)
        let legacyAccountColumn = firstIndex(of: legacyAccountHeaders, in: legacyHeader)
        let legacyCurrencyColumn = firstIndex(of: legacyCurrencyHeaders, in: legacyHeader)

        var skipped = 0
        var diagnostics: [FinanceImportDiagnostic] = []
        var fallbackIdentityOrdinals: [String: Int] = [:]
        var collector = UniqueTransactionCollector()
        for (offset, row) in dataRows.enumerated() {
            let rowNumber = headerIndex + 2 + offset
            guard !row.isMalformed else {
                skipped += 1
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .malformedRow))
                continue
            }
            guard row.fields.count == rawHeader.count else {
                skipped += 1
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .malformedRow))
                continue
            }
            let fields = row.fields
            let rawDate = normalizedField(fields[dateColumn])
            let rawAmount = normalizedField(fields[amountColumn])
            let currency: String
            if isEnglishTradeRepublicProfile {
                guard let currencyColumn else {
                    skipped += 1
                    diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .unsupportedCurrency))
                    continue
                }
                currency = normalizedField(fields[currencyColumn])
                guard !currency.isEmpty, currency.caseInsensitiveCompare("EUR") == .orderedSame else {
                    skipped += 1
                    diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .unsupportedCurrency))
                    continue
                }
            } else {
                // The exact enabled German legacy profiles have no currency
                // column, so their source currency is implicitly EUR.
                currency = currencyColumn.map { normalizedField(fields[$0]) } ?? "EUR"
                guard currency.isEmpty || currency.caseInsensitiveCompare("EUR") == .orderedSame else {
                    skipped += 1
                    diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .unsupportedCurrency))
                    continue
                }
            }
            guard let bookedAt = parseDate(rawDate), let amountCents = parseAmountCents(rawAmount) else {
                skipped += 1
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .invalidDateOrAmount))
                continue
            }
            let merchant = merchantColumn.map { normalizedField(fields[$0]) }
            let description = descriptionColumn.map { normalizedField(fields[$0]) }
            let category = categoryColumn.map { normalizedField(fields[$0]) }
            let providerCode = providerCodeColumn.map { normalizedField(fields[$0]) }
            let rawType = typeColumn.map { normalizedField(fields[$0]) }
            let rawAssetClass = assetClassColumn.map { normalizedField(fields[$0]) }
            let rawSymbol = symbolColumn.map { normalizedField(fields[$0]) }
            let rawQuantity = quantityColumn.map { normalizedField(fields[$0]) }
            let rawPrice = priceColumn.map { normalizedField(fields[$0]) }
            // Prefer the merchant column (e.g. TR's `name`) over the generic
            // description column, since the latter is often a non-specific
            // label like "TR Card Transaction". Falls back to description
            // (meaningful for transfers, where `name` is empty) and finally
            // to an honest placeholder if neither is present.
            let resolvedDescription: String
            if let merchant, !merchant.isEmpty {
                resolvedDescription = merchant
            } else if let description, !description.isEmpty {
                resolvedDescription = description
            } else {
                resolvedDescription = "Imported transaction"
            }
            let isInvestmentOrder = candidateSource == .tradeRepublicCSV && isInvestmentRow(
                type: rawType,
                category: category,
                assetClass: rawAssetClass,
                symbol: rawSymbol,
                quantity: rawQuantity,
                price: rawPrice
            )
            let investment: FinanceImportedInvestmentDetails? = isInvestmentOrder
                ? FinanceImportedInvestmentDetails(
                    symbol: rawSymbol,
                    assetClass: rawAssetClass,
                    quantity: normalizedQuantity(rawQuantity),
                    unitPriceCents: rawPrice.flatMap { parseAmountCents($0) },
                    tradeType: rawType,
                    currency: "EUR"
                )
                : nil
            let identity = fallbackIdentity(
                source: oldIdentitySource,
                bookedAt: bookedAt,
                amountCents: amountCents,
                description: legacyResolvedDescription(
                    merchant: legacyMerchantColumn.map { normalizedField(fields[$0]) },
                    description: legacyDescriptionColumn.map { normalizedField(fields[$0]) }
                ),
                currency: legacyCurrencyColumn.map { normalizedField(fields[$0]) } ?? "EUR",
                account: legacyAccountColumn.map { normalizedField(fields[$0]) } ?? ""
            )
            let legacyProviderID = legacyProviderIDColumn.map { normalizedField(fields[$0]) }
            let ordinal: Int
            if legacyProviderID?.isEmpty == false {
                ordinal = 0
            } else {
                ordinal = fallbackIdentityOrdinals[identity, default: 0]
                fallbackIdentityOrdinals[identity] = ordinal + 1
            }
            let transaction = FinanceImportedTransaction(
                id: stableID(source: oldIdentitySource, providerID: legacyProviderID, identity: identity, ordinal: ordinal),
                bookedAt: bookedAt,
                amountCents: amountCents,
                description: resolvedDescription,
                category: nil,
                source: candidateSource,
                sourceCategory: (category?.isEmpty == false) ? category : nil,
                providerCode: providerCode,
                kind: isInvestmentOrder ? .investmentOrder : .cash,
                investment: investment
            )
            collector.append(transaction, sourceRowNumber: rowNumber)
        }

        let unique = collector.finish()
        skipped += unique.skippedCount
        diagnostics.append(contentsOf: unique.diagnostics)
        diagnostics.sort { $0.rowNumber < $1.rowNumber }

        let detectedSource: FinanceImportSource = candidateSource == .tradeRepublicCSV && !unique.transactions.isEmpty
            ? .tradeRepublicCSV
            : .genericCSV
        let finalDetection = FinanceInstitutionDetector.detect(
            headers: rawHeader,
            delimiter: csvDelimiter,
            validEURRowCount: unique.transactions.count
        )

        return FinanceImportResult(
            transactions: unique.transactions,
            skippedRowCount: skipped,
            detectedSource: detectedSource,
            dataRowCount: dataRows.count,
            headerRecognized: true,
            diagnostics: diagnostics,
            institutionDetection: finalDetection,
            sourceRowNumbers: unique.sourceRowNumbers
        )
    }

    // MARK: - Line/row splitting

    private static func splitRecords(
        _ text: String,
        delimiter: Character,
        meter: inout CSVScanMeter
    ) -> [CSVRecord] {
        let characters = Array(text)
        let potentialClosingQuoteAfter = potentialClosingQuoteSuffix(
            in: characters,
            delimiter: delimiter,
            meter: &meter
        )
        var records: [CSVRecord] = []
        var current = ""
        var inQuotes = false
        var atFieldStart = true
        var afterClosingQuote = false
        var recordMalformed = false
        var recoveryContext: CSVRecoveryContext?
        var pendingRecoveryBoundary: CSVRecoveryBoundary?
        var didReplayAtEOF = false
        var index = 0

        func appendRecord() {
            guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                current = ""
                inQuotes = false
                atFieldStart = true
                afterClosingQuote = false
                recordMalformed = false
                pendingRecoveryBoundary = nil
                return
            }
            let raw = current
            let malformed = recordMalformed || inQuotes
            records.append(CSVRecord(raw: raw, isMalformed: malformed))
            if recoveryContext == nil, !malformed {
                recoveryContext = Self.recoveryContext(for: raw, delimiter: delimiter, meter: &meter)
            }
            current = ""
            inQuotes = false
            atFieldStart = true
            afterClosingQuote = false
            recordMalformed = false
            pendingRecoveryBoundary = nil
        }

        while true {
            while index < characters.count {
                meter.record()
                let character = characters[index]
                if inQuotes {
                    let candidate = character == "\n"
                        ? recoveredRecordCandidate(
                            in: characters,
                            after: index + 1,
                            delimiter: delimiter,
                            context: recoveryContext,
                            meter: &meter
                        )
                        : nil
                    if character == "\n", let candidate {
                        // Keep the earliest validated boundary even when a later
                        // quote could still close a legitimate multiline field.
                        // If the open record later proves malformed, replay from
                        // this boundary so the candidate and everything after it
                        // can be parsed as ordinary records.
                        if pendingRecoveryBoundary == nil {
                            pendingRecoveryBoundary = CSVRecoveryBoundary(
                                replayIndex: index + 1,
                                rawPrefix: current
                            )
                        }
                        let continuationIsMalformed = candidate.continuationState == .malformed
                        let quoteCacheExhausted = !potentialClosingQuoteAfter[index + 1]
                        if continuationIsMalformed || quoteCacheExhausted,
                           let boundary = pendingRecoveryBoundary {
                            records.append(CSVRecord(raw: boundary.rawPrefix, isMalformed: true))
                            pendingRecoveryBoundary = nil
                            current = ""
                            inQuotes = false
                            atFieldStart = true
                            afterClosingQuote = false
                            recordMalformed = false
                            index = boundary.replayIndex
                            continue
                        }
                    }
                    current.append(character)
                    if character == "\"" && inQuotes {
                        if index + 1 < characters.count {
                            meter.record()
                        }
                        if index + 1 < characters.count, characters[index + 1] == "\"" {
                            current.append(characters[index + 1])
                            index += 1
                        } else {
                            inQuotes = false
                            afterClosingQuote = true
                        }
                    }
                } else if character == "\"" {
                    current.append(character)
                    if atFieldStart {
                        inQuotes = true
                        atFieldStart = false
                        afterClosingQuote = false
                    } else {
                        recordMalformed = true
                    }
                } else if character == delimiter {
                    current.append(character)
                    atFieldStart = true
                    afterClosingQuote = false
                } else if character == "\n" {
                    appendRecord()
                } else {
                    current.append(character)
                    if afterClosingQuote && !character.isWhitespace {
                        recordMalformed = true
                    }
                    if !character.isWhitespace {
                        atFieldStart = false
                        afterClosingQuote = false
                    }
                }
                if recordMalformed, let boundary = pendingRecoveryBoundary {
                    records.append(CSVRecord(raw: boundary.rawPrefix, isMalformed: true))
                    pendingRecoveryBoundary = nil
                    current = ""
                    inQuotes = false
                    atFieldStart = true
                    afterClosingQuote = false
                    recordMalformed = false
                    index = boundary.replayIndex
                    continue
                }
                index += 1
            }

            if !didReplayAtEOF, inQuotes, let boundary = pendingRecoveryBoundary {
                // EOF can prove the open record malformed just as a later
                // character can. Preserve the boundary so valid rows after the
                // malformed prefix are replayed exactly once.
                didReplayAtEOF = true
                records.append(CSVRecord(raw: boundary.rawPrefix, isMalformed: true))
                pendingRecoveryBoundary = nil
                current = ""
                inQuotes = false
                atFieldStart = true
                afterClosingQuote = false
                recordMalformed = false
                index = boundary.replayIndex
                continue
            }
            break
        }

        appendRecord()
        return records
    }

    private static func potentialClosingQuoteSuffix(
        in characters: [Character],
        delimiter: Character,
        meter: inout CSVScanMeter
    ) -> [Bool] {
        var potentialAt = [Bool](repeating: false, count: characters.count + 1)
        var cursor = 0
        while cursor < characters.count {
            meter.record()
            guard characters[cursor] == "\"" else {
                cursor += 1
                continue
            }
            if cursor + 1 < characters.count {
                meter.record()
            }
            if cursor + 1 < characters.count, characters[cursor + 1] == "\"" {
                cursor += 2
                continue
            }
            var following = cursor + 1
            while following < characters.count {
                meter.record()
                if characters[following] == delimiter || characters[following] == "\n" {
                    potentialAt[cursor] = true
                    break
                }
                guard characters[following].isWhitespace else { break }
                following += 1
            }
            if following == characters.count {
                potentialAt[cursor] = true
            }
            cursor += 1
        }

        var suffix = [Bool](repeating: false, count: characters.count + 1)
        var hasPotential = false
        cursor = characters.count
        while cursor > 0 {
            cursor -= 1
            meter.record()
            hasPotential = hasPotential || potentialAt[cursor]
            suffix[cursor] = hasPotential
        }
        return suffix
    }

    private static func recoveryContext(
        for raw: String,
        delimiter: Character,
        meter: inout CSVScanMeter
    ) -> CSVRecoveryContext? {
        let row = splitRow(raw, delimiter: delimiter, recordMalformed: false, meter: &meter)
        guard !row.isMalformed, !row.fields.isEmpty else { return nil }

        let normalized = row.fields.map(FinanceInstitutionDetector.normalizeHeader)
        let legacy = row.fields.map { normalizedField($0).lowercased() }
        guard let dateColumn = firstIndex(of: legacyDateHeaders, in: legacy)
                ?? firstIndex(of: dateHeaders, in: normalized),
              let amountColumn = firstIndex(of: legacyAmountHeaders, in: legacy)
                ?? firstIndex(of: amountHeaders, in: normalized) else {
            return nil
        }
        return CSVRecoveryContext(
            expectedColumnCount: row.fields.count,
            dateColumn: dateColumn,
            amountColumn: amountColumn
        )
    }

    private static func recoveredRecordCandidate(
        in characters: [Character],
        after index: Int,
        delimiter: Character,
        context: CSVRecoveryContext?,
        meter: inout CSVScanMeter
    ) -> CSVRecoveryCandidate? {
        guard let context, index < characters.count else { return nil }
        var line = ""
        var cursor = index
        while cursor < characters.count {
            meter.record()
            if characters[cursor] == "\n" { break }
            line.append(characters[cursor])
            cursor += 1
        }
        let row = splitRow(line, delimiter: delimiter, recordMalformed: false, meter: &meter)
        guard !row.isMalformed else { return nil }

        guard row.fields.count == context.expectedColumnCount,
              context.dateColumn < row.fields.count,
              context.amountColumn < row.fields.count,
              parseDate(normalizedField(row.fields[context.dateColumn])) != nil,
              parseAmountCents(normalizedField(row.fields[context.amountColumn])) != nil else {
            return nil
        }
        return CSVRecoveryCandidate(
            continuationState: continuationState(
                in: characters,
                after: index,
                delimiter: delimiter,
                meter: &meter
            )
        )
    }

    private static func continuationState(
        in characters: [Character],
        after index: Int,
        delimiter: Character,
        meter: inout CSVScanMeter
    ) -> CSVContinuationState {
        var state = CSVContinuationState.inQuotedField
        var cursor = index
        while cursor < characters.count {
            meter.record()
            if characters[cursor] == "\n" { break }
            let character = characters[cursor]
            switch state {
            case .inQuotedField:
                if character == "\"" {
                    if cursor + 1 < characters.count {
                        meter.record()
                    }
                    if cursor + 1 < characters.count, characters[cursor + 1] == "\"" {
                        cursor += 2
                        continue
                    }
                    state = .afterClosingQuote
                }
            case .afterClosingQuote:
                if character == delimiter {
                    state = .atFieldStart
                } else if !character.isWhitespace {
                    return .malformed
                }
            case .atFieldStart:
                if character == "\"" {
                    state = .inQuotedField
                } else if character == delimiter {
                    state = .atFieldStart
                } else if !character.isWhitespace {
                    state = .inUnquotedField
                }
            case .inUnquotedField:
                if character == "\"" {
                    return .malformed
                } else if character == delimiter {
                    state = .atFieldStart
                }
            case .malformed:
                return .malformed
            }
            cursor += 1
        }
        return state
    }

    private static func detectDelimiter(in text: String, meter: inout CSVScanMeter) -> Character {
        let probe = delimiterProbeText(text, meter: &meter)
        let candidates: [Character] = [",", ";", "\t"]
        var headerScores: [(Character, Int)] = []
        headerScores.reserveCapacity(candidates.count)
        for delimiter in candidates {
            let csvDelimiter = FinanceCSVDelimiter(character: delimiter) ?? .comma
            let records = splitRecords(probe, delimiter: delimiter, meter: &meter)
            let probeRows = records.prefix(64).map { record in
                splitRow(
                    record.raw,
                    delimiter: delimiter,
                    recordMalformed: record.isMalformed,
                    meter: &meter
                )
            }
            var score = 0
            for (index, row) in probeRows.enumerated() {
                if isImporterHeaderRow(row, delimiter: csvDelimiter) {
                    score += 1_000
                } else if isMappingHeaderCandidate(at: index, rows: probeRows, delimiter: csvDelimiter) {
                    score += 1
                }
            }
            headerScores.append((delimiter, score))
        }
        if let best = headerScores.max(by: { lhs, rhs in lhs.1 < rhs.1 }), best.1 > 0 {
            return best.0
        }

        var firstLineStarted = false
        var semicolons = 0
        var commas = 0
        var tabs = 0
        for character in probe {
            meter.record()
            if character == "\n" {
                if firstLineStarted { break }
                continue
            }
            firstLineStarted = true
            if character == ";" {
                semicolons += 1
            } else if character == "," {
                commas += 1
            } else if character == "\t" {
                tabs += 1
            }
        }
        if tabs > semicolons && tabs > commas { return "\t" }
        return semicolons > commas ? ";" : ","
    }

    private static func delimiterProbeText(_ text: String, meter: inout CSVScanMeter) -> String {
        var probe = ""
        probe.reserveCapacity(delimiterProbeMaximumCharacters)
        var characterCount = 0
        var physicalLineCount = 0
        for character in text {
            meter.record()
            guard characterCount < delimiterProbeMaximumCharacters else { break }
            probe.append(character)
            characterCount += 1
            if character == "\n" {
                physicalLineCount += 1
                if physicalLineCount >= delimiterProbeMaximumPhysicalLines { break }
            }
        }
        return probe
    }

    /// Minimal CSV field splitter supporting double-quoted fields (with `""`
    /// as an escaped quote) so a description containing the delimiter does
    /// not corrupt column alignment.
    private static func splitRow(
        _ line: String,
        delimiter: Character,
        recordMalformed: Bool,
        meter: inout CSVScanMeter
    ) -> CSVRow {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var atFieldStart = true
        var afterClosingQuote = false
        var malformed = recordMalformed
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            meter.record()
            let char = characters[index]
            if inQuotes {
                if char == "\"" {
                    if index + 1 < characters.count {
                        meter.record()
                    }
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        current.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                        afterClosingQuote = true
                    }
                } else {
                    current.append(char)
                }
            } else if char == delimiter {
                fields.append(current)
                current = ""
                atFieldStart = true
                afterClosingQuote = false
            } else if char == "\"" {
                if atFieldStart {
                    inQuotes = true
                    atFieldStart = false
                    afterClosingQuote = false
                } else {
                    malformed = true
                }
            } else {
                if afterClosingQuote && !char.isWhitespace {
                    malformed = true
                }
                current.append(char)
                if !char.isWhitespace {
                    atFieldStart = false
                    afterClosingQuote = false
                }
            }
            index += 1
        }
        fields.append(current)
        if inQuotes { malformed = true }
        return CSVRow(fields: fields, isMalformed: malformed)
    }

    private static func normalizedField(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    private static func isImporterHeaderRow(_ row: CSVRow, delimiter: FinanceCSVDelimiter) -> Bool {
        guard !row.isMalformed, !row.fields.isEmpty else { return false }

        let normalized = row.fields.map(FinanceInstitutionDetector.normalizeHeader)
        let hasGenericDateAndAmount = firstIndex(of: dateHeaders, in: normalized) != nil
            && firstIndex(of: amountHeaders, in: normalized) != nil
        return hasGenericDateAndAmount
            || FinanceInstitutionDetector.hasImporterFingerprint(headers: row.fields, delimiter: delimiter)
            || FinanceInstitutionDetector.hasUnsupportedNearMatch(headers: row.fields, delimiter: delimiter)
    }

    /// Finds a header that the detector does not know by looking for a row of
    /// textual labels followed by a bounded sample containing both a strict
    /// date and a strict amount in different columns. This is intentionally a
    /// conservative fallback: it never parses or imports the sample row here,
    /// and the eventual mapping still has to choose every column explicitly.
    private static func isMappingHeaderCandidate(
        at index: Int,
        rows: [CSVRow],
        delimiter: FinanceCSVDelimiter
    ) -> Bool {
        guard rows.indices.contains(index), index <= 255 else { return false }
        let row = rows[index]
        guard !row.isMalformed,
              row.fields.count > 1,
              row.fields.count <= FinanceImportMapping.maximumColumnCount else { return false }
        if isImporterHeaderRow(row, delimiter: delimiter) { return true }
        guard row.fields.allSatisfy({ field in
            let value = normalizedField(field)
            return !value.isEmpty
                && value.rangeOfCharacter(from: .letters) != nil
                && parseDate(value) == nil
                && parseAmountCents(value) == nil
        }) else {
            return false
        }

        for nextRow in rows.dropFirst(index + 1).prefix(8) {
            guard !nextRow.isMalformed, nextRow.fields.count == row.fields.count else { continue }
            var hasDate = false
            var hasAmount = false
            for field in nextRow.fields {
                let value = normalizedField(field)
                if parseDate(value) != nil { hasDate = true }
                if parseAmountCents(value) != nil { hasAmount = true }
                if hasDate && hasAmount { return true }
            }
        }
        return false
    }

    private static func firstIndex(of candidates: Set<String>, in header: [String]) -> Int? {
        header.firstIndex { candidates.contains($0) }
    }

    // MARK: - Field parsing

    /// Accepts ISO (`yyyy-MM-dd`) and European day-first (`dd.MM.yyyy`,
    /// `dd/MM/yyyy`) formats. Returns `nil` (never a fabricated date) if
    /// nothing matches.
    private static func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        // Trade Republic and other exports may emit a complete ISO-8601
        // timestamp, including fractional seconds and an explicit UTC/offset
        // suffix. Keep the date-only formatters below for bank statements
        // whose dates are intentionally local calendar dates.
        if let date = iso8601FractionalFormatter.date(from: raw)
            ?? iso8601Formatter.date(from: raw) {
            return date
        }
        for formatter in dateFormatters {
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateFormatters: [DateFormatter] = {
        // Keep the timezone-less ISO timestamp used by Trade Republic's
        // `datetime` column. ISO8601DateFormatter intentionally requires an
        // explicit timezone, while this export's timestamp is a local value.
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "dd.MM.yyyy", "dd/MM/yyyy", "yyyy/MM/dd"]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
            formatter.isLenient = false
            return formatter
        }
    }()

    /// Parses a EUR amount string into signed integer cents. Supports:
    /// - European format: `.` as thousands separator, `,` as decimal
    ///   (`1.234,56`, `1 234,56`, or `-12,50`)
    /// - Plain format: `.` as decimal, no thousands separator (`1234.56`)
    /// Strips a trailing/leading `€`/`EUR` and surrounding whitespace.
    /// Returns `nil` (never a fabricated amount) if the string does not
    /// resolve to a valid decimal number.
    private static func parseAmountCents(_ raw: String) -> Int? {
        var cleaned = raw
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        var isNegative = false
        if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") {
            isNegative = true
            cleaned.removeFirst()
            cleaned.removeLast()
        } else if cleaned.hasPrefix("-") {
            isNegative = true
            cleaned.removeFirst()
        } else if cleaned.hasPrefix("+") {
            cleaned.removeFirst()
        } else if cleaned.hasSuffix("-") {
            // Some European exports use a trailing minus, e.g. `12,50-`.
            // Accept it only at the outer edge; any other misplaced sign is
            // rejected by Decimal below rather than guessed.
            isNegative = true
            cleaned.removeLast()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        let hasComma = cleaned.contains(",")
        let hasDot = cleaned.contains(".")
        var normalized: String
        if hasComma && hasDot {
            // Whichever separator occurs last is the decimal separator. This
            // handles both German `1.234,56` and English `1,234.56` exports;
            // the other separator is grouping and is removed.
            if let comma = cleaned.lastIndex(of: ","), let dot = cleaned.lastIndex(of: "."), comma > dot {
                guard validMixedSeparatorAmount(cleaned, decimalSeparator: ",", groupingSeparator: ".") else { return nil }
                normalized = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                guard validMixedSeparatorAmount(cleaned, decimalSeparator: ".", groupingSeparator: ",") else { return nil }
                normalized = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            // Only comma present: treat as the decimal separator.
            normalized = cleaned.replacingOccurrences(of: ",", with: ".")
        } else {
            // Only dot or no separator: already plain decimal.
            normalized = cleaned
        }

        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let cents = value * 100
        var rounded = Decimal()
        var mutableCents = cents
        NSDecimalRound(&rounded, &mutableCents, 0, .plain)
        // Bank exports must resolve to genuine cents. Do not silently turn a
        // value such as 12.345 into 12.35; trailing zeroes remain valid.
        guard rounded == cents else { return nil }
        let intCents = (rounded as NSDecimalNumber).intValue
        guard rounded == Decimal(intCents) else { return nil }
        return isNegative ? -abs(intCents) : intCents
    }

    private static func validMixedSeparatorAmount(_ value: String, decimalSeparator: Character, groupingSeparator: Character) -> Bool {
        let parts = value.split(separator: decimalSeparator, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 1 || parts[1].count == 2 else { return false }
        let integer = String(parts[0])
        guard !integer.isEmpty else { return false }
        let groups = integer.split(separator: groupingSeparator, omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        if groups.count == 1 { return true }
        return groups[0].count <= 3 && groups.dropFirst().allSatisfy { $0.count == 3 }
    }

    private static func normalizedQuantity(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = normalizedField(raw)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }

        let normalized: String
        if cleaned.contains(",") && cleaned.contains(".") {
            if let comma = cleaned.lastIndex(of: ","), let dot = cleaned.lastIndex(of: "."), comma > dot {
                normalized = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else {
            normalized = cleaned.replacingOccurrences(of: ",", with: ".")
        }
        guard let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), decimal >= 0 else {
            return nil
        }
        return normalizedField((decimal as NSDecimalNumber).stringValue)
    }

    private static func mappedAmountCents(
        _ amount: FinanceImportAmountSelection,
        fields: [String]
    ) -> Int? {
        switch amount.signConvention {
        case .signed:
            guard let index = amount.amountColumn, fields.indices.contains(index) else { return nil }
            return FinanceImportStrictValueParser.parseCents(
                normalizedField(fields[index]),
                format: amount.format,
                allowSign: true
            )
        case .debitCredit:
            guard let debitIndex = amount.debitColumn,
                  let creditIndex = amount.creditColumn,
                  fields.indices.contains(debitIndex), fields.indices.contains(creditIndex) else {
                return nil
            }
            let debitRaw = normalizedField(fields[debitIndex])
            let creditRaw = normalizedField(fields[creditIndex])
            guard !(debitRaw.isEmpty && creditRaw.isEmpty), debitRaw.isEmpty || creditRaw.isEmpty else {
                return nil
            }
            let debit = debitRaw.isEmpty ? 0 : FinanceImportStrictValueParser.parseCents(
                debitRaw,
                format: amount.format,
                allowSign: false
            )
            let credit = creditRaw.isEmpty ? 0 : FinanceImportStrictValueParser.parseCents(
                creditRaw,
                format: amount.format,
                allowSign: false
            )
            guard let debit, let credit, debit == 0 || credit == 0 else { return nil }
            guard credit <= FinanceImportedSyncRecord.maximumSafeCents,
                  debit <= FinanceImportedSyncRecord.maximumSafeCents,
                  credit >= 0, debit >= 0 else { return nil }
            let difference: Int
            switch amount.debitCreditConvention {
            case .debitIsNegative:
                difference = credit - debit
            case .creditIsNegative:
                difference = debit - credit
            }
            guard difference >= -FinanceImportedSyncRecord.maximumSafeCents,
                  difference <= FinanceImportedSyncRecord.maximumSafeCents else { return nil }
            return difference
        }
    }

    private static func userMappedDetection(
        from original: FinanceInstitutionDetection,
        delimiter: FinanceCSVDelimiter
    ) -> FinanceInstitutionDetection {
        let provenance = original.provenance
        return FinanceInstitutionDetection(
            state: .userMapped,
            institution: nil,
            profileID: nil,
            candidates: original.candidates,
            provenance: FinanceInstitutionDetectionProvenance(
                registryVersion: provenance.registryVersion,
                detectorVersion: provenance.detectorVersion,
                normalizationVersion: provenance.normalizationVersion,
                delimiter: delimiter,
                legacyLayoutCompatibility: false,
                reasonCodes: provenance.reasonCodes,
                evidenceCodes: provenance.evidenceCodes
            )
        )
    }

    private static func mappedFallbackIdentity(
        bookedAt: Date,
        amountCents: Int,
        description: String,
        currency: String,
        accountID: UUID,
        sourceAccountValue: String?
    ) -> String {
        [
            "lifeos-finance-mapped-v1",
            mappedComponent(String(format: "%.0f", bookedAt.timeIntervalSinceReferenceDate)),
            mappedComponent(String(amountCents)),
            mappedComponent(identityComponent(description)),
            mappedComponent(identityComponent(currency)),
            mappedComponent(accountID.uuidString.lowercased()),
            // Account values are opaque identity components. Only the field's
            // outer whitespace was removed before this function was called.
            mappedComponent(sourceAccountValue ?? "")
        ].joined(separator: "\u{1F}")
    }

    private static func mappedStableID(
        providerID: String?,
        identity: String,
        accountID: UUID,
        sourceAccountValue: String?,
        ordinal: Int
    ) -> UUID {
        let opaqueSourceAccount = sourceAccountValue ?? ""
        let sourceKey: String
        if let providerID {
                // Provider IDs are stable within the persistent mapped account.
                // Do not add date, amount, description, or an ordinal here:
                // corrected exports must address the existing ledger row.
                sourceKey = [
                    "provider",
                    mappedComponent(providerID),
                    "source-account",
                    mappedComponent(opaqueSourceAccount)
                ].joined(separator: "\u{1F}")
        } else {
            // Without a provider ID, retain deterministic multiplicity for
            // identical rows while keeping the fallback identity scoped to
            // both the persistent account and any selected source account.
            sourceKey = [
                "row",
                mappedComponent(identity),
                "source-account",
                mappedComponent(opaqueSourceAccount),
                String(ordinal)
            ].joined(separator: "\u{1F}")
        }
        let stableIdentity = [
            "lifeos-finance-mapped-v3",
            mappedComponent(accountID.uuidString.lowercased()),
            sourceKey
        ].joined(separator: "\u{1E}")
        let digest = Array(SHA256.hash(data: Data(stableIdentity.utf8)).prefix(16))
        return UUID(uuid: (
            digest[0] & 0x0f | 0x50, digest[1], digest[2], digest[3],
            digest[4] & 0x3f | 0x80, digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private static func mappedComponent(_ value: String) -> String {
        let byteCount = value.utf8.count
        return "\(byteCount):\(value)"
    }

    private static func isInvestmentRow(
        type: String?,
        category: String?,
        assetClass: String?,
        symbol: String?,
        quantity: String?,
        price: String?
    ) -> Bool {
        // Some layouts (e.g. Trade Republic's German export) only carry a
        // single "Typ" column, which column-detection claims as the CATEGORY
        // header (categoryHeaders is checked first and already contains
        // "typ"). In that case the dedicated type column is absent, so fall
        // back to the category value as the classification source — without
        // this, "Dividende"/"Zinsen" rows are invisible to the cash-income
        // check below and get misclassified as investment orders whenever
        // Symbol/Anzahl/Kurs happen to be populated too.
        let classificationRaw = type ?? category
        let typeKey = classificationRaw.map { normalizedField($0).lowercased() } ?? ""
        let cashIncomeTokens = [
            "dividend", "distribution", "interest", "dividende", "ausschüttung",
            "ausschuettung", "zins", "zinse"
        ]
        if cashIncomeTokens.contains(where: { typeKey.contains($0) }) {
            return false
        }
        let hasStructuredFields = [assetClass, symbol, quantity, price].contains {
            guard let value = $0 else { return false }
            return !normalizedField(value).isEmpty
        }
        let investmentTypeTokens = [
            "buy", "sell", "order", "etf", "stock", "share",
            "security", "securities", "wertpapier", "aktie", "aktien", "sparplan",
            "kauf", "verkauf", "dividende", "ausschüttung", "ausschuettung", "ausführung", "ausfuehrung"
        ]
        return hasStructuredFields || investmentTypeTokens.contains { typeKey.contains($0) }
    }

    private static func fallbackIdentity(
        source: FinanceImportSource,
        bookedAt: Date,
        amountCents: Int,
        description: String,
        currency: String,
        account: String
    ) -> String {
        return [
            "lifeos-finance-csv-v2",
            source.rawValue,
            String(format: "%.0f", bookedAt.timeIntervalSinceReferenceDate),
            String(amountCents),
            identityComponent(description),
            identityComponent(currency),
            identityComponent(account)
        ].joined(separator: "\u{1F}")
    }

    // Detection metadata and profile names must never enter the historical
    // UUID input. These predicates intentionally mirror the pre-detector
    // source attribution used by existing imports.
    private static func historicalIdentitySource(for header: [String]) -> FinanceImportSource {
        let normalized = header.map { normalizedField($0).lowercased() }
        let isTradeRepublicGerman = normalized.contains("betrag") && normalized.contains("datum")
        let isTradeRepublicEnglish = normalized.contains("counterparty_name")
            && normalized.contains("original_amount")
            && normalized.contains("fx_rate")
        return isTradeRepublicGerman || isTradeRepublicEnglish
            ? .tradeRepublicCSV
            : .genericCSV
    }

    private static func legacyResolvedDescription(merchant: String?, description: String?) -> String {
        if let merchant, !merchant.isEmpty { return merchant }
        if let description, !description.isEmpty { return description }
        return "Imported transaction"
    }

    private static func identityComponent(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func stableID(
        source: FinanceImportSource,
        providerID: String?,
        identity: String,
        ordinal: Int
    ) -> UUID {
        let stableIdentity = [
            "lifeos-finance-csv-v2",
            source.rawValue,
            providerID.map(identityComponent) ?? identity,
            String(ordinal)
        ].joined(separator: "\u{1E}")
        let digest = Array(SHA256.hash(data: Data(stableIdentity.utf8)).prefix(16))
        return UUID(uuid: (
            digest[0] & 0x0f | 0x50, digest[1], digest[2], digest[3],
            digest[4] & 0x3f | 0x80, digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
