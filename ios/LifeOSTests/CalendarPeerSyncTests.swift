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

    func testEnvelopeRoundTripPreservesFractionalDates() throws {
        let createdAt = base.addingTimeInterval(0.25)
        let updatedAt = base.addingTimeInterval(0.75)
        let sentAt = base.addingTimeInterval(0.875)
        let item = try CalendarItem(
            title: "fractional edit",
            start: base.addingTimeInterval(0.125),
            end: base.addingTimeInterval(60.125),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let original = try CalendarPeerSyncEnvelope(
            snapshot: CalendarSnapshot(items: [item]),
            senderID: "iphone",
            revision: 8,
            sentAt: sentAt
        )

        let data = try original.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(".25Z"))
        XCTAssertTrue(text.contains(".875Z"))

        let decoded = try CalendarPeerSyncEnvelope.decode(data)
        let decodedItem = try XCTUnwrap(decoded.snapshot.items.first)
        XCTAssertEqual(decoded.sentAt.timeIntervalSince1970, sentAt.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(decodedItem.createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(decodedItem.updatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.000_001)
    }

    func testEnvelopeDecoderAcceptsLegacyWholeSecondVersionOne() throws {
        let item = try CalendarItem(
            title: "legacy",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        legacyEncoder.outputFormatting = [.sortedKeys]
        let snapshot = try JSONSerialization.jsonObject(
            with: legacyEncoder.encode(CalendarSnapshot(items: [item]))
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let legacyObject: [String: Any] = [
            "version": CalendarPeerSyncEnvelope.legacyVersion,
            "snapshot": snapshot,
            "senderID": "legacy-device",
            "revision": 4,
            "sentAt": formatter.string(from: base)
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])

        let decoded = try CalendarPeerSyncEnvelope.decode(data)
        XCTAssertEqual(decoded.version, CalendarPeerSyncEnvelope.legacyVersion)
        XCTAssertEqual(decoded.senderID, "legacy-device")
        XCTAssertEqual(decoded.snapshot.items.first?.title, "legacy")
        XCTAssertEqual(decoded.sentAt.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.000_001)
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

    func testVersionOneEncryptedFrameRetainsNumericFoundationDateCodec() throws {
        let peer = MCPeerID(displayName: "bob")
        let key = Data(repeating: 11, count: 32)
        var security = CalendarPeerSecurity(localSender: "alice")
        try security.pair(peer, sender: "bob", key: key)
        let packet = try security.begin(peer, now: base.addingTimeInterval(0.125))
        let plain = try AES.GCM.open(
            AES.GCM.SealedBox(combined: packet),
            using: SymmetricKey(data: key)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertTrue(object["sentAt"] is NSNumber)
    }

    func testEnvelopeRejectsInvalidMetadata() {
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(), senderID: " ", revision: 0))
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(), senderID: "mac", revision: -1))
        XCTAssertThrowsError(try CalendarPeerSyncEnvelope(
            snapshot: CalendarSnapshot(),
            senderID: String(repeating: "x", count: CalendarPeerSyncEnvelope.maximumSenderIDUTF8Bytes + 1),
            revision: 0
        ))
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

    func testCoordinatorEnvelopeAuthorizationRequiresAuthenticatedPinnedSender() throws {
        let envelope = try CalendarPeerSyncEnvelope(snapshot: CalendarSnapshot(), senderID: "remote", revision: 1, sentAt: base)
        XCTAssertTrue(CalendarPeerEnvelopeAuthorization.isAuthorized(
            envelope: envelope, authenticatedSenderID: "remote", localSenderID: "local"
        ))
        XCTAssertFalse(CalendarPeerEnvelopeAuthorization.isAuthorized(
            envelope: envelope, authenticatedSenderID: nil, localSenderID: "local"
        ))
        XCTAssertFalse(CalendarPeerEnvelopeAuthorization.isAuthorized(
            envelope: envelope, authenticatedSenderID: "attacker", localSenderID: "local"
        ))
        XCTAssertFalse(CalendarPeerEnvelopeAuthorization.isAuthorized(
            envelope: envelope, authenticatedSenderID: "local", localSenderID: "local"
        ))
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testUnpairedServiceCannotStartDiscovery() {
        let service = CalendarPeerSync(displayName: "local")
        var statuses: [CalendarPeerConnectionStatus] = []
        service.onStatusChanged = { statuses.append($0) }

        service.start()

        XCTAssertEqual(statuses, [.stopped])
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testRetiredDiscoveryFailureCannotResetStoppedOrCurrentRetry() throws {
        let service = CalendarPeerSync(displayName: "local")
        let peer = MCPeerID(displayName: "remote")
        try service.pair(peerID: peer, senderID: "remote", sharedKey: Data(repeating: 7, count: 32))
        var statuses: [CalendarPeerConnectionStatus] = []
        service.onStatusChanged = { statuses.append($0) }

        service.start()
        XCTAssertEqual(statuses.last, .started)
        let retiredObjects = service.discoveryObjectsForTesting()
        service.retryPairingConnection()
        service.advertiser(
            retiredObjects.0,
            didNotStartAdvertisingPeer: NSError(domain: "CalendarPeerSyncTests", code: 1)
        )
        service.browser(
            retiredObjects.1,
            didNotStartBrowsingForPeers: NSError(domain: "CalendarPeerSyncTests", code: 2)
        )
        XCTAssertEqual(statuses.last, .started)

        service.stop()
        XCTAssertEqual(statuses.last, .stopped)
        service.advertiser(
            retiredObjects.0,
            didNotStartAdvertisingPeer: NSError(domain: "CalendarPeerSyncTests", code: 3)
        )
        service.browser(
            retiredObjects.1,
            didNotStartBrowsingForPeers: NSError(domain: "CalendarPeerSyncTests", code: 4)
        )
        XCTAssertEqual(statuses.last, .stopped)
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testRetiredAdvertiserCannotAcceptInvitationAfterRetry() throws {
        let service = CalendarPeerSync(displayName: "local")
        let peer = MCPeerID(displayName: "remote")
        try service.pair(peerID: peer, senderID: "remote", sharedKey: Data(repeating: 7, count: 32))

        service.start()
        let retiredAdvertiser = service.discoveryObjectsForTesting().0
        service.retryPairingConnection()

        var accepted: Bool?
        service.advertiser(
            retiredAdvertiser,
            didReceiveInvitationFromPeer: peer,
            withContext: nil
        ) { allowed, _ in
            accepted = allowed
        }

        XCTAssertEqual(accepted, false)
    }

    func testPeerMutationFenceRejectsCapturedTokenAfterRevocation() throws {
        let fence = CalendarPeerMutationFence()
        fence.activate()
        let token = try XCTUnwrap(fence.capture())
        fence.invalidate()

        var committed = false
        XCTAssertThrowsError(try fence.withAuthorizedCommit(token) {
            committed = true
        }) { error in
            XCTAssertEqual(error as? CalendarPeerMutationFenceError, .revoked)
        }
        XCTAssertFalse(committed)
    }

    func testPeerMutationFenceReactivatesOnlyCurrentTransport() throws {
        let fence = CalendarPeerMutationFence()
        let firstTransport = fence.installTransport()
        fence.activate(firstTransport)
        let retiredToken = try XCTUnwrap(fence.capture(firstTransport))

        let currentTransport = fence.installTransport()
        fence.activate(firstTransport)
        XCTAssertNil(fence.capture(currentTransport))
        XCTAssertFalse(fence.isCurrent(retiredToken))

        fence.activate(currentTransport)
        let currentToken = try XCTUnwrap(fence.capture(currentTransport))
        XCTAssertTrue(fence.isCurrent(currentToken))

        fence.invalidate()
        fence.activate(currentTransport)
        XCTAssertNil(fence.capture(currentTransport), "An explicit stop must retire its transport token")
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testRevokingPeerStopsDiscoveryAndRejectsLaterInvitations() throws {
        let service = CalendarPeerSync(displayName: "local")
        let peer = MCPeerID(displayName: "remote")
        try service.pair(peerID: peer, senderID: "remote", sharedKey: Data(repeating: 7, count: 32))
        var statuses: [CalendarPeerConnectionStatus] = []
        service.onStatusChanged = { statuses.append($0) }

        service.start()
        XCTAssertEqual(statuses.last, .started)

        service.revoke(peerID: peer)
        XCTAssertEqual(statuses.last, .stopped)

        var acceptedInvitation: Bool?
        let advertiser = MCNearbyServiceAdvertiser(
            peer: service.localPeerID,
            discoveryInfo: nil,
            serviceType: CalendarPeerSync.serviceType
        )
        service.advertiser(
            advertiser,
            didReceiveInvitationFromPeer: peer,
            withContext: nil
        ) { accepted, _ in
            acceptedInvitation = accepted
        }
        XCTAssertEqual(acceptedInvitation, false)
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
    func testCurrentPeersNegotiateVersionTwoAndPreserveFractionalDates() throws {
        let (a, b) = try paired()
        let fractional = try CalendarItem(
            title: "fractional negotiated payload",
            start: now.addingTimeInterval(0.125),
            end: now.addingTimeInterval(60.125),
            createdAt: now.addingTimeInterval(0.25),
            updatedAt: now.addingTimeInterval(0.75)
        )
        let expected = try CalendarPeerSyncEnvelope(
            snapshot: CalendarSnapshot(items: [fractional]),
            senderID: "alice",
            revision: 9,
            sentAt: now.addingTimeInterval(0.875)
        )

        var sender = a
        var receiver = b
        let packet = try sender.send(expected, to: bob, now: now)
        let received = try XCTUnwrap(receiver.receive(packet, from: alice, now: now).snapshot)
        let receivedItem = try XCTUnwrap(received.snapshot.items.first)
        XCTAssertEqual(received.version, CalendarPeerSyncEnvelope.currentVersion)
        XCTAssertEqual(received.sentAt.timeIntervalSince1970, expected.sentAt.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(receivedItem.updatedAt.timeIntervalSince1970,
                       fractional.updatedAt.timeIntervalSince1970,
                       accuracy: 0.000_001)
    }
    private func rewrite(_ packet: Data, _ transform: (inout [String: Any]) -> Void) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: packet), using: symmetricKey)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        transform(&object)
        return try XCTUnwrap(AES.GCM.seal(JSONSerialization.data(withJSONObject: object), using: symmetricKey).combined)
    }
    private func payload(from packet: Data) throws -> Data {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: packet), using: SymmetricKey(data: key))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        let encoded = try XCTUnwrap(object["payload"] as? String)
        return try XCTUnwrap(Data(base64Encoded: encoded))
    }
    private func removeEnvelopeCapabilities(from packet: Data) throws -> Data {
        try rewrite(packet) { $0.removeValue(forKey: "supportedEnvelopeVersions") }
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
    func testLegacyPeerNegotiationSelectsVersionOneAndRoundTrips() throws {
        var a = CalendarPeerSecurity(localSender: "alice")
        var b = CalendarPeerSecurity(localSender: "bob")
        try a.pair(bob, sender: "bob", key: key)
        try b.pair(alice, sender: "alice", key: key)

        let helloA = try removeEnvelopeCapabilities(from: a.begin(bob, now: now))
        let helloB = try removeEnvelopeCapabilities(from: b.begin(alice, now: now))
        let ackB = try XCTUnwrap(b.receive(helloA, from: alice, now: now).reply)
        let ackA = try XCTUnwrap(a.receive(helloB, from: bob, now: now).reply)
        _ = try a.receive(try removeEnvelopeCapabilities(from: ackB), from: bob, now: now)
        _ = try b.receive(try removeEnvelopeCapabilities(from: ackA), from: alice, now: now)

        let fractional = try CalendarItem(
            title: "legacy fractional payload",
            start: now.addingTimeInterval(0.125),
            end: now.addingTimeInterval(60.125),
            createdAt: now.addingTimeInterval(0.25),
            updatedAt: now.addingTimeInterval(0.75)
        )
        let expected = try CalendarPeerSyncEnvelope(
            snapshot: CalendarSnapshot(items: [fractional]),
            senderID: "alice",
            revision: 7,
            sentAt: now
        )
        let packet = try a.send(expected, to: bob, now: now)
        let received = try XCTUnwrap(b.receive(packet, from: alice, now: now).snapshot)
        XCTAssertEqual(received.version, CalendarPeerSyncEnvelope.legacyVersion)
        XCTAssertEqual(received.snapshot.items.count, 1)
        let receivedItem = try XCTUnwrap(received.snapshot.items.first)
        XCTAssertEqual(receivedItem.title, fractional.title)
        XCTAssertEqual(receivedItem.updatedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.000_001)

        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .iso8601
        let legacyDecoded = try legacyDecoder.decode(
            CalendarPeerSyncEnvelope.self,
            from: payload(from: packet)
        )
        XCTAssertEqual(legacyDecoded.version, CalendarPeerSyncEnvelope.legacyVersion)
        XCTAssertEqual(legacyDecoded.snapshot.items.count, 1)
        let legacyItem = try XCTUnwrap(legacyDecoded.snapshot.items.first)
        XCTAssertEqual(
            legacyItem.updatedAt.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }
    func testMalformedEnvelopeCapabilitiesAreRejectedBeforePairingStateChanges() throws {
        var receiver = CalendarPeerSecurity(localSender: "bob")
        var mutableSender = CalendarPeerSecurity(localSender: "alice")
        try mutableSender.pair(bob, sender: "bob", key: key)
        try receiver.pair(alice, sender: "alice", key: key)
        let hello = try mutableSender.begin(bob, now: now)
        _ = try receiver.begin(alice, now: now)

        for advertised in [
            [],
            [99],
            [1, 2, 1],
            [1, 1]
        ] {
            let malformed = try rewrite(hello) { $0["supportedEnvelopeVersions"] = advertised }
            XCTAssertThrowsError(try receiver.receive(malformed, from: alice, now: now)) { error in
                XCTAssertEqual(error as? CalendarPeerSyncError, .rejectedMessage)
            }
            XCTAssertFalse(receiver.isAuthenticated(alice))
        }

        let wrongType = try rewrite(hello) { $0["supportedEnvelopeVersions"] = "v2" }
        XCTAssertThrowsError(try receiver.receive(wrongType, from: alice, now: now)) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .rejectedMessage)
        }
        XCTAssertFalse(receiver.isAuthenticated(alice))

        var ackSender = CalendarPeerSecurity(localSender: "alice")
        var ackReceiver = CalendarPeerSecurity(localSender: "bob")
        try ackSender.pair(bob, sender: "bob", key: key)
        try ackReceiver.pair(alice, sender: "alice", key: key)
        let ackHello = try ackSender.begin(bob, now: now)
        let receiverHello = try ackReceiver.begin(alice, now: now)
        let validAck = try XCTUnwrap(ackReceiver.receive(ackHello, from: alice, now: now).reply)
        for advertised in [
            [],
            [99],
            [1, 2, 1],
            [1, 1]
        ] {
            let malformedAck = try rewrite(validAck) { $0["supportedEnvelopeVersions"] = advertised }
            XCTAssertThrowsError(try ackSender.receive(malformedAck, from: bob, now: now)) { error in
                XCTAssertEqual(error as? CalendarPeerSyncError, .rejectedMessage)
            }
            XCTAssertFalse(ackSender.isAuthenticated(bob))
        }
        let wrongAckType = try rewrite(validAck) { $0["supportedEnvelopeVersions"] = "v2" }
        XCTAssertThrowsError(try ackSender.receive(wrongAckType, from: bob, now: now)) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .rejectedMessage)
        }
        XCTAssertFalse(ackSender.isAuthenticated(bob))
        _ = try ackSender.receive(validAck, from: bob, now: now)
        let senderAck = try XCTUnwrap(ackSender.receive(receiverHello, from: bob, now: now).reply)
        _ = try ackReceiver.receive(senderAck, from: alice, now: now)
        XCTAssertTrue(ackSender.isAuthenticated(bob))
        XCTAssertTrue(ackReceiver.isAuthenticated(alice))
    }
    func testCapabilitiesCannotBeRenegotiatedAfterAuthentication() throws {
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

        let replayedHello = try rewrite(helloA) { $0["supportedEnvelopeVersions"] = [1] }
        XCTAssertThrowsError(try b.receive(replayedHello, from: alice, now: now))
        XCTAssertTrue(b.isAuthenticated(alice))

        let replayedAck = try rewrite(ackB) { $0["supportedEnvelopeVersions"] = [1] }
        XCTAssertThrowsError(try a.receive(replayedAck, from: bob, now: now))
        XCTAssertTrue(a.isAuthenticated(bob))
    }
    func testProvisionalReplayCannotPoisonFreshHandshake() throws {
        var a = CalendarPeerSecurity(localSender: "alice")
        var b = CalendarPeerSecurity(localSender: "bob")
        try a.pair(bob, sender: "bob", key: key)
        try b.pair(alice, sender: "alice", key: key)

        let oldHelloA = try a.begin(bob, now: now)
        let oldHelloB = try b.begin(alice, now: now)
        let oldAckB = try XCTUnwrap(b.receive(oldHelloA, from: alice, now: now).reply)
        let oldAckA = try XCTUnwrap(a.receive(oldHelloB, from: bob, now: now).reply)
        _ = try a.receive(oldAckB, from: bob, now: now)
        _ = try b.receive(oldAckA, from: alice, now: now)

        let freshHelloA = try a.begin(bob, now: now)
        let freshHelloB = try b.begin(alice, now: now)
        let staleAck = try XCTUnwrap(b.receive(oldHelloA, from: alice, now: now).reply)
        XCTAssertThrowsError(try a.receive(staleAck, from: bob, now: now)) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .staleHandshake)
        }
        XCTAssertFalse(b.isAuthenticated(alice))

        let freshAckB = try XCTUnwrap(b.receive(freshHelloA, from: alice, now: now).reply)
        let freshAckA = try XCTUnwrap(a.receive(freshHelloB, from: bob, now: now).reply)
        _ = try a.receive(freshAckB, from: bob, now: now)
        _ = try b.receive(freshAckA, from: alice, now: now)

        XCTAssertTrue(a.isAuthenticated(bob))
        XCTAssertTrue(b.isAuthenticated(alice))

        XCTAssertThrowsError(try b.receive(oldHelloA, from: alice, now: now)) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .staleHandshake)
        }
        let currentEnvelope = try envelope()
        let currentPacket = try a.send(currentEnvelope, to: bob, now: now)
        XCTAssertEqual(try b.receive(currentPacket, from: alice, now: now).snapshot, currentEnvelope)
    }
    func testInvalidStaleAcknowledgementCapabilitiesAreRejectedBeforeStaleClassification() throws {
        var a = CalendarPeerSecurity(localSender: "alice")
        var b = CalendarPeerSecurity(localSender: "bob")
        try a.pair(bob, sender: "bob", key: key)
        try b.pair(alice, sender: "alice", key: key)

        let oldHelloA = try a.begin(bob, now: now)
        let oldHelloB = try b.begin(alice, now: now)
        let oldAckB = try XCTUnwrap(b.receive(oldHelloA, from: alice, now: now).reply)
        let oldAckA = try XCTUnwrap(a.receive(oldHelloB, from: bob, now: now).reply)
        _ = try a.receive(oldAckB, from: bob, now: now)
        _ = try b.receive(oldAckA, from: alice, now: now)

        _ = try a.begin(bob, now: now)
        let staleMalformedAck = try rewrite(oldAckB) { $0["supportedEnvelopeVersions"] = [99] }
        XCTAssertThrowsError(try a.receive(staleMalformedAck, from: bob, now: now)) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .rejectedMessage)
        }
        XCTAssertFalse(a.isAuthenticated(bob))
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testProductionPeerHandlerIgnoresStaleHelloAndContinuesAuthenticatedDelivery() throws {
        let localPeer = MCPeerID(displayName: "local-peer")
        let remotePeer = MCPeerID(displayName: "remote-peer")
        let sharedKey = Data(repeating: 42, count: 32)
        let service = CalendarPeerSync(displayName: "local", peerID: localPeer)
        try service.pair(peerID: remotePeer, senderID: "remote", sharedKey: sharedKey)

        var outbound: [(data: Data, peer: MCPeerID)] = []
        service.setPeerDataSenderForTesting { data, peer in
            outbound.append((data, peer))
        }
        service.start()
        defer { service.stop() }

        var remote = CalendarPeerSecurity(localSender: "remote")
        try remote.pair(localPeer, sender: "local", key: sharedKey)

        service.notifyPeerStateForTesting(.connected, peerID: remotePeer)
        let firstLocalHello = try XCTUnwrap(outbound.removeFirst().data)
        let firstRemoteHello = try remote.begin(localPeer)
        let firstRemoteAck = try XCTUnwrap(remote.receive(firstLocalHello, from: localPeer).reply)
        service.receivePeerDataForTesting(firstRemoteHello, from: remotePeer)
        let firstLocalAck = try XCTUnwrap(outbound.removeFirst().data)
        service.receivePeerDataForTesting(firstRemoteAck, from: remotePeer)
        _ = try remote.receive(firstLocalAck, from: localPeer)

        service.notifyPeerStateForTesting(.connected, peerID: remotePeer)
        let secondLocalHello = try XCTUnwrap(outbound.removeFirst().data)
        let secondRemoteHello = try remote.begin(localPeer)
        let secondRemoteAck = try XCTUnwrap(remote.receive(secondLocalHello, from: localPeer).reply)
        service.receivePeerDataForTesting(secondRemoteHello, from: remotePeer)
        let secondLocalAck = try XCTUnwrap(outbound.removeFirst().data)
        service.receivePeerDataForTesting(secondRemoteAck, from: remotePeer)
        _ = try remote.receive(secondLocalAck, from: localPeer)

        var received: [CalendarPeerSyncEnvelope] = []
        service.onSnapshotReceived = { envelope, _ in received.append(envelope) }
        service.receivePeerDataForTesting(firstRemoteHello, from: remotePeer)
        XCTAssertTrue(outbound.isEmpty, "A stale hello must not provoke a reply or a disconnect path")

        let envelope = try CalendarPeerSyncEnvelope(
            snapshot: CalendarSnapshot(),
            senderID: "remote",
            revision: 2,
            sentAt: .now
        )
        let packet = try remote.send(envelope, to: localPeer)
        service.receivePeerDataForTesting(packet, from: remotePeer)
        XCTAssertEqual(received, [envelope])
    }
    func testSnapshotCapabilityInjectionIsRejectedWithoutConsumingSequence() throws {
        var (a, b) = try paired()
        let packet = try a.send(envelope(), to: bob, now: now)
        let injected = try rewrite(packet) { $0["supportedEnvelopeVersions"] = [1, 2] }

        XCTAssertThrowsError(try b.receive(injected, from: alice, now: now)) { error in
            XCTAssertEqual(error as? CalendarPeerSyncError, .rejectedMessage)
        }
        XCTAssertTrue(b.isAuthenticated(alice))
        let expected = try envelope()
        XCTAssertEqual(try b.receive(packet, from: alice, now: now).snapshot, expected)
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
        XCTAssertEqual(messages[3], "Nearby connection authenticated by pairing.")
        XCTAssertFalse(messages[1].contains("connection authenticated"))
        XCTAssertFalse(messages[2].contains("connection authenticated"))
        XCTAssertFalse(messages[5].contains("internal error"))
    }
}
