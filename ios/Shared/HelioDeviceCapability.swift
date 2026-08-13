import Foundation

/// The route by which a Helio capability could reach LifeOS.  A route is not
/// evidence that this build can read the capability; the inventory below keeps
/// that distinction explicit.
public enum HelioDeviceSourcePath: String, Codable, CaseIterable, Sendable {
    case appleHealthExportCandidate = "apple_health_export_candidate"
    case publicBluetoothHeartRateBroadcast = "public_bluetooth_heart_rate_broadcast"
    case zeppDerivedNoPublicIOSInterface = "zepp_derived_no_public_ios_interface"
    case zeppOnlyExternalControls = "zepp_only_external_controls"
    case officialBatteryInterfacePending = "official_battery_interface_pending"

    public var title: String {
        switch self {
        case .appleHealthExportCandidate: "Apple Health export candidate"
        case .publicBluetoothHeartRateBroadcast: "Public Bluetooth HR broadcast candidate"
        case .zeppDerivedNoPublicIOSInterface: "Zepp-derived · no public iOS interface"
        case .zeppOnlyExternalControls: "Zepp-only external controls"
        case .officialBatteryInterfacePending: "Official battery interface pending"
        }
    }

    public var detail: String {
        switch self {
        case .appleHealthExportCandidate:
            "Helio Strap → Zepp → Apple Health / HealthKit; device provenance is required before a value is observed."
        case .publicBluetoothHeartRateBroadcast:
            "Amazfit documents real-time Bluetooth heart-rate broadcast; a reviewed receiving path is still required."
        case .zeppDerivedNoPublicIOSInterface:
            "Zepp exposes the derived metric, but no public third-party iOS interface is verified."
        case .zeppOnlyExternalControls:
            "Pairing and device management remain in Zepp; no supported LifeOS control interface is verified."
        case .officialBatteryInterfacePending:
            "Battery remains unavailable pending an official interface or a reviewed physical BLE probe."
        }
    }

    /// Only the two candidate paths may carry a future observed metric.  The
    /// other paths are deliberately reserved for unavailable/external states.
    public var supportsObservedMetric: Bool {
        switch self {
        case .appleHealthExportCandidate, .publicBluetoothHeartRateBroadcast:
            true
        case .zeppDerivedNoPublicIOSInterface, .zeppOnlyExternalControls, .officialBatteryInterfacePending:
            false
        }
    }
}

public enum HelioDeviceCapabilityGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleHealthExport = "apple_health_export"
    case bluetooth = "bluetooth"
    case zeppDerived = "zepp_derived"
    case externalManagement = "external_management"
    case deviceStatus = "device_status"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleHealthExport: "Apple Health export candidates"
        case .bluetooth: "Bluetooth candidates"
        case .zeppDerived: "Zepp-derived metrics"
        case .externalManagement: "External device management"
        case .deviceStatus: "Device status"
        }
    }
}

public enum HelioDeviceCapabilityStatus: String, Codable, CaseIterable, Sendable {
    case unverified
    case observed
    case unavailable
    case externalZepp = "external_zepp"

    public var title: String {
        switch self {
        case .unverified: "Unverified"
        case .observed: "Observed"
        case .unavailable: "Unavailable"
        case .externalZepp: "External Zepp"
        }
    }
}

public enum HelioDeviceCapabilityID: String, Codable, CaseIterable, Identifiable, Sendable {
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "heart_rate_variability"
    case bloodOxygen = "blood_oxygen"
    case sleep = "sleep"
    case sleepStages = "sleep_stages"
    case naps = "naps"
    case vo2Max = "vo2_max"
    case workouts = "workouts"
    case activeEnergy = "active_energy"
    case heartRateBroadcast = "heart_rate_broadcast"
    case stress = "stress"
    case bioCharge = "bio_charge"
    case trainingLoad = "training_load"
    case trainingEffect = "training_effect"
    case recovery = "recovery"
    case pai = "pai"
    case sleepScore = "sleep_score"
    case pairing = "pairing"
    case firmware = "firmware"
    case reboot = "reboot"
    case configuration = "configuration"
    case battery = "battery"

    public var id: String { rawValue }
}

/// One row in the reviewed Helio capability matrix.  This is capability
/// metadata, not a metric value.  Values are accepted only by
/// `HelioDeviceMetricObservation` after a future adapter has supplied evidence.
public struct HelioDeviceCapability: Codable, Equatable, Identifiable, Sendable {
    public let id: HelioDeviceCapabilityID
    public let group: HelioDeviceCapabilityGroup
    public let title: String
    public let sourcePath: HelioDeviceSourcePath
    public let status: HelioDeviceCapabilityStatus
    public let detail: String

    /// Capability rows are part of the reviewed registry. Construction stays
    /// module-internal so a caller cannot manufacture an observed battery,
    /// firmware, or Zepp-management row and make it look like a live source.
    /// Future adapters must amend the canonical registry in a reviewed change.
    init(
        id: HelioDeviceCapabilityID,
        group: HelioDeviceCapabilityGroup,
        title: String,
        sourcePath: HelioDeviceSourcePath,
        status: HelioDeviceCapabilityStatus,
        detail: String
    ) {
        self.id = id
        self.group = group
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourcePath = sourcePath
        self.status = status
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id, group, title, sourcePath, status, detail
    }

    /// Decode only an exact row from the reviewed registry. This prevents a
    /// persisted or remote payload from changing a candidate into an observed
    /// capability (or turning an unavailable Zepp/battery row into a source).
    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(
            decoder,
            allowed: ["id", "group", "title", "sourcePath", "status", "detail"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(HelioDeviceCapabilityID.self, forKey: .id)
        let group = try container.decode(HelioDeviceCapabilityGroup.self, forKey: .group)
        let title = try container.decode(String.self, forKey: .title)
        let sourcePath = try container.decode(HelioDeviceSourcePath.self, forKey: .sourcePath)
        let status = try container.decode(HelioDeviceCapabilityStatus.self, forKey: .status)
        let detail = try container.decode(String.self, forKey: .detail)

        guard let canonical = Self.inventory.first(where: { $0.id == id }),
              canonical.group == group,
              canonical.title == title,
              canonical.sourcePath == sourcePath,
              canonical.status == status,
              canonical.detail == detail else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Capability does not match the reviewed Helio registry"
            )
        }
        self = canonical
    }

    public var statusTitle: String { status.title }

    /// The static inventory never carries a value.  A future importer must
    /// first publish a separate observed capability and matching provenance.
    public var canCarryObservedValue: Bool {
        guard let canonical = Self.inventory.first(where: { $0 == self }) else {
            return false
        }
        return canonical.status == .observed && canonical.sourcePath.supportsObservedMetric
    }

    /// Reviewed source-honest inventory for the Helio Strap.  Every candidate
    /// is intentionally unverified until a physical device and source metadata
    /// are observed by a supported adapter.
    public static let inventory: [HelioDeviceCapability] = [
        HelioDeviceCapability(id: .heartRate, group: .appleHealthExport, title: "Heart rate", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .restingHeartRate, group: .appleHealthExport, title: "Resting heart rate", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .heartRateVariability, group: .appleHealthExport, title: "Heart-rate variability", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .bloodOxygen, group: .appleHealthExport, title: "Blood oxygen (SpO₂)", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .sleep, group: .appleHealthExport, title: "Sleep", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .sleepStages, group: .appleHealthExport, title: "Sleep stages", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .naps, group: .appleHealthExport, title: "Naps", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .vo2Max, group: .appleHealthExport, title: "VO₂ max", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .workouts, group: .appleHealthExport, title: "Workouts", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),
        HelioDeviceCapability(id: .activeEnergy, group: .appleHealthExport, title: "Active energy", sourcePath: .appleHealthExportCandidate, status: .unverified, detail: "Candidate export · Helio device provenance is not observed."),

        HelioDeviceCapability(id: .heartRateBroadcast, group: .bluetooth, title: "Heart-rate broadcast", sourcePath: .publicBluetoothHeartRateBroadcast, status: .unverified, detail: "Public Bluetooth candidate · no reviewed receiver is present in this build."),

        HelioDeviceCapability(id: .stress, group: .zeppDerived, title: "Stress", sourcePath: .zeppDerivedNoPublicIOSInterface, status: .unavailable, detail: "Zepp-derived value · no public third-party iOS interface is verified."),
        HelioDeviceCapability(id: .bioCharge, group: .zeppDerived, title: "BioCharge", sourcePath: .zeppDerivedNoPublicIOSInterface, status: .unavailable, detail: "Zepp-derived value · no public third-party iOS interface is verified."),
        HelioDeviceCapability(id: .trainingLoad, group: .zeppDerived, title: "Training load", sourcePath: .zeppDerivedNoPublicIOSInterface, status: .unavailable, detail: "Zepp-derived value · no public third-party iOS interface is verified."),
        HelioDeviceCapability(id: .trainingEffect, group: .zeppDerived, title: "Training effect", sourcePath: .zeppDerivedNoPublicIOSInterface, status: .unavailable, detail: "Zepp-derived value · no public third-party iOS interface is verified."),
        HelioDeviceCapability(id: .recovery, group: .zeppDerived, title: "Recovery", sourcePath: .zeppDerivedNoPublicIOSInterface, status: .unavailable, detail: "Zepp-derived value · no public third-party iOS interface is verified."),
        HelioDeviceCapability(id: .pai, group: .zeppDerived, title: "PAI", sourcePath: .zeppDerivedNoPublicIOSInterface, status: .unavailable, detail: "Zepp-derived value · no public third-party iOS interface is verified."),
        HelioDeviceCapability(id: .sleepScore, group: .zeppDerived, title: "Sleep score", sourcePath: .zeppDerivedNoPublicIOSInterface, status: .unavailable, detail: "Zepp-derived value · no public third-party iOS interface is verified."),

        HelioDeviceCapability(id: .pairing, group: .externalManagement, title: "Pairing", sourcePath: .zeppOnlyExternalControls, status: .externalZepp, detail: "Complete pairing in Zepp; no verified LifeOS control path is present."),
        HelioDeviceCapability(id: .firmware, group: .externalManagement, title: "Firmware", sourcePath: .zeppOnlyExternalControls, status: .externalZepp, detail: "Check and install firmware in Zepp; no verified LifeOS control path is present."),
        HelioDeviceCapability(id: .reboot, group: .externalManagement, title: "Reboot", sourcePath: .zeppOnlyExternalControls, status: .externalZepp, detail: "Reboot from Zepp; no verified LifeOS control path is present."),
        HelioDeviceCapability(id: .configuration, group: .externalManagement, title: "Configuration", sourcePath: .zeppOnlyExternalControls, status: .externalZepp, detail: "Configure the device in Zepp; no verified LifeOS control path is present."),

        HelioDeviceCapability(id: .battery, group: .deviceStatus, title: "Battery", sourcePath: .officialBatteryInterfacePending, status: .unavailable, detail: "Unavailable pending an official interface or reviewed physical BLE probe; no percentage is inferred."),
    ]

    public static func inventory(in group: HelioDeviceCapabilityGroup) -> [HelioDeviceCapability] {
        inventory.filter { $0.group == group }
    }
}
