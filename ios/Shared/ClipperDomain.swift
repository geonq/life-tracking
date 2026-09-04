import Foundation
import CryptoKit

public enum ClipperPayloadError: Error, Equatable, Sendable {
    case payloadTooLarge
    case invalidJSON
    case duplicateJSONKey
}

public enum ClipperPayloadLimits {
    public static let maximumSnapshotBytes = 1 * 1024 * 1024
    public static let maximumSecretReadBytes = 4 * 1024
    public static let minimumSecretCharacters = 32
    public static let maximumSecretCharacters = 256
    public static let maximumReplayKeys = 10_000
    public static let maximumClockSkew: TimeInterval = 5
    public static let freshnessWindow: TimeInterval = 15 * 60
}

/// Foundation's JSONDecoder does not reject duplicate object keys. The
/// uploader and the native boundary use this small syntax scanner before
/// decoding so an ambiguous payload cannot change meaning between platforms.
enum ClipperJSONBoundary {
    static func validate(_ data: Data) throws {
        guard data.count <= ClipperPayloadLimits.maximumSnapshotBytes else {
            throw ClipperPayloadError.payloadTooLarge
        }
        var scanner = Scanner(bytes: Array(data))
        try scanner.scanValue()
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { throw ClipperPayloadError.invalidJSON }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index: Int = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count && [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func scanValue() throws {
            skipWhitespace()
            guard index < bytes.count else { throw ClipperPayloadError.invalidJSON }
            switch bytes[index] {
            case 0x7b: try scanObject() // {
            case 0x5b: try scanArray() // [
            case 0x22: _ = try scanString()
            case 0x74: try scanLiteral("true")
            case 0x66: try scanLiteral("false")
            case 0x6e: try scanLiteral("null")
            case 0x2d, 0x30...0x39: try scanNumber()
            default: throw ClipperPayloadError.invalidJSON
            }
        }

        mutating func scanObject() throws {
            index += 1
            skipWhitespace()
            if consume(0x7d) { return } // }

            var keys = Set<String>()
            while true {
                skipWhitespace()
                let key = try scanString()
                guard keys.insert(key).inserted else {
                    throw ClipperPayloadError.duplicateJSONKey
                }
                skipWhitespace()
                guard consume(0x3a) else { throw ClipperPayloadError.invalidJSON } // :
                try scanValue()
                skipWhitespace()
                if consume(0x7d) { return } // }
                guard consume(0x2c) else { throw ClipperPayloadError.invalidJSON } // ,
            }
        }

        mutating func scanArray() throws {
            index += 1
            skipWhitespace()
            if consume(0x5d) { return } // ]
            while true {
                try scanValue()
                skipWhitespace()
                if consume(0x5d) { return } // ]
                guard consume(0x2c) else { throw ClipperPayloadError.invalidJSON } // ,
            }
        }

        mutating func scanString() throws -> String {
            guard consume(0x22) else { throw ClipperPayloadError.invalidJSON } // "
            let start = index - 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    let raw = Data(bytes[start..<index])
                    guard let object = try? JSONSerialization.jsonObject(
                        with: raw, options: [.fragmentsAllowed]
                    ), let value = object as? String else {
                        throw ClipperPayloadError.invalidJSON
                    }
                    return value
                }
                if byte < 0x20 { throw ClipperPayloadError.invalidJSON }
                if byte == 0x5c { // \
                    index += 1
                    guard index < bytes.count else { throw ClipperPayloadError.invalidJSON }
                    switch bytes[index] {
                    case 0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74:
                        index += 1
                    case 0x75:
                        guard index + 4 < bytes.count,
                              (index + 1...index + 4).allSatisfy({ isHex(bytes[$0]) }) else {
                            throw ClipperPayloadError.invalidJSON
                        }
                        index += 5
                    default: throw ClipperPayloadError.invalidJSON
                    }
                } else {
                    index += 1
                }
            }
            throw ClipperPayloadError.invalidJSON
        }

        mutating func scanLiteral(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<index + expected.count]) == expected else {
                throw ClipperPayloadError.invalidJSON
            }
            index += expected.count
        }

        mutating func scanNumber() throws {
            let start = index
            if consume(0x2d) { }
            guard index < bytes.count else { throw ClipperPayloadError.invalidJSON }
            if consume(0x30) {
                if index < bytes.count, bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                    throw ClipperPayloadError.invalidJSON
                }
            } else {
                guard consumeDigit(nonZero: true) else { throw ClipperPayloadError.invalidJSON }
                while consumeDigit(nonZero: false) { }
            }
            if consume(0x2e) {
                guard consumeDigit(nonZero: false) else { throw ClipperPayloadError.invalidJSON }
                while consumeDigit(nonZero: false) { }
            }
            if index < bytes.count, bytes[index] == 0x65 || (index < bytes.count && bytes[index] == 0x45) {
                index += 1
                if index < bytes.count, bytes[index] == 0x2b || (index < bytes.count && bytes[index] == 0x2d) {
                    index += 1
                }
                guard consumeDigit(nonZero: false) else { throw ClipperPayloadError.invalidJSON }
                while consumeDigit(nonZero: false) { }
            }
            guard index > start else { throw ClipperPayloadError.invalidJSON }
        }

        mutating func consume(_ expected: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == expected else { return false }
            index += 1
            return true
        }

        mutating func consumeDigit(nonZero: Bool) -> Bool {
            guard index < bytes.count else { return false }
            let byte = bytes[index]
            let valid = nonZero ? (0x31...0x39).contains(byte) : (0x30...0x39).contains(byte)
            if valid { index += 1 }
            return valid
        }

        private func isHex(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

public enum ClipperSecretFileValidation: String, Codable, Equatable, Sendable {
    case valid
    case missing
    case unreadable
    case notRegular
    case insecurePermissions
    case tooLarge
    case invalidShape
}

/// Validates the Hermes handoff secret without returning or persisting its
/// contents. The native app does not need this secret for read-only summary
/// access; this helper exists to keep the file boundary explicit and safe.
public enum ClipperSecretFilePolicy {
    public static func validate(data: Data, permissions: UInt16? = nil) -> ClipperSecretFileValidation {
        if let permissions, permissions != 0o600 { return .insecurePermissions }
        guard data.count <= ClipperPayloadLimits.maximumSecretReadBytes else { return .tooLarge }
        guard data.count >= ClipperPayloadLimits.minimumSecretCharacters,
              data.count <= ClipperPayloadLimits.maximumSecretCharacters,
              data.allSatisfy({ (0x21...0x7e).contains($0) }) else { return .invalidShape }
        return .valid
    }

    public static func validateFile(at url: URL,
                                    fileManager: FileManager = .default) -> ClipperSecretFileValidation {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            return .missing
        }
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular else {
            return .notRegular
        }
        guard let rawPermissions = attributes[FileAttributeKey.posixPermissions] as? NSNumber else {
            return .insecurePermissions
        }
        guard rawPermissions.uint16Value == 0o600 else { return .insecurePermissions }
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= ClipperPayloadLimits.maximumSecretReadBytes else { return .tooLarge }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return validate(data: data, permissions: rawPermissions.uint16Value)
        } catch {
            return .unreadable
        }
    }
}

public enum ClipperReplayDecision: String, Codable, Equatable, Sendable {
    case accepted
    case replay
    case stale
    case unavailable
    case revoked
}

/// Bounded native replay identity. It stores only canonical payload digests,
/// never Clipper values or the Hermes secret.
public struct ClipperReplayLedger: Codable, Equatable, Sendable {
    public private(set) var acceptedKeys: [String]
    public private(set) var isRevoked: Bool

    public init(acceptedKeys: [String] = [], isRevoked: Bool = false) {
        self.acceptedKeys = Array(acceptedKeys.suffix(ClipperPayloadLimits.maximumReplayKeys))
        self.isRevoked = isRevoked
    }

    public mutating func accept(snapshotData: Data, now: Date = .now) throws -> ClipperReplayDecision {
        let snapshot = try ClipperSnapshot.decode(snapshotData, now: now)
        return try accept(snapshot: snapshot, now: now)
    }

    public mutating func accept(snapshot: ClipperSnapshot, now: Date = .now) throws -> ClipperReplayDecision {
        if isRevoked { return .revoked }
        guard snapshot.availability == .observed else { return .unavailable }
        let generatedAge = now.timeIntervalSince(snapshot.generatedAt)
        let observedAge = now.timeIntervalSince(snapshot.provenance.observedAt)
        guard generatedAge >= -ClipperPayloadLimits.maximumClockSkew,
              observedAge >= -ClipperPayloadLimits.maximumClockSkew else {
            throw ClipperPayloadError.invalidJSON
        }
        guard snapshot.provenance.freshness == .fresh,
              generatedAge <= ClipperPayloadLimits.freshnessWindow,
              observedAge <= ClipperPayloadLimits.freshnessWindow else {
            return .stale
        }

        let key = try ClipperPayloadIdentity.idempotencyKey(for: snapshot)
        if acceptedKeys.contains(key) { return .replay }
        acceptedKeys.append(key)
        if acceptedKeys.count > ClipperPayloadLimits.maximumReplayKeys {
            acceptedKeys.removeFirst(acceptedKeys.count - ClipperPayloadLimits.maximumReplayKeys)
        }
        return .accepted
    }

    public mutating func revoke() {
        isRevoked = true
        acceptedKeys.removeAll(keepingCapacity: false)
    }

    public mutating func clearRevocation() {
        isRevoked = false
    }
}

public enum ClipperPayloadIdentity {
    public static func canonicalData(_ data: Data) throws -> Data {
        try ClipperJSONBoundary.validate(data)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ClipperPayloadError.invalidJSON
        }
        guard object is [String: Any] else { throw ClipperPayloadError.invalidJSON }
        do {
            let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard canonical.count <= ClipperPayloadLimits.maximumSnapshotBytes else {
                throw ClipperPayloadError.payloadTooLarge
            }
            return canonical
        } catch let error as ClipperPayloadError {
            throw error
        } catch {
            throw ClipperPayloadError.invalidJSON
        }
    }

    public static func canonicalData(for snapshot: ClipperSnapshot) throws -> Data {
        let encoded = try JSONEncoder.lifeOS.encode(snapshot)
        return try canonicalData(encoded)
    }

    public static func idempotencyKey(for data: Data) throws -> String {
        let canonical = try canonicalData(data)
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return "hermes-" + digest
    }

    public static func idempotencyKey(for snapshot: ClipperSnapshot) throws -> String {
        try idempotencyKey(for: canonicalData(for: snapshot))
    }
}

private let clipperMaximumClockSkew: TimeInterval = 5
private let clipperFreshnessWindow: TimeInterval = 15 * 60
private let clipperMaximumCents = 9_007_199_254_740_991
private let clipperConnectorStates: Set<ConnectorState> = [
    .healthy, .refreshDue, .reauthRequired, .revoked, .rateLimited, .unavailable
]

public enum ClipperMetricAvailability: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
}

public enum ClipperPayloadFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unknown
}

public enum ClipperPayloadQuality: String, Codable, Equatable, Sendable {
    case observed
    case partial
    case unavailable
}

public struct ClipperPayloadProvenance: Codable, Equatable, Sendable {
    public let source: String
    public let observedAt: Date
    public let freshness: ClipperPayloadFreshness
    public let quality: ClipperPayloadQuality
    public let connectorState: ConnectorState

    private enum CodingKeys: String, CodingKey {
        case source, observedAt, freshness, quality, connectorState
    }

    public init(source: String, observedAt: Date, freshness: ClipperPayloadFreshness,
                quality: ClipperPayloadQuality, connectorState: ConnectorState) {
        self.source = source
        self.observedAt = observedAt
        self.freshness = freshness
        self.quality = quality
        self.connectorState = connectorState
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "source", "observedAt", "freshness", "quality", "connectorState"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        freshness = try container.decode(ClipperPayloadFreshness.self, forKey: .freshness)
        quality = try container.decode(ClipperPayloadQuality.self, forKey: .quality)
        connectorState = try container.decode(ConnectorState.self, forKey: .connectorState)

        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        let age = now.timeIntervalSince(observedAt)
        let expectedFreshness: ClipperPayloadFreshness? = age < -clipperMaximumClockSkew
            ? nil
            : age <= clipperFreshnessWindow ? .fresh : .stale
        let isUnavailable = quality == .unavailable
        let connectorIsLive = connectorState == .healthy || connectorState == .refreshDue
        let expectedConnector: ConnectorState? = expectedFreshness == .fresh
            ? .healthy
            : expectedFreshness == .stale ? .refreshDue : nil
        let valid = !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && clipperConnectorStates.contains(connectorState)
            && expectedFreshness != nil
            && (isUnavailable
                ? freshness == .unknown && !connectorIsLive
                : freshness == expectedFreshness && connectorState == expectedConnector)
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .source, in: container,
                debugDescription: "Clipper provenance is contradictory or unsafe"
            )
        }
    }
}

public struct ClipperCountMetric: Codable, Equatable, Sendable {
    public let availability: ClipperMetricAvailability
    public let value: Int?
    public let provenance: ClipperPayloadProvenance

    private enum CodingKeys: String, CodingKey { case availability, value, provenance }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["availability", "value", "provenance"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(ClipperMetricAvailability.self, forKey: .availability)
        let hasValue = container.contains(.value)
        value = try container.decodeIfPresent(Int.self, forKey: .value)
        provenance = try container.decode(ClipperPayloadProvenance.self, forKey: .provenance)
        let live = provenance.connectorState == .healthy || provenance.connectorState == .refreshDue
        let valid: Bool
        switch availability {
        case .observed:
            valid = hasValue && value.map { $0 >= 0 && $0 <= clipperMaximumCents } == true
                && provenance.quality == .observed && live
        case .unavailable:
            valid = !hasValue && value == nil && provenance.quality == .unavailable && !live
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability, in: container,
                debugDescription: "Clipper count availability and value are inconsistent"
            )
        }
    }
}

public struct ClipperRevenueMetric: Codable, Equatable, Sendable {
    public let availability: ClipperMetricAvailability
    public let amountCents: Int?
    public let currency: String
    public let provenance: ClipperPayloadProvenance

    private enum CodingKeys: String, CodingKey { case availability, amountCents, currency, provenance }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["availability", "amountCents", "currency", "provenance"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(ClipperMetricAvailability.self, forKey: .availability)
        let hasAmount = container.contains(.amountCents)
        amountCents = try container.decodeIfPresent(Int.self, forKey: .amountCents)
        currency = try container.decode(String.self, forKey: .currency)
        provenance = try container.decode(ClipperPayloadProvenance.self, forKey: .provenance)
        let live = provenance.connectorState == .healthy || provenance.connectorState == .refreshDue
        let valid: Bool
        switch availability {
        case .observed:
            valid = currency == "EUR" && hasAmount
                && amountCents.map { $0 >= 0 && $0 <= clipperMaximumCents } == true
                && provenance.quality == .observed && live
        case .unavailable:
            valid = currency == "EUR" && !hasAmount && amountCents == nil
                && provenance.quality == .unavailable && !live
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability, in: container,
                debugDescription: "Clipper revenue availability, currency, or amount is invalid"
            )
        }
    }
}

public struct ClipperMetricSet: Codable, Equatable, Sendable {
    public let views: ClipperCountMetric
    public let subscribers: ClipperCountMetric
    public let revenue: ClipperRevenueMetric

    private enum CodingKeys: String, CodingKey { case views, subscribers, revenue }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["views", "subscribers", "revenue"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        views = try container.decode(ClipperCountMetric.self, forKey: .views)
        subscribers = try container.decode(ClipperCountMetric.self, forKey: .subscribers)
        revenue = try container.decode(ClipperRevenueMetric.self, forKey: .revenue)
    }

    public var hasObservedMetric: Bool {
        views.availability == .observed || subscribers.availability == .observed || revenue.availability == .observed
    }
}

private func clipperMetricObservationDates(_ metrics: ClipperMetricSet) -> [Date] {
    [
        metrics.views.provenance.observedAt,
        metrics.subscribers.provenance.observedAt,
        metrics.revenue.provenance.observedAt
    ]
}

private func clipperHasObservedDetail(_ account: ClipperAccount) -> Bool {
    account.metrics.hasObservedMetric
        || account.bots.contains { bot in
            bot.metrics.hasObservedMetric
                || bot.breakdowns.contains { $0.metrics.hasObservedMetric }
        }
        || account.breakdowns.contains { $0.metrics.hasObservedMetric }
}

public struct ClipperTrendPoint: Codable, Equatable, Identifiable, Sendable {
    public let at: Date
    public let metrics: ClipperMetricSet
    public var id: Date { at }

    private enum CodingKeys: String, CodingKey { case at, metrics }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["at", "metrics"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Date.self, forKey: .at)
        metrics = try container.decode(ClipperMetricSet.self, forKey: .metrics)
        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        guard at <= now.addingTimeInterval(clipperMaximumClockSkew) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "Future Clipper trend point")
        }
    }
}

public struct ClipperBreakdown: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let periodStart: Date
    public let periodEnd: Date
    public let metrics: ClipperMetricSet

    private enum CodingKeys: String, CodingKey { case id, label, periodStart, periodEnd, metrics }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["id", "label", "periodStart", "periodEnd", "metrics"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        periodStart = try container.decode(Date.self, forKey: .periodStart)
        periodEnd = try container.decode(Date.self, forKey: .periodEnd)
        metrics = try container.decode(ClipperMetricSet.self, forKey: .metrics)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              periodEnd > periodStart else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid Clipper breakdown")
        }
    }
}

public struct ClipperBot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let metrics: ClipperMetricSet
    public let breakdowns: [ClipperBreakdown]

    private enum CodingKeys: String, CodingKey { case id, name, metrics, breakdowns }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["id", "name", "metrics", "breakdowns"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        metrics = try container.decode(ClipperMetricSet.self, forKey: .metrics)
        breakdowns = try container.decode([ClipperBreakdown].self, forKey: .breakdowns)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(breakdowns.map(\.id)).count == breakdowns.count else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid or duplicate Clipper bot data")
        }
    }
}

public struct ClipperAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let metrics: ClipperMetricSet
    public let bots: [ClipperBot]
    public let breakdowns: [ClipperBreakdown]

    private enum CodingKeys: String, CodingKey { case id, name, metrics, bots, breakdowns }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["id", "name", "metrics", "bots", "breakdowns"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        metrics = try container.decode(ClipperMetricSet.self, forKey: .metrics)
        bots = try container.decode([ClipperBot].self, forKey: .bots)
        breakdowns = try container.decode([ClipperBreakdown].self, forKey: .breakdowns)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(bots.map(\.id)).count == bots.count,
              Set(breakdowns.map(\.id)).count == breakdowns.count else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid or duplicate Clipper account data")
        }
    }
}

public enum ClipperSnapshotAvailability: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
}

public enum ClipperApprovedField: String, CaseIterable, Hashable, Sendable {
    case views = "metrics.views"
    case subscribers = "metrics.subscribers"
    case revenue = "metrics.revenue"
    case accounts
    case trends
    case breakdowns
}

/// Explicit operator decision required before an observed Clipper payload can
/// enter the presentation layer. An empty or absent approval is a hard stop;
/// the native app never infers authority from a non-empty payload.
public struct ClipperSourceApproval: Equatable, Sendable {
    public let source: String
    public let fields: Set<ClipperApprovedField>

    public init(source: String, fields: Set<ClipperApprovedField>) {
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fields = fields
    }

    public var isUsable: Bool {
        !source.isEmpty && !fields.isEmpty
    }

    public func permits(_ snapshot: ClipperSnapshot) -> Bool {
        guard snapshot.availability == .observed,
              !source.isEmpty,
              snapshot.provenance.source == source,
              !snapshot.observedFieldIDs.isEmpty else {
            return false
        }
        return snapshot.observedFieldIDs.isSubset(of: fields)
    }
}

public struct ClipperSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let availability: ClipperSnapshotAvailability
    public let generatedAt: Date
    public let currency: String
    public let metrics: ClipperMetricSet?
    public let accounts: [ClipperAccount]?
    public let trends: [ClipperTrendPoint]?
    public let breakdowns: [ClipperBreakdown]?
    public let provenance: ClipperPayloadProvenance

    public var observedFieldIDs: Set<ClipperApprovedField> {
        var fields = Set<ClipperApprovedField>()
        if let metrics {
            if metrics.views.availability == .observed { fields.insert(.views) }
            if metrics.subscribers.availability == .observed { fields.insert(.subscribers) }
            if metrics.revenue.availability == .observed { fields.insert(.revenue) }
        }
        if accounts?.contains(where: clipperHasObservedDetail) == true { fields.insert(.accounts) }
        if trends?.contains(where: { $0.metrics.hasObservedMetric }) == true { fields.insert(.trends) }
        if breakdowns?.contains(where: { $0.metrics.hasObservedMetric }) == true { fields.insert(.breakdowns) }
        return fields
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, availability, generatedAt, currency, metrics, accounts, trends, breakdowns, provenance
    }

    private init(schemaVersion: Int, availability: ClipperSnapshotAvailability, generatedAt: Date,
                 currency: String, metrics: ClipperMetricSet?, accounts: [ClipperAccount]?,
                 trends: [ClipperTrendPoint]?, breakdowns: [ClipperBreakdown]?,
                 provenance: ClipperPayloadProvenance) {
        self.schemaVersion = schemaVersion
        self.availability = availability
        self.generatedAt = generatedAt
        self.currency = currency
        self.metrics = metrics
        self.accounts = accounts
        self.trends = trends
        self.breakdowns = breakdowns
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "schemaVersion", "availability", "generatedAt", "currency", "metrics", "accounts", "trends", "breakdowns", "provenance"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        availability = try container.decode(ClipperSnapshotAvailability.self, forKey: .availability)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        currency = try container.decode(String.self, forKey: .currency)
        metrics = try container.decodeIfPresent(ClipperMetricSet.self, forKey: .metrics)
        accounts = try container.decodeIfPresent([ClipperAccount].self, forKey: .accounts)
        trends = try container.decodeIfPresent([ClipperTrendPoint].self, forKey: .trends)
        breakdowns = try container.decodeIfPresent([ClipperBreakdown].self, forKey: .breakdowns)
        provenance = try container.decode(ClipperPayloadProvenance.self, forKey: .provenance)

        let now = decoder.userInfo[.lifeOSNow] as? Date ?? .now
        let live = provenance.connectorState == .healthy || provenance.connectorState == .refreshDue
        let observed = metrics?.hasObservedMetric == true || accounts?.contains(where: clipperHasObservedDetail) == true
        let uniqueAccounts = accounts.map { Set($0.map(\.id)).count == $0.count } ?? true
        let uniqueBreakdowns = breakdowns.map { Set($0.map(\.id)).count == $0.count } ?? true
        let uniqueTrends = trends.map { Set($0.map(\.id)).count == $0.count } ?? true
        var nestedObservationDates = [provenance.observedAt]
        if let metrics {
            nestedObservationDates.append(contentsOf: clipperMetricObservationDates(metrics))
        }
        for account in accounts ?? [] {
            nestedObservationDates.append(contentsOf: clipperMetricObservationDates(account.metrics))
            for bot in account.bots {
                nestedObservationDates.append(contentsOf: clipperMetricObservationDates(bot.metrics))
                for breakdown in bot.breakdowns {
                    nestedObservationDates.append(contentsOf: clipperMetricObservationDates(breakdown.metrics))
                }
            }
            for breakdown in account.breakdowns {
                nestedObservationDates.append(contentsOf: clipperMetricObservationDates(breakdown.metrics))
            }
        }
        for trend in trends ?? [] {
            nestedObservationDates.append(trend.at)
            nestedObservationDates.append(contentsOf: clipperMetricObservationDates(trend.metrics))
        }
        for breakdown in breakdowns ?? [] {
            nestedObservationDates.append(contentsOf: clipperMetricObservationDates(breakdown.metrics))
        }
        let generatedAtCoversNestedObservations = nestedObservationDates.allSatisfy {
            $0 <= generatedAt.addingTimeInterval(clipperMaximumClockSkew)
        }
        let valid: Bool
        switch availability {
        case .observed:
            valid = schemaVersion == 1 && currency == "EUR"
                && metrics != nil && accounts != nil && trends != nil && breakdowns != nil
                && uniqueAccounts && uniqueBreakdowns && uniqueTrends
                && provenance.quality != .unavailable && live && observed
        case .unavailable:
            valid = schemaVersion == 1 && currency == "EUR"
                && metrics == nil && accounts == nil && trends == nil && breakdowns == nil
                && provenance.quality == .unavailable && provenance.freshness == .unknown && !live
        }
        guard generatedAt <= now.addingTimeInterval(clipperMaximumClockSkew), generatedAtCoversNestedObservations, valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability, in: container,
                debugDescription: "Clipper snapshot availability, detail, or provenance is inconsistent"
            )
        }
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> ClipperSnapshot {
        try ClipperJSONBoundary.validate(data)
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(ClipperSnapshot.self, from: data)
    }

    public static func unavailable(at date: Date = .now) -> ClipperSnapshot {
        let provenance = ClipperPayloadProvenance(
            source: "no-authorized-clipper-source", observedAt: date,
            freshness: .unknown, quality: .unavailable, connectorState: .unavailable
        )
        return ClipperSnapshot(
            schemaVersion: 1, availability: .unavailable, generatedAt: date,
            currency: "EUR", metrics: nil, accounts: nil, trends: nil,
            breakdowns: nil, provenance: provenance
        )
    }
}
