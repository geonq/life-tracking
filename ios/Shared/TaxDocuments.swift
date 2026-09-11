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
    private static let canonicalMaskedIdentifierRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z*])\*{8}(?:[0-9]{2})?(?![0-9A-Za-z*])"#
    )
    private static let unlabelledAlphaNumericIdentifierRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z*])([0-9A-Za-z][0-9A-Za-z./-]{1,31})(?![0-9A-Za-z./-])"#
    )
    private static let allCapsEvidenceTokenRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z*])([A-Z]{6,32})(?![0-9A-Za-z*])"#
    )
    private static let standaloneNumberRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z*])([0-9]{2,32})(?![0-9A-Za-z*])"#
    )
    private static let ordinaryDateSpanRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?:[0-9]{1,2}[./][0-9]{1,2}[./][0-9]{4}|[0-9]{4}-[0-9]{2}-[0-9]{2})(?![0-9A-Za-z])"#
    )
    private static let ordinaryDecimalAmountSpanRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?:[+-]?(?:[0-9]{1,3}(?:[. ][0-9]{3})+|[0-9]+)(?:,[0-9]{2}|\.[0-9]{2})(?:[ \t]*(?:EUR|USD|GBP|CHF|€|\$|£))?)(?![0-9A-Za-z])"#,
        options: .caseInsensitive
    )
    private static let ordinaryYearSpanRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:tax[ \t]+year|steuerjahr|year)[ \t]*[:#-]?[ \t]*[0-9]{4}\b"#
    )
    private static let ordinaryIdentifierEndingSpanRegex = try! NSRegularExpression(
        pattern: #"(?i)\bidentifier[ \t]+ending[ \t]*[0-9]{2}\b"#
    )
    private static let ordinaryEvidencePageSpanRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:page|seite)[ \t]*[:#-]?[ \t]*[0-9]{1,3}\b"#
    )
    private static let ordinaryYearContextRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:tax[ \t]+year|steuerjahr|year)[\s:#()/.\\-]*$"#
    )
    private static let ordinaryIdentifierEndingContextRegex = try! NSRegularExpression(
        pattern: #"(?i)identifier[ \t]+ending[\s:#()/.\\-]*$"#
    )
    private static let ordinaryPageNumberContextRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:page|seite)[\s:#()/.\\-]*$"#
    )
    private static let ordinaryEvidenceWordRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:page|seite|date|datum|amount|betrag|summe|total|owed|tax|year|steuerjahr|id|identifier|ending|reference|ref|taxpayer|issuer|steuer|steuernummer|aktenzeichen|identifikationsnummer|einkommensteuer|ust|finanzamt|berlin|rechnung|vom|bescheid|eur|usd|gbp|chf)\b"#
    )
    private static let secretReferenceSpanRegex = try! NSRegularExpression(
        pattern: #"(?i)\bsecretref\b[ \t:#-]*(?:[0-9A-Z*][0-9A-Z*./-]{1,30})?"#
    )
    private static let referenceValueRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:secretref|ref|reference(?:[ \t]+identifier)?|identifier|aktenzeichen|steuernummer|taxpayer(?:[ \t]+id(?:entifier)?)?|id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?)\b[ \t]*[:#-]?[ \t]*([0-9A-Z*][0-9A-Z*./-]{1,30})"#
    )
    private static let validatedDocumentLabelSpanRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:form[ \t]+(?:w-?2|w-?3|1040(?:-sr)?|1098|1099)|schedule[ \t]+(?:a|c|d|e|f|k-?1))\b"#
    )
    private static let formDocumentLabelPrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)form[ \t]*$"#
    )
    private static let scheduleDocumentLabelPrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)schedule[ \t]*$"#
    )
    private static let validatedFormTokens: Set<String> = [
        "w2", "w-2", "w3", "w-3", "1040", "1040-sr", "1098", "1099"
    ]
    private static let validatedScheduleTokens: Set<String> = [
        "a", "c", "d", "e", "f", "k1", "k-1"
    ]
    private static let ordinaryPageNumberMaximum = 200
    static let evidencePrivacyPlaceholder = "Evidence withheld for privacy."
    private static let identifierFieldLabels = [
        "Steuerliche Identifikationsnummer", "Steueridentifikationsnummer",
        "Identifikationsnummer", "Steuer-ID", "Id-Nr", "Steuernummer",
        "Aktenzeichen", "Reference"
    ]

    static func boundedText(_ text: String, maximumCharacters: Int) -> String {
        guard maximumCharacters >= 0 else { return "" }
        let prefix = text.prefix(maximumCharacters)
        return prefix.endIndex == text.endIndex ? text : String(prefix)
    }

    /// Applies range replacements in one forward pass over an immutable
    /// NSString. The replacement range may be a capture inside the match;
    /// untouched spans are copied once and never searched again.
    private static func replacingMatchRanges(
        _ regex: NSRegularExpression,
        in text: String,
        replacement: (NSString, NSTextCheckingResult) -> (range: NSRange, value: String)?
    ) -> String {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var pieces: [String] = []
        pieces.reserveCapacity(matches.count * 2 + 1)
        var cursor = 0

        for match in matches {
            guard let change = replacement(source, match) else { continue }
            let target = change.range
            let matchRange = match.range
            guard target.location >= cursor,
                  target.location >= matchRange.location,
                  target.location <= source.length,
                  target.length >= 0,
                  NSMaxRange(target) <= source.length,
                  NSMaxRange(target) <= NSMaxRange(matchRange) else { continue }

            if cursor < target.location {
                pieces.append(source.substring(with: NSRange(
                    location: cursor,
                    length: target.location - cursor
                )))
            }
            pieces.append(change.value)
            cursor = NSMaxRange(target)
        }

        if cursor < source.length {
            pieces.append(source.substring(with: NSRange(
                location: cursor,
                length: source.length - cursor
            )))
        }
        return pieces.joined()
    }

    private static func isOrdinaryDecimalContinuation(
        _ source: NSString,
        after valueRange: NSRange
    ) -> Bool {
        guard valueRange.location >= 0,
              valueRange.length >= 0,
              valueRange.location <= source.length,
              valueRange.length <= source.length - valueRange.location else {
            return false
        }
        let start = valueRange.location + valueRange.length
        guard start < source.length else { return false }

        let isASCIIDigit: (unichar) -> Bool = { unit in
            unit >= 48 && unit <= 57
        }
        let separator = source.character(at: start)
        guard separator == 46 || separator == 44,
              start + 2 < source.length,
              isASCIIDigit(source.character(at: start + 1)),
              isASCIIDigit(source.character(at: start + 2)) else {
            return false
        }

        let fourthIndex = start + 3
        guard fourthIndex < source.length else { return true }
        return !isASCIIDigit(source.character(at: fourthIndex))
    }

    static func redactIdentifiers(
        in text: String,
        maximumCharacters: Int = TaxDocumentLimits.maximumFieldCharacters
    ) -> String {
        let bounded = boundedText(text, maximumCharacters: maximumCharacters)
        guard !bounded.isEmpty else { return bounded }
        var redacted = bounded
        for regex in [
            germanTaxIdentifierRegex,
            groupedIdentifierRegex,
            bareIdentifierRegex,
            maskedIdentifierTokenRegex,
            identifierRegex
        ] {
            redacted = replacingMatchRanges(regex, in: redacted) { source, match in
                guard match.numberOfRanges > 1 else { return nil }
                let valueRange = match.range(at: 1)
                guard valueRange.location != NSNotFound,
                      NSMaxRange(valueRange) <= source.length,
                      !isOrdinaryDecimalContinuation(source, after: valueRange) else { return nil }
                let value = source.substring(with: valueRange)
                guard value.unicodeScalars.contains(where: {
                    CharacterSet.decimalDigits.contains($0) || $0.value == 42
                }) else {
                    return nil
                }
                return (valueRange, maskIdentifier(value))
            }
        }
        return redacted
    }

    private static func isValidatedDocumentLabelToken(
        _ token: String,
        source: NSString,
        valueRange: NSRange
    ) -> Bool {
        let contextLength = min(32, valueRange.location)
        let context = source.substring(with: NSRange(
            location: valueRange.location - contextLength,
            length: contextLength
        )).lowercased()
        let contextRange = NSRange(location: 0, length: (context as NSString).length)
        let isForm = formDocumentLabelPrefixRegex.firstMatch(
            in: context,
            range: contextRange
        ) != nil
        let isSchedule = scheduleDocumentLabelPrefixRegex.firstMatch(
            in: context,
            range: contextRange
        ) != nil
        let normalizedToken = token.lowercased()
        return (isForm && validatedFormTokens.contains(normalizedToken))
            || (isSchedule && validatedScheduleTokens.contains(normalizedToken))
    }

    /// Redacts bounded unlabelled mixed alpha-numeric tokens. This is kept
    /// separate from the broad text redactor so ordinary labels such as
    /// "Form W2" remain readable unless they occur in identifier evidence.
    static func redactUnlabelledAlphaNumericIdentifiers(
        in text: String,
        maximumCharacters: Int = TaxDocumentLimits.maximumFieldCharacters
    ) -> String {
        let bounded = boundedText(text, maximumCharacters: maximumCharacters)
        guard !bounded.isEmpty else { return bounded }
        return replacingMatchRanges(unlabelledAlphaNumericIdentifierRegex, in: bounded) { source, match in
            guard match.numberOfRanges > 1 else { return nil }
            let valueRange = match.range(at: 1)
            guard valueRange.location != NSNotFound,
                  NSMaxRange(valueRange) <= source.length else { return nil }
            let token = source.substring(with: valueRange)
            guard token.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
                  token.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else {
                return nil
            }

            // Context is deliberately capped in UTF-16 units so a hostile
            // prefix cannot make each match rescan an ever-growing String.
            if isValidatedDocumentLabelToken(token, source: source, valueRange: valueRange) {
                return nil
            }
            return (valueRange, maskIdentifier(token))
        }
    }

    /// Replaces exact identifier values before generic redaction. Candidate
    /// values are the only authoritative mapping available for a document;
    /// keeping this operation case-insensitive covers OCR/header casing while
    /// leaving unrelated UUIDs and ordinary numbers untouched.
    static func replacingKnownIdentifierValues(
        in text: String,
        replacements: [String: String],
        maximumCharacters: Int = TaxDocumentLimits.maximumFieldCharacters
    ) -> String {
        let bounded = boundedText(text, maximumCharacters: maximumCharacters)
        guard !bounded.isEmpty, !replacements.isEmpty else { return bounded }
        var result = bounded
        for (source, replacement) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
            guard !source.isEmpty,
                  let regex = try? NSRegularExpression(
                    pattern: NSRegularExpression.escapedPattern(for: source),
                    options: .caseInsensitive
                  ) else { continue }
            result = replacingMatchRanges(regex, in: result) { _, match in
                (match.range, replacement)
            }
        }
        return result
    }

    static func identifierReplacements(for candidates: [TaxCandidate?]) -> [String: String] {
        var replacements: [String: String] = [:]
        for candidate in candidates.compactMap({ $0 }) {
            let raw = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let safe = maskIdentifierValue(raw)
            guard raw.caseInsensitiveCompare(safe) != .orderedSame else { continue }
            replacements[raw] = safe
        }
        return replacements
    }

    static func visibleIdentifierSuffixes(for candidates: [TaxCandidate?]) -> Set<String> {
        var suffixes = Set<String>()
        for candidate in candidates.compactMap({ $0 }) {
            let value = candidate.value
            let source = value as NSString
            let range = NSRange(location: 0, length: source.length)
            for match in canonicalMaskedIdentifierRegex.matches(in: value, range: range) {
                let token = source.substring(with: match.range)
                let digits = token.filter { $0.isNumber }
                guard digits.count >= 2 else { continue }
                suffixes.insert(String(digits.suffix(2)))
            }
        }
        return suffixes
    }

    private static func replacingMatches(_ regex: NSRegularExpression, in text: String) -> String {
        replacingMatchRanges(regex, in: text) { _, match in
            (match.range, "")
        }
    }

    /// Returns a valid UTF-8 prefix without inserting a replacement scalar
    /// when the byte boundary falls inside a multi-byte character.
    static func boundedUTF8Prefix(
        _ text: String,
        maximumBytes: Int
    ) -> (value: String, truncated: Bool) {
        guard maximumBytes >= 0 else { return ("", true) }
        let data = Data(text.utf8)
        guard data.count > maximumBytes else { return (text, false) }
        guard maximumBytes > 0 else { return ("", true) }

        var end = maximumBytes
        while end > 0 {
            if let value = String(data: Data(data.prefix(end)), encoding: .utf8) {
                return (value, true)
            }
            // A valid UTF-8 scalar is at most four bytes, so this loop backs
            // up only across the partial scalar at the boundary.
            end -= 1
        }
        return ("", true)
    }

    private static func evidenceContainsUntrustedNumber(_ text: String) -> Bool {
        let bounded = boundedText(text, maximumCharacters: TaxDocumentLimits.maximumEvidenceCharacters)
        var residual = replacingMatches(ordinaryDateSpanRegex, in: bounded)
        residual = replacingMatches(ordinaryDecimalAmountSpanRegex, in: residual)
        residual = replacingMatches(ordinaryYearSpanRegex, in: residual)
        residual = replacingMatches(ordinaryEvidencePageSpanRegex, in: residual)
        residual = replacingMatches(ordinaryIdentifierEndingSpanRegex, in: residual)
        let matches = standaloneNumberRegex.matches(
            in: residual,
            range: NSRange(location: 0, length: (residual as NSString).length)
        )
        let source = residual as NSString
        for match in matches {
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: residual) else { continue }
            let numberRange = match.range(at: 1)
            let contextLength = min(64, numberRange.location)
            let context = source.substring(with: NSRange(
                location: numberRange.location - contextLength,
                length: contextLength
            ))
            if ordinaryPageNumberContextRegex.firstMatch(
                in: context,
                range: NSRange(location: 0, length: (context as NSString).length)
            ) != nil {
                if let page = Int(String(residual[valueRange])) {
                    if page <= ordinaryPageNumberMaximum {
                        continue
                    }
                }
                return true
            }
            if ordinaryYearContextRegex.firstMatch(
                in: context,
                range: NSRange(location: 0, length: (context as NSString).length)
            ) != nil {
                if let year = Int(String(residual[valueRange])), (1900...2100).contains(year) {
                    continue
                }
            }
            if ordinaryIdentifierEndingContextRegex.firstMatch(
                in: context,
                range: NSRange(location: 0, length: (context as NSString).length)
            ) != nil, String(residual[valueRange]).count <= 2 {
                continue
            }
            return true
        }
        return false
    }

    private static func isClearlyOrdinaryEvidence(_ text: String) -> Bool {
        let bounded = boundedText(text, maximumCharacters: TaxDocumentLimits.maximumEvidenceCharacters)
        guard !evidenceContainsUntrustedNumber(bounded) else { return false }
        var residual = replacingMatches(ordinaryEvidencePageSpanRegex, in: bounded)
        residual = replacingMatches(ordinaryYearSpanRegex, in: residual)
        residual = replacingMatches(ordinaryIdentifierEndingSpanRegex, in: residual)
        residual = replacingMatches(ordinaryDateSpanRegex, in: residual)
        residual = replacingMatches(ordinaryDecimalAmountSpanRegex, in: residual)
        residual = replacingMatches(canonicalMaskedIdentifierRegex, in: residual)
        residual = replacingMatches(validatedDocumentLabelSpanRegex, in: residual)
        residual = replacingMatches(ordinaryEvidenceWordRegex, in: residual)
        let separators = CharacterSet(charactersIn: "·•,:;|/()[]{}#.+-–—")
        return residual.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || separators.contains($0)
        }
    }

    static func redactIdentifierEvidence(
        _ text: String,
        replacements: [String: String]
    ) -> String {
        let bounded = boundedText(text, maximumCharacters: TaxDocumentLimits.maximumEvidenceCharacters)
        var redacted = replacingKnownIdentifierValues(
            in: bounded,
            replacements: replacements,
            maximumCharacters: TaxDocumentLimits.maximumEvidenceCharacters
        )
        redacted = redactIdentifiers(
            in: redacted,
            maximumCharacters: TaxDocumentLimits.maximumEvidenceCharacters
        )
        let mixedMatches = unlabelledAlphaNumericIdentifierRegex.matches(
            in: redacted,
            range: NSRange(location: 0, length: (redacted as NSString).length)
        )
        if mixedMatches.contains(where: { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: redacted) else { return false }
            let token = redacted[valueRange]
            if isValidatedDocumentLabelToken(
                String(token),
                source: redacted as NSString,
                valueRange: match.range(at: 1)
            ) {
                return false
            }
            return token.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
                && token.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
        }) {
            return evidencePrivacyPlaceholder
        }
        if allCapsEvidenceTokenRegex.firstMatch(
            in: redacted,
            range: NSRange(location: 0, length: (redacted as NSString).length)
        ) != nil || !isClearlyOrdinaryEvidence(redacted) {
            return evidencePrivacyPlaceholder
        }
        return redacted
    }

    private static func isCanonicalMaskedIdentifier(_ value: String) -> Bool {
        let bounded = boundedText(value, maximumCharacters: TaxDocumentLimits.maximumEvidenceCharacters)
        let range = NSRange(location: 0, length: (bounded as NSString).length)
        return canonicalMaskedIdentifierRegex.firstMatch(in: bounded, range: range)?.range == range
    }

    private static func containsUntrustedReferenceMaterial(
        in text: String,
        visibleSuffixes: Set<String>
    ) -> Bool {
        let bounded = boundedText(text, maximumCharacters: TaxDocumentLimits.maximumFieldCharacters)
        let fullRange = NSRange(location: 0, length: (bounded as NSString).length)
        if secretReferenceSpanRegex.firstMatch(in: bounded, range: fullRange) != nil {
            return true
        }

        let source = bounded as NSString
        for match in referenceValueRegex.matches(in: bounded, range: fullRange) {
            guard match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else { continue }
            let token = source.substring(with: match.range(at: 1))
            let hasIdentifierMaterial = token.unicodeScalars.contains {
                CharacterSet.decimalDigits.contains($0) || $0 == "*"
            }
            guard hasIdentifierMaterial else { continue }
            if !isCanonicalMaskedIdentifier(token) {
                return true
            }
        }

        guard !visibleSuffixes.isEmpty else { return false }
        var residual = replacingMatches(ordinaryDateSpanRegex, in: bounded)
        residual = replacingMatches(ordinaryDecimalAmountSpanRegex, in: residual)
        residual = replacingMatches(ordinaryYearSpanRegex, in: residual)
        residual = replacingMatches(ordinaryEvidencePageSpanRegex, in: residual)
        residual = replacingMatches(ordinaryIdentifierEndingSpanRegex, in: residual)
        residual = replacingMatches(canonicalMaskedIdentifierRegex, in: residual)
        let residualSource = residual as NSString
        let residualRange = NSRange(location: 0, length: residualSource.length)
        for match in standaloneNumberRegex.matches(in: residual, range: residualRange) {
            guard match.numberOfRanges > 1 else { continue }
            let token = residualSource.substring(with: match.range(at: 1))
            if visibleSuffixes.contains(where: { token.hasSuffix($0) }) {
                return true
            }
        }
        return false
    }

    static func sanitizePublishedField(
        _ text: String,
        maximumCharacters: Int = TaxDocumentLimits.maximumFieldCharacters,
        replacements: [String: String] = [:],
        visibleSuffixes: Set<String> = []
    ) -> String {
        let bounded = boundedText(text, maximumCharacters: maximumCharacters)
        let replaced = replacingKnownIdentifierValues(
            in: bounded,
            replacements: replacements,
            maximumCharacters: maximumCharacters
        )
        var redacted = redactIdentifiers(
            in: replaced,
            maximumCharacters: maximumCharacters
        )
        redacted = redactUnlabelledAlphaNumericIdentifiers(
            in: redacted,
            maximumCharacters: maximumCharacters
        )
        if containsUntrustedReferenceMaterial(in: redacted, visibleSuffixes: visibleSuffixes) {
            return evidencePrivacyPlaceholder
        }
        return boundedText(redacted, maximumCharacters: maximumCharacters)
    }

    static func sanitizePageText(_ text: String) -> String {
        let bounded = boundedText(text, maximumCharacters: TaxDocumentLimits.maximumPageCharacters)
        var redacted = redactUnlabelledAlphaNumericIdentifiers(
            in: redactIdentifiers(in: bounded, maximumCharacters: TaxDocumentLimits.maximumPageCharacters),
            maximumCharacters: TaxDocumentLimits.maximumPageCharacters
        )
        redacted = replacingMatchRanges(secretReferenceSpanRegex, in: redacted) { _, match in
            (match.range, evidencePrivacyPlaceholder)
        }
        redacted = replacingMatchRanges(referenceValueRegex, in: redacted) { source, match in
            guard match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else { return nil }
            let token = source.substring(with: match.range(at: 1))
            let hasIdentifierMaterial = token.unicodeScalars.contains {
                CharacterSet.decimalDigits.contains($0) || $0 == "*"
            }
            guard hasIdentifierMaterial, !isCanonicalMaskedIdentifier(token) else { return nil }
            return (match.range, evidencePrivacyPlaceholder)
        }
        return boundedText(redacted, maximumCharacters: TaxDocumentLimits.maximumPageCharacters)
    }

    /// The one privacy boundary for evidence snippets. Every evidence field
    /// uses this bounded strict pass before it can be held in memory or
    /// serialized. Identifier replacements are applied first so a known
    /// candidate can retain its canonical mask; the strict classifier then
    /// withholds anything that still contains untrusted reference material.
    static func sanitizeEvidenceSnippet(
        _ text: String,
        replacements: [String: String] = [:]
    ) -> String {
        let bounded = boundedText(
            text,
            maximumCharacters: TaxDocumentLimits.maximumEvidenceCharacters
        )
        let sanitized = redactIdentifierEvidence(bounded, replacements: replacements)
        return boundedText(
            sanitized,
            maximumCharacters: TaxDocumentLimits.maximumEvidenceCharacters
        )
    }

    static func maskIdentifierValue(_ value: String) -> String {
        let trimmed = boundedText(value, maximumCharacters: TaxDocumentLimits.maximumFieldCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let boundedLine = boundedText(line, maximumCharacters: TaxDocumentLimits.maximumFieldCharacters)
        guard let labelRange = boundedLine.range(of: label, options: .caseInsensitive) else {
            return redactIdentifiers(in: boundedLine)
        }
        let suffix = String(boundedLine[labelRange.upperBound...])
        let valueRegex = try? NSRegularExpression(
            pattern: #"(?i)^[ \t]*[:#-]?[ \t]*(?:([0-9*]{2}[ \t/.-][0-9*]{3}[ \t/.-][0-9*]{5}|[0-9*]{2}(?:[ \t][0-9*]{3}){3}|(?:[0-9*]{3}[ \t]){3}[0-9*]{2}|[0-9*]{11,30}|\*+[0-9]{1,30}|(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z*][0-9A-Z*./-]{0,30}|[0-9A-Z*][0-9A-Z*./-]{0,30}))(?![0-9A-Z*./-])"#
        )
        guard let valueRegex,
              let match = valueRegex.firstMatch(in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length)),
              let valueEnd = Range(match.range, in: suffix) else {
            return redactIdentifiers(in: line)
        }
        let field = String(boundedLine[..<labelRange.upperBound]) + String(suffix[..<valueEnd.upperBound])
        return redactIdentifiers(in: field).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func maskIdentifier(_ value: String) -> String {
        let trimmed = boundedText(value, maximumCharacters: TaxDocumentLimits.maximumFieldCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

}

public struct TaxEvidence: Codable, Equatable, Sendable {
    public let page: Int
    public let snippet: String

    public init(page: Int, snippet: String) {
        self.page = max(1, page)
        self.snippet = TaxPrivacy.sanitizeEvidenceSnippet(snippet)
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
        try container.encode(
            TaxPrivacy.sanitizeEvidenceSnippet(snippet),
            forKey: .snippet
        )
    }
}

public struct TaxDate: Codable, Equatable, Sendable {
    public var value: String
    public var evidence: TaxEvidence

    public init(value: String, evidence: TaxEvidence) {
        let redacted = TaxPrivacy.sanitizePublishedField(
            value,
            maximumCharacters: TaxDocumentLimits.maximumFieldCharacters
        )
        self.value = String(redacted.prefix(TaxDocumentLimits.maximumFieldCharacters))
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
        let redacted = TaxPrivacy.sanitizePublishedField(
            value,
            maximumCharacters: TaxDocumentLimits.maximumFieldCharacters
        )
        try container.encode(redacted, forKey: .value)
        try container.encode(evidence, forKey: .evidence)
    }
}

public struct TaxAmount: Codable, Equatable, Sendable {
    public var value: String
    public var label: String
    public var evidence: TaxEvidence

    public init(value: String, label: String, evidence: TaxEvidence) {
        let redactedValue = TaxPrivacy.sanitizePublishedField(
            value,
            maximumCharacters: TaxDocumentLimits.maximumFieldCharacters
        )
        let redactedLabel = TaxPrivacy.sanitizePublishedField(
            label,
            maximumCharacters: TaxDocumentLimits.maximumFieldCharacters
        )
        self.value = String(redactedValue.prefix(TaxDocumentLimits.maximumFieldCharacters))
        self.label = String(redactedLabel.prefix(TaxDocumentLimits.maximumFieldCharacters))
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
        let redactedValue = TaxPrivacy.sanitizePublishedField(
            value,
            maximumCharacters: TaxDocumentLimits.maximumFieldCharacters
        )
        let redactedLabel = TaxPrivacy.sanitizePublishedField(
            label,
            maximumCharacters: TaxDocumentLimits.maximumFieldCharacters
        )
        try container.encode(redactedValue, forKey: .value)
        try container.encode(redactedLabel, forKey: .label)
        try container.encode(evidence, forKey: .evidence)
    }
}

public struct TaxCandidate: Codable, Equatable, Sendable {
    public var value: String
    public var evidence: TaxEvidence

    public init(value: String, evidence: TaxEvidence) {
        let redacted = TaxPrivacy.sanitizePublishedField(
            value,
            maximumCharacters: TaxDocumentLimits.maximumFieldCharacters
        )
        self.value = String(redacted.prefix(TaxDocumentLimits.maximumFieldCharacters))
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
        let redacted = TaxPrivacy.sanitizePublishedField(
            value,
            maximumCharacters: TaxDocumentLimits.maximumFieldCharacters
        )
        try container.encode(redacted, forKey: .value)
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
                TaxCandidate(value: $0, evidence: TaxEvidence(page: 1, snippet: $0))
            },
            referenceIdentifier: referenceIdentifier.map {
                TaxCandidate(value: $0, evidence: TaxEvidence(page: 1, snippet: $0))
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
        let replacements = TaxPrivacy.identifierReplacements(
            for: [taxpayerIdentifier, referenceIdentifier]
        )
        let visibleSuffixes = TaxPrivacy.visibleIdentifierSuffixes(
            for: [taxpayerIdentifier, referenceIdentifier]
        )
        self.id = id
        self.title = Self.redactedField(
            title,
            replacements: replacements,
            visibleSuffixes: visibleSuffixes
        )
        self.documentType = Self.redactedField(
            documentType,
            replacements: replacements,
            visibleSuffixes: visibleSuffixes
        )
        self.taxYear = taxYear
        self.issuer = Self.redactedTextCandidate(
            issuer,
            replacements: replacements,
            visibleSuffixes: visibleSuffixes
        )
        self.taxpayerIdentifier = Self.redactedIdentifierCandidate(
            taxpayerIdentifier,
            replacements: replacements
        )
        self.referenceIdentifier = Self.redactedIdentifierCandidate(
            referenceIdentifier,
            replacements: replacements
        )
        self.dates = dates.prefix(TaxDocumentLimits.maximumDates).map {
            Self.redactedDate(
                $0,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            )
        }
        self.amounts = amounts.prefix(TaxDocumentLimits.maximumAmounts).map {
            Self.redactedAmount(
                $0,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            )
        }
        self.pages = Self.boundedPagesForParsing(
            pages,
            replacements: replacements
        ).pages
        self.warnings = Array(warnings.prefix(TaxDocumentLimits.maximumWarnings)).map {
            Self.redactedField(
                $0,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            )
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
        let replacements = TaxPrivacy.identifierReplacements(
            for: [taxpayerIdentifier, referenceIdentifier]
        )
        let visibleSuffixes = TaxPrivacy.visibleIdentifierSuffixes(
            for: [taxpayerIdentifier, referenceIdentifier]
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(
            Self.redactedField(
                title,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            ),
            forKey: .title
        )
        try container.encode(
            Self.redactedField(
                documentType,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            ),
            forKey: .documentType
        )
        try container.encodeIfPresent(taxYear, forKey: .taxYear)
        try container.encode(
            Self.redactedTextCandidate(
                issuer,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            ),
            forKey: .issuer
        )
        try container.encode(
            Self.redactedIdentifierCandidate(taxpayerIdentifier, replacements: replacements),
            forKey: .taxpayerIdentifier
        )
        try container.encode(
            Self.redactedIdentifierCandidate(referenceIdentifier, replacements: replacements),
            forKey: .referenceIdentifier
        )
        try container.encode(
            dates.map {
                Self.redactedDate(
                    $0,
                    replacements: replacements,
                    visibleSuffixes: visibleSuffixes
                )
            },
            forKey: .dates
        )
        try container.encode(
            amounts.map {
                Self.redactedAmount(
                    $0,
                    replacements: replacements,
                    visibleSuffixes: visibleSuffixes
                )
            },
            forKey: .amounts
        )
        try container.encode(
            warnings.map {
                Self.redactedField(
                    $0,
                    replacements: replacements,
                    visibleSuffixes: visibleSuffixes
                )
            },
            forKey: .warnings
        )
        try container.encode(confidence, forKey: .confidence)
        // Page text is transient extraction/review state and is intentionally
        // excluded from the ordinary document and sync representation.
    }

    private static func redactedField(
        _ value: String,
        replacements: [String: String] = [:],
        visibleSuffixes: Set<String> = []
    ) -> String {
        TaxPrivacy.sanitizePublishedField(
            value,
            replacements: replacements,
            visibleSuffixes: visibleSuffixes
        )
    }

    private static func redactedEvidence(
        _ evidence: TaxEvidence,
        replacements: [String: String]
    ) -> TaxEvidence {
        return TaxEvidence(
            page: evidence.page,
            snippet: TaxPrivacy.sanitizeEvidenceSnippet(
                evidence.snippet,
                replacements: replacements
            )
        )
    }

    private static func redactedTextCandidate(
        _ candidate: TaxCandidate?,
        replacements: [String: String],
        visibleSuffixes: Set<String>
    ) -> TaxCandidate? {
        guard let candidate else { return nil }
        let safeValue = redactedField(
            candidate.value,
            replacements: replacements,
            visibleSuffixes: visibleSuffixes
        )
        return TaxCandidate(
            value: safeValue,
            evidence: redactedEvidence(candidate.evidence, replacements: replacements)
        )
    }

    private static func redactedIdentifierCandidate(
        _ candidate: TaxCandidate?,
        replacements: [String: String]
    ) -> TaxCandidate? {
        guard let candidate else { return nil }
        let replacedValue = TaxPrivacy.replacingKnownIdentifierValues(
            in: candidate.value,
            replacements: replacements
        )
        let safeValue = TaxPrivacy.maskIdentifierValue(replacedValue)
        let safeEvidenceSnippet = TaxPrivacy.sanitizeEvidenceSnippet(
            candidate.evidence.snippet,
            replacements: replacements
        )
        return TaxCandidate(
            value: safeValue,
            evidence: TaxEvidence(page: candidate.evidence.page, snippet: safeEvidenceSnippet)
        )
    }

    private static func redactedDate(
        _ date: TaxDate,
        replacements: [String: String],
        visibleSuffixes: Set<String>
    ) -> TaxDate {
        TaxDate(
            value: redactedField(
                date.value,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            ),
            evidence: redactedEvidence(date.evidence, replacements: replacements)
        )
    }

    private static func redactedAmount(
        _ amount: TaxAmount,
        replacements: [String: String],
        visibleSuffixes: Set<String>
    ) -> TaxAmount {
        TaxAmount(
            value: redactedField(
                amount.value,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            ),
            label: redactedField(
                amount.label,
                replacements: replacements,
                visibleSuffixes: visibleSuffixes
            ),
            evidence: redactedEvidence(amount.evidence, replacements: replacements)
        )
    }

    static func boundedPagesForParsing(
        _ pages: [String],
        cancellationCheck: @escaping () -> Bool = { false }
    ) -> (pages: [String], truncated: Bool) {
        boundedPagesForParsing(
            pages,
            replacements: [:],
            cancellationCheck: cancellationCheck
        )
    }

    static func boundedPagesForParsing(
        _ pages: [String],
        replacements: [String: String],
        cancellationCheck: @escaping () -> Bool = { false }
    ) -> (pages: [String], truncated: Bool) {
        var remainingInputBytes = TaxDocumentLimits.maximumTotalPageBytes
        var remainingOutputBytes = TaxDocumentLimits.maximumTotalPageBytes
        var truncated = pages.count > TaxDocumentLimits.maximumPages
        var bounded: [String] = []
        bounded.reserveCapacity(min(pages.count, TaxDocumentLimits.maximumPages))
        for page in pages.prefix(TaxDocumentLimits.maximumPages) {
            if cancellationCheck() {
                truncated = true
                break
            }

            let characterPrefix = page.prefix(TaxDocumentLimits.maximumPageCharacters)
            let characterBounded = String(characterPrefix)
            truncated = truncated || characterPrefix.endIndex != page.endIndex
            guard remainingInputBytes > 0 else {
                truncated = true
                bounded.append("")
                continue
            }

            let boundedInput = TaxPrivacy.boundedUTF8Prefix(
                characterBounded,
                maximumBytes: remainingInputBytes
            )
            truncated = truncated || boundedInput.truncated
            remainingInputBytes -= boundedInput.value.utf8.count
            guard remainingOutputBytes > 0 else {
                truncated = true
                bounded.append("")
                continue
            }

            // Check again after the cheap input bounds and immediately before
            // the regex passes, which are the expensive part of page import.
            if cancellationCheck() {
                truncated = true
                break
            }
            let replaced = TaxPrivacy.replacingKnownIdentifierValues(
                in: boundedInput.value,
                replacements: replacements,
                maximumCharacters: TaxDocumentLimits.maximumPageCharacters
            )
            let redacted = TaxPrivacy.redactIdentifiers(
                in: replaced,
                maximumCharacters: TaxDocumentLimits.maximumPageCharacters
            )
            let redactedPage = TaxPrivacy.redactUnlabelledAlphaNumericIdentifiers(
                in: redacted,
                maximumCharacters: TaxDocumentLimits.maximumPageCharacters
            )
            let sanitizedPage = TaxPrivacy.sanitizePageText(redactedPage)
            let boundedOutput = TaxPrivacy.boundedUTF8Prefix(
                sanitizedPage,
                maximumBytes: remainingOutputBytes
            )
            truncated = truncated || boundedOutput.truncated
            remainingOutputBytes -= boundedOutput.value.utf8.count
            bounded.append(boundedOutput.value)
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
        let bounded = TaxDocument.boundedPagesForParsing(
            pages,
            cancellationCheck: cancellationCheck
        )
        let cleanedPages = bounded.pages.map { $0.replacingOccurrences(of: "\u{FFFD}", with: "") }
        // boundedPagesForParsing already applies the complete privacy pass
        // from a bounded input and enforces the aggregate redacted output
        // budget. Re-running the regexes here doubled page-import work.
        let safePages = cleanedPages
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
        let pattern = #"(?i)\b(?:steuerliche[ \t]+(?:identifikationsnummer|id)|steueridentifikationsnummer|identifikationsnummer|steuer[ \t]*[-–—]?[ \t]*id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?|id[ \t]*[-–—.]?[ \t]*nr\.?|ident[ \t]*[-–—.]?[ \t]*nr\.?|tax[ \t]+identification[ \t]+number|tax[ \t]+id(?:entifier)?|taxpayer[ \t]+id(?:entifier)?|tin|steuer[- ]?nummer|id)\s*[:#-]?\s*(\*+[0-9]{2,30}|(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z*][0-9A-Z*./-]{2,30}|[0-9A-Z*][0-9A-Z*./-]{2,30})(?![0-9A-Z*./-])"#
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
