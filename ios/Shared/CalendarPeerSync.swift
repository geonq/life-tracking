import Foundation
import MultipeerConnectivity
import CryptoKit

public enum CalendarPeerSyncError: Error, Equatable, Sendable {
    case unsupportedEnvelopeVersion(Int)
    case invalidSenderID
    case invalidRevision
    case invalidEnvelope
    case snapshotTooLarge
    case unauthorizedPeer
    case invalidPairing
    case rejectedMessage
}

/// The wire format is deliberately versioned so peers can reject newer formats safely.
public struct CalendarPeerSyncEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumRevision = Int(Int32.max)
    /// Keep the peer frame bounded while leaving room for envelope metadata on
    /// top of the remote calendar resource's 256 KiB body limit.
    public static let maximumEncodedBytes = 288 * 1_024

    public let version: Int
    public let snapshot: CalendarSnapshot
    public let senderID: String
    public let revision: Int
    public let sentAt: Date

    public init(snapshot: CalendarSnapshot, senderID: String, revision: Int, sentAt: Date = .now) throws {
        guard !senderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarPeerSyncError.invalidSenderID }
        guard (0...Self.maximumRevision).contains(revision) else { throw CalendarPeerSyncError.invalidRevision }
        self.version = Self.currentVersion
        self.snapshot = snapshot
        self.senderID = senderID
        self.revision = revision
        self.sentAt = sentAt
    }

    public func encoded() throws -> Data {
        guard snapshot.schemaVersion == CalendarSnapshot.currentSchemaVersion,
              snapshot.items.count <= CalendarSnapshot.maximumItemCount else {
            throw CalendarPeerSyncError.snapshotTooLarge
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let snapshotData = try encoder.encode(snapshot)
        guard snapshotData.count <= CalendarSnapshot.maximumEncodedBytes else {
            throw CalendarPeerSyncError.snapshotTooLarge
        }
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw CalendarPeerSyncError.snapshotTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> CalendarPeerSyncEnvelope {
        guard data.count <= Self.maximumEncodedBytes else {
            throw CalendarPeerSyncError.snapshotTooLarge
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(Self.self, from: data)
            guard envelope.version == currentVersion else { throw CalendarPeerSyncError.unsupportedEnvelopeVersion(envelope.version) }
            guard !envelope.senderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarPeerSyncError.invalidSenderID }
            guard (0...Self.maximumRevision).contains(envelope.revision) else { throw CalendarPeerSyncError.invalidRevision }
            try envelope.snapshot.validatedForPersistence()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(envelope.snapshot).count <= CalendarSnapshot.maximumEncodedBytes else {
                throw CalendarPeerSyncError.snapshotTooLarge
            }
            return envelope
        } catch let error as CalendarPeerSyncError {
            throw error
        } catch let error as CalendarSnapshotError {
            switch error {
            case .tooManyItems, .payloadTooLarge:
                throw CalendarPeerSyncError.snapshotTooLarge
            case .unsupportedSchemaVersion:
                throw CalendarPeerSyncError.invalidEnvelope
            }
        } catch {
            throw CalendarPeerSyncError.invalidEnvelope
        }
    }
}

public enum CalendarPeerConnectionStatus: Sendable, Equatable {
    case started
    case connecting(String)
    case connected(String)
    case disconnected(String)
    case stopped
    case failed(String)
}

public enum CalendarPeerSyncPolicy {
    /// Exactly one side invites: the lexicographically smaller stable peer ID does.
    public static func shouldInvite(localID: String, remoteID: String) -> Bool {
        guard !localID.isEmpty, !remoteID.isEmpty, localID != remoteID else { return false }
        return localID < remoteID
    }
}

/// Nearby discovery is an explicit, durable opt-in. Pairing still requires
/// the existing private handoff and pinned peer authentication after discovery.
public enum CalendarNearbyDiscoveryPolicy {
    public static let defaultsKey = "LifeOS.Calendar.NearbyDiscoveryEnabled.v1"
    public static let didChangeNotification = Notification.Name(
        "LifeOS.Calendar.NearbyDiscoveryPolicy.didChange"
    )

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func allowsDiscovery(usesVisualFixtures: Bool, settingEnabled: Bool) -> Bool {
        !usesVisualFixtures && settingEnabled
    }
}

/// Memory-only trust: the caller must transfer a fresh random 32-byte key through
/// an authenticated out-of-band channel and explicitly pin both peer and sender ID.
/// Nothing learned through discovery is trusted. Restart requires pairing again.
/// The transport serializes all access, including delivery and revocation.
struct CalendarPeerSecurity {
    static let maximumFrameBytes = 544 * 1_024
    static let maximumSequence: UInt64 = 9_007_199_254_740_991
    struct Frame: Codable {
        let version: Int
        let kind: String
        let sender: String
        let recipient: String
        let challenge: String
        let response: String?
        let sequence: UInt64
        let sentAt: Date
        let payload: Data?
    }
    private struct Pin {
        let sender: String
        let key: SymmetricKey
        var challenge: String?
        var remoteChallenge: String?
        var sent: UInt64 = 0
        var received: UInt64 = 0
    }
    let localSender: String
    private var pins: [MCPeerID: Pin] = [:]

    init(localSender: String) { self.localSender = localSender }

    mutating func pair(_ peer: MCPeerID, sender: String, key: Data) throws {
        guard !localSender.isEmpty, localSender.utf8.count <= 128,
              !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sender.utf8.count <= 128, sender != localSender, key.count == 32,
              pins[peer] == nil,
              !pins.values.contains(where: { $0.sender == sender }) else {
            throw CalendarPeerSyncError.invalidPairing
        }
        pins[peer] = Pin(sender: sender, key: SymmetricKey(data: key))
    }
    func isPaired(_ peer: MCPeerID) -> Bool { pins[peer] != nil }
    func sender(for peer: MCPeerID) -> String? { pins[peer]?.sender }
    func isAuthenticated(_ peer: MCPeerID) -> Bool { pins[peer]?.remoteChallenge != nil }
    mutating func revoke(_ peer: MCPeerID) { pins.removeValue(forKey: peer) }
    mutating func disconnect(_ peer: MCPeerID) {
        pins[peer]?.challenge = nil
        pins[peer]?.remoteChallenge = nil
        pins[peer]?.sent = 0
        pins[peer]?.received = 0
    }
    mutating func disconnectAll() {
        for peer in Array(pins.keys) { disconnect(peer) }
    }
    mutating func begin(_ peer: MCPeerID, now: Date = .now) throws -> Data {
        guard var pin = pins[peer] else { throw CalendarPeerSyncError.unauthorizedPeer }
        pin.challenge = UUID().uuidString
        pin.remoteChallenge = nil
        pin.sent = 0
        pin.received = 0
        pins[peer] = pin
        return try seal(frame("hello", pin: pin, now: now), key: pin.key)
    }
    private func frame(_ kind: String, pin: Pin, response: String? = nil,
                       sequence: UInt64 = 0, payload: Data? = nil, now: Date) -> Frame {
        Frame(version: 1, kind: kind, sender: localSender, recipient: pin.sender,
              challenge: pin.challenge ?? "", response: response, sequence: sequence,
              sentAt: now, payload: payload)
    }
    private func seal(_ frame: Frame, key: SymmetricKey) throws -> Data {
        let data = try JSONEncoder().encode(frame)
        guard let sealed = try AES.GCM.seal(data, using: key).combined,
              sealed.count <= Self.maximumFrameBytes else { throw CalendarPeerSyncError.snapshotTooLarge }
        return sealed
    }
    mutating func send(_ envelope: CalendarPeerSyncEnvelope, to peer: MCPeerID, now: Date = .now) throws -> Data {
        guard var pin = pins[peer], let remote = pin.remoteChallenge,
              pin.challenge != nil else { throw CalendarPeerSyncError.unauthorizedPeer }
        guard envelope.senderID == localSender, pin.sent < Self.maximumSequence else {
            throw CalendarPeerSyncError.rejectedMessage
        }
        let payload = try envelope.encoded()
        pin.sent += 1
        let data = try seal(frame("snapshot", pin: pin, response: remote,
                                  sequence: pin.sent, payload: payload, now: now), key: pin.key)
        pins[peer] = pin
        return data
    }
    mutating func receive(_ data: Data, from peer: MCPeerID, now: Date = .now) throws
        -> (reply: Data?, snapshot: CalendarPeerSyncEnvelope?) {
        guard var pin = pins[peer], let challenge = pin.challenge else {
            throw CalendarPeerSyncError.unauthorizedPeer
        }
        guard data.count <= Self.maximumFrameBytes else { throw CalendarPeerSyncError.snapshotTooLarge }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: pin.key)
        let message = try JSONDecoder().decode(Frame.self, from: plain)
        guard message.version == 1, message.sender == pin.sender, message.recipient == localSender,
              UUID(uuidString: message.challenge) != nil,
              message.sentAt.timeIntervalSince(now).isFinite,
              (-120...30).contains(message.sentAt.timeIntervalSince(now)) else {
            throw CalendarPeerSyncError.rejectedMessage
        }
        switch message.kind {
        case "hello":
            guard message.sequence == 0, message.payload == nil, message.response == nil else {
                throw CalendarPeerSyncError.rejectedMessage
            }
            return (try seal(frame("ack", pin: pin, response: message.challenge, now: now), key: pin.key), nil)
        case "ack":
            guard message.sequence == 0, message.payload == nil, message.response == challenge,
                  pin.remoteChallenge == nil || pin.remoteChallenge == message.challenge else {
                throw CalendarPeerSyncError.rejectedMessage
            }
            pin.remoteChallenge = message.challenge
            pins[peer] = pin
            return (nil, nil)
        case "snapshot":
            guard message.response == challenge, message.challenge == pin.remoteChallenge,
                  message.sequence > pin.received, message.sequence <= Self.maximumSequence,
                  let payload = message.payload else { throw CalendarPeerSyncError.rejectedMessage }
            let envelope = try CalendarPeerSyncEnvelope.decode(payload)
            guard envelope.senderID == pin.sender,
                  (-120...30).contains(envelope.sentAt.timeIntervalSince(now)) else {
                throw CalendarPeerSyncError.rejectedMessage
            }
            pin.received = message.sequence
            pins[peer] = pin
            return (nil, envelope)
        default: throw CalendarPeerSyncError.rejectedMessage
        }
    }
}

/// Out-of-band handoff only. Tokens contain a secret; never log or persist them.
/// Peer archives are decoded with a single allowed secure-coding class, never
/// sourced from Bonjour metadata. One active pairing keeps revoke unambiguous.
struct CalendarPairingHandoff {
    enum Stage: String, Equatable {
        case idle, awaitingResponse, awaitingConfirmation, confirmed, cancelled, revoked
    }
    struct Token: Codable {
        let version: Int
        let attempt: UUID
        let expires: Date
        let response: Bool
        let sender: String
        let peer: Data
        let secret: Data
    }
    static let maximumTokenBytes = 8_192
    private(set) var stage: Stage = .idle
    private(set) var outgoing: String?
    private(set) var remoteSender: String?
    private(set) var fingerprint: String?
    private var offer: Token?
    private var remote: Token?
    private var consumed: Set<UUID> = []
    let localPeer: MCPeerID
    let localSender: String

    init(localPeer: MCPeerID, localSender: String) {
        self.localPeer = localPeer
        self.localSender = localSender
    }

    private func token(secret: Data, attempt: UUID, expires: Date, response: Bool) throws -> Token {
        Token(version: 1, attempt: attempt, expires: expires, response: response,
              sender: localSender,
              peer: try NSKeyedArchiver.archivedData(withRootObject: localPeer, requiringSecureCoding: true),
              secret: secret)
    }
    private func encode(_ token: Token) throws -> String {
        let result = try JSONEncoder().encode(token).base64EncodedString()
        guard result.utf8.count <= Self.maximumTokenBytes else { throw CalendarPeerSyncError.invalidPairing }
        return result
    }
    private func peer(_ token: Token) throws -> MCPeerID {
        guard let peer = try NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: token.peer),
              peer != localPeer else { throw CalendarPeerSyncError.invalidPairing }
        return peer
    }
    private func validate(_ token: Token, now: Date) throws {
        guard token.version == 1, token.secret.count == 32, token.peer.count <= 4_096,
              token.sender == token.sender.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.sender.isEmpty, token.sender.utf8.count <= 128, token.sender != localSender,
              token.expires > now, token.expires.timeIntervalSince(now) <= 300,
              !consumed.contains(token.attempt) else { throw CalendarPeerSyncError.invalidPairing }
        _ = try peer(token)
    }
    mutating func create(now: Date = .now, secret: Data? = nil, attempt: UUID = UUID()) throws {
        guard stage != .confirmed, stage != .awaitingConfirmation, stage != .awaitingResponse,
              consumed.count < 1_024, !consumed.contains(attempt) else { throw CalendarPeerSyncError.invalidPairing }
        let key = secret ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard key.count == 32 else { throw CalendarPeerSyncError.invalidPairing }
        let value = try token(secret: key, attempt: attempt, expires: now.addingTimeInterval(300), response: false)
        outgoing = try encode(value)
        offer = value
        stage = .awaitingResponse
        fingerprint = SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    mutating func importToken(_ text: String, now: Date = .now) throws {
        guard stage != .confirmed, stage != .awaitingConfirmation, consumed.count < 1_024,
              text.utf8.count <= Self.maximumTokenBytes,
              let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CalendarPeerSyncError.invalidPairing
        }
        let value = try JSONDecoder().decode(Token.self, from: data)
        try validate(value, now: now)
        if let offer {
            guard stage == .awaitingResponse, value.response,
                  value.attempt == offer.attempt, value.expires == offer.expires,
                  value.secret == offer.secret else { throw CalendarPeerSyncError.invalidPairing }
            outgoing = nil
        } else {
            guard !value.response else { throw CalendarPeerSyncError.invalidPairing }
            outgoing = try encode(token(secret: value.secret, attempt: value.attempt,
                                        expires: value.expires, response: true))
        }
        remote = value
        remoteSender = value.sender
        fingerprint = SHA256.hash(data: value.secret).prefix(8).map { String(format: "%02x", $0) }.joined()
        stage = .awaitingConfirmation
    }
    mutating func confirm(now: Date = .now, pin: (MCPeerID, String, Data) throws -> Void) throws {
        guard stage == .awaitingConfirmation, let remote else { throw CalendarPeerSyncError.invalidPairing }
        try validate(remote, now: now)
        try pin(peer(remote), remote.sender, remote.secret)
        consumed.insert(remote.attempt)
        self.remote = nil
        offer = nil
        outgoing = nil
        stage = .confirmed
    }
    mutating func clear(revoked: Bool = false) {
        if let offer { consumed.insert(offer.attempt) }
        if let remote { consumed.insert(remote.attempt) }
        offer = nil
        remote = nil
        outgoing = nil
        remoteSender = nil
        fingerprint = nil
        stage = revoked ? .revoked : .cancelled
    }
}

public struct CalendarPairingState: Equatable, Sendable {
    public var stage: String = "idle"
    public var outgoing: String?
    public var remoteSender: String?
    public var fingerprint: String?
    public var message = "Nearby sync unavailable. Pair both devices first."
    public var available = true

    public static func connectionMessage(_ status: CalendarPeerConnectionStatus) -> String {
        switch status {
        case .started: return "Searching nearby; discovery alone does not enable sync."
        case .connecting: return "Connecting; authentication pending."
        case .connected: return "Nearby connection authenticated."
        case .disconnected: return "Nearby connection lost. Use Connect / retry."
        case .stopped: return "No active nearby connection."
        case .failed: return "Nearby sync failed. Check local network permission and pairing on both devices, then retry."
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
public final class CalendarPeerSync: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    public static let serviceType = "lifeos-calendar"
    public let localPeerID: MCPeerID
    public var onSnapshotReceived: ((CalendarPeerSyncEnvelope, MCPeerID) -> Void)?
    public var onStatusChanged: ((CalendarPeerConnectionStatus) -> Void)?
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let lock = NSRecursiveLock()
    private var security: CalendarPeerSecurity
    private var running = false
    private var handoff: CalendarPairingHandoff
    private var confirmedPeer: MCPeerID?
    private var discoveredPeers: Set<MCPeerID> = []
    public var onPairingChanged: ((CalendarPairingState) -> Void)?

    private func publishPairing(_ message: String) {
        onPairingChanged?(CalendarPairingState(stage: handoff.stage.rawValue,
            outgoing: handoff.outgoing, remoteSender: handoff.remoteSender,
            fingerprint: handoff.fingerprint, message: message))
    }
    public func createPairing() throws {
        lock.lock(); defer { lock.unlock() }
        try handoff.create()
        publishPairing("Transfer this offer privately to your other device, then paste its response here. Expires in five minutes.")
    }
    public func importPairing(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        try handoff.importToken(token)
        publishPairing(handoff.outgoing == nil
            ? "Compare the verification code on both devices, then confirm on each."
            : "Return this response privately to the first device. Compare verification codes before confirming on each.")
    }
    public func confirmPairing() throws {
        lock.lock(); defer { lock.unlock() }
        // Mutate a copy so a failed pin leaves the handoff retryable.
        var next = handoff
        try next.confirm { peer, sender, secret in
            try security.pair(peer, sender: sender, key: secret)
            confirmedPeer = peer
        }
        handoff = next
        publishPairing("Confirmed here; sync unavailable until the other device confirms the same secret and authenticates. Use Connect / retry on both devices.")
        retryPairingConnection()
    }
    public func cancelPairing() {
        lock.lock(); defer { lock.unlock() }
        if let confirmedPeer { revoke(peerID: confirmedPeer); return }
        handoff.clear()
        publishPairing("Pairing cancelled. Create a new offer on the first device; cancel on the other device too.")
    }
    public func retryPairingConnection() {
        lock.lock(); defer { lock.unlock() }
        guard confirmedPeer != nil else { return }
        if !running { start(); return }
        // Re-announce after local confirmation: discovery may have happened
        // while the other device was still unpaired and rejecting invitations.
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        for peer in discoveredPeers { inviteIfPaired(peer) }
    }

    public init(displayName: String, peerID: MCPeerID? = nil) {
        let identity = peerID ?? MCPeerID(displayName: displayName)
        localPeerID = identity
        security = CalendarPeerSecurity(localSender: displayName)
        handoff = CalendarPairingHandoff(localPeer: identity, localSender: displayName)
        session = MCSession(peer: identity, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: identity, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: identity, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    /// Call only after authenticated out-of-band verification, never from discovery.
    /// Use a unique random key per pairing. Display names are not credentials.
    public func pair(peerID: MCPeerID, senderID: String, sharedKey: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard peerID != localPeerID else { throw CalendarPeerSyncError.invalidPairing }
        try security.pair(peerID, sender: senderID, key: sharedKey)
    }
    public func revoke(peerID: MCPeerID) {
        lock.lock(); defer { lock.unlock() }
        security.revoke(peerID)
        if confirmedPeer == peerID {
            confirmedPeer = nil
            handoff.clear(revoked: true)
            publishPairing("Pairing revoked on this device. Revoke on the other device too; reconnect with a newly generated offer.")
            onStatusChanged?(.stopped)
        }
        // MCSession has no individual disconnect API; rotate every connection.
        security.disconnectAll()
        session.disconnect()
    }
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        onStatusChanged?(.started)
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        running = false
        discoveredPeers.removeAll()
        security = CalendarPeerSecurity(localSender: handoff.localSender)
        confirmedPeer = nil
        handoff.clear()
        publishPairing("Nearby sync stopped; in-memory pairing cleared. Both devices must pair again with a new offer.")
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        onStatusChanged?(.stopped)
    }
    public func send(snapshot: CalendarSnapshot, senderID: String, revision: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let envelope = try CalendarPeerSyncEnvelope(snapshot: snapshot, senderID: senderID, revision: revision)
        guard running else { return }
        for peer in session.connectedPeers where security.isAuthenticated(peer) {
            try session.send(security.send(envelope, to: peer), toPeers: [peer], with: .reliable)
        }
    }
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        lock.lock(); defer { lock.unlock() }
        guard running, security.isPaired(peerID) else { return }
        switch state {
        case .connecting:
            publishPairing("Connecting; nearby sync awaits proof of the same secret on both devices.")
            onStatusChanged?(.connecting(peerID.displayName))
        case .connected:
            do { try session.send(security.begin(peerID), toPeers: [peerID], with: .reliable) }
            catch { security.disconnect(peerID); onStatusChanged?(.failed("Peer authentication failed")) }
        case .notConnected:
            security.disconnect(peerID)
            publishPairing("Peer disconnected. Keep both apps open nearby and use Connect / retry. If either app restarted, revoke and pair again.")
            onStatusChanged?(.disconnected(peerID.displayName))
        @unknown default: security.disconnect(peerID)
        }
    }
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        do {
            let wasAuthenticated = security.isAuthenticated(peerID)
            let result = try security.receive(data, from: peerID)
            if let reply = result.reply { try session.send(reply, toPeers: [peerID], with: .reliable) }
            if !wasAuthenticated, security.isAuthenticated(peerID) {
                publishPairing("Authenticated nearby connection. Pairing lasts only until sync stops or this app quits.")
                onStatusChanged?(.connected(peerID.displayName))
            }
            if let envelope = result.snapshot { onSnapshotReceived?(envelope, peerID) }
        } catch {
            publishPairing("Peer message rejected. If verification codes differ or either app restarted, revoke on both devices and create a new offer.")
            onStatusChanged?(.failed("Rejected peer message"))
        }
    }
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        let allowed = running && security.isPaired(peerID)
        invitationHandler(allowed, allowed ? session : nil)
    }
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { onStatusChanged?(.failed("Discovery unavailable")) }
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        // Bound untrusted discovery bookkeeping. Only OOB-pinned identities invite.
        if discoveredPeers.count < 64 { discoveredPeers.insert(peerID) }
        inviteIfPaired(peerID)
    }
    private func inviteIfPaired(_ peer: MCPeerID) {
        guard running, let sender = security.sender(for: peer),
              !session.connectedPeers.contains(peer),
              CalendarPeerSyncPolicy.shouldInvite(localID: handoff.localSender, remoteID: sender) else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        lock.lock(); defer { lock.unlock() }
        discoveredPeers.remove(peerID)
    }
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) { onStatusChanged?(.failed("Discovery unavailable")) }
}
