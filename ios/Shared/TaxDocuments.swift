import Foundation

public enum TaxDocumentLimits {
    public static let maximumStoredDocuments = 512
    public static let maximumStoredBytes = 4 * 1024 * 1024
    public static let maximumPages = 200
    public static let maximumPageCharacters = 250_000
    public static let maximumTotalPageBytes = 8 * 1024 * 1024
    public static let maximumDates = 2_048
    public static let maximumAmounts = 2_048
    public static let maximumWarnings = 64
    public static let maximumFieldCharacters = 2_048
    public static let maximumEvidenceCharacters = 512
    public static let maximumPDFBytes = 64 * 1024 * 1024
}

private enum TaxPrivacy {
    // German tax IDs are eleven digits and are often printed immediately
    // before a date. Keep the capture to those eleven digits so redaction
    // cannot consume or alter the date that the parser needs to retain.
    private static let germanTaxIdentifierRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:steuerliche[ \t]+(?:identifikationsnummer|id)|steueridentifikationsnummer|identifikationsnummer|steuer[ \t]*[-–—]?[ \t]*id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?|id[ \t]*[-–—.]?[ \t]*nr\.?|ident[ \t]*[-–—.]?[ \t]*nr\.?|tax[ \t]+identification[ \t]+number|tax[ \t]+id(?:entifier)?|taxpayer[ \t]+id(?:entifier)?|tin)(?=[ \t]*[:#-]?[ \t]*[0-9])[ \t]*[:#-]?[ \t]*([0-9](?:[ \t]?[0-9]){10})(?![0-9])"#
    )

    private static let identifierRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:steuerliche[ \t]+(?:identifikationsnummer|id)|steueridentifikationsnummer|identifikationsnummer|steuer[ \t]*[-–—]?[ \t]*id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?|id[ \t]*[-–—.]?[ \t]*nr\.?|ident[ \t]*[-–—.]?[ \t]*nr\.?|tax[ \t]+identification[ \t]+number|tax[ \t]+id(?:entifier)?|taxpayer[ \t]+id(?:entifier)?|tin|steuer[- ]?nummer|aktenzeichen|reference(?:[ \t]+identifier)?|identifier|id)\b[ \t]*[:#-]?[ \t]*(\*+[0-9]{1,30}|(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z*][0-9A-Z*./-]{0,30}|[0-9A-Z*][0-9A-Z*./-]{0,30})(?![0-9A-Z*./-])"#
    )

    // A bare identifier-shaped token can appear in page text or evidence
    // without a label. It is deliberately bounded: ordinary dates are
    // shorter, and money values use a decimal comma or two-digit decimal
    // suffix that is not in this grammar. This also prevents a regex from
    // scanning an unbounded run of attacker-controlled characters.
    private static let bareIdentifierRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Z])([0-9*]{11,30})(?![0-9A-Z]|[.,][0-9]{1,2}(?![0-9]))"#
    )
    private static let groupedIdentifierRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Z])([0-9*]{2}[ \t/.-][0-9*]{3}[ \t/.-][0-9*]{5}|[0-9*]{2}(?:[ \t][0-9*]{3}){3}|(?:[0-9*]{3}[ \t/.-]){3}[0-9*]{2})(?![0-9A-Z]|[.,][0-9]{1,2}(?![0-9]))"#
    )

    // Masked values are canonicalized even when they are already partially
    // masked. This makes *90, **90, ***90, and raw or grouped values produce
    // the same eight-mask-plus-two-digit representation.
    private static let maskedIdentifierTokenRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Z])(\*+[0-9]{1,30})(?![0-9A-Z])"#
    )
    private static let ordinaryDateRegex = try! NSRegularExpression(
        pattern: #"^(?:[0-9]{1,2}[./][0-9]{1,2}[./][0-9]{4}|[0-9]{4}-[0-9]{2}-[0-9]{2})$"#
    )
    private static let ordinaryAmountRegex = try! NSRegularExpression(
        pattern: #"^[+-]?(?:[0-9]{1,3}(?:[. ][0-9]{3})+|[0-9]+)(?:,[0-9]{2}|\.[0-9]{2})(?:[ \t]*(?:EUR|USD|€|\$))?$"#
    )
    private static let identifierFieldLabels = [
        "Steuerliche Identifikationsnummer", "Steueridentifikationsnummer",
        "Identifikationsnummer", "Steuer-ID", "Id-Nr", "Steuernummer",
        "Aktenzeichen", "Reference"
    ]

    static func redactIdentifiers(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var redacted = text
        for regex in [
            germanTaxIdentifierRegex,
            groupedIdentifierRegex,
            bareIdentifierRegex,
            maskedIdentifierTokenRegex,
            identifierRegex
        ] {
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = redactIdentifiers(in: trimmed)
        if redacted != trimmed {
            return redacted
        }
        // A value can already be canonicalized while its field label remains
        // intact. Preserve that label instead of falling back to masking the
        // entire string and losing useful context in the review UI.
        for label in identifierFieldLabels {
            guard trimmed.range(of: label, options: .caseInsensitive) != nil else { continue }
            let field = redactedIdentifierField(in: trimmed, label: label)
            if field.contains("*") {
                return field
            }
        }
        return maskIdentifier(trimmed)
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
            pattern: #"(?i)^[ \t]*[:#-]?[ \t]*(?:([0-9*]{2}[ \t/.-][0-9*]{3}[ \t/.-][0-9*]{5}|[0-9*]{2}(?:[ \t][0-9*]{3}){3}|(?:[0-9*]{3}[ \t]){3}[0-9*]{2}|[0-9*]{11,30}|\*+[0-9]{1,30}|(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z*][0-9A-Z*./-]{0,30}|[0-9A-Z*][0-9A-Z*./-]{0,30}))(?![0-9A-Z*./-])"#
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
        guard !trimmed.isEmpty else { return trimmed }
        if ordinaryDateRegex.firstMatch(
            in: trimmed,
            range: NSRange(location: 0, length: (trimmed as NSString).length)
        ) != nil {
            return trimmed
        }
        let digits = trimmed.filter { character in
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first else { return false }
            return (48...57).contains(scalar.value)
        }
        guard digits.count >= 2 else {
            return String(repeating: "*", count: 8)
        }
        return String(repeating: "*", count: 8) + String(digits.suffix(2))
    }

    static func redactDateValue(_ value: String) -> String {
        redactIdentifiers(in: value)
    }

    static func redactFinancialValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ordinaryAmountRegex.firstMatch(
            in: trimmed,
            range: NSRange(location: 0, length: (trimmed as NSString).length)
        ) == nil else {
            return value
        }
        return redactIdentifiers(in: value)
    }
}

public struct TaxEvidence: Codable, Equatable, Sendable {
    public let page: Int
    public let snippet: String

    public init(page: Int, snippet: String) {
        self.page = max(1, page)
        self.snippet = String(TaxPrivacy.redactIdentifiers(in: snippet).prefix(TaxDocumentLimits.maximumEvidenceCharacters))
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
        self.value = String(TaxPrivacy.redactDateValue(value).prefix(TaxDocumentLimits.maximumFieldCharacters))
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
        try container.encode(TaxPrivacy.redactDateValue(value), forKey: .value)
        try container.encode(evidence, forKey: .evidence)
    }
}

public struct TaxAmount: Codable, Equatable, Sendable {
    public var value: String
    public var label: String
    public var evidence: TaxEvidence

    public init(value: String, label: String, evidence: TaxEvidence) {
        self.value = String(TaxPrivacy.redactFinancialValue(value).prefix(TaxDocumentLimits.maximumFieldCharacters))
        self.label = String(TaxPrivacy.redactIdentifiers(in: label).prefix(TaxDocumentLimits.maximumFieldCharacters))
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
        try container.encode(TaxPrivacy.redactFinancialValue(value), forKey: .value)
        try container.encode(TaxPrivacy.redactIdentifiers(in: label), forKey: .label)
        try container.encode(evidence, forKey: .evidence)
    }
}

public struct TaxCandidate: Codable, Equatable, Sendable {
    public var value: String
    public var evidence: TaxEvidence

    public init(value: String, evidence: TaxEvidence) {
        self.value = String(TaxPrivacy.redactIdentifiers(in: value).prefix(TaxDocumentLimits.maximumFieldCharacters))
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
        self.title = Self.redactedField(title)
        self.documentType = Self.redactedField(documentType)
        self.taxYear = taxYear
        self.issuer = Self.redactedTextCandidate(issuer)
        self.taxpayerIdentifier = Self.redactedIdentifierCandidate(taxpayerIdentifier)
        self.referenceIdentifier = Self.redactedIdentifierCandidate(referenceIdentifier)
        self.dates = Array(dates.prefix(TaxDocumentLimits.maximumDates))
        self.amounts = Array(amounts.prefix(TaxDocumentLimits.maximumAmounts))
        self.pages = Self.boundedPagesForParsing(pages).pages
        self.warnings = Array(warnings.prefix(TaxDocumentLimits.maximumWarnings)).map {
            Self.redactedField($0)
        }
        self.confidence = confidence ?? TaxDocumentParser.confidence(
            taxYear: taxYear, issuer: self.issuer, taxpayerIdentifier: self.taxpayerIdentifier,
            referenceIdentifier: self.referenceIdentifier, dates: self.dates, amounts: self.amounts
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
            dates: try Self.decodeBoundedArray(TaxDate.self, from: container, forKey: .dates,
                                               maximumCount: TaxDocumentLimits.maximumDates),
            amounts: try Self.decodeBoundedArray(TaxAmount.self, from: container, forKey: .amounts,
                                                 maximumCount: TaxDocumentLimits.maximumAmounts),
            pages: [],
            warnings: try Self.decodeBoundedArray(String.self, from: container, forKey: .warnings,
                                                  maximumCount: TaxDocumentLimits.maximumWarnings),
            confidence: try container.decodeIfPresent(TaxConfidence.self, forKey: .confidence)
        )
    }

    /// Decode arrays incrementally so a compact malicious JSON array cannot
    /// allocate an arbitrary number of elements before the initializer's
    /// normal value bounds are applied.
    private static func decodeBoundedArray<Element: Decodable>(
        _ type: Element.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        maximumCount: Int
    ) throws -> [Element] {
        guard container.contains(key) else { return [] }
        guard try !container.decodeNil(forKey: key) else { return [] }
        var valuesContainer = try container.nestedUnkeyedContainer(forKey: key)
        var values: [Element] = []
        values.reserveCapacity(min(valuesContainer.count ?? maximumCount, maximumCount))
        while !valuesContainer.isAtEnd {
            guard values.count < maximumCount else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: valuesContainer.codingPath,
                    debugDescription: "Tax document array exceeds its safe element limit."
                ))
            }
            values.append(try valuesContainer.decode(Element.self))
        }
        return values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Self.redactedField(title), forKey: .title)
        try container.encode(Self.redactedField(documentType), forKey: .documentType)
        try container.encodeIfPresent(taxYear, forKey: .taxYear)
        try container.encode(Self.redactedTextCandidate(issuer), forKey: .issuer)
        try container.encode(Self.redactedIdentifierCandidate(taxpayerIdentifier), forKey: .taxpayerIdentifier)
        try container.encode(Self.redactedIdentifierCandidate(referenceIdentifier), forKey: .referenceIdentifier)
        try container.encode(dates, forKey: .dates)
        try container.encode(amounts, forKey: .amounts)
        try container.encode(warnings.map(Self.redactedField), forKey: .warnings)
        try container.encode(confidence, forKey: .confidence)
        // Page text is transient extraction/review state and is intentionally
        // excluded from the ordinary document and sync representation.
    }

    private static func redactedField(_ value: String) -> String {
        String(TaxPrivacy.redactIdentifiers(in: value).prefix(TaxDocumentLimits.maximumFieldCharacters))
    }

    private static func redactedTextCandidate(_ candidate: TaxCandidate?) -> TaxCandidate? {
        guard let candidate else { return nil }
        let safeEvidence = TaxPrivacy.redactIdentifiers(in: candidate.evidence.snippet)
        return TaxCandidate(
            value: TaxPrivacy.redactIdentifiers(in: candidate.value),
            evidence: TaxEvidence(page: candidate.evidence.page, snippet: safeEvidence)
        )
    }

    private static func redactedIdentifierCandidate(_ candidate: TaxCandidate?) -> TaxCandidate? {
        guard let candidate else { return nil }
        let safeValue = TaxPrivacy.maskIdentifierValue(candidate.value)
        var safeEvidenceSnippet = candidate.evidence.snippet
        if !candidate.value.isEmpty {
            safeEvidenceSnippet = safeEvidenceSnippet.replacingOccurrences(
                of: candidate.value,
                with: safeValue
            )
        }
        safeEvidenceSnippet = TaxPrivacy.redactIdentifiers(in: safeEvidenceSnippet)
        return TaxCandidate(
            value: safeValue,
            evidence: TaxEvidence(page: candidate.evidence.page, snippet: safeEvidenceSnippet)
        )
    }

    static func boundedPagesForParsing(_ pages: [String]) -> (pages: [String], truncated: Bool) {
        var remainingBytes = TaxDocumentLimits.maximumTotalPageBytes
        var truncated = pages.count > TaxDocumentLimits.maximumPages
        var bounded: [String] = []
        bounded.reserveCapacity(min(pages.count, TaxDocumentLimits.maximumPages))
        for page in pages.prefix(TaxDocumentLimits.maximumPages) {
            let characterBounded = String(page.prefix(TaxDocumentLimits.maximumPageCharacters))
            truncated = truncated || characterBounded.count != page.count
            guard remainingBytes > 0 else {
                truncated = true
                bounded.append("")
                continue
            }
            let encoded = Data(characterBounded.utf8)
            let prefix = encoded.count > remainingBytes ? Data(encoded.prefix(remainingBytes)) : encoded
            let value = String(decoding: prefix, as: UTF8.self)
            truncated = truncated || value.utf8.count != encoded.count
            remainingBytes -= value.utf8.count
            bounded.append(TaxPrivacy.redactIdentifiers(in: value))
        }
        return (bounded, truncated)
    }
}

enum TaxDocumentParser {
    static func parse(
        text: String, documentName: String,
        cancellationCheck: @escaping () -> Bool = { false }
    ) -> TaxDocument {
        parse(pages: [text], documentName: documentName, cancellationCheck: cancellationCheck)
    }

    static func parse(
        pages: [String], documentName: String,
        cancellationCheck: @escaping () -> Bool = { false }
    ) -> TaxDocument {
        let bounded = TaxDocument.boundedPagesForParsing(pages)
        let cleanedPages = bounded.pages.map { $0.replacingOccurrences(of: "\u{FFFD}", with: "") }
        let safePages = cleanedPages.map { TaxPrivacy.redactIdentifiers(in: $0) }
        var dates: [TaxDate] = []
        var amounts: [TaxAmount] = []
        var years: [Int] = []
        let datePattern = #"\b(?:\d{1,2}[./]\d{1,2}[./]\d{4}|\d{4}-\d{2}-\d{2})\b"#
        let moneyPattern = #"(?i)([\wÄÖÜäöüß -]{2,30}?)\s+([€$])?\s*(\d{1,3}(?:[. ]\d{3})*,\d{2}|\d+(?:[.,]\d{2})?)\s*(EUR|€|USD|\$)?(?![0-9A-Za-z.,])"#
        let dateRegex = try? NSRegularExpression(pattern: datePattern)
        let moneyRegex = try? NSRegularExpression(pattern: moneyPattern)

        for (index, page) in safePages.enumerated() {
            if cancellationCheck() { break }
            let nsPage = page as NSString
            let range = NSRange(location: 0, length: nsPage.length)
            if dates.count < TaxDocumentLimits.maximumDates {
                dateRegex?.enumerateMatches(in: page, range: range) { match, _, stop in
                    if cancellationCheck() {
                        stop.pointee = true
                        return
                    }
                    guard dates.count < TaxDocumentLimits.maximumDates else {
                        stop.pointee = true
                        return
                    }
                    guard let match else { return }
                    let value = nsPage.substring(with: match.range)
                    let evidence = TaxEvidence(page: index + 1, snippet: evidenceSnippet(in: page, around: value))
                    dates.append(TaxDate(value: value, evidence: evidence))
                    let yearText = value.contains("-") ? String(value.prefix(4)) : String(value.suffix(4))
                    if let year = Int(yearText), (1900...2100).contains(year), years.count < TaxDocumentLimits.maximumDates {
                        years.append(year)
                    }
                    if dates.count >= TaxDocumentLimits.maximumDates { stop.pointee = true }
                }
            }
            if cancellationCheck() { break }
            if amounts.count < TaxDocumentLimits.maximumAmounts {
                moneyRegex?.enumerateMatches(in: page, range: range) { match, _, stop in
                    if cancellationCheck() {
                        stop.pointee = true
                        return
                    }
                    guard amounts.count < TaxDocumentLimits.maximumAmounts else {
                        stop.pointee = true
                        return
                    }
                    guard let match else { return }
                    let hasPrefixCurrency = match.range(at: 2).location != NSNotFound
                    let hasSuffixCurrency = match.range(at: 4).location != NSNotFound
                    guard hasPrefixCurrency || hasSuffixCurrency else { return }
                    let label = nsPage.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    let raw = nsPage.substring(with: match.range(at: 3))
                    guard let normalized = normalizeMoneyToken(raw) else { return }
                    let evidence = TaxEvidence(page: index + 1, snippet: evidenceSnippet(in: page, around: match.range))
                    amounts.append(TaxAmount(value: normalized, label: label, evidence: evidence))
                    if amounts.count >= TaxDocumentLimits.maximumAmounts { stop.pointee = true }
                }
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
        if bounded.truncated {
            warnings.append("Document text was truncated to a safe limit.")
        }
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

    /// Normalizes only the bounded money grammar captured by `moneyPattern`.
    /// A comma is the decimal separator for German grouped values; a single
    /// dot followed by two digits is retained as a plain decimal point. Any
    /// other punctuation layout is rejected instead of being guessed.
    private static func normalizeMoneyToken(_ raw: String) -> String? {
        let compact = raw.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty, compact.count <= 64 else { return nil }

        let isASCIIDigits: (String) -> Bool = { value in
            !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value)
            }
        }
        guard compact.unicodeScalars.allSatisfy({ scalar in
            (48...57).contains(scalar.value) || scalar.value == 44 || scalar.value == 46
        }) else { return nil }

        let commaCount = compact.reduce(into: 0) { count, character in
            if character == "," { count += 1 }
        }
        let dotCount = compact.reduce(into: 0) { count, character in
            if character == "." { count += 1 }
        }

        if commaCount == 1 {
            let components = compact.split(separator: ",", omittingEmptySubsequences: false)
            guard components.count == 2,
                  components[1].count == 2,
                  isASCIIDigits(String(components[1])) else { return nil }

            let integerPart = String(components[0])
            let integer: String
            if integerPart.contains(".") {
                let groups = integerPart.split(separator: ".", omittingEmptySubsequences: false)
                guard groups.count >= 2,
                      let first = groups.first,
                      (1...3).contains(first.count),
                      isASCIIDigits(String(first)),
                      groups.dropFirst().allSatisfy({ group in
                          group.count == 3 && isASCIIDigits(String(group))
                      }) else { return nil }
                integer = groups.map(String.init).joined()
            } else {
                guard isASCIIDigits(integerPart) else { return nil }
                integer = integerPart
            }
            return "\(integer).\(components[1])"
        }

        guard commaCount == 0 else { return nil }
        if dotCount == 0 {
            return isASCIIDigits(compact) ? compact : nil
        }

        // More than one dot could be grouping or a malformed decimal. The
        // parser has no reliable signal to distinguish those cases.
        guard dotCount == 1 else { return nil }
        let components = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[1].count == 2,
              isASCIIDigits(String(components[0])),
              isASCIIDigits(String(components[1])) else { return nil }
        return compact
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
        let pattern = #"(?i)(?:steuerliche[ \t]+(?:identifikationsnummer|id)|steueridentifikationsnummer|identifikationsnummer|steuer[ \t]*[-–—]?[ \t]*id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?|id[ \t]*[-–—.]?[ \t]*nr\.?|ident[ \t]*[-–—.]?[ \t]*nr\.?|tax[ \t]+identification[ \t]+number|tax[ \t]+id(?:entifier)?|taxpayer[ \t]+id(?:entifier)?|tin|steuer[- ]?nummer|id)\s*[:#-]?\s*(\*+[0-9]{2,30}|(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z*][0-9A-Z*./-]{2,30}|[0-9A-Z*][0-9A-Z*./-]{2,30})(?![0-9A-Z*./-])"#
        guard let raw = firstCapture(in: text, pattern: pattern)?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 4 else { return nil }
        let safeValue = TaxPrivacy.maskIdentifierValue(raw)
        let suffix = String(safeValue.suffix(2))
        return TaxCandidate(value: safeValue,
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

#if os(iOS)
    static let durableWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
#else
    static let durableWriteOptions: Data.WritingOptions = [.atomic]
#endif

    public func load() throws -> [TaxDocument] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= TaxDocumentLimits.maximumStoredBytes else {
            throw TaxDocumentStoreError.fileTooLarge
        }
        let data = try Data(contentsOf: fileURL)
        let documents = try JSONDecoder().decode([TaxDocument].self, from: data)
        guard documents.count <= TaxDocumentLimits.maximumStoredDocuments else {
            throw TaxDocumentStoreError.tooManyDocuments
        }
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
        guard documents.count <= TaxDocumentLimits.maximumStoredDocuments else {
            throw TaxDocumentStoreError.tooManyDocuments
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(documents)
        guard data.count <= TaxDocumentLimits.maximumStoredBytes else {
            throw TaxDocumentStoreError.fileTooLarge
        }
        try persist(data)
    }

    private func persist(_ data: Data) throws {
        let temporary = directory.appendingPathComponent("documents.json.tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: Self.durableWriteOptions)
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
    case fileTooLarge
    case tooManyDocuments

    public var errorDescription: String? {
        switch self {
        case .rawPageMigrationFailed: return "Stored tax metadata could not be migrated safely."
        case .fileTooLarge: return "The local tax store exceeds its safe size limit."
        case .tooManyDocuments: return "The local tax store contains too many documents."
        }
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
