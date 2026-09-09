import Foundation

private enum TaxPrivacy {
    // German tax IDs are eleven digits and are often printed immediately
    // before a date. Keep the capture to those eleven digits so redaction
    // cannot consume or alter the date that the parser needs to retain.
    private static let germanTaxIdentifierRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:steuerliche[ \t]+(?:identifikationsnummer|id)|steueridentifikationsnummer|identifikationsnummer|steuer[ \t]*[-–—]?[ \t]*id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?|id[ \t]*[-–—.]?[ \t]*nr\.?|ident[ \t]*[-–—.]?[ \t]*nr\.?|tax[ \t]+identification[ \t]+number|tax[ \t]+id(?:entifier)?|taxpayer[ \t]+id(?:entifier)?|tin)(?=[ \t]*[:#-]?[ \t]*[0-9])[ \t]*[:#-]?[ \t]*([0-9](?:[ \t]?[0-9]){10})(?![0-9])"#
    )

    private static let identifierRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:steuerliche[ \t]+(?:identifikationsnummer|id)|steueridentifikationsnummer|identifikationsnummer|steuer[ \t]*[-–—]?[ \t]*id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?|id[ \t]*[-–—.]?[ \t]*nr\.?|ident[ \t]*[-–—.]?[ \t]*nr\.?|tax[ \t]+identification[ \t]+number|tax[ \t]+id(?:entifier)?|taxpayer[ \t]+id(?:entifier)?|tin|steuer[- ]?nummer|aktenzeichen|reference(?:[ \t]+identifier)?|identifier|id)\b[ \t]*[:#-]?[ \t]*(\*+[0-9]{2}|(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z][0-9A-Z./-]{2,30}|[0-9A-Z][0-9A-Z./-]{2,30})(?![0-9A-Z./-])"#
    )

    static func redactIdentifiers(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var redacted = text
        for regex in [germanTaxIdentifierRegex, identifierRegex] {
            let matches = regex.matches(
                in: redacted,
                range: NSRange(location: 0, length: (redacted as NSString).length)
            )
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: redacted) else { continue }
                redacted.replaceSubrange(valueRange, with: maskIdentifier(String(redacted[valueRange])))
            }
        }
        return redacted
    }

    static func maskIdentifierValue(_ value: String) -> String {
        let redacted = redactIdentifiers(in: value)
        if redacted != value || value.contains("*") { return redacted }
        return maskIdentifier(value)
    }

    /// Keep a reference field on its label and identifier only. Tax PDFs often
    /// put an amount or date on the same line; retaining that whole line lets
    /// a privacy helper consume adjacent financial data and corrupt parsing.
    static func redactedIdentifierField(in line: String, label: String) -> String {
        guard let labelRange = line.range(of: label, options: .caseInsensitive) else {
            return redactIdentifiers(in: line)
        }
        let suffix = String(line[labelRange.upperBound...])
        let valueRegex = try? NSRegularExpression(
            pattern: #"(?i)^[ \t]*[:#-]?[ \t]*(\*+[0-9]{2}|(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z][0-9A-Z./-]{2,30}|[0-9A-Z][0-9A-Z./-]{2,30})(?![0-9A-Z./-])"#
        )
        guard let valueRegex,
              let match = valueRegex.firstMatch(in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length)),
              let valueEnd = Range(match.range, in: suffix) else {
            return redactIdentifiers(in: line)
        }
        let field = String(line[..<labelRange.upperBound]) + String(suffix[..<valueEnd.upperBound])
        return redactIdentifiers(in: field).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func maskIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return trimmed }
        let suffix = String(trimmed.suffix(2))
        let prefix = trimmed.dropLast(2)
        if !prefix.isEmpty && prefix.allSatisfy({ $0 == "*" }) { return trimmed }
        let maskCount = min(8, max(1, prefix.count))
        return String(repeating: "*", count: maskCount) + suffix
    }
}

public struct TaxEvidence: Codable, Equatable, Sendable {
    public let page: Int
    public let snippet: String

    public init(page: Int, snippet: String) {
        self.page = page
        self.snippet = TaxPrivacy.redactIdentifiers(in: snippet)
    }

    private enum CodingKeys: String, CodingKey {
        case page
        case snippet
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            page: try container.decode(Int.self, forKey: .page),
            snippet: try container.decode(String.self, forKey: .snippet)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(page, forKey: .page)
        try container.encode(TaxPrivacy.redactIdentifiers(in: snippet), forKey: .snippet)
    }
}

public struct TaxDate: Codable, Equatable, Sendable {
    public var value: String
    public var evidence: TaxEvidence

    public init(value: String, evidence: TaxEvidence) {
        self.value = TaxPrivacy.redactIdentifiers(in: value)
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try container.decode(String.self, forKey: .value),
            evidence: try container.decode(TaxEvidence.self, forKey: .evidence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(TaxPrivacy.redactIdentifiers(in: value), forKey: .value)
        try container.encode(evidence, forKey: .evidence)
    }
}

public struct TaxAmount: Codable, Equatable, Sendable {
    public var value: String
    public var label: String
    public var evidence: TaxEvidence

    public init(value: String, label: String, evidence: TaxEvidence) {
        self.value = TaxPrivacy.redactIdentifiers(in: value)
        self.label = TaxPrivacy.redactIdentifiers(in: label)
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case label
        case evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try container.decode(String.self, forKey: .value),
            label: try container.decode(String.self, forKey: .label),
            evidence: try container.decode(TaxEvidence.self, forKey: .evidence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(TaxPrivacy.redactIdentifiers(in: value), forKey: .value)
        try container.encode(TaxPrivacy.redactIdentifiers(in: label), forKey: .label)
        try container.encode(evidence, forKey: .evidence)
    }
}

public struct TaxCandidate: Codable, Equatable, Sendable {
    public var value: String
    public var evidence: TaxEvidence

    public init(value: String, evidence: TaxEvidence) {
        self.value = TaxPrivacy.redactIdentifiers(in: value)
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try container.decode(String.self, forKey: .value),
            evidence: try container.decode(TaxEvidence.self, forKey: .evidence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(TaxPrivacy.redactIdentifiers(in: value), forKey: .value)
        try container.encode(evidence, forKey: .evidence)
    }
}

public enum TaxConfidence: String, Codable, Sendable {
    case low
    case medium
    case high
}

public struct TaxDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var documentType: String
    public var taxYear: Int?
    public var issuer: TaxCandidate?
    public var taxpayerIdentifier: TaxCandidate?
    public var referenceIdentifier: TaxCandidate?
    public var dates: [TaxDate]
    public var amounts: [TaxAmount]
    public var pages: [String]
    public var warnings: [String]
    public var confidence: TaxConfidence

    public init(
        id: UUID = UUID(), title: String, documentType: String, taxYear: Int?,
        issuer: String?, taxpayerIdentifier: String?, referenceIdentifier: String?,
        dates: [TaxDate], amounts: [TaxAmount], pages: [String], warnings: [String] = [],
        confidence: TaxConfidence? = nil
    ) {
        self.init(
            id: id, title: title, documentType: documentType, taxYear: taxYear,
            issuer: issuer.map { TaxCandidate(value: $0, evidence: TaxEvidence(page: 1, snippet: $0)) },
            taxpayerIdentifier: taxpayerIdentifier.map {
                let safeValue = TaxPrivacy.maskIdentifierValue($0)
                return TaxCandidate(value: safeValue, evidence: TaxEvidence(page: 1, snippet: safeValue))
            },
            referenceIdentifier: referenceIdentifier.map {
                let safeValue = TaxPrivacy.maskIdentifierValue($0)
                return TaxCandidate(value: safeValue, evidence: TaxEvidence(page: 1, snippet: safeValue))
            },
            dates: dates, amounts: amounts, pages: pages, warnings: warnings, confidence: confidence
        )
    }

    public init(
        id: UUID = UUID(), title: String, documentType: String, taxYear: Int?,
        issuer: TaxCandidate?, taxpayerIdentifier: TaxCandidate?, referenceIdentifier: TaxCandidate?,
        dates: [TaxDate], amounts: [TaxAmount], pages: [String], warnings: [String] = [],
        confidence: TaxConfidence? = nil
    ) {
        self.id = id
        self.title = title
        self.documentType = documentType
        self.taxYear = taxYear
        self.issuer = issuer
        self.taxpayerIdentifier = Self.redactedIdentifierCandidate(taxpayerIdentifier)
        self.referenceIdentifier = Self.redactedIdentifierCandidate(referenceIdentifier)
        self.dates = dates
        self.amounts = amounts
        self.pages = pages.map { TaxPrivacy.redactIdentifiers(in: $0) }
        self.warnings = warnings
        self.confidence = confidence ?? TaxDocumentParser.confidence(
            taxYear: taxYear, issuer: issuer, taxpayerIdentifier: self.taxpayerIdentifier,
            referenceIdentifier: self.referenceIdentifier, dates: dates, amounts: amounts
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case documentType
        case taxYear
        case issuer
        case taxpayerIdentifier
        case referenceIdentifier
        case dates
        case amounts
        case warnings
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            documentType: try container.decode(String.self, forKey: .documentType),
            taxYear: try container.decodeIfPresent(Int.self, forKey: .taxYear),
            issuer: try container.decodeIfPresent(TaxCandidate.self, forKey: .issuer),
            taxpayerIdentifier: try container.decodeIfPresent(TaxCandidate.self, forKey: .taxpayerIdentifier),
            referenceIdentifier: try container.decodeIfPresent(TaxCandidate.self, forKey: .referenceIdentifier),
            dates: try container.decodeIfPresent([TaxDate].self, forKey: .dates) ?? [],
            amounts: try container.decodeIfPresent([TaxAmount].self, forKey: .amounts) ?? [],
            pages: [],
            warnings: try container.decodeIfPresent([String].self, forKey: .warnings) ?? [],
            confidence: try container.decodeIfPresent(TaxConfidence.self, forKey: .confidence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(documentType, forKey: .documentType)
        try container.encodeIfPresent(taxYear, forKey: .taxYear)
        try container.encode(issuer, forKey: .issuer)
        try container.encode(Self.redactedIdentifierCandidate(taxpayerIdentifier), forKey: .taxpayerIdentifier)
        try container.encode(Self.redactedIdentifierCandidate(referenceIdentifier), forKey: .referenceIdentifier)
        try container.encode(dates, forKey: .dates)
        try container.encode(amounts, forKey: .amounts)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(confidence, forKey: .confidence)
        // Page text is transient extraction/review state and is intentionally
        // excluded from the ordinary document and sync representation.
    }

    private static func redactedIdentifierCandidate(_ candidate: TaxCandidate?) -> TaxCandidate? {
        guard let candidate else { return nil }
        let safeValue = TaxPrivacy.maskIdentifierValue(candidate.value)
        let safeEvidenceSnippet = candidate.evidence.snippet.replacingOccurrences(
            of: candidate.value,
            with: safeValue
        )
        return TaxCandidate(
            value: safeValue,
            evidence: TaxEvidence(page: candidate.evidence.page, snippet: safeEvidenceSnippet)
        )
    }
}

enum TaxDocumentParser {
    static func parse(text: String, documentName: String) -> TaxDocument {
        parse(pages: [text], documentName: documentName)
    }

    static func parse(pages: [String], documentName: String) -> TaxDocument {
        let cleanedPages = pages.map { $0.replacingOccurrences(of: "\u{FFFD}", with: "") }
        let safePages = cleanedPages.map { TaxPrivacy.redactIdentifiers(in: $0) }
        var dates: [TaxDate] = []
        var amounts: [TaxAmount] = []
        var years: [Int] = []
        let datePattern = #"\b(?:\d{1,2}[./]\d{1,2}[./]\d{4}|\d{4}-\d{2}-\d{2})\b"#
        let moneyPattern = #"(?i)([\wÄÖÜäöüß -]{2,30}?)\s+([€$])?\s*(\d{1,3}(?:[. ]\d{3})*(?:,\d{2})|\d+(?:\.\d{2})?)\s*(EUR|€|USD|\$)?"#
        let dateRegex = try? NSRegularExpression(pattern: datePattern)
        let moneyRegex = try? NSRegularExpression(pattern: moneyPattern)

        for (index, page) in safePages.enumerated() {
            let nsPage = page as NSString
            let range = NSRange(location: 0, length: nsPage.length)
            dateRegex?.enumerateMatches(in: page, range: range) { match, _, _ in
                guard let match else { return }
                let value = nsPage.substring(with: match.range)
                let evidence = TaxEvidence(page: index + 1, snippet: evidenceSnippet(in: page, around: value))
                dates.append(TaxDate(value: value, evidence: evidence))
                let yearText = value.contains("-") ? String(value.prefix(4)) : String(value.suffix(4))
                if let year = Int(yearText), (1900...2100).contains(year) { years.append(year) }
            }
            moneyRegex?.enumerateMatches(in: page, range: range) { match, _, _ in
                guard let match else { return }
                let hasPrefixCurrency = match.range(at: 2).location != NSNotFound
                let hasSuffixCurrency = match.range(at: 4).location != NSNotFound
                guard hasPrefixCurrency || hasSuffixCurrency else { return }
                let label = nsPage.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let raw = nsPage.substring(with: match.range(at: 3))
                let normalized = raw.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: ",", with: ".")
                let evidence = TaxEvidence(page: index + 1, snippet: evidenceSnippet(in: page, around: match.range))
                amounts.append(TaxAmount(value: normalized, label: label, evidence: evidence))
            }
        }

        let combined = safePages.joined(separator: "\n")
        let issuer = candidate(for: combined, labels: ["Finanzamt", "Issuer"])
        let taxpayerIdentifier = identifierCandidate(in: combined)
        let referenceIdentifier = candidate(for: combined, labels: [
            "Steuerliche Identifikationsnummer", "Steueridentifikationsnummer",
            "Identifikationsnummer", "Steuer-ID", "Id-Nr", "Steuernummer",
            "Aktenzeichen", "Reference"
        ])
        let explicitYear = firstCapture(in: combined, pattern: #"(?i)(?:Steuerjahr|tax year)\s*:?\s*(\d{4})"#).flatMap(Int.init)
        var warnings: [String] = []
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("No embedded text was found.")
        }
        if cleanedPages.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            warnings.append("One or more pages had no readable text.")
        }
        var uniqueWarnings: [String] = []
        for warning in warnings where !uniqueWarnings.contains(warning) {
            uniqueWarnings.append(warning)
        }
        return TaxDocument(
            title: documentName,
            documentType: documentName.replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive),
            taxYear: explicitYear ?? years.first,
            issuer: issuer,
            taxpayerIdentifier: taxpayerIdentifier,
            referenceIdentifier: referenceIdentifier,
            dates: dates,
            amounts: amounts,
            pages: safePages,
            warnings: uniqueWarnings
        )
    }

    static func confidence(
        taxYear: Int?, issuer: TaxCandidate?, taxpayerIdentifier: TaxCandidate?,
        referenceIdentifier: TaxCandidate?, dates: [TaxDate], amounts: [TaxAmount]
    ) -> TaxConfidence {
        let score = [taxYear != nil, issuer != nil, taxpayerIdentifier != nil,
                     referenceIdentifier != nil, !dates.isEmpty, !amounts.isEmpty]
            .filter { $0 }.count
        return score >= 5 ? .high : (score >= 3 ? .medium : .low)
    }

    private static func evidenceSnippet(in text: String, around value: String) -> String {
        evidenceSnippet(in: text, around: NSRange(location: (text as NSString).range(of: value).location, length: value.utf16.count))
    }

    private static func evidenceSnippet(in text: String, around range: NSRange) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let start = max(0, min(range.location - 80, normalized.utf16.count))
        let length = min(240, normalized.utf16.count - start)
        guard length > 0, let swiftRange = Range(NSRange(location: start, length: length), in: normalized) else { return "" }
        return String(normalized[swiftRange]).trimmingCharacters(in: .whitespaces)
    }

    private static func candidate(for text: String, labels: [String]) -> TaxCandidate? {
        guard let label = labels.first(where: { text.range(of: $0, options: .caseInsensitive) != nil }),
              let range = text.range(of: label, options: .caseInsensitive) else { return nil }
        let line = String(text[range.lowerBound...]).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? label
        let identifierLabels = [
            "Steuerliche Identifikationsnummer", "Steueridentifikationsnummer",
            "Identifikationsnummer", "Steuer-ID", "Id-Nr", "Steuernummer",
            "Aktenzeichen", "Reference"
        ]
        let value = identifierLabels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame })
            ? TaxPrivacy.redactedIdentifierField(in: line, label: label)
            : line.trimmingCharacters(in: .whitespaces)
        return TaxCandidate(value: value, evidence: TaxEvidence(page: 1, snippet: value))
    }

    private static func identifierCandidate(in text: String) -> TaxCandidate? {
        let pattern = #"(?i)(?:steuerliche[ \t]+(?:identifikationsnummer|id)|steueridentifikationsnummer|identifikationsnummer|steuer[ \t]*[-–—]?[ \t]*id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?|id[ \t]*[-–—.]?[ \t]*nr\.?|ident[ \t]*[-–—.]?[ \t]*nr\.?|tax[ \t]+identification[ \t]+number|tax[ \t]+id(?:entifier)?|taxpayer[ \t]+id(?:entifier)?|tin|steuer[- ]?nummer|id)\s*[:#-]?\s*(\*+[0-9]{2}|(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z][0-9A-Z./-]{2,30}|[0-9A-Z][0-9A-Z./-]{2,30})(?![0-9A-Z./-])"#
        guard let raw = firstCapture(in: text, pattern: pattern)?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 4 else { return nil }
        let visibleCharacterCount = 2
        let suffix = String(raw.suffix(visibleCharacterCount))
        let maskCharacterCount = min(8, max(0, raw.count - visibleCharacterCount))
        return TaxCandidate(value: String(repeating: "*", count: maskCharacterCount) + suffix,
                            evidence: TaxEvidence(page: 1, snippet: "identifier ending \(suffix)"))
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)), match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }
}

public struct TaxDocumentStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    private var fileURL: URL { directory.appendingPathComponent("documents.json") }

    public func load() throws -> [TaxDocument] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let documents = try JSONDecoder().decode([TaxDocument].self, from: data)
        let sanitizedData = try JSONEncoder().encode(documents)
        if sanitizedData != data {
            do {
                try persist(sanitizedData)
            } catch {
                throw TaxDocumentStoreError.rawPageMigrationFailed
            }
        }
        return documents
    }

    public func save(_ documents: [TaxDocument]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(documents)
        try persist(data)
    }

    private func persist(_ data: Data) throws {
        let temporary = directory.appendingPathComponent("documents.json.tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func delete(_ document: TaxDocument) throws {
        var documents = try load()
        documents.removeAll { $0.id == document.id }
        try save(documents)
    }

    private static func defaultDirectory() -> URL {
        let group = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String
        let validGroup = group?.hasPrefix("group.") == true && group?.contains("$(") == false
        let base: URL
        if validGroup, let group {
            base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) ?? applicationSupportURL()
        } else {
            base = applicationSupportURL()
        }
        return base.appendingPathComponent("TaxDocuments", isDirectory: true)
    }

    private static func applicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }
}

public enum TaxDocumentStoreError: LocalizedError, Equatable, Sendable {
    case rawPageMigrationFailed

    public var errorDescription: String? {
        "Stored tax metadata could not be migrated safely."
    }
}

public enum TaxCSVExporter {
    public static func export(_ documents: [TaxDocument]) -> String {
        let header = ["title", "document_type", "tax_year", "issuer", "identifier", "confidence"]
        let rows = documents.map { document in
            [document.title, document.documentType, document.taxYear.map(String.init) ?? "",
             document.issuer?.value ?? "", document.taxpayerIdentifier?.value ?? "", document.confidence.rawValue]
                .map(escape)
                .joined(separator: ",")
        }
        return ([header.map(escape).joined(separator: ",")] + rows).joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        let safeValue = neutralizeFormulaPrefix(in: value)
        return "\"\(safeValue.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func neutralizeFormulaPrefix(in value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var firstNonWhitespace = 0
        var hasLeadingControlWhitespace = false
        while firstNonWhitespace < scalars.count {
            let scalar = scalars[firstNonWhitespace]
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0xFEFF
            guard isWhitespace || isControl else { break }
            hasLeadingControlWhitespace = hasLeadingControlWhitespace || isControl
            firstNonWhitespace += 1
        }

        let startsWithFormulaPrefix = firstNonWhitespace < scalars.count
            && "=+-@".unicodeScalars.contains(scalars[firstNonWhitespace])
        guard hasLeadingControlWhitespace || startsWithFormulaPrefix else { return value }
        return "'" + value
    }
}
