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
        try remote.validatedForPersistence()
        let current = try load()
        let merged = current.merged(with: remote)
        guard merged != current else { return current }
        return try save(merged)
    }
}

extension JSONEncoder {
    static var calendar: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
}

extension JSONDecoder {
    static var calendar: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
