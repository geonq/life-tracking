import Foundation

public enum UsageRegistryPreferencesError: Error, Equatable, LocalizedError, Sendable {
    case invalidState
    case loadFailed
    case saveFailed
    case registryRebuildFailed

    public var errorDescription: String? {
        switch self {
        case .invalidState: return "Usage display preferences are invalid."
        case .loadFailed: return "Usage display preferences could not be loaded."
        case .saveFailed: return "Usage display preferences could not be saved."
        case .registryRebuildFailed: return "Usage display preferences could not be applied to the Usage registry."
        }
    }
}

/// Versioned, bounded display preferences. This type intentionally contains
/// only visibility, pinning, and order; it cannot persist observations or
/// authentication material.
public struct UsageRegistryPreferencesState: Codable, Equatable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maximumConnectionIDs = 32

    public let version: Int
    public let hiddenConnectionIDs: Set<UsageConnectionID>
    public let pinnedConnectionIDs: Set<UsageConnectionID>
    /// False means the reviewed connection defaults are still active. Once a
    /// user saves the management sheet, this becomes the sole authority for
    /// pinning, including the meaningful empty set (everything unpinned).
    public let pinningConfigured: Bool
    public let orderedConnectionIDs: [UsageConnectionID]

    public init(
        version: Int = currentVersion,
        hiddenConnectionIDs: Set<UsageConnectionID> = [],
        pinnedConnectionIDs: Set<UsageConnectionID> = [],
        pinningConfigured: Bool = false,
        orderedConnectionIDs: [UsageConnectionID] = []
    ) throws {
        guard version == Self.currentVersion,
              hiddenConnectionIDs.count <= Self.maximumConnectionIDs,
              pinnedConnectionIDs.count <= Self.maximumConnectionIDs,
              orderedConnectionIDs.count <= Self.maximumConnectionIDs,
              Set(orderedConnectionIDs).count == orderedConnectionIDs.count else {
            throw UsageRegistryPreferencesError.invalidState
        }
        self.version = version
        self.hiddenConnectionIDs = hiddenConnectionIDs
        self.pinnedConnectionIDs = pinnedConnectionIDs
        self.pinningConfigured = pinningConfigured
        self.orderedConnectionIDs = orderedConnectionIDs
    }

    public static let empty: UsageRegistryPreferencesState = {
        do {
            return try UsageRegistryPreferencesState()
        } catch {
            preconditionFailure("The empty Usage preferences state must be valid")
        }
    }()

    public func validate() throws {
        guard version == Self.currentVersion,
              hiddenConnectionIDs.count <= Self.maximumConnectionIDs,
              pinnedConnectionIDs.count <= Self.maximumConnectionIDs,
              orderedConnectionIDs.count <= Self.maximumConnectionIDs,
              Set(orderedConnectionIDs).count == orderedConnectionIDs.count else {
            throw UsageRegistryPreferencesError.invalidState
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, hiddenConnectionIDs, pinnedConnectionIDs, pinningConfigured, orderedConnectionIDs
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let hidden = try container.decode(Set<UsageConnectionID>.self, forKey: .hiddenConnectionIDs)
        let pinned = try container.decode(Set<UsageConnectionID>.self, forKey: .pinnedConnectionIDs)
        let pinningConfigured = try container.decodeIfPresent(Bool.self, forKey: .pinningConfigured) ?? false
        let ordered = try container.decode([UsageConnectionID].self, forKey: .orderedConnectionIDs)
        try self.init(
            version: version,
            hiddenConnectionIDs: hidden,
            pinnedConnectionIDs: pinned,
            pinningConfigured: pinningConfigured,
            orderedConnectionIDs: ordered
        )
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(hiddenConnectionIDs.sorted(), forKey: .hiddenConnectionIDs)
        try container.encode(pinnedConnectionIDs.sorted(), forKey: .pinnedConnectionIDs)
        try container.encode(pinningConfigured, forKey: .pinningConfigured)
        try container.encode(orderedConnectionIDs, forKey: .orderedConnectionIDs)
    }

    public func replacing(
        hiddenConnectionIDs: Set<UsageConnectionID>? = nil,
        pinnedConnectionIDs: Set<UsageConnectionID>? = nil,
        pinningConfigured: Bool? = nil,
        orderedConnectionIDs: [UsageConnectionID]? = nil
    ) throws -> UsageRegistryPreferencesState {
        try UsageRegistryPreferencesState(
            version: version,
            hiddenConnectionIDs: hiddenConnectionIDs ?? self.hiddenConnectionIDs,
            pinnedConnectionIDs: pinnedConnectionIDs ?? self.pinnedConnectionIDs,
            pinningConfigured: pinningConfigured ?? self.pinningConfigured,
            orderedConnectionIDs: orderedConnectionIDs ?? self.orderedConnectionIDs
        )
    }
}

public protocol UsageRegistryPreferencesPersisting {
    func load() throws -> UsageRegistryPreferencesState
    func save(_ state: UsageRegistryPreferencesState) throws
}

public final class UserDefaultsUsageRegistryPreferencesStore: UsageRegistryPreferencesPersisting {
    public static let key = "LifeOS.usage.registryPreferences.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> UsageRegistryPreferencesState {
        guard let data = defaults.data(forKey: Self.key) else { return .empty }
        guard data.count <= 32 * 1024 else {
            throw UsageRegistryPreferencesError.loadFailed
        }
        do {
            return try JSONDecoder.lifeOS.decode(UsageRegistryPreferencesState.self, from: data)
        } catch {
            throw UsageRegistryPreferencesError.loadFailed
        }
    }

    public func save(_ state: UsageRegistryPreferencesState) throws {
        do {
            try state.validate()
            let data = try JSONEncoder.lifeOS.encode(state)
            guard data.count <= 32 * 1024 else { throw UsageRegistryPreferencesError.saveFailed }
            defaults.set(data, forKey: Self.key)
            guard defaults.data(forKey: Self.key) == data else {
                throw UsageRegistryPreferencesError.saveFailed
            }
        } catch let error as UsageRegistryPreferencesError {
            throw error
        } catch {
            throw UsageRegistryPreferencesError.saveFailed
        }
    }
}

/// An in-memory store keeps coordinator tests deterministic and proves that
/// preference changes do not require a network refresh.
public final class InMemoryUsageRegistryPreferencesStore: UsageRegistryPreferencesPersisting {
    public var state: UsageRegistryPreferencesState
    public var loadError: UsageRegistryPreferencesError?
    public var saveError: UsageRegistryPreferencesError?

    public init(state: UsageRegistryPreferencesState = .empty) {
        self.state = state
    }

    public func load() throws -> UsageRegistryPreferencesState {
        if let loadError { throw loadError }
        return state
    }

    public func save(_ state: UsageRegistryPreferencesState) throws {
        if let saveError { throw saveError }
        try state.validate()
        self.state = state
    }
}
