import XCTest
import CryptoKit
import MultipeerConnectivity
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

final class CalendarPeerAuthenticationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let alice = MCPeerID(displayName: "alice")
    private let bob = MCPeerID(displayName: "bob")
    private let key = Data(repeating: 42, count: 32)

    private func paired() throws -> (CalendarPeerSecurity, CalendarPeerSecurity) {
        var a = CalendarPeerSecurity(localSender: "alice")
        var b = CalendarPeerSecurity(localSender: "bob")
        try a.pair(bob, sender: "bob", key: key)
        try b.pair(alice, sender: "alice", key: key)
        let helloA = try a.begin(bob, now: now)
        let helloB = try b.begin(alice, now: now)
        let ackB = try XCTUnwrap(b.receive(helloA, from: alice, now: now).reply)
        let ackA = try XCTUnwrap(a.receive(helloB, from: bob, now: now).reply)
        _ = try a.receive(ackB, from: bob, now: now)
        _ = try b.receive(ackA, from: alice, now: now)
        return (a, b)
    }
    private func envelope(at date: Date? = nil) throws -> CalendarPeerSyncEnvelope {
        try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(), senderID: "alice", revision: 7, sentAt: date ?? now)
    }
    private func rewrite(_ packet: Data, _ transform: (inout [String: Any]) -> Void) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: packet), using: symmetricKey)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        transform(&object)
        return try XCTUnwrap(AES.GCM.seal(JSONSerialization.data(withJSONObject: object), using: symmetricKey).combined)
    }
    func testMutualProofRequiredBeforeSnapshotAndRoundTrip() throws {
        var unproven = CalendarPeerSecurity(localSender: "alice")
        try unproven.pair(bob, sender: "bob", key: key)
        _ = try unproven.begin(bob, now: now)
        XCTAssertThrowsError(try unproven.send(envelope(), to: bob, now: now))
        var (a, b) = try paired()
        XCTAssertTrue(a.isAuthenticated(bob))
        XCTAssertTrue(b.isAuthenticated(alice))
        let expected = try envelope()
        let packet = try a.send(expected, to: bob, now: now)
        XCTAssertEqual(try b.receive(packet, from: alice, now: now).snapshot, expected)
        XCTAssertNil(String(data: packet, encoding: .utf8))
    }
    func testUnpairedThirdDeviceAndRevocationFailClosed() throws {
        var (a, b) = try paired()
        let packet = try a.send(envelope(), to: bob, now: now)
        let third = MCPeerID(displayName: "alice") // Identical label is not the pinned MCPeerID.
        XCTAssertFalse(b.isPaired(third))
        XCTAssertThrowsError(try b.receive(packet, from: third, now: now))
        b.revoke(alice)
        XCTAssertFalse(b.isAuthenticated(alice))
        XCTAssertThrowsError(try b.receive(packet, from: alice, now: now))
        XCTAssertThrowsError(try b.begin(alice, now: now))
    }
    func testReplayAndPreviousConnectionRejected() throws {
        var (a, b) = try paired()
        let packet = try a.send(envelope(), to: bob, now: now)
        _ = try b.receive(packet, from: alice, now: now)
        XCTAssertThrowsError(try b.receive(packet, from: alice, now: now))
        _ = try b.begin(alice, now: now)
        XCTAssertThrowsError(try b.receive(packet, from: alice, now: now))
        let restarted = CalendarPeerSecurity(localSender: "bob")
        XCTAssertFalse(restarted.isPaired(alice))
    }
    func testWrongKeyTamperingAndIdentitySubstitutionRejected() throws {
        var (a, b) = try paired()
        let packet = try a.send(envelope(), to: bob, now: now)
        var tampered = packet
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try b.receive(tampered, from: alice, now: now))
        let spoofed = try rewrite(packet) { $0["sender"] = "third" }
        XCTAssertThrowsError(try b.receive(spoofed, from: alice, now: now))
        let misdirected = try rewrite(packet) { $0["recipient"] = "third" }
        XCTAssertThrowsError(try b.receive(misdirected, from: alice, now: now))
        var wrong = CalendarPeerSecurity(localSender: "bob")
        try wrong.pair(alice, sender: "alice", key: Data(repeating: 9, count: 32))
        _ = try wrong.begin(alice, now: now)
        XCTAssertThrowsError(try wrong.receive(packet, from: alice, now: now))
        // Rejected packets must not consume the legitimate sequence.
        XCTAssertNotNil(try b.receive(packet, from: alice, now: now).snapshot)
    }
    func testStaleFutureDisallowedAndOversizedMessagesRejected() throws {
        var (a, b) = try paired()
        let packet = try a.send(envelope(), to: bob, now: now)
        XCTAssertThrowsError(try b.receive(packet, from: alice, now: now.addingTimeInterval(121)))
        XCTAssertThrowsError(try b.receive(packet, from: alice, now: now.addingTimeInterval(-31)))
        let disallowed = try rewrite(packet) { $0["kind"] = "delete_all" }
        XCTAssertThrowsError(try b.receive(disallowed, from: alice, now: now))
        let oversizedSequence = try rewrite(packet) { $0["sequence"] = CalendarPeerSecurity.maximumSequence + 1 }
        XCTAssertThrowsError(try b.receive(oversizedSequence, from: alice, now: now))
        let zeroSequence = try rewrite(packet) { $0["sequence"] = 0 }
        XCTAssertThrowsError(try b.receive(zeroSequence, from: alice, now: now))
        XCTAssertThrowsError(try b.receive(Data(repeating: 0, count: CalendarPeerSecurity.maximumFrameBytes + 1), from: alice, now: now))
        XCTAssertNotNil(try b.receive(packet, from: alice, now: now).snapshot)
        let stalePayload = try a.send(envelope(at: now.addingTimeInterval(-121)), to: bob, now: now)
        XCTAssertThrowsError(try b.receive(stalePayload, from: alice, now: now))
    }
    func testOversizedRevisionAndInvalidPairingRejected() throws {
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(), senderID: "alice", revision: Int.max))
        let encoded = try envelope().encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["revision"] = Int.max
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope.decode(JSONSerialization.data(withJSONObject: object)))
        var a = CalendarPeerSecurity(localSender: "alice")
        XCTAssertThrowsError(try a.pair(bob, sender: "bob", key: Data()))
        XCTAssertThrowsError(try a.pair(bob, sender: "alice", key: key))
        try a.pair(bob, sender: "bob", key: key)
        XCTAssertThrowsError(try a.pair(bob, sender: "bob", key: key))
    }
    func testCapturedAcknowledgementCannotAuthenticateNewConnection() throws {
        var a = CalendarPeerSecurity(localSender: "alice")
        var b = CalendarPeerSecurity(localSender: "bob")
        try a.pair(bob, sender: "bob", key: key)
        try b.pair(alice, sender: "alice", key: key)
        let hello = try a.begin(bob, now: now)
        _ = try b.begin(alice, now: now)
        let oldAck = try XCTUnwrap(b.receive(hello, from: alice, now: now).reply)
        _ = try a.begin(bob, now: now)
        XCTAssertThrowsError(try a.receive(oldAck, from: bob, now: now))
        XCTAssertFalse(a.isAuthenticated(bob))
    }
}

final class CalendarPairingHandoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let attempt = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let key = Data(repeating: 42, count: 32)
    private let alice = MCPeerID(displayName: "alice")
    private let bob = MCPeerID(displayName: "bob")

    private func handoffs() throws -> (CalendarPairingHandoff, CalendarPairingHandoff) {
        var a = CalendarPairingHandoff(localPeer: alice, localSender: "alice")
        var b = CalendarPairingHandoff(localPeer: bob, localSender: "bob")
        try a.create(now: now, secret: key, attempt: attempt)
        try b.importToken(XCTUnwrap(a.outgoing), now: now)
        try a.importToken(XCTUnwrap(b.outgoing), now: now)
        return (a, b)
    }
    private func rewrite(_ token: String, _ change: (inout [String: Any]) -> Void) throws -> String {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: token))) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object).base64EncodedString()
    }
    func testTwoExplicitConfirmationsThenAuthenticatedRoundTrip() throws {
        var a = CalendarPairingHandoff(localPeer: alice, localSender: "alice")
        var b = CalendarPairingHandoff(localPeer: bob, localSender: "bob")
        var aSecurity = CalendarPeerSecurity(localSender: "alice")
        var bSecurity = CalendarPeerSecurity(localSender: "bob")
        XCTAssertEqual(a.stage, .idle)
        try a.create(now: now, secret: key, attempt: attempt)
        XCTAssertEqual(a.stage, .awaitingResponse)
        XCTAssertThrowsError(try a.confirm(now: now) { _, _, _ in XCTFail("Cannot pin without response") })
        try b.importToken(XCTUnwrap(a.outgoing), now: now)
        XCTAssertEqual(b.stage, .awaitingConfirmation)
        XCTAssertFalse(bSecurity.isPaired(alice))
        let response = try XCTUnwrap(b.outgoing)
        try b.confirm(now: now) { try bSecurity.pair($0, sender: $1, key: $2) }
        XCTAssertEqual(b.stage, .confirmed)
        XCTAssertNil(b.outgoing)
        XCTAssertFalse(bSecurity.isAuthenticated(alice))
        try a.importToken(response, now: now)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        try a.confirm(now: now) { try aSecurity.pair($0, sender: $1, key: $2) }
        XCTAssertEqual(a.stage, .confirmed)
        XCTAssertNil(a.outgoing)
        let helloA = try aSecurity.begin(bob, now: now)
        let helloB = try bSecurity.begin(alice, now: now)
        let ackB = try XCTUnwrap(bSecurity.receive(helloA, from: alice, now: now).reply)
        let ackA = try XCTUnwrap(aSecurity.receive(helloB, from: bob, now: now).reply)
        _ = try aSecurity.receive(ackB, from: bob, now: now)
        _ = try bSecurity.receive(ackA, from: alice, now: now)
        XCTAssertTrue(aSecurity.isAuthenticated(bob))
        XCTAssertTrue(bSecurity.isAuthenticated(alice))
        let envelope = try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(), senderID: "alice", revision: 1, sentAt: now)
        XCTAssertEqual(try bSecurity.receive(aSecurity.send(envelope, to: bob, now: now), from: alice, now: now).snapshot, envelope)
    }
    func testMalformedWrongLengthVersionIdentityAndExpiredTokensLeaveStateUnchanged() throws {
        var a = CalendarPairingHandoff(localPeer: alice, localSender: "alice")
        var b = CalendarPairingHandoff(localPeer: bob, localSender: "bob")
        XCTAssertThrowsError(try a.create(now: now, secret: Data(repeating: 1, count: 31), attempt: attempt))
        try a.create(now: now, secret: key, attempt: attempt)
        let offer = try XCTUnwrap(a.outgoing)
        for bad in ["invalid", String(repeating: "a", count: CalendarPairingHandoff.maximumTokenBytes + 1),
                    try rewrite(offer) { $0["version"] = 2 },
                    try rewrite(offer) { $0["secret"] = Data(repeating: 1, count: 31).base64EncodedString() },
                    try rewrite(offer) { $0["sender"] = "bob" },
                    try rewrite(offer) { $0["sender"] = " " },
                    try rewrite(offer) { $0["peer"] = Data("bad archive".utf8).base64EncodedString() }] {
            XCTAssertThrowsError(try b.importToken(bad, now: now))
            XCTAssertEqual(b.stage, .idle)
            XCTAssertNil(b.outgoing)
        }
        XCTAssertThrowsError(try b.importToken(offer, now: now.addingTimeInterval(300)))
        try b.importToken(offer, now: now)
        XCTAssertThrowsError(try b.confirm(now: now.addingTimeInterval(300)) { _, _, _ in XCTFail("Expired pin") })
    }
    func testMismatchedSecretAndAttemptRejectResponseWithoutLosingOffer() throws {
        var a = CalendarPairingHandoff(localPeer: alice, localSender: "alice")
        var b = CalendarPairingHandoff(localPeer: bob, localSender: "bob")
        try a.create(now: now, secret: key, attempt: attempt)
        try b.importToken(XCTUnwrap(a.outgoing), now: now)
        let response = try XCTUnwrap(b.outgoing)
        let wrongKey = try rewrite(response) { $0["secret"] = Data(repeating: 9, count: 32).base64EncodedString() }
        let wrongAttempt = try rewrite(response) { $0["attempt"] = "22222222-2222-4222-8222-222222222222" }
        XCTAssertThrowsError(try a.importToken(wrongKey, now: now))
        XCTAssertThrowsError(try a.importToken(wrongAttempt, now: now))
        XCTAssertEqual(a.stage, .awaitingResponse)
        try a.importToken(response, now: now)
        XCTAssertEqual(a.stage, .awaitingConfirmation)
    }
    func testCancellationRestartDuplicateAndRevokeRequireFreshHandoff() throws {
        var (a, b) = try handoffs()
        let response = try XCTUnwrap(b.outgoing)
        XCTAssertThrowsError(try a.importToken(response, now: now))
        a.clear()
        XCTAssertEqual(a.stage, .cancelled)
        XCTAssertNil(a.outgoing)
        XCTAssertNil(a.fingerprint)
        XCTAssertThrowsError(try a.importToken(response, now: now))
        XCTAssertThrowsError(try a.create(now: now, secret: key, attempt: attempt))
        var restarted = CalendarPairingHandoff(localPeer: MCPeerID(displayName: "alice"), localSender: "alice")
        XCTAssertEqual(restarted.stage, .idle)
        XCTAssertThrowsError(try restarted.importToken(response, now: now))
        var security = CalendarPeerSecurity(localSender: "bob")
        try b.confirm(now: now) { try security.pair($0, sender: $1, key: $2) }
        XCTAssertThrowsError(try b.confirm(now: now) { _, _, _ in XCTFail("Duplicate pin") })
        security.revoke(alice)
        b.clear(revoked: true)
        XCTAssertEqual(b.stage, .revoked)
        XCTAssertFalse(security.isPaired(alice))
        XCTAssertThrowsError(try security.begin(alice, now: now))
        let newAttempt = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        try a.create(now: now, secret: Data(repeating: 7, count: 32), attempt: newAttempt)
        try b.importToken(XCTUnwrap(a.outgoing), now: now)
        XCTAssertEqual(b.stage, .awaitingConfirmation)
    }
    func testDuplicateSenderOrPeerPinDoesNotConsumeConfirmation() throws {
        var (a, _) = try handoffs()
        var security = CalendarPeerSecurity(localSender: "alice")
        try security.pair(bob, sender: "bob", key: key)
        XCTAssertThrowsError(try a.confirm(now: now) { try security.pair($0, sender: $1, key: $2) })
        XCTAssertEqual(a.stage, .awaitingConfirmation)
        XCTAssertThrowsError(try security.pair(MCPeerID(displayName: "bob-copy"), sender: "bob", key: key))
    }
}

final class CalendarPairingStatusTests: XCTestCase {
    func testDiscoveryAndConnectionStatusesNeverImplyPrematureAuthentication() {
        XCTAssertEqual(CalendarPairingState().message, "Nearby sync unavailable. Pair both devices first.")
        let states: [CalendarPeerConnectionStatus] = [.stopped, .started, .connecting("peer"),
            .connected("peer"), .disconnected("peer"), .failed("internal error")]
        let messages = states.map(CalendarPairingState.connectionMessage)
        XCTAssertEqual(Set(messages).count, states.count)
        XCTAssertEqual(messages[3], "Nearby connection authenticated.")
        XCTAssertFalse(messages[1].contains("connection authenticated"))
        XCTAssertFalse(messages[2].contains("connection authenticated"))
        XCTAssertFalse(messages[5].contains("internal error"))
    }
}
