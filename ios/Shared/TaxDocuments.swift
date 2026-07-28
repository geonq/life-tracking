import Foundation

public struct TaxEvidence: Codable, Equatable, Sendable {
    public let page: Int
    public let snippet: String

    public init(page: Int, snippet: String) {
        self.page = page
        self.snippet = snippet
    }
}

public struct TaxDate: Codable, Equatable, Sendable {
    public var value: String
    public var evidence: TaxEvidence

    public init(value: String, evidence: TaxEvidence) {
        self.value = value
        self.evidence = evidence
    }
}

public struct TaxAmount: Codable, Equatable, Sendable {
    public var value: String
    public var label: String
    public var evidence: TaxEvidence

    public init(value: String, label: String, evidence: TaxEvidence) {
        self.value = value
        self.label = label
        self.evidence = evidence
    }
}

public struct TaxCandidate: Codable, Equatable, Sendable {
    public var value: String
    public var evidence: TaxEvidence

    public init(value: String, evidence: TaxEvidence) {
        self.value = value
        self.evidence = evidence
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
            taxpayerIdentifier: taxpayerIdentifier.map { TaxCandidate(value: $0, evidence: TaxEvidence(page: 1, snippet: $0)) },
            referenceIdentifier: referenceIdentifier.map { TaxCandidate(value: $0, evidence: TaxEvidence(page: 1, snippet: $0)) },
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
        self.taxpayerIdentifier = taxpayerIdentifier
        self.referenceIdentifier = referenceIdentifier
        self.dates = dates
        self.amounts = amounts
        self.pages = pages
        self.warnings = warnings
        self.confidence = confidence ?? TaxDocumentParser.confidence(
            taxYear: taxYear, issuer: issuer, taxpayerIdentifier: taxpayerIdentifier,
            referenceIdentifier: referenceIdentifier, dates: dates, amounts: amounts
        )
    }
}

enum TaxDocumentParser {
    static func parse(text: String, documentName: String) -> TaxDocument {
        parse(pages: [text], documentName: documentName)
    }

    static func parse(pages: [String], documentName: String) -> TaxDocument {
        let cleanedPages = pages.map { $0.replacingOccurrences(of: "\u{FFFD}", with: "") }
        var dates: [TaxDate] = []
        var amounts: [TaxAmount] = []
        var years: [Int] = []
        let datePattern = #"\b(?:\d{1,2}[./]\d{1,2}[./]\d{4}|\d{4}-\d{2}-\d{2})\b"#
        let moneyPattern = #"(?i)([\wÄÖÜäöüß -]{2,30}?)\s+([€$])?\s*(\d{1,3}(?:[. ]\d{3})*(?:,\d{2})|\d+(?:\.\d{2})?)\s*(EUR|€|USD|\$)?"#
        let dateRegex = try? NSRegularExpression(pattern: datePattern)
        let moneyRegex = try? NSRegularExpression(pattern: moneyPattern)

        for (index, page) in cleanedPages.enumerated() {
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
                let label = nsPage.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let raw = nsPage.substring(with: match.range(at: 3))
                let normalized = raw.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: ",", with: ".")
                let evidence = TaxEvidence(page: index + 1, snippet: evidenceSnippet(in: page, around: match.range))
                amounts.append(TaxAmount(value: normalized, label: label, evidence: evidence))
            }
        }

        let combined = cleanedPages.joined(separator: "\n")
        let issuer = candidate(for: combined, labels: ["Finanzamt", "Issuer"])
        let taxpayerIdentifier = identifierCandidate(in: combined)
        let referenceIdentifier = candidate(for: combined, labels: ["Steuernummer", "Aktenzeichen", "Reference"])
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
            pages: cleanedPages,
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
        return TaxCandidate(value: line.trimmingCharacters(in: .whitespaces), evidence: TaxEvidence(page: 1, snippet: line))
    }

    private static func identifierCandidate(in text: String) -> TaxCandidate? {
        let pattern = #"(?i)(?:steuer[- ]?nummer|tax id|id)\s*[:]?\s*([0-9A-Z][0-9A-Z /-]{3,})"#
        guard let raw = firstCapture(in: text, pattern: pattern)?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 4 else { return nil }
        let visibleCharacterCount = 2
        let suffix = String(raw.suffix(visibleCharacterCount))
        return TaxCandidate(value: String(repeating: "*", count: max(0, raw.count - visibleCharacterCount)) + suffix,
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
        return try JSONDecoder().decode([TaxDocument].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ documents: [TaxDocument]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(documents)
        let temporary = directory.appendingPathComponent("documents.json.tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        try FileManager.default.moveItem(at: temporary, to: fileURL)
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
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
