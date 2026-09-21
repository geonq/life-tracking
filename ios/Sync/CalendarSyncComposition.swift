import CryptoKit
import Foundation

/// Builds the explicitly configured calendar replication stack.
///
/// Callers must provide validated, persisted endpoint and trust configuration,
/// including the calendar store ID. Construction creates no network task and
/// does not enable synchronization; the caller owns when the returned engine
/// is used.
public enum CalendarSyncComposition {
    public static func makeEngine(
        endpoint: SyncEndpoint,
        store: CalendarStore,
        calendarStoreID: String,
        localDeviceID: String,
        keychain: any SyncKeychainStore,
        frontierStore: any SyncFrontierStore
    ) async throws -> SyncEngine {
        try validate(endpoint: endpoint)
        try SyncContractValidation.requireUUID(endpoint.id)
        try SyncContractValidation.requireUUID(endpoint.datasetID)
        try SyncContractValidation.requireUnsigned(endpoint.epoch, positive: true)
        try SyncContractValidation.requireUUID(calendarStoreID)
        try SyncContractValidation.requireUUID(localDeviceID)

        let identity = SyncIdentityStore(deviceID: localDeviceID, keychain: keychain)
        let localIdentity = try await identity.identity()
        guard localIdentity.deviceID == localDeviceID,
              localIdentity.role == .applying,
              let enrolled = endpoint.members.first(where: { $0.deviceID == localDeviceID }),
              enrolled.role == localIdentity.role,
              enrolled.keyID == localIdentity.keyID,
              enrolled.publicKey == localIdentity.publicKey else {
            throw SyncFailure.membershipMismatch
        }

        let applyingReplicaIDs = Set(
            endpoint.members
                .filter { $0.role == .applying }
                .map(\.deviceID)
        )
        guard applyingReplicaIDs.contains(localDeviceID) else {
            throw SyncFailure.membershipMismatch
        }

        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: endpoint.datasetID,
            epoch: endpoint.epoch,
            originID: localDeviceID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: endpoint.id,
            authorizedApplyingReplicaIDs: applyingReplicaIDs
        )
        let transport = SyncTransport(identity: identity)
        return try SyncEngine(
            adapters: [adapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )
    }

    private static func validate(endpoint: SyncEndpoint) throws {
        try SyncContractValidation.requireUUID(endpoint.id)
        try SyncContractValidation.requireUUID(endpoint.datasetID)
        try SyncContractValidation.requireUnsigned(endpoint.epoch, positive: true)
        try SyncContractValidation.requireHash(endpoint.serverKeyID)
        try SyncContractValidation.requireIdentifier(endpoint.approvedHost, maximumUTF8Bytes: 253)

        guard endpoint.approvedHost == endpoint.approvedHost.lowercased(),
              endpoint.origin.scheme?.lowercased() == "https",
              endpoint.origin.user == nil,
              endpoint.origin.password == nil,
              endpoint.origin.query == nil,
              endpoint.origin.fragment == nil,
              endpoint.origin.host?.lowercased() == endpoint.approvedHost,
              endpoint.origin.path.isEmpty || endpoint.origin.path == "/" else {
            throw SyncFailure.endpointNotApproved
        }

        let serverKeyBytes = try SyncContractValidation.requireBase64URL(
            endpoint.serverPublicKey,
            maximumDecodedBytes: 32
        )
        guard serverKeyBytes.count == 32,
              SyncWireCodec.sha256(serverKeyBytes) == endpoint.serverKeyID else {
            throw SyncFailure.membershipMismatch
        }
        do {
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: serverKeyBytes)
        } catch {
            throw SyncFailure.membershipMismatch
        }

        guard !endpoint.members.isEmpty,
              endpoint.members.count <= SyncContractConstants.maxMembers else {
            throw SyncFailure.membershipMismatch
        }
        var deviceIDs = Set<String>()
        var keyIDs = Set<String>()
        for member in endpoint.members {
            try SyncContractValidation.requireUUID(member.deviceID)
            try SyncContractValidation.requireHash(member.keyID)
            guard deviceIDs.insert(member.deviceID).inserted,
                  keyIDs.insert(member.keyID).inserted else {
                throw SyncFailure.membershipMismatch
            }
            _ = try SyncWireCodec.publicKey(for: member)
        }
        guard !deviceIDs.contains(endpoint.id) else {
            throw SyncFailure.membershipMismatch
        }
        guard endpoint.members.contains(where: { $0.role == .applying }) else {
            throw SyncFailure.membershipMismatch
        }
    }
}
