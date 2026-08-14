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
    case add
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
        case .usage: .terminal
        case .clipper: .statsUpSquare
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
        case .add: .plus
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
}

public struct LifeOSIcon: View {
    private let name: LifeOSIconName

    public init(_ name: LifeOSIconName) {
        self.name = name
    }

    public var body: some View {
        name.icon.asImage
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}
