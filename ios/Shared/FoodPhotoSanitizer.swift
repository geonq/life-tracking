import Foundation
import CoreGraphics
import CoreFoundation
import ImageIO
import CryptoKit

// MARK: - Client-side food photo sanitizer

/// A caller-owned image identifier and bounded in-memory input.  No filename,
/// local path, URL, EXIF, or GPS field is accepted at this boundary.
public struct FoodPhotoSanitizerInput: Equatable, Sendable {
    public let imageID: String
    public let data: Data

    public init(imageID: String, data: Data) throws {
        guard Self.isSafeIdentifier(imageID) else {
            throw FoodPhotoSanitizationError.unsafeImageID
        }
        guard !data.isEmpty, data.count <= FoodPhotoSanitizer.maximumInputBytes else {
            throw FoodPhotoSanitizationError.inputTooLarge
        }
        self.imageID = imageID
        self.data = data
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), let first = bytes.first else { return false }
        let firstIsAlphaNumeric = (48...57).contains(first)
            || (65...90).contains(first)
            || (97...122).contains(first)
        guard firstIsAlphaNumeric else { return false }
        return bytes.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public enum FoodPhotoSanitizationError: Error, Equatable, Sendable {
    case emptyInput
    case tooManyImages
    case duplicateImageID(String)
    case unsafeImageID
    case inputTooLarge
    case unsupportedImageType
    case invalidImage
    case invalidDimensions
    case invalidOrientation
    case outputTooLarge
    case encodingFailed
    case sensitiveMetadataPresent
}

/// Deterministic, bounded encoding options.  Production uses `standard`: JPEG
/// quality is fixed at 0.92 for opaque pixels, while images with an alpha
/// channel always use PNG to preserve transparency.  The output-byte override
/// is intentionally capped at the contract's 20 MiB limit and is useful for
/// small deterministic tests without manufacturing a 20+ MiB image.
public struct FoodPhotoSanitizerOptions: Equatable, Sendable {
    public let jpegQuality: Double
    public let maximumOutputBytes: Int

    public init(jpegQuality: Double = 0.92,
                maximumOutputBytes: Int = FoodPhotoSanitizer.maximumOutputBytes) throws {
        guard jpegQuality.isFinite, (0.5...0.98).contains(jpegQuality),
              (1...FoodPhotoSanitizer.maximumOutputBytes).contains(maximumOutputBytes) else {
            throw FoodPhotoSanitizationError.outputTooLarge
        }
        self.jpegQuality = jpegQuality
        self.maximumOutputBytes = maximumOutputBytes
    }

    public static let standard = try! FoodPhotoSanitizerOptions()
}

/// Sanitizes opted-in image bytes locally before a caller chooses whether to
/// upload them.  This type performs no network, persistence, PhotosPicker, or
/// provider/SDK work.  A failed item throws and no partial descriptor array is
/// returned.
public struct FoodPhotoSanitizer: Sendable {
    public static let maximumInputBytes = 20 * 1_024 * 1_024
    public static let maximumAggregateInputBytes = 20 * 1_024 * 1_024
    public static let maximumOutputBytes = 20 * 1_024 * 1_024
    public static let maximumImageCount = 3
    public static let maximumImageDimension = 12_000
    public static let maximumImagePixels = 40_000_000
    /// ImageIO may materialize an RGBA buffer during the post-bound decode.
    /// Keeping the hard contract at 40M pixels bounds that primary buffer to
    /// roughly 160 MB before encoder output (which is separately capped).
    public static let maximumDecodedRGBABytes = maximumImagePixels * 4

    private static let supportedInputTypes: Set<String> = [
        "public.jpeg", "public.png", "public.heic", "public.heif",
        "public.webp", "org.webmproject.webp"
    ]

    private let options: FoodPhotoSanitizerOptions

    public init(options: FoodPhotoSanitizerOptions = .standard) {
        self.options = options
    }

    /// Preserves the caller's input order and IDs exactly.  The returned
    /// descriptors contain only sanitized output bytes as canonical base64;
    /// original input `Data` is never retained in the result.
    public func sanitize(_ inputs: [FoodPhotoSanitizerInput]) throws -> [FoodPhotoImageDescriptor] {
        guard !inputs.isEmpty else { throw FoodPhotoSanitizationError.emptyInput }
        guard inputs.count <= Self.maximumImageCount else {
            throw FoodPhotoSanitizationError.tooManyImages
        }

        var ids = Set<String>()
        for input in inputs {
            guard ids.insert(input.imageID).inserted else {
                throw FoodPhotoSanitizationError.duplicateImageID(input.imageID)
            }
        }
        var totalInputBytes = 0
        for input in inputs {
            let (next, overflow) = totalInputBytes.addingReportingOverflow(input.data.count)
            guard !overflow else { throw FoodPhotoSanitizationError.inputTooLarge }
            totalInputBytes = next
        }
        guard totalInputBytes <= Self.maximumAggregateInputBytes else {
            throw FoodPhotoSanitizationError.inputTooLarge
        }

        var descriptors: [FoodPhotoImageDescriptor] = []
        descriptors.reserveCapacity(inputs.count)
        var totalOutputBytes = 0
        for input in inputs {
            let descriptor = try sanitizeOne(input)
            let (next, overflow) = totalOutputBytes.addingReportingOverflow(descriptor.byteLength)
            guard !overflow else { throw FoodPhotoSanitizationError.outputTooLarge }
            totalOutputBytes = next
            guard totalOutputBytes <= Self.maximumOutputBytes else {
                throw FoodPhotoSanitizationError.outputTooLarge
            }
            descriptors.append(descriptor)
        }
        return descriptors
    }

    private func sanitizeOne(_ input: FoodPhotoSanitizerInput) throws -> FoodPhotoImageDescriptor {
        // The input initializer enforces this bound too; retain the check here
        // so callers cannot bypass it through future construction changes.
        guard !input.data.isEmpty, input.data.count <= Self.maximumInputBytes else {
            throw FoodPhotoSanitizationError.inputTooLarge
        }

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(input.data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source),
              Self.supportedInputTypes.contains(sourceType as String) else {
            throw FoodPhotoSanitizationError.unsupportedImageType
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = integerProperty(properties[kCGImagePropertyPixelWidth]),
              let height = integerProperty(properties[kCGImagePropertyPixelHeight]),
              (1...Self.maximumImageDimension).contains(width),
              (1...Self.maximumImageDimension).contains(height),
              width * height <= Self.maximumImagePixels,
              width * height <= Self.maximumDecodedRGBABytes / 4 else {
            // This guard happens before ImageIO is asked to create a decoded
            // image, preventing oversized pixel payloads from being expanded.
            throw FoodPhotoSanitizationError.invalidDimensions
        }

        let orientation = integerProperty(properties[kCGImagePropertyOrientation]) ?? 1
        guard (1...8).contains(orientation) else {
            throw FoodPhotoSanitizationError.invalidOrientation
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let normalizedImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            throw FoodPhotoSanitizationError.invalidImage
        }

        let outputWidth = normalizedImage.width
        let outputHeight = normalizedImage.height
        guard (1...Self.maximumImageDimension).contains(outputWidth),
              (1...Self.maximumImageDimension).contains(outputHeight),
              outputWidth * outputHeight <= Self.maximumImagePixels else {
            throw FoodPhotoSanitizationError.invalidDimensions
        }

        let preservesAlpha = Self.hasAlpha(normalizedImage)
        let outputFormat: FoodPhotoOutputFormat = preservesAlpha ? .png : .jpeg
        let outputType: CFString = outputFormat == .png ? "public.png" as CFString : "public.jpeg" as CFString
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData, outputType, 1, nil
        ) else {
            throw FoodPhotoSanitizationError.encodingFailed
        }

        let encodingProperties: [CFString: Any]? = outputFormat == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: options.jpegQuality]
            : nil
        CGImageDestinationAddImage(destination, normalizedImage, encodingProperties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else {
            throw FoodPhotoSanitizationError.encodingFailed
        }

        let encodedData = outputData as Data
        let sanitizedData: Data
        switch outputFormat {
        case .jpeg:
            // ImageIO may synthesize an APP1 Exif segment containing only
            // pixel dimensions. Remove every APP1–APP15/COM segment before
            // the final property verification so no Exif/IPTC/vendor block
            // can survive the local boundary.
            sanitizedData = try Self.stripJPEGMetadataSegments(encodedData)
        case .png:
            sanitizedData = encodedData
        }
        guard !sanitizedData.isEmpty, sanitizedData.count <= options.maximumOutputBytes else {
            throw FoodPhotoSanitizationError.outputTooLarge
        }
        try verifySanitizedOutput(
            sanitizedData, expectedFormat: outputFormat,
            expectedWidth: outputWidth, expectedHeight: outputHeight,
            expectedHasAlpha: preservesAlpha
        )

        let digest = SHA256.hash(data: sanitizedData)
            .map { String(format: "%02x", $0) }
            .joined()
        let descriptor = try FoodPhotoImageDescriptor(
            imageID: input.imageID,
            mimeType: outputFormat.mimeType,
            byteLength: sanitizedData.count,
            width: outputWidth,
            height: outputHeight,
            sanitized: true,
            inlineDataBase64: sanitizedData.base64EncodedString(),
            sha256: digest
        )
        return descriptor
    }

    private func verifySanitizedOutput(
        _ data: Data,
        expectedFormat: FoodPhotoOutputFormat,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedHasAlpha: Bool
    ) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              type as String == expectedFormat.uti,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              integerProperty(properties[kCGImagePropertyPixelWidth]) == expectedWidth,
              integerProperty(properties[kCGImagePropertyPixelHeight]) == expectedHeight else {
            throw FoodPhotoSanitizationError.encodingFailed
        }
        if let outputOrientation = integerProperty(properties[kCGImagePropertyOrientation]),
           outputOrientation != 1 {
            throw FoodPhotoSanitizationError.sensitiveMetadataPresent
        }
        try verifySanitizedMetadata(
            properties,
            expectedFormat: expectedFormat,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            expectedHasAlpha: expectedHasAlpha
        )
    }

    private static func integerProperty(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func integerProperty(_ value: Any?) -> Int? {
        Self.integerProperty(value)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    private func verifySanitizedMetadata(
        _ properties: [CFString: Any],
        expectedFormat: FoodPhotoOutputFormat,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedHasAlpha: Bool
    ) throws {
        let allowedTopLevelKeys: Set<String> = [
            "ColorModel", "Depth", "PixelWidth", "PixelHeight", "HasAlpha",
            "ProfileName", "{Exif}", "{JFIF}", "{PNG}"
        ]
        var topLevel: [String: Any] = [:]
        for (key, value) in properties {
            let keyText = key as String
            guard allowedTopLevelKeys.contains(keyText),
                  topLevel[keyText] == nil else {
                throw FoodPhotoSanitizationError.sensitiveMetadataPresent
            }
            topLevel[keyText] = value
        }

        guard Self.exactString(topLevel["ColorModel"]) == "RGB",
              Self.exactInteger(topLevel["Depth"]) == 8,
              Self.exactInteger(topLevel["PixelWidth"]) == expectedWidth,
              Self.exactInteger(topLevel["PixelHeight"]) == expectedHeight else {
            throw FoodPhotoSanitizationError.sensitiveMetadataPresent
        }

        if let profileName = topLevel["ProfileName"],
           Self.exactString(profileName) != "sRGB IEC61966-2.1" {
            throw FoodPhotoSanitizationError.sensitiveMetadataPresent
        }
        if let hasAlpha = topLevel["HasAlpha"] {
            guard let hasAlpha = Self.exactBoolean(hasAlpha), hasAlpha == expectedHasAlpha else {
                throw FoodPhotoSanitizationError.sensitiveMetadataPresent
            }
        }

        if let exif = topLevel["{Exif}"] {
            try verifyEXIFDictionary(exif, expectedWidth: expectedWidth, expectedHeight: expectedHeight)
        }
        if let jfif = topLevel["{JFIF}"] {
            try verifyJFIFDictionary(jfif)
        }
        if let png = topLevel["{PNG}"] {
            try verifyPNGDictionary(png)
        }

        switch expectedFormat {
        case .jpeg:
            guard topLevel["{JFIF}"] != nil, topLevel["{PNG}"] == nil else {
                throw FoodPhotoSanitizationError.sensitiveMetadataPresent
            }
        case .png:
            guard topLevel["{PNG}"] != nil, topLevel["{JFIF}"] == nil else {
                throw FoodPhotoSanitizationError.sensitiveMetadataPresent
            }
        }
    }

    private func verifyEXIFDictionary(
        _ value: Any,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        let values = try exactDictionary(
            value,
            keys: ["ColorSpace", "PixelXDimension", "PixelYDimension"]
        )
        guard Self.exactInteger(values["ColorSpace"]) == 1,
              Self.exactInteger(values["PixelXDimension"]) == expectedWidth,
              Self.exactInteger(values["PixelYDimension"]) == expectedHeight else {
            throw FoodPhotoSanitizationError.sensitiveMetadataPresent
        }
    }

    private func verifyJFIFDictionary(_ value: Any) throws {
        let values = try exactDictionary(
            value,
            keys: ["DensityUnit", "JFIFVersion", "XDensity", "YDensity"]
        )
        guard Self.exactInteger(values["DensityUnit"]) == 0,
              Self.exactInteger(values["XDensity"]) == 72,
              Self.exactInteger(values["YDensity"]) == 72,
              let version = values["JFIFVersion"] as? NSArray,
              version.count == 3,
              version.enumerated().allSatisfy({ index, value in
                  Self.exactInteger(value) == [1, 0, 1][index]
              }) else {
            throw FoodPhotoSanitizationError.sensitiveMetadataPresent
        }
    }

    private func verifyPNGDictionary(_ value: Any) throws {
        let values = try exactDictionary(
            value,
            keys: ["InterlaceType", "sRGBIntent", "Gamma", "Chromaticities"]
        )
        guard Self.exactInteger(values["InterlaceType"]) == 0,
              Self.exactInteger(values["sRGBIntent"]) == 0,
              Self.isGamma(values["Gamma"]),
              Self.isChromaticities(values["Chromaticities"]) else {
            throw FoodPhotoSanitizationError.sensitiveMetadataPresent
        }
    }

    private func exactDictionary(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let dictionary = value as? NSDictionary else {
            throw FoodPhotoSanitizationError.sensitiveMetadataPresent
        }
        var values: [String: Any] = [:]
        for key in dictionary.allKeys {
            guard let keyText = key as? String,
                  keys.contains(keyText),
                  let nested = dictionary.object(forKey: key),
                  values[keyText] == nil else {
                throw FoodPhotoSanitizationError.sensitiveMetadataPresent
            }
            values[keyText] = nested
        }
        guard values.count == keys.count else {
            throw FoodPhotoSanitizationError.sensitiveMetadataPresent
        }
        return values
    }

    private static func exactString(_ value: Any?) -> String? {
        value as? String
    }

    private static func exactBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func exactDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func isGamma(_ value: Any?) -> Bool {
        let gamma = exactDouble(value) ?? (value as? String).flatMap(Double.init)
        guard let gamma, gamma.isFinite else { return false }
        return abs(gamma - 0.45455) <= 0.000001
    }

    private static func isChromaticities(_ value: Any?) -> Bool {
        let expected = [0.3127, 0.329, 0.64, 0.33, 0.3, 0.6, 0.15, 0.06]
        guard let values = value as? NSArray, values.count == expected.count else { return false }
        return values.enumerated().allSatisfy { index, value in
            let number = exactDouble(value) ?? (value as? String).flatMap(Double.init)
            guard let number, number.isFinite else {
                return false
            }
            return abs(number - expected[index]) <= 0.000001
        }
    }

    private static func stripJPEGMetadataSegments(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw FoodPhotoSanitizationError.encodingFailed
        }

        var sanitized = [UInt8](bytes[0..<2])
        var index = 2
        while index < bytes.count {
            let segmentStart = index
            guard bytes[index] == 0xff else { throw FoodPhotoSanitizationError.encodingFailed }
            while index < bytes.count, bytes[index] == 0xff { index += 1 }
            guard index < bytes.count else { throw FoodPhotoSanitizationError.encodingFailed }
            let marker = bytes[index]
            index += 1

            if marker == 0xda {
                guard index + 2 <= bytes.count else { throw FoodPhotoSanitizationError.encodingFailed }
                let length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
                guard length >= 2, index + length <= bytes.count else {
                    throw FoodPhotoSanitizationError.encodingFailed
                }
                let scanDataStart = index + length
                sanitized.append(contentsOf: bytes[segmentStart..<scanDataStart])
                var scanIndex = scanDataStart
                while scanIndex < bytes.count {
                    guard bytes[scanIndex] == 0xff else {
                        scanIndex += 1
                        continue
                    }
                    while scanIndex < bytes.count, bytes[scanIndex] == 0xff { scanIndex += 1 }
                    guard scanIndex < bytes.count else { throw FoodPhotoSanitizationError.encodingFailed }
                    let scanMarker = bytes[scanIndex]
                    scanIndex += 1
                    if scanMarker == 0x00 || (0xd0...0xd7).contains(scanMarker) {
                        continue // stuffed byte or restart marker
                    }
                    guard scanMarker == 0xd9 else {
                        throw FoodPhotoSanitizationError.encodingFailed
                    }
                    sanitized.append(contentsOf: bytes[scanDataStart...scanIndex - 1])
                    // A valid encoder should end at EOI. Zero padding is
                    // harmless transport padding; all other trailing bytes
                    // are rejected and never enter the descriptor hash.
                    if scanIndex < bytes.count,
                       !bytes[scanIndex...].allSatisfy({ $0 == 0 }) {
                        throw FoodPhotoSanitizationError.encodingFailed
                    }
                    return Data(sanitized)
                }
                throw FoodPhotoSanitizationError.encodingFailed
            }
            if marker == 0xd9 {
                // EOI before SOS is malformed for this sanitizer boundary.
                throw FoodPhotoSanitizationError.encodingFailed
            }
            // Standalone markers have no length field.
            if marker == 0x01 || (0xd0...0xd7).contains(marker) {
                sanitized.append(contentsOf: bytes[segmentStart..<index])
                continue
            }
            guard index + 2 <= bytes.count else { throw FoodPhotoSanitizationError.encodingFailed }
            let length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.count else {
                throw FoodPhotoSanitizationError.encodingFailed
            }
            let segmentEnd = index + length
            let isMetadata = (0xe1...0xef).contains(marker) || marker == 0xfe
            if !isMetadata {
                sanitized.append(contentsOf: bytes[segmentStart..<segmentEnd])
            }
            index = segmentEnd
        }
        throw FoodPhotoSanitizationError.encodingFailed
    }
}

private enum FoodPhotoOutputFormat: Equatable {
    case jpeg
    case png

    var uti: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        }
    }

    var mimeType: FoodImageMimeType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }
}
