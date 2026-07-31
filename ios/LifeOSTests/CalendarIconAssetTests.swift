import XCTest
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

    func testEmojiFallbackRemainsWhenNoAssetExists() throws {
        let item = try CalendarItem(title: "Fallback", icon: "not-an-emoji",
                                    start: base, end: base.addingTimeInterval(60))
        XCTAssertEqual(item.icon, "📅")
        XCTAssertNil(item.iconAsset)
    }
}
