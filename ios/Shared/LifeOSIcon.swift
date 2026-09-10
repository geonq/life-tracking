import SwiftUI

public enum LifeOSIconName: Sendable {
    case overview
    case home
    case usage
    case clipper
    case health
    case finance
    case bankConnections
    case investments
    case business
    case calendar
    case tax
    case documents
    case tasks
    case grocery
    case shopping
    case reports
    case fitness
    case settings
    case more
    case close
    case chevronLeft
    case chevronRight
    case zoomIn
    case zoomOut
    case views
    case subscribers
    case revenue
    case heartRate
    case sleep
    case savings
    case budget
    case cashFlow
    case income
    case spending
    case netWorth
    case coins
    case graphUp
    case add
    case calendarPlus
    case search
    case undo
    case refresh
    case security
    case verified
    case warning
    case image
    case empty
    case done
    case aborted
    case planned
    case inProgress
    case importDocument

    /// The exact SF Symbol used for this semantic icon. Keeping the mapping
    /// centralized prevents route-specific weight and glyph drift.
    public var systemImageName: String {
        switch self {
        // `overview` is the compact product mark used by the primary shell.
        // Keep the legacy `.home` case below for older widget/deep-link callers.
        case .overview: "square.grid.2x2"
        case .home: "house"
        case .usage: "chart.bar.xaxis"
        case .clipper: "chart.xyaxis.line"
        case .health: "waveform.path.ecg"
        case .finance: "creditcard"
        case .bankConnections: "link"
        case .investments: "chart.line.uptrend.xyaxis"
        case .business: "briefcase"
        case .calendar: "calendar"
        case .tax: "doc.text"
        case .documents: "folder"
        case .tasks: "checklist"
        case .grocery: "basket"
        case .shopping: "bag"
        case .reports: "chart.bar.doc"
        case .fitness: "figure.strengthtraining.traditional"
        case .settings: "gearshape"
        case .more: "ellipsis"
        case .close: "xmark"
        case .chevronLeft: "chevron.left"
        case .chevronRight: "chevron.right"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .views: "eye"
        case .subscribers: "person.2"
        case .revenue: "banknote"
        case .heartRate: "waveform.path.ecg"
        case .sleep: "moon.zzz"
        case .savings: "dollarsign.circle"
        case .budget: "wallet.pass"
        case .cashFlow: "arrow.left.arrow.right"
        case .income: "arrow.up"
        case .spending: "arrow.down"
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .coins: "circle.hexagongrid"
        case .graphUp: "chart.line.uptrend.xyaxis"
        case .add: "plus"
        case .calendarPlus: "calendar.badge.plus"
        case .search: "magnifyingglass"
        case .undo: "arrow.uturn.backward"
        case .refresh: "arrow.clockwise"
        case .security: "lock"
        case .verified: "checkmark.seal"
        case .warning: "exclamationmark.triangle"
        case .image: "photo"
        case .empty: "sun.max"
        case .done: "checkmark.circle"
        case .aborted: "xmark.circle"
        case .planned: "circle"
        case .inProgress: "clock"
        case .importDocument: "doc.badge.plus"
        }
    }

    /// Stable spoken names for icons that are exposed directly in an
    /// accessibility tree. Most instances stay decorative because their
    /// containing control supplies the complete label, but the catalog keeps
    /// a fitting name available for standalone graphics and widget cells.
    public var accessibilityLabel: String {
        switch self {
        case .overview: "Overview"
        case .home: "Home"
        case .usage: "Usage"
        case .clipper: "Clipper"
        case .health: "Health"
        case .finance: "Finance"
        case .bankConnections: "Bank connections"
        case .investments: "Investments"
        case .business: "Business"
        case .calendar: "Calendar"
        case .tax: "Tax documents"
        case .documents: "Documents"
        case .tasks: "Tasks"
        case .grocery: "Grocery"
        case .shopping: "Shopping"
        case .reports: "Reports"
        case .fitness: "Fitness"
        case .settings: "Settings"
        case .more: "More"
        case .close: "Close"
        case .chevronLeft: "Back"
        case .chevronRight: "Open"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .views: "View"
        case .subscribers: "Subscribers"
        case .revenue: "Revenue"
        case .heartRate: "Heart rate"
        case .sleep: "Sleep"
        case .savings: "Savings"
        case .budget: "Budget"
        case .cashFlow: "Cash flow"
        case .income: "Income"
        case .spending: "Spending"
        case .netWorth: "Net worth"
        case .coins: "Coins"
        case .graphUp: "Growth"
        case .add: "Add"
        case .calendarPlus: "Add calendar event"
        case .search: "Search"
        case .undo: "Undo"
        case .refresh: "Refresh"
        case .security: "Security"
        case .verified: "Verified"
        case .warning: "Warning"
        case .image: "Image"
        case .empty: "Empty"
        case .done: "Done"
        case .aborted: "Aborted"
        case .planned: "Planned"
        case .inProgress: "In progress"
        case .importDocument: "Import document"
        }
    }
}

/// Semantic icon geometry. The default keeps the existing 24-point box and
/// 17-point glyph so existing callers retain their layout. Compact contexts
/// choose a smaller visual symbol without shrinking the surrounding control's
/// hit target.
public enum LifeOSIconContext: Sendable {
    case standard
    case navigation
    case card
    case toolbar
    case disclosure

    public var box: CGFloat {
#if os(macOS)
        switch self {
        case .standard: LifeOSTokens.Icon.box
        case .navigation: LifeOSTokens.Icon.statusBox
        case .card: LifeOSTokens.Icon.statusBox
        case .toolbar, .disclosure: 18
        }
#else
        switch self {
        case .standard, .navigation, .toolbar: LifeOSTokens.Icon.box
        case .card: LifeOSTokens.Icon.statusBox
        case .disclosure: 20
        }
#endif
    }

    public var glyph: CGFloat {
#if os(macOS)
        switch self {
        case .standard: LifeOSTokens.Icon.glyph
        case .navigation: 15
        case .card: 14
        case .toolbar: 14
        case .disclosure: 12
        }
#else
        switch self {
        case .standard: LifeOSTokens.Icon.glyph
        case .navigation: 18
        case .card: 14
        case .toolbar: 17
        case .disclosure: 14
        }
#endif
    }

    public var weight: Font.Weight {
        switch self {
        case .standard, .toolbar: .medium
        case .navigation, .card, .disclosure: .regular
        }
    }
}

public struct LifeOSIcon: View {
    private let name: LifeOSIconName
    private let context: LifeOSIconContext
    private let explicitAccessibilityLabel: String?

    public init(
        _ name: LifeOSIconName,
        accessibilityLabel: String? = nil,
        context: LifeOSIconContext = .standard
    ) {
        self.name = name
        self.context = context
        self.explicitAccessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        Image(systemName: name.systemImageName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: context.glyph, weight: context.weight, design: .default))
            .frame(width: context.box, height: context.box)
            .modifier(LifeOSIconAccessibilityModifier(label: explicitAccessibilityLabel))
    }
}

private struct LifeOSIconAccessibilityModifier: ViewModifier {
    let label: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let label, !label.isEmpty {
            content.accessibilityLabel(label)
        } else {
            content.accessibilityHidden(true)
        }
    }
}
