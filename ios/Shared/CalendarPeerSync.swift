import Foundation
import MultipeerConnectivity

public enum CalendarPeerSyncError: Error, Equatable, Sendable {
    case unsupportedEnvelopeVersion(Int)
    case invalidSenderID
    case invalidRevision
    case invalidEnvelope
    case snapshotTooLarge
}

/// The wire format is deliberately versioned so peers can reject newer formats safely.
public struct CalendarPeerSyncEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
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
        guard revision >= 0 else { throw CalendarPeerSyncError.invalidRevision }
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
            guard envelope.revision >= 0 else { throw CalendarPeerSyncError.invalidRevision }
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

@available(iOS 17.0, macOS 14.0, *)
public final class CalendarPeerSync: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    public static let serviceType = "lifeos-calendar" // Bonjour service types are limited to 15 characters.

    public let localPeerID: MCPeerID
    public var onSnapshotReceived: ((CalendarPeerSyncEnvelope, MCPeerID) -> Void)?
    public var onStatusChanged: ((CalendarPeerConnectionStatus) -> Void)?

    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var running = false

    public init(displayName: String, peerID: MCPeerID? = nil) {
        let identity = peerID ?? MCPeerID(displayName: displayName)
        localPeerID = identity
        session = MCSession(peer: identity, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: identity, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: identity, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    public func start() {
        guard !running else { return }
        running = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        onStatusChanged?(.started)
    }

    public func stop() {
        guard running else { onStatusChanged?(.stopped); return }
        running = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        onStatusChanged?(.stopped)
    }

    public func send(snapshot: CalendarSnapshot, senderID: String, revision: Int) throws {
        let data = try CalendarPeerSyncEnvelope(snapshot: snapshot, senderID: senderID, revision: revision).encoded()
        guard !session.connectedPeers.isEmpty else { return }
        try session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connecting: onStatusChanged?(.connecting(peerID.displayName))
        case .connected: onStatusChanged?(.connected(peerID.displayName))
        case .notConnected: onStatusChanged?(.disconnected(peerID.displayName))
        @unknown default: onStatusChanged?(.failed("Unknown connection state"))
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do { onSnapshotReceived?(try CalendarPeerSyncEnvelope.decode(data), peerID) }
        catch { onStatusChanged?(.failed("Rejected envelope")) }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(CalendarPeerSyncPolicy.shouldInvite(localID: peerID.displayName, remoteID: localPeerID.displayName), session)
    }
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { onStatusChanged?(.failed(error.localizedDescription)) }
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard CalendarPeerSyncPolicy.shouldInvite(localID: localPeerID.displayName, remoteID: peerID.displayName) else { return }
        onStatusChanged?(.connecting(peerID.displayName))
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) { onStatusChanged?(.failed(error.localizedDescription)) }
}
