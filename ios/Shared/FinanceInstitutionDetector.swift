import Foundation

// MARK: - CSV institution detection metadata

/// Institutions represented by the versioned manual-import registry. An
/// institution can exist in the registry before a safe profile is enabled.
public enum FinanceInstitution: String, CaseIterable, Equatable, Hashable, Sendable {
    case tradeRepublic = "trade_republic"
    case robinhood
    case sparkasse
    case revolut
}

public enum FinanceInstitutionDetectionState: String, CaseIterable, Equatable, Sendable {
    case known
    case unknown
    case ambiguous
    case userMapped
}

public enum FinanceCSVDelimiter: String, CaseIterable, Equatable, Hashable, Sendable {
    case comma = ","
    case semicolon = ";"
    case tab = "\t"

    public var character: Character {
        switch self {
        case .comma: ","
        case .semicolon: ";"
        case .tab: "\t"
        }
    }

    public init?(character: Character) {
        switch character {
        case ",": self = .comma
        case ";": self = .semicolon
        case "\t": self = .tab
        default: return nil
        }
    }
}

/// Content-free reasons which can be shown in a preview or diagnostic log.
/// These values intentionally describe only detector decisions, never source
/// fields or source values.
public enum FinanceInstitutionDetectionReasonCode: String, CaseIterable, Equatable, Sendable {
    case noEligibleProfile = "no_eligible_profile"
    case duplicateNormalizedHeader = "duplicate_normalized_header"
    case missingRequiredHeader = "missing_required_header"
    case forbiddenHeaderPresent = "forbidden_header_present"
    case extraHeader = "extra_header"
    case delimiterMismatch = "delimiter_mismatch"
    case columnCountMismatch = "column_count_mismatch"
    case disabledProfile = "disabled_profile"
    case noValidEURRows = "no_valid_eur_rows"
    case ambiguousCandidates = "ambiguous_candidates"
    case unsupportedNearMatch = "unsupported_near_match"
}

/// Content-free evidence which supports a detector decision.
public enum FinanceInstitutionDetectionEvidenceCode: String, CaseIterable, Equatable, Sendable {
    case requiredHeadersPresent = "required_headers_present"
    case exactHeaderSet = "exact_header_set"
    case delimiterMatched = "delimiter_matched"
    case columnCountMatched = "column_count_matched"
    case noForbiddenHeaders = "no_forbidden_headers"
    case legacyLayoutCompatibility = "legacy_layout_compatibility"
    case validEURRow = "valid_eur_row"
}

/// Safe provenance for a detection result. It deliberately contains no file
/// name, account identifier, raw header, or row value.
public struct FinanceInstitutionDetectionProvenance: Equatable, Sendable {
    public static let currentRegistryVersion = "finance-registry-v1"
    public static let currentDetectorVersion = "finance-detector-v1"
    public static let currentNormalizationVersion = "finance-header-normalization-v1"

    public let registryVersion: String
    public let detectorVersion: String
    public let normalizationVersion: String
    public let profileID: String?
    public let profileVersion: Int?
    public let delimiter: FinanceCSVDelimiter?
    public let legacyLayoutCompatibility: Bool
    public let reasonCodes: [FinanceInstitutionDetectionReasonCode]
    public let evidenceCodes: [FinanceInstitutionDetectionEvidenceCode]

    public init(
        registryVersion: String = FinanceInstitutionDetectionProvenance.currentRegistryVersion,
        detectorVersion: String = FinanceInstitutionDetectionProvenance.currentDetectorVersion,
        normalizationVersion: String = FinanceInstitutionDetectionProvenance.currentNormalizationVersion,
        profileID: String? = nil,
        profileVersion: Int? = nil,
        delimiter: FinanceCSVDelimiter? = nil,
        legacyLayoutCompatibility: Bool = false,
        reasonCodes: [FinanceInstitutionDetectionReasonCode] = [],
        evidenceCodes: [FinanceInstitutionDetectionEvidenceCode] = []
    ) {
        self.registryVersion = registryVersion
        self.detectorVersion = detectorVersion
        self.normalizationVersion = normalizationVersion
        self.profileID = profileID
        self.profileVersion = profileVersion
        self.delimiter = delimiter
        self.legacyLayoutCompatibility = legacyLayoutCompatibility
        self.reasonCodes = reasonCodes
        self.evidenceCodes = evidenceCodes
    }
}

public struct FinanceInstitutionCandidate: Equatable, Sendable {
    public let institution: FinanceInstitution
    public let profileID: String
    public let profileVersion: Int
    public let isEnabled: Bool
    public let isEligible: Bool
    public let score: Int
    public let reasonCodes: [FinanceInstitutionDetectionReasonCode]
    public let evidenceCodes: [FinanceInstitutionDetectionEvidenceCode]

    public init(
        institution: FinanceInstitution,
        profileID: String,
        profileVersion: Int,
        isEnabled: Bool,
        isEligible: Bool,
        score: Int,
        reasonCodes: [FinanceInstitutionDetectionReasonCode] = [],
        evidenceCodes: [FinanceInstitutionDetectionEvidenceCode] = []
    ) {
        self.institution = institution
        self.profileID = profileID
        self.profileVersion = profileVersion
        self.isEnabled = isEnabled
        self.isEligible = isEligible
        self.score = score
        self.reasonCodes = reasonCodes
        self.evidenceCodes = evidenceCodes
    }
}

public struct FinanceInstitutionDetection: Equatable, Sendable {
    public let state: FinanceInstitutionDetectionState
    public let institution: FinanceInstitution?
    public let profileID: String?
    public let candidates: [FinanceInstitutionCandidate]
    public let provenance: FinanceInstitutionDetectionProvenance

    public init(
        state: FinanceInstitutionDetectionState,
        institution: FinanceInstitution? = nil,
        profileID: String? = nil,
        candidates: [FinanceInstitutionCandidate] = [],
        provenance: FinanceInstitutionDetectionProvenance = .init()
    ) {
        self.state = state
        self.institution = institution
        self.profileID = profileID
        self.candidates = candidates
        self.provenance = provenance
    }

    public static let unknown = FinanceInstitutionDetection(state: .unknown)

    public var isKnown: Bool { state == .known && institution != nil }
}

/// A registry entry is either an exact enabled schema or a disabled marker
/// profile. Disabled profiles can block an unsafe future format without
/// claiming that the format is supported.
public struct FinanceInstitutionProfile: Equatable, Sendable {
    public let id: String
    public let institution: FinanceInstitution
    public let version: Int
    public let isEnabled: Bool
    public let delimiter: FinanceCSVDelimiter?
    public let requiredHeaders: [String]
    public let allowedHeaders: [String]
    public let forbiddenHeaders: [String]
    public let legacyLayoutCompatibility: Bool
    /// Distinctive headers used to stop a recognizable but unsupported export
    /// from falling through to the generic EUR parser. These are deliberately
    /// separate from the exact fingerprint so incomplete or extended broker
    /// exports can be surfaced as mapping-required instead of being imported
    /// with the wrong semantics.
    public let nearMatchHeaders: [String]
    public let nearMatchMinimum: Int

    public init(
        id: String,
        institution: FinanceInstitution,
        version: Int = 1,
        isEnabled: Bool,
        delimiter: FinanceCSVDelimiter?,
        requiredHeaders: [String],
        allowedHeaders: [String] = [],
        forbiddenHeaders: [String] = [],
        legacyLayoutCompatibility: Bool = false,
        nearMatchHeaders: [String] = [],
        nearMatchMinimum: Int = 0
    ) {
        self.id = id
        self.institution = institution
        self.version = version
        self.isEnabled = isEnabled
        self.delimiter = delimiter
        self.requiredHeaders = financeNormalizedHeaderList(requiredHeaders)
        self.allowedHeaders = financeNormalizedHeaderList(allowedHeaders)
        self.forbiddenHeaders = financeNormalizedHeaderList(forbiddenHeaders)
        self.legacyLayoutCompatibility = legacyLayoutCompatibility
        self.nearMatchHeaders = financeNormalizedHeaderList(nearMatchHeaders)
        self.nearMatchMinimum = max(nearMatchMinimum, 0)
    }

    public var enabled: Bool { isEnabled }
    public var columnCount: Int? { allowedHeaders.isEmpty ? nil : allowedHeaders.count }
}

public enum FinanceInstitutionRegistry {
    public static let version = FinanceInstitutionDetectionProvenance.currentRegistryVersion

    private static let tradeRepublicEnglishHeaders = [
        "datetime", "date", "account_type", "category", "type", "asset_class",
        "name", "symbol", "shares", "price", "amount", "fee", "tax", "currency",
        "original_amount", "original_currency", "fx_rate", "description", "transaction_id",
        "counterparty_name", "counterparty_iban", "payment_reference", "mcc_code"
    ]

    private static let tradeRepublicGermanLegacyHeaders = ["Datum", "Typ", "Beschreibung", "Betrag"]
    private static let tradeRepublicGermanSecurityHeaders = [
        "Datum", "Typ", "Beschreibung", "Betrag", "Symbol", "Anzahl", "Kurs"
    ]

    /// The order is part of the deterministic detector contract. Do not build
    /// this collection from a Set or dictionary.
    public static let profiles: [FinanceInstitutionProfile] = [
        FinanceInstitutionProfile(
            id: "trade-republic-english-v1",
            institution: .tradeRepublic,
            isEnabled: true,
            delimiter: .comma,
            requiredHeaders: tradeRepublicEnglishHeaders,
            allowedHeaders: tradeRepublicEnglishHeaders,
            nearMatchHeaders: [
                "counterparty_name", "original_amount", "original_currency", "fx_rate",
                "transaction_id", "counterparty_iban", "payment_reference", "mcc_code"
            ],
            nearMatchMinimum: 2
        ),
        FinanceInstitutionProfile(
            id: "trade-republic-german-legacy-v1",
            institution: .tradeRepublic,
            isEnabled: true,
            delimiter: .semicolon,
            requiredHeaders: tradeRepublicGermanLegacyHeaders,
            allowedHeaders: tradeRepublicGermanLegacyHeaders,
            forbiddenHeaders: ["original_amount", "original_currency", "fx_rate", "counterparty_name"],
            legacyLayoutCompatibility: true
        ),
        FinanceInstitutionProfile(
            id: "trade-republic-german-security-legacy-v1",
            institution: .tradeRepublic,
            isEnabled: true,
            delimiter: .semicolon,
            requiredHeaders: tradeRepublicGermanSecurityHeaders,
            allowedHeaders: tradeRepublicGermanSecurityHeaders,
            forbiddenHeaders: ["original_amount", "original_currency", "fx_rate", "counterparty_name"],
            legacyLayoutCompatibility: true,
            // Security fields are distinctive enough to stop an extended or
            // incomplete investment export from becoming generic cash.
            nearMatchHeaders: ["Symbol", "Anzahl", "Kurs"],
            nearMatchMinimum: 2
        ),
        FinanceInstitutionProfile(
            id: "robinhood-disabled-v1",
            institution: .robinhood,
            isEnabled: false,
            // The marker is intentionally delimiter-independent. A user
            // export with these distinctive columns must be blocked even when
            // the portal changes separator or adds a preamble.
            delimiter: nil,
            requiredHeaders: ["Activity Date", "Trans Code", "Net Amount"],
            nearMatchHeaders: ["Activity Date", "Trans Code", "Net Amount"],
            nearMatchMinimum: 2
        ),
        FinanceInstitutionProfile(
            id: "sparkasse-disabled-v1",
            institution: .sparkasse,
            isEnabled: false,
            delimiter: nil,
            requiredHeaders: ["Buchungstag", "Umsatz"],
            nearMatchHeaders: ["Buchungstag", "Umsatz"],
            nearMatchMinimum: 2
        ),
        FinanceInstitutionProfile(
            id: "revolut-disabled-v1",
            institution: .revolut,
            isEnabled: false,
            delimiter: nil,
            requiredHeaders: ["Completed Date", "Amount", "Currency", "State"],
            nearMatchHeaders: ["Completed Date", "Currency", "State"],
            nearMatchMinimum: 2
        )
    ]

    public static let institutions: [FinanceInstitution] = [
        .tradeRepublic, .robinhood, .sparkasse, .revolut
    ]

    public static var enabledProfiles: [FinanceInstitutionProfile] {
        profiles.filter(\.isEnabled)
    }

    public static var disabledProfiles: [FinanceInstitutionProfile] {
        profiles.filter { !$0.isEnabled }
    }
}

private func financeNormalizedHeader(_ value: String) -> String {
    var folded = value
        .replacingOccurrences(of: "\u{FEFF}", with: "")
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()

    // Foundation's folding is supplemented with stable transliterations for
    // characters it does not normalize consistently across platforms.
    for (source, replacement) in [
        ("ß", "ss"),
        ("æ", "ae"), ("ø", "o"), ("ð", "d"), ("þ", "th"),
        ("ł", "l")
    ] {
        folded = folded.replacingOccurrences(of: source, with: replacement)
    }

    let compact = folded.unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map(String.init)
        .joined()

    // Apply only known header aliases after punctuation has been removed.
    // A global "ue"/"oe"/"ae" rewrite would corrupt ordinary English words
    // such as "value" and is not idempotent for all inputs.
    switch compact {
    case "waehrung": return "wahrung"
    case "stueck": return "stuck"
    case "empfaenger": return "empfanger"
    case "transaktionsid": return "transactionid"
    default: return compact
    }
}

private func financeNormalizedHeaderList(_ headers: [String]) -> [String] {
    headers.map(financeNormalizedHeader)
}

public enum FinanceInstitutionDetector {
    public static let version = FinanceInstitutionDetectionProvenance.currentDetectorVersion
    public static let normalizationVersion = FinanceInstitutionDetectionProvenance.currentNormalizationVersion

    public static func normalizeHeader(_ value: String) -> String {
        financeNormalizedHeader(value)
    }

    public static func normalizedHeaders(_ headers: [String]) -> [String] {
        financeNormalizedHeaderList(headers)
    }

    public static func hasDuplicateNormalizedHeaders(_ headers: [String]) -> Bool {
        let normalized = normalizedHeaders(headers)
        return Set(normalized).count != normalized.count
    }

    /// Returns whether the header row contains a registry fingerprint for any
    /// registered delimiter. Header and forbidden-field checks are still
    /// applied; callers with a parsed delimiter should use
    /// `hasImporterFingerprint(headers:delimiter:)`.
    public static func hasRegistryFingerprint(headers: [String]) -> Bool {
        let normalized = normalizedHeaders(headers)
        guard !normalized.isEmpty, Set(normalized).count == normalized.count else { return false }
        return FinanceCSVDelimiter.allCases.contains {
            hasImporterFingerprint(headers: headers, delimiter: $0)
        }
    }

    /// Returns whether a source header matches a registered profile under the
    /// supplied delimiter. This is intentionally independent of generic date
    /// and amount headers so disabled marker profiles can be surfaced as
    /// unsupported metadata without ever becoming importable.
    public static func hasImporterFingerprint(
        headers: [String],
        delimiter: FinanceCSVDelimiter
    ) -> Bool {
        let normalized = normalizedHeaders(headers)
        guard !normalized.isEmpty, Set(normalized).count == normalized.count else { return false }
        return FinanceInstitutionRegistry.profiles.contains {
            candidate(for: $0, headers: normalized, delimiter: delimiter).isEligible
        }
    }

    /// Returns true for an exact disabled marker or a distinctive incomplete
    /// profile. Importers must use this before generic column mapping so a
    /// brokerage export cannot silently become an ordinary EUR cash ledger.
    public static func hasUnsupportedNearMatch(
        headers: [String],
        delimiter: FinanceCSVDelimiter
    ) -> Bool {
        let normalized = Self.normalizedHeaders(headers)
        guard !normalized.isEmpty, Set(normalized).count == normalized.count else { return false }
        return FinanceInstitutionRegistry.profiles.contains { profile in
            let candidate = Self.candidate(for: profile, headers: normalized, delimiter: delimiter)
            return (!profile.isEnabled && candidate.isEligible)
                || Self.isNearMatch(profile: profile, normalizedHeaders: normalized, delimiter: delimiter)
        }
    }

    /// Detects only from a hard eligible fingerprint. `validEURRowCount` is
    /// optional so callers can inspect header eligibility; import confirmation
    /// passes the parsed valid-row count and therefore cannot become known for
    /// header-only or all-invalid input.
    public static func detect(
        headers: [String],
        delimiter: FinanceCSVDelimiter,
        validEURRowCount: Int? = nil
    ) -> FinanceInstitutionDetection {
        let normalizedHeaders = Self.normalizedHeaders(headers)
        guard !normalizedHeaders.isEmpty else {
            return FinanceInstitutionDetection(
                state: .unknown,
                provenance: FinanceInstitutionDetectionProvenance(
                    delimiter: delimiter,
                    reasonCodes: [.noEligibleProfile]
                )
            )
        }

        guard Set(normalizedHeaders).count == normalizedHeaders.count else {
            return FinanceInstitutionDetection(
                state: .unknown,
                provenance: FinanceInstitutionDetectionProvenance(
                    delimiter: delimiter,
                    reasonCodes: [.duplicateNormalizedHeader]
                )
            )
        }

        let candidates = FinanceInstitutionRegistry.profiles.map {
            candidate(for: $0, headers: normalizedHeaders, delimiter: delimiter)
        }

        if let disabled = candidates.first(where: { !$0.isEnabled && $0.isEligible }) {
            return FinanceInstitutionDetection(
                state: .unknown,
                profileID: disabled.profileID,
                candidates: candidates,
                provenance: FinanceInstitutionDetectionProvenance(
                    profileID: disabled.profileID,
                    profileVersion: disabled.profileVersion,
                    delimiter: delimiter,
                    reasonCodes: [.disabledProfile],
                    evidenceCodes: disabled.evidenceCodes
                )
            )
        }

        if let nearMatch = FinanceInstitutionRegistry.profiles.first(where: {
            isNearMatch(profile: $0, normalizedHeaders: normalizedHeaders, delimiter: delimiter)
        }) {
            let candidate = candidates.first { $0.profileID == nearMatch.id }
            return FinanceInstitutionDetection(
                state: .unknown,
                profileID: nearMatch.id,
                candidates: candidates,
                provenance: FinanceInstitutionDetectionProvenance(
                    profileID: nearMatch.id,
                    profileVersion: nearMatch.version,
                    delimiter: delimiter,
                    legacyLayoutCompatibility: nearMatch.legacyLayoutCompatibility,
                    reasonCodes: [.unsupportedNearMatch],
                    evidenceCodes: candidate?.evidenceCodes ?? []
                )
            )
        }

        let eligible = candidates.filter { $0.isEnabled && $0.isEligible }
        guard let best = eligible.max(by: { $0.score < $1.score }) else {
            return FinanceInstitutionDetection(
                state: .unknown,
                candidates: candidates,
                provenance: FinanceInstitutionDetectionProvenance(
                    delimiter: delimiter,
                    reasonCodes: [.noEligibleProfile]
                )
            )
        }

        let tied = eligible.filter { $0.score == best.score }
        guard tied.count == 1 else {
            return FinanceInstitutionDetection(
                state: .ambiguous,
                candidates: candidates,
                provenance: FinanceInstitutionDetectionProvenance(
                    delimiter: delimiter,
                    reasonCodes: [.ambiguousCandidates]
                )
            )
        }

        if let validEURRowCount, validEURRowCount <= 0 {
            return FinanceInstitutionDetection(
                state: .unknown,
                profileID: best.profileID,
                candidates: candidates,
                provenance: FinanceInstitutionDetectionProvenance(
                    profileID: best.profileID,
                    profileVersion: best.profileVersion,
                    delimiter: delimiter,
                    legacyLayoutCompatibility: best.evidenceCodes.contains(.legacyLayoutCompatibility),
                    reasonCodes: [.noValidEURRows],
                    evidenceCodes: best.evidenceCodes
                )
            )
        }

        var evidence = best.evidenceCodes
        if validEURRowCount.map({ $0 > 0 }) == true, !evidence.contains(.validEURRow) {
            evidence.append(.validEURRow)
        }
        return FinanceInstitutionDetection(
            state: .known,
            institution: best.institution,
            profileID: best.profileID,
            candidates: candidates,
            provenance: FinanceInstitutionDetectionProvenance(
                profileID: best.profileID,
                profileVersion: best.profileVersion,
                delimiter: delimiter,
                legacyLayoutCompatibility: best.evidenceCodes.contains(.legacyLayoutCompatibility),
                evidenceCodes: evidence
            )
        )
    }

    private static func candidate(
        for profile: FinanceInstitutionProfile,
        headers: [String],
        delimiter: FinanceCSVDelimiter
    ) -> FinanceInstitutionCandidate {
        let headerSet = Set(headers)
        var reasons: [FinanceInstitutionDetectionReasonCode] = []
        var evidence: [FinanceInstitutionDetectionEvidenceCode] = []

        if let expectedDelimiter = profile.delimiter {
            if expectedDelimiter == delimiter {
                evidence.append(.delimiterMatched)
            } else {
                reasons.append(.delimiterMismatch)
            }
        }

        let required = Set(profile.requiredHeaders)
        if required.isSubset(of: headerSet) {
            evidence.append(.requiredHeadersPresent)
        } else {
            reasons.append(.missingRequiredHeader)
        }

        let forbidden = Set(profile.forbiddenHeaders)
        if headerSet.isDisjoint(with: forbidden) {
            evidence.append(.noForbiddenHeaders)
        } else {
            reasons.append(.forbiddenHeaderPresent)
        }

        let isMarkerProfile = !profile.isEnabled && profile.allowedHeaders.isEmpty
        if isMarkerProfile {
            let isEligible = required.isSubset(of: headerSet)
                && !reasons.contains(.delimiterMismatch)
                && !reasons.contains(.forbiddenHeaderPresent)
            if isEligible {
                reasons = [.disabledProfile]
                evidence = evidence.filter { $0 != .noForbiddenHeaders }
            }
            return FinanceInstitutionCandidate(
                institution: profile.institution,
                profileID: profile.id,
                profileVersion: profile.version,
                isEnabled: profile.isEnabled,
                isEligible: isEligible,
                score: isEligible ? 100 : 0,
                reasonCodes: reasons,
                evidenceCodes: evidence
            )
        }

        if headers.count == profile.allowedHeaders.count {
            evidence.append(.columnCountMatched)
        } else {
            reasons.append(.columnCountMismatch)
        }

        if headerSet == Set(profile.allowedHeaders) {
            evidence.append(.exactHeaderSet)
        } else if !headerSet.subtracting(profile.allowedHeaders).isEmpty {
            reasons.append(.extraHeader)
        }

        if profile.legacyLayoutCompatibility {
            evidence.append(.legacyLayoutCompatibility)
        }

        let isEligible = reasons.isEmpty
        return FinanceInstitutionCandidate(
            institution: profile.institution,
            profileID: profile.id,
            profileVersion: profile.version,
            isEnabled: profile.isEnabled,
            isEligible: isEligible,
            score: isEligible ? 100 + evidence.count : 0,
            reasonCodes: reasons,
            evidenceCodes: evidence
        )
    }

    private static func isNearMatch(
        profile: FinanceInstitutionProfile,
        normalizedHeaders: [String],
        delimiter: FinanceCSVDelimiter
    ) -> Bool {
        guard !profile.nearMatchHeaders.isEmpty,
              profile.nearMatchMinimum > 0 else { return false }
        let headerSet = Set(normalizedHeaders)
        let protectedMatches = profile.nearMatchHeaders.reduce(into: 0) { count, header in
            if headerSet.contains(header) { count += 1 }
        }
        guard protectedMatches >= profile.nearMatchMinimum else { return false }
        let exactCandidate = candidate(for: profile, headers: normalizedHeaders, delimiter: delimiter)
        return !exactCandidate.isEligible
    }
}
