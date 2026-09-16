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

public struct FinanceImportDiagnostic: Equatable, Sendable {
    public let rowNumber: Int
    public let reason: FinanceImportSkipReason

    public init(rowNumber: Int, reason: FinanceImportSkipReason) {
        self.rowNumber = max(rowNumber, 1)
        self.reason = reason
    }
}

public struct FinanceImportResult: Equatable, Sendable {
    public let transactions: [FinanceImportedTransaction]
    /// Rows present in the file (excluding the header and blank lines) that
    /// did not yield a valid date + amount and were therefore skipped.
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

    public init(
        transactions: [FinanceImportedTransaction],
        skippedRowCount: Int,
        detectedSource: FinanceImportSource,
        dataRowCount: Int? = nil,
        headerRecognized: Bool = true,
        diagnostics: [FinanceImportDiagnostic] = [],
        institutionDetection: FinanceInstitutionDetection = .unknown
    ) {
        self.transactions = transactions
        self.skippedRowCount = skippedRowCount
        self.detectedSource = detectedSource
        self.dataRowCount = max(dataRowCount ?? transactions.count + skippedRowCount, 0)
        self.headerRecognized = headerRecognized
        self.diagnostics = diagnostics
        self.institutionDetection = institutionDetection
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

    public static let maximumInputBytes = 5 * 1024 * 1024
    private static let delimiterProbeMaximumCharacters = 128 * 1024
    private static let delimiterProbeMaximumPhysicalLines = 256

    public enum Error: Swift.Error, Equatable, Sendable {
        case inputTooLarge
        case unsupportedEncoding
    }

    /// Decodes common bank-export encodings before parsing. Bank portals often
    /// emit UTF-16 with a BOM even when the file is named `.csv`.
    public static func parseCSV(data: Data) throws -> FinanceImportResult {
        guard data.count <= maximumInputBytes else { throw Error.inputTooLarge }
        for encoding in [
            String.Encoding.utf8,
            .utf16LittleEndian,
            .utf16BigEndian,
            .utf32LittleEndian,
            .utf32BigEndian
        ] {
            if let text = String(data: data, encoding: encoding) {
                return parseCSV(text)
            }
        }
        throw Error.unsupportedEncoding
    }

    /// Column header names (lowercased) recognized for each logical field.
    /// Trade Republic's own CSV export uses German headers ("Datum",
    /// "Beschreibung", "Betrag"); other exports commonly use English ones.
    private static let dateHeaders: Set<String> = Set([
        "date", "datum", "buchungsdatum", "booking date", "wertstellung", "booking_date",
        "timestamp", "datetime"
    ].map(FinanceInstitutionDetector.normalizeHeader))
    private static let amountHeaders: Set<String> = Set(["amount", "betrag", "wert", "value", "netto"]
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

        var transactions: [FinanceImportedTransaction] = []
        var skipped = 0
        var diagnostics: [FinanceImportDiagnostic] = []
        var fallbackIdentityOrdinals: [String: Int] = [:]
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
            transactions.append(
                FinanceImportedTransaction(
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
            )
        }

        let detectedSource: FinanceImportSource = candidateSource == .tradeRepublicCSV && !transactions.isEmpty
            ? .tradeRepublicCSV
            : .genericCSV
        let finalDetection = FinanceInstitutionDetector.detect(
            headers: rawHeader,
            delimiter: csvDelimiter,
            validEURRowCount: transactions.count
        )

        return FinanceImportResult(
            transactions: transactions,
            skippedRowCount: skipped,
            detectedSource: detectedSource,
            dataRowCount: dataRows.count,
            headerRecognized: true,
            diagnostics: diagnostics,
            institutionDetection: finalDetection
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
            var score = 0
            for record in records.prefix(32) {
                let row = splitRow(
                    record.raw,
                    delimiter: delimiter,
                    recordMalformed: record.isMalformed,
                    meter: &meter
                )
                if isImporterHeaderRow(row, delimiter: csvDelimiter) { score += 1 }
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
