import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import XCTest
@testable import LifeOS

final class FoodPhotoSanitizerTests: XCTestCase {
    private let validPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    private func makeImage(
        width: Int,
        height: Int,
        uti: String = "public.jpeg",
        orientation: Int? = nil,
        includeSensitiveMetadata: Bool = false,
        alpha: Bool = false
    ) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: alphaInfo.rawValue
        ), let image = context.makeImage() else {
            throw FoodPhotoSanitizationError.invalidImage
        }

        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, uti as CFString, 1, nil) else {
            throw FoodPhotoSanitizationError.encodingFailed
        }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if includeSensitiveMetadata {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 52.5200,
                kCGImagePropertyGPSLongitude: 13.4050,
            ] as [CFString: Any]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:11 12:00:00",
            ] as [CFString: Any]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFArtist: "synthetic-test",
                kCGImagePropertyTIFFDateTime: "2026:08:11 12:00:00",
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FoodPhotoSanitizationError.encodingFailed
        }
        return bytes as Data
    }

    private func input(_ id: String, data: Data) throws -> FoodPhotoSanitizerInput {
        try FoodPhotoSanitizerInput(imageID: id, data: data)
    }

    private func outputProperties(_ descriptor: FoodPhotoImageDescriptor) throws -> [CFString: Any] {
        let data = try XCTUnwrap(Data(base64Encoded: descriptor.inlineDataBase64))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func properties(for data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func property(_ key: String, in properties: [CFString: Any]) -> Any? {
        properties.first { String(describing: $0.key) == key }?.value
    }

    private func assertExactSanitizedMetadata(
        _ properties: [CFString: Any],
        format: FoodImageMimeType,
        width: Int,
        height: Int,
        hasAlpha: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actualKeys = Set(properties.keys.compactMap { $0 as? String })
        let expectedKeys: Set<String> = format == .jpeg
            ? ["ColorModel", "Depth", "PixelWidth", "PixelHeight", "ProfileName", "{JFIF}"]
            : ["ColorModel", "Depth", "PixelWidth", "PixelHeight", "HasAlpha", "ProfileName", "{Exif}", "{PNG}"]
        XCTAssertEqual(actualKeys, expectedKeys, file: file, line: line)
        XCTAssertEqual(property("ColorModel", in: properties) as? String, "RGB", file: file, line: line)
        XCTAssertEqual((property("Depth", in: properties) as? NSNumber)?.intValue, 8, file: file, line: line)
        XCTAssertEqual((property("PixelWidth", in: properties) as? NSNumber)?.intValue, width, file: file, line: line)
        XCTAssertEqual((property("PixelHeight", in: properties) as? NSNumber)?.intValue, height, file: file, line: line)
        XCTAssertEqual(property("ProfileName", in: properties) as? String, "sRGB IEC61966-2.1", file: file, line: line)

        if format == .png {
            let alpha = try XCTUnwrap(property("HasAlpha", in: properties) as? NSNumber, file: file, line: line)
            XCTAssertEqual(CFGetTypeID(alpha), CFBooleanGetTypeID(), file: file, line: line)
            XCTAssertEqual(alpha.boolValue, hasAlpha, file: file, line: line)
        } else {
            XCTAssertFalse(hasAlpha, file: file, line: line)
        }

        if format == .jpeg {
            let jfif = try XCTUnwrap(property("{JFIF}", in: properties) as? NSDictionary, file: file, line: line)
            let jfifKeys = Set(jfif.allKeys.compactMap { $0 as? String })
            XCTAssertEqual(jfifKeys, ["DensityUnit", "JFIFVersion", "XDensity", "YDensity"], file: file, line: line)
            XCTAssertEqual((jfif["DensityUnit"] as? NSNumber)?.intValue, 0, file: file, line: line)
            XCTAssertEqual((jfif["XDensity"] as? NSNumber)?.intValue, 72, file: file, line: line)
            XCTAssertEqual((jfif["YDensity"] as? NSNumber)?.intValue, 72, file: file, line: line)
            let version = try XCTUnwrap(jfif["JFIFVersion"] as? NSArray, file: file, line: line)
            XCTAssertEqual(version.count, 3, file: file, line: line)
            XCTAssertEqual(version.compactMap { ($0 as? NSNumber)?.intValue }, [1, 0, 1], file: file, line: line)
        } else {
            let png = try XCTUnwrap(property("{PNG}", in: properties) as? NSDictionary, file: file, line: line)
            let pngKeys = Set(png.allKeys.compactMap { $0 as? String })
            XCTAssertEqual(pngKeys, ["InterlaceType", "sRGBIntent", "Gamma", "Chromaticities"], file: file, line: line)
            XCTAssertEqual((png["InterlaceType"] as? NSNumber)?.intValue, 0, file: file, line: line)
            XCTAssertEqual((png["sRGBIntent"] as? NSNumber)?.intValue, 0, file: file, line: line)
            let gamma = (png["Gamma"] as? String).flatMap(Double.init)
                ?? (png["Gamma"] as? NSNumber)?.doubleValue
            XCTAssertEqual(gamma ?? .nan, 0.45455, accuracy: 0.000001, file: file, line: line)
            let chromaticities = try XCTUnwrap(png["Chromaticities"] as? NSArray, file: file, line: line)
            let expected = [0.3127, 0.329, 0.64, 0.33, 0.3, 0.6, 0.15, 0.06]
            XCTAssertEqual(chromaticities.count, expected.count, file: file, line: line)
            for (index, value) in chromaticities.enumerated() {
                let number = (value as? String).flatMap(Double.init)
                    ?? (value as? NSNumber)?.doubleValue
                XCTAssertEqual(number ?? .nan, expected[index], accuracy: 0.000001, file: file, line: line)
            }

            let exif = try XCTUnwrap(property("{Exif}", in: properties) as? NSDictionary, file: file, line: line)
            let exifKeys = Set(exif.allKeys.compactMap { $0 as? String })
            XCTAssertEqual(exifKeys, ["ColorSpace", "PixelXDimension", "PixelYDimension"], file: file, line: line)
            XCTAssertEqual((exif["ColorSpace"] as? NSNumber)?.intValue, 1, file: file, line: line)
            XCTAssertEqual((exif["PixelXDimension"] as? NSNumber)?.intValue, width, file: file, line: line)
            XCTAssertEqual((exif["PixelYDimension"] as? NSNumber)?.intValue, height, file: file, line: line)
        }
    }

    func testNormalizesOrientationStripsMetadataAndBindsOutputHashAndBase64() throws {
        let sourceData = try makeImage(
            width: 2, height: 3, orientation: 6,
            includeSensitiveMetadata: true
        )
        let sourceProperties = try properties(for: sourceData)
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(sourceProperties[kCGImagePropertyExifDictionary])
        let sourceTIFF = try XCTUnwrap(sourceProperties[kCGImagePropertyTIFFDictionary] as? NSDictionary)
        XCTAssertNotNil(sourceTIFF[kCGImagePropertyTIFFArtist])
        XCTAssertNotNil(sourceTIFF[kCGImagePropertyTIFFDateTime])
        let input = try input("meal-angle-a", data: sourceData)
        let descriptor = try FoodPhotoSanitizer().sanitize([input]).first
        let output = try XCTUnwrap(descriptor)

        XCTAssertEqual(output.imageID, "meal-angle-a")
        XCTAssertEqual(output.mimeType, .jpeg)
        XCTAssertEqual(output.width, 3)
        XCTAssertEqual(output.height, 2)
        XCTAssertTrue(output.sanitized)

        let sanitizedData = try XCTUnwrap(Data(base64Encoded: output.inlineDataBase64))
        XCTAssertEqual(output.byteLength, sanitizedData.count)
        let expectedHash = SHA256.hash(data: sanitizedData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(output.sha256, expectedHash)
        let properties = try outputProperties(output)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyOrientation])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        try assertExactSanitizedMetadata(properties, format: .jpeg, width: 3, height: 2, hasAlpha: false)

        let outputBytes = Array(sanitizedData)
        XCTAssertEqual(Array(outputBytes.suffix(2)), [0xff, 0xd9])
        XCTAssertFalse(contains(outputBytes, sequence: Array("Exif\0\0".utf8)))
    }

    func testUsesPNGWhenAlphaRequiresTransparencyAndPreservesInputOrder() throws {
        let opaque = try input("opaque", data: makeImage(width: 4, height: 3, uti: "public.png"))
        let alpha = try input("transparent", data: makeImage(width: 3, height: 4, uti: "public.png", alpha: true))

        let descriptors = try FoodPhotoSanitizer().sanitize([opaque, alpha])
        XCTAssertEqual(descriptors.map(\.imageID), ["opaque", "transparent"])
        XCTAssertEqual(descriptors.map(\.mimeType), [.jpeg, .png])
        XCTAssertEqual(descriptors.map(\.width), [4, 3])
        XCTAssertEqual(descriptors.map(\.height), [3, 4])
        for descriptor in descriptors {
            let properties = try outputProperties(descriptor)
            try assertExactSanitizedMetadata(
                properties,
                format: descriptor.mimeType,
                width: descriptor.width,
                height: descriptor.height,
                hasAlpha: descriptor.mimeType == .png
            )
        }
    }

    func testEnforcesCountInputOutputPixelAndAtomicFailureBounds() throws {
        let small = try makeImage(width: 2, height: 2)
        let first = try input("one", data: small)
        let second = try input("two", data: small)
        let third = try input("three", data: small)
        XCTAssertEqual(try FoodPhotoSanitizer().sanitize([first, second, third]).count, 3)
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([first, second, third, first]))
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([
            first, try input("one", data: small)
        ]))

        XCTAssertThrowsError(try FoodPhotoSanitizerInput(
            imageID: "too-large", data: Data(repeating: 0, count: FoodPhotoSanitizer.maximumInputBytes + 1)
        ))
        XCTAssertThrowsError(try FoodPhotoSanitizerInput(imageID: "../path", data: small))
        XCTAssertThrowsError(try FoodPhotoSanitizer(options: try FoodPhotoSanitizerOptions(maximumOutputBytes: 1)).sanitize([first]))

        let exactInputSize = 10 * 1_024 * 1_024
        let paddedSmall = small + Data(repeating: 0, count: exactInputSize - small.count)
        XCTAssertEqual(paddedSmall.count, exactInputSize)
        let exactAggregate = try FoodPhotoSanitizer().sanitize([
            try input("aggregate-a", data: paddedSmall),
            try input("aggregate-b", data: paddedSmall),
        ])
        XCTAssertEqual(exactAggregate.count, 2)
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([
            try input("aggregate-a", data: paddedSmall + Data([0])),
            try input("aggregate-b", data: paddedSmall),
        ])) { error in
            XCTAssertEqual(error as? FoodPhotoSanitizationError, .inputTooLarge)
        }

        let tooManyPixels = try patchedPNG(width: 6_401, height: 6_251)
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([
            try input("pixel-bomb", data: tooManyPixels)
        ]))

        let corrupt = try input("corrupt", data: Data([0x01, 0x02, 0x03]))
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([first, corrupt]))
    }

    func testRejectsEmptyUnsupportedAndInvalidImagePayloads() throws {
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([]))
        XCTAssertThrowsError(try FoodPhotoSanitizerInput(imageID: "empty", data: Data()))
        let unsupported = try input("text", data: Data("not an image".utf8))
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([unsupported]))
        let invalidPNG = try input("invalid", data: Data(validPNG.dropLast()))
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([invalidPNG]))
    }

    func testPNGMetadataIsRemovedAndJPEGTrailingPayloadNeverSurvives() throws {
        let metadataPNG = try makeImage(
            width: 3, height: 2, uti: "public.png",
            includeSensitiveMetadata: true, alpha: true
        )
        let sourceProperties = try properties(for: metadataPNG)
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(sourceProperties[kCGImagePropertyExifDictionary])
        let descriptor = try XCTUnwrap(try FoodPhotoSanitizer().sanitize([
            try input("png-metadata", data: metadataPNG)
        ]).first)
        XCTAssertEqual(descriptor.mimeType, .png)
        let outputProperties = try outputProperties(descriptor)
        XCTAssertNil(outputProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(outputProperties[kCGImagePropertyTIFFDictionary])
        try assertExactSanitizedMetadata(outputProperties, format: .png, width: 3, height: 2, hasAlpha: true)

        let jpegWithTrailingBytes = try makeImage(width: 3, height: 2) + Data([0x99, 0x88, 0x77])
        let jpegDescriptor = try XCTUnwrap(try FoodPhotoSanitizer().sanitize([
            try input("jpeg-trailing", data: jpegWithTrailingBytes)
        ]).first)
        let outputBytes = try XCTUnwrap(Data(base64Encoded: jpegDescriptor.inlineDataBase64))
        XCTAssertEqual(Array(outputBytes.suffix(2)), [0xff, 0xd9])
        XCTAssertFalse(contains(Array(outputBytes), sequence: Array("Exif\0\0".utf8)))
    }

    func testRejectsAdversarialNonRGBStructuralOutput() throws {
        XCTAssertThrowsError(try FoodPhotoSanitizer().sanitize([
            try input("gray", data: validPNG)
        ])) { error in
            XCTAssertEqual(error as? FoodPhotoSanitizationError, .sensitiveMetadataPresent)
        }
    }

    /// Reuses the valid 1×1 PNG's payload but changes the IHDR dimensions and
    /// CRC.  The sanitizer must reject from properties before attempting to
    /// decode the advertised 40M+ pixels.
    private func patchedPNG(width: Int, height: Int) throws -> Data {
        var bytes = Array(validPNG)
        func writeUInt32(_ value: Int, at index: Int) {
            bytes[index] = UInt8((value >> 24) & 0xff)
            bytes[index + 1] = UInt8((value >> 16) & 0xff)
            bytes[index + 2] = UInt8((value >> 8) & 0xff)
            bytes[index + 3] = UInt8(value & 0xff)
        }
        writeUInt32(width, at: 16)
        writeUInt32(height, at: 20)
        let crc = crc32(Array(bytes[12..<29]))
        writeUInt32(Int(crc), at: 29)
        return Data(bytes)
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0)
            }
        }
        return crc ^ 0xffffffff
    }

    private func contains(_ bytes: [UInt8], sequence: [UInt8]) -> Bool {
        guard !sequence.isEmpty, bytes.count >= sequence.count else { return false }
        return bytes.indices.contains { index in
            guard index + sequence.count <= bytes.count else { return false }
            return Array(bytes[index..<(index + sequence.count)]) == sequence
        }
    }
}
