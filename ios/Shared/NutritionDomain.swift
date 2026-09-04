import Foundation

// MARK: - Native nutrition/photo contract

/// Errors raised when a nutrition photo, estimate, or confirmation crosses the
/// native contract boundary.  This file is deliberately a Foundation-only
/// model/validator layer: it does not persist, upload, infer, or write to
/// HealthKit.
public enum NutritionValidationError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupportedSchemaVersion(Int)
    case unsafeIdentifier(String)
    case duplicateIdentifier(String)
    case invalidTimestamp(String)
    case invalidBounds(String)
    case invalidText(String)
    case invalidBase64(String)
    case contradictoryState(String)
    case invalidLineage(String)
}

private struct NutritionAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownNutritionKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: NutritionAnyCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath,
                  debugDescription: "Unknown nutrition field")
        )
    }
}

private func decodeNutritionOptional<T: Decodable, Key: CodingKey>(
    _ type: T.Type,
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>
) throws -> T? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw DecodingError.valueNotFound(
            type,
            .init(codingPath: container.codingPath + [key],
                  debugDescription: "Explicit null is not accepted")
        )
    }
    return try container.decode(type, forKey: key)
}

private extension CodingUserInfoKey {
    static var nutritionNow: CodingUserInfoKey {
        CodingUserInfoKey(rawValue: "com.hermes.lifeos.nutrition.now")!
    }
}

private enum NutritionValidation {
    static let schemaVersion = 1
    static let maximumClockSkew: TimeInterval = 5
    static let maximumPhotoBytes = 20 * 1_024 * 1_024
    static let maximumPhotoCount = 3
    static let maximumImageDimension = 12_000
    static let maximumImagePixels = 40_000_000
    static let maximumItems = 40
    static let maximumText = 1_000
    static let maximumAmount = 1_000_000.0
    static let maximumQuantity = 100_000.0
    static let maximumUncertaintyNotes = 8
    static let rangeTolerance = 0.05

    static let timestampPattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$"#,
        options: []
    )

    static func now(from decoder: Decoder) -> Date {
        decoder.userInfo[.nutritionNow] as? Date ?? .now
    }

    static func validateSchema(_ value: Int) throws {
        guard value == schemaVersion else {
            throw NutritionValidationError.unsupportedSchemaVersion(value)
        }
    }

    static func validateID(_ value: String, field: String = "id") throws {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count),
              let first = bytes.first,
              isASCIIAlphaNumeric(first),
              bytes.dropFirst().allSatisfy({ isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 95 }) else {
            throw NutritionValidationError.unsafeIdentifier(field)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    static func validateText(_ value: String, maximum: Int, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= maximum else {
            throw NutritionValidationError.invalidText(field)
        }
    }

    static func validateSecretFreeText(_ value: String, maximum: Int, field: String) throws {
        try validateText(value, maximum: maximum, field: field)
        guard !containsSecretLike(value) else {
            throw NutritionValidationError.invalidText(field)
        }
    }

    static func validateFoodText(_ value: String, maximum: Int, field: String) throws {
        try validateSecretFreeText(value, maximum: maximum, field: field)
        guard !containsProhibitedAdvice(value) else {
            throw NutritionValidationError.invalidText(field)
        }
    }

    private static func containsSecretLike(_ value: String) -> Bool {
        value.range(
            of: #"(?i)(?:api[_ -]?key|access[_ -]?token|auth(?:orization)?|bearer|client[_ -]?secret|password|private[_ -]?key|refresh[_ -]?token|secret|token\s*[:=]|sk-[A-Za-z0-9]|AIza[A-Za-z0-9_-]{20,})"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsProhibitedAdvice(_ value: String) -> Bool {
        value.range(
            of: #"(?i)\b(?:diagnos(?:is|e|tic)|allerg(?:y|ic|ies)|medical|medication|prescri(?:be|ption)|supplement(?:s)?|disease|treatment)\b"#,
            options: .regularExpression
        ) != nil
    }

    static func parseTimestamp(_ raw: String, field: String = "timestamp") throws -> Date {
        guard raw.utf16.count <= 40,
              timestampPattern.firstMatch(
                in: raw,
                options: [],
                range: NSRange(location: 0, length: raw.utf16.count)
              ) != nil else {
            throw NutritionValidationError.invalidTimestamp(field)
        }

        let body: String
        let zone: String
        if raw.hasSuffix("Z") {
            body = String(raw.dropLast())
            zone = "Z"
        } else if raw.count >= 6 && raw[raw.index(raw.endIndex, offsetBy: -3)] == ":" {
            body = String(raw.dropLast(6))
            zone = String(raw.suffix(6))
        } else {
            body = String(raw.dropLast(5))
            let rawZone = String(raw.suffix(5))
            zone = String(rawZone.prefix(3)) + ":" + rawZone.suffix(2)
        }
        let time = body.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false).last!
        let normalizedBody = time.utf8.count == 5 ? body + ":00" : body
        let normalized = normalizedBody + zone

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: normalized) ?? standard.date(from: normalized),
              date.timeIntervalSinceReferenceDate.isFinite else {
            throw NutritionValidationError.invalidTimestamp(field)
        }
        return date
    }

    static func validateObserved(_ value: String, field: String, now: Date) throws -> Date {
        let date = try parseTimestamp(value, field: field)
        guard now.timeIntervalSinceReferenceDate.isFinite,
              date <= now.addingTimeInterval(maximumClockSkew) else {
            throw NutritionValidationError.invalidTimestamp(field)
        }
        return date
    }

    static func validateAmount(_ value: Double, field: String, positive: Bool = false) throws {
        let validSign = positive ? value > 0 : value >= 0
        guard value.isFinite, validSign, value <= maximumAmount,
              abs(value * 100 - (value * 100).rounded()) < 1e-8 else {
            throw NutritionValidationError.invalidBounds(field)
        }
    }

    static func validateQuantity(_ value: Double, field: String) throws {
        guard value.isFinite, value > 0, value <= maximumQuantity,
              abs(value * 100 - (value * 100).rounded()) < 1e-8 else {
            throw NutritionValidationError.invalidBounds(field)
        }
    }

    static func validateDecimalAtMostTwoPlaces(_ value: Double, field: String) throws {
        guard value.isFinite, abs(value * 100 - (value * 100).rounded()) < 1e-8 else {
            throw NutritionValidationError.invalidBounds(field)
        }
    }

    static func validateUniqueIDs(_ values: [String], maximum: Int, field: String) throws {
        guard values.count <= maximum else {
            throw NutritionValidationError.invalidBounds(field)
        }
        var seen = Set<String>()
        for value in values {
            try validateID(value, field: field)
            guard seen.insert(value).inserted else {
                throw NutritionValidationError.duplicateIdentifier(value)
            }
        }
    }

    static func validateSHA256(_ value: String, field: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.count == 64,
              bytes.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else {
            throw NutritionValidationError.invalidBounds(field)
        }
    }

    static func isCanonicalBase64(_ value: String) -> Bool {
        guard value.count >= 4, value.count % 4 == 0 else { return false }
        let firstPadding = value.firstIndex(of: "=")
        let contentEnd = firstPadding.map { value.distance(from: value.startIndex, to: $0) } ?? value.count
        if firstPadding != nil, contentEnd < value.count - 2 { return false }
        for character in value.prefix(contentEnd) {
            let code = character.asciiValue ?? 0
            let isUpper = (65...90).contains(code)
            let isLower = (97...122).contains(code)
            let isDigit = (48...57).contains(code)
            if !isUpper && !isLower && !isDigit && character != "+" && character != "/" {
                return false
            }
        }
        guard let firstPadding else { return true }
        let paddingCount = value.distance(from: firstPadding, to: value.endIndex)
        guard paddingCount == 1 || paddingCount == 2 else { return false }
        return value.suffix(paddingCount) == String(repeating: "=", count: paddingCount)
    }

    static func decodedBase64ByteLength(_ value: String) -> Int {
        let padding = value.hasSuffix("==") ? 2 : value.hasSuffix("=") ? 1 : 0
        return (value.count / 4) * 3 - padding
    }

    static func validateBase64(_ value: String, byteLength: Int) throws {
        guard value.count <= Int(ceil(Double(maximumPhotoBytes) / 3.0)) * 4,
              isCanonicalBase64(value),
              decodedBase64ByteLength(value) == byteLength else {
            throw NutritionValidationError.invalidBase64("inlineDataBase64")
        }
    }

    static func validateRange(_ value: FoodEstimateRange) throws {
        try validateAmount(value.estimate, field: "estimate")
        try validateAmount(value.min, field: "min")
        try validateAmount(value.max, field: "max")
        guard value.min <= value.max else { throw NutritionValidationError.invalidBounds("range") }
        guard value.estimate >= value.min && value.estimate <= value.max else {
            throw NutritionValidationError.invalidBounds("range.estimate")
        }
    }

    static func sumTolerance(_ sum: Double) -> Double {
        max(rangeTolerance, abs(sum) * 0.005)
    }

    static func macroEnergyIsPlausible(calories: Double, protein: Double, carbs: Double, fat: Double) -> Bool {
        let macroEnergy = protein * 4 + carbs * 4 + fat * 9
        return calories >= max(0, macroEnergy * 0.25 - 100)
            && calories <= macroEnergy * 2.5 + 100
    }

    static func validateNutrientSemantics(
        grams: FoodEstimateRange,
        calories: FoodEstimateRange,
        protein: FoodEstimateRange,
        carbs: FoodEstimateRange,
        fat: FoodEstimateRange,
        fiber: FoodEstimateRange?,
        path: String
    ) throws {
        _ = fiber // Fiber is bounded independently; it is not part of the macro-energy rule.
        let macroMass = protein.max + carbs.max + fat.max
        guard macroMass <= grams.max + 5 else {
            throw NutritionValidationError.invalidBounds("\(path).grams")
        }
        guard calories.max <= grams.max * 9 + 100 else {
            throw NutritionValidationError.invalidBounds("\(path).calories")
        }
        guard macroEnergyIsPlausible(
            calories: calories.estimate,
            protein: protein.estimate,
            carbs: carbs.estimate,
            fat: fat.estimate
        ) else {
            throw NutritionValidationError.invalidBounds("\(path).calories")
        }
    }
}

public enum FoodImageMimeType: String, Codable, CaseIterable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case heic = "image/heic"
    case webp = "image/webp"
}

public typealias FoodRequestID = String
public typealias FoodMealID = String
public typealias FoodClientTimeZone = String
public typealias FoodEstimateAlternative = String

public struct FoodPhotoImageDescriptor: Codable, Equatable, Sendable {
    public let imageID: String
    public let mimeType: FoodImageMimeType
    public let byteLength: Int
    public let width: Int
    public let height: Int
    public let sanitized: Bool
    public let inlineDataBase64: String
    public let sha256: String

    private enum CodingKeys: String, CodingKey {
        case imageID, mimeType, byteLength, width, height, sanitized, inlineDataBase64, sha256
    }

    public init(imageID: String, mimeType: FoodImageMimeType, byteLength: Int,
                width: Int, height: Int, sanitized: Bool,
                inlineDataBase64: String, sha256: String) throws {
        self.imageID = imageID
        self.mimeType = mimeType
        self.byteLength = byteLength
        self.width = width
        self.height = height
        self.sanitized = sanitized
        self.inlineDataBase64 = inlineDataBase64
        self.sha256 = sha256
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "imageID", "mimeType", "byteLength", "width", "height", "sanitized",
            "inlineDataBase64", "sha256"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageID = try c.decode(String.self, forKey: .imageID)
        mimeType = try c.decode(FoodImageMimeType.self, forKey: .mimeType)
        byteLength = try c.decode(Int.self, forKey: .byteLength)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        sanitized = try c.decode(Bool.self, forKey: .sanitized)
        inlineDataBase64 = try c.decode(String.self, forKey: .inlineDataBase64)
        sha256 = try c.decode(String.self, forKey: .sha256)
        try validate(now: NutritionValidation.now(from: decoder))
    }

    public func validate(now: Date = .now) throws {
        try NutritionValidation.validateID(imageID, field: "imageID")
        guard (1...NutritionValidation.maximumPhotoBytes).contains(byteLength) else {
            throw NutritionValidationError.invalidBounds("byteLength")
        }
        guard (1...NutritionValidation.maximumImageDimension).contains(width),
              (1...NutritionValidation.maximumImageDimension).contains(height) else {
            throw NutritionValidationError.invalidBounds("image dimensions")
        }
        guard width * height <= NutritionValidation.maximumImagePixels else {
            throw NutritionValidationError.invalidBounds("image pixels")
        }
        guard sanitized else { throw NutritionValidationError.contradictoryState("image is not sanitized") }
        try NutritionValidation.validateBase64(inlineDataBase64, byteLength: byteLength)
        try NutritionValidation.validateSHA256(sha256, field: "sha256")
        _ = now // Descriptor has no timestamp; retain a uniform validation API.
    }
}

public struct FoodPhotoUserContext: Codable, Equatable, Sendable {
    public let plateDiameterMm: Double?
    public let knownReference: String?
    public let portionWeightGrams: Double?
    public let packageLabelContext: String?
    public let note: String?

    private enum CodingKeys: String, CodingKey {
        case plateDiameterMm, knownReference, portionWeightGrams, packageLabelContext, note
    }

    public init(plateDiameterMm: Double? = nil, knownReference: String? = nil,
                portionWeightGrams: Double? = nil, packageLabelContext: String? = nil,
                note: String? = nil) throws {
        self.plateDiameterMm = plateDiameterMm
        self.knownReference = knownReference
        self.portionWeightGrams = portionWeightGrams
        self.packageLabelContext = packageLabelContext
        self.note = note
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "plateDiameterMm", "knownReference", "portionWeightGrams", "packageLabelContext", "note"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plateDiameterMm = try decodeNutritionOptional(Double.self, forKey: .plateDiameterMm, from: c)
        knownReference = try decodeNutritionOptional(String.self, forKey: .knownReference, from: c)
        portionWeightGrams = try decodeNutritionOptional(Double.self, forKey: .portionWeightGrams, from: c)
        packageLabelContext = try decodeNutritionOptional(String.self, forKey: .packageLabelContext, from: c)
        note = try decodeNutritionOptional(String.self, forKey: .note, from: c)
        try validate()
    }

    public func validate() throws {
        if let plateDiameterMm {
            guard plateDiameterMm.isFinite, (50...1_000).contains(plateDiameterMm) else {
                throw NutritionValidationError.invalidBounds("plateDiameterMm")
            }
            try NutritionValidation.validateDecimalAtMostTwoPlaces(plateDiameterMm, field: "plateDiameterMm")
        }
        if let portionWeightGrams {
            try NutritionValidation.validateAmount(portionWeightGrams, field: "portionWeightGrams")
        }
        if let knownReference { try NutritionValidation.validateSecretFreeText(knownReference, maximum: 200, field: "knownReference") }
        if let packageLabelContext { try NutritionValidation.validateSecretFreeText(packageLabelContext, maximum: 1_000, field: "packageLabelContext") }
        if let note { try NutritionValidation.validateSecretFreeText(note, maximum: 500, field: "note") }
    }
}

public struct FoodPhotoManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let mealID: String
    public let requestID: String
    public let capturedAt: String
    public let clientTimeZone: String
    public let inferenceConsent: Bool
    public let images: [FoodPhotoImageDescriptor]
    public let userContext: FoodPhotoUserContext?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mealID, requestID, capturedAt, clientTimeZone, inferenceConsent, images, userContext
    }

    public init(schemaVersion: Int = 1, mealID: String, requestID: String, capturedAt: String,
                clientTimeZone: String, inferenceConsent: Bool,
                images: [FoodPhotoImageDescriptor], userContext: FoodPhotoUserContext? = nil) throws {
        self.schemaVersion = schemaVersion
        self.mealID = mealID
        self.requestID = requestID
        self.capturedAt = capturedAt
        self.clientTimeZone = clientTimeZone
        self.inferenceConsent = inferenceConsent
        self.images = images
        self.userContext = userContext
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "schemaVersion", "mealID", "requestID", "capturedAt", "clientTimeZone",
            "inferenceConsent", "images", "userContext"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        mealID = try c.decode(String.self, forKey: .mealID)
        requestID = try c.decode(String.self, forKey: .requestID)
        capturedAt = try c.decode(String.self, forKey: .capturedAt)
        clientTimeZone = try c.decode(String.self, forKey: .clientTimeZone)
        inferenceConsent = try c.decode(Bool.self, forKey: .inferenceConsent)
        images = try c.decode([FoodPhotoImageDescriptor].self, forKey: .images)
        userContext = try decodeNutritionOptional(FoodPhotoUserContext.self, forKey: .userContext, from: c)
        try validate(now: NutritionValidation.now(from: decoder))
    }

    public func validate(now: Date = .now) throws {
        try NutritionValidation.validateSchema(schemaVersion)
        try NutritionValidation.validateID(mealID, field: "mealID")
        try NutritionValidation.validateID(requestID, field: "requestID")
        _ = try NutritionValidation.validateObserved(capturedAt, field: "capturedAt", now: now)
        try validateTimeZone(clientTimeZone)
        guard inferenceConsent else {
            throw NutritionValidationError.contradictoryState("photo inference requires explicit consent")
        }
        guard (1...NutritionValidation.maximumPhotoCount).contains(images.count) else {
            throw NutritionValidationError.invalidBounds("images")
        }
        var ids = Set<String>()
        var totalBytes = 0
        for image in images {
            try image.validate(now: now)
            guard ids.insert(image.imageID).inserted else {
                throw NutritionValidationError.duplicateIdentifier(image.imageID)
            }
            let (nextTotalBytes, overflow) = totalBytes.addingReportingOverflow(image.byteLength)
            guard !overflow else {
                throw NutritionValidationError.invalidBounds("combined photo payload")
            }
            totalBytes = nextTotalBytes
        }
        guard totalBytes <= NutritionValidation.maximumPhotoBytes else {
            throw NutritionValidationError.invalidBounds("combined photo payload")
        }
        try NutritionPhotoRetentionPolicy.validateAsset(
            kind: .original,
            byteCount: totalBytes,
            imageCount: images.count
        )
        try userContext?.validate()
    }

    private func validateTimeZone(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        func isLetter(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte)
        }
        func isSafeSegment(_ segment: String, firstMustBeLetter: Bool) -> Bool {
            let bytes = Array(segment.utf8)
            guard (1...32).contains(bytes.count) else { return false }
            if firstMustBeLetter, let first = bytes.first, !isLetter(first) { return false }
            return bytes.dropFirst().allSatisfy {
                isLetter($0) || (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 95
            }
        }
        let valid = value == "UTC" || (parts.count >= 2
            && isSafeSegment(parts[0], firstMustBeLetter: true)
            && parts.dropFirst().allSatisfy { isSafeSegment($0, firstMustBeLetter: false) })
        guard
            valid,
            !parts.contains("."),
            value.utf16.count <= 64,
            TimeZone(identifier: value) != nil
        else {
            throw NutritionValidationError.invalidBounds("clientTimeZone")
        }
    }
}

public enum FoodEstimateConfidence: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

public enum FoodEstimateFlag: String, Codable, CaseIterable, Sendable {
    case needsConfirmation = "needs_confirmation"
    case mixedDish = "mixed_dish"
    case unknownPortion = "unknown_portion"
    case hiddenOil = "hidden_oil"
    case lowConfidence = "low_confidence"
    case wideInterval = "wide_interval"
}

public enum FoodEstimateProposalState: String, Codable, Sendable {
    case needsConfirmation = "needs_confirmation"
}

public struct FoodEstimateRange: Codable, Equatable, Sendable {
    public let estimate: Double
    public let min: Double
    public let max: Double

    private enum CodingKeys: String, CodingKey { case estimate, min, max }

    public init(estimate: Double, min: Double, max: Double) throws {
        self.estimate = estimate
        self.min = min
        self.max = max
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: ["estimate", "min", "max"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        estimate = try c.decode(Double.self, forKey: .estimate)
        min = try c.decode(Double.self, forKey: .min)
        max = try c.decode(Double.self, forKey: .max)
        try validate()
    }

    public func validate() throws { try NutritionValidation.validateRange(self) }
}

public struct FoodEstimateItem: Codable, Equatable, Sendable {
    public let itemID: String
    public let enteredLabel: String?
    public let estimatedLabel: String
    public let labelSource: FoodEstimateLabelSource
    public let quantity: Double
    public let unit: FoodUnit
    public let grams: FoodEstimateRange
    public let calories: FoodEstimateRange
    public let protein: FoodEstimateRange
    public let carbs: FoodEstimateRange
    public let fat: FoodEstimateRange
    public let fiber: FoodEstimateRange?
    public let confidence: FoodEstimateConfidence
    public let uncertaintyNotes: [String]?
    public let alternatives: [String]?
    public let flags: [FoodEstimateFlag]?

    private enum CodingKeys: String, CodingKey {
        case itemID, enteredLabel, estimatedLabel, labelSource, quantity, unit, grams,
             calories, protein, carbs, fat, fiber, confidence, uncertaintyNotes, alternatives, flags
    }

    public init(itemID: String, enteredLabel: String? = nil, estimatedLabel: String,
                labelSource: FoodEstimateLabelSource, quantity: Double, unit: FoodUnit,
                grams: FoodEstimateRange, calories: FoodEstimateRange,
                protein: FoodEstimateRange, carbs: FoodEstimateRange,
                fat: FoodEstimateRange, fiber: FoodEstimateRange? = nil,
                confidence: FoodEstimateConfidence, uncertaintyNotes: [String]? = nil,
                alternatives: [String]? = nil, flags: [FoodEstimateFlag]? = nil) throws {
        self.itemID = itemID
        self.enteredLabel = enteredLabel
        self.estimatedLabel = estimatedLabel
        self.labelSource = labelSource
        self.quantity = quantity
        self.unit = unit
        self.grams = grams
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.confidence = confidence
        self.uncertaintyNotes = uncertaintyNotes
        self.alternatives = alternatives
        self.flags = flags
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "itemID", "enteredLabel", "estimatedLabel", "labelSource", "quantity", "unit",
            "grams", "calories", "protein", "carbs", "fat", "fiber", "confidence",
            "uncertaintyNotes", "alternatives", "flags"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(String.self, forKey: .itemID)
        enteredLabel = try decodeNutritionOptional(String.self, forKey: .enteredLabel, from: c)
        estimatedLabel = try c.decode(String.self, forKey: .estimatedLabel)
        labelSource = try c.decode(FoodEstimateLabelSource.self, forKey: .labelSource)
        quantity = try c.decode(Double.self, forKey: .quantity)
        unit = try c.decode(FoodUnit.self, forKey: .unit)
        grams = try c.decode(FoodEstimateRange.self, forKey: .grams)
        calories = try c.decode(FoodEstimateRange.self, forKey: .calories)
        protein = try c.decode(FoodEstimateRange.self, forKey: .protein)
        carbs = try c.decode(FoodEstimateRange.self, forKey: .carbs)
        fat = try c.decode(FoodEstimateRange.self, forKey: .fat)
        fiber = try decodeNutritionOptional(FoodEstimateRange.self, forKey: .fiber, from: c)
        confidence = try c.decode(FoodEstimateConfidence.self, forKey: .confidence)
        uncertaintyNotes = try decodeNutritionOptional([String].self, forKey: .uncertaintyNotes, from: c)
        alternatives = try decodeNutritionOptional([String].self, forKey: .alternatives, from: c)
        flags = try decodeNutritionOptional([FoodEstimateFlag].self, forKey: .flags, from: c)
        try validate()
    }

    public func validate() throws {
        try NutritionValidation.validateID(itemID, field: "itemID")
        if let enteredLabel { try NutritionValidation.validateFoodText(enteredLabel, maximum: 160, field: "enteredLabel") }
        try NutritionValidation.validateFoodText(estimatedLabel, maximum: 160, field: "estimatedLabel")
        try NutritionValidation.validateQuantity(quantity, field: "quantity")
        try grams.validate(); try calories.validate(); try protein.validate(); try carbs.validate(); try fat.validate()
        try fiber?.validate()
        guard grams.estimate > 0, grams.max > 0 else {
            throw NutritionValidationError.invalidBounds("grams")
        }
        if let uncertaintyNotes {
            guard uncertaintyNotes.count <= NutritionValidation.maximumUncertaintyNotes else {
                throw NutritionValidationError.invalidBounds("uncertaintyNotes")
            }
            for note in uncertaintyNotes { try NutritionValidation.validateFoodText(note, maximum: 240, field: "uncertaintyNotes") }
        }
        if let alternatives {
            guard alternatives.count <= 5 else { throw NutritionValidationError.invalidBounds("alternatives") }
            var seen = Set<String>()
            for alternative in alternatives {
                try NutritionValidation.validateFoodText(alternative, maximum: 160, field: "alternatives")
                guard seen.insert(alternative).inserted else { throw NutritionValidationError.duplicateIdentifier(alternative) }
            }
        }
        if let flags {
            guard flags.count <= FoodEstimateFlag.allCases.count else { throw NutritionValidationError.invalidBounds("flags") }
            guard Set(flags).count == flags.count else { throw NutritionValidationError.invalidBounds("duplicate flags") }
        }
        try NutritionValidation.validateNutrientSemantics(
            grams: grams, calories: calories, protein: protein, carbs: carbs, fat: fat,
            fiber: fiber, path: "item"
        )
    }
}

public enum FoodEstimateLabelSource: String, Codable, Sendable {
    case recognized, assumed
}

public enum FoodUnit: String, Codable, CaseIterable, Sendable {
    case g, kg, ml, l, oz, lb, serving, portion, piece, slice, cup, tbsp, tsp
}

public struct FoodEstimateTotals: Codable, Equatable, Sendable {
    public let grams: FoodEstimateRange
    public let calories: FoodEstimateRange
    public let protein: FoodEstimateRange
    public let carbs: FoodEstimateRange
    public let fat: FoodEstimateRange
    public let fiber: FoodEstimateRange?

    private enum CodingKeys: String, CodingKey { case grams, calories, protein, carbs, fat, fiber }

    public init(grams: FoodEstimateRange, calories: FoodEstimateRange,
                protein: FoodEstimateRange, carbs: FoodEstimateRange,
                fat: FoodEstimateRange, fiber: FoodEstimateRange? = nil) throws {
        self.grams = grams; self.calories = calories; self.protein = protein
        self.carbs = carbs; self.fat = fat; self.fiber = fiber
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: ["grams", "calories", "protein", "carbs", "fat", "fiber"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grams = try c.decode(FoodEstimateRange.self, forKey: .grams)
        calories = try c.decode(FoodEstimateRange.self, forKey: .calories)
        protein = try c.decode(FoodEstimateRange.self, forKey: .protein)
        carbs = try c.decode(FoodEstimateRange.self, forKey: .carbs)
        fat = try c.decode(FoodEstimateRange.self, forKey: .fat)
        fiber = try decodeNutritionOptional(FoodEstimateRange.self, forKey: .fiber, from: c)
        try validate()
    }

    public func validate() throws {
        try grams.validate(); try calories.validate(); try protein.validate(); try carbs.validate(); try fat.validate()
        try fiber?.validate()
    }
}

public struct FoodEstimateImageHashReference: Codable, Equatable, Sendable {
    public let imageID: String
    public let sha256: String

    private enum CodingKeys: String, CodingKey { case imageID, sha256 }

    public init(imageID: String, sha256: String) throws {
        self.imageID = imageID; self.sha256 = sha256
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: ["imageID", "sha256"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageID = try c.decode(String.self, forKey: .imageID)
        sha256 = try c.decode(String.self, forKey: .sha256)
        try validate()
    }

    public func validate() throws {
        try NutritionValidation.validateID(imageID, field: "imageID")
        try NutritionValidation.validateSHA256(sha256, field: "sha256")
    }
}

/// The minimum proposal provenance that survives when a reviewed photo
/// estimate becomes a durable meal.  The photo bytes are deliberately not
/// part of this value: `FoodPhotoPreparationCoordinator` owns only sanitized
/// descriptors, and the review flow clears them after the request finishes.
/// Keeping the request/proposal/provider/hash lineage here means a later
/// correction can still explain what was confirmed without retaining the
/// user's image.
public struct NutritionMealPhotoLineage: Codable, Equatable, Sendable {
    public let proposalID: String
    public let requestID: String
    public let requestTimestamp: String
    public let generatedAt: String
    public let provider: String
    public let modelIdentifier: String
    public let modelVersion: String
    public let policyVersion: String
    public let sanitizedImageHashes: [FoodEstimateImageHashReference]

    private enum CodingKeys: String, CodingKey {
        case proposalID, requestID, requestTimestamp, generatedAt, provider, modelIdentifier,
             modelVersion, policyVersion, sanitizedImageHashes
    }

    public init(proposal: FoodEstimateProposal) throws {
        self.proposalID = proposal.proposalID
        self.requestID = proposal.requestID
        self.requestTimestamp = proposal.provenance.requestTimestamp
        self.generatedAt = proposal.generatedAt
        self.provider = proposal.provenance.provider
        self.modelIdentifier = proposal.provenance.modelIdentifier
        self.modelVersion = proposal.provenance.modelVersion
        self.policyVersion = proposal.provenance.policyVersion
        self.sanitizedImageHashes = proposal.provenance.sanitizedImageHashes
        try validate()
    }

    public init(
        proposalID: String,
        requestID: String,
        requestTimestamp: String,
        generatedAt: String,
        provider: String,
        modelIdentifier: String,
        modelVersion: String,
        policyVersion: String,
        sanitizedImageHashes: [FoodEstimateImageHashReference]
    ) throws {
        self.proposalID = proposalID
        self.requestID = requestID
        self.requestTimestamp = requestTimestamp
        self.generatedAt = generatedAt
        self.provider = provider
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.policyVersion = policyVersion
        self.sanitizedImageHashes = sanitizedImageHashes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "proposalID", "requestID", "requestTimestamp", "generatedAt", "provider", "modelIdentifier",
            "modelVersion", "policyVersion", "sanitizedImageHashes"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proposalID = try c.decode(String.self, forKey: .proposalID)
        requestID = try c.decode(String.self, forKey: .requestID)
        requestTimestamp = try c.decode(String.self, forKey: .requestTimestamp)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        provider = try c.decode(String.self, forKey: .provider)
        modelIdentifier = try c.decode(String.self, forKey: .modelIdentifier)
        modelVersion = try c.decode(String.self, forKey: .modelVersion)
        policyVersion = try c.decode(String.self, forKey: .policyVersion)
        sanitizedImageHashes = try c.decode([FoodEstimateImageHashReference].self, forKey: .sanitizedImageHashes)
        try validate(now: NutritionValidation.now(from: decoder))
    }

    public func validate(now: Date = .now) throws {
        try NutritionValidation.validateID(proposalID, field: "photoLineage.proposalID")
        try NutritionValidation.validateID(requestID, field: "photoLineage.requestID")
        let generated = try NutritionValidation.validateObserved(
            generatedAt,
            field: "photoLineage.generatedAt",
            now: now
        )
        let request = try NutritionValidation.validateObserved(
            requestTimestamp,
            field: "photoLineage.requestTimestamp",
            now: now
        )
        guard generated >= request else {
            throw NutritionValidationError.invalidLineage("photo lineage generation predates inference request")
        }
        try NutritionValidation.validateSecretFreeText(provider, maximum: 120, field: "photoLineage.provider")
        try NutritionValidation.validateSecretFreeText(modelIdentifier, maximum: 160, field: "photoLineage.modelIdentifier")
        try NutritionValidation.validateSecretFreeText(modelVersion, maximum: 80, field: "photoLineage.modelVersion")
        try NutritionValidation.validateSecretFreeText(policyVersion, maximum: 80, field: "photoLineage.policyVersion")
        guard (1...NutritionValidation.maximumPhotoCount).contains(sanitizedImageHashes.count) else {
            throw NutritionValidationError.invalidBounds("photoLineage.sanitizedImageHashes")
        }
        var seen = Set<String>()
        for hash in sanitizedImageHashes {
            try hash.validate()
            guard seen.insert(hash.imageID).inserted else {
                throw NutritionValidationError.duplicateIdentifier(hash.imageID)
            }
        }
    }

}

public struct FoodEstimateProvenance: Codable, Equatable, Sendable {
    public let provider: String
    public let modelIdentifier: String
    public let modelVersion: String
    public let policyVersion: String
    public let requestTimestamp: String
    public let sanitizedImageHashes: [FoodEstimateImageHashReference]

    private enum CodingKeys: String, CodingKey {
        case provider, modelIdentifier, modelVersion, policyVersion, requestTimestamp, sanitizedImageHashes
    }

    public init(provider: String, modelIdentifier: String, modelVersion: String,
                policyVersion: String, requestTimestamp: String,
                sanitizedImageHashes: [FoodEstimateImageHashReference]) throws {
        self.provider = provider; self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion; self.policyVersion = policyVersion
        self.requestTimestamp = requestTimestamp; self.sanitizedImageHashes = sanitizedImageHashes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "provider", "modelIdentifier", "modelVersion", "policyVersion", "requestTimestamp", "sanitizedImageHashes"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        modelIdentifier = try c.decode(String.self, forKey: .modelIdentifier)
        modelVersion = try c.decode(String.self, forKey: .modelVersion)
        policyVersion = try c.decode(String.self, forKey: .policyVersion)
        requestTimestamp = try c.decode(String.self, forKey: .requestTimestamp)
        sanitizedImageHashes = try c.decode([FoodEstimateImageHashReference].self, forKey: .sanitizedImageHashes)
        try validate(now: NutritionValidation.now(from: decoder))
    }

    public func validate(now: Date = .now) throws {
        try NutritionValidation.validateSecretFreeText(provider, maximum: 120, field: "provider")
        try NutritionValidation.validateSecretFreeText(modelIdentifier, maximum: 160, field: "modelIdentifier")
        try NutritionValidation.validateSecretFreeText(modelVersion, maximum: 80, field: "modelVersion")
        try NutritionValidation.validateSecretFreeText(policyVersion, maximum: 80, field: "policyVersion")
        _ = try NutritionValidation.validateObserved(requestTimestamp, field: "requestTimestamp", now: now)
        guard (1...NutritionValidation.maximumPhotoCount).contains(sanitizedImageHashes.count) else {
            throw NutritionValidationError.invalidBounds("sanitizedImageHashes")
        }
        var ids = Set<String>()
        for hash in sanitizedImageHashes {
            try hash.validate()
            guard ids.insert(hash.imageID).inserted else {
                throw NutritionValidationError.duplicateIdentifier(hash.imageID)
            }
        }
    }
}

public struct FoodEstimateProposal: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let mealID: String
    public let proposalID: String
    public let requestID: String
    public let state: FoodEstimateProposalState
    public let generatedAt: String
    public let provenance: FoodEstimateProvenance
    public let items: [FoodEstimateItem]
    public let totals: FoodEstimateTotals
    public let flags: [FoodEstimateFlag]
    public let uncertaintyNotes: [String]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mealID, proposalID, requestID, state, generatedAt, provenance,
             items, totals, flags, uncertaintyNotes
    }

    public init(schemaVersion: Int = 1, mealID: String, proposalID: String,
                requestID: String, state: FoodEstimateProposalState = .needsConfirmation,
                generatedAt: String, provenance: FoodEstimateProvenance,
                items: [FoodEstimateItem], totals: FoodEstimateTotals,
                flags: [FoodEstimateFlag], uncertaintyNotes: [String]? = nil) throws {
        self.schemaVersion = schemaVersion; self.mealID = mealID; self.proposalID = proposalID
        self.requestID = requestID; self.state = state; self.generatedAt = generatedAt
        self.provenance = provenance; self.items = items; self.totals = totals
        self.flags = flags; self.uncertaintyNotes = uncertaintyNotes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "schemaVersion", "mealID", "proposalID", "requestID", "state", "generatedAt",
            "provenance", "items", "totals", "flags", "uncertaintyNotes"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        mealID = try c.decode(String.self, forKey: .mealID)
        proposalID = try c.decode(String.self, forKey: .proposalID)
        requestID = try c.decode(String.self, forKey: .requestID)
        state = try c.decode(FoodEstimateProposalState.self, forKey: .state)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        provenance = try c.decode(FoodEstimateProvenance.self, forKey: .provenance)
        items = try c.decode([FoodEstimateItem].self, forKey: .items)
        totals = try c.decode(FoodEstimateTotals.self, forKey: .totals)
        flags = try c.decode([FoodEstimateFlag].self, forKey: .flags)
        uncertaintyNotes = try decodeNutritionOptional([String].self, forKey: .uncertaintyNotes, from: c)
        try validate(now: NutritionValidation.now(from: decoder))
    }

    public func validate(now: Date = .now) throws {
        try NutritionValidation.validateSchema(schemaVersion)
        try NutritionValidation.validateID(mealID, field: "mealID")
        try NutritionValidation.validateID(proposalID, field: "proposalID")
        try NutritionValidation.validateID(requestID, field: "requestID")
        _ = try NutritionValidation.validateObserved(generatedAt, field: "generatedAt", now: now)
        try provenance.validate(now: now)
        guard (1...NutritionValidation.maximumItems).contains(items.count) else {
            throw NutritionValidationError.invalidBounds("items")
        }
        var itemIDs = Set<String>()
        for item in items {
            try item.validate()
            guard itemIDs.insert(item.itemID).inserted else {
                throw NutritionValidationError.duplicateIdentifier(item.itemID)
            }
        }
        try totals.validate()
        guard (1...FoodEstimateFlag.allCases.count).contains(flags.count),
              flags.contains(.needsConfirmation), Set(flags).count == flags.count else {
            throw NutritionValidationError.contradictoryState("proposal flags")
        }
        if items.contains(where: { $0.confidence == .low }) && !flags.contains(.lowConfidence) {
            throw NutritionValidationError.contradictoryState("low-confidence items require low_confidence")
        }
        if let uncertaintyNotes {
            guard uncertaintyNotes.count <= NutritionValidation.maximumUncertaintyNotes else {
                throw NutritionValidationError.invalidBounds("uncertaintyNotes")
            }
            for note in uncertaintyNotes { try NutritionValidation.validateFoodText(note, maximum: 240, field: "uncertaintyNotes") }
        }

        let generated = try NutritionValidation.parseTimestamp(generatedAt, field: "generatedAt")
        let requested = try NutritionValidation.parseTimestamp(provenance.requestTimestamp, field: "requestTimestamp")
        guard generated >= requested else {
            throw NutritionValidationError.invalidLineage("proposal generation predates inference request")
        }
        try validateTotals()
    }

    private func validateTotals() throws {
        let dimensions: [(String, FoodEstimateRange, (FoodEstimateItem) -> FoodEstimateRange)] = [
            ("grams", totals.grams, { $0.grams }),
            ("calories", totals.calories, { $0.calories }),
            ("protein", totals.protein, { $0.protein }),
            ("carbs", totals.carbs, { $0.carbs }),
            ("fat", totals.fat, { $0.fat }),
        ]
        for (name, total, value) in dimensions {
            let ranges = items.map(value)
            let sumEstimate = ranges.reduce(0) { $0 + $1.estimate }
            let sumMin = ranges.reduce(0) { $0 + $1.min }
            let sumMax = ranges.reduce(0) { $0 + $1.max }
            let tolerance = NutritionValidation.sumTolerance(sumEstimate)
            guard abs(total.estimate - sumEstimate) <= tolerance,
                  total.min <= sumMin + tolerance,
                  total.max >= sumMax - tolerance else {
                throw NutritionValidationError.invalidBounds("totals.\(name)")
            }
        }
        if let fiberTotal = totals.fiber {
            guard items.allSatisfy({ $0.fiber != nil }) else {
                throw NutritionValidationError.invalidBounds("totals.fiber")
            }
            let ranges = items.compactMap(\.fiber)
            let sumEstimate = ranges.reduce(0) { $0 + $1.estimate }
            let sumMin = ranges.reduce(0) { $0 + $1.min }
            let sumMax = ranges.reduce(0) { $0 + $1.max }
            let tolerance = NutritionValidation.sumTolerance(sumEstimate)
            guard abs(fiberTotal.estimate - sumEstimate) <= tolerance,
                  fiberTotal.min <= sumMin + tolerance,
                  fiberTotal.max >= sumMax - tolerance else {
                throw NutritionValidationError.invalidBounds("totals.fiber")
            }
        }
        try NutritionValidation.validateNutrientSemantics(
            grams: totals.grams, calories: totals.calories, protein: totals.protein,
            carbs: totals.carbs, fat: totals.fat, fiber: totals.fiber, path: "totals"
        )
    }
}

public struct FoodConfirmedItem: Codable, Equatable, Sendable {
    public let itemID: String
    public let label: String
    public let quantity: Double
    public let unit: FoodUnit
    public let grams: Double
    public let calories: Double
    public let protein: Double
    public let carbs: Double
    public let fat: Double
    public let fiber: Double?

    private enum CodingKeys: String, CodingKey {
        case itemID, label, quantity, unit, grams, calories, protein, carbs, fat, fiber
    }

    public init(itemID: String, label: String, quantity: Double, unit: FoodUnit,
                grams: Double, calories: Double, protein: Double, carbs: Double,
                fat: Double, fiber: Double? = nil) throws {
        self.itemID = itemID; self.label = label; self.quantity = quantity; self.unit = unit
        self.grams = grams; self.calories = calories; self.protein = protein
        self.carbs = carbs; self.fat = fat; self.fiber = fiber
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "itemID", "label", "quantity", "unit", "grams", "calories", "protein", "carbs", "fat", "fiber"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(String.self, forKey: .itemID)
        label = try c.decode(String.self, forKey: .label)
        quantity = try c.decode(Double.self, forKey: .quantity)
        unit = try c.decode(FoodUnit.self, forKey: .unit)
        grams = try c.decode(Double.self, forKey: .grams)
        calories = try c.decode(Double.self, forKey: .calories)
        protein = try c.decode(Double.self, forKey: .protein)
        carbs = try c.decode(Double.self, forKey: .carbs)
        fat = try c.decode(Double.self, forKey: .fat)
        fiber = try decodeNutritionOptional(Double.self, forKey: .fiber, from: c)
        try validate()
    }

    public func validate() throws {
        try NutritionValidation.validateID(itemID, field: "itemID")
        try NutritionValidation.validateFoodText(label, maximum: 160, field: "label")
        try NutritionValidation.validateQuantity(quantity, field: "quantity")
        try NutritionValidation.validateAmount(grams, field: "grams", positive: true)
        try NutritionValidation.validateAmount(calories, field: "calories")
        try NutritionValidation.validateAmount(protein, field: "protein")
        try NutritionValidation.validateAmount(carbs, field: "carbs")
        try NutritionValidation.validateAmount(fat, field: "fat")
        if let fiber { try NutritionValidation.validateAmount(fiber, field: "fiber") }
        let gramsRange = try FoodEstimateRange(estimate: grams, min: grams, max: grams)
        let caloriesRange = try FoodEstimateRange(estimate: calories, min: calories, max: calories)
        let proteinRange = try FoodEstimateRange(estimate: protein, min: protein, max: protein)
        let carbsRange = try FoodEstimateRange(estimate: carbs, min: carbs, max: carbs)
        let fatRange = try FoodEstimateRange(estimate: fat, min: fat, max: fat)
        let fiberRange = try fiber.map { try FoodEstimateRange(estimate: $0, min: $0, max: $0) }
        try NutritionValidation.validateNutrientSemantics(
            grams: gramsRange, calories: caloriesRange, protein: proteinRange,
            carbs: carbsRange, fat: fatRange, fiber: fiberRange, path: "item"
        )
    }
}

public struct FoodConfirmedTotals: Codable, Equatable, Sendable {
    public let grams: Double
    public let calories: Double
    public let protein: Double
    public let carbs: Double
    public let fat: Double
    public let fiber: Double?

    private enum CodingKeys: String, CodingKey { case grams, calories, protein, carbs, fat, fiber }

    public init(grams: Double, calories: Double, protein: Double, carbs: Double,
                fat: Double, fiber: Double? = nil) throws {
        self.grams = grams; self.calories = calories; self.protein = protein
        self.carbs = carbs; self.fat = fat; self.fiber = fiber
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: ["grams", "calories", "protein", "carbs", "fat", "fiber"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grams = try c.decode(Double.self, forKey: .grams)
        calories = try c.decode(Double.self, forKey: .calories)
        protein = try c.decode(Double.self, forKey: .protein)
        carbs = try c.decode(Double.self, forKey: .carbs)
        fat = try c.decode(Double.self, forKey: .fat)
        fiber = try decodeNutritionOptional(Double.self, forKey: .fiber, from: c)
        try validate()
    }

    public func validate() throws {
        try NutritionValidation.validateAmount(grams, field: "grams", positive: true)
        try NutritionValidation.validateAmount(calories, field: "calories")
        try NutritionValidation.validateAmount(protein, field: "protein")
        try NutritionValidation.validateAmount(carbs, field: "carbs")
        try NutritionValidation.validateAmount(fat, field: "fat")
        if let fiber { try NutritionValidation.validateAmount(fiber, field: "fiber") }
    }
}

public enum FoodConfirmationAction: String, Codable, CaseIterable, Sendable {
    case reject
    case confirm
    case editAndConfirm = "edit_and_confirm"
}

/// A confirmation is the only native contract branch that can carry a final
/// structured meal.  Rejection intentionally has no meal fields at all.
public struct FoodConfirmationRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let mealID: String
    public let requestID: String
    public let proposalID: String
    public let action: FoodConfirmationAction
    public let mealName: String?
    public let mealAt: String?
    public let items: [FoodConfirmedItem]?
    public let totals: FoodConfirmedTotals?
    public let confirmedAt: String?
    public let rejectedAt: String?
    public let reason: String?
    public let correctionNotes: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mealID, requestID, proposalID, action, mealName, mealAt,
             items, totals, confirmedAt, rejectedAt, reason, correctionNotes
    }

    public init(schemaVersion: Int = 1, mealID: String, requestID: String,
                proposalID: String, action: FoodConfirmationAction,
                mealName: String? = nil, mealAt: String? = nil,
                items: [FoodConfirmedItem]? = nil, totals: FoodConfirmedTotals? = nil,
                confirmedAt: String? = nil, rejectedAt: String? = nil,
                reason: String? = nil, correctionNotes: String? = nil) throws {
        self.schemaVersion = schemaVersion; self.mealID = mealID; self.requestID = requestID
        self.proposalID = proposalID; self.action = action; self.mealName = mealName
        self.mealAt = mealAt; self.items = items; self.totals = totals
        self.confirmedAt = confirmedAt; self.rejectedAt = rejectedAt; self.reason = reason
        self.correctionNotes = correctionNotes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownNutritionKeys(decoder, allowed: [
            "schemaVersion", "mealID", "requestID", "proposalID", "action", "mealName",
            "mealAt", "items", "totals", "confirmedAt", "rejectedAt", "reason", "correctionNotes"
        ])
        let all = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try all.decode(Int.self, forKey: .schemaVersion)
        mealID = try all.decode(String.self, forKey: .mealID)
        requestID = try all.decode(String.self, forKey: .requestID)
        proposalID = try all.decode(String.self, forKey: .proposalID)
        action = try all.decode(FoodConfirmationAction.self, forKey: .action)

        switch action {
        case .reject:
            try rejectUnknownNutritionKeys(decoder, allowed: [
                "schemaVersion", "mealID", "requestID", "proposalID", "action", "rejectedAt", "reason"
            ])
            mealName = nil; mealAt = nil; items = nil; totals = nil; confirmedAt = nil
            rejectedAt = try all.decode(String.self, forKey: .rejectedAt)
            reason = try decodeNutritionOptional(String.self, forKey: .reason, from: all)
            correctionNotes = nil
        case .confirm:
            try rejectUnknownNutritionKeys(decoder, allowed: [
                "schemaVersion", "mealID", "requestID", "proposalID", "action", "mealName",
                "mealAt", "items", "totals", "confirmedAt"
            ])
            mealName = try decodeNutritionOptional(String.self, forKey: .mealName, from: all)
            mealAt = try all.decode(String.self, forKey: .mealAt)
            items = try all.decode([FoodConfirmedItem].self, forKey: .items)
            totals = try all.decode(FoodConfirmedTotals.self, forKey: .totals)
            confirmedAt = try all.decode(String.self, forKey: .confirmedAt)
            rejectedAt = nil; reason = nil; correctionNotes = nil
        case .editAndConfirm:
            try rejectUnknownNutritionKeys(decoder, allowed: [
                "schemaVersion", "mealID", "requestID", "proposalID", "action", "mealName",
                "mealAt", "items", "totals", "confirmedAt", "correctionNotes"
            ])
            mealName = try decodeNutritionOptional(String.self, forKey: .mealName, from: all)
            mealAt = try all.decode(String.self, forKey: .mealAt)
            items = try all.decode([FoodConfirmedItem].self, forKey: .items)
            totals = try all.decode(FoodConfirmedTotals.self, forKey: .totals)
            confirmedAt = try all.decode(String.self, forKey: .confirmedAt)
            correctionNotes = try all.decode(String.self, forKey: .correctionNotes)
            rejectedAt = nil; reason = nil
        }
        try validate(now: NutritionValidation.now(from: decoder))
    }

    public func validate(now: Date = .now) throws {
        try NutritionValidation.validateSchema(schemaVersion)
        try NutritionValidation.validateID(mealID, field: "mealID")
        try NutritionValidation.validateID(requestID, field: "requestID")
        try NutritionValidation.validateID(proposalID, field: "proposalID")

        switch action {
        case .reject:
            guard let rejectedAt else { throw NutritionValidationError.contradictoryState("rejection requires rejectedAt") }
            _ = try NutritionValidation.validateObserved(rejectedAt, field: "rejectedAt", now: now)
            if let reason { try NutritionValidation.validateSecretFreeText(reason, maximum: 500, field: "reason") }
            guard mealName == nil, mealAt == nil, items == nil, totals == nil,
                  confirmedAt == nil, correctionNotes == nil else {
                throw NutritionValidationError.contradictoryState("rejection cannot carry a meal")
            }
        case .confirm, .editAndConfirm:
            guard let mealAt, let items, let totals, let confirmedAt else {
                throw NutritionValidationError.contradictoryState("confirmation requires meal, totals, and confirmedAt")
            }
            _ = try NutritionValidation.validateObserved(mealAt, field: "mealAt", now: now)
            _ = try NutritionValidation.validateObserved(confirmedAt, field: "confirmedAt", now: now)
            if let mealName { try NutritionValidation.validateFoodText(mealName, maximum: 200, field: "mealName") }
            guard (1...NutritionValidation.maximumItems).contains(items.count) else {
                throw NutritionValidationError.invalidBounds("items")
            }
            for item in items { try item.validate() }
            try totals.validate()
            try validateConfirmedMeal(items: items, totals: totals)
            guard rejectedAt == nil, reason == nil else {
                throw NutritionValidationError.contradictoryState("confirmation cannot carry rejection fields")
            }
            if action == .confirm {
                guard correctionNotes == nil else {
                    throw NutritionValidationError.contradictoryState("only edits may carry correction notes")
                }
            } else {
                guard let correctionNotes else {
                    throw NutritionValidationError.contradictoryState("edit confirmation requires correction notes")
                }
                try NutritionValidation.validateFoodText(correctionNotes, maximum: 500, field: "correctionNotes")
            }
        }
    }

    private func validateConfirmedMeal(items: [FoodConfirmedItem], totals: FoodConfirmedTotals) throws {
        var ids = Set<String>()
        for item in items {
            guard ids.insert(item.itemID).inserted else {
                throw NutritionValidationError.duplicateIdentifier(item.itemID)
            }
        }
        func sum(_ keyPath: KeyPath<FoodConfirmedItem, Double>) -> Double {
            items.reduce(0) { $0 + $1[keyPath: keyPath] }
        }
        let required: [(String, Double, KeyPath<FoodConfirmedItem, Double>)] = [
            ("grams", totals.grams, \.grams),
            ("calories", totals.calories, \.calories),
            ("protein", totals.protein, \.protein),
            ("carbs", totals.carbs, \.carbs),
            ("fat", totals.fat, \.fat),
        ]
        for (name, total, keyPath) in required {
            let itemSum = sum(keyPath)
            guard abs(total - itemSum) <= NutritionValidation.sumTolerance(itemSum) else {
                throw NutritionValidationError.invalidBounds("totals.\(name)")
            }
        }
        if let totalFiber = totals.fiber {
            guard items.allSatisfy({ $0.fiber != nil }) else {
                throw NutritionValidationError.invalidBounds("totals.fiber")
            }
            let itemFiber = items.reduce(0) { $0 + ($1.fiber ?? 0) }
            guard abs(totalFiber - itemFiber) <= NutritionValidation.sumTolerance(itemFiber) else {
                throw NutritionValidationError.invalidBounds("totals.fiber")
            }
        }

        // TS validates confirmed totals with grams/calories/macros only; fiber
        // remains an optional consistency field, not part of energy plausibility.
        let gramsRange = try FoodEstimateRange(estimate: totals.grams, min: totals.grams, max: totals.grams)
        let caloriesRange = try FoodEstimateRange(estimate: totals.calories, min: totals.calories, max: totals.calories)
        let proteinRange = try FoodEstimateRange(estimate: totals.protein, min: totals.protein, max: totals.protein)
        let carbsRange = try FoodEstimateRange(estimate: totals.carbs, min: totals.carbs, max: totals.carbs)
        let fatRange = try FoodEstimateRange(estimate: totals.fat, min: totals.fat, max: totals.fat)
        try NutritionValidation.validateNutrientSemantics(
            grams: gramsRange, calories: caloriesRange, protein: proteinRange,
            carbs: carbsRange, fat: fatRange, fiber: nil, path: "totals"
        )
    }
}

/// Verifies that a proposal refers to exactly the request, meal, capture, and
/// sanitized image hashes that the user opted into, in the original order.
public func validateFoodEstimateProposalAgainstManifest(
    _ proposal: FoodEstimateProposal,
    _ manifest: FoodPhotoManifest,
    now: Date = .now
) throws -> FoodEstimateProposal {
    try proposal.validate(now: now)
    try manifest.validate(now: now)
    guard proposal.requestID == manifest.requestID, proposal.mealID == manifest.mealID else {
        throw NutritionValidationError.invalidLineage("proposal request/meal id does not match photo manifest")
    }
    let capturedAt = try NutritionValidation.parseTimestamp(manifest.capturedAt, field: "capturedAt")
    let requestAt = try NutritionValidation.parseTimestamp(proposal.provenance.requestTimestamp, field: "requestTimestamp")
    guard requestAt >= capturedAt else {
        throw NutritionValidationError.invalidLineage("proposal request timestamp predates photo capture")
    }
    let hashes = proposal.provenance.sanitizedImageHashes
    guard hashes.count == manifest.images.count,
          hashes.enumerated().allSatisfy({ index, hash in
              guard index < manifest.images.count else { return false }
              let image = manifest.images[index]
              return hash.imageID == image.imageID
                  && hash.sha256.caseInsensitiveCompare(image.sha256) == .orderedSame
          }) else {
        throw NutritionValidationError.invalidLineage("proposal image hashes do not reference exactly the manifest images")
    }
    return proposal
}

/// Verifies confirmation lineage while allowing legitimate user-edited totals.
public func validateFoodConfirmationAgainstProposal(
    _ confirmation: FoodConfirmationRequest,
    _ proposal: FoodEstimateProposal,
    now: Date = .now
) throws -> FoodConfirmationRequest {
    try confirmation.validate(now: now)
    try proposal.validate(now: now)
    guard confirmation.requestID == proposal.requestID,
          confirmation.proposalID == proposal.proposalID,
          confirmation.mealID == proposal.mealID else {
        throw NutritionValidationError.invalidLineage("confirmation does not reference the reviewed proposal lineage")
    }
    let eventAt: String
    switch confirmation.action {
    case .reject: eventAt = confirmation.rejectedAt!
    case .confirm, .editAndConfirm: eventAt = confirmation.confirmedAt!
    }
    let eventDate = try NutritionValidation.parseTimestamp(eventAt)
    let proposalDate = try NutritionValidation.parseTimestamp(proposal.generatedAt)
    guard eventDate >= proposalDate else {
        throw NutritionValidationError.invalidLineage("confirmation event predates the proposal")
    }
    return confirmation
}

public struct NutritionContractConstants: Sendable {
    public static let schemaVersion = 1
    public static let maximumClockSkewMilliseconds = 5_000
    public static let maximumPhotoBytes = 20 * 1_024 * 1_024
    public static let maximumPhotoCount = 3
    public static let maximumItems = 40

    private init() {}
}

// MARK: - Photo retention and storage policy

/// Storage classes are explicit because the retention clock for an original
/// is intentionally different from the clock for a review/detail derivative.
/// A derivative may never be larger than 500 KiB, even when the source image
/// was within the 20 MiB request limit.
public enum NutritionPhotoAssetKind: String, Codable, CaseIterable, Sendable {
    case original
    case detail
    case derivative
}

public enum NutritionPhotoStorageState: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
    case ingestBlocked = "ingest_blocked"
}

/// Retention is a decision, not an implicit delete.  A caller must record an
/// explicit deletion/export action before removing an eligible asset; this
/// policy never silently removes a photo or its provenance.
public enum NutritionPhotoRetentionDecision: String, Codable, Equatable, Sendable {
    case retain
    case eligibleForDeletion = "eligible_for_deletion"
    case rejectIngest = "reject_ingest"
}

public enum NutritionPhotoRetentionPolicy {
    public static let maximumImagesPerMeal = 3
    public static let maximumInputBytes = 20 * 1_024 * 1_024
    public static let maximumDerivativeBytes = 500 * 1_024
    public static let originalRetention: TimeInterval = 90 * 86_400
    public static let detailRetention: TimeInterval = 365 * 86_400
    public static let warningStorageBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    public static let criticalStorageBytes: Int64 = 9 * 1_024 * 1_024 * 1_024
    public static let ingestGateStorageBytes: Int64 = 10 * 1_024 * 1_024 * 1_024

    public static func storageState(totalBytes: Int64) -> NutritionPhotoStorageState {
        guard totalBytes >= 0 else { return .ingestBlocked }
        if totalBytes >= ingestGateStorageBytes { return .ingestBlocked }
        if totalBytes >= criticalStorageBytes { return .critical }
        if totalBytes >= warningStorageBytes { return .warning }
        return .normal
    }

    public static func validateAsset(
        kind: NutritionPhotoAssetKind,
        byteCount: Int,
        imageCount: Int,
        totalStorageBytes: Int64 = 0
    ) throws {
        guard (1...maximumImagesPerMeal).contains(imageCount) else {
            throw NutritionValidationError.invalidBounds("photoRetention.imageCount")
        }
        guard (1...maximumInputBytes).contains(byteCount) else {
            throw NutritionValidationError.invalidBounds("photoRetention.byteCount")
        }
        if kind == .derivative, byteCount > maximumDerivativeBytes {
            throw NutritionValidationError.invalidBounds("photoRetention.derivativeBytes")
        }
        guard totalStorageBytes >= 0, totalStorageBytes < ingestGateStorageBytes else {
            throw NutritionValidationError.invalidBounds("photoRetention.storageGate")
        }
    }

    public static func retentionDeadline(
        for kind: NutritionPhotoAssetKind,
        capturedAt: Date
    ) -> Date? {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let interval = kind == .original ? originalRetention : detailRetention
        return capturedAt.addingTimeInterval(interval)
    }

    public static func decision(
        for kind: NutritionPhotoAssetKind,
        capturedAt: Date,
        now: Date,
        byteCount: Int,
        imageCount: Int,
        totalStorageBytes: Int64 = 0
    ) -> NutritionPhotoRetentionDecision {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let deadline = retentionDeadline(for: kind, capturedAt: capturedAt) else {
            return .rejectIngest
        }
        do {
            try validateAsset(
                kind: kind,
                byteCount: byteCount,
                imageCount: imageCount,
                totalStorageBytes: totalStorageBytes
            )
        } catch {
            return .rejectIngest
        }
        return now >= deadline ? .eligibleForDeletion : .retain
    }
}
