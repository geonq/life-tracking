import Foundation

public enum TaskStoreURL {
    /// Local app storage. Tasks are not shared via App Group/widget today,
    /// so this is the only supported location — unlike CalendarStoreURL
    /// there is no app-group variant to keep this module's surface small.
    public static func localURL(baseDirectory: URL? = nil, fileName: String = "tasks.json", fileManager: FileManager = .default) -> URL {
        let base = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LifeOS", isDirectory: true)
        return base.appendingPathComponent(fileName, isDirectory: false)
    }
}

/// Local-only JSON persistence for Tasks, following `CalendarStore`'s
/// atomic write + replace pattern exactly. No network, no peer sync — an
/// absent file is an honest empty list, not a fabricated default.
public actor TaskStore {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> [TaskItem] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let snapshot = try JSONDecoder.lifeOSTasks.decode(TaskSnapshot.self, from: Data(contentsOf: url))
        return snapshot.items
    }

    @discardableResult
    public func save(_ items: [TaskItem]) throws -> [TaskItem] {
        let data = try JSONEncoder.lifeOSTasks.encode(TaskSnapshot(items: items))
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
#if os(iOS)
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: temporary, options: .atomic)
#endif
        if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temporary) } else { try fileManager.moveItem(at: temporary, to: url) }
        return items
    }

    @discardableResult
    public func add(_ item: TaskItem) throws -> [TaskItem] {
        var items = try load()
        items.append(item)
        return try save(items)
    }

    @discardableResult
    public func update(_ item: TaskItem) throws -> [TaskItem] {
        var items = try load()
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return items }
        items[index] = item
        return try save(items)
    }

    @discardableResult
    public func delete(id: UUID) throws -> [TaskItem] {
        var items = try load()
        items.removeAll { $0.id == id }
        return try save(items)
    }

    @discardableResult
    public func toggleComplete(id: UUID, now: Date = .now) throws -> [TaskItem] {
        var items = try load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items }
        items[index].isCompleted.toggle()
        items[index].completedAt = items[index].isCompleted ? now : nil
        return try save(items)
    }

    @discardableResult
    public func setArchived(id: UUID, archived: Bool) throws -> [TaskItem] {
        var items = try load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items }
        items[index].isArchived = archived
        return try save(items)
    }
}

extension JSONEncoder {
    static var lifeOSTasks: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
}

extension JSONDecoder {
    static var lifeOSTasks: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
