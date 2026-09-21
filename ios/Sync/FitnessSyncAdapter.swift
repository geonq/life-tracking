import Foundation

/// The sealed training payload used by the fitness replication boundary.
///
/// The domain model already owns the complete session schema and its strict
/// nested decoders. This wrapper adds the versioned/tagged boundary required
/// by SyncPayload without creating a second training persistence model.
public enum FitnessPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let trainingTag = "training"

    case training(Wire4TrainingSession)

    public init(training session: TrainingSession, now: Date = .now) throws {
        self = .training(try Wire4TrainingSession(session: session, now: now))
    }

    public var trainingSession: TrainingSession? {
        guard case .training(let value) = self else { return nil }
        return value.session
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tag, value
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: FitnessPayloadAnyCodingKey.self)
        let actualKeys = Set(dynamic.allKeys.map(\.stringValue))
        guard actualKeys == Set(["schemaVersion", "tag", "value"]) else {
            throw SyncFailure.invalidInput
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == Self.currentSchemaVersion,
              try container.decode(String.self, forKey: .tag) == Self.trainingTag else {
            throw SyncFailure.unsupportedSchema
        }
        self = .training(try container.decode(Wire4TrainingSession.self, forKey: .value))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        switch self {
        case .training(let session):
            try container.encode(Self.trainingTag, forKey: .tag)
            try container.encode(session, forKey: .value)
        }
    }
}

/// A named wire value keeps the domain conversion explicit for later adapter
/// work. It does not duplicate any session fields or persistence state.
public struct Wire4TrainingSession: Codable, Equatable, Sendable {
    public let session: TrainingSession

    public init(session: TrainingSession, now: Date = .now) throws {
        try session.validate(now: now)
        self.session = session
    }

    public init(from decoder: Decoder) throws {
        session = try TrainingSession(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try session.encode(to: encoder)
    }
}

/// The only codec that turns a training domain value into a replicated
/// payload. It uses the training domain's lossless numeric date strategy and
/// a bounded local canonical JSON implementation, so payload hashes are
/// stable across Mac and iPhone without weakening the shared envelope codec.
public enum FitnessPayloadCodec {
    private static let maximumPayloadBytes = min(
        SyncContractConstants.maxInlinePayloadBytes,
        SyncContractConstants.maxOperationBytes
    )

    public static func encode(_ session: TrainingSession, now: Date = .now) throws -> Data {
        let payload = try FitnessPayload(training: session, now: now)
        return try encodePayload(payload)
    }

    private static func encodePayload(_ payload: FitnessPayload) throws -> Data {
        let encoded = try TrainingDateCoding.makeEncoder().encode(payload)
        try validateSize(encoded)
        let canonical = try FitnessJSONCanonicalizer.canonicalize(
            encoded,
            maximumBytes: maximumPayloadBytes
        )
        try validateSize(canonical)
        return canonical
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> FitnessPayload {
        try validateSize(data)
        let canonical = try FitnessJSONCanonicalizer.canonicalize(
            data,
            maximumBytes: maximumPayloadBytes
        )
        guard canonical == data else { throw SyncFailure.invalidInput }

        do {
            let decoder = TrainingDateCoding.makeDecoder(now: now)
            let decoded = try decoder.decode(FitnessPayload.self, from: data)
            do {
                guard let session = decoded.trainingSession else {
                    throw SyncFailure.invalidInput
                }
                let reencoded = try encodePayload(try FitnessPayload(training: session, now: now))
                guard reencoded == data else { throw SyncFailure.invalidInput }
            } catch {
                throw SyncFailure.invalidInput
            }
            return decoded
        } catch let error as SyncFailure {
            throw error
        } catch {
            throw SyncFailure.invalidInput
        }
    }

    private static func validateSize(_ data: Data) throws {
        guard data.count <= maximumPayloadBytes else { throw SyncFailure.capacity }
    }
}

private struct FitnessPayloadAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Canonical JSON for domain payloads. The replication envelope has stricter
/// unsigned-integer fields, but fitness values contain finite fractional
/// numbers and lossless reference-date timestamps. Keeping this parser local
/// prevents domain numbers from weakening those envelope rules.
enum FitnessJSONCanonicalizer {
    private enum Value {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case number(String)
        case boolean(Bool)
        case null
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        init(data: Data) { bytes = Array(data) }

        mutating func parse() throws -> Value {
            let value = try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw SyncFailure.invalidInput }
            return value
        }

        private mutating func parseValue() throws -> Value {
            skipWhitespace()
            guard depth < 32, index < bytes.count else { throw SyncFailure.invalidInput }
            switch bytes[index] {
            case 123: return try parseObject()
            case 91: return try parseArray()
            case 34: return .string(try parseString())
            case 116:
                try consume([116, 114, 117, 101])
                return .boolean(true)
            case 102:
                try consume([102, 97, 108, 115, 101])
                return .boolean(false)
            case 110:
                try consume([110, 117, 108, 108])
                return .null
            case 45, 48...57: return .number(try parseNumber())
            default: throw SyncFailure.invalidInput
            }
        }

        private mutating func parseObject() throws -> Value {
            try expect(123)
            depth += 1
            defer { depth -= 1 }
            skipWhitespace()
            if consumeIf(125) { return .object([]) }

            var fields: [(String, Value)] = []
            var names = Set<String>()
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 34 else { throw SyncFailure.invalidInput }
                let name = try parseString()
                let normalizedName = name.precomposedStringWithCanonicalMapping
                guard names.insert(normalizedName).inserted else { throw SyncFailure.invalidInput }
                skipWhitespace()
                try expect(58)
                fields.append((name, try parseValue()))
                skipWhitespace()
                if consumeIf(125) { return .object(fields) }
                try expect(44)
            }
        }

        private mutating func parseArray() throws -> Value {
            try expect(91)
            depth += 1
            defer { depth -= 1 }
            skipWhitespace()
            if consumeIf(93) { return .array([]) }

            var values: [Value] = []
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
                        decoded = try JSONSerialization.jsonObject(
                            with: raw,
                            options: [.fragmentsAllowed]
                        )
                    } catch {
                        throw SyncFailure.invalidInput
                    }
                    guard let value = decoded as? String else { throw SyncFailure.invalidInput }
                    return value
                }
                if byte < 0x20 && !escaped { throw SyncFailure.invalidInput }
                if byte == 92 && !escaped { escaped = true } else { escaped = false }
            }
            throw SyncFailure.invalidInput
        }

        private mutating func parseNumber() throws -> String {
            let start = index
            _ = consumeIf(45)
            if consumeIf(48) {
                if index < bytes.count, (48...57).contains(bytes[index]) {
                    throw SyncFailure.invalidInput
                }
            } else {
                guard index < bytes.count, (49...57).contains(bytes[index]) else {
                    throw SyncFailure.invalidInput
                }
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            }
            if consumeIf(46) {
                guard index < bytes.count, (48...57).contains(bytes[index]) else {
                    throw SyncFailure.invalidInput
                }
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
                index += 1
                _ = consumeIf(43) || consumeIf(45)
                guard index < bytes.count, (48...57).contains(bytes[index]) else {
                    throw SyncFailure.invalidInput
                }
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let number = Double(raw), number.isFinite else { throw SyncFailure.invalidInput }
            return raw
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard index < bytes.count, bytes[index] == byte else { throw SyncFailure.invalidInput }
            index += 1
        }

        private mutating func consume(_ sequence: [UInt8]) throws {
            guard index + sequence.count <= bytes.count,
                  bytes[index..<(index + sequence.count)].elementsEqual(sequence) else {
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
            while index < bytes.count,
                  bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 || bytes[index] == 32 {
                index += 1
            }
        }
    }

    static func canonicalize(_ data: Data, maximumBytes: Int) throws -> Data {
        guard data.count <= maximumBytes else { throw SyncFailure.capacity }
        var parser = Parser(data: data)
        let value = try parser.parse()
        let result = Data(try write(value).utf8)
        guard result.count <= maximumBytes else { throw SyncFailure.capacity }
        return result
    }

    private static func write(_ value: Value) throws -> String {
        switch value {
        case .null: return "null"
        case .boolean(let value): return value ? "true" : "false"
        case .number(let value):
            guard let number = Double(value), number.isFinite else { throw SyncFailure.invalidInput }
            if value.contains(".") || value.contains("e") || value.contains("E") {
                return number.description
            }
            return value
        case .string(let value):
            let normalized = value.precomposedStringWithCanonicalMapping
            let encoded = try JSONSerialization.data(withJSONObject: [normalized])
            guard encoded.count >= 2 else { throw SyncFailure.invalidInput }
            return String(decoding: encoded.dropFirst().dropLast(), as: UTF8.self)
        case .array(let values):
            return "[" + (try values.map(write).joined(separator: ",")) + "]"
        case .object(let fields):
            let sorted = fields.sorted {
                Array($0.0.utf16).lexicographicallyPrecedes(Array($1.0.utf16))
            }
            let body = try sorted.map { key, value in
                let encodedKey = try write(.string(key))
                return encodedKey + ":" + (try write(value))
            }.joined(separator: ",")
            return "{" + body + "}"
        }
    }
}
