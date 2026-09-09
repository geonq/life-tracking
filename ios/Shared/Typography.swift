import SwiftUI

/// The product's single typography facade.
///
/// The `Font` returning methods are retained as a source-compatible boundary
/// for existing screens. A `Font` is a value and cannot read SwiftUI's
/// Dynamic Type environment after it is created, so new or migrated views
/// should use `View.lifeOSTypography(_:)` below. That modifier owns the
/// `@ScaledMetric` property and applies the role's system font in the view's
/// environment.
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
        case button

        public var baseSize: CGFloat {
            switch self {
            case .pageTitle: 28
            case .sectionTitle: 20
            case .cardTitle, .body: 17
            case .label, .button: 15
            case .metadata: 13
            case .metric: 36
            case .metricCompact: 24
            }
        }

        public var defaultWeight: Font.Weight {
            switch self {
            case .pageTitle: .bold
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
            case .button: .headline
            }
        }

        public var tracking: CGFloat {
            switch self {
            case .pageTitle: -0.4
            case .sectionTitle: -0.2
            case .metric: -0.6
            case .metricCompact: -0.3
            case .cardTitle, .body, .label, .metadata, .button: 0
            }
        }

        public var lineSpacing: CGFloat {
            self == .body ? 3 : 0
        }

        public var usesMonospacedDigits: Bool {
            self == .metric || self == .metricCompact
        }
    }

    private static func systemFont(
        size: CGFloat,
        weight: Font.Weight
    ) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    public static func pageTitle(weight: Font.Weight = .bold) -> Font {
        systemFont(size: 28, weight: weight)
    }

    public static func sectionTitle(weight: Font.Weight = .semibold) -> Font {
        systemFont(size: 20, weight: weight)
    }

    public static func cardTitle(weight: Font.Weight = .semibold) -> Font {
        systemFont(size: 17, weight: weight)
    }

    public static func body(weight: Font.Weight = .regular) -> Font {
        systemFont(size: 17, weight: weight)
    }

    public static func label(weight: Font.Weight = .medium) -> Font {
        systemFont(size: 15, weight: weight)
    }

    public static func metadata(weight: Font.Weight = .regular) -> Font {
        systemFont(size: 13, weight: weight)
    }

    public static func metric(weight: Font.Weight = .semibold) -> Font {
        systemFont(size: 36, weight: weight).monospacedDigit()
    }

    public static func metricCompact(weight: Font.Weight = .semibold) -> Font {
        systemFont(size: 24, weight: weight).monospacedDigit()
    }

    public static func button(weight: Font.Weight = .semibold) -> Font {
        systemFont(size: 15, weight: weight)
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
    /// This is the migration API for screens whose old call sites used
    /// `.font(LifeOSTypography.body())`. It preserves the role's base size at
    /// the default content size and scales it from the declared Apple anchor.
    func lifeOSTypography(
        _ role: LifeOSTypography.Role,
        weight: Font.Weight? = nil
    ) -> some View {
        modifier(LifeOSTypography.modifier(for: role, weight: weight))
    }
}
