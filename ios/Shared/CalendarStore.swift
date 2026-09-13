import Foundation

public enum CalendarStoreError: Error, Equatable, Sendable {
    case invalidAppGroupIdentifier
}

public enum CalendarStoreURL {
    /// Local app fallback; unlike an App Group this does not claim widget sharing.
    public static func localURL(baseDirectory: URL? = nil, fileName: String = "calendar.json", fileManager: FileManager = .default) -> URL {
        let base = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LifeOS", isDirectory: true)
        return base.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func appGroupURL(identifier: String, fileName: String = "calendar.json", fileManager: FileManager = .default) throws -> URL {
        guard let value = AppGroupConfiguration.validatedIdentifier(identifier),
              let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: value) else {
            throw CalendarStoreError.invalidAppGroupIdentifier
        }
        return url.appendingPathComponent(fileName, isDirectory: false)
    }
}

public actor CalendarStore {
    public let url: URL
    private let fileManager: FileManager
    // This is an internal test seam used to make coordinator overlap
    // deterministic. It runs before the actor takes its synchronous
    // read/modify/write section; production stores leave it nil.
    private let beforeMutation: (@Sendable () async throws -> Void)?
    private var cached: CalendarSnapshot?

    public init(
        url: URL,
        fileManager: FileManager = .default,
        beforeMutation: (@Sendable () async throws -> Void)? = nil
    ) {
        self.url = url
        self.fileManager = fileManager
        self.beforeMutation = beforeMutation
    }

    public func load() throws -> CalendarSnapshot {
        guard fileManager.fileExists(atPath: url.path) else { let empty = CalendarSnapshot(); cached = empty; return empty }
        let data = try Data(contentsOf: url)
        guard data.count <= CalendarSnapshot.maximumEncodedBytes else {
            throw CalendarSnapshotError.payloadTooLarge
        }
        let snapshot = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: data)
        cached = snapshot; return snapshot
    }

    @discardableResult
    public func save(_ snapshot: CalendarSnapshot) throws -> CalendarSnapshot {
        try snapshot.validatedForPersistence()
        let data = try JSONEncoder.calendar.encode(snapshot)
        guard data.count <= CalendarSnapshot.maximumEncodedBytes else {
            throw CalendarSnapshotError.payloadTooLarge
        }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
#if os(iOS)
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: temporary, options: .atomic)
#endif
        if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temporary) } else { try fileManager.moveItem(at: temporary, to: url) }
        cached = snapshot; return snapshot
    }

    /// Applies one read/modify/write transaction against the latest durable
    /// snapshot. The mutation itself and the subsequent save contain no
    /// suspension points, so actor reentrancy cannot allow two callers to
    /// derive candidates from the same old snapshot.
    public func mutate(
        _ mutation: @Sendable (CalendarSnapshot) throws -> CalendarSnapshot
    ) async throws -> CalendarSnapshot {
        try await beforeMutation?()
        let current = try load()
        return try save(try mutation(current))
    }

    public func merge(_ remote: CalendarSnapshot) throws -> CalendarSnapshot {
        try merge(remote, authorizedBy: nil, token: nil)
    }

    func merge(
        _ remote: CalendarSnapshot,
        authorizedBy peerFence: CalendarPeerMutationFence?,
        token: CalendarPeerMutationFence.Token?
    ) throws -> CalendarSnapshot {
        let operation = { [self] in
            try remote.validatedForPersistence()
            let current = try self.load()
            let merged = current.merged(with: remote)
            guard merged != current else { return current }
            return try self.save(merged)
        }
        guard let peerFence else {
            return try operation()
        }
        guard let token else { throw CalendarPeerMutationFenceError.revoked }
        return try peerFence.withAuthorizedCommit(token, operation)
    }
}

private enum CalendarDateCoding {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(.+T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$"#
    )

    static func encode(_ date: Date, to encoder: Encoder) throws {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else {
            throw EncodingError.invalidValue(
                date,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid calendar timestamp")
            )
        }
        var wholeSeconds = floor(seconds)
        var nanoseconds = Int(((seconds - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds >= 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }
        let base = formatter().string(from: Date(timeIntervalSince1970: wholeSeconds))
        var fraction = String(format: "%09d", nanoseconds)
        while fraction.last == "0" { fraction.removeLast() }
        let value = fraction.isEmpty
            ? base
            : base.replacingOccurrences(of: "Z", with: ".\(fraction)Z")
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    static func decode(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let range = NSRange(location: 0, length: (raw as NSString).length)
        guard let match = pattern.firstMatch(in: raw, range: range),
              let baseRange = Range(match.range(at: 1), in: raw),
              let zoneRange = Range(match.range(at: 3), in: raw),
              let baseDate = formatter().date(from: String(raw[baseRange]) + String(raw[zoneRange])) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 calendar timestamp"
            )
        }

        var fraction = 0.0
        if match.range(at: 2).location != NSNotFound,
           let fractionRange = Range(match.range(at: 2), in: raw) {
            let digits = String(raw[fractionRange].prefix(9))
            guard let parsed = Double("0.\(digits)") else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 fractional timestamp"
                )
            }
            fraction = parsed
        }
        return baseDate.addingTimeInterval(fraction)
    }
}

extension JSONEncoder {
    static var calendar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, nestedEncoder in
            try CalendarDateCoding.encode(date, to: nestedEncoder)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var calendar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { nestedDecoder in
            try CalendarDateCoding.decode(from: nestedDecoder)
        }
        return decoder
    }
}
