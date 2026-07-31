import SwiftUI
import Iconoir

public enum LifeOSIconName: Sendable {
    case overview
    case usage
    case clipper
    case health
    case finance
    case calendar
    case tax
    case settings
    case chevronLeft
    case chevronRight
    case views
    case subscribers
    case revenue
    case heartRate
    case sleep
    case savings
    case budget
    case add
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
        case .usage: .terminal
        case .clipper: .statsUpSquare
        case .health: .heart
        case .finance: .bank
        case .calendar: .calendar
        case .tax: .pageSearch
        case .settings: .settings
        case .chevronLeft: .navArrowLeft
        case .chevronRight: .navArrowRight
        case .views: .eye
        case .subscribers: .userPlus
        case .revenue: .handCash
        case .heartRate: .heart
        case .sleep: .moonSat
        case .savings: .piggyBank
        case .budget: .wallet
        case .add: .plus
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
