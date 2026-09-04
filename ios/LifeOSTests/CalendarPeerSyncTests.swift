import XCTest
@testable import LifeOS

final class CalendarPeerSyncTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testEnvelopeRoundTripPreservesSnapshotAndMetadata() throws {
        let item = try CalendarItem(title: "focus", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let original = try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(items: [item]), senderID: "iphone", revision: 7, sentAt: base)
        let decoded = try CalendarPeerSyncEnvelope.decode(original.encoded())
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.version, CalendarPeerSyncEnvelope.currentVersion)
    }

    func testEnvelopeRejectsMalformedAndUnsupportedData() throws {
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope.decode(Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .invalidEnvelope)
        }
        let unsupported = Data("{\"version\":99,\"snapshot\":{\"schemaVersion\":1,\"items\":[]},\"senderID\":\"mac\",\"revision\":1,\"sentAt\":\"2023-11-14T22:13:20Z\"}".utf8)
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope.decode(unsupported)) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .unsupportedEnvelopeVersion(99))
        }
    }

    func testEnvelopeRejectsOversizedFramesBeforeDecoding() {
        let oversized = Data(repeating: 0, count: CalendarPeerSyncEnvelope.maximumEncodedBytes + 1)
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope.decode(oversized)) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .snapshotTooLarge)
        }
    }

    func testEnvelopeRejectsInvalidMetadata() {
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(), senderID: " ", revision: 0))
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(), senderID: "mac", revision: -1))
    }

    func testInvitationPolicyHasExactlyOneInitiator() {
        XCTAssertTrue(CalendarPeerSyncPolicy.shouldInvite(localID: "a", remoteID: "b"))
        XCTAssertFalse(CalendarPeerSyncPolicy.shouldInvite(localID: "b", remoteID: "a"))
        XCTAssertFalse(CalendarPeerSyncPolicy.shouldInvite(localID: "same", remoteID: "same"))
        XCTAssertFalse(CalendarPeerSyncPolicy.shouldInvite(localID: "", remoteID: "b"))
    }

    func testTransportUsesShortServiceType() {
        XCTAssertLessThanOrEqual(CalendarPeerSync.serviceType.utf8.count, 15)
    }
}
