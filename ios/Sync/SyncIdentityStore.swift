import CryptoKit
import Foundation
import Security

public protocol SyncKeychainStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public final class SystemSyncKeychainStore: SyncKeychainStore, @unchecked Sendable {
    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw SyncFailure.corruptStore }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed:
            throw SyncFailure.identityUnavailable
        default:
            throw SyncFailure.identityUnavailable
        }
    }

    public func write(_ data: Data, service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false,
        ]
        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw SyncFailure.identityUnavailable }
            return
        }
        if addStatus == errSecInteractionNotAllowed || addStatus == errSecNotAvailable {
            throw SyncFailure.identityUnavailable
        }
        throw SyncFailure.identityUnavailable
    }

    public func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncFailure.identityUnavailable
        }
    }
}

public struct SyncDeviceIdentity: Codable, Equatable, Sendable {
    public let deviceID: String
    public let keyID: String
    public let publicKey: String
    public let role: SyncReplicaRole
}

private struct StoredSyncIdentity: Codable, Sendable {
    let schemaVersion: Int
    let deviceID: String
    let seed: String
}

public actor SyncIdentityStore {
    public static let replicationService = "LifeOS.replication.v1"
    public static let revokedService = "LifeOS.replication.revocation.v1"

    private let deviceID: String
    private let role: SyncReplicaRole
    private let keychain: any SyncKeychainStore
    private let keyAccount: String
    private var cachedKey: Curve25519.Signing.PrivateKey?
    private var revokedAtEpoch: UInt64?
    private var revocationLoaded = false

    public init(
        deviceID: String,
        role: SyncReplicaRole = .applying,
        keychain: any SyncKeychainStore = SystemSyncKeychainStore()
    ) {
        self.deviceID = deviceID
        self.role = role
        self.keychain = keychain
        self.keyAccount = deviceID
    }

    public func identity() throws -> SyncDeviceIdentity {
        try SyncContractValidation.requireUUID(deviceID)
        let key = try loadOrCreateKey()
        let publicData = key.publicKey.rawRepresentation
        return SyncDeviceIdentity(
            deviceID: deviceID,
            keyID: SyncWireCodec.sha256(publicData),
            publicKey: publicData.syncBase64URL,
            role: role
        )
    }

    public func loadOrCreateKey() throws -> Curve25519.Signing.PrivateKey {
        try loadRevocationIfNeeded()
        if let cachedKey { return cachedKey }
        if let revokedAtEpoch {
            throw revokedAtEpoch > 0 ? SyncFailure.revoked : SyncFailure.identityUnavailable
        }
        if let stored = try keychain.read(service: Self.replicationService, account: keyAccount) {
            do {
                let identity = try SyncWireCodec.decodeStrict(
                    StoredSyncIdentity.self,
                    from: stored,
                    maximumBytes: 1_024,
                    requiredKeys: ["schemaVersion", "deviceID", "seed"],
                    validate: {
                        try SyncContractValidation.requireSchema($0.schemaVersion)
                        try SyncContractValidation.requireUUID($0.deviceID)
                        guard $0.deviceID == deviceID,
                              try Data(syncBase64URL: $0.seed).count == 32 else { throw SyncFailure.corruptStore }
                    }
                )
                let seed = try Data(syncBase64URL: identity.seed)
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                cachedKey = key
                return key
            } catch {
                throw SyncFailure.corruptStore
            }
        }
        let key = Curve25519.Signing.PrivateKey()
        let stored = StoredSyncIdentity(schemaVersion: 1, deviceID: deviceID, seed: key.rawRepresentation.syncBase64URL)
        let encoded = try SyncWireCodec.canonicalJSON(stored, maximumBytes: 1_024)
        do {
            try keychain.write(encoded, service: Self.replicationService, account: keyAccount)
        } catch {
            // A failed write is never followed by a new key on the next read.
            throw error
        }
        cachedKey = key
        return key
    }

    private func sign(_ bytes: Data) throws -> Data {
        guard !bytes.isEmpty else { throw SyncFailure.invalidInput }
        return try loadOrCreateKey().signature(for: bytes)
    }

    public func signOperation(_ operation: SyncOperation) throws -> SyncOperation {
        guard role == .applying else { throw SyncFailure.unauthenticated }
        let current = try identity()
        guard operation.originID == current.deviceID, operation.keyID == current.keyID else {
            throw SyncFailure.unauthenticated
        }
        return try SyncWireCodec.signOperation(operation, using: loadOrCreateKey())
    }

    public func signFrame(_ frame: SyncSignedFrame) throws -> SyncSignedFrame {
        let current = try identity()
        guard frame.senderID == current.deviceID, frame.keyID == current.keyID else {
            throw SyncFailure.unauthenticated
        }
        return try SyncWireCodec.signFrame(frame, using: loadOrCreateKey())
    }

    public func signAcknowledgement(_ acknowledgement: SyncAck) throws -> SyncAck {
        guard role == .applying else { throw SyncFailure.unauthenticated }
        let current = try identity()
        guard acknowledgement.replicaID == current.deviceID,
              acknowledgement.keyID == current.keyID else {
            throw SyncFailure.unauthenticated
        }
        return try SyncWireCodec.signAcknowledgement(acknowledgement, using: loadOrCreateKey())
    }

    public func signObservation(_ observation: SignedHealthObservation) throws -> SignedHealthObservation {
        let current = try identity()
        guard role == .applying,
              observation.originID == current.deviceID,
              observation.keyID == current.keyID else {
            throw SyncFailure.unauthenticated
        }
        return try SyncWireCodec.signObservation(observation, using: loadOrCreateKey())
    }

    public func signHTTP(
        method: String,
        route: String,
        headers: [SyncHTTPHeader],
        body: Data
    ) throws -> SyncDetachedSignatureCarrierV6 {
        guard method == "POST",
              SyncHTTPRoute(rawValue: route) != .challenge,
              SyncHTTPRoute(rawValue: route) != .health else { throw SyncFailure.unauthenticated }
        let current = try identity()
        let signing = try SyncHTTPV6.canonicalSigningBytes(method: method, route: route, headers: headers, body: body)
        return SyncDetachedSignatureCarrierV6(
            algorithm: "Ed25519",
            keyID: current.keyID,
            signedBytesHash: SyncWireCodec.sha256(signing),
            signatureBase64URL: try sign(signing).syncBase64URL
        )
    }

    public func revoke(deviceID: UUID, epoch: UInt64) throws {
        guard deviceID.uuidString.lowercased() == self.deviceID else { throw SyncFailure.unauthenticated }
        var bytes = Data()
        var value = epoch.bigEndian
        withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        try keychain.write(bytes, service: Self.revokedService, account: keyAccount)
        revokedAtEpoch = epoch
        cachedKey = nil
    }

    public func retire(keyID: String) throws {
        let current = try identity()
        guard current.keyID == keyID else { throw SyncFailure.unauthenticated }
        guard let device = UUID(uuidString: deviceID) else { throw SyncFailure.invalidInput }
        try revoke(deviceID: device, epoch: 1)
    }

    public func rotate() throws -> SyncDeviceIdentity {
        try SyncContractValidation.requireUUID(deviceID)
        try loadRevocationIfNeeded()
        let key = Curve25519.Signing.PrivateKey()
        let stored = StoredSyncIdentity(schemaVersion: 1, deviceID: deviceID, seed: key.rawRepresentation.syncBase64URL)
        try keychain.write(try SyncWireCodec.canonicalJSON(stored, maximumBytes: 1_024), service: Self.replicationService, account: keyAccount)
        cachedKey = key
        revokedAtEpoch = nil
        try keychain.delete(service: Self.revokedService, account: keyAccount)
        return try identity()
    }

    public func isRevoked() -> Bool {
        revokedAtEpoch != nil
    }

    private func loadRevocationIfNeeded() throws {
        guard !revocationLoaded else { return }
        revocationLoaded = true
        guard let stored = try keychain.read(service: Self.revokedService, account: keyAccount) else { return }
        guard stored.count == MemoryLayout<UInt64>.size else { throw SyncFailure.corruptStore }
        let epoch = stored.reduce(UInt64(0)) { partial, byte in (partial << 8) | UInt64(byte) }
        guard epoch > 0 else { throw SyncFailure.corruptStore }
        revokedAtEpoch = epoch
    }
}

/// Separate custody boundary for the receipt authority. It is intentionally
/// not a generic signing oracle and never returns private key bytes.
public actor ReceiptAuthorityKeyStore19 {
    public static let service = "LifeOS.receipt-authority.v1"

    private let installationID: String
    private let ownerKeyID: String
    private let deviceKeyID: String
    private let keychain: any SyncKeychainStore
    private let reservationURL: URL
    private var cachedKey: Curve25519.Signing.PrivateKey?
    private var activated = false
    private var reservation: BootstrapReservation20?
    private var reservationLoaded = false

    public init(
        installationID: String,
        ownerKeyID: String,
        deviceKeyID: String,
        reservationURL: URL,
        keychain: any SyncKeychainStore = SystemSyncKeychainStore()
    ) {
        self.installationID = installationID
        self.ownerKeyID = ownerKeyID
        self.deviceKeyID = deviceKeyID
        self.reservationURL = reservationURL
        self.keychain = keychain
    }

    public func authorizeReceiptBootstrap(
        confirmedFingerprint: String?,
        existingAuthorityHash: String?,
        authorityID: UUID,
        migrationEpoch: UInt64,
        bootstrapToken: UUID
    ) throws -> ReceiptBootstrapAuthorization19 {
        try loadReservationIfNeeded()
        guard let confirmedFingerprint, !confirmedFingerprint.isEmpty else {
            throw SyncFailure.bootstrapConfirmationRequired
        }
        try SyncContractValidation.requireUUID(installationID)
        try SyncContractValidation.requireUUID(authorityID.uuidString.lowercased())
        try SyncContractValidation.requireHash(ownerKeyID)
        try SyncContractValidation.requireHash(deviceKeyID)
        guard migrationEpoch > 0 else { throw SyncFailure.invalidInput }
        guard existingAuthorityHash == nil else { throw SyncFailure.receiptAuthorityAlreadyActive }
        if activated { throw SyncFailure.receiptAuthorityAlreadyActive }
        try SyncContractValidation.requireUUID(bootstrapToken.uuidString.lowercased())
        if let reservation, reservation.status == 1 {
            guard reservation.authorityID == authorityID.uuidString.lowercased(),
                  reservation.bootstrapToken == bootstrapToken.uuidString.lowercased(),
                  reservation.migrationEpoch == migrationEpoch else {
                throw SyncFailure.bootstrapConflict
            }
        }
        return ReceiptBootstrapAuthorization19(
            installationID: installationID,
            authorityID: authorityID.uuidString.lowercased(),
            migrationEpoch: migrationEpoch,
            bootstrapToken: bootstrapToken.uuidString.lowercased(),
            deviceKeyID: deviceKeyID,
            ownerKeyID: ownerKeyID,
            expectedExistingAuthorityHash: existingAuthorityHash,
            authorizationID: UUID().uuidString.lowercased()
        )
    }

    public func signBootstrapFence(
        record: UnsignedAuthorityMutationV9,
        authorization: ReceiptBootstrapAuthorization19
    ) throws -> SignedBootstrapFence20 {
        try loadReservationIfNeeded()
        guard !activated else { throw SyncFailure.bootstrapAlreadyActivated }
        guard record.kind == .fenceOpen,
              record.sequence == 0,
              record.previousRecordHash == nil,
              record.authorityID.uuidString.lowercased() == authorization.authorityID,
              record.migrationEpoch == authorization.migrationEpoch,
              record.signerKeyID == authorization.deviceKeyID,
              authorization.installationID == installationID,
              authorization.deviceKeyID == deviceKeyID,
              authorization.ownerKeyID == ownerKeyID else {
            throw SyncFailure.invalidInput
        }
        try validateMutationRecord(record)
        try validateFencePayload(record.payload, bootstrapToken: authorization.bootstrapToken)
        guard try authorityMutationHash(record) == record.recordHash else { throw SyncFailure.hashMismatch }

        if let reservation {
            guard reservation.status == 1,
                  reservation.installationID == installationID,
                  reservation.authorityID == authorization.authorityID,
                  reservation.migrationEpoch == authorization.migrationEpoch,
                  reservation.bootstrapToken == authorization.bootstrapToken,
                  reservation.ownerKeyID == ownerKeyID,
                  reservation.deviceKeyID == deviceKeyID,
                  reservation.fenceHash == record.recordHash,
                  reservation.fenceMatches(record) else {
                throw SyncFailure.bootstrapConflict
            }
            return SignedBootstrapFence20(record: reservation.fence)
        }

        let signed = try makeSigned(record: record, key: try receiptKey())
        let candidate = BootstrapReservation20(
            schemaVersion: 20,
            installationID: installationID,
            authorityID: authorization.authorityID,
            migrationEpoch: authorization.migrationEpoch,
            bootstrapToken: authorization.bootstrapToken,
            ownerKeyID: ownerKeyID,
            deviceKeyID: deviceKeyID,
            fenceHash: signed.recordHash,
            fence: signed,
            status: 1
        )
        try persistReservation(candidate)
        reservation = candidate
        reservationLoaded = true
        return SignedBootstrapFence20(record: signed)
    }

    public func signMutation(
        record: UnsignedAuthorityMutationV9,
        authorization: ReceiptMutationAuthorization19
    ) throws -> ReceiptSignature19 {
        try loadReservationIfNeeded()
        guard activated,
              record.kind != .fenceOpen,
              record.sequence >= 1,
              record.authorityID.uuidString.lowercased() == authorization.authorityID,
              record.migrationEpoch == authorization.epoch,
              record.signerKeyID == deviceKeyID,
              record.sequence == authorization.sequence,
              record.previousRecordHash == authorization.expectedPreviousHash else {
            throw activated ? SyncFailure.invalidInput : SyncFailure.bootstrapAlreadyActivated
        }
        try validateMutationRecord(record)
        guard try authorityMutationHash(record) == record.recordHash else { throw SyncFailure.hashMismatch }
        let signed = try makeSigned(record: record, key: try receiptKey())
        return ReceiptSignature19(signerKeyID: deviceKeyID, signature: signed.signature.syncBase64URL)
    }

    public func signDeletionCompletion20(
        record: DeletionCompletion20,
        authorization: VerifiedDeletionSigning20
    ) throws -> ReceiptSignature19 {
        try loadReservationIfNeeded()
        guard activated,
              record.authorityID == authorization.authorityID,
              record.receiptID == authorization.receiptID,
              record.operationID == authorization.operationID,
              record.completionHash == authorization.completionHash,
              record.signerKeyID == deviceKeyID else {
            throw SyncFailure.capabilityUnavailable
        }
        guard record.schemaVersion == 20, record.fenceClosed else { throw SyncFailure.invalidInput }
        for value in [record.authorityID, record.receiptID, record.operationID, record.fenceID] {
            try SyncContractValidation.requireUUID(value)
        }
        for value in [
            record.workPlanHash, record.setupHash, record.lastTargetProofHash,
            record.remoteClosureRoot, record.proofRoot, record.journalHash,
            record.completionHash, record.signerKeyID
        ] {
            try SyncContractValidation.requireHash(value)
        }
        if let credentialHash = record.credentialRetirementProofHash {
            try SyncContractValidation.requireHash(credentialHash)
        }
        guard try SyncWireCodec.deletionCompletionHash(record) == record.completionHash else {
            throw SyncFailure.hashMismatch
        }
        let signed = try SyncWireCodec.signDeletionCompletion20(record, using: try receiptKey())
        return ReceiptSignature19(signerKeyID: deviceKeyID, signature: signed.signature)
    }

    public func activateReceiptBootstrap(verified: VerifiedBootstrapPublication20) throws {
        try loadReservationIfNeeded()
        guard let reservation,
              reservation.installationID == installationID,
              reservation.authorityID == verified.authorityID,
              reservation.bootstrapToken == verified.bootstrapToken,
              reservation.fenceHash == verified.fenceHash,
              reservation.ownerKeyID == ownerKeyID,
              reservation.deviceKeyID == deviceKeyID,
              reservation.status == 1,
              verified.logHeadSequence == 0 else {
            throw SyncFailure.bootstrapConflict
        }
        try SyncContractValidation.requireUUID(verified.authorityID)
        try SyncContractValidation.requireUUID(verified.bootstrapToken)
        try SyncContractValidation.requireHash(verified.authorityFileHash)
        try SyncContractValidation.requireHash(verified.fenceHash)
        try SyncContractValidation.requireHash(verified.logHeadHash)
        let next = BootstrapReservation20(
            schemaVersion: reservation.schemaVersion,
            installationID: reservation.installationID,
            authorityID: reservation.authorityID,
            migrationEpoch: reservation.migrationEpoch,
            bootstrapToken: reservation.bootstrapToken,
            ownerKeyID: reservation.ownerKeyID,
            deviceKeyID: reservation.deviceKeyID,
            fenceHash: reservation.fenceHash,
            fence: reservation.fence,
            status: 2
        )
        try persistReservation(next)
        activated = true
        self.reservation = next
    }

    public func discardUnusedBootstrap(
        authorization: ReceiptBootstrapAuthorization19,
        verifiedAbsence: VerifiedBootstrapAbsence20
    ) throws {
        try loadReservationIfNeeded()
        guard !activated,
              self.reservation?.status == 1,
              authorization.installationID == installationID,
              authorization.authorityID == verifiedAbsence.authorityID,
              authorization.bootstrapToken == verifiedAbsence.bootstrapToken,
              self.reservation?.authorityID == authorization.authorityID,
              self.reservation?.bootstrapToken == authorization.bootstrapToken,
              verifiedAbsence.parentHash == authorization.expectedExistingAuthorityHash else {
            throw SyncFailure.bootstrapConflict
        }
        if FileManager.default.fileExists(atPath: reservationURL.path) {
            try FileManager.default.removeItem(at: reservationURL)
        }
        reservation = nil
        reservationLoaded = true
    }

    private func receiptKey() throws -> Curve25519.Signing.PrivateKey {
        if let cachedKey { return cachedKey }
        try SyncContractValidation.requireHash(deviceKeyID)
        let account = installationID
        if let stored = try keychain.read(service: Self.service, account: account) {
            do {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
                guard SyncWireCodec.sha256(key.publicKey.rawRepresentation) == deviceKeyID else {
                    throw SyncFailure.identityUnavailable
                }
                cachedKey = key
                return key
            } catch {
                if let failure = error as? SyncFailure { throw failure }
                throw SyncFailure.corruptStore
            }
        }
        guard !activated else { throw SyncFailure.identityUnavailable }
        let key = Curve25519.Signing.PrivateKey()
        guard SyncWireCodec.sha256(key.publicKey.rawRepresentation) == deviceKeyID else {
            throw SyncFailure.identityUnavailable
        }
        try keychain.write(key.rawRepresentation, service: Self.service, account: account)
        cachedKey = key
        return key
    }

    private func makeSigned(record: UnsignedAuthorityMutationV9, key: Curve25519.Signing.PrivateKey) throws -> LifeOSAuthorityMutationV9 {
        guard SyncWireCodec.sha256(key.publicKey.rawRepresentation) == record.signerKeyID else {
            throw SyncFailure.identityUnavailable
        }
        guard try authorityMutationHash(record) == record.recordHash else { throw SyncFailure.hashMismatch }
        let unsigned = LifeOSAuthorityMutationV9(
            schemaVersion: record.schemaVersion,
            authorityID: record.authorityID,
            migrationEpoch: record.migrationEpoch,
            sequence: record.sequence,
            mutationID: record.mutationID,
            kind: record.kind,
            previousRecordHash: record.previousRecordHash,
            payload: record.payload,
            recordHash: record.recordHash,
            signerKeyID: record.signerKeyID,
            signature: Data()
        )
        let canonical = try SyncWireCodec.canonicalJSONWithoutSignature(unsigned)
        let bytes = try SyncWireCodec.encodeLengthPrefixed(domain: "LifeOS/receipt-authority-mutation/v9", canonical: canonical)
        return LifeOSAuthorityMutationV9(
            schemaVersion: unsigned.schemaVersion,
            authorityID: unsigned.authorityID,
            migrationEpoch: unsigned.migrationEpoch,
            sequence: unsigned.sequence,
            mutationID: unsigned.mutationID,
            kind: unsigned.kind,
            previousRecordHash: unsigned.previousRecordHash,
            payload: unsigned.payload,
            recordHash: unsigned.recordHash,
            signerKeyID: unsigned.signerKeyID,
            signature: try key.signature(for: bytes)
        )
    }

    private func loadReservationIfNeeded() throws {
        guard !reservationLoaded else { return }
        guard FileManager.default.fileExists(atPath: reservationURL.path) else {
            reservationLoaded = true
            return
        }
        let data = try Data(contentsOf: reservationURL, options: [.mappedIfSafe])
        let loaded: BootstrapReservation20
        do {
            loaded = try SyncWireCodec.decodeStrict(
                BootstrapReservation20.self,
                from: data,
                maximumBytes: 12_288,
                requiredKeys: [
                    "schemaVersion", "installationID", "authorityID", "migrationEpoch",
                    "bootstrapToken", "ownerKeyID", "deviceKeyID", "fenceHash", "fence", "status"
                ],
                validate: { value in
                    guard value.schemaVersion == 20,
                          value.installationID == installationID,
                          value.status == 1 || value.status == 2 else {
                        throw SyncFailure.corruptStore
                    }
                    try SyncContractValidation.requireUUID(value.installationID)
                    try SyncContractValidation.requireUUID(value.authorityID)
                    try SyncContractValidation.requireUUID(value.bootstrapToken)
                    try SyncContractValidation.requireHash(value.ownerKeyID)
                    try SyncContractValidation.requireHash(value.deviceKeyID)
                    try SyncContractValidation.requireHash(value.fenceHash)
                    guard value.fenceHash == value.fence.recordHash,
                          value.fence.authorityID.uuidString.lowercased() == value.authorityID,
                          value.fence.migrationEpoch == value.migrationEpoch,
                          value.fence.sequence == 0,
                          value.fence.kind == .fenceOpen,
                          value.fence.previousRecordHash == nil,
                          value.fence.signerKeyID == value.deviceKeyID,
                          value.fence.signature.count == 64 else {
                        throw SyncFailure.corruptStore
                    }
                    try validateFencePayload(value.fence.payload, bootstrapToken: value.bootstrapToken)
                    try validateMutationRecord(Self.unsignedRecord(from: value.fence))
                    guard try Self.authorityMutationHash(Self.unsignedRecord(from: value.fence)) == value.fence.recordHash else {
                        throw SyncFailure.corruptStore
                    }
                }
            )
        } catch let failure as SyncFailure {
            throw failure
        } catch {
            throw SyncFailure.corruptStore
        }
        reservation = loaded
        activated = loaded.status == 2
        reservationLoaded = true
    }

    private func validateMutationRecord(_ record: UnsignedAuthorityMutationV9) throws {
        guard record.schemaVersion == 9,
              record.migrationEpoch > 0,
              record.sequence <= UInt64.max - 1 else { throw SyncFailure.invalidInput }
        try SyncContractValidation.requireUUID(record.authorityID.uuidString.lowercased())
        try SyncContractValidation.requireUUID(record.mutationID.uuidString.lowercased())
        try SyncContractValidation.requireHashOrNil(record.previousRecordHash)
        try SyncContractValidation.requireHash(record.recordHash)
        try SyncContractValidation.requireHash(record.signerKeyID)
        guard Self.payloadMatchesKind(record.kind, payload: record.payload) else { throw SyncFailure.invalidVariant }
    }

    private func validateFencePayload(_ payload: LifeOSAuthorityMutationPayloadV9, bootstrapToken: String) throws {
        guard case .fenceOpen(let value) = payload,
              value.bootstrapToken.uuidString.lowercased() == bootstrapToken,
              value.sourceInventory.count == 3,
              value.initialInventory.count == 3 else {
            throw SyncFailure.invalidInput
        }
        let domains: [LifeOSReceiptDomainV6] = [.recovery, .data, .deletion]
        guard value.sourceInventory.map(\.domain) == domains,
              value.initialInventory.map(\.domain) == domains,
              Set(value.sourceInventory.map(\.sourceID)).count == 3 else {
            throw SyncFailure.invalidInput
        }
        for source in value.sourceInventory {
            try SyncContractValidation.requireUUID(source.sourceID.uuidString.lowercased())
            if let fileHash = source.fileHash { try SyncContractValidation.requireHash(fileHash) }
            if let receiptHeadHash = source.receiptHeadHash { try SyncContractValidation.requireHash(receiptHeadHash) }
        }
        for entry in value.initialInventory {
            if let fileHash = entry.fileHash { try SyncContractValidation.requireHash(fileHash) }
            try SyncContractValidation.requireHash(entry.receiptHeadHash)
            try SyncContractValidation.requireHash(entry.terminalHeadHash)
        }
    }

    private static func payloadMatchesKind(_ kind: LifeOSAuthorityMutationKindV9, payload: LifeOSAuthorityMutationPayloadV9) -> Bool {
        switch (kind, payload) {
        case (.fenceOpen, .fenceOpen),
             (.canonicalReplaceIntent, .canonicalReplaceIntent),
             (.canonicalReplaceCommit, .canonicalReplaceCommit),
             (.canonicalVerified, .canonicalVerified),
             (.legacyRetireIntent, .legacyRetireIntent),
             (.legacyRetireCommit, .legacyRetireCommit),
             (.retirementProof, .retirementProof),
             (.postRetirementCanonicalIntent, .postRetirementCanonicalIntent),
             (.postRetirementCanonicalCommit, .postRetirementCanonicalCommit),
             (.checkpoint, .checkpoint),
             (.canonicalAbort, .canonicalAbort):
            return true
        default:
            return false
        }
    }

    private static func unsignedRecord(from record: LifeOSAuthorityMutationV9) -> UnsignedAuthorityMutationV9 {
        UnsignedAuthorityMutationV9(
            schemaVersion: record.schemaVersion,
            authorityID: record.authorityID,
            migrationEpoch: record.migrationEpoch,
            sequence: record.sequence,
            mutationID: record.mutationID,
            kind: record.kind,
            previousRecordHash: record.previousRecordHash,
            payload: record.payload,
            recordHash: record.recordHash,
            signerKeyID: record.signerKeyID
        )
    }

    private static func authorityMutationHash(_ record: UnsignedAuthorityMutationV9) throws -> String {
        try SyncWireCodec.hash(
            domain: "LifeOS/receipt-authority-mutation-hash/v9",
            canonical: SyncWireCodec.canonicalJSON(AuthorityMutationHashPreimageV9(record))
        )
    }

    private func authorityMutationHash(_ record: UnsignedAuthorityMutationV9) throws -> String {
        try Self.authorityMutationHash(record)
    }

    private func persistReservation(_ value: BootstrapReservation20) throws {
        let data = try SyncWireCodec.canonicalJSON(value, maximumBytes: 12_288)
        let directory = reservationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(reservationURL.lastPathComponent + ".tmp")
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
        if FileManager.default.fileExists(atPath: reservationURL.path) {
            _ = try FileManager.default.replaceItemAt(reservationURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: reservationURL)
        }
    }

}

private struct AuthorityMutationHashPreimageV9: Encodable {
    let schemaVersion: UInt16
    let authorityID: UUID
    let migrationEpoch: UInt64
    let sequence: UInt64
    let mutationID: UUID
    let kind: LifeOSAuthorityMutationKindV9
    let previousRecordHash: String?
    let payload: LifeOSAuthorityMutationPayloadV9
    let signerKeyID: String

    init(_ record: UnsignedAuthorityMutationV9) {
        schemaVersion = record.schemaVersion
        authorityID = record.authorityID
        migrationEpoch = record.migrationEpoch
        sequence = record.sequence
        mutationID = record.mutationID
        kind = record.kind
        previousRecordHash = record.previousRecordHash
        payload = record.payload
        signerKeyID = record.signerKeyID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, authorityID, migrationEpoch, sequence, mutationID, kind, previousRecordHash, payload, signerKeyID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(authorityID, forKey: .authorityID)
        try container.encode(migrationEpoch, forKey: .migrationEpoch)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(mutationID, forKey: .mutationID)
        try container.encode(kind, forKey: .kind)
        try container.encode(previousRecordHash, forKey: .previousRecordHash)
        try payload.encode(to: container.superEncoder(forKey: .payload))
        try container.encode(signerKeyID, forKey: .signerKeyID)
    }
}

private extension BootstrapReservation20 {
    func fenceMatches(_ record: UnsignedAuthorityMutationV9) -> Bool {
        fence.schemaVersion == record.schemaVersion
            && fence.authorityID == record.authorityID
            && fence.migrationEpoch == record.migrationEpoch
            && fence.sequence == record.sequence
            && fence.mutationID == record.mutationID
            && fence.kind == record.kind
            && fence.previousRecordHash == record.previousRecordHash
            && fence.payload == record.payload
            && fence.recordHash == record.recordHash
            && fence.signerKeyID == record.signerKeyID
    }
}

private extension Data {
    var syncBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(syncBase64URL value: String) throws {
        self = try SyncContractValidation.requireBase64URL(value)
    }
}
