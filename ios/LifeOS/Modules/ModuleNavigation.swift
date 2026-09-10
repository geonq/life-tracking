import SwiftUI

/// The full internal route catalog. Release-visible navigation is defined by
/// explicit arrays below; keeping the compatibility cases here preserves old
/// deep links without exposing unfinished surfaces.
public enum LifeOSModule: String, CaseIterable, Hashable, Identifiable, Sendable {
    case home
    case finance
    case bankConnections = "bank-connections"
    case investments
    case business
    case tax
    case documents
    case calendar
    case tasks
    case grocery
    case shopping
    case fitness
    case reports
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .finance: "Finance"
        case .bankConnections: "Bank Connections"
        case .investments: "Investments"
        case .business: "Business"
        case .tax: "Tax"
        case .documents: "Documents"
        case .calendar: "Calendar"
        case .tasks: "Tasks"
        case .grocery: "Grocery"
        case .shopping: "Shopping"
        case .fitness: "Fitness"
        case .reports: "Reports"
        case .settings: "Settings"
        }
    }

    public var icon: LifeOSIconName {
        switch self {
        // The compact overview grid reads as a product surface at a glance;
        // `.home` remains in the icon catalog for older callers.
        case .home: .overview
        case .finance: .finance
        case .bankConnections: .bankConnections
        case .investments: .investments
        case .business: .business
        case .tax: .tax
        case .documents: .documents
        case .calendar: .calendar
        case .tasks: .tasks
        case .grocery: .grocery
        case .shopping: .shopping
        case .fitness: .fitness
        case .reports: .reports
        case .settings: .settings
        }
    }

    public var accent: Color {
        switch self {
        case .home: LifeOSTokens.Module.usage
        case .finance, .bankConnections, .investments: LifeOSTokens.Module.finance
        case .calendar: LifeOSTokens.Module.calendar
        case .fitness: LifeOSTokens.Module.fitness
        case .tasks, .grocery, .shopping: LifeOSTokens.Module.tasks
        case .tax, .business, .documents: LifeOSTokens.Module.tax
        case .reports: LifeOSTokens.Module.business
        case .settings: LifeOSTokens.secondaryText
        }
    }

    public var subtitle: String {
        switch self {
        case .home: "A quiet view of what matters now"
        case .finance: "Money in, money out, and what is connected"
        case .bankConnections: "Accounts, imports, and sync health"
        case .investments: "Holdings, performance, and income"
        case .business: "Revenue, expenses, and invoices"
        case .tax: "Documents, deductions, and tax position"
        case .documents: "One searchable place for your records"
        case .calendar: "Events, tasks, and obligations in time"
        case .tasks: "The next actions that need your attention"
        case .grocery: "A disposable list for the weekly shop"
        case .shopping: "Wishlist, comparisons, and purchases"
        case .fitness: "Health signals, recovery, and nutrition"
        case .reports: "Structured summaries across LifeOS"
        case .settings: "Privacy, sync, and app configuration"
        }
    }

    /// Existing views are kept reachable from navigation while the remaining
    /// modules use the honest shell below until their data contracts land.
    public var hasWorkingView: Bool {
        switch self {
        case .home, .calendar, .finance, .fitness, .tax, .settings: true
        default: false
        }
    }

    public var unavailableMessage: String {
        switch self {
        case .finance:
            "The Finance foundation is ready for connector wiring, but no account observations are connected yet."
        case .fitness:
            "Fitness is waiting for the reviewed Helio Strap → Zepp → HealthKit connection and permissions."
        case .bankConnections:
            "Bank connections are not enabled. Add an explicit, reviewed consent before any account can appear here."
        case .investments:
            "Investment holdings are not connected. Trade Republic remains manual CSV/PDF import only."
        case .business:
            "Business data is not connected yet. No revenue, expense, or invoice values are shown."
        case .documents:
            "The shared document library is not connected yet. Existing tax-document storage remains available under Tax."
        case .tasks:
            "Tasks are not implemented yet. Calendar events continue to work independently."
        case .grocery:
            "Grocery lists are not implemented yet."
        case .shopping:
            "Shopping lists are not implemented yet."
        case .reports:
            "Reports are not implemented yet. Connect a module before generating a summary."
        default:
            "This module is not connected yet."
        }
    }
}

public struct LifeOSModuleGroup: Identifiable, Hashable, Sendable {
    public let title: String
    public let modules: [LifeOSModule]

    public var id: String { title }

    public init(title: String, modules: [LifeOSModule]) {
        self.title = title
        self.modules = modules
    }
}

public extension LifeOSModule {
    /// Release-visible macOS destinations. Internal enum cases remain available
    /// for backwards-compatible deep links, but unfinished modules must not
    /// become accidental product navigation.
    static let macPrimaryModules: [LifeOSModule] = [
        .home, .calendar, .finance, .fitness, .tax, .settings
    ]

    /// The iOS More destination is intentionally small: infrequent, useful
    /// destinations only. Usage is opened from the Home usage card/detail.
    static let moreGroups: [LifeOSModuleGroup] = [
        .init(title: "More", modules: [.tax, .settings])
    ]
}

/// App-shell routing extends the widget route catalog without changing its legacy semantics.
enum LifeOSNavigationRoute: Equatable {
    case existing(LifeOSDeepLink)
    case home
    case destinationUnavailable

    init(url: URL) {
        if let route = LifeOSDeepLink(url: url) {
            self = .existing(route)
        } else {
            self = .destinationUnavailable
        }
    }

    init?(restorationKey: String) {
        guard !restorationKey.isEmpty else { return nil }
        if restorationKey == "home" {
            self = .home
        } else if let route = LifeOSDeepLink(restorationKey: restorationKey) {
            self = .existing(route)
        } else {
            return nil
        }
    }

    var restorationKey: String? {
        switch self {
        case .existing(let route): route.restorationKey
        case .home: "home"
        case .destinationUnavailable: nil
        }
    }

    var module: LifeOSModule {
        switch self {
        case .existing(let route): route.module
        case .home, .destinationUnavailable: .home
        }
    }

    static func restoredSecondaryModule(_ rawValue: String) -> LifeOSModule? {
        guard let module = LifeOSModule(rawValue: rawValue),
              LifeOSModule.moreGroups.flatMap(\.modules).contains(module) else { return nil }
        return module
    }
}

/// Shown when an external link does not resolve to a supported LifeOS route.
/// The shell owns recovery so this view never guesses a module or presents a
/// loading state for an address it cannot interpret.
struct LifeOSDestinationUnavailableView: View {
    let onBack: () -> Void
    let onHome: () -> Void

    var body: some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                LifeOSIcon(.warning, context: .card)
                    .foregroundStyle(LifeOSTokens.warning)

                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                    Text("Destination unavailable")
                        .lifeOSTypography(.cardTitle, weight: .semibold)
                        .foregroundStyle(LifeOSTokens.primaryText)
                    Text("This link does not match a supported LifeOS destination.")
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LifeOSTokens.Space.xs) {
                        actionButtons
                    }
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                        actionButtons
                    }
                }
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(LifeOSTokens.pageGutter)
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("destination-unavailable")
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Back", action: onBack)
            .buttonStyle(LifeOSButtonStyle(.secondary))
            .accessibilityIdentifier("destination-unavailable-back")
        Button("Home", action: onHome)
            .buttonStyle(LifeOSButtonStyle(.primary))
            .accessibilityIdentifier("destination-unavailable-home")
    }
}

public extension LifeOSDeepLink {
    /// A stable, local-only key for scene restoration. This is deliberately
    /// separate from URL parsing so persisted state never needs to retain a
    /// full external URL or any query data.
    var restorationKey: String {
        switch self {
        case .usage: "usage"
        case .calendar: "calendar"
        // Creating an event is a one-shot intent. Persist the normal calendar
        // route after the shell consumes it so a terminated scene never
        // reopens an editor from stale restoration state.
        case .newCalendarEvent: "calendar"
        case .tax: "tax"
        case .finance: "finance"
        case .financeSpend: "finance-spend"
        case .financeCashFlow: "finance-cash-flow"
        case .fitness: "fitness"
        case .fitnessTraining: "fitness-training"
        case .fitnessDailyOverview: "fitness-daily-overview"
        case .fitnessStrain: "fitness-strain"
        case .fitnessRecovery: "fitness-recovery"
        case .fitnessSleep: "fitness-sleep"
        case .fitnessHealthMonitor: "fitness-health-monitor"
        case .fitnessRespiration: "fitness-respiration"
        case .fitnessHeartRate: "fitness-heart-rate"
        case .fitnessHRV: "fitness-hrv"
        case .fitnessSpO2: "fitness-spo2"
        case .fitnessTemperature: "fitness-temperature"
        case .fitnessSleepDuration: "fitness-sleep-duration"
        case .fitnessNutrition: "fitness-nutrition"
        case .fitnessNutritionGoals: "fitness-nutrition-goals"
        case .fitnessNutritionImport: "fitness-nutrition-import"
        case .fitnessNutritionCamera: "fitness-nutrition-camera"
        case .fitnessNutritionBarcode: "fitness-nutrition-barcode"
        case .fitnessNutritionAIProposal: "fitness-nutrition-ai-proposal"
        case .fitnessNutritionSearch: "fitness-nutrition-search"
        case .fitnessNetEnergy: "fitness-net-energy"
        case .fitnessStress: "fitness-stress"
        case .fitnessEnergyReserve: "fitness-energy-reserve"
        case .tasks: "tasks"
        case .settings: "settings"
        }
    }

    init?(restorationKey: String) {
        switch restorationKey {
        case "usage": self = .usage
        case "calendar": self = .calendar
        case "new-calendar-event": self = .newCalendarEvent
        case "tax": self = .tax
        case "finance": self = .finance
        case "finance-spend": self = .financeSpend
        case "finance-cash-flow": self = .financeCashFlow
        case "fitness": self = .fitness
        case "fitness-training": self = .fitnessTraining
        case "fitness-daily-overview": self = .fitnessDailyOverview
        case "fitness-strain": self = .fitnessStrain
        case "fitness-recovery": self = .fitnessRecovery
        case "fitness-sleep": self = .fitnessSleep
        case "fitness-health-monitor": self = .fitnessHealthMonitor
        case "fitness-respiration": self = .fitnessRespiration
        case "fitness-heart-rate": self = .fitnessHeartRate
        case "fitness-hrv": self = .fitnessHRV
        case "fitness-spo2": self = .fitnessSpO2
        case "fitness-temperature": self = .fitnessTemperature
        case "fitness-sleep-duration": self = .fitnessSleepDuration
        case "fitness-nutrition": self = .fitnessNutrition
        case "fitness-nutrition-goals": self = .fitnessNutritionGoals
        case "fitness-nutrition-import": self = .fitnessNutritionImport
        case "fitness-nutrition-camera": self = .fitnessNutritionCamera
        case "fitness-nutrition-barcode": self = .fitnessNutritionBarcode
        case "fitness-nutrition-ai-proposal": self = .fitnessNutritionAIProposal
        case "fitness-nutrition-search": self = .fitnessNutritionSearch
        case "fitness-net-energy": self = .fitnessNetEnergy
        case "fitness-stress": self = .fitnessStress
        case "fitness-energy-reserve": self = .fitnessEnergyReserve
        case "tasks": self = .tasks
        case "settings": self = .settings
        default: return nil
        }
    }

    var module: LifeOSModule {
        switch self {
        case .usage: .home
        case .calendar, .newCalendarEvent: .calendar
        case .tax: .tax
        case .finance, .financeSpend, .financeCashFlow: .finance
        case .fitness, .fitnessTraining, .fitnessDailyOverview, .fitnessStrain, .fitnessRecovery, .fitnessSleep,
             .fitnessHealthMonitor, .fitnessRespiration, .fitnessHeartRate, .fitnessHRV, .fitnessSpO2,
             .fitnessTemperature, .fitnessSleepDuration, .fitnessNutrition, .fitnessNutritionGoals, .fitnessNutritionImport,
             .fitnessNutritionCamera, .fitnessNutritionBarcode, .fitnessNutritionAIProposal,
             .fitnessNutritionSearch, .fitnessNetEnergy, .fitnessStress, .fitnessEnergyReserve: .fitness
        case .tasks: .calendar
        case .settings: .settings
        }
    }

    var sectionTitle: String? {
        switch self {
        case .financeSpend: "Spend"
        case .financeCashFlow: "Cash Flow"
        case .fitnessDailyOverview: "Daily Overview"
        case .fitnessTraining: "Training"
        case .fitnessStrain: "Strain"
        case .fitnessRecovery: "Recovery"
        case .fitnessSleep: "Sleep"
        case .fitnessHealthMonitor: "Health Monitor"
        case .fitnessRespiration: "Respiration"
        case .fitnessHeartRate: "Heart rate"
        case .fitnessHRV: "HRV"
        case .fitnessSpO2: "SpO₂"
        case .fitnessTemperature: "Temperature"
        case .fitnessSleepDuration: "Sleep duration"
        case .fitnessNutrition: "Nutrition"
        case .fitnessNutritionGoals: "Nutrition goals"
        case .fitnessNutritionImport: "Import food photo"
        case .fitnessNutritionCamera: "Camera capture"
        case .fitnessNutritionBarcode: "Barcode capture"
        case .fitnessNutritionAIProposal: "AI photo proposal"
        case .fitnessNutritionSearch: "Food search"
        case .fitnessNetEnergy: "Net Energy"
        case .fitnessStress: "Stress"
        case .fitnessEnergyReserve: "Energy Reserve"
        case .newCalendarEvent: "New Event"
        default: nil
        }
    }

    var fitnessSection: FitnessSection {
        switch self {
        case .fitnessNutrition, .fitnessNutritionGoals, .fitnessNutritionImport,
             .fitnessNutritionCamera, .fitnessNutritionBarcode, .fitnessNutritionAIProposal,
             .fitnessNutritionSearch, .fitnessNetEnergy: .nutrition
        case .fitnessTraining: .training
        case .fitness, .fitnessDailyOverview, .fitnessStrain, .fitnessRecovery, .fitnessSleep,
             .fitnessHealthMonitor, .fitnessRespiration, .fitnessHeartRate, .fitnessHRV, .fitnessSpO2,
             .fitnessTemperature, .fitnessSleepDuration: .today
        case .fitnessStress, .fitnessEnergyReserve: .today
        default: .today
        }
    }

    var nutritionEntryPoint: FitnessNutritionEntryPoint? {
        switch self {
        case .fitnessNutritionGoals: .goals
        case .fitnessNetEnergy: .netEnergy
        case .fitnessNutritionImport: .capture(.photoLibrary)
        case .fitnessNutritionCamera: .capture(.camera)
        case .fitnessNutritionBarcode: .capture(.barcode)
        case .fitnessNutritionAIProposal: .capture(.aiProposal)
        case .fitnessNutritionSearch: .capture(.search)
        case .fitnessNutrition: .overview
        default: nil
        }
    }

    var fitnessEntryPoint: FitnessWidgetEntryPoint? {
        switch self {
        case .fitnessDailyOverview: .dailyOverview
        case .fitnessStrain: .strain
        case .fitnessRecovery: .recovery
        case .fitnessSleep: .sleep
        case .fitnessHealthMonitor: .healthMonitor
        case .fitnessStress: .stress
        case .fitnessEnergyReserve: .energyReserve
        case .fitnessRespiration: .healthMetric(.respiration)
        case .fitnessHeartRate: .healthMetric(.heartRate)
        case .fitnessHRV: .healthMetric(.hrv)
        case .fitnessSpO2: .healthMetric(.spo2)
        case .fitnessTemperature: .healthMetric(.temperature)
        case .fitnessSleepDuration: .healthMetric(.sleepDuration)
        default: nil
        }
    }
}

/// A deliberately honest landing shell for module work that is not connected
/// or has not passed its release gates yet. It never contains synthetic
/// metrics; fixture mode only adds a clearly labelled structural preview.
public struct LifeOSModuleLandingView: View {
    public let module: LifeOSModule
    public let route: LifeOSDeepLink?
    public let usesVisualFixtures: Bool

    public init(module: LifeOSModule, route: LifeOSDeepLink? = nil, usesVisualFixtures: Bool = false) {
        self.module = module
        self.route = route
        self.usesVisualFixtures = usesVisualFixtures
    }

    public var body: some View {
        landingBody
    }

    private var landingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LifeOSTokens.sectionGap) {
                header
                statusCard
                if let section = route?.sectionTitle {
                    routeCard(section: section)
                }
                if usesVisualFixtures {
                    previewStructure
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, LifeOSTokens.pageGutter)
            .padding(.vertical, LifeOSTokens.Space.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        // The content owns the one page title. The surrounding More stack
        // supplies back navigation without repeating the module name in a
        // second large toolbar title.
        .accessibilityIdentifier("module-landing-\(module.rawValue)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
            LifeOSIcon(module.icon, context: .navigation)
                .foregroundStyle(module.accent)

            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text(module.title)
                    .lifeOSTypography(.pageTitle)
                Text(module.subtitle)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                HStack(spacing: LifeOSTokens.Space.xs) {
                    Circle()
                        .fill(LifeOSTokens.warning)
                        .frame(width: 6, height: 6)
                    Text("Not connected")
                        .lifeOSTypography(.label, weight: .medium)
                        .foregroundStyle(LifeOSTokens.warning)
                }
                Text(module.unavailableMessage)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Connect a source in Settings to see current data here.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module-landing-status")
    }

    private func routeCard(section: String) -> some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                Text("Requested view")
                    .lifeOSTypography(.metadata, weight: .medium)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                Text("\(module.title) / \(section)")
                    .lifeOSTypography(.body, weight: .semibold)
                Text("This destination will show its data when a source is connected.")
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module-route-context")
    }

    private var previewStructure: some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                Text("Demo preview")
                    .lifeOSTypography(.cardTitle, weight: .semibold)
                    .foregroundStyle(LifeOSTokens.warning)
                ForEach(["Overview", "Recent activity", "Trends"], id: \.self) { label in
                    HStack {
                        Text(label)
                            .lifeOSTypography(.body, weight: .medium)
                        Spacer()
                        Text("Unavailable")
                            .lifeOSTypography(.body, weight: .semibold)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    .padding(.vertical, LifeOSTokens.Space.xxs)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module-landing-preview-structure")
    }
}

/// Secondary iOS destinations live behind one readable More screen. Existing
/// working views are handed back to the app shell; unfinished modules push the
/// landing shell in this navigation stack.
public struct LifeOSMoreModulesView: View {
    private let usesVisualFixtures: Bool
    private let destinationForModule: (LifeOSModule, LifeOSDeepLink?) -> AnyView
    @State private var selectedModule: LifeOSModule?
    @State private var restoredOnce = false
    @SceneStorage("LifeOS.More.selectedModule.v1") private var restoredModule = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let initialModule: LifeOSModule?

    public init(
        initialModule: LifeOSModule? = nil,
        initialRoute: LifeOSDeepLink? = nil,
        usesVisualFixtures: Bool = false,
        destinationForModule: @escaping (LifeOSModule, LifeOSDeepLink?) -> AnyView
    ) {
        self.initialModule = initialModule
        self.usesVisualFixtures = usesVisualFixtures
        self.destinationForModule = destinationForModule
        _selectedModule = State(initialValue: initialModule)
        self.initialRoute = initialRoute
    }

    private let initialRoute: LifeOSDeepLink?

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LifeOSTokens.sectionGap) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                        Text("More")
                            .lifeOSTypography(.pageTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        Text("The rest of LifeOS, grouped so it stays easy to reach one-handed.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(LifeOSModule.moreGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .lifeOSTypography(.metadata, weight: .semibold)
                                .foregroundStyle(LifeOSTokens.secondaryText)

                            VStack(spacing: 0) {
                                ForEach(group.modules) { module in
                                    moduleRow(module)
                                    if module.id != group.modules.last?.id {
                                        Divider().padding(.leading, 52)
                                    }
                                }
                            }
                            .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
                            .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, LifeOSTokens.pageGutter)
                .padding(.top, LifeOSTokens.Space.lg)
                .padding(.bottom, LifeOSTokens.Space.xxl)
            }
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .accessibilityIdentifier("more-modules-screen")
            .onAppear {
                guard !restoredOnce else { return }
                restoredOnce = true
                if selectedModule == nil {
                    selectedModule = initialModule ?? LifeOSNavigationRoute.restoredSecondaryModule(restoredModule)
                }
            }
            .onChange(of: initialModule) { _, module in selectedModule = module }
            .onChange(of: selectedModule) { _, module in restoredModule = module?.rawValue ?? "" }
            .navigationDestination(item: $selectedModule) { module in
                destinationForModule(module, module == initialRoute?.module ? initialRoute : nil)
            }
        }
    }

    private func moduleRow(_ module: LifeOSModule) -> some View {
        let selected = selectedModule == module
        return Button {
            selectedModule = module
        } label: {
            HStack(spacing: LifeOSTokens.Space.sm) {
                Capsule(style: .continuous)
                    .fill(selected ? LifeOSTokens.accent : .clear)
                    .frame(width: 2, height: 16)
                LifeOSIcon(module.icon, context: .navigation)
                    .foregroundStyle(selected ? LifeOSTokens.selectedNavigationText : LifeOSTokens.secondaryText)
                Text(module.title)
                    .lifeOSTypography(.label, weight: .medium)
                    .foregroundStyle(selected ? LifeOSTokens.selectedNavigationText : LifeOSTokens.secondaryText)
                Spacer(minLength: LifeOSTokens.Space.sm)
                LifeOSIcon(.chevronRight, context: .disclosure)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            .padding(.horizontal, LifeOSTokens.Space.sm)
            .frame(minHeight: LifeOSTokens.Control.standardHeight)
            .background(
                selected ? LifeOSTokens.selectedNavigationFill : .clear,
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : LifeOSMotion.selector, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(module.title)
        .accessibilityValue(module.hasWorkingView ? "Available" : "Not connected")
        .accessibilityIdentifier("more-module-\(module.rawValue)")
    }
}
