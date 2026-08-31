import SwiftUI
import Iconoir

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

    fileprivate var icon: Iconoir {
        switch self {
        case .overview: .viewGrid
        case .home: .home
        case .usage: .graphUp
        case .clipper: .clipboardCheck
        case .health: .heart
        case .finance: .bank
        case .bankConnections: .link
        case .investments: .statsUpSquare
        case .business: .suitcase
        case .calendar: .calendar
        case .tax: .pageSearch
        case .documents: .page
        case .tasks: .taskList
        case .grocery: .cart
        case .shopping: .shoppingBag
        case .reports: .reports
        case .fitness: .activity
        case .settings: .settings
        case .more: .list
        case .chevronLeft: .navArrowLeft
        case .chevronRight: .navArrowRight
        case .zoomIn: .zoomIn
        case .zoomOut: .zoomOut
        case .views: .eye
        case .subscribers: .userPlus
        case .revenue: .handCash
        case .heartRate: .heart
        case .sleep: .moonSat
        case .savings: .piggyBank
        case .budget: .wallet
        case .cashFlow: .dataTransferBoth
        case .income: .dataTransferUp
        case .spending: .dataTransferDown
        case .netWorth: .coins
        case .coins: .coins
        case .graphUp: .graphUp
        case .add: .plus
        case .calendarPlus: .calendarPlus
        case .search: .search
        case .undo: .undo
        case .refresh: .refresh
        case .assistant: .chatBubble
        case .security: .lock
        case .verified: .badgeCheck
        case .warning: .warningTriangle
        case .image: .mediaImage
        case .empty: .sunLight
        case .done: .checkCircle
        case .aborted: .warningCircle
        case .planned: .circle
        case .inProgress: .clock
        case .importDocument: .pagePlus
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
        name.icon.asImage
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
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
