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
    case assistant
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

    fileprivate var systemName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .home: "house"
        case .usage: "chart.bar"
        case .clipper: "checklist"
        case .health: "heart"
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
        case .reports: "chart.bar.doc.horizontal"
        case .fitness: "heart"
        case .settings: "gearshape"
        case .more: "ellipsis"
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
        case .assistant: "sparkles"
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
        case .assistant: "Assistant"
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

public struct LifeOSIcon: View {
    private let name: LifeOSIconName
    private let explicitAccessibilityLabel: String?

    public init(_ name: LifeOSIconName, accessibilityLabel: String? = nil) {
        self.name = name
        self.explicitAccessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        Image(systemName: name.systemName)
            .renderingMode(.template)
            .font(.system(size: 17, weight: .medium, design: .default))
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
