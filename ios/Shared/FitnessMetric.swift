import SwiftUI

/// A source-backed fitness value shared by the app, widgets, and detail
/// contracts. The shared location is intentional: widgets must be able to
/// compile fitness contracts without importing an app-only view.
public struct FitnessMetric: Identifiable {
    /// Availability is deliberately separate from `Quality`. Quality answers
    /// how a value was produced for presentation; this state answers whether
    /// the source is currently authoritative. Keeping the two fields separate
    /// lets a stale or partial value remain visible without presenting it as a
    /// fresh observation, and lets a conflict stay value-less.
    public enum SourceState: String, CaseIterable, Equatable, Sendable {
        case unavailable
        case permissionRequired = "permission_required"
        case deviceUnavailable = "device_unavailable"
        case readIndeterminate = "read_indeterminate"
        case calibrating
        case observed
        case partial
        case stale
        case conflict
        case error
        case derived
        case manual
        case demo

        public var label: String {
            switch self {
            case .unavailable: "Unavailable"
            case .permissionRequired: "Permission required"
            case .deviceUnavailable: "Device unavailable"
            case .readIndeterminate: "Read status unknown"
            case .calibrating: "Calibrating"
            case .observed: "Observed"
            case .partial: "Partial"
            case .stale: "Stale"
            case .conflict: "Conflict"
            case .error: "Source error"
            case .derived: "Derived"
            case .manual: "Manual"
            case .demo: "Demo fixture"
            }
        }

        /// A value can be rendered only when the state has an actual value
        /// contract. Conflict/permission/error states are intentionally
        /// value-less even if a caller accidentally supplies a string.
        public var canDisplayValue: Bool {
            switch self {
            case .observed, .partial, .stale, .derived, .manual, .demo:
                true
            case .unavailable, .permissionRequired, .deviceUnavailable,
                 .readIndeterminate, .calibrating, .conflict, .error:
                false
            }
        }

        public var requiresAttention: Bool {
            switch self {
            case .partial, .stale, .conflict, .permissionRequired,
                 .deviceUnavailable, .readIndeterminate, .calibrating, .error:
                true
            case .unavailable, .observed, .derived, .manual, .demo:
                false
            }
        }
    }

    /// Typed presentation provenance. The source/device/window/freshness
    /// tuple is required before a metric can be described as source-backed;
    /// optional observation and revision identifiers preserve the link to a
    /// source record without exposing HealthKit types in the generic contract.
    public struct Provenance: Equatable, Sendable {
        public let source: String
        public let device: String
        public let window: String
        public let freshness: String
        public let observationID: String?
        public let revision: String?

        public init?(
            source: String,
            device: String,
            window: String,
            freshness: String,
            observationID: String? = nil,
            revision: String? = nil
        ) {
            let values = [source, device, window, freshness].map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let observationID = observationID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let revision = revision?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard values.allSatisfy({ !$0.isEmpty }),
                  observationID == nil || observationID?.isEmpty == false,
                  revision == nil || revision?.isEmpty == false else {
                return nil
            }
            self.source = values[0]
            self.device = values[1]
            self.window = values[2]
            self.freshness = values[3]
            self.observationID = observationID
            self.revision = revision
        }

        public var summary: String {
            var result = "\(source) · \(device) · \(window) · \(freshness)"
            if let observationID { result += " · observation \(observationID)" }
            if let revision { result += " · revision \(revision)" }
            return result
        }
    }

    public enum Quality: Equatable {
        case unavailable, observed, derived, manual, demo

        public var label: String {
            switch self {
            case .unavailable: "Not available"
            case .observed: "Observed"
            case .derived: "Derived estimate"
            case .manual: "Manual"
            case .demo: "Demo fixture"
            }
        }
    }

    public let id: String
    public let title: String
    public let value: String?
    public let unit: String
    public let detail: String
    public let quality: Quality
    public let sourceState: SourceState
    public let provenance: Provenance?
    public let progress: Double?
    public let hue: LifeOSTokens.Hue
    public let trend: [Double]

    public init(
        id: String? = nil,
        title: String,
        value: String?,
        unit: String,
        detail: String,
        quality: Quality,
        progress: Double? = nil,
        hue: LifeOSTokens.Hue = .blue,
        trend: [Double] = [],
        sourceState: SourceState? = nil,
        provenance: Provenance? = nil
    ) {
        self.id = id ?? title
        self.title = title
        let resolvedSourceState = sourceState ?? Self.defaultSourceState(for: quality)
        self.value = resolvedSourceState.canDisplayValue ? value : nil
        self.unit = unit
        self.detail = detail
        self.quality = quality
        self.sourceState = resolvedSourceState
        self.provenance = provenance
        self.progress = resolvedSourceState.canDisplayValue ? progress : nil
        self.hue = hue
        self.trend = trend
    }

    public var isValueAvailable: Bool {
        sourceState.canDisplayValue && value != nil
    }

    public var provenanceSummary: String {
        provenance?.summary ?? detail
    }

    public static func unavailable(
        _ title: String,
        reason: String = "Connect a reviewed source to see this metric.",
        sourceState: SourceState = .unavailable,
        provenance: Provenance? = nil
    ) -> FitnessMetric {
        FitnessMetric(
            title: title,
            value: nil,
            unit: "",
            detail: reason,
            quality: .unavailable,
            sourceState: sourceState,
            provenance: provenance
        )
    }

    public static let defaultHealthMonitor: [FitnessMetric] = [
        unavailable("HRV"), unavailable("Resting heart rate"), unavailable("Respiration"),
        unavailable("Blood oxygen"), unavailable("Skin temperature"), unavailable("Sleep")
    ]

    public static let defaultBodyMetrics: [FitnessMetric] = [
        unavailable("Weight"), unavailable("Body fat"), unavailable("VO₂ max"), unavailable("HRV baseline")
    ]

    private static func defaultSourceState(for quality: Quality) -> SourceState {
        switch quality {
        case .unavailable: .unavailable
        case .observed: .observed
        case .derived: .derived
        case .manual: .manual
        case .demo: .demo
        }
    }
}
