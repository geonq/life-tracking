import SwiftUI

/// A source-backed fitness value shared by the app, widgets, and detail
/// contracts. The shared location is intentional: widgets must be able to
/// compile fitness contracts without importing an app-only view.
public struct FitnessMetric: Identifiable {
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
        trend: [Double] = []
    ) {
        self.id = id ?? title
        self.title = title
        self.value = value
        self.unit = unit
        self.detail = detail
        self.quality = quality
        self.progress = progress
        self.hue = hue
        self.trend = trend
    }

    public static func unavailable(_ title: String) -> FitnessMetric {
        FitnessMetric(title: title, value: nil, unit: "", detail: "Connect a reviewed source to see this metric.", quality: .unavailable)
    }

    public static let defaultHealthMonitor: [FitnessMetric] = [
        unavailable("HRV"), unavailable("Resting heart rate"), unavailable("Respiration"),
        unavailable("Blood oxygen"), unavailable("Skin temperature"), unavailable("Sleep")
    ]

    public static let defaultBodyMetrics: [FitnessMetric] = [
        unavailable("Weight"), unavailable("Body fat"), unavailable("VO₂ max"), unavailable("HRV baseline")
    ]
}
