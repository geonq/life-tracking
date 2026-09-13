import SwiftUI

/// The product's single typography facade.
///
/// A `Font` is a value and cannot read SwiftUI's Dynamic Type environment after
/// it is created. Views therefore apply this facade through
/// `View.lifeOSTypography(_:)`, whose modifier owns the `@ScaledMetric`
/// property and applies the role's system font in the view's environment.
public enum LifeOSTypography {
    /// A semantic role with a custom base size and a Dynamic Type anchor.
    ///
    /// Base sizes are the Large/default content-size values from `design.md`.
    /// The anchors are deliberately the closest Apple text styles so the
    /// system applies the same scale curve on iOS and macOS.
    public enum Role: CaseIterable, Hashable {
        case pageTitle
        case sectionTitle
        case cardTitle
        case body
        case label
        case metadata
        case metric
        case metricCompact
        case inlineMonitoringValue
        case button

        public var baseSize: CGFloat {
#if os(macOS)
            switch self {
            case .pageTitle: 22
            case .sectionTitle: 15
            case .cardTitle: 14
            case .body: 13
            case .label, .button: 13
            case .metadata: 12
            case .metric: 28
            case .metricCompact: 22
            case .inlineMonitoringValue: 20
            }
#else
            switch self {
            case .pageTitle: 24
            case .sectionTitle: 18
            case .cardTitle: 16
            case .body: 17
            case .label, .button: 15
            case .metadata: 13
            case .metric: 30
            case .metricCompact: 24
            case .inlineMonitoringValue: 22
            }
#endif
        }

        public var defaultWeight: Font.Weight {
            switch self {
            case .pageTitle, .inlineMonitoringValue: .semibold
            case .sectionTitle, .cardTitle, .metric, .metricCompact, .button: .semibold
            case .body, .metadata: .regular
            case .label: .medium
            }
        }

        public var dynamicTypeAnchor: Font.TextStyle {
            switch self {
            case .pageTitle: .title
            case .sectionTitle: .title2
            case .cardTitle: .headline
            case .body: .body
            case .label: .subheadline
            case .metadata: .footnote
            case .metric: .largeTitle
            case .metricCompact: .title2
            case .inlineMonitoringValue: .title2
            case .button: .headline
            }
        }

        public var tracking: CGFloat {
            switch self {
            case .pageTitle: -0.3
            case .sectionTitle: -0.2
            case .metric: -0.4
            case .metricCompact: -0.3
            case .cardTitle, .body, .label, .metadata, .inlineMonitoringValue, .button: 0
            }
        }

        public var lineSpacing: CGFloat {
            0
        }

        public var usesMonospacedDigits: Bool {
            switch self {
            case .metric, .metricCompact, .inlineMonitoringValue: true
            default: false
            }
        }
    }

    /// Returns a Dynamic Type-aware modifier for a semantic role.
    public static func modifier(
        for role: Role,
        weight: Font.Weight? = nil
    ) -> RoleModifier {
        RoleModifier(role: role, weight: weight)
    }

    /// The implementation is public because the facade's modifier factory
    /// returns it, but callers should prefer `View.lifeOSTypography(_:)`.
    public struct RoleModifier: ViewModifier {
        private let role: Role
        private let weight: Font.Weight
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @ScaledMetric private var scaledSize: CGFloat

        fileprivate init(role: Role, weight: Font.Weight?) {
            self.role = role
            self.weight = weight ?? role.defaultWeight
            _scaledSize = ScaledMetric(
                wrappedValue: role.baseSize,
                relativeTo: role.dynamicTypeAnchor
            )
        }

        @ViewBuilder
        public func body(content: Content) -> some View {
            let tracking = dynamicTypeSize.isAccessibilitySize ? 0 : role.tracking
            if role.usesMonospacedDigits {
                content
                    .font(.system(size: scaledSize, weight: weight, design: .default))
                    .monospacedDigit()
                    .tracking(tracking)
                    .lineSpacing(role.lineSpacing)
            } else {
                content
                    .font(.system(size: scaledSize, weight: weight, design: .default))
                    .tracking(tracking)
                    .lineSpacing(role.lineSpacing)
            }
        }
    }
}

public extension View {
    /// Applies a LifeOS typography role with Dynamic Type scaling.
    ///
    /// This preserves the role's base size at the default content size and
    /// scales it from the declared Apple anchor.
    func lifeOSTypography(
        _ role: LifeOSTypography.Role,
        weight: Font.Weight? = nil
    ) -> some View {
        modifier(LifeOSTypography.modifier(for: role, weight: weight))
    }
}
