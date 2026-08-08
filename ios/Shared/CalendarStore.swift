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
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("group."), !value.contains("$("), !value.contains("REPLACE_WITH"), !value.contains(" "),
              let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: value) else { throw CalendarStoreError.invalidAppGroupIdentifier }
        return url.appendingPathComponent(fileName, isDirectory: false)
    }
}

public actor CalendarStore {
    public let url: URL
    private let fileManager: FileManager
    private var cached: CalendarSnapshot?

    public init(url: URL, fileManager: FileManager = .default) { self.url = url; self.fileManager = fileManager }

    public func load() throws -> CalendarSnapshot {
        guard fileManager.fileExists(atPath: url.path) else { let empty = CalendarSnapshot(); cached = empty; return empty }
        let snapshot = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: Data(contentsOf: url))
        cached = snapshot; return snapshot
    }

    @discardableResult
    public func save(_ snapshot: CalendarSnapshot) throws -> CalendarSnapshot {
        let data = try JSONEncoder.calendar.encode(snapshot)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temporary) } else { try fileManager.moveItem(at: temporary, to: url) }
        cached = snapshot; return snapshot
    }

    public func merge(_ remote: CalendarSnapshot) throws -> CalendarSnapshot {
        let merged = (try load()).merged(with: remote)
        return try save(merged)
    }
}

extension JSONEncoder {
    static var calendar: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
}

extension JSONDecoder {
    static var calendar: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
