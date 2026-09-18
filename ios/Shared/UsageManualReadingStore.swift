import Foundation

public enum UsageManualReadingStoreError: Error, Equatable, LocalizedError, Sendable {
    case payloadTooLarge
    case invalidEnvelope
    case unsupportedProvider
    case unsupportedAdapter
    case invalidWindow
    case duplicateWindow
    case tooManyReadings
    case invalidValue
    case invalidTimestamp
    case futureObservedAt
    case resetBeforeObserved
    case saveFailed
    case deleteFailed

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge: return "The saved manual usage reading is too large."
        case .invalidEnvelope: return "The saved manual usage reading could not be read."
        case .unsupportedProvider: return "This manual usage provider is not reviewed."
        case .unsupportedAdapter: return "This manual usage adapter is not reviewed."
        case .invalidWindow: return "The manual usage window is invalid."
        case .duplicateWindow: return "Only the latest reading for each usage window is supported."
        case .tooManyReadings: return "Too many manual usage readings were supplied."
        case .invalidValue: return "The usage percentage must be between 0 and 100."
        case .invalidTimestamp: return "The manual usage timestamp is invalid."
        case .futureObservedAt: return "The observed time cannot be in the future."
        case .resetBeforeObserved: return "The reset time cannot precede the observed time."
        case .saveFailed: return "The manual usage reading could not be saved."
        case .deleteFailed: return "The manual usage reading could not be deleted."
        }
    }
}

public enum UsageManualReadingWindow: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case fiveHour = "five_hour"
    case weekly = "weekly"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .weekly: return "Weekly"
        }
    }

    public var durationMinutes: Int {
        switch self {
        case .fiveHour: return 300
        case .weekly: return 10_080
        }
    }

    var registryWindowID: String {
        switch self {
        case .fiveHour: return "catalog.gemini_subscription.five_hour"
        case .weekly: return "catalog.gemini_subscription.weekly"
        }
    }
}

public enum UsageManualReadingValueKind: String, CaseIterable, Hashable, Sendable {
    case used
    case remaining

    public var label: String {
        switch self {
        case .used: return "Used %"
        case .remaining: return "Remaining %"
        }
    }
}

public enum UsageManualReadingStatus: String, Equatable, Sendable {
    case recorded
    case needsUpdating = "needs_updating"
}

public struct UsageManualReading: Codable, Equatable, Hashable, Sendable {
    public static let supportedProviderID = "gemini_subscription"
    public static let supportedAdapterID = "gemini_subscription_manual"
    public static let maximumFutureSkew: TimeInterval = 5
    public static let staleAfter: TimeInterval = 15 * 60

    public let providerID: UsageProviderID
    public let adapterID: String
    public let window: UsageManualReadingWindow
    /// The stored representation is always used percentage, even when the
    /// user entered remaining percentage in the sheet.
    public let usedPercent: Double
    public let observedAt: Date
    public let resetAt: Date?

    public init(
        providerID: UsageProviderID,
        adapterID: String,
        window: UsageManualReadingWindow,
        value: Double,
        valueKind: UsageManualReadingValueKind,
        observedAt: Date,
        resetAt: Date? = nil,
        now: Date = .now
    ) throws {
        let usedPercent = try Self.canonicalUsedPercent(value, kind: valueKind)
        try self.init(
            providerID: providerID,
            adapterID: adapterID,
            window: window,
            usedPercent: usedPercent,
            observedAt: observedAt,
            resetAt: resetAt,
            now: now
        )
    }

    public init(
        providerID: UsageProviderID,
        adapterID: String,
        window: UsageManualReadingWindow,
        usedPercent: Double,
        observedAt: Date,
        resetAt: Date? = nil,
        now: Date = .now
    ) throws {
        self.providerID = providerID
        self.adapterID = adapterID
        self.window = window
        self.usedPercent = usedPercent
        self.observedAt = observedAt
        self.resetAt = resetAt
        try validate(now: now)
    }

    public static func canonicalUsedPercent(
        _ value: Double,
        kind: UsageManualReadingValueKind
    ) throws -> Double {
        guard value.isFinite, (0...100).contains(value) else {
            throw UsageManualReadingStoreError.invalidValue
        }
        let usedPercent = kind == .used ? value : 100 - value
        guard usedPercent.isFinite, (0...100).contains(usedPercent) else {
            throw UsageManualReadingStoreError.invalidValue
        }
        return usedPercent
    }

    public func validate(now: Date) throws {
        try validateStructure()
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw UsageManualReadingStoreError.invalidTimestamp
        }
        guard observedAt.timeIntervalSince(now) <= Self.maximumFutureSkew else {
            throw UsageManualReadingStoreError.futureObservedAt
        }
    }

    public func isStale(at now: Date) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              observedAt.timeIntervalSinceReferenceDate.isFinite else { return true }
        let age = now.timeIntervalSince(observedAt)
        if age >= Self.staleAfter { return true }
        if let resetAt, now >= resetAt { return true }
        return false
    }

    public func status(at now: Date) -> UsageManualReadingStatus {
        isStale(at: now) ? .needsUpdating : .recorded
    }

    public func freshness(at now: Date) -> UsageRegistryFreshness {
        if isStale(at: now) { return .stale }
        let age = max(0, now.timeIntervalSince(observedAt))
        return age < Self.staleAfter / 2 ? .fresh : .aging
    }

    private func validateStructure() throws {
        guard providerID.rawValue == Self.supportedProviderID else {
            throw UsageManualReadingStoreError.unsupportedProvider
        }
        guard adapterID == Self.supportedAdapterID else {
            throw UsageManualReadingStoreError.unsupportedAdapter
        }
        guard usedPercent.isFinite, (0...100).contains(usedPercent) else {
            throw UsageManualReadingStoreError.invalidValue
        }
        guard observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw UsageManualReadingStoreError.invalidTimestamp
        }
        if let resetAt {
            guard resetAt.timeIntervalSinceReferenceDate.isFinite else {
                throw UsageManualReadingStoreError.invalidTimestamp
            }
            guard resetAt >= observedAt else {
                throw UsageManualReadingStoreError.resetBeforeObserved
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case providerID
        case adapterID
        case window
        case usedPercent
        case observedAt
        case resetAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = UsageManualReading(
            providerID: try container.decode(UsageProviderID.self, forKey: .providerID),
            adapterID: try container.decode(String.self, forKey: .adapterID),
            window: try container.decode(UsageManualReadingWindow.self, forKey: .window),
            usedPercent: try container.decode(Double.self, forKey: .usedPercent),
            observedAt: try container.decode(Date.self, forKey: .observedAt),
            resetAt: try container.decodeIfPresent(Date.self, forKey: .resetAt),
            unvalidated: true
        )
        try decoded.validateStructure()
        self = decoded
    }

    private init(
        providerID: UsageProviderID,
        adapterID: String,
        window: UsageManualReadingWindow,
        usedPercent: Double,
        observedAt: Date,
        resetAt: Date?,
        unvalidated: Bool
    ) {
        self.providerID = providerID
        self.adapterID = adapterID
        self.window = window
        self.usedPercent = usedPercent
        self.observedAt = observedAt
        self.resetAt = resetAt
        _ = unvalidated
    }

    public func encode(to encoder: Encoder) throws {
        try validateStructure()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(window, forKey: .window)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
    }
}

public struct UsageManualReadingEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumEncodedBytes = 16 * 1024
    public static let maximumReadings = UsageManualReadingWindow.allCases.count

    public let version: Int
    public let providerID: UsageProviderID
    public let adapterID: String
    public let readings: [UsageManualReading]

    public init(
        version: Int = currentVersion,
        providerID: UsageProviderID,
        adapterID: String,
        readings: [UsageManualReading]
    ) throws {
        guard version == Self.currentVersion else {
            throw UsageManualReadingStoreError.invalidEnvelope
        }
        guard providerID.rawValue == UsageManualReading.supportedProviderID else {
            throw UsageManualReadingStoreError.unsupportedProvider
        }
        guard adapterID == UsageManualReading.supportedAdapterID else {
            throw UsageManualReadingStoreError.unsupportedAdapter
        }
        guard readings.count <= Self.maximumReadings else {
            throw UsageManualReadingStoreError.tooManyReadings
        }
        var windows = Set<UsageManualReadingWindow>()
        for reading in readings {
            try reading.validateStructureForEnvelope()
            guard windows.insert(reading.window).inserted else {
                throw UsageManualReadingStoreError.duplicateWindow
            }
        }
        self.version = version
        self.providerID = providerID
        self.adapterID = adapterID
        self.readings = readings.sorted { $0.window.rawValue < $1.window.rawValue }
    }

    public func validatedReadings(now: Date) throws -> [UsageManualReading] {
        let envelope = try UsageManualReadingEnvelope(
            version: version,
            providerID: providerID,
            adapterID: adapterID,
            readings: readings
        )
        for reading in envelope.readings {
            try reading.validate(now: now)
        }
        return envelope.readings
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case providerID
        case adapterID
        case readings
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try UsageManualReadingEnvelope(
            version: try container.decode(Int.self, forKey: .version),
            providerID: try container.decode(UsageProviderID.self, forKey: .providerID),
            adapterID: try container.decode(String.self, forKey: .adapterID),
            readings: try container.decode([UsageManualReading].self, forKey: .readings)
        )
    }

    public func encode(to encoder: Encoder) throws {
        _ = try UsageManualReadingEnvelope(
            version: version,
            providerID: providerID,
            adapterID: adapterID,
            readings: readings
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(readings, forKey: .readings)
    }
}

private extension UsageManualReading {
    func validateStructureForEnvelope() throws {
        try validateStructure()
    }
}

enum UsageManualReadingSet {
    static func validated(_ readings: [UsageManualReading], now: Date) throws -> [UsageManualReading] {
        guard readings.count <= UsageManualReadingEnvelope.maximumReadings else {
            throw UsageManualReadingStoreError.tooManyReadings
        }
        var byWindow = [UsageManualReadingWindow: UsageManualReading]()
        for reading in readings {
            try reading.validate(now: now)
            guard byWindow.updateValue(reading, forKey: reading.window) == nil else {
                throw UsageManualReadingStoreError.duplicateWindow
            }
        }
        return byWindow.values.sorted { $0.window.rawValue < $1.window.rawValue }
    }

    static func merged(
        _ current: [UsageManualReading],
        with incoming: UsageManualReading,
        now: Date
    ) throws -> [UsageManualReading] {
        let existing = try validated(current, now: now)
        try incoming.validate(now: now)
        var byWindow = Dictionary(uniqueKeysWithValues: existing.map { ($0.window, $0) })
        if let prior = byWindow[incoming.window], prior.observedAt > incoming.observedAt {
            return existing
        }
        byWindow[incoming.window] = incoming
        return try validated(Array(byWindow.values), now: now)
    }
}

public protocol UsageManualReadingStore: AnyObject {
    func load(now: Date) throws -> [UsageManualReading]
    @discardableResult
    func save(_ reading: UsageManualReading, now: Date) throws -> [UsageManualReading]
    @discardableResult
    func replace(_ readings: [UsageManualReading], now: Date) throws -> [UsageManualReading]
    func delete() throws
}

public extension UsageManualReadingStore {
    func load() throws -> [UsageManualReading] { try load(now: .now) }
    func save(_ reading: UsageManualReading) throws { try save(reading, now: .now) }
    func replace(_ readings: [UsageManualReading]) throws { try replace(readings, now: .now) }
}

public final class UserDefaultsUsageManualReadingStore: UsageManualReadingStore {
    public static let key = "LifeOS.usage.manualReadings.v1"
    private static let processMutationLock = NSLock()
    private static let maximumRollbackAttempts = 2

    private struct RawPayloadSnapshot {
        let object: Any?

        init(defaults: UserDefaults) {
            guard let object = defaults.object(forKey: UserDefaultsUsageManualReadingStore.key) else {
                self.object = nil
                return
            }
            if let data = object as? Data {
                self.object = Data(data)
            } else {
                self.object = object
            }
        }

        func matches(_ current: Any?) -> Bool {
            guard let previous = object, let current else {
                return object == nil && current == nil
            }
            if let previousData = previous as? Data, let currentData = current as? Data {
                return previousData == currentData
            }
            if let previousObject = previous as? NSObject,
               let currentObject = current as? NSObject {
                return previousObject.isEqual(currentObject)
            }
            return false
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(now: Date) throws -> [UsageManualReading] {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        return try loadUnlocked(now: now)
    }

    private func loadUnlocked(now: Date) throws -> [UsageManualReading] {
        guard defaults.object(forKey: Self.key) != nil else { return [] }
        guard let data = defaults.data(forKey: Self.key) else {
            throw UsageManualReadingStoreError.invalidEnvelope
        }
        guard data.count <= UsageManualReadingEnvelope.maximumEncodedBytes else {
            throw UsageManualReadingStoreError.payloadTooLarge
        }
        do {
            let envelope = try JSONDecoder.lifeOS.decode(UsageManualReadingEnvelope.self, from: data)
            return try envelope.validatedReadings(now: now)
        } catch let error as UsageManualReadingStoreError {
            throw error
        } catch {
            throw UsageManualReadingStoreError.invalidEnvelope
        }
    }

    @discardableResult
    public func save(_ reading: UsageManualReading, now: Date) throws -> [UsageManualReading] {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        let merged = try UsageManualReadingSet.merged(loadUnlocked(now: now), with: reading, now: now)
        return try replaceUnlocked(merged, now: now)
    }

    @discardableResult
    public func replace(_ readings: [UsageManualReading], now: Date) throws -> [UsageManualReading] {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        return try replaceUnlocked(readings, now: now)
    }

    private func replaceUnlocked(_ readings: [UsageManualReading], now: Date) throws -> [UsageManualReading] {
        let canonical = try UsageManualReadingSet.validated(readings, now: now)
        let providerID = try UsageProviderID(UsageManualReading.supportedProviderID)
        let envelope = try UsageManualReadingEnvelope(
            providerID: providerID,
            adapterID: UsageManualReading.supportedAdapterID,
            readings: canonical
        )
        let data: Data
        do {
            data = try JSONEncoder.lifeOS.encode(envelope)
        } catch let error as UsageManualReadingStoreError {
            throw error
        } catch {
            throw UsageManualReadingStoreError.saveFailed
        }
        guard data.count <= UsageManualReadingEnvelope.maximumEncodedBytes else {
            throw UsageManualReadingStoreError.payloadTooLarge
        }
        let previous = RawPayloadSnapshot(defaults: defaults)
        do {
            defaults.set(data, forKey: Self.key)
            guard defaults.data(forKey: Self.key) == data else {
                throw UsageManualReadingStoreError.saveFailed
            }
            return canonical
        } catch let error as UsageManualReadingStoreError {
            _ = rollback(to: previous)
            throw error
        } catch {
            _ = rollback(to: previous)
            throw UsageManualReadingStoreError.saveFailed
        }
    }

    @discardableResult
    private func rollback(to snapshot: RawPayloadSnapshot) -> Bool {
        for _ in 0..<Self.maximumRollbackAttempts {
            if let object = snapshot.object {
                defaults.set(object, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
            if snapshot.matches(defaults.object(forKey: Self.key)) {
                return true
            }
        }

        // Never remove a previously committed raw payload when restoration
        // cannot be verified. The last bounded restore attempt remains in
        // place while the caller reports the original save failure.
        guard snapshot.object == nil else { return false }

        // The key was absent before the failed write. A final removal is safe
        // only for that case, and absence must still be verified explicitly.
        defaults.removeObject(forKey: Self.key)
        return defaults.object(forKey: Self.key) == nil
    }

    public func delete() throws {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        defaults.removeObject(forKey: Self.key)
        guard defaults.object(forKey: Self.key) == nil else {
            throw UsageManualReadingStoreError.deleteFailed
        }
    }
}

public final class InMemoryUsageManualReadingStore: UsageManualReadingStore {
    public private(set) var readings: [UsageManualReading]
    public var loadError: UsageManualReadingStoreError?
    public var saveError: UsageManualReadingStoreError?
    public var deleteError: UsageManualReadingStoreError?

    public init(readings: [UsageManualReading] = []) {
        self.readings = readings
    }

    public func load(now: Date) throws -> [UsageManualReading] {
        if let loadError { throw loadError }
        return try UsageManualReadingSet.validated(readings, now: now)
    }

    @discardableResult
    public func save(_ reading: UsageManualReading, now: Date) throws -> [UsageManualReading] {
        if let saveError { throw saveError }
        readings = try UsageManualReadingSet.merged(readings, with: reading, now: now)
        return readings
    }

    @discardableResult
    public func replace(_ readings: [UsageManualReading], now: Date) throws -> [UsageManualReading] {
        if let saveError { throw saveError }
        self.readings = try UsageManualReadingSet.validated(readings, now: now)
        return self.readings
    }

    public func delete() throws {
        if let deleteError { throw deleteError }
        readings = []
    }
}
