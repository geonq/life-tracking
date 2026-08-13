import Foundation

public enum HelioDeviceFreshness: String, Codable, CaseIterable, Sendable {
    case fresh
    case stale

    public var title: String {
        switch self {
        case .fresh: "Fresh"
        case .stale: "Stale"
        }
    }
}

/// Only live candidate routes can be named as an observation origin.  Fixtures
/// intentionally have no case here; `HelioDeviceFixtureObservation` remains a
/// separate, non-convertible type.
public enum HelioDeviceObservationOrigin: String, Codable, CaseIterable, Sendable {
    case appleHealthExport = "apple_health_export"
    case publicBluetoothHeartRateBroadcast = "public_bluetooth_heart_rate_broadcast"

    public var sourcePath: HelioDeviceSourcePath {
        switch self {
        case .appleHealthExport: .appleHealthExportCandidate
        case .publicBluetoothHeartRateBroadcast: .publicBluetoothHeartRateBroadcast
        }
    }
}

/// Provenance is an adapter boundary, not a claim that an adapter exists.
/// Construction is intentionally failable: source, device, timestamp, and
/// freshness must all be present and mutually consistent.
public struct HelioDeviceObservationProvenance: Codable, Equatable, Sendable {
    public static let defaultFreshnessWindow: TimeInterval = 15 * 60

    public let origin: HelioDeviceObservationOrigin
    public let sourcePath: HelioDeviceSourcePath
    public let source: String
    public let device: String
    public let observedAt: Date
    public let freshness: HelioDeviceFreshness

    private enum CodingKeys: String, CodingKey {
        case origin, sourcePath, source, device, observedAt, freshness
    }

    public init?(
        origin: HelioDeviceObservationOrigin,
        sourcePath: HelioDeviceSourcePath,
        source: String,
        device: String,
        observedAt: Date,
        freshness: HelioDeviceFreshness,
        now: Date = .now,
        freshnessWindow: TimeInterval = HelioDeviceObservationProvenance.defaultFreshnessWindow
    ) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = device.trimmingCharacters(in: .whitespacesAndNewlines)
        let age = now.timeIntervalSince(observedAt)
        guard origin.sourcePath == sourcePath,
              sourcePath.supportsObservedMetric,
              !source.isEmpty,
              !device.isEmpty,
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              freshnessWindow > 0,
              freshnessWindow.isFinite,
              age >= 0 else {
            return nil
        }

        switch freshness {
        case .fresh where age <= freshnessWindow:
            break
        case .stale where age > freshnessWindow:
            break
        default:
            return nil
        }

        self.origin = origin
        self.sourcePath = sourcePath
        self.source = source
        self.device = device
        self.observedAt = observedAt
        self.freshness = freshness
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(
            decoder,
            allowed: ["origin", "sourcePath", "source", "device", "observedAt", "freshness"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let origin = try container.decode(HelioDeviceObservationOrigin.self, forKey: .origin)
        let sourcePath = try container.decode(HelioDeviceSourcePath.self, forKey: .sourcePath)
        let source = try container.decode(String.self, forKey: .source)
        let device = try container.decode(String.self, forKey: .device)
        let observedAt = try container.decode(Date.self, forKey: .observedAt)
        let freshness = try container.decode(HelioDeviceFreshness.self, forKey: .freshness)
        let now = (decoder.userInfo[.lifeOSNow] as? Date) ?? .now

        guard let provenance = HelioDeviceObservationProvenance(
            origin: origin,
            sourcePath: sourcePath,
            source: source,
            device: device,
            observedAt: observedAt,
            freshness: freshness,
            now: now
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .freshness,
                in: container,
                debugDescription: "Helio observation provenance is inconsistent or incomplete"
            )
        }
        self = provenance
    }

    public var summary: String {
        "\(source) · \(device) · \(observedAt.formatted(date: .abbreviated, time: .shortened)) · \(freshness.title)"
    }
}

/// Fixtures have their own type and cannot be converted into live provenance.
/// This keeps demo/sample data from accidentally becoming an observed state.
public struct HelioDeviceFixtureObservation: Equatable, Sendable {
    public let label: String
    public let observedAt: Date

    public init(label: String, observedAt: Date) {
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.observedAt = observedAt
    }
}

public enum HelioDeviceConnectionState: String, Codable, CaseIterable, Sendable {
    case notConfigured = "not_configured"
    case permissionRequired = "permission_required"
    case availableUnverified = "available_unverified"
    case observed
    case partial
    case stale
    case conflict
    case unavailable
    case externalZepp = "external_zepp"

    public var title: String {
        switch self {
        case .notConfigured: "Not configured"
        case .permissionRequired: "Permission required"
        case .availableUnverified: "Available · unverified"
        case .observed: "Observed"
        case .partial: "Partial"
        case .stale: "Stale"
        case .conflict: "Conflict"
        case .unavailable: "Unavailable"
        case .externalZepp: "External Zepp"
        }
    }
}

/// Connection state plus optional evidence/reason.  The initializer rejects
/// observed/stale claims without matching provenance and normalizes them to a
/// safe unavailable state instead of allowing a value-less "Connected" claim.
public struct HelioDeviceConnection: Codable, Equatable, Sendable {
    public let state: HelioDeviceConnectionState
    public let provenance: HelioDeviceObservationProvenance?
    public let reason: String?

    private enum CodingKeys: String, CodingKey {
        case state, provenance, reason
    }

    public init(
        state: HelioDeviceConnectionState,
        provenance: HelioDeviceObservationProvenance? = nil,
        reason: String? = nil
    ) {
        let cleanReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = cleanReason.flatMap { $0.isEmpty ? nil : $0 }

        switch state {
        case .observed:
            guard let provenance, provenance.freshness == .fresh else {
                self.state = .unavailable
                self.provenance = nil
                self.reason = "Observed state requires source, device, timestamp, and fresh provenance."
                return
            }
            self.state = .observed
            self.provenance = provenance
            self.reason = normalizedReason
        case .stale:
            guard let provenance, provenance.freshness == .stale else {
                self.state = .unavailable
                self.provenance = nil
                self.reason = "Stale state requires source, device, timestamp, and stale provenance."
                return
            }
            self.state = .stale
            self.provenance = provenance
            self.reason = normalizedReason
        case .partial:
            self.state = .partial
            self.provenance = provenance
            self.reason = normalizedReason ?? "The source supplied only part of the expected device data."
        case .conflict:
            self.state = .conflict
            self.provenance = provenance
            self.reason = normalizedReason ?? "Source observations disagree."
        case .unavailable:
            self.state = .unavailable
            self.provenance = nil
            self.reason = normalizedReason ?? "No supported device observation is available."
        case .notConfigured, .permissionRequired, .availableUnverified, .externalZepp:
            self.state = state
            self.provenance = nil
            self.reason = normalizedReason
        }
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["state", "provenance", "reason"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(HelioDeviceConnectionState.self, forKey: .state)
        let provenance = try decodeStrictOptional(
            HelioDeviceObservationProvenance.self,
            forKey: .provenance,
            from: container
        )
        let reason = try decodeStrictOptional(String.self, forKey: .reason, from: container)
        let normalized = HelioDeviceConnection(state: state, provenance: provenance, reason: reason)

        // The public initializer is intentionally fail-safe for UI callers;
        // decoding is stricter and must reject a payload that tried to turn
        // an invalid observed/stale state into unavailable silently.
        guard normalized.state == state,
              normalized.provenance == provenance else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Helio connection state has invalid or mismatched provenance"
            )
        }
        self = normalized
    }

    public static let notConfigured = HelioDeviceConnection(state: .notConfigured)
    public static let permissionRequired = HelioDeviceConnection(state: .permissionRequired)
    public static let availableUnverified = HelioDeviceConnection(state: .availableUnverified)
    public static let externalZepp = HelioDeviceConnection(state: .externalZepp)

    public static func observed(_ provenance: HelioDeviceObservationProvenance) -> HelioDeviceConnection {
        HelioDeviceConnection(state: .observed, provenance: provenance)
    }

    public static func stale(_ provenance: HelioDeviceObservationProvenance) -> HelioDeviceConnection {
        HelioDeviceConnection(state: .stale, provenance: provenance)
    }

    public static func partial(_ reason: String, provenance: HelioDeviceObservationProvenance? = nil) -> HelioDeviceConnection {
        HelioDeviceConnection(state: .partial, provenance: provenance, reason: reason)
    }

    public static func conflict(_ reason: String, provenance: HelioDeviceObservationProvenance? = nil) -> HelioDeviceConnection {
        HelioDeviceConnection(state: .conflict, provenance: provenance, reason: reason)
    }

    public static func unavailable(_ reason: String) -> HelioDeviceConnection {
        HelioDeviceConnection(state: .unavailable, reason: reason)
    }

    public var title: String { state.title }

    public var detail: String {
        if let reason { return reason }
        switch state {
        case .notConfigured:
            return "No Helio/Zepp/Health source adapter is configured in this build."
        case .permissionRequired:
            return "The relevant health-source permission is required before an observation can be accepted."
        case .availableUnverified:
            return "A candidate source exists, but this device and source have not been observed together."
        case .observed:
            return provenance.map { "Observed · \($0.summary)" } ?? "Observed source evidence is unavailable."
        case .partial:
            return "The source supplied only part of the expected device data."
        case .stale:
            return provenance.map { "Stale · \($0.summary)" } ?? "The last source observation is stale."
        case .conflict:
            return "Source observations disagree."
        case .unavailable:
            return "No supported device observation is available."
        case .externalZepp:
            return "This device action remains in the Zepp app; no verified LifeOS control path exists."
        }
    }
}

public enum HelioDevicePermissionState: String, Codable, CaseIterable, Sendable {
    case notRequested = "not_requested"
    case permissionRequired = "permission_required"
    case pending
    case authorized
    case denied
    case revoked
    case unavailable

    public var title: String {
        switch self {
        case .notRequested: "Not requested"
        case .permissionRequired: "Permission required"
        case .pending: "Pending"
        case .authorized: "Authorized"
        case .denied: "Denied"
        case .revoked: "Revoked"
        case .unavailable: "Unavailable"
        }
    }

    public var detail: String {
        switch self {
        case .notRequested, .permissionRequired:
            "No permission request has been made by this build."
        case .pending:
            "The source permission workflow is still pending."
        case .authorized:
            "Permission is reported by the future adapter; source/device provenance is still required for values."
        case .denied:
            "The source permission was denied; no values are substituted."
        case .revoked:
            "The source permission was revoked; no values are substituted."
        case .unavailable:
            "This platform/build does not expose the required source permission."
        }
    }
}

public enum HelioDeviceBatteryEvidenceSource: String, Codable, CaseIterable, Sendable {
    case officialPublicInterface = "official_public_interface"
    case reviewedPhysicalProbe = "reviewed_physical_probe"
    case staticProductSpecification = "static_product_specification"
}

public struct HelioDeviceBatteryReading: Codable, Equatable, Sendable {
    public let levelPercent: Double
    public let evidenceSource: HelioDeviceBatteryEvidenceSource
    public let source: String
    public let device: String
    public let observedAt: Date
    public let freshness: HelioDeviceFreshness

    private enum CodingKeys: String, CodingKey {
        case levelPercent, evidenceSource, source, device, observedAt, freshness
    }

    public init?(
        levelPercent: Double,
        evidenceSource: HelioDeviceBatteryEvidenceSource,
        source: String,
        device: String,
        observedAt: Date,
        freshness: HelioDeviceFreshness,
        now: Date = .now,
        freshnessWindow: TimeInterval = HelioDeviceObservationProvenance.defaultFreshnessWindow
    ) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = device.trimmingCharacters(in: .whitespacesAndNewlines)
        let age = now.timeIntervalSince(observedAt)
        guard evidenceSource != .staticProductSpecification,
              levelPercent.isFinite,
              (0...100).contains(levelPercent),
              !source.isEmpty,
              !device.isEmpty,
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              freshnessWindow > 0,
              freshnessWindow.isFinite,
              age >= 0 else {
            return nil
        }
        switch freshness {
        case .fresh where age <= freshnessWindow:
            break
        case .stale where age > freshnessWindow:
            break
        default:
            return nil
        }
        self.levelPercent = levelPercent
        self.evidenceSource = evidenceSource
        self.source = source
        self.device = device
        self.observedAt = observedAt
        self.freshness = freshness
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(
            decoder,
            allowed: ["levelPercent", "evidenceSource", "source", "device", "observedAt", "freshness"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let levelPercent = try container.decode(Double.self, forKey: .levelPercent)
        let evidenceSource = try container.decode(HelioDeviceBatteryEvidenceSource.self, forKey: .evidenceSource)
        let source = try container.decode(String.self, forKey: .source)
        let device = try container.decode(String.self, forKey: .device)
        let observedAt = try container.decode(Date.self, forKey: .observedAt)
        let freshness = try container.decode(HelioDeviceFreshness.self, forKey: .freshness)
        let now = (decoder.userInfo[.lifeOSNow] as? Date) ?? .now

        guard let reading = HelioDeviceBatteryReading(
            levelPercent: levelPercent,
            evidenceSource: evidenceSource,
            source: source,
            device: device,
            observedAt: observedAt,
            freshness: freshness,
            now: now
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .levelPercent,
                in: container,
                debugDescription: "Helio battery reading has unsupported evidence or freshness"
            )
        }
        self = reading
    }

    public var summary: String {
        "Source: \(source) · Device: \(device) · Observed: \(observedAt.formatted(date: .abbreviated, time: .shortened)) · Freshness: \(freshness.title)"
    }
}

public enum HelioDeviceBatteryStatus: Codable, Equatable, Sendable {
    case unavailable(reason: String)
    case observed(HelioDeviceBatteryReading)

    public static let current = HelioDeviceBatteryStatus.unavailable(
        reason: "Battery percentage is unavailable pending an official interface or reviewed physical BLE probe."
    )

    public var title: String {
        switch self {
        case .unavailable: "Unavailable"
        case .observed(let reading): reading.freshness == .stale ? "Stale" : "Observed"
        }
    }

    public var detail: String {
        switch self {
        case .unavailable(let reason): reason
        case .observed(let reading):
            "\(reading.levelPercent.formatted(.number.precision(.fractionLength(0...1))))% · \(reading.summary)"
        }
    }
}

public enum HelioDeviceFirmwareStatus: Codable, Equatable, Sendable {
    case unavailable(reason: String)

    public static let current = HelioDeviceFirmwareStatus.unavailable(
        reason: "Firmware information is available in Zepp only; no official third-party iOS interface is verified."
    )

    public var title: String { "Unavailable" }
    public var detail: String {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

public enum HelioDeviceManagementAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case pairing
    case firmware
    case reboot
    case configuration

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pairing: "Pairing"
        case .firmware: "Firmware"
        case .reboot: "Reboot"
        case .configuration: "Configuration"
        }
    }
}

public enum HelioDeviceManagementState: Codable, Equatable, Sendable {
    case externalZepp(reason: String)

    public static let current = HelioDeviceManagementState.externalZepp(
        reason: "Pairing, firmware, reboot, and configuration remain external Zepp actions. No verified Zepp URL scheme is available, so LifeOS provides no dead deep link."
    )

    public var title: String { "External Zepp" }
    public var detail: String {
        switch self {
        case .externalZepp(let reason): reason
        }
    }
}

public enum HelioDeviceAuthorityStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case helioStrap = "helio_strap"
    case zepp
    case appleHealth = "apple_health"
    case healthKit = "health_kit"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .helioStrap: "Helio Strap"
        case .zepp: "Zepp"
        case .appleHealth: "Apple Health"
        case .healthKit: "HealthKit"
        }
    }
}

public struct HelioDeviceSettingsSnapshot: Equatable, Sendable {
    public let authorityChain: [HelioDeviceAuthorityStage]
    public let connection: HelioDeviceConnection
    public let permission: HelioDevicePermissionState
    public let lastSuccessfulSync: HelioDeviceObservationProvenance?
    public let capabilities: [HelioDeviceCapability]
    public let battery: HelioDeviceBatteryStatus
    public let firmware: HelioDeviceFirmwareStatus
    public let management: HelioDeviceManagementState

    public init(
        authorityChain: [HelioDeviceAuthorityStage] = [.helioStrap, .zepp, .appleHealth, .healthKit],
        connection: HelioDeviceConnection,
        permission: HelioDevicePermissionState,
        lastSuccessfulSync: HelioDeviceObservationProvenance? = nil,
        capabilities: [HelioDeviceCapability] = HelioDeviceCapability.inventory,
        battery: HelioDeviceBatteryStatus = .current,
        firmware: HelioDeviceFirmwareStatus = .current,
        management: HelioDeviceManagementState = .current
    ) {
        self.authorityChain = authorityChain
        self.connection = connection
        self.permission = permission
        self.lastSuccessfulSync = lastSuccessfulSync
        self.capabilities = capabilities
        self.battery = battery
        self.firmware = firmware
        self.management = management
    }

    public static let current = HelioDeviceSettingsSnapshot(
        connection: .notConfigured,
        permission: .permissionRequired
    )
}

/// A metric value accepted by a future importer.  It is impossible to create
/// one from the current unverified inventory or without matching provenance.
public struct HelioDeviceMetricObservation: Equatable, Sendable {
    public let capability: HelioDeviceCapabilityID
    public let value: Double
    public let unit: String
    public let provenance: HelioDeviceObservationProvenance

    public init?(
        capability: HelioDeviceCapability,
        value: Double,
        unit: String,
        provenance: HelioDeviceObservationProvenance
    ) {
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = HelioDeviceCapability.inventory.first(where: { $0 == capability }),
              canonical.canCarryObservedValue,
              value.isFinite,
              !unit.isEmpty,
              canonical.sourcePath == provenance.sourcePath else {
            return nil
        }
        self.capability = canonical.id
        self.value = value
        self.unit = unit
        self.provenance = provenance
    }

    /// Resolve by registry identity so future adapters cannot pass a
    /// hand-built capability row with an observed status.
    public init?(
        capabilityID: HelioDeviceCapabilityID,
        value: Double,
        unit: String,
        provenance: HelioDeviceObservationProvenance
    ) {
        guard let capability = HelioDeviceCapability.inventory.first(where: { $0.id == capabilityID }) else {
            return nil
        }
        self.init(capability: capability, value: value, unit: unit, provenance: provenance)
    }
}
