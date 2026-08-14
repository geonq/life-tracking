import Foundation

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

// MARK: - Supported HealthKit contract

/// The subset of HealthKit that LifeOS can reconcile without inventing a
/// value.  The raw identifiers intentionally use LifeOS names; the iOS
/// adapter owns the platform-specific mapping.
public enum HealthKitMetricID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case water
    case caffeine
    case alcoholicBeverages = "alcoholic_beverages"
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariabilitySDNN = "heart_rate_variability_sdnn"
    case oxygenSaturation = "oxygen_saturation"
    case vo2Max = "vo2_max"
    case activeEnergy = "active_energy"
    case steps
    case respiratoryRate = "respiratory_rate"
    case bodyMass = "body_mass"
    case bodyFatPercentage = "body_fat_percentage"
    case leanBodyMass = "lean_body_mass"
    case sleep
    case workout

    public var id: String { rawValue }

    public var isQuantity: Bool {
        switch self {
        case .sleep, .workout: false
        default: true
        }
    }

    public var canonicalUnit: HealthKitCanonicalUnit? {
        switch self {
        case .water: .milliliters
        case .caffeine: .milligrams
        case .alcoholicBeverages: .standardDrinks
        case .heartRate, .restingHeartRate, .respiratoryRate: .countPerMinute
        case .heartRateVariabilitySDNN: .milliseconds
        case .oxygenSaturation, .bodyFatPercentage: .percent
        case .vo2Max: .millilitersPerKilogramMinute
        case .activeEnergy: .kilocalories
        case .steps: .count
        case .bodyMass, .leanBodyMass: .kilograms
        case .sleep, .workout: nil
        }
    }
}

public enum HealthKitCanonicalUnit: String, Codable, CaseIterable, Sendable {
    case milliliters
    case milligrams
    case standardDrinks = "standard_drinks"
    case countPerMinute = "count_per_minute"
    case milliseconds
    case percent
    case millilitersPerKilogramMinute = "milliliters_per_kilogram_minute"
    case kilocalories
    case count
    case kilograms
    case seconds
}

public enum HealthKitDomainError: Error, Equatable, Sendable {
    case invalidText(String)
    case invalidDate(String)
    case futureDate
    case invalidInterval
    case unsupportedUnit(metric: HealthKitMetricID, expected: HealthKitCanonicalUnit)
    case invalidQuantity
    case invalidRevision
    case invalidAnchor
    case invalidSourceMetadata
    case invalidSleepStage
    case invalidWorkout
    case invalidSourceIndex
}

/// Conservative limits at the HealthKit/client boundary. HealthKit queries
/// are incremental, but an untrusted archive or provider response must never
/// be allowed to turn that boundary into an unbounded memory or arithmetic
/// operation.
public enum HealthKitSafetyLimits {
    public static let maxQuantityValue: Double = 1_000_000_000
    public static let maxObservationIntervalSeconds: TimeInterval = 366 * 24 * 60 * 60
    public static let maxWorkoutDurationSeconds: TimeInterval = 366 * 24 * 60 * 60
    public static let maxSampleAliases = 64
    public static let maxSyncBatchItems = 5_000
    public static let maxProjectionItems = 50_000
    public static let maxConflictItems = 10_000
    public static let maxSourceIndexItems = 50_000
    public static let maxAnchorBytes = 1_048_576
    public static let maxAnchorArchiveCharacters = 1_398_104
    public static let maxEnvelopeBytes = 8 * 1_048_576
}

/// A canonical non-negative quantity.  HealthKit's quantity APIs perform the
/// unit conversion; this type is the boundary where the converted value is
/// checked before it can enter LifeOS storage or calculations.
public struct HealthKitQuantityValue: Codable, Equatable, Sendable {
    public let metric: HealthKitMetricID
    public let value: Double
    public let unit: HealthKitCanonicalUnit

    public init(metric: HealthKitMetricID, value: Double, unit: HealthKitCanonicalUnit) throws {
        guard let expected = metric.canonicalUnit else {
            throw HealthKitDomainError.unsupportedUnit(metric: metric, expected: unit)
        }
        guard expected == unit else {
            throw HealthKitDomainError.unsupportedUnit(metric: metric, expected: expected)
        }
        guard value.isFinite, value >= 0, value <= HealthKitSafetyLimits.maxQuantityValue else {
            throw HealthKitDomainError.invalidQuantity
        }
        self.metric = metric
        self.value = value
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey { case metric, value, unit }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["metric", "value", "unit"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metric = try container.decode(HealthKitMetricID.self, forKey: .metric)
        let value = try container.decode(Double.self, forKey: .value)
        let unit = try container.decode(HealthKitCanonicalUnit.self, forKey: .unit)
        self = try HealthKitQuantityValue(metric: metric, value: value, unit: unit)
    }
}

// MARK: - Sample identity and source provenance

public enum HealthKitSampleRevision: Codable, Equatable, Hashable, Sendable {
    /// HKMetadataKeySyncVersion is an ordered non-negative integer.  Keeping
    /// it numeric prevents lexical ordering bugs (for example, "10" before
    /// "2") and rejects provider values that are not the documented number.
    case syncVersion(Int64)
    case uuidFallback

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(syncVersion: Int64?) throws {
        guard let syncVersion else {
            self = .uuidFallback
            return
        }
        guard syncVersion >= 0 else {
            throw HealthKitDomainError.invalidRevision
        }
        self = .syncVersion(syncVersion)
    }

    public var rawValue: String {
        switch self {
        case .syncVersion(let value): "sync:\(value)"
        case .uuidFallback: "uuid-fallback"
        }
    }

    public var numericValue: Int64? {
        switch self {
        case .syncVersion(let value): value
        case .uuidFallback: nil
        }
    }

    public func isNewer(than other: HealthKitSampleRevision) -> Bool {
        switch (numericValue, other.numericValue) {
        case let (.some(lhs), .some(rhs)): return lhs > rhs
        case (.some, .none): return true
        default: return false
        }
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["kind", "value"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "sync_version":
            let value = try container.decode(Int64.self, forKey: .value)
            self = try HealthKitSampleRevision(syncVersion: value)
        case "uuid_fallback":
            guard !container.contains(.value) else { throw HealthKitDomainError.invalidRevision }
            self = .uuidFallback
        default:
            throw HealthKitDomainError.invalidRevision
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .syncVersion(let value):
            try container.encode("sync_version", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .uuidFallback:
            try container.encode("uuid_fallback", forKey: .kind)
        }
    }
}

public struct HealthKitSampleIdentity: Codable, Equatable, Hashable, Sendable {
    public let uuid: UUID
    /// HKMetadataKeySyncIdentifier is the stable source identity.  The HK
    /// UUID is retained as an alias because HealthKit may issue a new UUID for
    /// a revised copy and deletions only provide the UUID alias.
    public let syncIdentifier: String?
    public let aliases: [UUID]
    public let revision: HealthKitSampleRevision

    public init(
        uuid: UUID,
        syncIdentifier: String? = nil,
        aliases: [UUID] = [],
        revision: HealthKitSampleRevision = .uuidFallback
    ) {
        self.uuid = uuid
        self.syncIdentifier = Self.cleanSyncIdentifier(syncIdentifier)
        self.aliases = Array(Set(aliases).subtracting([uuid])).sorted { $0.uuidString < $1.uuidString }
        self.revision = revision
    }

    private static func cleanSyncIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 512 else { return nil }
        return clean
    }

    public var stableKey: String {
        if let syncIdentifier { return "sync_identifier:\(syncIdentifier)" }
        return "uuid:" + aliasUUIDs.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
    }

    public var aliasKeys: Set<String> {
        var result: Set<String> = ([uuid] + aliases).map { "uuid:\($0.uuidString.lowercased())" }.reduce(into: Set<String>()) { $0.insert($1) }
        if let syncIdentifier { result.insert("sync_identifier:\(syncIdentifier)") }
        return result
    }

    /// Stable identity matching deliberately allows a UUID-only observation
    /// to meet a later sync-identifier observation with the same UUID.  A
    /// sync identifier is otherwise authoritative across UUID changes.
    public func matchesStableIdentity(_ other: HealthKitSampleIdentity) -> Bool {
        // A UUID is an alias even when both records also carry sync
        // identifiers.  HealthKit can revise metadata in place, so a
        // matching UUID must not be hidden by two different sync IDs.
        if sharesUUID(with: other) {
            return true
        }
        if let syncIdentifier, let otherIdentifier = other.syncIdentifier {
            return syncIdentifier == otherIdentifier
        }
        return false
    }

    /// Checks UUID alias overlap without materializing either alias set. This
    /// is used by bounded reconciliation/projection hot paths where the old
    /// `Set([uuid] + aliases)` allocation multiplied across thousands of
    /// retained observations.
    public func sharesUUID(with other: HealthKitSampleIdentity) -> Bool {
        guard uuid != other.uuid else { return true }
        guard !aliases.contains(other.uuid), !other.aliases.contains(uuid) else { return true }
        return aliases.contains { other.aliases.contains($0) }
    }

    public var aliasUUIDs: Set<UUID> { Set([uuid] + aliases) }

    public var isWithinSafetyBounds: Bool {
        aliases.count <= HealthKitSafetyLimits.maxSampleAliases
    }

    public func withMergedAliases(from other: HealthKitSampleIdentity) -> HealthKitSampleIdentity {
        HealthKitSampleIdentity(
            uuid: uuid,
            syncIdentifier: syncIdentifier ?? other.syncIdentifier,
            aliases: Array(aliasUUIDs.union(other.aliasUUIDs).subtracting([uuid])),
            revision: revision
        )
    }

    public static func == (lhs: HealthKitSampleIdentity, rhs: HealthKitSampleIdentity) -> Bool {
        lhs.uuid == rhs.uuid &&
        lhs.syncIdentifier == rhs.syncIdentifier &&
        lhs.aliases == rhs.aliases &&
        lhs.revision == rhs.revision
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
        hasher.combine(syncIdentifier)
        hasher.combine(aliases)
        hasher.combine(revision)
    }

    private enum CodingKeys: String, CodingKey { case uuid, syncIdentifier, aliases, revision }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["uuid", "syncIdentifier", "aliases", "revision"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uuid = try container.decode(UUID.self, forKey: .uuid)
        let syncIdentifier = try decodeStrictOptional(String.self, forKey: .syncIdentifier, from: container)
        let clean = Self.cleanSyncIdentifier(syncIdentifier)
        guard syncIdentifier == nil || clean != nil else { throw HealthKitDomainError.invalidRevision }
        self.syncIdentifier = clean
        let aliases = try decodeStrictOptional([UUID].self, forKey: .aliases, from: container) ?? []
        guard !aliases.contains(uuid),
              Set(aliases).count == aliases.count,
              aliases.count <= HealthKitSafetyLimits.maxSampleAliases else {
            throw HealthKitDomainError.invalidRevision
        }
        self.aliases = aliases.sorted { $0.uuidString < $1.uuidString }
        let revision = try container.decode(HealthKitSampleRevision.self, forKey: .revision)
        guard syncIdentifier == nil || revision.numericValue != nil else {
            throw HealthKitDomainError.invalidRevision
        }
        self.revision = revision
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        if let syncIdentifier { try container.encode(syncIdentifier, forKey: .syncIdentifier) }
        if !aliases.isEmpty { try container.encode(aliases, forKey: .aliases) }
        try container.encode(revision, forKey: .revision)
    }
}

public struct HealthKitSourceMetadata: Codable, Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let productType: String?
    public let operatingSystemVersion: String?

    public init(
        bundleIdentifier: String,
        name: String,
        version: String? = nil,
        productType: String? = nil,
        operatingSystemVersion: String? = nil
    ) throws {
        self.bundleIdentifier = try Self.required(bundleIdentifier, field: "bundleIdentifier")
        self.name = try Self.required(name, field: "name")
        self.version = try Self.optional(version, field: "version")
        self.productType = try Self.optional(productType, field: "productType")
        self.operatingSystemVersion = try Self.optional(operatingSystemVersion, field: "operatingSystemVersion")
    }

    private static func required(_ value: String, field: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 512 else { throw HealthKitDomainError.invalidSourceMetadata }
        return clean
    }

    private static func optional(_ value: String?, field: String) throws -> String? {
        guard let value else { return nil }
        return try required(value, field: field)
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name, version, productType, operatingSystemVersion
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["bundleIdentifier", "name", "version", "productType", "operatingSystemVersion"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try HealthKitSourceMetadata(
            bundleIdentifier: container.decode(String.self, forKey: .bundleIdentifier),
            name: container.decode(String.self, forKey: .name),
            version: decodeStrictOptional(String.self, forKey: .version, from: container),
            productType: decodeStrictOptional(String.self, forKey: .productType, from: container),
            operatingSystemVersion: decodeStrictOptional(String.self, forKey: .operatingSystemVersion, from: container)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(name, forKey: .name)
        if let version { try container.encode(version, forKey: .version) }
        if let productType { try container.encode(productType, forKey: .productType) }
        if let operatingSystemVersion { try container.encode(operatingSystemVersion, forKey: .operatingSystemVersion) }
    }
}

public struct HealthKitDeviceMetadata: Codable, Equatable, Hashable, Sendable {
    public let name: String?
    public let manufacturer: String?
    public let model: String?
    public let hardwareVersion: String?
    public let firmwareVersion: String?
    public let softwareVersion: String?
    public let localIdentifier: String?

    public init(
        name: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        hardwareVersion: String? = nil,
        firmwareVersion: String? = nil,
        softwareVersion: String? = nil,
        localIdentifier: String? = nil
    ) throws {
        self.name = try Self.clean(name)
        self.manufacturer = try Self.clean(manufacturer)
        self.model = try Self.clean(model)
        self.hardwareVersion = try Self.clean(hardwareVersion)
        self.firmwareVersion = try Self.clean(firmwareVersion)
        self.softwareVersion = try Self.clean(softwareVersion)
        self.localIdentifier = try Self.clean(localIdentifier)
    }

    private static func clean(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 512 else { throw HealthKitDomainError.invalidSourceMetadata }
        return clean
    }

    private enum CodingKeys: String, CodingKey {
        case name, manufacturer, model, hardwareVersion, firmwareVersion, softwareVersion, localIdentifier
    }

    public init(from decoder: Decoder) throws {
        // `udiDeviceIdentifier` was present in an early local schema. It is
        // intentionally accepted and ignored during migration so old files
        // remain readable, but it is not part of the current metadata model
        // and can never be re-encoded.
        try rejectUnknownLifeOSKeys(decoder, allowed: ["name", "manufacturer", "model", "hardwareVersion", "firmwareVersion", "softwareVersion", "localIdentifier", "udiDeviceIdentifier"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try HealthKitDeviceMetadata(
            name: decodeStrictOptional(String.self, forKey: .name, from: container),
            manufacturer: decodeStrictOptional(String.self, forKey: .manufacturer, from: container),
            model: decodeStrictOptional(String.self, forKey: .model, from: container),
            hardwareVersion: decodeStrictOptional(String.self, forKey: .hardwareVersion, from: container),
            firmwareVersion: decodeStrictOptional(String.self, forKey: .firmwareVersion, from: container),
            softwareVersion: decodeStrictOptional(String.self, forKey: .softwareVersion, from: container),
            localIdentifier: decodeStrictOptional(String.self, forKey: .localIdentifier, from: container)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let name { try container.encode(name, forKey: .name) }
        if let manufacturer { try container.encode(manufacturer, forKey: .manufacturer) }
        if let model { try container.encode(model, forKey: .model) }
        if let hardwareVersion { try container.encode(hardwareVersion, forKey: .hardwareVersion) }
        if let firmwareVersion { try container.encode(firmwareVersion, forKey: .firmwareVersion) }
        if let softwareVersion { try container.encode(softwareVersion, forKey: .softwareVersion) }
        if let localIdentifier { try container.encode(localIdentifier, forKey: .localIdentifier) }
    }
}

public enum HealthKitSourceMatch: String, Codable, CaseIterable, Sendable {
    case confirmed
    case candidate
    case unattributed
    case other
    case conflict
}

/// A reviewed registry entry.  A missing constraint means that the reviewed
/// entry does not require that field; it never turns a mismatching field into
/// a match. Bundle and supplied device fields are compared as exact strings.
public struct HealthKitHelioEvidenceRule: Codable, Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let manufacturer: String?
    public let model: String?

    public init(bundleIdentifier: String, manufacturer: String? = nil, model: String? = nil) throws {
        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty, bundle.count <= 512 else { throw HealthKitDomainError.invalidSourceMetadata }
        self.bundleIdentifier = bundle
        self.manufacturer = try HealthKitDeviceMetadata.cleanForRule(manufacturer)
        self.model = try HealthKitDeviceMetadata.cleanForRule(model)
    }

    /// The canonical inventory is compiled into this source file.  This
    /// fileprivate initializer avoids turning a compile-time-reviewed
    /// literal into a runtime crash while keeping all external rule input on
    /// the throwing, validated initializer above.
    fileprivate init(canonicalBundleIdentifier: String, manufacturer: String?, model: String?) {
        self.bundleIdentifier = canonicalBundleIdentifier
        self.manufacturer = manufacturer
        self.model = model
    }

    private enum CodingKeys: String, CodingKey { case bundleIdentifier, manufacturer, model }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["bundleIdentifier", "manufacturer", "model"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try HealthKitHelioEvidenceRule(
            bundleIdentifier: container.decode(String.self, forKey: .bundleIdentifier),
            manufacturer: decodeStrictOptional(String.self, forKey: .manufacturer, from: container),
            model: decodeStrictOptional(String.self, forKey: .model, from: container)
        )
    }

    fileprivate func compatibility(with source: HealthKitSourceMetadata, device: HealthKitDeviceMetadata?) -> (complete: Bool, compatible: Bool) {
        guard source.bundleIdentifier == bundleIdentifier else { return (false, false) }
        let fields: [(expected: String?, actual: String?)] = [(manufacturer, device?.manufacturer), (model, device?.model)]
        // A source-only rule is never enough to confirm a Helio device. It is
        // a candidate until at least one reviewed device constraint is
        // present and observed.
        var complete = fields.contains { $0.expected != nil }
        for (expected, actual) in fields {
            guard let expected else { continue }
            guard let actual else { complete = false; continue }
            guard expected == actual else { return (false, false) }
        }
        return (complete, true)
    }
}

fileprivate extension HealthKitDeviceMetadata {
    static func cleanForRule(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 512 else { throw HealthKitDomainError.invalidSourceMetadata }
        return clean
    }
}

public struct HealthKitHelioEvidenceRegistry: Codable, Equatable, Sendable {
    public let rules: [HealthKitHelioEvidenceRule]

    public init(rules: [HealthKitHelioEvidenceRule]) {
        self.rules = rules
    }

    /// The only registry used when persisted provenance is decoded.  A caller
    /// may pass a value registry while constructing a test observation, but a
    /// persisted `helioMatch` is always re-derived against this reviewed
    /// immutable inventory.
    public static let canonical: HealthKitHelioEvidenceRegistry = {
        let rule = HealthKitHelioEvidenceRule(
            canonicalBundleIdentifier: "com.zepp.health",
            manufacturer: "Amazfit",
            model: "Helio Strap"
        )
        return HealthKitHelioEvidenceRegistry(rules: [rule])
    }()

    private enum CodingKeys: String, CodingKey { case rules }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["rules"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rules = try container.decode([HealthKitHelioEvidenceRule].self, forKey: .rules)
        let identities = rules.map { "\($0.bundleIdentifier)|\($0.manufacturer ?? "")|\($0.model ?? "")" }
        guard Set(identities).count == identities.count else { throw HealthKitDomainError.invalidSourceMetadata }
        self.rules = rules
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rules, forKey: .rules)
    }

    public func match(source: HealthKitSourceMetadata?, device: HealthKitDeviceMetadata?) -> HealthKitSourceMatch {
        guard let source, !source.bundleIdentifier.isEmpty else { return .unattributed }
        let bundleRules = rules.filter { $0.bundleIdentifier == source.bundleIdentifier }
        guard !bundleRules.isEmpty else { return .other }

        let compatible = bundleRules.map { $0.compatibility(with: source, device: device) }
        let confirmedCount = compatible.filter(\.complete).count
        if confirmedCount > 1 { return .conflict }
        if confirmedCount == 1 { return .confirmed }
        if compatible.contains(where: \.compatible) { return .candidate }
        return .other
    }
}

public struct HealthKitProvenance: Codable, Equatable, Hashable, Sendable {
    public let source: HealthKitSourceMetadata?
    public let device: HealthKitDeviceMetadata?
    public let helioMatch: HealthKitSourceMatch

    private init(source: HealthKitSourceMetadata?, device: HealthKitDeviceMetadata?, helioMatch: HealthKitSourceMatch) throws {
        guard source != nil || device != nil || helioMatch == .unattributed else {
            throw HealthKitDomainError.invalidSourceMetadata
        }
        self.source = source
        self.device = device
        self.helioMatch = helioMatch
    }

    public static func from(source: HealthKitSourceMetadata?, device: HealthKitDeviceMetadata?, registry: HealthKitHelioEvidenceRegistry) throws -> HealthKitProvenance {
        try HealthKitProvenance(source: source, device: device, helioMatch: registry.match(source: source, device: device))
    }

    /// Persistence and reconciliation accept only evidence whose match was
    /// derived from the immutable reviewed registry.  Adapters may still use
    /// a value registry while constructing an in-memory sample, but that
    /// sample cannot cross the durable commit boundary unless this is true.
    public var matchesCanonicalRegistry: Bool {
        HealthKitHelioEvidenceRegistry.canonical.match(source: source, device: device) == helioMatch
    }

    private enum CodingKeys: String, CodingKey { case source, device, helioMatch }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["source", "device", "helioMatch"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try decodeStrictOptional(HealthKitSourceMetadata.self, forKey: .source, from: container)
        let device = try decodeStrictOptional(HealthKitDeviceMetadata.self, forKey: .device, from: container)
        let match = try container.decode(HealthKitSourceMatch.self, forKey: .helioMatch)
        let derived = HealthKitHelioEvidenceRegistry.canonical.match(source: source, device: device)
        guard match == derived else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath + [CodingKeys.helioMatch],
                debugDescription: "Persisted Helio match does not match the canonical reviewed registry"
            ))
        }
        self = try HealthKitProvenance(source: source, device: device, helioMatch: derived)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let source { try container.encode(source, forKey: .source) }
        if let device { try container.encode(device, forKey: .device) }
        try container.encode(helioMatch, forKey: .helioMatch)
    }
}

// MARK: - Source-index contract

/// Source-index keys are deliberately boring and inspectable.  Each key has
/// exactly three non-empty components: bundle, manufacturer, and model.  The
/// percent escapes keep metadata containing `|` unambiguous while accepting
/// the legacy plain form used by the first HealthKit tranche.
public enum HealthKitSourceIndexKey {
    public static func make(for provenance: HealthKitProvenance) -> String {
        let bundle = provenance.source?.bundleIdentifier ?? "unknown"
        let manufacturer = provenance.device?.manufacturer ?? "unknown"
        let model = provenance.device?.model ?? "unknown"
        return [bundle, manufacturer, model].map(escape).joined(separator: "|")
    }

    public static func isValid(_ key: String) -> Bool {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 512 }) else { return false }
        return parts.allSatisfy { validEscapes(String($0)) }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
    }

    private static func validEscapes(_ value: String) -> Bool {
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "%" else {
                index = value.index(after: index)
                continue
            }
            let next = value.index(after: index)
            guard next < value.endIndex else { return false }
            let second = value.index(after: next)
            guard second < value.endIndex else { return false }
            let end = value.index(after: second)
            let token = String(value[next..<end])
            guard token == "25" || token == "7C" else { return false }
            index = end
        }
        return true
    }
}

public enum HealthKitSourceIndex {
    public static func build(observations: [HealthKitObservation]) throws -> [String: HealthKitSourceMatch] {
        var result: [String: HealthKitSourceMatch] = [:]
        for observation in observations {
            let key = HealthKitSourceIndexKey.make(for: observation.provenance)
            guard HealthKitSourceIndexKey.isValid(key) else { throw HealthKitDomainError.invalidSourceIndex }
            if let existing = result[key], existing != observation.provenance.helioMatch {
                result[key] = .conflict
            } else {
                result[key] = observation.provenance.helioMatch
            }
        }
        return result
    }
}

/// HealthKit can expose the same calories through active-energy quantity
/// samples and workout samples.  LifeOS uses active-energy samples as the
/// authority whenever their intervals overlap a workout; workouts are a
/// fallback only when no authoritative active-energy interval covers them.
public enum HealthKitEnergyOverlapPolicy: String, Codable, CaseIterable, Sendable {
    case activeEnergyAuthoritative = "active_energy_authoritative"
}

public struct HealthKitEnergyAggregate: Equatable, Sendable {
    public let kilocalories: Double
    public let policy: HealthKitEnergyOverlapPolicy

    public init(kilocalories: Double, policy: HealthKitEnergyOverlapPolicy) throws {
        guard kilocalories.isFinite, kilocalories >= 0 else { throw HealthKitDomainError.invalidQuantity }
        self.kilocalories = kilocalories
        self.policy = policy
    }

    public static func from(observations: [HealthKitObservation]) throws -> HealthKitEnergyAggregate {
        let activeEnergy = observations.filter { $0.metric == .activeEnergy }
        let workouts = observations.filter { $0.metric == .workout }
        let activeIntervals = activeEnergy.map { ($0.startDate, $0.endDate) }
        var total = 0.0
        for observation in activeEnergy {
            guard case .quantity(let value) = observation.value,
                  value.metric == .activeEnergy else { throw HealthKitDomainError.invalidQuantity }
            total += value.value
            guard total.isFinite, total <= HealthKitSafetyLimits.maxQuantityValue else {
                throw HealthKitDomainError.invalidQuantity
            }
        }
        for observation in workouts {
            guard case .workout(let workout) = observation.value else { throw HealthKitDomainError.invalidWorkout }
            // A workout's totalEnergyBurned is a fallback contribution only.
            // If any authoritative active-energy interval overlaps it, adding
            // the workout would double-count the same calories.
            guard let calories = workout.activeEnergyKilocalories,
                  !activeIntervals.contains(where: { $0.0 < observation.endDate && observation.startDate < $0.1 }) else { continue }
            total += calories
            guard total.isFinite, total <= HealthKitSafetyLimits.maxQuantityValue else {
                throw HealthKitDomainError.invalidQuantity
            }
        }
        return try HealthKitEnergyAggregate(kilocalories: total, policy: .activeEnergyAuthoritative)
    }
}

// MARK: - Observation values

public enum HealthKitSleepStage: Codable, Equatable, Hashable, Sendable {
    case inBed
    case asleepUnspecified
    case awake
    case asleepCore
    case asleepDeep
    case asleepREM
    case unknown(rawValue: Int)

    private enum CodingKeys: String, CodingKey { case kind, rawValue }

    public init(rawValue: Int) {
        switch rawValue {
        case 0: self = .inBed
        case 1: self = .asleepUnspecified
        case 2: self = .awake
        case 3: self = .asleepCore
        case 4: self = .asleepDeep
        case 5: self = .asleepREM
        default: self = .unknown(rawValue: rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .inBed: 0
        case .asleepUnspecified: 1
        case .awake: 2
        case .asleepCore: 3
        case .asleepDeep: 4
        case .asleepREM: 5
        case .unknown(let rawValue): rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["kind", "rawValue"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "in_bed":
            guard container.allKeys.count == 1 else { throw HealthKitDomainError.invalidSleepStage }
            self = .inBed
        case "asleep_unspecified":
            guard container.allKeys.count == 1 else { throw HealthKitDomainError.invalidSleepStage }
            self = .asleepUnspecified
        case "awake":
            guard container.allKeys.count == 1 else { throw HealthKitDomainError.invalidSleepStage }
            self = .awake
        case "asleep_core":
            guard container.allKeys.count == 1 else { throw HealthKitDomainError.invalidSleepStage }
            self = .asleepCore
        case "asleep_deep":
            guard container.allKeys.count == 1 else { throw HealthKitDomainError.invalidSleepStage }
            self = .asleepDeep
        case "asleep_rem":
            guard container.allKeys.count == 1 else { throw HealthKitDomainError.invalidSleepStage }
            self = .asleepREM
        case "unknown":
            guard container.allKeys.count == 2 else { throw HealthKitDomainError.invalidSleepStage }
            let rawValue = try container.decode(Int.self, forKey: .rawValue)
            guard rawValue >= 0 else { throw HealthKitDomainError.invalidSleepStage }
            self = .unknown(rawValue: rawValue)
        default: throw HealthKitDomainError.invalidSleepStage
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inBed: try container.encode("in_bed", forKey: .kind)
        case .asleepUnspecified: try container.encode("asleep_unspecified", forKey: .kind)
        case .awake: try container.encode("awake", forKey: .kind)
        case .asleepCore: try container.encode("asleep_core", forKey: .kind)
        case .asleepDeep: try container.encode("asleep_deep", forKey: .kind)
        case .asleepREM: try container.encode("asleep_rem", forKey: .kind)
        case .unknown(let rawValue):
            try container.encode("unknown", forKey: .kind)
            try container.encode(rawValue, forKey: .rawValue)
        }
    }
}

public struct HealthKitSleepValue: Codable, Equatable, Sendable {
    public let stage: HealthKitSleepStage
    public let timeZoneIdentifier: String?

    public init(stage: HealthKitSleepStage, timeZoneIdentifier: String? = nil) throws {
        guard stage.rawValue >= 0 else { throw HealthKitDomainError.invalidSleepStage }
        if let timeZoneIdentifier {
            guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw HealthKitDomainError.invalidText("timeZoneIdentifier") }
        }
        self.stage = stage
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    private enum CodingKeys: String, CodingKey { case stage, timeZoneIdentifier }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["stage", "timeZoneIdentifier"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try HealthKitSleepValue(
            stage: container.decode(HealthKitSleepStage.self, forKey: .stage),
            timeZoneIdentifier: decodeStrictOptional(String.self, forKey: .timeZoneIdentifier, from: container)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stage, forKey: .stage)
        if let timeZoneIdentifier { try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier) }
    }
}

public struct HealthKitWorkoutValue: Codable, Equatable, Sendable {
    public let activityTypeRawValue: Int
    public let durationSeconds: Double
    /// HealthKit may attach totalEnergyBurned to a workout.  It is retained
    /// for the explicit overlap policy below, never implicitly summed with an
    /// active-energy quantity sample.
    public let activeEnergyKilocalories: Double?

    public init(
        activityTypeRawValue: Int,
        durationSeconds: Double,
        activeEnergyKilocalories: Double? = nil
    ) throws {
        guard activityTypeRawValue >= 0,
              durationSeconds.isFinite,
              durationSeconds > 0,
              durationSeconds <= HealthKitSafetyLimits.maxWorkoutDurationSeconds else {
            throw HealthKitDomainError.invalidWorkout
        }
        if let activeEnergyKilocalories {
            guard activeEnergyKilocalories.isFinite,
                  activeEnergyKilocalories >= 0,
                  activeEnergyKilocalories <= HealthKitSafetyLimits.maxQuantityValue else {
                throw HealthKitDomainError.invalidWorkout
            }
        }
        self.activityTypeRawValue = activityTypeRawValue
        self.durationSeconds = durationSeconds
        self.activeEnergyKilocalories = activeEnergyKilocalories
    }

    private enum CodingKeys: String, CodingKey { case activityTypeRawValue, durationSeconds, activeEnergyKilocalories }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["activityTypeRawValue", "durationSeconds", "activeEnergyKilocalories"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try HealthKitWorkoutValue(
            activityTypeRawValue: container.decode(Int.self, forKey: .activityTypeRawValue),
            durationSeconds: container.decode(Double.self, forKey: .durationSeconds),
            activeEnergyKilocalories: decodeStrictOptional(Double.self, forKey: .activeEnergyKilocalories, from: container)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activityTypeRawValue, forKey: .activityTypeRawValue)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        if let activeEnergyKilocalories { try container.encode(activeEnergyKilocalories, forKey: .activeEnergyKilocalories) }
    }
}

public enum HealthKitObservationValue: Codable, Equatable, Sendable {
    case quantity(HealthKitQuantityValue)
    case sleep(HealthKitSleepValue)
    case workout(HealthKitWorkoutValue)

    private enum CodingKeys: String, CodingKey { case kind, quantity, sleep, workout }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["kind", "quantity", "sleep", "workout"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "quantity":
            guard Set(container.allKeys.map(\.stringValue)) == Set(["kind", "quantity"]) else {
                throw HealthKitDomainError.invalidText("observation value payload")
            }
            self = .quantity(try container.decode(HealthKitQuantityValue.self, forKey: .quantity))
        case "sleep":
            guard Set(container.allKeys.map(\.stringValue)) == Set(["kind", "sleep"]) else {
                throw HealthKitDomainError.invalidText("observation value payload")
            }
            self = .sleep(try container.decode(HealthKitSleepValue.self, forKey: .sleep))
        case "workout":
            guard Set(container.allKeys.map(\.stringValue)) == Set(["kind", "workout"]) else {
                throw HealthKitDomainError.invalidText("observation value payload")
            }
            self = .workout(try container.decode(HealthKitWorkoutValue.self, forKey: .workout))
        default: throw HealthKitDomainError.invalidText("observation value kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quantity(let value):
            try container.encode("quantity", forKey: .kind)
            try container.encode(value, forKey: .quantity)
        case .sleep(let value):
            try container.encode("sleep", forKey: .kind)
            try container.encode(value, forKey: .sleep)
        case .workout(let value):
            try container.encode("workout", forKey: .kind)
            try container.encode(value, forKey: .workout)
        }
    }
}

public struct HealthKitObservation: Codable, Equatable, Sendable {
    public static let defaultFutureTolerance: TimeInterval = 5

    public let metric: HealthKitMetricID
    public let identity: HealthKitSampleIdentity
    public let value: HealthKitObservationValue
    public let startDate: Date
    public let endDate: Date
    public let provenance: HealthKitProvenance

    public init(
        metric: HealthKitMetricID,
        identity: HealthKitSampleIdentity,
        value: HealthKitObservationValue,
        startDate: Date,
        endDate: Date,
        provenance: HealthKitProvenance,
        now: Date = .now,
        futureTolerance: TimeInterval = HealthKitObservation.defaultFutureTolerance
    ) throws {
        let interval = endDate.timeIntervalSince(startDate)
        guard startDate.timeIntervalSinceReferenceDate.isFinite,
              endDate.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              interval.isFinite,
              startDate <= endDate,
              interval <= HealthKitSafetyLimits.maxObservationIntervalSeconds,
              endDate.timeIntervalSince(now) <= futureTolerance,
              futureTolerance >= 0,
              futureTolerance.isFinite else {
            throw startDate > endDate ? HealthKitDomainError.invalidInterval : HealthKitDomainError.futureDate
        }
        switch value {
        case .quantity(let quantity):
            guard quantity.metric == metric else { throw HealthKitDomainError.invalidQuantity }
        case .sleep:
            guard metric == .sleep else { throw HealthKitDomainError.invalidSleepStage }
        case .workout:
            guard metric == .workout, endDate > startDate else { throw HealthKitDomainError.invalidWorkout }
        }
        self.metric = metric
        self.identity = identity
        self.value = value
        self.startDate = startDate
        self.endDate = endDate
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey { case metric, identity, value, startDate, endDate, provenance }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["metric", "identity", "value", "startDate", "endDate", "provenance"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try HealthKitObservation(
            metric: container.decode(HealthKitMetricID.self, forKey: .metric),
            identity: container.decode(HealthKitSampleIdentity.self, forKey: .identity),
            value: container.decode(HealthKitObservationValue.self, forKey: .value),
            startDate: container.decode(Date.self, forKey: .startDate),
            endDate: container.decode(Date.self, forKey: .endDate),
            provenance: container.decode(HealthKitProvenance.self, forKey: .provenance),
            now: (decoder.userInfo[.lifeOSNow] as? Date) ?? .now
        )
    }
}

public struct HealthKitDeletionTombstone: Codable, Equatable, Hashable, Sendable {
    public let metric: HealthKitMetricID
    public let identity: HealthKitSampleIdentity
    public let deletedAt: Date

    public init(metric: HealthKitMetricID, identity: HealthKitSampleIdentity, deletedAt: Date = .now) throws {
        guard deletedAt.timeIntervalSinceReferenceDate.isFinite else { throw HealthKitDomainError.invalidDate("deletedAt") }
        self.metric = metric
        self.identity = identity
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey { case metric, identity, deletedAt }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["metric", "identity", "deletedAt"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deletedAt = try container.decode(Date.self, forKey: .deletedAt)
        let now = (decoder.userInfo[.lifeOSNow] as? Date) ?? .now
        guard deletedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              deletedAt.timeIntervalSince(now) <= HealthKitObservation.defaultFutureTolerance else {
            throw HealthKitDomainError.futureDate
        }
        self = try HealthKitDeletionTombstone(
            metric: container.decode(HealthKitMetricID.self, forKey: .metric),
            identity: container.decode(HealthKitSampleIdentity.self, forKey: .identity),
            deletedAt: deletedAt
        )
    }
}

// MARK: - Authorization and sync state

public enum HealthKitAuthorizationState: String, Codable, CaseIterable, Sendable {
    case unavailable
    case restricted
    case protectedDataUnavailable = "protected_data_unavailable"
    case notRequested = "not_requested"
    case requestRequired = "request_required"
    case requestPending = "request_pending"
    /// HealthKit intentionally does not expose per-type read denial.  This
    /// state means “the request completed; a query may be empty because the
    /// user denied access or because no readable samples exist.”
    case readIndeterminate = "read_indeterminate"
    case writeNotDetermined = "write_not_determined"
    case writeAuthorized = "write_authorized"
    case writeDenied = "write_denied"
    case revoked
    case error
}

public enum HealthKitMetricState: String, Codable, CaseIterable, Sendable {
    case unavailable
    case permissionRequired = "permission_required"
    case readIndeterminate = "read_indeterminate"
    case observed
    case partial
    case stale
    case conflict
    case error
}

public enum HealthKitSyncState: String, Codable, CaseIterable, Sendable {
    case neverSynced = "never_synced"
    case syncing
    case synced
    case partial
    case readIndeterminate = "read_indeterminate"
    case stale
    case conflict
    case fullResyncRequired = "full_resync_required"
    case error
}

public struct HealthKitOpaqueAnchor: Codable, Equatable, Sendable {
    public let archivedData: Data

    public init(archivedData: Data) throws {
        guard !archivedData.isEmpty,
              archivedData.count <= HealthKitSafetyLimits.maxAnchorBytes,
              Self.isSupportedArchive(archivedData) else { throw HealthKitDomainError.invalidAnchor }
        self.archivedData = archivedData
    }

    private static func isSupportedArchive(_ data: Data) -> Bool {
#if os(iOS) && canImport(HealthKit)
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)) != nil
#else
        // The macOS/widget target intentionally has no HealthKit transport;
        // it may carry opaque bytes but cannot claim to validate them.
        return true
#endif
    }

    private enum CodingKeys: String, CodingKey { case archivedData }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["archivedData"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try HealthKitOpaqueAnchor(archivedData: container.decode(Data.self, forKey: .archivedData))
    }
}

/// HealthKit cannot reveal whether a caller has read access to a particular
/// type. An empty unanchored query is therefore explicitly different from an
/// empty anchored query: the former must not be treated as a successful
/// no-data result.
public enum HealthKitReadability: String, Codable, CaseIterable, Sendable {
    case established
    case emptyIndeterminate = "empty_indeterminate"
}

public struct HealthKitMetricSyncInput: Sendable {
    public let metric: HealthKitMetricID
    public let additions: [HealthKitObservation]
    public let deletions: [HealthKitDeletionTombstone]
    public let nextAnchor: HealthKitOpaqueAnchor?
    public let observedAt: Date
    public let partial: Bool
    public let readability: HealthKitReadability

    public init(
        metric: HealthKitMetricID,
        additions: [HealthKitObservation],
        deletions: [HealthKitDeletionTombstone],
        nextAnchor: HealthKitOpaqueAnchor?,
        observedAt: Date,
        partial: Bool = false,
        readability: HealthKitReadability? = nil
    ) throws {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite else { throw HealthKitDomainError.invalidDate("observedAt") }
        guard additions.count <= HealthKitSafetyLimits.maxSyncBatchItems,
              deletions.count <= HealthKitSafetyLimits.maxSyncBatchItems,
              additions.count + deletions.count <= HealthKitSafetyLimits.maxSyncBatchItems else {
            throw HealthKitDomainError.invalidQuantity
        }
        guard additions.allSatisfy({ $0.metric == metric }) && deletions.allSatisfy({ $0.metric == metric }) else {
            throw HealthKitDomainError.invalidQuantity
        }
        self.metric = metric
        self.additions = additions
        self.deletions = deletions
        self.nextAnchor = nextAnchor
        self.observedAt = observedAt
        self.partial = partial
        self.readability = readability ??
            (additions.isEmpty && deletions.isEmpty && nextAnchor == nil ? .emptyIndeterminate : .established)
    }
}
