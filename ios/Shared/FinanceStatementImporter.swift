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

    public init(
        transactions: [FinanceImportedTransaction],
        skippedRowCount: Int,
        detectedSource: FinanceImportSource,
        dataRowCount: Int? = nil,
        headerRecognized: Bool = true,
        diagnostics: [FinanceImportDiagnostic] = []
    ) {
        self.transactions = transactions
        self.skippedRowCount = skippedRowCount
        self.detectedSource = detectedSource
        self.dataRowCount = max(dataRowCount ?? transactions.count + skippedRowCount, 0)
        self.headerRecognized = headerRecognized
        self.diagnostics = diagnostics
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
}

/// Pure, offline CSV parser for bank statements. No network access, no
/// credentials, no fabricated data: it only ever emits rows it could
/// actually derive a date and amount for, and it never crashes on malformed
/// input — malformed rows are counted and skipped.
public enum FinanceStatementImporter {
    public static let maximumInputBytes = 5 * 1024 * 1024

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
    private static let dateHeaders: Set<String> = [
        "date", "datum", "buchungsdatum", "booking date", "wertstellung", "booking_date",
        "timestamp", "datetime"
    ]
    private static let amountHeaders: Set<String> = ["amount", "betrag", "wert", "value", "netto"]
    private static let descriptionHeaders: Set<String> = [
        "description", "beschreibung", "memo", "merchant", "verwendungszweck", "text", "empfänger/zahlungspflichtiger", "empfaenger"
    ]
    /// Merchant-name columns, checked BEFORE the generic description column.
    /// Trade Republic's own export (23-column `name,...,description,...`
    /// layout) puts the actual merchant in `name` and leaves `description`
    /// generic ("TR Card Transaction") for card purchases, while transfers
    /// leave `name` empty and put the meaningful text in `description` (or
    /// `counterparty_name`). Preferring these columns when non-empty is what
    /// makes card-purchase rows categorizable by `FinanceCategorizer`.
    private static let merchantHeaders: Set<String> = ["name", "counterparty_name", "counterparty", "payee", "merchant"]
    private static let categoryHeaders: Set<String> = ["category", "kategorie", "typ", "type"]
    private static let typeHeaders: Set<String> = [
        "type", "transaction_type", "transaction type", "order_type", "order type",
        "transaktionstyp", "transaktionstyp", "buchungstyp"
    ]
    private static let assetClassHeaders: Set<String> = [
        "asset_class", "asset class", "assetklasse", "asset", "security_type", "security type",
        "wertpapierart", "instrument_type"
    ]
    private static let symbolHeaders: Set<String> = ["symbol", "ticker", "isin", "wkn"]
    private static let quantityHeaders: Set<String> = ["shares", "share", "quantity", "units", "anzahl", "stück", "stueck"]
    private static let priceHeaders: Set<String> = [
        "price", "unit_price", "unit price", "execution_price", "execution price", "kurs"
    ]
    private static let providerIDHeaders: Set<String> = [
        "transaction_id", "transaction id", "transactionid", "entry_reference", "entry reference",
        "reference", "referenz", "transaktions-id", "transaktionsid"
    ]
    private static let providerCodeHeaders: Set<String> = [
        "mcc", "mcc_code", "mcc code", "merchant_category_code", "merchant category code",
        "category_code", "category code"
    ]
    private static let accountHeaders: Set<String> = ["account", "account_id", "konto", "kontonummer", "iban"]
    private static let currencyHeaders: Set<String> = ["currency", "waehrung", "währung", "curr"]

    public static func parseCSV(_ text: String) -> FinanceImportResult {
        let records = splitRecords(text)
        guard !records.isEmpty else { return .empty }

        // Do not assume the first physical record is the header. Some bank
        // exports put a comma-separated account/preamble line before a
        // semicolon- or tab-delimited table. Choose the delimiter that
        // actually produces a recognizable date+amount header, then fall
        // back to the cheap first-line heuristic for a headerless file.
        let delimiter = detectDelimiter(in: records)
        let rows = records.map { splitRow($0, delimiter: delimiter) }

        guard let headerIndex = rows.firstIndex(where: { isHeaderRow($0) }) else {
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

        let header = rows[headerIndex].map { normalizedField($0).lowercased() }
        guard let dateColumn = firstIndex(of: dateHeaders, in: header),
              let amountColumn = firstIndex(of: amountHeaders, in: header) else {
            let dataRowCount = rows.count - headerIndex - 1
            let safeDataRowCount = max(dataRowCount, 0)
            return FinanceImportResult(
                transactions: [],
                skippedRowCount: safeDataRowCount,
                detectedSource: .genericCSV,
                dataRowCount: safeDataRowCount,
                diagnostics: (0..<safeDataRowCount).map {
                    FinanceImportDiagnostic(rowNumber: headerIndex + 2 + $0, reason: .unrecognizedHeader)
                }
            )
        }
        let descriptionColumn = firstIndex(of: descriptionHeaders, in: header)
        let merchantColumn = firstIndex(of: merchantHeaders, in: header)
        let categoryColumn = firstIndex(of: categoryHeaders, in: header)
        let providerIDColumn = firstIndex(of: providerIDHeaders, in: header)
        let accountColumn = firstIndex(of: accountHeaders, in: header)
        let currencyColumn = firstIndex(of: currencyHeaders, in: header)
        let providerCodeColumn = firstIndex(of: providerCodeHeaders, in: header)
        let typeColumn = firstIndex(of: typeHeaders, in: header)
        let assetClassColumn = firstIndex(of: assetClassHeaders, in: header)
        let symbolColumn = firstIndex(of: symbolHeaders, in: header)
        let quantityColumn = firstIndex(of: quantityHeaders, in: header)
        let priceColumn = firstIndex(of: priceHeaders, in: header)
        // Detect Trade Republic CSV by either German headers (Betrag/Datum) or
        // the characteristic English header layout (name, counterparty_name,
        // original_amount, original_currency, fx_rate, mcc_code, etc.)
        let isTradeRepublicGerman = header.contains("betrag") && header.contains("datum")
        let isTradeRepublicEnglish = header.contains("counterparty_name") && header.contains("original_amount") && header.contains("fx_rate")
        let detectedSource: FinanceImportSource = (isTradeRepublicGerman || isTradeRepublicEnglish) ? .tradeRepublicCSV : .genericCSV

        var transactions: [FinanceImportedTransaction] = []
        var skipped = 0
        var diagnostics: [FinanceImportDiagnostic] = []
        var fallbackIdentityOrdinals: [String: Int] = [:]
        let dataRows = rows[(headerIndex + 1)...]

        for (offset, row) in dataRows.enumerated() {
            let rowNumber = headerIndex + 2 + offset
            guard row.count > dateColumn, row.count > amountColumn else {
                if !row.isEmpty {
                    skipped += 1
                    diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .malformedRow))
                }
                continue
            }
            let rawDate = normalizedField(row[dateColumn])
            let rawAmount = normalizedField(row[amountColumn])
            let currency = currencyColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil } ?? "EUR"
            guard currency.isEmpty || currency.caseInsensitiveCompare("EUR") == .orderedSame else {
                skipped += 1
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .unsupportedCurrency))
                continue
            }
            guard let bookedAt = parseDate(rawDate), let amountCents = parseAmountCents(rawAmount) else {
                skipped += 1
                diagnostics.append(FinanceImportDiagnostic(rowNumber: rowNumber, reason: .invalidDateOrAmount))
                continue
            }
            let merchant = merchantColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let description = descriptionColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let category = categoryColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let providerID = providerIDColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let account = accountColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil } ?? ""
            let providerCode = providerCodeColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let rawType = typeColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let rawAssetClass = assetClassColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let rawSymbol = symbolColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let rawQuantity = quantityColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
            let rawPrice = priceColumn.flatMap { row.count > $0 ? normalizedField(row[$0]) : nil }
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
            let isInvestmentOrder = detectedSource == .tradeRepublicCSV && isInvestmentRow(
                type: rawType,
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
                source: detectedSource,
                bookedAt: bookedAt,
                amountCents: amountCents,
                description: resolvedDescription,
                currency: currency,
                account: account
            )
            let ordinal: Int
            if providerID?.isEmpty == false {
                ordinal = 0
            } else {
                ordinal = fallbackIdentityOrdinals[identity, default: 0]
                fallbackIdentityOrdinals[identity] = ordinal + 1
            }
            transactions.append(
                FinanceImportedTransaction(
                    id: stableID(source: detectedSource, providerID: providerID, identity: identity, ordinal: ordinal),
                    bookedAt: bookedAt,
                    amountCents: amountCents,
                    description: resolvedDescription,
                    category: nil,
                    source: detectedSource,
                    sourceCategory: (category?.isEmpty == false) ? category : nil,
                    providerCode: providerCode,
                    kind: isInvestmentOrder ? .investmentOrder : .cash,
                    investment: investment
                )
            )
        }

        return FinanceImportResult(
            transactions: transactions,
            skippedRowCount: skipped,
            detectedSource: detectedSource,
            dataRowCount: dataRows.count,
            headerRecognized: true,
            diagnostics: diagnostics
        )
    }

    // MARK: - Line/row splitting

    private static func splitRecords(_ text: String) -> [String] {
        let characters = Array(text)
        var records: [String] = []
        var current = ""
        var inQuotes = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                current.append(character)
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    current.append(characters[index + 1])
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if !inQuotes, character == "\n" || character == "\r" {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { records.append(current) }
                current = ""
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else {
                current.append(character)
            }
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { records.append(current) }
        return records
    }

    private static func detectDelimiter(in records: [String]) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        let headerScores = candidates.map { delimiter in
            (delimiter, records.prefix(32).reduce(into: 0) { score, record in
                if isHeaderRow(splitRow(record, delimiter: delimiter)) { score += 1 }
            })
        }
        if let best = headerScores.max(by: { lhs, rhs in lhs.1 < rhs.1 }), best.1 > 0 {
            return best.0
        }

        let firstLine = records.first ?? ""
        let semicolons = firstLine.filter { $0 == ";" }.count
        let commas = firstLine.filter { $0 == "," }.count
        let tabs = firstLine.filter { $0 == "\t" }.count
        if tabs > semicolons && tabs > commas { return "\t" }
        return semicolons > commas ? ";" : ","
    }

    /// Minimal CSV field splitter supporting double-quoted fields (with `""`
    /// as an escaped quote) so a description containing the delimiter does
    /// not corrupt column alignment.
    private static func splitRow(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    current.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if !inQuotes, char == delimiter {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }

    private static func normalizedField(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    private static func isHeaderRow(_ row: [String]) -> Bool {
        let normalized = row.map { normalizedField($0).lowercased() }
        return firstIndex(of: dateHeaders, in: normalized) != nil && firstIndex(of: amountHeaders, in: normalized) != nil
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
        assetClass: String?,
        symbol: String?,
        quantity: String?,
        price: String?
    ) -> Bool {
        let typeKey = type.map { normalizedField($0).lowercased() } ?? ""
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
