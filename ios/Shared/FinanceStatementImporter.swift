import Foundation

// MARK: - Local, offline bank-statement CSV parsing

/// The outcome of parsing a CSV bank statement. `transactions` never contains
/// fabricated rows: every entry was derived from a source row that yielded a
/// valid date and amount. Rows that could not be parsed are counted in
/// `skippedRowCount`, never silently dropped without a trace.
public struct FinanceImportResult: Equatable, Sendable {
    public let transactions: [FinanceImportedTransaction]
    /// Rows present in the file (excluding the header and blank lines) that
    /// did not yield a valid date + amount and were therefore skipped.
    public let skippedRowCount: Int
    /// The detected source layout, used to label imported rows. `.genericCSV`
    /// when no specific known layout was recognized.
    public let detectedSource: FinanceImportSource

    public init(transactions: [FinanceImportedTransaction], skippedRowCount: Int, detectedSource: FinanceImportSource) {
        self.transactions = transactions
        self.skippedRowCount = skippedRowCount
        self.detectedSource = detectedSource
    }

    public static let empty = FinanceImportResult(transactions: [], skippedRowCount: 0, detectedSource: .genericCSV)
}

/// Pure, offline CSV parser for bank statements. No network access, no
/// credentials, no fabricated data: it only ever emits rows it could
/// actually derive a date and amount for, and it never crashes on malformed
/// input — malformed rows are counted and skipped.
public enum FinanceStatementImporter {
    /// Column header names (lowercased) recognized for each logical field.
    /// Trade Republic's own CSV export uses German headers ("Datum",
    /// "Beschreibung", "Betrag"); other exports commonly use English ones.
    private static let dateHeaders: Set<String> = ["date", "datum", "buchungsdatum", "booking date", "wertstellung"]
    private static let amountHeaders: Set<String> = ["amount", "betrag", "wert", "value", "netto"]
    private static let descriptionHeaders: Set<String> = [
        "description", "beschreibung", "memo", "merchant", "verwendungszweck", "text", "empfänger/zahlungspflichtiger", "empfaenger"
    ]
    private static let categoryHeaders: Set<String> = ["category", "kategorie", "typ", "type"]

    public static func parseCSV(_ text: String) -> FinanceImportResult {
        let lines = splitLines(text)
        guard !lines.isEmpty else { return .empty }

        let delimiter = detectDelimiter(in: lines.first!)
        let rows = lines.map { splitRow($0, delimiter: delimiter) }

        guard let headerIndex = rows.firstIndex(where: { isHeaderRow($0) }) else {
            // No recognizable header: cannot map columns, so every row is
            // reported as skipped rather than guessing column order.
            return FinanceImportResult(transactions: [], skippedRowCount: rows.count, detectedSource: .genericCSV)
        }

        let header = rows[headerIndex].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let dateColumn = firstIndex(of: dateHeaders, in: header),
              let amountColumn = firstIndex(of: amountHeaders, in: header) else {
            let dataRowCount = rows.count - headerIndex - 1
            return FinanceImportResult(transactions: [], skippedRowCount: max(dataRowCount, 0), detectedSource: .genericCSV)
        }
        let descriptionColumn = firstIndex(of: descriptionHeaders, in: header)
        let categoryColumn = firstIndex(of: categoryHeaders, in: header)
        let detectedSource: FinanceImportSource = header.contains("betrag") && header.contains("datum") ? .tradeRepublicCSV : .genericCSV

        var transactions: [FinanceImportedTransaction] = []
        var skipped = 0
        let dataRows = rows[(headerIndex + 1)...]

        for row in dataRows {
            guard row.count > dateColumn, row.count > amountColumn else {
                if !row.isEmpty { skipped += 1 }
                continue
            }
            let rawDate = row[dateColumn].trimmingCharacters(in: .whitespaces)
            let rawAmount = row[amountColumn].trimmingCharacters(in: .whitespaces)
            guard let bookedAt = parseDate(rawDate), let amountCents = parseAmountCents(rawAmount) else {
                skipped += 1
                continue
            }
            let description = descriptionColumn.flatMap { row.count > $0 ? row[$0].trimmingCharacters(in: .whitespaces) : nil }
            let category = categoryColumn.flatMap { row.count > $0 ? row[$0].trimmingCharacters(in: .whitespaces) : nil }
            transactions.append(
                FinanceImportedTransaction(
                    bookedAt: bookedAt,
                    amountCents: amountCents,
                    description: (description?.isEmpty == false) ? description! : "Imported transaction",
                    category: (category?.isEmpty == false) ? category : nil,
                    source: detectedSource
                )
            )
        }

        return FinanceImportResult(transactions: transactions, skippedRowCount: skipped, detectedSource: detectedSource)
    }

    // MARK: - Line/row splitting

    private static func splitLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func detectDelimiter(in headerLine: String) -> Character {
        let semicolons = headerLine.filter { $0 == ";" }.count
        let commas = headerLine.filter { $0 == "," }.count
        return semicolons > commas ? ";" : ","
    }

    /// Minimal CSV field splitter supporting double-quoted fields (with `""`
    /// as an escaped quote) so a description containing the delimiter does
    /// not corrupt column alignment.
    private static func splitRow(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()

        while let char = pending {
            if inQuotes {
                if char == "\"" {
                    var peekIterator = iterator
                    if peekIterator.next() == "\"" {
                        current.append("\"")
                        iterator = peekIterator
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == delimiter {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            pending = iterator.next()
        }
        fields.append(current)
        return fields
    }

    private static func isHeaderRow(_ row: [String]) -> Bool {
        let normalized = row.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
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
        for formatter in dateFormatters {
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = ["yyyy-MM-dd", "dd.MM.yyyy", "dd/MM/yyyy", "yyyy/MM/dd"]
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
    ///   (`1.234,56` or `-12,50`)
    /// - Plain format: `.` as decimal, no thousands separator (`1234.56`)
    /// Strips a trailing/leading `€`/`EUR` and surrounding whitespace.
    /// Returns `nil` (never a fabricated amount) if the string does not
    /// resolve to a valid decimal number.
    private static func parseAmountCents(_ raw: String) -> Int? {
        var cleaned = raw
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        var isNegative = false
        if cleaned.hasPrefix("-") {
            isNegative = true
            cleaned.removeFirst()
        } else if cleaned.hasPrefix("+") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        let hasComma = cleaned.contains(",")
        let hasDot = cleaned.contains(".")
        var normalized: String
        if hasComma && hasDot {
            // European: '.' thousands, ',' decimal.
            normalized = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
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
        guard let intCents = (rounded as NSDecimalNumber).intValue as Int?, rounded == Decimal(intCents) else { return nil }
        return isNegative ? -abs(intCents) : intCents
    }
}
