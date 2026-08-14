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
    case aiUsage = "ai-usage"
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
        case .aiUsage: "Usage"
        case .fitness: "Fitness"
        case .reports: "Reports"
        case .settings: "Settings"
        }
    }

    public var icon: LifeOSIconName {
        switch self {
        case .home: .home
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
        case .aiUsage: .usage
        case .fitness: .fitness
        case .reports: .reports
        case .settings: .settings
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
        case .aiUsage: "Usage, limits, and provider history"
        case .fitness: "Health signals, recovery, and nutrition"
        case .reports: "Structured summaries across LifeOS"
        case .settings: "Privacy, sync, and app configuration"
        }
    }

    /// Existing views are kept reachable from navigation while the remaining
    /// modules use the honest shell below until their data contracts land.
    public var hasWorkingView: Bool {
        switch self {
        case .home, .calendar, .finance, .fitness, .tax, .aiUsage, .settings, .tasks: true
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
        .home, .calendar, .tasks, .finance, .fitness, .tax, .settings
    ]

    /// The iOS More destination is intentionally small: infrequent, useful
    /// destinations only. Usage is opened from the Home usage card/detail.
    static let moreGroups: [LifeOSModuleGroup] = [
        .init(title: "More", modules: [.tasks, .tax, .settings])
    ]
}

public extension LifeOSDeepLink {
    var module: LifeOSModule {
        switch self {
        case .usage: .home
        case .calendar, .newCalendarEvent: .calendar
        case .tax: .tax
        case .finance, .financeSpend, .financeCashFlow: .finance
        case .fitness, .fitnessDailyOverview, .fitnessStrain, .fitnessRecovery, .fitnessSleep,
             .fitnessHealthMonitor, .fitnessRespiration, .fitnessHeartRate, .fitnessHRV, .fitnessSpO2,
             .fitnessTemperature, .fitnessSleepDuration, .fitnessNutrition, .fitnessNutritionGoals, .fitnessNutritionImport,
             .fitnessNutritionCamera, .fitnessNutritionBarcode, .fitnessNutritionAIProposal,
             .fitnessNutritionSearch, .fitnessNetEnergy, .fitnessStress, .fitnessEnergyReserve: .fitness
        case .tasks: .tasks
        case .settings: .settings
        }
    }

    var sectionTitle: String? {
        switch self {
        case .financeSpend: "Spend"
        case .financeCashFlow: "Cash Flow"
        case .fitnessDailyOverview: "Daily Overview"
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                if let section = route?.sectionTitle {
                    routeCard(section: section)
                }
                if usesVisualFixtures {
                    previewStructure
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle(module.title)
        .accessibilityIdentifier("module-landing-\(module.rawValue)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LifeOSTokens.accent.opacity(0.12))
                LifeOSIcon(module.icon)
                    .foregroundStyle(LifeOSTokens.accent)
                    .frame(width: 24, height: 24)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(module.title)
                    .font(LifeOSFont.spaceGrotesk(28, weight: .bold))
                Text(module.subtitle)
                    .font(LifeOSFont.inter(14))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(LifeOSTokens.warning)
                    .frame(width: 8, height: 8)
                Text("Not connected")
                    .font(LifeOSFont.inter(13, weight: .semiBold))
                    .foregroundStyle(LifeOSTokens.warning)
            }
            Text(module.unavailableMessage)
                .font(LifeOSFont.inter(14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Unavailable values stay unavailable until a reviewed source is available.")
                .font(LifeOSFont.inter(12))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module-landing-status")
    }

    private func routeCard(section: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requested view")
                .font(LifeOSFont.inter(11, weight: .semiBold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text("\(module.title) / \(section)")
                .font(LifeOSFont.inter(16, weight: .semiBold))
            Text("This route is ready for navigation, but its data surface is not connected in this build.")
                .font(LifeOSFont.inter(13))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.accent.opacity(0.07), in: LifeOSTokens.cardShape)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module-route-context")
    }

    private var previewStructure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DEMO · PREVIEW STRUCTURE · NOT LIVE DATA")
                .font(LifeOSFont.inter(10, weight: .bold))
                .tracking(0.65)
                .foregroundStyle(LifeOSTokens.warning)
            ForEach(["Overview", "Recent activity", "Trends"], id: \.self) { label in
                HStack {
                    Text(label)
                        .font(LifeOSFont.inter(13, weight: .medium))
                    Spacer()
                    Text("Unavailable")
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.warning.opacity(0.07), in: LifeOSTokens.cardShape)
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

    public init(
        initialModule: LifeOSModule? = nil,
        initialRoute: LifeOSDeepLink? = nil,
        usesVisualFixtures: Bool = false,
        destinationForModule: @escaping (LifeOSModule, LifeOSDeepLink?) -> AnyView
    ) {
        self.usesVisualFixtures = usesVisualFixtures
        self.destinationForModule = destinationForModule
        _selectedModule = State(initialValue: initialModule)
        self.initialRoute = initialRoute
    }

    private let initialRoute: LifeOSDeepLink?

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("The rest of LifeOS, grouped so it stays easy to reach one-handed.")
                        .font(LifeOSFont.inter(14))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(LifeOSModule.moreGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.uppercased())
                                .font(LifeOSFont.inter(11, weight: .bold))
                                .tracking(0.7)
                                .foregroundStyle(LifeOSTokens.tertiaryText)

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
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle("More")
            .accessibilityIdentifier("more-modules-screen")
            .navigationDestination(item: $selectedModule) { module in
                destinationForModule(module, module == initialRoute?.module ? initialRoute : nil)
            }
        }
    }

    private func moduleRow(_ module: LifeOSModule) -> some View {
        Button {
            selectedModule = module
        } label: {
            HStack(spacing: 14) {
                LifeOSIcon(module.icon)
                    .foregroundStyle(LifeOSTokens.accent)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title)
                        .font(LifeOSFont.inter(15, weight: .semiBold))
                        .foregroundStyle(.primary)
                    Text(module.hasWorkingView ? "Open" : "Not connected")
                        .font(LifeOSFont.inter(12))
                        .foregroundStyle(module.hasWorkingView ? LifeOSTokens.success : LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 12)
                LifeOSIcon(.chevronRight)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 15, height: 15)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(module.title)
        .accessibilityValue(module.hasWorkingView ? "Available" : "Not connected")
        .accessibilityIdentifier("more-module-\(module.rawValue)")
    }
}
