import Foundation

// MARK: - Read-only Germany-capable barcode lookup contract

public enum NutritionBarcodeInputError: Error, Equatable, Sendable {
    case invalidBarcode
    case invalidResponse
    case invalidProposal
}

public enum NutritionBarcodeNormalizer {
    /// Returns canonical EAN-8/EAN-13 digits. UPC-A is checksum-validated and
    /// represented as EAN-13 with a leading zero. Scanner and manual input use
    /// the same path, and no other symbology is accepted in this tranche.
    public static func normalize(_ input: String) -> String? {
        guard input.utf8.count <= 32 else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ $0.value == 45 || $0.value == 32 || $0.value == 9 || (48...57).contains($0.value) }) else { return nil }
        let digits = String(trimmed.unicodeScalars.filter { (48...57).contains($0.value) })
        let nonSeparatorCount = trimmed.unicodeScalars.filter { $0.value != 32 && $0.value != 9 && $0.value != 45 }.count
        guard [8, 12, 13].contains(digits.count), digits.count == nonSeparatorCount,
              validChecksum(digits) else { return nil }
        return digits.count == 12 ? "0\(digits)" : digits
    }

    private static func validChecksum(_ digits: String) -> Bool {
        guard let check = digits.last.flatMap({ Int(String($0)) }) else { return false }
        let data = digits.dropLast()
        var sum = 0
        var weight = 3
        for character in data.reversed() {
            guard let value = Int(String(character)) else { return false }
            sum += value * weight
            weight = weight == 3 ? 1 : 3
        }
        return (10 - sum % 10) % 10 == check
    }
}

/// Locale-neutral parser for editable kcal/macronutrient fields. German comma
/// decimals are accepted, while exponent notation, signs, NaN, and excessive
/// precision are rejected before values reach a local record.
public enum NutritionBarcodeValueParser {
    public static func parse(_ input: String, maximum: Double) -> Double? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.range(of: #"^[0-9]+([.,][0-9]{1,3})?$"#, options: .regularExpression) != nil else { return nil }
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized), parsed.isFinite, parsed >= 0, parsed <= maximum else { return nil }
        return parsed
    }
}

private struct NutritionBarcodeAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownBarcodeKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: NutritionBarcodeAnyCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown nutrition barcode field"))
    }
}

private func decodeBarcodeOptional<T: Decodable, Key: CodingKey>(_ type: T.Type, forKey key: Key, from container: KeyedDecodingContainer<Key>) throws -> T? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw DecodingError.valueNotFound(type, .init(codingPath: container.codingPath + [key], debugDescription: "Explicit null is not accepted"))
    }
    return try container.decode(type, forKey: key)
}

public enum NutritionBarcodeLookupState: String, Codable, Sendable {
    case found
    case notFound = "not_found"
    case unavailable
}

public enum NutritionBarcodeReason: String, Codable, Sendable {
    case upstreamTimeout = "upstream_timeout"
    case upstreamRateLimited = "upstream_rate_limited"
    case upstreamUnavailable = "upstream_unavailable"
    case upstreamRedirect = "upstream_redirect"
    case upstreamOversized = "upstream_oversized"
    case invalidResponse = "invalid_response"
    case configurationUnavailable = "configuration_unavailable"
}

public enum NutritionBarcodeDataState: String, Codable, Sendable {
    case complete
    case partial
    case unreliable
    case unavailable
}

public enum NutritionBarcodeQualityFlag: String, Codable, Sendable {
    case providerQualityError = "provider_quality_error"
    case providerQualityWarning = "provider_quality_warning"
}

public struct NutritionBarcodeMacros: Codable, Equatable, Sendable {
    public let kcal: Double?
    public let proteinGrams: Double?
    public let carbsGrams: Double?
    public let fatGrams: Double?

    private enum CodingKeys: String, CodingKey { case kcal, proteinGrams, carbsGrams, fatGrams }

    public init(kcal: Double? = nil, proteinGrams: Double? = nil, carbsGrams: Double? = nil, fatGrams: Double? = nil) throws {
        self.kcal = kcal; self.proteinGrams = proteinGrams; self.carbsGrams = carbsGrams; self.fatGrams = fatGrams
        try validate(per100g: false)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownBarcodeKeys(decoder, allowed: ["kcal", "proteinGrams", "carbsGrams", "fatGrams"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kcal = try decodeBarcodeOptional(Double.self, forKey: .kcal, from: container)
        proteinGrams = try decodeBarcodeOptional(Double.self, forKey: .proteinGrams, from: container)
        carbsGrams = try decodeBarcodeOptional(Double.self, forKey: .carbsGrams, from: container)
        fatGrams = try decodeBarcodeOptional(Double.self, forKey: .fatGrams, from: container)
        try validate(per100g: false)
    }

    fileprivate func validate(per100g: Bool) throws {
        guard kcal != nil || proteinGrams != nil || carbsGrams != nil || fatGrams != nil else { throw NutritionBarcodeInputError.invalidResponse }
        let kcalLimit = per100g ? 1_000.0 : 5_000.0
        let macroLimit = per100g ? 100.0 : 2_000.0
        for (value, limit) in [(kcal, kcalLimit), (proteinGrams, macroLimit), (carbsGrams, macroLimit), (fatGrams, macroLimit)] {
            if let value, (!value.isFinite || value < 0 || value > limit) { throw NutritionBarcodeInputError.invalidResponse }
        }
    }

    fileprivate var isComplete: Bool { kcal != nil && proteinGrams != nil && carbsGrams != nil && fatGrams != nil }
}

public struct NutritionBarcodeProduct: Codable, Equatable, Sendable {
    public let name: String?
    public let brand: String?
    public let quantity: String?
    public let servingSize: String?
    public let countriesTags: [String]?

    private enum CodingKeys: String, CodingKey { case name, brand, quantity, servingSize, countriesTags }

    public init(name: String? = nil, brand: String? = nil, quantity: String? = nil, servingSize: String? = nil, countriesTags: [String]? = nil) throws {
        self.name = name; self.brand = brand; self.quantity = quantity; self.servingSize = servingSize; self.countriesTags = countriesTags
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownBarcodeKeys(decoder, allowed: ["name", "brand", "quantity", "servingSize", "countriesTags"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try decodeBarcodeOptional(String.self, forKey: .name, from: container)
        brand = try decodeBarcodeOptional(String.self, forKey: .brand, from: container)
        quantity = try decodeBarcodeOptional(String.self, forKey: .quantity, from: container)
        servingSize = try decodeBarcodeOptional(String.self, forKey: .servingSize, from: container)
        countriesTags = try decodeBarcodeOptional([String].self, forKey: .countriesTags, from: container)
        try validate()
    }

    private func validate() throws {
        for value in [name, brand, quantity, servingSize] {
            if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.utf8.count > 240 { throw NutritionBarcodeInputError.invalidResponse }
        }
        if let countriesTags, countriesTags.count > 50 || countriesTags.contains(where: { $0.isEmpty || $0.utf8.count > 120 }) { throw NutritionBarcodeInputError.invalidResponse }
    }
}

public struct NutritionBarcodeProvenance: Codable, Equatable, Sendable {
    public let source: String
    public let apiVersion: String
    public let apiURL: String
    public let productURL: String?
    public let fetchedAt: String
    public let databaseLicense: String
    public let contentLicense: String
    public let attribution: String
    public let dataQualityWarning: String

    private enum CodingKeys: String, CodingKey { case source, apiVersion, apiURL, productURL, fetchedAt, databaseLicense, contentLicense, attribution, dataQualityWarning }

    public init(from decoder: Decoder) throws {
        try rejectUnknownBarcodeKeys(decoder, allowed: ["source", "apiVersion", "apiURL", "productURL", "fetchedAt", "databaseLicense", "contentLicense", "attribution", "dataQualityWarning"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        apiVersion = try container.decode(String.self, forKey: .apiVersion)
        apiURL = try container.decode(String.self, forKey: .apiURL)
        productURL = try decodeBarcodeOptional(String.self, forKey: .productURL, from: container)
        fetchedAt = try container.decode(String.self, forKey: .fetchedAt)
        databaseLicense = try container.decode(String.self, forKey: .databaseLicense)
        contentLicense = try container.decode(String.self, forKey: .contentLicense)
        attribution = try container.decode(String.self, forKey: .attribution)
        dataQualityWarning = try container.decode(String.self, forKey: .dataQualityWarning)
        guard source == "openfoodfacts", apiVersion == "v3.6", databaseLicense == "ODbL-1.0", contentLicense == "DbCL-1.0",
              dataQualityWarning == "Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed.",
              apiURL.utf8.count <= 2_048,
              productURL == nil || productURL!.utf8.count <= 2_048,
              fetchedAt.utf8.count <= 40,
              !attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              attribution.utf8.count <= 500,
              NutritionBarcodeISO8601.isValid(fetchedAt),
              let apiComponents = URLComponents(string: apiURL), apiComponents.scheme == "https", apiComponents.host == "world.openfoodfacts.org",
              productURL == nil || (URLComponents(string: productURL!)?.scheme == "https" && URLComponents(string: productURL!)?.host == "world.openfoodfacts.org") else { throw NutritionBarcodeInputError.invalidResponse }
    }
}

private enum NutritionBarcodeISO8601 {
    static func isValid(_ value: String) -> Bool {
        guard value.utf8.count <= 40 else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

public struct NutritionBarcodeFound: Equatable, Sendable {
    public let barcode: String
    public let product: NutritionBarcodeProduct
    public let nutritionState: NutritionBarcodeDataState
    public let per100g: NutritionBarcodeMacros?
    public let perServing: NutritionBarcodeMacros?
    public let qualityFlags: [NutritionBarcodeQualityFlag]?
    public let provenance: NutritionBarcodeProvenance

    fileprivate init(barcode: String, product: NutritionBarcodeProduct, nutritionState: NutritionBarcodeDataState,
                     per100g: NutritionBarcodeMacros?, perServing: NutritionBarcodeMacros?, qualityFlags: [NutritionBarcodeQualityFlag]?, provenance: NutritionBarcodeProvenance) throws {
        self.barcode = barcode; self.product = product; self.nutritionState = nutritionState; self.per100g = per100g; self.perServing = perServing; self.qualityFlags = qualityFlags; self.provenance = provenance
        if let per100g { try per100g.validate(per100g: true) }
        if let perServing { try perServing.validate(per100g: false) }
        let hasNutrition = per100g != nil || perServing != nil
        let completeBasis = per100g?.isComplete == true || perServing?.isComplete == true
        guard nutritionState == .unavailable ? !hasNutrition && qualityFlags == nil : hasNutrition else { throw NutritionBarcodeInputError.invalidResponse }
        guard nutritionState != .complete || completeBasis else { throw NutritionBarcodeInputError.invalidResponse }
        guard nutritionState != .partial || !completeBasis else { throw NutritionBarcodeInputError.invalidResponse }
        guard nutritionState == .unreliable ? !(qualityFlags ?? []).isEmpty : qualityFlags == nil else { throw NutritionBarcodeInputError.invalidResponse }
        if let qualityFlags, Set(qualityFlags).count != qualityFlags.count { throw NutritionBarcodeInputError.invalidResponse }
    }
}

public enum NutritionBarcodeLookup: Decodable, Equatable, Sendable {
    case found(NutritionBarcodeFound)
    case notFound(barcode: String, provenance: NutritionBarcodeProvenance)
    case unavailable(barcode: String, reason: NutritionBarcodeReason, retryAfterSeconds: Int?, provenance: NutritionBarcodeProvenance)

    public var state: NutritionBarcodeLookupState {
        switch self { case .found: return .found; case .notFound: return .notFound; case .unavailable: return .unavailable }
    }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: NutritionBarcodeAnyCodingKey.self)
        guard let state = try all.decodeIfPresent(String.self, forKey: .init(stringValue: "state")!) else { throw NutritionBarcodeInputError.invalidResponse }
        let schema = try all.decode(Int.self, forKey: .init(stringValue: "schemaVersion")!)
        guard schema == 1 else { throw NutritionBarcodeInputError.invalidResponse }
        let barcode = try all.decode(String.self, forKey: .init(stringValue: "barcode")!)
        guard NutritionBarcodeNormalizer.normalize(barcode) == barcode else { throw NutritionBarcodeInputError.invalidResponse }
        let provenance = try all.decode(NutritionBarcodeProvenance.self, forKey: .init(stringValue: "provenance")!)
        switch state {
        case "not_found":
            try rejectUnknownBarcodeKeys(decoder, allowed: ["schemaVersion", "state", "barcode", "provenance"])
            self = .notFound(barcode: barcode, provenance: provenance)
        case "unavailable":
            try rejectUnknownBarcodeKeys(decoder, allowed: ["schemaVersion", "state", "barcode", "reason", "retryAfterSeconds", "provenance"])
            let reason = try all.decode(NutritionBarcodeReason.self, forKey: .init(stringValue: "reason")!)
            let retry = try all.decodeIfPresent(Int.self, forKey: .init(stringValue: "retryAfterSeconds")!)
            guard retry == nil || (0...3_600).contains(retry!) else { throw NutritionBarcodeInputError.invalidResponse }
            self = .unavailable(barcode: barcode, reason: reason, retryAfterSeconds: retry, provenance: provenance)
        case "found":
            try rejectUnknownBarcodeKeys(decoder, allowed: ["schemaVersion", "state", "barcode", "product", "nutritionState", "per100g", "perServing", "qualityFlags", "provenance"])
            let product = try all.decode(NutritionBarcodeProduct.self, forKey: .init(stringValue: "product")!)
            let nutritionState = try all.decode(NutritionBarcodeDataState.self, forKey: .init(stringValue: "nutritionState")!)
            let per100g = try all.decodeIfPresent(NutritionBarcodeMacros.self, forKey: .init(stringValue: "per100g")!)
            let perServing = try all.decodeIfPresent(NutritionBarcodeMacros.self, forKey: .init(stringValue: "perServing")!)
            let flags = try all.decodeIfPresent([NutritionBarcodeQualityFlag].self, forKey: .init(stringValue: "qualityFlags")!)
            self = .found(try NutritionBarcodeFound(barcode: barcode, product: product, nutritionState: nutritionState, per100g: per100g, perServing: perServing, qualityFlags: flags, provenance: provenance))
        default:
            throw NutritionBarcodeInputError.invalidResponse
        }
    }
}

// MARK: - Editable confirmation and explicit local persistence

public enum NutritionBarcodeBasis: String, Codable, Sendable { case per100g, perServing }

public struct NutritionBarcodeProposal: Codable, Equatable, Sendable {
    public let proposalID: String
    public let barcode: String
    public let product: NutritionBarcodeProduct
    public let nutritionState: NutritionBarcodeDataState
    public let per100g: NutritionBarcodeMacros?
    public let perServing: NutritionBarcodeMacros?
    public let qualityFlags: [NutritionBarcodeQualityFlag]?
    public let provenance: NutritionBarcodeProvenance

    public init(proposalID: String, lookup: NutritionBarcodeLookup) throws {
        guard Self.validID(proposalID) else { throw NutritionBarcodeInputError.invalidProposal }
        guard case .found(let value) = lookup else { throw NutritionBarcodeInputError.invalidProposal }
        self.proposalID = proposalID; self.barcode = value.barcode; self.product = value.product; self.nutritionState = value.nutritionState
        self.per100g = value.per100g; self.perServing = value.perServing; self.qualityFlags = value.qualityFlags; self.provenance = value.provenance
    }

    fileprivate static func validID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count) && bytes.first.map({ $0.isASCIIAlphaNumeric }) == true && bytes.dropFirst().allSatisfy({ $0.isASCIIAlphaNumeric || $0 == 45 || $0 == 95 })
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool { (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self) }
}

public struct NutritionBarcodeConfirmation: Codable, Equatable, Sendable {
    public let proposalID: String
    public let barcode: String
    public let basis: NutritionBarcodeBasis
    public let mealAt: String
    public let productName: String?
    public let grams: Double?
    public let kcal: Double?
    public let proteinGrams: Double?
    public let carbsGrams: Double?
    public let fatGrams: Double?
    public let confirmedAt: String

    public init(proposalID: String, barcode: String, basis: NutritionBarcodeBasis, mealAt: String,
                productName: String?, grams: Double?, kcal: Double?, proteinGrams: Double?, carbsGrams: Double?, fatGrams: Double?, confirmedAt: String) {
        self.proposalID = proposalID; self.barcode = barcode; self.basis = basis; self.mealAt = mealAt; self.productName = productName; self.grams = grams; self.kcal = kcal; self.proteinGrams = proteinGrams; self.carbsGrams = carbsGrams; self.fatGrams = fatGrams; self.confirmedAt = confirmedAt
    }
}

public struct NutritionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The editable proposal lineage is retained so a retry after a failed
    /// file write can replace the same logical meal instead of creating a
    /// second entry.  The meal timestamp remains part of the identity key so
    /// the same packaged food can be logged again later.
    public let proposalID: String
    public let barcode: String
    public let basis: NutritionBarcodeBasis
    public let productName: String?
    public let grams: Double?
    public let kcal: Double?
    public let proteinGrams: Double?
    public let carbsGrams: Double?
    public let fatGrams: Double?
    public let mealAt: String
    public let confirmedAt: String
    public let source: NutritionBarcodeProvenance

    private enum CodingKeys: String, CodingKey {
        case id, proposalID, barcode, basis, productName, grams, kcal,
             proteinGrams, carbsGrams, fatGrams, mealAt, confirmedAt, source
    }

    fileprivate init(id: UUID = UUID(), confirmation: NutritionBarcodeConfirmation, source: NutritionBarcodeProvenance) {
        self.id = id; self.proposalID = confirmation.proposalID; self.barcode = confirmation.barcode; self.basis = confirmation.basis; self.productName = confirmation.productName; self.grams = confirmation.grams; self.kcal = confirmation.kcal; self.proteinGrams = confirmation.proteinGrams; self.carbsGrams = confirmation.carbsGrams; self.fatGrams = confirmation.fatGrams; self.mealAt = confirmation.mealAt; self.confirmedAt = confirmation.confirmedAt; self.source = source
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownBarcodeKeys(decoder, allowed: [
            "id", "proposalID", "barcode", "basis", "productName", "grams", "kcal",
            "proteinGrams", "carbsGrams", "fatGrams", "mealAt", "confirmedAt", "source"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // Records written by the first barcode slice predate lineage. Keep
        // those records readable, but reject an explicit null rather than
        // treating malformed data as a legacy record.
        if container.contains(.proposalID) {
            guard try !container.decodeNil(forKey: .proposalID) else {
                throw DecodingError.valueNotFound(String.self, .init(codingPath: container.codingPath + [CodingKeys.proposalID], debugDescription: "Explicit null is not accepted"))
            }
            proposalID = try container.decode(String.self, forKey: .proposalID)
        } else {
            proposalID = "legacy-\(id.uuidString)"
        }
        barcode = try container.decode(String.self, forKey: .barcode)
        basis = try container.decode(NutritionBarcodeBasis.self, forKey: .basis)
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        grams = try container.decodeIfPresent(Double.self, forKey: .grams)
        kcal = try container.decodeIfPresent(Double.self, forKey: .kcal)
        proteinGrams = try container.decodeIfPresent(Double.self, forKey: .proteinGrams)
        carbsGrams = try container.decodeIfPresent(Double.self, forKey: .carbsGrams)
        fatGrams = try container.decodeIfPresent(Double.self, forKey: .fatGrams)
        mealAt = try container.decode(String.self, forKey: .mealAt)
        confirmedAt = try container.decode(String.self, forKey: .confirmedAt)
        source = try container.decode(NutritionBarcodeProvenance.self, forKey: .source)
    }

    public var mealDate: Date? { NutritionBarcodeISO8601.date(mealAt) }

    fileprivate var retryIdentity: String { "\(proposalID)|\(basis.rawValue)|\(mealAt)" }

    fileprivate func validateForPersistence() throws {
        guard NutritionBarcodeProposal.validID(proposalID),
              NutritionBarcodeNormalizer.normalize(barcode) == barcode,
              NutritionBarcodeISO8601.isValid(mealAt),
              NutritionBarcodeISO8601.isValid(confirmedAt),
              let mealDate = NutritionBarcodeISO8601.date(mealAt),
              let confirmedDate = NutritionBarcodeISO8601.date(confirmedAt),
              let fetchedDate = NutritionBarcodeISO8601.date(source.fetchedAt),
              confirmedDate >= fetchedDate,
              mealDate <= confirmedDate.addingTimeInterval(5),
              kcal != nil || proteinGrams != nil || carbsGrams != nil || fatGrams != nil else { throw NutritionBarcodeInputError.invalidProposal }
        if let productName, productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || productName.utf8.count > 240 { throw NutritionBarcodeInputError.invalidProposal }
        if let grams, !grams.isFinite || grams < 0 || grams > 5_000 { throw NutritionBarcodeInputError.invalidProposal }
        if let kcal, !kcal.isFinite || kcal < 0 || kcal > 5_000 { throw NutritionBarcodeInputError.invalidProposal }
        for value in [proteinGrams, carbsGrams, fatGrams] {
            if let value, !value.isFinite || value < 0 || value > 2_000 { throw NutritionBarcodeInputError.invalidProposal }
        }
    }
}

public enum NutritionBarcodeFlow {
    public static func confirm(_ confirmation: NutritionBarcodeConfirmation, for proposal: NutritionBarcodeProposal, now: Date = .now) throws -> NutritionRecord {
        guard confirmation.proposalID == proposal.proposalID,
              confirmation.barcode == proposal.barcode,
              NutritionBarcodeNormalizer.normalize(confirmation.barcode) == confirmation.barcode else { throw NutritionBarcodeInputError.invalidProposal }
        switch confirmation.basis {
        case .per100g:
            guard proposal.per100g != nil else { throw NutritionBarcodeInputError.invalidProposal }
        case .perServing:
            guard proposal.perServing != nil else { throw NutritionBarcodeInputError.invalidProposal }
        }
        guard let mealDate = NutritionBarcodeISO8601.date(confirmation.mealAt),
              let confirmedDate = NutritionBarcodeISO8601.date(confirmation.confirmedAt),
              let generatedDate = NutritionBarcodeISO8601.date(proposal.provenance.fetchedAt),
              mealDate <= now.addingTimeInterval(5), confirmedDate <= now.addingTimeInterval(5), confirmedDate >= generatedDate else { throw NutritionBarcodeInputError.invalidProposal }
        if let name = confirmation.productName, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 240 { throw NutritionBarcodeInputError.invalidProposal }
        if let grams = confirmation.grams, !grams.isFinite || grams < 0 || grams > 5_000 { throw NutritionBarcodeInputError.invalidProposal }
        if let kcal = confirmation.kcal, !kcal.isFinite || kcal < 0 || kcal > 5_000 { throw NutritionBarcodeInputError.invalidProposal }
        for value in [confirmation.proteinGrams, confirmation.carbsGrams, confirmation.fatGrams] {
            if let value, !value.isFinite || value < 0 || value > 2_000 { throw NutritionBarcodeInputError.invalidProposal }
        }
        let record = NutritionRecord(confirmation: confirmation, source: proposal.provenance)
        try record.validateForPersistence()
        return record
    }
}

public actor NutritionRecordStore {
    public let url: URL
    private let fileManager: FileManager

    public static var defaultPersistenceURL: URL {
        // Both branches remain inside a stable Application Support location.
        // Never silently downgrade sensitive food records to a temporary
        // directory whose lifecycle and protection semantics are unclear.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("nutrition-barcode-records.json", isDirectory: false)
    }

    public init(url: URL, fileManager: FileManager = .default) { self.url = url; self.fileManager = fileManager }

    public func load() throws -> [NutritionRecord] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let records = try JSONDecoder().decode([NutritionRecord].self, from: Data(contentsOf: url))
        guard Set(records.map(\.id)).count == records.count else { throw NutritionBarcodeInputError.invalidResponse }
        guard Set(records.map(\.retryIdentity)).count == records.count else { throw NutritionBarcodeInputError.invalidResponse }
        for record in records { try record.validateForPersistence() }
        return records
    }

    /// Persistence is intentionally a separate call after the editable
    /// confirmation has been validated. Lookup/proposal construction never
    /// writes a record.
    public func save(_ record: NutritionRecord) throws {
        try record.validateForPersistence()
        var records = try load()
        if let index = records.firstIndex(where: { $0.id == record.id || $0.retryIdentity == record.retryIdentity }) {
            records[index] = record
        } else {
            records.append(record)
        }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
#if os(iOS)
            try JSONEncoder().encode(records).write(to: temporary, options: [.atomic, .completeFileProtection])
#else
            try JSONEncoder().encode(records).write(to: temporary, options: [.atomic])
#endif
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            // The original file is never touched until the final replace/move
            // succeeds. Remove a failed temporary write, but preserve the
            // previous record set and surface the error to the caller.
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
