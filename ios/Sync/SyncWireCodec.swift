import CryptoKit
import Foundation

private enum SyncJSONValue {
    case object([(String, SyncJSONValue)])
    case array([SyncJSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
}

private struct SyncJSONParser {
    private let bytes: [UInt8]
    private var index: Int = 0
    private var depth: Int = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func parse() throws -> SyncJSONValue {
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw SyncFailure.invalidInput }
        return value
    }

    private mutating func parseValue() throws -> SyncJSONValue {
        guard depth < 32, index < bytes.count else { throw SyncFailure.invalidInput }
        skipWhitespace()
        guard index < bytes.count else { throw SyncFailure.invalidInput }
        switch bytes[index] {
        case 123:
            return try parseObject()
        case 91:
            return try parseArray()
        case 34:
            return .string(try parseString())
        case 116:
            try consume([116, 114, 117, 101])
            return .boolean(true)
        case 102:
            try consume([102, 97, 108, 115, 101])
            return .boolean(false)
        case 110:
            try consume([110, 117, 108, 108])
            return .null
        case 48...57:
            return .number(try parseUnsignedNumber())
        default:
            throw SyncFailure.invalidInput
        }
    }

    private mutating func parseObject() throws -> SyncJSONValue {
        try expect(123)
        depth += 1
        defer { depth -= 1 }
        skipWhitespace()
        if consumeIf(125) { return .object([]) }
        var fields: [(String, SyncJSONValue)] = []
        var names = Set<String>()
        while true {
            skipWhitespace()
            guard consumeIf(34) else { throw SyncFailure.invalidInput }
            index -= 1
            let name = try parseString()
            guard names.insert(name).inserted else { throw SyncFailure.invalidInput }
            skipWhitespace()
            try expect(58)
            let value = try parseValue()
            fields.append((name, value))
            skipWhitespace()
            if consumeIf(125) { return .object(fields) }
            try expect(44)
        }
    }

    private mutating func parseArray() throws -> SyncJSONValue {
        try expect(91)
        depth += 1
        defer { depth -= 1 }
        skipWhitespace()
        if consumeIf(93) { return .array([]) }
        var values: [SyncJSONValue] = []
        while true {
            values.append(try parseValue())
            skipWhitespace()
            if consumeIf(93) { return .array(values) }
            try expect(44)
        }
    }

    private mutating func parseString() throws -> String {
        try expect(34)
        let start = index - 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 && !escaped {
                let raw = Data(bytes[start..<index])
                let decoded: Any
                do {
                    decoded = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
                } catch {
                    throw SyncFailure.invalidInput
                }
                guard let value = decoded as? String else {
                    throw SyncFailure.invalidInput
                }
                let sourceValue = try decodeStringPreservingNormalization(raw)
                let normalizedSource = sourceValue.precomposedStringWithCanonicalMapping
                guard Array(normalizedSource.utf8) == Array(sourceValue.utf8) else {
                    throw SyncFailure.invalidInput
                }
                return value
            }
            if byte < 0x20 && !escaped { throw SyncFailure.invalidInput }
            if byte == 92 && !escaped {
                escaped = true
            } else {
                escaped = false
            }
        }
        throw SyncFailure.invalidInput
    }

    private func decodeStringPreservingNormalization(_ raw: Data) throws -> String {
        let bytes = Array(raw)
        guard bytes.count >= 2, bytes.first == 34, bytes.last == 34 else {
            throw SyncFailure.invalidInput
        }

        let end = bytes.count - 1
        var cursor = 1
        var output = Data()
        output.reserveCapacity(raw.count)

        while cursor < end {
            let byte = bytes[cursor]
            cursor += 1
            if byte != 92 {
                guard byte >= 0x20, byte != 34 else { throw SyncFailure.invalidInput }
                output.append(byte)
                continue
            }

            guard cursor < end else { throw SyncFailure.invalidInput }
            let escape = bytes[cursor]
            cursor += 1
            switch escape {
            case 34, 47, 92:
                output.append(escape)
            case 98:
                output.append(8)
            case 102:
                output.append(12)
            case 110:
                output.append(10)
            case 114:
                output.append(13)
            case 116:
                output.append(9)
            case 117:
                let first = try parseHexQuad(bytes, at: cursor, end: end)
                cursor += 4
                if (0xD800...0xDBFF).contains(first) {
                    guard cursor + 1 < end, bytes[cursor] == 92, bytes[cursor + 1] == 117 else {
                        throw SyncFailure.invalidInput
                    }
                    cursor += 2
                    let second = try parseHexQuad(bytes, at: cursor, end: end)
                    cursor += 4
                    guard (0xDC00...0xDFFF).contains(second) else { throw SyncFailure.invalidInput }
                    let scalar = 0x10000 + ((UInt32(first) - 0xD800) << 10) + (UInt32(second) - 0xDC00)
                    guard let unicodeScalar = UnicodeScalar(scalar) else { throw SyncFailure.invalidInput }
                    output.append(contentsOf: String(unicodeScalar).utf8)
                } else {
                    guard !(0xDC00...0xDFFF).contains(first),
                          let unicodeScalar = UnicodeScalar(UInt32(first)) else {
                        throw SyncFailure.invalidInput
                    }
                    output.append(contentsOf: String(unicodeScalar).utf8)
                }
            default:
                throw SyncFailure.invalidInput
            }
        }

        guard let value = String(data: output, encoding: .utf8) else {
            throw SyncFailure.invalidInput
        }
        return value
    }

    private func parseHexQuad(_ bytes: [UInt8], at start: Int, end: Int) throws -> UInt16 {
        guard start >= 0, start + 4 <= end else { throw SyncFailure.invalidInput }
        var value: UInt16 = 0
        for offset in 0..<4 {
            let byte = bytes[start + offset]
            let nibble: UInt16
            switch byte {
            case 48...57:
                nibble = UInt16(byte - 48)
            case 65...70:
                nibble = UInt16(byte - 55)
            case 97...102:
                nibble = UInt16(byte - 87)
            default:
                throw SyncFailure.invalidInput
            }
            value = (value << 4) | nibble
        }
        return value
    }

    private mutating func parseUnsignedNumber() throws -> String {
        let start = index
        while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
            index += 1
        }
        let raw = String(decoding: bytes[start..<index], as: UTF8.self)
        guard raw == "0" || !raw.hasPrefix("0") else { throw SyncFailure.invalidInput }
        return raw
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard index < bytes.count, bytes[index] == byte else { throw SyncFailure.invalidInput }
        index += 1
    }

    private mutating func consume(_ sequence: [UInt8]) throws {
        guard bytes[index..<min(index + sequence.count, bytes.count)].elementsEqual(sequence) else {
            throw SyncFailure.invalidInput
        }
        index += sequence.count
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count && (bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 || bytes[index] == 32) {
            index += 1
        }
    }
}

private enum SyncJSONWriter {
    static func write(_ value: SyncJSONValue) throws -> Data {
        Data(try writeString(value).utf8)
    }

    private static func writeString(_ value: SyncJSONValue) throws -> String {
        switch value {
        case .null:
            return "null"
        case .boolean(let value):
            return value ? "true" : "false"
        case .number(let value):
            guard value == "0" || !value.hasPrefix("0"),
                  UInt64(value) != nil else { throw SyncFailure.invalidInput }
            return value
        case .string(let value):
            let normalized = value.precomposedStringWithCanonicalMapping
            let encoded = try JSONSerialization.data(withJSONObject: [normalized])
            guard encoded.count >= 2 else { throw SyncFailure.invalidInput }
            return String(decoding: encoded.dropFirst().dropLast(), as: UTF8.self)
        case .array(let values):
            let encoded = try values.map { try writeString($0) }.joined(separator: ",")
            return "[" + encoded + "]"
        case .object(let fields):
            let sorted = fields.sorted {
                Array($0.0.utf16).lexicographicallyPrecedes(Array($1.0.utf16))
            }
            let body = try sorted.map { key, value in
                let encodedKey = try writeString(.string(key))
                return encodedKey + ":" + (try writeString(value))
            }.joined(separator: ",")
            return "{" + body + "}"
        }
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

public enum SyncWireCodec {
    public static let requestDomain = "LifeOS/replication/request/v1"
    public static let responseDomain = "LifeOS/replication/response/v1"
    public static let operationDomain = "LifeOS/operation/v1"
    public static let acknowledgementDomain = "LifeOS/acknowledgement/v1"
    public static let observationDomain = "LifeOS/observation/v1"
    public static let frameDomain = "LifeOS/frame/v1"

    public static func canonicalJSON<T: Encodable>(_ value: T, maximumBytes: Int = SyncContractConstants.maxBodyBytes) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= maximumBytes else { throw SyncFailure.capacity }
        var parser = SyncJSONParser(data: encoded)
        let tree = try parser.parse()
        let canonical = try SyncJSONWriter.write(tree)
        guard canonical.count <= maximumBytes else { throw SyncFailure.capacity }
        return canonical
    }

    public static func canonicalizeJSON(_ data: Data, maximumBytes: Int = SyncContractConstants.maxBodyBytes) throws -> Data {
        guard data.count <= maximumBytes else { throw SyncFailure.capacity }
        var parser = SyncJSONParser(data: data)
        return try SyncJSONWriter.write(parser.parse())
    }

    /// Returns the canonical object bytes with the required detached-signature
    /// member removed.  Signed records keep a `signature` key on the wire, but
    /// the preimage is the exact record with that member absent.
    public static func canonicalJSONWithoutSignature<T: Encodable>(
        _ value: T,
        maximumBytes: Int = SyncContractConstants.maxBodyBytes
    ) throws -> Data {
        var parser = SyncJSONParser(data: try canonicalJSON(value, maximumBytes: maximumBytes))
        guard case .object(let fields) = try parser.parse() else { throw SyncFailure.invalidInput }
        let unsigned = SyncJSONValue.object(fields.filter { $0.0 != "signature" })
        let canonical = try SyncJSONWriter.write(unsigned)
        guard canonical.count <= maximumBytes else { throw SyncFailure.capacity }
        return canonical
    }

    public static func decodeStrict<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        maximumBytes: Int = SyncContractConstants.maxBodyBytes,
        requiredKeys: Set<String>,
        optionalKeys: Set<String> = [],
        validate: (T) throws -> Void
    ) throws -> T {
        guard data.count <= maximumBytes else { throw SyncFailure.capacity }
        var parser = SyncJSONParser(data: data)
        let tree = try parser.parse()
        guard case .object(let fields) = tree else {
            throw SyncFailure.invalidInput
        }
        let keys = Set(fields.map { $0.0 })
        guard requiredKeys.isSubset(of: keys),
              keys.isSubset(of: requiredKeys.union(optionalKeys)) else {
            throw SyncFailure.invalidInput
        }
        let value: T
        do {
            value = try JSONDecoder().decode(type, from: data)
        } catch {
            throw SyncFailure.invalidInput
        }
        try validate(value)
        return value
    }

    public static func encodeLengthPrefixed(domain: String, canonical: Data) throws -> Data {
        guard canonical.count <= Int(UInt32.max) else { throw SyncFailure.capacity }
        var output = Data(domain.utf8)
        output.append(0)
        var length = UInt32(canonical.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(canonical)
        return output
    }

    public static func hash(domain: String, canonical: Data) throws -> String {
        let framed = try encodeLengthPrefixed(domain: domain, canonical: canonical)
        return SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
    }

    public static func operationSigningBytes(for operation: SyncOperation) throws -> Data {
        try validate(operation, signatureMayBeEmpty: true)
        let unsigned = SyncOperation(
            schemaVersion: operation.schemaVersion,
            datasetID: operation.datasetID,
            epoch: operation.epoch,
            storeID: operation.storeID,
            domain: operation.domain,
            originID: operation.originID,
            keyID: operation.keyID,
            sequence: operation.sequence,
            mutationID: operation.mutationID,
            entityID: operation.entityID,
            parents: operation.parents,
            baseHash: operation.baseHash,
            kind: operation.kind,
            payload: operation.payload,
            signature: ""
        )
        let canonical = try canonicalJSONWithoutSignature(unsigned)
        return try encodeLengthPrefixed(domain: operationDomain, canonical: canonical)
    }

    public static func operationHash(for operation: SyncOperation) throws -> String {
        sha256(try operationSigningBytes(for: operation))
    }

    public static func signOperation(_ operation: SyncOperation, using key: Curve25519.Signing.PrivateKey) throws -> SyncOperation {
        let bytes = try operationSigningBytes(for: operation)
        return SyncOperation(
            schemaVersion: operation.schemaVersion,
            datasetID: operation.datasetID,
            epoch: operation.epoch,
            storeID: operation.storeID,
            domain: operation.domain,
            originID: operation.originID,
            keyID: operation.keyID,
            sequence: operation.sequence,
            mutationID: operation.mutationID,
            entityID: operation.entityID,
            parents: operation.parents,
            baseHash: operation.baseHash,
            kind: operation.kind,
            payload: operation.payload,
            signature: try key.signature(for: bytes).syncBase64URL
        )
    }

    public static func verifyOperation(_ operation: SyncOperation, publicKey: Curve25519.Signing.PublicKey) throws {
        try validate(operation)
        let signature = try Data(syncBase64URL: operation.signature)
        guard publicKey.isValidSignature(signature, for: try operationSigningBytes(for: operation)) else {
            throw SyncFailure.unauthenticated
        }
    }

    public static func acknowledgementSigningBytes(for acknowledgement: SyncAck) throws -> Data {
        try validate(acknowledgement, signatureMayBeEmpty: true)
        let unsigned = SyncAck(
            schemaVersion: acknowledgement.schemaVersion,
            datasetID: acknowledgement.datasetID,
            epoch: acknowledgement.epoch,
            storeID: acknowledgement.storeID,
            mutationID: acknowledgement.mutationID,
            operationHash: acknowledgement.operationHash,
            replicaID: acknowledgement.replicaID,
            keyID: acknowledgement.keyID,
            level: acknowledgement.level,
            resultHash: acknowledgement.resultHash,
            signature: ""
        )
        let canonical = try canonicalJSONWithoutSignature(unsigned)
        return try encodeLengthPrefixed(domain: acknowledgementDomain, canonical: canonical)
    }

    public static func signAcknowledgement(_ acknowledgement: SyncAck, using key: Curve25519.Signing.PrivateKey) throws -> SyncAck {
        let signature = try key.signature(for: try acknowledgementSigningBytes(for: acknowledgement)).syncBase64URL
        return SyncAck(
            schemaVersion: acknowledgement.schemaVersion,
            datasetID: acknowledgement.datasetID,
            epoch: acknowledgement.epoch,
            storeID: acknowledgement.storeID,
            mutationID: acknowledgement.mutationID,
            operationHash: acknowledgement.operationHash,
            replicaID: acknowledgement.replicaID,
            keyID: acknowledgement.keyID,
            level: acknowledgement.level,
            resultHash: acknowledgement.resultHash,
            signature: signature
        )
    }

    public static func verifyAcknowledgement(_ acknowledgement: SyncAck, publicKey: Curve25519.Signing.PublicKey) throws {
        try validate(acknowledgement)
        let signature = try Data(syncBase64URL: acknowledgement.signature)
        guard publicKey.isValidSignature(signature, for: try acknowledgementSigningBytes(for: acknowledgement)) else {
            throw SyncFailure.unauthenticated
        }
    }

    public static func publicKey(for member: SyncMember) throws -> Curve25519.Signing.PublicKey {
        try SyncContractValidation.requireUUID(member.deviceID)
        try SyncContractValidation.requireHash(member.keyID)
        let raw: Data
        do {
            raw = try Data(syncBase64URL: member.publicKey)
        } catch {
            throw SyncFailure.membershipMismatch
        }
        guard raw.count == 32, sha256(raw) == member.keyID else {
            throw SyncFailure.membershipMismatch
        }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            throw SyncFailure.membershipMismatch
        }
    }

    /// Verify the device-signed records inside a server-authenticated response.
    /// The outer response signature authenticates the gateway only; every
    /// nested record still needs its enrolled device signature checked here.
    public static func verifyResponseRecords(
        _ response: SyncExchangeResponse,
        endpoint: SyncEndpoint,
        expectedStoreID: String
    ) throws {
        try SyncContractValidation.requireSchema(response.schemaVersion)
        try SyncContractValidation.requireUUID(response.storeID)
        try SyncContractValidation.requireUUID(expectedStoreID)
        guard response.storeID == expectedStoreID,
              response.operations.count <= SyncContractConstants.maxPageOperations,
              response.acknowledgements.count <= SyncContractConstants.maxPageOperations else {
            throw SyncFailure.membershipMismatch
        }
        var membersByDevice: [String: SyncMember] = [:]
        var keyIDs = Set<String>()
        for member in endpoint.members {
            guard membersByDevice[member.deviceID] == nil,
                  keyIDs.insert(member.keyID).inserted else {
                throw SyncFailure.membershipMismatch
            }
            _ = try publicKey(for: member)
            membersByDevice[member.deviceID] = member
        }
        guard response.operations.isEmpty && response.acknowledgements.isEmpty || !membersByDevice.isEmpty else {
            throw SyncFailure.membershipMismatch
        }
        for operation in response.operations {
            try validate(operation)
            guard operation.datasetID == endpoint.datasetID,
                  operation.epoch == endpoint.epoch,
                  operation.storeID == expectedStoreID,
                  let member = membersByDevice[operation.originID],
                  member.keyID == operation.keyID,
                  member.role == .applying else {
                throw SyncFailure.membershipMismatch
            }
            try verifyOperation(operation, publicKey: try publicKey(for: member))
        }
        for acknowledgement in response.acknowledgements {
            try validate(acknowledgement)
            guard acknowledgement.datasetID == endpoint.datasetID,
                  acknowledgement.epoch == endpoint.epoch,
                  acknowledgement.storeID == expectedStoreID,
                  let member = membersByDevice[acknowledgement.replicaID],
                  member.keyID == acknowledgement.keyID else {
                throw SyncFailure.membershipMismatch
            }
            try verifyAcknowledgement(acknowledgement, publicKey: try publicKey(for: member))
        }
    }

    public static func observationSigningBytes(for observation: SignedHealthObservation) throws -> Data {
        try validate(observation, signatureMayBeEmpty: true)
        let unsigned = SignedHealthObservation(
            schemaVersion: observation.schemaVersion,
            datasetID: observation.datasetID,
            originID: observation.originID,
            keyID: observation.keyID,
            sequence: observation.sequence,
            body: observation.body,
            bodyHash: observation.bodyHash,
            signature: ""
        )
        return try encodeLengthPrefixed(domain: observationDomain, canonical: canonicalJSONWithoutSignature(unsigned))
    }

    public static func signObservation(_ observation: SignedHealthObservation, using key: Curve25519.Signing.PrivateKey) throws -> SignedHealthObservation {
        let signature = try key.signature(for: try observationSigningBytes(for: observation)).syncBase64URL
        return SignedHealthObservation(
            schemaVersion: observation.schemaVersion,
            datasetID: observation.datasetID,
            originID: observation.originID,
            keyID: observation.keyID,
            sequence: observation.sequence,
            body: observation.body,
            bodyHash: observation.bodyHash,
            signature: signature
        )
    }

    public static func verifyObservation(_ observation: SignedHealthObservation, publicKey: Curve25519.Signing.PublicKey) throws {
        try validate(observation)
        guard publicKey.isValidSignature(
            try Data(syncBase64URL: observation.signature),
            for: try observationSigningBytes(for: observation)
        ) else { throw SyncFailure.unauthenticated }
    }

    public static func encodeOperation(_ operation: SyncOperation) throws -> Data {
        try validate(operation)
        return try canonicalJSON(operation, maximumBytes: SyncContractConstants.maxOperationBytes)
    }

    public static func decodeOperation(_ data: Data) throws -> SyncOperation {
        try decodeStrict(
            SyncOperation.self,
            from: data,
            maximumBytes: SyncContractConstants.maxOperationBytes,
            requiredKeys: ["schemaVersion", "datasetID", "epoch", "storeID", "domain", "originID", "keyID", "sequence", "mutationID", "entityID", "parents", "kind", "payload", "signature"],
            optionalKeys: ["baseHash"],
            validate: { try validate($0) }
        )
    }

    public static func frameSigningBytes(_ frame: SyncSignedFrame) throws -> Data {
        try validate(frame, signatureMayBeEmpty: true)
        let unsigned = SyncSignedFrame(
            schemaVersion: frame.schemaVersion,
            datasetID: frame.datasetID,
            epoch: frame.epoch,
            endpointID: frame.endpointID,
            senderID: frame.senderID,
            keyID: frame.keyID,
            requestID: frame.requestID,
            nonce: frame.nonce,
            method: frame.method,
            path: frame.path,
            status: frame.status,
            body: frame.body,
            bodyHash: frame.bodyHash,
            signature: ""
        )
        let canonical = try canonicalJSONWithoutSignature(unsigned)
        return try encodeLengthPrefixed(domain: frameDomain, canonical: canonical)
    }

    public static func encodeSignedFrame(_ frame: SyncSignedFrame) throws -> Data {
        try validate(frame)
        return try canonicalJSON(frame, maximumBytes: 2_097_152)
    }

    public static func signFrame(_ frame: SyncSignedFrame, using key: Curve25519.Signing.PrivateKey) throws -> SyncSignedFrame {
        let signature = try key.signature(for: try frameSigningBytes(frame)).syncBase64URL
        return SyncSignedFrame(
            schemaVersion: frame.schemaVersion,
            datasetID: frame.datasetID,
            epoch: frame.epoch,
            endpointID: frame.endpointID,
            senderID: frame.senderID,
            keyID: frame.keyID,
            requestID: frame.requestID,
            nonce: frame.nonce,
            method: frame.method,
            path: frame.path,
            status: frame.status,
            body: frame.body,
            bodyHash: frame.bodyHash,
            signature: signature
        )
    }

    public static func verifyFrame(_ frame: SyncSignedFrame, publicKey: Curve25519.Signing.PublicKey) throws {
        try validate(frame)
        let signature = try Data(syncBase64URL: frame.signature)
        guard publicKey.isValidSignature(signature, for: try frameSigningBytes(frame)) else {
            throw SyncFailure.unauthenticated
        }
    }

    public static func validate(_ payload: SyncPayload) throws {
        try SyncContractValidation.requireSchema(payload.schemaVersion)
        try SyncContractValidation.requireHash(payload.hash)
        guard payload.byteCount >= 0,
              UInt64(payload.byteCount) <= SyncContractConstants.maxBlobBytes else {
            throw SyncFailure.capacity
        }
        let hasInline = payload.inline != nil
        let hasBlob = payload.blobHash != nil
        guard hasInline != hasBlob else { throw SyncFailure.invalidInput }
        if let inline = payload.inline {
            let bytes = try SyncContractValidation.requireBase64URL(inline, maximumDecodedBytes: SyncContractConstants.maxInlinePayloadBytes)
            guard bytes.count == payload.byteCount, sha256(bytes) == payload.hash else { throw SyncFailure.hashMismatch }
        }
        if let blobHash = payload.blobHash {
            try SyncContractValidation.requireHash(blobHash)
            guard blobHash == payload.hash else { throw SyncFailure.hashMismatch }
        }
    }

    public static func validate(_ operation: SyncOperation, signatureMayBeEmpty: Bool = false) throws {
        try SyncContractValidation.requireSchema(operation.schemaVersion)
        for value in [operation.datasetID, operation.storeID, operation.originID, operation.mutationID] {
            try SyncContractValidation.requireUUID(value)
        }
        _ = try SyncContractValidation.requireUnsigned(operation.epoch, positive: true)
        try SyncContractValidation.requireHash(operation.keyID)
        _ = try SyncContractValidation.requireUnsigned(operation.sequence, positive: true)
        try SyncContractValidation.requireHash(operation.entityID)
        try SyncContractValidation.requireHashOrNil(operation.baseHash)
        guard operation.parents.count <= SyncContractConstants.maxCausalParents else { throw SyncFailure.capacity }
        for parent in operation.parents { try SyncContractValidation.requireUUID(parent) }
        try SyncContractValidation.requireSortedUnique(operation.parents)
        try validate(operation.payload)
        if operation.kind == .delete {
            guard operation.payload.inline == "" else { throw SyncFailure.invalidInput }
        }
        if !signatureMayBeEmpty || !operation.signature.isEmpty {
            _ = try SyncContractValidation.requireBase64URL(operation.signature, maximumDecodedBytes: 64)
            guard try Data(syncBase64URL: operation.signature).count == 64 else { throw SyncFailure.invalidInput }
        } else if !operation.signature.isEmpty {
            throw SyncFailure.invalidInput
        }
    }

    public static func validate(_ acknowledgement: SyncAck, signatureMayBeEmpty: Bool = false) throws {
        try SyncContractValidation.requireSchema(acknowledgement.schemaVersion)
        for value in [acknowledgement.datasetID, acknowledgement.storeID, acknowledgement.mutationID, acknowledgement.replicaID] {
            try SyncContractValidation.requireUUID(value)
        }
        _ = try SyncContractValidation.requireUnsigned(acknowledgement.epoch, positive: true)
        try SyncContractValidation.requireHash(acknowledgement.operationHash)
        try SyncContractValidation.requireHash(acknowledgement.keyID)
        try SyncContractValidation.requireHash(acknowledgement.resultHash)
        if !signatureMayBeEmpty || !acknowledgement.signature.isEmpty {
            let signature = try Data(syncBase64URL: acknowledgement.signature)
            guard signature.count == 64 else { throw SyncFailure.invalidInput }
        }
    }

    public static func validate(_ observation: SignedHealthObservation, signatureMayBeEmpty: Bool = false) throws {
        try SyncContractValidation.requireSchema(observation.schemaVersion)
        try SyncContractValidation.requireUUID(observation.datasetID)
        try SyncContractValidation.requireUUID(observation.originID)
        try SyncContractValidation.requireHash(observation.keyID)
        _ = try SyncContractValidation.requireUnsigned(observation.sequence, positive: true)
        try SyncContractValidation.requireHash(observation.bodyHash)
        let body = try Data(syncBase64URL: observation.body)
        guard body.count <= 131_072, SyncWireCodec.sha256(body) == observation.bodyHash else { throw SyncFailure.hashMismatch }
        if !signatureMayBeEmpty || !observation.signature.isEmpty {
            guard try Data(syncBase64URL: observation.signature).count == 64 else { throw SyncFailure.invalidInput }
        }
    }

    public static func validate(_ frame: SyncSignedFrame, signatureMayBeEmpty: Bool = false) throws {
        try SyncContractValidation.requireSchema(frame.schemaVersion)
        for value in [frame.datasetID, frame.endpointID, frame.senderID, frame.requestID] {
            try SyncContractValidation.requireUUID(value)
        }
        _ = try SyncContractValidation.requireUnsigned(frame.epoch, positive: true)
        try SyncContractValidation.requireHash(frame.keyID)
        let nonce = try Data(syncBase64URL: frame.nonce)
        guard nonce.count == SyncContractConstants.maxNonceBytes else { throw SyncFailure.invalidInput }
        guard frame.method == "POST",
              SyncHTTPRoute(rawValue: frame.path) != nil,
              frame.path.utf8.count <= 64,
              frame.status == 0 || (100...599).contains(frame.status) else {
            throw SyncFailure.invalidInput
        }
        let body = try Data(syncBase64URL: frame.body)
        guard body.count <= SyncContractConstants.maxBodyBytes,
              sha256(body) == frame.bodyHash else { throw SyncFailure.hashMismatch }
        if !signatureMayBeEmpty || !frame.signature.isEmpty {
            let signature = try Data(syncBase64URL: frame.signature)
            guard signature.count == 64 else { throw SyncFailure.invalidInput }
        }
    }

    public static func validate(_ frontier: SyncFrontier) throws {
        try SyncContractValidation.requireSchema(frontier.schemaVersion)
        guard frontier.positions.count <= SyncContractConstants.maxFrontierPositions else { throw SyncFailure.capacity }
        var keys: [String] = []
        for position in frontier.positions {
            try SyncContractValidation.requireUUID(position.stream.storeID)
            try SyncContractValidation.requireUUID(position.stream.originID)
            _ = try SyncContractValidation.requireUnsigned(position.through)
            keys.append(position.stream.storeID + "\u{0}" + position.stream.originID)
        }
        guard Set(keys).count == keys.count,
              zip(keys, keys.dropFirst()).allSatisfy({ $0 < $1 }) else { throw SyncFailure.invalidInput }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func deletionCompletionHash(_ record: DeletionCompletion20) throws -> String {
        try hash(
            domain: "LifeOS/deletion-completion/v20",
            canonical: canonicalJSON(DeletionCompletionPreimage20(record))
        )
    }

    public static func deletionCompletionSigningBytes(_ record: DeletionCompletion20) throws -> Data {
        try encodeLengthPrefixed(
            domain: "LifeOS/deletion-completion-signature/v20",
            canonical: try Data(hex: record.completionHash)
        )
    }

    public static func signDeletionCompletion20(_ record: DeletionCompletion20, using key: Curve25519.Signing.PrivateKey) throws -> DeletionCompletion20 {
        guard record.fenceClosed else { throw SyncFailure.invalidTransition }
        guard try deletionCompletionHash(record) == record.completionHash else { throw SyncFailure.hashMismatch }
        return DeletionCompletion20(
            schemaVersion: record.schemaVersion,
            authorityID: record.authorityID,
            receiptID: record.receiptID,
            operationID: record.operationID,
            attempt: record.attempt,
            fenceID: record.fenceID,
            workPlanHash: record.workPlanHash,
            setupHash: record.setupHash,
            targetCount: record.targetCount,
            lastTargetProofHash: record.lastTargetProofHash,
            remoteClosureRoot: record.remoteClosureRoot,
            credentialRetirementProofHash: record.credentialRetirementProofHash,
            proofRoot: record.proofRoot,
            journalHash: record.journalHash,
            fenceClosed: record.fenceClosed,
            completionHash: record.completionHash,
            signerKeyID: record.signerKeyID,
            signature: try key.signature(for: deletionCompletionSigningBytes(record)).syncBase64URL
        )
    }

    public static func remoteDeletionClosureHash(_ record: RemoteDeletionClosure20) throws -> String {
        try hash(
            domain: "LifeOS/remote-deletion-closure/v20",
            canonical: canonicalJSON(RemoteDeletionClosurePreimage20(record))
        )
    }

    public static func signRemoteDeletionClosure20(_ record: RemoteDeletionClosure20, using key: Curve25519.Signing.PrivateKey) throws -> RemoteDeletionClosure20 {
        try validate(record, signatureMayBeEmpty: true)
        guard try remoteDeletionClosureHash(record) == record.recordHash else { throw SyncFailure.hashMismatch }
        let signature = try key.signature(
            for: encodeLengthPrefixed(domain: "LifeOS/remote-deletion-closure-signature/v20", canonical: Data(hex: record.recordHash))
        ).syncBase64URL
        return RemoteDeletionClosure20(
            schemaVersion: record.schemaVersion,
            datasetID: record.datasetID,
            targetHostID: record.targetHostID,
            receiptID: record.receiptID,
            operationID: record.operationID,
            fenceID: record.fenceID,
            workPlanHash: record.workPlanHash,
            disposition: record.disposition,
            completedTargetKeys: record.completedTargetKeys,
            appliedProofs: record.appliedProofs,
            pending: record.pending,
            collectorsDisabled: record.collectorsDisabled,
            memberKeyID: record.memberKeyID,
            epoch: record.epoch,
            recordHash: record.recordHash,
            signerKeyID: record.signerKeyID,
            signature: signature
        )
    }

    public static func validate(_ record: RemoteDeletionClosure20, signatureMayBeEmpty: Bool = false) throws {
        guard record.schemaVersion == 20 else { throw SyncFailure.unsupportedSchema }
        for value in [record.datasetID, record.targetHostID, record.receiptID, record.operationID, record.fenceID] {
            try SyncContractValidation.requireUUID(value)
        }
        try SyncContractValidation.requireHash(record.workPlanHash)
        try SyncContractValidation.requireHash(record.memberKeyID)
        try SyncContractValidation.requireUnsigned(String(record.epoch), positive: true)
        try SyncContractValidation.requireHash(record.recordHash)
        try SyncContractValidation.requireHash(record.signerKeyID)
        guard record.pending == nil, record.collectorsDisabled, record.appliedProofs.count <= 2 else { throw SyncFailure.invalidInput }
        try SyncContractValidation.requireSortedUnique(record.completedTargetKeys)
        let appliedKeys = record.appliedProofs.map { $0.context.input.targetKey }
        guard appliedKeys == record.completedTargetKeys else { throw SyncFailure.invalidInput }
        if !signatureMayBeEmpty || !record.signature.isEmpty {
            guard try Data(syncBase64URL: record.signature).count == 64 else { throw SyncFailure.invalidInput }
        }
    }

    public static func verifyRemoteDeletionClosure20(_ record: RemoteDeletionClosure20, pin: LifeOSRemoteServerPin20) throws {
        try validate(record)
        guard record.targetHostID == pin.targetHostID,
              record.signerKeyID == pin.keyID,
              record.epoch == pin.epoch,
              try remoteDeletionClosureHash(record) == record.recordHash else {
            throw SyncFailure.hashMismatch
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try Data(syncBase64URL: pin.publicKey))
        let signing = try encodeLengthPrefixed(domain: "LifeOS/remote-deletion-closure-signature/v20", canonical: Data(hex: record.recordHash))
        guard publicKey.isValidSignature(try Data(syncBase64URL: record.signature), for: signing) else {
            throw SyncFailure.unauthenticated
        }
    }

    public static func verifyDeletionCompletion20(_ record: DeletionCompletion20, pin: ReceiptPublicIdentity19) throws {
        guard record.schemaVersion == 20 else { throw SyncFailure.unsupportedSchema }
        guard record.authorityID == pin.authorityID, record.signerKeyID == pin.signerKeyID else {
            throw SyncFailure.unauthenticated
        }
        for value in [record.authorityID, record.receiptID, record.operationID, record.fenceID] {
            try SyncContractValidation.requireUUID(value)
        }
        try SyncContractValidation.requireHash(record.completionHash)
        guard try deletionCompletionHash(record) == record.completionHash, record.fenceClosed else { throw SyncFailure.hashMismatch }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(syncBase64URL: pin.publicKey))
        let signature = try Data(syncBase64URL: record.signature)
        let signing = try deletionCompletionSigningBytes(record)
        guard publicKey.isValidSignature(signature, for: signing) else { throw SyncFailure.unauthenticated }
    }

    private struct DeletionCompletionPreimage20: Codable, Sendable {
        let schemaVersion: Int
        let authorityID: String
        let receiptID: String
        let operationID: String
        let attempt: String
        let fenceID: String
        let workPlanHash: String
        let setupHash: String
        let targetCount: String
        let lastTargetProofHash: String
        let remoteClosureRoot: String
        let credentialRetirementProofHash: String?
        let proofRoot: String
        let journalHash: String
        let fenceClosed: Bool
        let signerKeyID: String

        init(_ value: DeletionCompletion20) {
            schemaVersion = value.schemaVersion
            authorityID = value.authorityID
            receiptID = value.receiptID
            operationID = value.operationID
            attempt = String(value.attempt)
            fenceID = value.fenceID
            workPlanHash = value.workPlanHash
            setupHash = value.setupHash
            targetCount = String(value.targetCount)
            lastTargetProofHash = value.lastTargetProofHash
            remoteClosureRoot = value.remoteClosureRoot
            credentialRetirementProofHash = value.credentialRetirementProofHash
            proofRoot = value.proofRoot
            journalHash = value.journalHash
            fenceClosed = value.fenceClosed
            signerKeyID = value.signerKeyID
        }
    }

    private struct RemoteDeletionClosurePreimage20: Codable, Sendable {
        let schemaVersion: Int
        let datasetID: String
        let targetHostID: String
        let receiptID: String
        let operationID: String
        let fenceID: String
        let workPlanHash: String
        let disposition: String
        let completedTargetKeys: [String]
        let appliedProofs: [RemoteDeletionApplied20]
        let pending: String?
        let collectorsDisabled: Bool
        let memberKeyID: String
        let epoch: String
        let signerKeyID: String

        init(_ value: RemoteDeletionClosure20) {
            schemaVersion = value.schemaVersion
            datasetID = value.datasetID
            targetHostID = value.targetHostID
            receiptID = value.receiptID
            operationID = value.operationID
            fenceID = value.fenceID
            workPlanHash = value.workPlanHash
            disposition = value.disposition
            completedTargetKeys = value.completedTargetKeys
            appliedProofs = value.appliedProofs
            pending = value.pending
            collectorsDisabled = value.collectorsDisabled
            memberKeyID = value.memberKeyID
            epoch = String(value.epoch)
            signerKeyID = value.signerKeyID
        }
    }
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw SyncFailure.invalidInput }
        var result = Data()
        result.reserveCapacity(hex.count / 2)
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<next], radix: 16) else { throw SyncFailure.invalidInput }
            result.append(byte)
            cursor = next
        }
        self = result
    }
}

public enum SyncHTTPV6 {
    public static func canonicalSigningBytes(method: String, route: String, headers: [SyncHTTPHeader], body: Data) throws -> Data {
        let normalized = try normalizedHeaders(headers, excludingSignature: true)
        let object = HTTPRequestSigningObject(
            method: method,
            route: route,
            contentType: try requiredHeader("content-type", from: normalized),
            sessionID: try requiredHeader("x-lifeos-session", from: normalized),
            requestID: try requiredHeader("x-lifeos-request-id", from: normalized),
            nonce: try requiredHeader("x-lifeos-nonce", from: normalized),
            epoch: try requiredHeader("x-lifeos-epoch", from: normalized),
            bodyHash: SyncWireCodec.sha256(body)
        )
        return try SyncWireCodec.encodeLengthPrefixed(
            domain: "LifeOS/sync-http/v6",
            canonical: SyncWireCodec.canonicalJSON(object)
        )
    }

    public static func requestSigningBytes(method: String, route: String, headers: [SyncHTTPHeader], body: Data) throws -> Data {
        try canonicalSigningBytes(method: method, route: route, headers: headers, body: body)
    }

    public static func responseSigningBytes(status: Int, headers: [SyncHTTPHeader], body: Data) throws -> Data {
        guard (100...599).contains(status) else { throw SyncFailure.invalidInput }
        let normalized = try normalizedHeaders(headers, excludingSignature: true)
        let object = HTTPResponseSigningObject(
            status: status,
            headers: normalized,
            sessionID: try requiredHeader("x-lifeos-session", from: normalized),
            requestID: try requiredHeader("x-lifeos-request-id", from: normalized),
            requestNonce: try requiredHeader("x-lifeos-request-nonce", from: normalized),
            nextNonce: try requiredHeader("x-lifeos-next-nonce", from: normalized),
            epoch: try requiredHeader("x-lifeos-epoch", from: normalized),
            bodyHash: SyncWireCodec.sha256(body)
        )
        return try SyncWireCodec.encodeLengthPrefixed(
            domain: "LifeOS/sync-http-response/v6",
            canonical: SyncWireCodec.canonicalJSON(object)
        )
    }

    public static func verifyRequest(
        method: String,
        route: String,
        headers: [SyncHTTPHeader],
        body: Data,
        trust: SyncTrustRecord
    ) throws -> VerifiedHTTPFrameV6 {
        guard method == "POST",
              SyncHTTPRoute(rawValue: route) != nil,
              body.count <= SyncContractConstants.maxBodyBytes else {
            throw SyncFailure.invalidInput
        }
        let normalized = try normalizedHeaders(headers, excludingSignature: false)
        let signedHeaders = normalized.filter { $0.name != "x-lifeos-signature" }
        guard try requiredHeader("content-type", from: normalized) == "application/json; charset=utf-8",
              Int(try requiredHeader("content-length", from: normalized)) == body.count,
              try requiredHeader("x-lifeos-session", from: normalized).isEmpty == false else {
            throw SyncFailure.invalidInput
        }
        let carrier = try decodeSignatureCarrier(try requiredHeader("x-lifeos-signature", from: normalized))
        let signing = try canonicalSigningBytes(method: method, route: route, headers: signedHeaders, body: body)
        guard carrier.signedBytesHash == SyncWireCodec.sha256(signing) else { throw SyncFailure.hashMismatch }
        guard let member = trust.members.first(where: { $0.keyID == carrier.keyID }) else { throw SyncFailure.unauthenticated }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try Data(syncBase64URL: member.publicKey))
        let signature = try Data(syncBase64URL: carrier.signatureBase64URL)
        guard publicKey.isValidSignature(signature, for: signing) else { throw SyncFailure.unauthenticated }
        guard let sessionID = UUID(uuidString: try requiredHeader("x-lifeos-session", from: normalized)),
              let requestID = UUID(uuidString: try requiredHeader("x-lifeos-request-id", from: normalized)) else {
            throw SyncFailure.invalidInput
        }
        let epochString = try requiredHeader("x-lifeos-epoch", from: normalized)
        let epoch = try SyncContractValidation.requireUnsigned(epochString, positive: true)
        let nonce = try requiredHeader("x-lifeos-nonce", from: normalized)
        guard try Data(syncBase64URL: nonce).count == SyncContractConstants.maxNonceBytes else { throw SyncFailure.invalidInput }
        return VerifiedHTTPFrameV6(
            method: method,
            route: route,
            sessionID: sessionID,
            requestID: requestID,
            nonce: nonce,
            epoch: epoch,
            body: body,
            memberKeyID: member.keyID
        )
    }

    public static func signResponse(
        status: Int,
        route: String,
        request: VerifiedHTTPFrameV6,
        body: Data,
        member: SyncMember
    ) throws -> SyncHTTPResponseV6 {
        // The P02 server signer owns the private key. Keeping this overload
        // fail-closed prevents a public-member DTO from becoming a signing
        // oracle in the shared client module.
        _ = (status, route, request, body, member)
        throw SyncFailure.identityUnavailable
    }

    public static func verifyResponse(
        _ response: SyncHTTPResponseV6,
        for request: SyncHTTPRequestStateV6,
        trust: SyncTrustRecord
    ) throws -> SyncHTTPResponseV6 {
        let normalized = try normalizedHeaders(response.headers, excludingSignature: false)
        guard response.status >= 100,
              response.status <= 599,
              try requiredHeader("x-lifeos-session", from: normalized) == request.sessionID.uuidString.lowercased(),
              try requiredHeader("x-lifeos-request-id", from: normalized) == request.requestID.uuidString.lowercased(),
              try requiredHeader("x-lifeos-request-nonce", from: normalized) == request.requestNonce,
              try SyncContractValidation.requireUnsigned(requiredHeader("x-lifeos-epoch", from: normalized), positive: true) == request.epoch,
              try requiredHeader("content-type", from: normalized) == "application/json; charset=utf-8",
              Int(try requiredHeader("content-length", from: normalized)) == response.body.count else {
            throw SyncFailure.responseNonceMismatch
        }
        let nextNonce = try requiredHeader("x-lifeos-next-nonce", from: normalized)
        guard try Data(syncBase64URL: nextNonce).count == SyncContractConstants.maxNonceBytes else { throw SyncFailure.responseNonceMismatch }
        let carrier = try decodeSignatureCarrier(try requiredHeader("x-lifeos-signature", from: normalized))
        guard carrier.keyID == trust.serverKeyID else { throw SyncFailure.responseSignatureInvalid }
        let signing = try responseSigningBytes(status: response.status, headers: normalized.filter { $0.name != "x-lifeos-signature" }, body: response.body)
        guard carrier.signedBytesHash == SyncWireCodec.sha256(signing) else { throw SyncFailure.responseSignatureInvalid }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try Data(syncBase64URL: trust.serverPublicKey))
        guard publicKey.isValidSignature(try Data(syncBase64URL: carrier.signatureBase64URL), for: signing) else {
            throw SyncFailure.responseSignatureInvalid
        }
        return response
    }

    public static func headerValue(_ name: String, from headers: [SyncHTTPHeader]) throws -> String {
        try requiredHeader(name.lowercased(), from: try normalizedHeaders(headers, excludingSignature: false))
    }

    private static func normalizedHeaders(_ headers: [SyncHTTPHeader], excludingSignature: Bool) throws -> [SyncHTTPHeader] {
        guard headers.count <= 128 else { throw SyncFailure.capacity }
        var normalized: [SyncHTTPHeader] = []
        normalized.reserveCapacity(headers.count)
        for header in headers {
            guard header.name.unicodeScalars.allSatisfy({ $0.value < 128 }),
                  header.value.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw SyncFailure.invalidInput }
            let name = header.name.lowercased()
            let value = header.value.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.contains("\r"), !value.contains("\n") else { throw SyncFailure.invalidInput }
            normalized.append(SyncHTTPHeader(name: name, value: value))
        }
        normalized.sort { left, right in left.name == right.name ? left.value < right.value : left.name < right.name }
        guard Set(normalized.map { $0.name }).count == normalized.count else { throw SyncFailure.invalidInput }
        if excludingSignature { return normalized.filter { $0.name != "x-lifeos-signature" } }
        guard normalized.contains(where: { $0.name == "x-lifeos-signature" }) else { throw SyncFailure.invalidInput }
        return normalized
    }

    private static func requiredHeader(_ name: String, from headers: [SyncHTTPHeader]) throws -> String {
        guard let value = headers.first(where: { $0.name == name })?.value else { throw SyncFailure.invalidInput }
        return value
    }

    private static func decodeSignatureCarrier(_ value: String) throws -> SyncDetachedSignatureCarrierV6 {
        guard let data = value.data(using: .utf8) else { throw SyncFailure.invalidInput }
        return try SyncWireCodec.decodeStrict(
            SyncDetachedSignatureCarrierV6.self,
            from: data,
            maximumBytes: 16_384,
            requiredKeys: ["algorithm", "keyID", "signedBytesHash", "signatureBase64URL"],
            validate: {
                guard $0.algorithm == "Ed25519" else { throw SyncFailure.unauthenticated }
                try SyncContractValidation.requireHash($0.keyID)
                try SyncContractValidation.requireHash($0.signedBytesHash)
                guard try Data(syncBase64URL: $0.signatureBase64URL).count == 64 else { throw SyncFailure.unauthenticated }
            }
        )
    }

    private struct HTTPRequestSigningObject: Codable, Sendable {
        let method: String
        let route: String
        let contentType: String
        let sessionID: String
        let requestID: String
        let nonce: String
        let epoch: String
        let bodyHash: String
    }

    private struct HTTPResponseSigningObject: Codable, Sendable {
        let status: Int
        let headers: [SyncHTTPHeader]
        let sessionID: String
        let requestID: String
        let requestNonce: String
        let nextNonce: String
        let epoch: String
        let bodyHash: String
    }
}

public actor SyncSessionNonceStoreV6 {
    private var states: [UUID: SyncSessionNonceStateV6] = [:]

    public init() {}

    public func install(_ state: SyncSessionNonceStateV6) throws {
        guard try Data(syncBase64URL: state.currentNonce).count == SyncContractConstants.maxNonceBytes else {
            throw SyncFailure.invalidInput
        }
        states[state.sessionID] = state
    }

    public func current(_ sessionID: UUID) throws -> SyncSessionNonceStateV6 {
        guard let state = states[sessionID] else { throw SyncFailure.responseNonceMismatch }
        return state
    }

    public func consumeResponse(_ response: SyncHTTPResponseV6, for request: SyncHTTPRequestStateV6) throws {
        guard let current = states[request.sessionID],
              current.currentNonce == request.requestNonce,
              current.epoch == request.epoch else {
            throw SyncFailure.responseReplay
        }
        guard let sessionID = UUID(uuidString: try SyncHTTPV6.headerValue("x-lifeos-session", from: response.headers)),
              let requestID = UUID(uuidString: try SyncHTTPV6.headerValue("x-lifeos-request-id", from: response.headers)) else {
            throw SyncFailure.responseReplay
        }
        guard sessionID == request.sessionID,
              requestID == request.requestID,
              try SyncHTTPV6.headerValue("x-lifeos-request-nonce", from: response.headers) == request.requestNonce,
              try SyncContractValidation.requireUnsigned(try SyncHTTPV6.headerValue("x-lifeos-epoch", from: response.headers), positive: true) == request.epoch else {
            throw SyncFailure.responseReplay
        }
        let nextNonce = try SyncHTTPV6.headerValue("x-lifeos-next-nonce", from: response.headers)
        guard try Data(syncBase64URL: nextNonce).count == SyncContractConstants.maxNonceBytes else { throw SyncFailure.responseNonceMismatch }
        states[request.sessionID] = SyncSessionNonceStateV6(
            sessionID: request.sessionID,
            currentNonce: nextNonce,
            epoch: request.epoch,
            expiresAt: current.expiresAt,
            lastRequestID: request.requestID
        )
    }
}
