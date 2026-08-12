import XCTest
import ImageIO
@testable import LifeOS

final class CalendarIconAssetTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private let validPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    func testAcceptsBoundedDecodableImage() throws {
        let png = try CalendarIconAsset(format: .png, bytes: validPNG)
        XCTAssertEqual(png.bytes, validPNG)
        XCTAssertEqual(png.schemaVersion, 1)
        XCTAssertEqual(png.contentHash.count, 64)
        XCTAssertEqual(try CalendarIconAsset(format: .png, bytes: validPNG).contentHash, png.contentHash)
    }

    func testRejectsHeaderOnlyOrCorruptImages() {
        XCTAssertThrowsError(try CalendarIconAsset(format: .png, bytes: pngHeader))
        XCTAssertThrowsError(try CalendarIconAsset(format: .jpeg, bytes: Data([0xFF, 0xD8, 0xFF, 0xD9])))
    }

    func testRejectsMismatchedEmptyAndOversizedPayloads() {
        XCTAssertThrowsError(try CalendarIconAsset(format: .jpeg, bytes: validPNG))
        XCTAssertThrowsError(try CalendarIconAsset(format: .png, bytes: Data()))
        let oversized = validPNG + Data(repeating: 0, count: CalendarIconAsset.maxBytes)
        XCTAssertThrowsError(try CalendarIconAsset(format: .png, bytes: oversized))
    }

    func testDecoderRevalidatesBoundAndSignature() throws {
        let invalidSignature = Data("{\"format\":\"png\",\"bytes\":\"AA==\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CalendarIconAsset.self, from: invalidSignature))

        let oversized = validPNG + Data(repeating: 0, count: CalendarIconAsset.maxBytes)
        let wire = Data("{\"format\":\"png\",\"bytes\":\"\(oversized.base64EncodedString())\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CalendarIconAsset.self, from: wire))
    }

    func testIconPersistsAndRoundTripsInDeterministicPeerEnvelope() throws {
        let asset = try CalendarIconAsset(format: .png, bytes: validPNG)
        let item = try CalendarItem(title: "Focus", icon: "🎯", iconAsset: asset,
                                    start: base, end: base.addingTimeInterval(3600),
                                    createdAt: base, updatedAt: base)
        let envelope = try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(items: [item]),
                                                    senderID: "iphone", revision: 2, sentAt: base)
        let first = try envelope.encoded()
        let second = try envelope.encoded()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try CalendarPeerSyncEnvelope.decode(first), envelope)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("file://"))
    }

    func testInvalidEmojiWithoutAssetRemainsNoIcon() throws {
        let item = try CalendarItem(title: "Fallback", icon: "not-an-emoji",
                                    start: base, end: base.addingTimeInterval(60))
        XCTAssertNil(item.icon)
        XCTAssertNil(item.iconAsset)
    }

    func testReusableIconLibraryPersistsSanitizedAssetAndSupportsDeterministicReuse() throws {
        let suiteName = "LifeOS.CalendarIconAssetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let asset = try CalendarIconAssetSanitizer.sanitize(validPNG)
        let reusable = try CalendarReusableIcon(name: "Fixture mark", asset: asset)
        XCTAssertEqual(CalendarIconLibrary.upsert(reusable, defaults: defaults), [reusable])
        XCTAssertEqual(CalendarIconLibrary.load(defaults: defaults), [reusable])

        // A second save of the same content reuses the deterministic hash and
        // does not create a duplicate row; this is the relaunch/persistence
        // contract used by the picker.
        XCTAssertEqual(CalendarIconLibrary.upsert(reusable, defaults: defaults), [reusable])
        XCTAssertEqual(CalendarIconLibrary.load(defaults: defaults).first?.id, reusable.id)
    }

    func testCuratedEmojiCatalogRemainsExactly678Entries() {
        XCTAssertEqual(CalendarEmojiCatalog.curatedCount, 678)
    }

    func testSanitizerRendersPixelsAndStripsSensitiveMetadata() throws {
        XCTAssertNoThrow(try CalendarIconAssetSanitizer.sanitize(validPNG))
        guard let source = CGImageSourceCreateWithData(validPNG as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("Fixture image should decode")
            return
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            XCTFail("Could not create fixture encoder")
            return
        }
        let privateProperties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.5, kCGImagePropertyGPSLongitude: 13.4] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private fixture"] as [CFString: Any]
        ]
        CGImageDestinationAddImage(destination, image, privateProperties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let asset = try CalendarIconAssetSanitizer.sanitize(output as Data)
        XCTAssertEqual(asset.format, .png)
        XCTAssertLessThanOrEqual(asset.bytes.count, CalendarIconAsset.maxBytes)
        guard let sanitizedSource = CGImageSourceCreateWithData(asset.bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(sanitizedSource, 0, nil) as? [CFString: Any] else {
            XCTFail("Sanitized image should decode")
            return
        }
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        if let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary {
            let keys = Set(exif.allKeys.compactMap { $0 as? String })
            XCTAssertTrue(keys.isSubset(of: Set(["ColorSpace", "PixelXDimension", "PixelYDimension"])))
            XCTAssertTrue(keys.contains("PixelXDimension"))
            XCTAssertTrue(keys.contains("PixelYDimension"))
            if exif["ColorSpace"] != nil {
                XCTAssertEqual((exif["ColorSpace"] as? NSNumber)?.intValue, 1)
            }
            XCTAssertEqual((exif["PixelXDimension"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((exif["PixelYDimension"] as? NSNumber)?.intValue, 1)
        }
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }
}
