import SwiftUI

struct RetainedHealthDataSettings: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case unavailable
        case observed
        case partial
        case stale
        case conflict
        case readIndeterminate
        case error
    }

    let status: Status
    let sampleCount: Int
    let categoryCount: Int
    let confirmedHelioCategoryCount: Int
    let latestObservation: Date?

    init(
        status: Status,
        sampleCount: Int,
        categoryCount: Int,
        confirmedHelioCategoryCount: Int,
        latestObservation: Date?
    ) {
        self.status = status
        self.sampleCount = sampleCount
        self.categoryCount = categoryCount
        self.confirmedHelioCategoryCount = confirmedHelioCategoryCount
        self.latestObservation = latestObservation
    }

    static let unavailable = RetainedHealthDataSettings(
        status: .unavailable,
        sampleCount: 0,
        categoryCount: 0,
        confirmedHelioCategoryCount: 0,
        latestObservation: nil
    )

    var title: String {
        switch status {
        case .unavailable: "Unavailable"
        case .observed: "Observed · retained"
        case .partial: "Partial retention"
        case .stale: "Stale retained data"
        case .conflict: "Conflicting source records"
        case .readIndeterminate: "Read result indeterminate"
        case .error: "Health data read error"
        }
    }

    var detail: String {
        switch status {
        case .unavailable:
            "No HealthKit observations have been retained yet."
        case .observed:
            "Health data is retained locally from an observed HealthKit read; this does not claim device connection."
        case .partial:
            "Some HealthKit observations are retained locally; coverage is incomplete."
        case .stale:
            "Retained HealthKit data is present but its freshness needs review."
        case .conflict:
            "Conflicting HealthKit source records are retained; no single value is presented as authoritative."
        case .readIndeterminate:
            "Apple Health read completed, but access and an empty result cannot be distinguished."
        case .error:
            "A HealthKit read could not be interpreted; no device connection is claimed."
        }
    }

    var latestObservationLabel: String {
        guard let latestObservation else { return "No retained observation yet" }
        return latestObservation.formatted(date: .abbreviated, time: .shortened)
    }
}

struct HealthReadAccessSettings: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case unavailable
        case notRequested
        case requestRequired
        case requestPending
        case readIndeterminate
        case restricted
        case protectedDataUnavailable
        case error
    }

    let state: State
    let errorDescription: String?

    init(state: State, errorDescription: String? = nil) {
        self.state = state
        self.errorDescription = errorDescription
    }

    static var platformDefault: Self {
#if os(macOS)
        Self(state: .unavailable, errorDescription: "HealthKit reads are available only in the iPhone app.")
#else
        Self(state: .unavailable, errorDescription: "Open Health & devices from the main Settings screen to configure HealthKit.")
#endif
    }

    var title: String {
        switch state {
        case .unavailable: "Unavailable"
        case .notRequested: "Not requested"
        case .requestRequired: "Permission required"
        case .requestPending: "Waiting for Apple Health"
        case .readIndeterminate: "Read request completed"
        case .restricted: "Restricted"
        case .protectedDataUnavailable: "Device locked"
        case .error: "Could not connect"
        }
    }

    var detail: String {
        if let errorDescription, !errorDescription.isEmpty { return errorDescription }
        switch state {
        case .unavailable:
            return "HealthKit transport is not available in this app context."
        case .notRequested, .requestRequired:
            return "Choose the Health categories LifeOS may read. Manual logs remain available if you decline."
        case .requestPending:
            return "Complete the Apple Health sheet. LifeOS cannot see per-category read approval."
        case .readIndeterminate:
            return "Apple's sheet completed. Empty reads can mean no data or limited access, so each metric remains source-checked."
        case .restricted:
            return "Health data access is restricted on this device."
        case .protectedDataUnavailable:
            return "Unlock the iPhone before LifeOS retries protected health data."
        case .error:
            return "HealthKit setup did not complete. Retry from this screen."
        }
    }

    var buttonTitle: String {
        switch state {
        case .readIndeterminate: "Review Health access"
        case .requestPending: "Waiting…"
        default: "Allow Health reads"
        }
    }

    var allowsRequest: Bool {
        switch state {
        case .requestPending, .unavailable, .restricted, .protectedDataUnavailable: false
        default: true
        }
    }
}

#if os(iOS)
extension HealthReadAccessSettings {
    /// Keeps the SwiftUI settings surface on the same privacy boundary as the
    /// HealthKit controller: a completed request is still read-indeterminate,
    /// never an inferred per-type read grant.
    static func from(snapshot: HealthKitIntegrationSnapshot) -> Self {
        let state: State
        if snapshot.isRequestInFlight {
            state = .requestPending
        } else {
            switch snapshot.authorizationState {
            case .unavailable: state = .unavailable
            case .restricted, .revoked: state = .restricted
            case .protectedDataUnavailable: state = .protectedDataUnavailable
            case .notRequested: state = .notRequested
            case .requestRequired: state = .requestRequired
            case .requestPending: state = .requestPending
            case .readIndeterminate: state = .readIndeterminate
            case .error: state = .error
            case .writeNotDetermined, .writeAuthorized, .writeDenied:
                state = .error
            }
        }
        return Self(state: state, errorDescription: snapshot.errorDescription)
    }
}
#endif

private let settingsFinanceSourceLabel = "Windows finance gateway observation"
private let settingsFinanceTransactionSourceLabel = "Windows finance transaction observation"

private func settingsProviderSourceLabel(_ provider: Provider) -> String {
    "Windows Hermes · \(provider.displayName) observation"
}

enum SettingsProviderConnectionState: String, Equatable, Sendable {
    case observed
    case partial
    case stale
    case unavailable

    var title: String {
        switch self {
        case .observed: "Observed"
        case .partial: "Partial"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        }
    }
}

struct ProviderConnectionSettings: Identifiable, Equatable, Sendable {
    let provider: Provider
    let state: SettingsProviderConnectionState
    let freshness: Freshness
    let connector: ConnectorState
    let source: String
    let observedAt: Date?

    var id: String { provider.rawValue }

    static func resolve(
        provider: Provider,
        snapshot: ProviderSnapshot?,
        connector: ConnectorState?,
        now: Date,
        staleAfter: TimeInterval
    ) -> Self {
        guard let snapshot else {
            return Self(
                provider: provider,
                state: .unavailable,
                freshness: .unavailable,
                connector: connector ?? .unavailable,
                source: "No validated provider observation",
                observedAt: nil
            )
        }

        let resolvedConnector = connector ?? snapshot.provenance.connector
        let hasObservedProvider = snapshot.provenance.quality == .observed
        let freshness = hasObservedProvider
            ? snapshot.provenance.freshness(now: now, staleAfter: staleAfter)
            : .unavailable
        let hasIncompleteWindow = snapshot.windows.isEmpty || snapshot.windows.contains { window in
            guard let provenance = window.provenance else { return true }
            return provenance.quality != .observed || window.usedPercent == nil
        }

        let resolvedState: SettingsProviderConnectionState
        if !hasObservedProvider {
            resolvedState = .unavailable
        } else if freshness == .stale || freshness == .unavailable
                    || ![.healthy, .refreshDue].contains(resolvedConnector) {
            // A retained observation with a broken/revoked connector is stale,
            // not a new connected observation. It remains useful context without
            // implying that a provider can currently be queried.
            resolvedState = .stale
        } else if hasIncompleteWindow {
            resolvedState = .partial
        } else {
            resolvedState = .observed
        }

        return Self(
            provider: provider,
            state: resolvedState,
            freshness: freshness,
            connector: resolvedConnector,
            source: settingsProviderSourceLabel(provider),
            observedAt: hasObservedProvider ? snapshot.provenance.observedAt : nil
        )
    }

    var sourceDetail: String {
        source
    }
}

enum UsageSettingsHubReadiness: String, Equatable, Sendable {
    case observed
    case partial
    case stale
    case loading
    case unavailable

    var title: String {
        switch self {
        case .observed: "Observed"
        case .partial: "Partial observations"
        case .stale: "Stale observations"
        case .loading: "Refreshing"
        case .unavailable: "Unavailable"
        }
    }
}

struct UsageSettingsSnapshot: Equatable, Sendable {
    let state: UsageLoadState
    let providers: [ProviderConnectionSettings]
    let lastUpdated: Date?
    let errorMessage: String?

    init(
        state: UsageLoadState,
        providerSnapshots: [ProviderSnapshot],
        connectorStates: [Provider: ConnectorState],
        lastUpdated: Date?,
        errorMessage: String?,
        now: Date = .now,
        staleAfter: TimeInterval = 15 * 60
    ) {
        let snapshots = Dictionary(uniqueKeysWithValues: providerSnapshots.map { ($0.provider, $0) })
        providers = Provider.allCases.map { provider in
            ProviderConnectionSettings.resolve(
                provider: provider,
                snapshot: snapshots[provider],
                connector: connectorStates[provider],
                now: now,
                staleAfter: staleAfter
            )
        }
        self.state = state
        self.lastUpdated = lastUpdated
        self.errorMessage = errorMessage
    }

    static let unavailable = UsageSettingsSnapshot(
        state: .unavailable,
        providerSnapshots: [],
        connectorStates: [:],
        lastUpdated: nil,
        errorMessage: nil
    )

    var readiness: UsageSettingsHubReadiness {
        if state == .loading { return .loading }
        if state == .stale || providers.contains(where: { $0.state == .stale }) { return .stale }
        if providers.contains(where: { $0.state == .partial }) { return .partial }
        if providers.contains(where: { $0.state == .observed }) { return .observed }
        return .unavailable
    }

    var isRefreshing: Bool { state == .loading }

    var readinessDetail: String {
        let observedCount = providers.filter { $0.state != .unavailable }.count
        guard observedCount > 0 else {
            return "No validated provider observations are available from the configured usage source."
        }
        return "\(observedCount) of \(providers.count) providers have retained observations; each row keeps its own freshness and source."
    }
}

enum FinanceSettingsReadiness: String, Equatable, Sendable {
    case observed
    case stale
    case loading
    case demo
    case unavailable

    var title: String {
        switch self {
        case .observed: "Observed"
        case .stale: "Stale"
        case .loading: "Refreshing"
        case .demo: "Demo only · not live"
        case .unavailable: "Unavailable"
        }
    }
}

struct FinanceSettingsSnapshot: Equatable, Sendable {
    let state: FinanceLoadState
    let readiness: FinanceSettingsReadiness
    let generatedAt: Date?
    let observedSources: [String]
    let freshness: FinancePayloadFreshness
    let transactionsAvailability: FinanceMetricAvailability?
    let transactionSource: String?

    init(
        state: FinanceLoadState,
        summary: FinanceSummary?,
        now: Date = .now,
        staleAfter: TimeInterval = 15 * 60
    ) {
        self.state = state
        generatedAt = summary?.generatedAt

        var provenances: [FinancePayloadProvenance] = []
        var sourceLabels: [String] = []
        if let summary {
            let metrics = [
                summary.monthlyIncome,
                summary.fixedCosts,
                summary.discretionaryBuffer,
                summary.spent,
                summary.savingsGoal,
                summary.saved
            ]
            let observedMetrics = metrics.compactMap {
                $0.availability == .observed ? $0.provenance : nil
            }
            provenances.append(contentsOf: observedMetrics)
            if !observedMetrics.isEmpty {
                sourceLabels.append(settingsFinanceSourceLabel)
            }
            if let transactions = summary.transactions,
               transactions.availability == .observed {
                provenances.append(transactions.provenance)
                sourceLabels.append(settingsFinanceTransactionSourceLabel)
            }
        }

        observedSources = Array(Set(sourceLabels)).sorted()
        transactionsAvailability = summary?.transactions?.availability
        transactionSource = summary?.transactions?.availability == .observed
            ? settingsFinanceTransactionSourceLabel
            : nil
        if provenances.contains(where: { $0.freshness == .stale }) {
            freshness = .stale
        } else if provenances.contains(where: {
            $0.freshness == .fresh
                && now.timeIntervalSince($0.observedAt) < staleAfter
        }) {
            freshness = .fresh
        } else {
            freshness = .unknown
        }

        switch state {
        case .demo: readiness = .demo
        case .loading: readiness = .loading
        case .stale: readiness = .stale
        case .observed: readiness = .observed
        case .unavailable: readiness = .unavailable
        }
    }

    static let unavailable = FinanceSettingsSnapshot(state: .unavailable, summary: nil)

    var isRefreshing: Bool { state == .loading }

    var summaryDetail: String {
        switch readiness {
        case .observed:
            let source = observedSources.isEmpty ? "Finance source" : observedSources.joined(separator: " · ")
            let freshnessDetail = freshness == .fresh ? "Fresh" : "Source freshness needs review"
            return "\(source) · \(freshnessDetail)"
        case .stale:
            let source = observedSources.isEmpty ? "Last finance source" : observedSources.joined(separator: " · ")
            return "\(source) · refresh required before treating this as current"
        case .loading:
            return "Fetching the finance summary only; no account settings are changed."
        case .demo:
            return "Demo fixture only; no bank observation or account connection is implied."
        case .unavailable:
            return "No validated finance observation is available from the configured source."
        }
    }

    var transactionTitle: String {
        switch transactionsAvailability {
        case .observed: "Observed"
        case .unavailable: "Unavailable"
        case nil: "Not exposed"
        }
    }

    var transactionDetail: String {
        switch transactionsAvailability {
        case .observed:
            let source = transactionSource ?? "Finance source"
            return "\(source) · transaction observations are source-backed"
        case .unavailable:
            return "The finance API reported no transaction observation; this is not an empty ledger."
        case nil:
            return "The current finance summary API does not expose transaction observations."
        }
    }
}

enum SyncSettingsURLState: String, Equatable, Sendable {
    case missing
    case valid
    case invalid

    var title: String {
        switch self {
        case .missing: "Missing"
        case .valid: "Valid approved URL"
        case .invalid: "Rejected"
        }
    }
}

struct SyncSettingsReadiness: Equatable, Sendable {
    let approvedHostConfigured: Bool
    let urlState: SyncSettingsURLState
    let bearerAvailable: Bool

    static func resolve(
        serverURL: String,
        approvedHosts: Set<String>,
        bearerAvailable: Bool
    ) -> Self {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlState: SyncSettingsURLState
        if trimmed.isEmpty {
            urlState = .missing
        } else if TailscaleSyncClient.validatedServerURL(trimmed, approvedHosts: approvedHosts) != nil {
            urlState = .valid
        } else {
            urlState = .invalid
        }
        return Self(
            approvedHostConfigured: !approvedHosts.isEmpty,
            urlState: urlState,
            bearerAvailable: bearerAvailable
        )
    }

    var canAttemptConnection: Bool {
        approvedHostConfigured && urlState == .valid && bearerAvailable
    }

    var title: String {
        if !approvedHostConfigured { return "Approved signed host missing" }
        switch urlState {
        case .missing: return "Server URL missing"
        case .invalid: return "Server URL rejected"
        case .valid:
            return bearerAvailable ? "Ready for read-only preflight" : "Keychain bearer missing"
        }
    }
}

enum AppGroupSettingsState: String, Equatable, Sendable {
    case configured
    case placeholder
    case unavailable

    var title: String {
        switch self {
        case .configured: "Configured"
        case .placeholder: "Placeholder"
        case .unavailable: "Unavailable"
        }
    }
}

struct AppGroupSettingsSnapshot: Equatable, Sendable {
    let state: AppGroupSettingsState

    static func resolve(rawIdentifier: String?, sharedContainerAvailable: Bool) -> Self {
        guard let rawIdentifier, !rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self(state: .unavailable)
        }
        if rawIdentifier.contains("$(") {
            return Self(state: .placeholder)
        }
        guard AppGroupConfiguration.validatedIdentifier(rawIdentifier) != nil,
              sharedContainerAvailable else {
            return Self(state: .unavailable)
        }
        return Self(state: .configured)
    }

    static func current(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Self {
        let raw = bundle.object(forInfoDictionaryKey: AppGroupConfiguration.infoPlistKey) as? String
        let identifier = AppGroupConfiguration.validatedIdentifier(raw)
        let sharedContainerAvailable = identifier.map {
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        } ?? false
        return resolve(rawIdentifier: raw, sharedContainerAvailable: sharedContainerAvailable)
    }

    var detail: String {
        switch state {
        case .configured:
            return "The team-configured shared container is available to the app/widget pair."
        case .placeholder:
            return "The App Group build setting is unresolved; shared widget storage is not provisioned."
        case .unavailable:
            return "No usable shared App Group container is available in this build."
        }
    }

    var widgetGateDetail: String {
        switch state {
        case .configured:
            return "Calendar widget shared storage is configured; this does not certify calendar sync or event provenance."
        case .placeholder, .unavailable:
            return "Calendar widget shared storage is blocked until a team-owned App Group is configured and provisioned."
        }
    }
}

/// Settings is for infrequent setup and trust decisions. Product data views
/// stay focused; connections, credentials status, and device permissions live
/// here instead of becoming extra primary destinations.
struct SettingsView: View {
    @ObservedObject private var usageCoordinator: UsageCoordinator
    @ObservedObject private var financeCoordinator: FinanceCoordinator
    private let healthReadAccess: HealthReadAccessSettings
    private let requestHealthReadAccess: (@MainActor () async -> Void)?
    private let retainedHealthData: RetainedHealthDataSettings
#if os(iOS)
    private let healthKitController: HealthKitIntegrationController
    private let healthKitFitnessRepository: HealthKitFitnessRepository
#endif

    private var usageSettings: UsageSettingsSnapshot {
        UsageSettingsSnapshot(
            state: usageCoordinator.state,
            providerSnapshots: usageCoordinator.providers,
            connectorStates: usageCoordinator.connectorStates,
            lastUpdated: usageCoordinator.lastUpdated,
            errorMessage: usageCoordinator.errorMessage
        )
    }

    private var financeSettings: FinanceSettingsSnapshot {
        FinanceSettingsSnapshot(
            state: financeCoordinator.state,
            summary: financeCoordinator.summary
        )
    }

    private var categories: [SettingsCategory] {
        [
            .init(id: "providers", title: "AI providers", subtitle: "Codex, Claude, GLM, DeepSeek, Google AI Studio", readiness: .providers(usageSettings.readiness), icon: .assistant),
            .init(id: "finance", title: "Bank connections", subtitle: "Sparkasse, Revolut Personal / Business, Trade Republic, and consent", readiness: .finance(financeSettings.readiness), icon: .bankConnections),
            .init(id: "health", title: "Health & devices", subtitle: "Helio → Zepp → Apple Health / HealthKit", readiness: .healthRead(healthReadAccess.state), icon: .health),
            .init(id: "sync", title: "Sync & storage", subtitle: "Windows authority, server URL, and local data", readiness: .identityPending, icon: .refresh),
            .init(id: "privacy", title: "Privacy & security", subtitle: "Local safeguards, signing, and unresolved server gates", readiness: .localSafeguards, icon: .security)
        ]
    }

    #if os(iOS)
    init(
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator,
        healthReadAccess: HealthReadAccessSettings,
        requestHealthReadAccess: (@MainActor () async -> Void)?,
        retainedHealthData: RetainedHealthDataSettings,
        healthKitController: HealthKitIntegrationController,
        healthKitFitnessRepository: HealthKitFitnessRepository
    ) {
        _usageCoordinator = ObservedObject(wrappedValue: usageCoordinator)
        _financeCoordinator = ObservedObject(wrappedValue: financeCoordinator)
        self.healthReadAccess = healthReadAccess
        self.requestHealthReadAccess = requestHealthReadAccess
        self.retainedHealthData = retainedHealthData
        self.healthKitController = healthKitController
        self.healthKitFitnessRepository = healthKitFitnessRepository
    }
    #else
    init(
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator,
        healthReadAccess: HealthReadAccessSettings = .platformDefault,
        requestHealthReadAccess: (@MainActor () async -> Void)? = nil,
        retainedHealthData: RetainedHealthDataSettings = .unavailable
    ) {
        _usageCoordinator = ObservedObject(wrappedValue: usageCoordinator)
        _financeCoordinator = ObservedObject(wrappedValue: financeCoordinator)
        self.healthReadAccess = healthReadAccess
        self.requestHealthReadAccess = requestHealthReadAccess
        self.retainedHealthData = retainedHealthData
    }
    #endif

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep setup out of the daily workflow")
                            .font(LifeOSFont.spaceGrotesk(20, weight: .bold))
                        Text("Connections and security-sensitive configuration are managed here. LifeOS stays honest about what is and is not connected.")
                            .font(LifeOSFont.inter(14))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 390, maximum: 600), spacing: 12)], spacing: 12) {
                        NavigationLink {
                            ProviderConnectionsSettingsView(
                                snapshot: usageSettings,
                                refreshAction: { await usageCoordinator.refresh() }
                            )
                        } label: {
                            SettingsHubCard(category: categories[0])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-providers")

                        NavigationLink {
                            FinanceConnectionsSettingsView(
                                snapshot: financeSettings,
                                refreshAction: { await financeCoordinator.refresh() }
                            )
                        } label: {
                            SettingsHubCard(category: categories[1])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-finance")

                        NavigationLink {
#if os(iOS)
                            HealthDevicesSettingsView(
                                healthReadAccess: healthReadAccess,
                                requestHealthReadAccess: requestHealthReadAccess,
                                retainedHealthData: retainedHealthData,
                                healthKitController: healthKitController,
                                healthKitFitnessRepository: healthKitFitnessRepository
                            )
#else
                            HealthDevicesSettingsView(
                                healthReadAccess: healthReadAccess,
                                requestHealthReadAccess: requestHealthReadAccess,
                                retainedHealthData: retainedHealthData
                            )
#endif
                        } label: {
                            SettingsHubCard(category: categories[2])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-health")

                        NavigationLink {
                            SyncStorageSettingsView()
                        } label: {
                            SettingsHubCard(category: categories[3])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-sync")

                        NavigationLink {
                            PrivacySecuritySettingsView()
                        } label: {
                            SettingsHubCard(category: categories[4])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-privacy")
                    }

                    Text("Provider keys remain on the Windows Hermes server. This app does not accept or store raw provider secrets.")
                        .font(LifeOSFont.inter(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-provider-keys-disclaimer")
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Settings")
        .tint(LifeOSTokens.accent)
        .accessibilityIdentifier("settings-hub")
    }
}

private struct SettingsCategory: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let readiness: SettingsReadiness
    let icon: LifeOSIconName
}

private enum SettingsReadiness: Equatable {
    case providers(UsageSettingsHubReadiness)
    case finance(FinanceSettingsReadiness)
    case serverGatePending
    case consentRequired
    case healthRead(HealthReadAccessSettings.State)
    case identityPending
    case localSafeguards

    var title: String {
        switch self {
        case .providers(let readiness): readiness.title
        case .finance(let readiness): readiness.title
        case .serverGatePending: "Server gate pending"
        case .consentRequired: "Consent required"
        case .healthRead(let state):
            switch state {
            case .notRequested, .requestRequired: "Health permission pending"
            case .requestPending: "Waiting for Apple Health"
            case .readIndeterminate: "Read request completed · source checked"
            case .protectedDataUnavailable: "Unlock iPhone to refresh"
            case .restricted: "Health access restricted"
            case .unavailable: "Available on iPhone only"
            case .error: "Health setup needs attention"
            }
        case .identityPending: "Identity migration pending"
        case .localSafeguards: "Local safeguards active · server gate pending"
        }
    }

    var color: Color {
        switch self {
        case .providers(.observed), .finance(.observed):
            LifeOSTokens.success
        case .providers(.partial):
            LifeOSTokens.info
        case .providers(.loading), .providers(.stale),
             .providers(.unavailable),
             .finance(.loading), .finance(.stale),
             .finance(.demo), .finance(.unavailable):
            LifeOSTokens.warning
        case .healthRead(.readIndeterminate):
            LifeOSTokens.info
        case .localSafeguards, .serverGatePending, .consentRequired, .healthRead,
             .identityPending:
            LifeOSTokens.warning
        }
    }
}

private struct SettingsHubCard: View {
    let category: SettingsCategory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LifeOSTokens.accent.opacity(0.12))
                LifeOSIcon(category.icon)
                    .foregroundStyle(LifeOSTokens.accent)
                    .frame(width: 20, height: 20)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(category.title)
                    .font(LifeOSFont.inter(14, weight: .semiBold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(category.subtitle)
                    .font(LifeOSFont.inter(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(category.readiness.title)
                    .font(LifeOSFont.inter(11, weight: .semiBold))
                    .foregroundStyle(category.readiness.color)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            LifeOSIcon(.chevronRight)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .background(
            LinearGradient(
                colors: [LifeOSTokens.surface, LifeOSTokens.accent.opacity(isHovering || isFocused ? 0.045 : 0.018)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: LifeOSTokens.cardShape
        )
        .overlay(
            LifeOSTokens.cardShape.stroke(
                isHovering || isFocused ? LifeOSTokens.accent.opacity(0.38) : LifeOSTokens.quietBorder,
                lineWidth: isHovering || isFocused ? 1 : 0.75
            )
        )
        .contentShape(LifeOSTokens.cardShape)
        .scaleEffect(!reduceMotion && (isHovering || isFocused) ? 1.008 : 1)
        .animation(reduceMotion ? nil : LifeOSMotion.springSnappy, value: isHovering || isFocused)
        .accessibilityValue(Text(category.readiness.title))
        .accessibilityHint(Text("Opens \(category.title) settings"))
#if os(macOS)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .help("Open \(category.title) settings")
#endif
    }
}

struct ProviderConnectionsSettingsView: View {
    let snapshot: UsageSettingsSnapshot
    let refreshAction: (() async -> Void)?

    init(
        snapshot: UsageSettingsSnapshot = .unavailable,
        refreshAction: (() async -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.refreshAction = refreshAction
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "AI & provider connections",
                    message: "Usage is read from the Windows Hermes server. This client never accepts, copies, or stores a provider key."
                )

                SettingsSection(title: "Provider status", icon: .assistant) {
                    VStack(spacing: 0) {
                        ForEach(snapshot.providers) { provider in
                            SettingsStatusRow(
                                title: provider.provider.displayName,
                                detail: providerDetail(provider),
                                status: provider.state.title,
                                icon: .usage,
                                statusColor: providerColor(provider.state)
                            )
                            if provider.id != snapshot.providers.last?.id {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }

                SettingsSection(title: "Usage source", icon: .usage) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Usage hub",
                            detail: snapshot.readinessDetail,
                            status: snapshot.readiness.title,
                            icon: .overview,
                            statusColor: hubColor
                        )
                        if let lastUpdated = snapshot.lastUpdated {
                            Divider().padding(.leading, 38)
                            SettingsStatusRow(
                                title: "Latest source update",
                                detail: "Coordinator timestamp; provider rows retain their own observation timestamps.",
                                status: lastUpdated.formatted(date: .abbreviated, time: .shortened),
                                icon: .refresh,
                                statusColor: LifeOSTokens.tertiaryText
                            )
                        }
                    }
                }

                if let refreshAction {
                    Button {
                        Task { await refreshAction() }
                    } label: {
                        HStack(spacing: 8) {
                            if snapshot.isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                LifeOSIcon(.refresh).frame(width: 15, height: 15)
                            }
                            Text(snapshot.isRefreshing ? "Refreshing provider usage…" : "Refresh provider usage")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSTokens.accent)
                    .disabled(snapshot.isRefreshing)
                    .accessibilityIdentifier("settings-provider-refresh")
                }

                TruthfulSetupNote(text: "Provider rows reflect only UsageCoordinator observations and connector state. Provider keys remain on the Windows Hermes server; there is no paste, reveal, or copy path for raw keys.")
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("AI & Providers")
    }

    private func providerDetail(_ provider: ProviderConnectionSettings) -> String {
        let source = "Source: \(provider.sourceDetail)"
        let freshness = "Freshness: \(freshnessTitle(provider.freshness))"
        let connector = "Connector: \(connectorTitle(provider.connector))"
        switch provider.state {
        case .observed:
            return "\(source) · \(freshness) · \(connector)"
        case .partial:
            return "\(source) · \(freshness) · some windows are unavailable"
        case .stale:
            return "\(source) · last observed \(observedAtLabel(provider.observedAt)) · \(connector)"
        case .unavailable:
            return "\(source) · no current observation"
        }
    }

    private func observedAtLabel(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "time unavailable"
    }

    private func freshnessTitle(_ freshness: Freshness) -> String {
        switch freshness {
        case .fresh: "Fresh"
        case .aging: "Aging"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        }
    }

    private func connectorTitle(_ connector: ConnectorState) -> String {
        switch connector {
        case .healthy: "Healthy"
        case .refreshDue: "Refresh due"
        case .reauthRequired: "Re-auth required"
        case .revoked: "Revoked"
        case .rateLimited: "Rate limited"
        case .unavailable: "Unavailable"
        case .disabled: "Disabled"
        case .error: "Error"
        }
    }

    private func providerColor(_ state: SettingsProviderConnectionState) -> Color {
        switch state {
        case .observed: LifeOSTokens.success
        case .partial: LifeOSTokens.info
        case .stale, .unavailable: LifeOSTokens.warning
        }
    }

    private var hubColor: Color {
        switch snapshot.readiness {
        case .observed: LifeOSTokens.success
        case .partial: LifeOSTokens.info
        case .loading, .stale, .unavailable: LifeOSTokens.warning
        }
    }
}

private struct FinanceConnectionsSettingsView: View {
    let snapshot: FinanceSettingsSnapshot
    let refreshAction: (() async -> Void)?
    private let catalog = FinanceConnectorCatalog.defaults

    init(
        snapshot: FinanceSettingsSnapshot = .unavailable,
        refreshAction: (() async -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.refreshAction = refreshAction
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Bank & finance connections",
                    message: "Connectors are disabled by default. Explicit consent and the reviewed Windows gateway are required before account observations can appear."
                )

                SettingsSection(title: "Finance source", icon: .finance) {
                    VStack(spacing: 0) {
                            SettingsStatusRow(
                                title: "Finance summary",
                                detail: snapshot.summaryDetail,
                                status: snapshot.readiness.title,
                                icon: .finance,
                                statusColor: summaryColor
                            )
                            Divider().padding(.leading, 38)
                            SettingsStatusRow(
                                title: "Transaction observations",
                                detail: snapshot.transactionDetail,
                                status: snapshot.transactionTitle,
                                icon: .documents,
                                statusColor: snapshot.transactionsAvailability == .observed
                                    ? LifeOSTokens.success
                                    : LifeOSTokens.warning
                            )
                    }
                }

                if let refreshAction {
                    Button {
                        Task { await refreshAction() }
                    } label: {
                        HStack(spacing: 8) {
                            if snapshot.isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                LifeOSIcon(.refresh).frame(width: 15, height: 15)
                            }
                            Text(snapshot.isRefreshing ? "Refreshing finance summary…" : "Refresh finance summary")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSTokens.accent)
                    .disabled(snapshot.isRefreshing)
                    .accessibilityIdentifier("settings-finance-refresh")
                }

                SettingsSection(title: "Connection catalog", icon: .bankConnections) {
                    VStack(spacing: 0) {
                        ForEach(catalog) { descriptor in
                            SettingsStatusRow(
                                title: descriptor.displayName,
                                detail: "\(accessMethodTitle(descriptor.accessMethod)) · \(descriptor.recommendation)",
                                status: gateTitle(descriptor.risk),
                                icon: .finance,
                                statusColor: LifeOSTokens.warning
                            )
                            if descriptor.id != catalog.last?.id {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }

                NavigationLink {
                    SyncStorageSettingsView()
                } label: {
                    HStack(spacing: 8) {
                        LifeOSIcon(.security).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open secure Sync setup")
                                .font(LifeOSFont.inter(13, weight: .semiBold))
                            Text("Review the signed host, URL validation, and read-only Keychain authorization gate.")
                                .font(LifeOSFont.inter(12))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        LifeOSIcon(.chevronRight).frame(width: 14, height: 14)
                    }
                    .foregroundStyle(.primary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
                    .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-finance-open-sync")

                TruthfulSetupNote(text: "The catalog names the exact external gate; it does not claim that a bank is connected. Secrets and consent flows remain outside this client, and no bank transaction data is fabricated.")
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Bank & Finance")
    }

    private var summaryColor: Color {
        switch snapshot.readiness {
        case .observed: LifeOSTokens.success
        case .loading, .stale, .demo, .unavailable: LifeOSTokens.warning
        }
    }

    private func accessMethodTitle(_ method: FinanceAccessMethod) -> String {
        switch method {
        case .officialOAuth: "Official OAuth"
        case .regulatedOpenBanking: "Regulated open banking"
        case .manualImport: "Manual import"
        }
    }

    private func gateTitle(_ risk: FinanceConnectorRisk) -> String {
        switch risk {
        case .consentRequired: "External consent required"
        case .accountEligibilityRequired: "Eligibility + OAuth required"
        case .manualImportOnly: "Manual import only"
        }
    }
}

private struct HealthDevicesSettingsView: View {
    private let snapshot = HelioDeviceSettingsSnapshot.current
    let healthReadAccess: HealthReadAccessSettings
    let requestHealthReadAccess: (@MainActor () async -> Void)?
    let retainedHealthData: RetainedHealthDataSettings
#if os(iOS)
    @ObservedObject private var healthKitController: HealthKitIntegrationController
    @ObservedObject private var healthKitFitnessRepository: HealthKitFitnessRepository
#endif

 #if os(iOS)
    init(
        healthReadAccess: HealthReadAccessSettings,
        requestHealthReadAccess: (@MainActor () async -> Void)?,
        retainedHealthData: RetainedHealthDataSettings,
        healthKitController: HealthKitIntegrationController,
        healthKitFitnessRepository: HealthKitFitnessRepository
    ) {
        self.healthReadAccess = healthReadAccess
        self.requestHealthReadAccess = requestHealthReadAccess
        self.retainedHealthData = retainedHealthData
        _healthKitController = ObservedObject(wrappedValue: healthKitController)
        _healthKitFitnessRepository = ObservedObject(wrappedValue: healthKitFitnessRepository)
    }
#else
    init(
        healthReadAccess: HealthReadAccessSettings,
        requestHealthReadAccess: (@MainActor () async -> Void)?,
        retainedHealthData: RetainedHealthDataSettings
    ) {
        self.healthReadAccess = healthReadAccess
        self.requestHealthReadAccess = requestHealthReadAccess
        self.retainedHealthData = retainedHealthData
    }
#endif

#if os(iOS)
    private var resolvedHealthReadAccess: HealthReadAccessSettings {
        HealthReadAccessSettings.from(snapshot: healthKitController.snapshot)
    }

    private var resolvedRetainedHealthData: RetainedHealthDataSettings {
        guard let projection = healthKitFitnessRepository.projection else { return .unavailable }
        return .from(projection: projection)
    }
#else
    private var resolvedHealthReadAccess: HealthReadAccessSettings { healthReadAccess }
    private var resolvedRetainedHealthData: RetainedHealthDataSettings { retainedHealthData }
#endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Health & devices",
                    message: "Helio Strap is the sensor authority. LifeOS keeps the Zepp and Apple Health transport boundary visible until a reviewed adapter supplies real source evidence."
                )

                SettingsSection(title: "Authority chain", icon: .health) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(snapshot.authorityChain.map(\.title).joined(separator: "  →  "))
                            .font(LifeOSFont.inter(15, weight: .semiBold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Helio Strap measures. Zepp and Apple Health / HealthKit are transport and permission layers; neither is presented as the sensor.")
                            .font(LifeOSFont.inter(13))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings-health-authority-chain")
                }

                SettingsSection(title: "Connection & permission", icon: .health) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Apple Health read access",
                            detail: resolvedHealthReadAccess.detail,
                            status: resolvedHealthReadAccess.title,
                            icon: .security,
                            statusColor: healthReadAccessStatusColor
                        )
                        .accessibilityIdentifier("settings-health-read-status")
                        if let requestHealthReadAccess {
                            Button {
                                Task { @MainActor in await requestHealthReadAccess() }
                            } label: {
                                HStack(spacing: 8) {
                                    if resolvedHealthReadAccess.state == .requestPending {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(resolvedHealthReadAccess.buttonTitle)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LifeOSTokens.accent)
                            .disabled(!resolvedHealthReadAccess.allowsRequest)
                            .accessibilityIdentifier("settings-health-request-read-access")
                            .padding(.vertical, 10)
                        }
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Current connection",
                            detail: snapshot.connection.detail,
                            status: snapshot.connection.title,
                            icon: .health,
                            statusColor: connectionStatusColor(snapshot.connection)
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Health source permission",
                            detail: snapshot.permission.detail,
                            status: snapshot.permission.title,
                            icon: .security,
                            statusColor: permissionStatusColor(snapshot.permission)
                        )
                    }
                    .accessibilityIdentifier("settings-health-connection-permission")
                }

                SettingsSection(title: "Retained Health data", icon: .refresh) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Retained observations",
                            detail: "\(resolvedRetainedHealthData.sampleCount) retained observations across \(resolvedRetainedHealthData.categoryCount) HealthKit categories",
                            status: resolvedRetainedHealthData.title,
                            icon: retainedHealthDataIcon,
                            statusColor: retainedHealthDataStatusColor
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Latest retained observation",
                            detail: resolvedRetainedHealthData.detail,
                            status: resolvedRetainedHealthData.latestObservationLabel,
                            icon: retainedHealthDataIcon,
                            statusColor: retainedHealthDataStatusColor
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Confirmed Helio categories",
                            detail: "Source-confirmed categories only; this is not a device sync or battery claim.",
                            status: "\(resolvedRetainedHealthData.confirmedHelioCategoryCount)",
                            icon: .health,
                            statusColor: resolvedRetainedHealthData.confirmedHelioCategoryCount > 0 ? LifeOSTokens.info : LifeOSTokens.warning
                        )
                    }
                    .accessibilityIdentifier("settings-health-retained-data")
                }

                SettingsSection(title: "Metric capability inventory", icon: .health) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(HelioDeviceCapabilityGroup.allCases) { group in
                            let capabilities = snapshot.capabilities.filter { $0.group == group }
                            if !capabilities.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(group.title)
                                        .font(LifeOSFont.inter(12, weight: .semiBold))
                                        .foregroundStyle(LifeOSTokens.tertiaryText)
                                        .padding(.bottom, 4)
                                    ForEach(capabilities) { capability in
                                        SettingsStatusRow(
                                            title: capability.title,
                                            detail: "\(capability.sourcePath.title) · \(capability.detail)",
                                            status: capability.statusTitle,
                                            icon: capabilityStatusIcon(capability.status),
                                            statusColor: capabilityStatusColor(capability.status)
                                        )
                                        if capability.id != capabilities.last?.id {
                                            Divider().padding(.leading, 38)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("settings-health-capability-inventory")
                }

                SettingsSection(title: "Device status & management", icon: .security) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Battery",
                            detail: snapshot.battery.detail,
                            status: snapshot.battery.title,
                            icon: batteryStatusIcon(snapshot.battery),
                            statusColor: batteryStatusColor(snapshot.battery)
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Firmware",
                            detail: snapshot.firmware.detail,
                            status: snapshot.firmware.title,
                            icon: .warning,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Pairing, reboot & configuration",
                            detail: snapshot.management.detail,
                            status: snapshot.management.title,
                            icon: .refresh,
                            statusColor: LifeOSTokens.info
                        )
                    }
                    .accessibilityIdentifier("settings-health-device-management")
                }

                TruthfulSetupNote(text: "HealthKit reads are iPhone-only and read-only. Battery, firmware, pairing, reboot, configuration, private BLE control, and a verified Zepp launch route remain unavailable or Zepp-only until a supported interface is proven. Demo fixtures remain separate from observed device data.")
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Health & Devices")
    }

    private var healthReadAccessStatusColor: Color {
        switch resolvedHealthReadAccess.state {
        case .readIndeterminate:
            return LifeOSTokens.info
        case .notRequested, .requestRequired, .requestPending, .protectedDataUnavailable, .unavailable:
            return LifeOSTokens.warning
        case .restricted, .error:
            return LifeOSTokens.danger
        }
    }

    private func connectionStatusColor(_ connection: HelioDeviceConnection) -> Color {
        switch connection.state {
        case .observed:
            return LifeOSTokens.success
        case .conflict:
            return LifeOSTokens.danger
        case .externalZepp:
            return LifeOSTokens.info
        case .notConfigured, .permissionRequired, .availableUnverified, .partial, .stale, .unavailable:
            return LifeOSTokens.warning
        }
    }

    private func permissionStatusColor(_ permission: HelioDevicePermissionState) -> Color {
        switch permission {
        case .authorized:
            return LifeOSTokens.success
        case .denied, .revoked:
            return LifeOSTokens.danger
        case .notRequested, .permissionRequired, .pending, .unavailable:
            return LifeOSTokens.warning
        }
    }

    private var retainedHealthDataStatusColor: Color {
        switch resolvedRetainedHealthData.status {
        case .observed:
            return LifeOSTokens.success
        case .partial, .stale:
            return LifeOSTokens.warning
        case .conflict, .error:
            return LifeOSTokens.danger
        case .readIndeterminate:
            return LifeOSTokens.info
        case .unavailable:
            return LifeOSTokens.warning
        }
    }

    private var retainedHealthDataIcon: LifeOSIconName {
        switch resolvedRetainedHealthData.status {
        case .observed:
            return .verified
        case .readIndeterminate:
            return .refresh
        case .partial, .stale, .conflict, .error, .unavailable:
            return .warning
        }
    }

    private func capabilityStatusColor(_ status: HelioDeviceCapabilityStatus) -> Color {
        switch status {
        case .observed:
            return LifeOSTokens.success
        case .externalZepp:
            return LifeOSTokens.info
        case .unverified, .unavailable:
            return LifeOSTokens.warning
        }
    }

    private func capabilityStatusIcon(_ status: HelioDeviceCapabilityStatus) -> LifeOSIconName {
        switch status {
        case .observed:
            return .verified
        case .externalZepp:
            return .refresh
        case .unverified, .unavailable:
            return .warning
        }
    }

    private func batteryStatusColor(_ status: HelioDeviceBatteryStatus) -> Color {
        switch status {
        case .unavailable:
            return LifeOSTokens.warning
        case .observed(let reading):
            return reading.freshness == .fresh ? LifeOSTokens.success : LifeOSTokens.warning
        }
    }

    private func batteryStatusIcon(_ status: HelioDeviceBatteryStatus) -> LifeOSIconName {
        switch status {
        case .unavailable:
            return .warning
        case .observed(let reading):
            return reading.freshness == .fresh ? .verified : .warning
        }
    }
}

private struct SyncStorageSettingsView: View {
    private let syncClient = TailscaleSyncClient()
    @AppStorage(TailscaleSyncClient.serverURLDefaultsKey) private var syncServerURL = ""
    @AppStorage("LifeOS.Sync.LastSuccess") private var lastSyncTimestamp: Double = 0
    @State private var connectionPreflight: TailscaleConnectionPreflightState?
    @State private var isCheckingConnection = false
    @State private var connectionPreflightTask: Task<Void, Never>?
    @State private var connectionPreflightGeneration = 0

    private var localReadiness: SyncSettingsReadiness {
        SyncSettingsReadiness.resolve(
            serverURL: syncServerURL,
            approvedHosts: TailscaleSyncClient.configuredApprovedHosts(),
            bearerAvailable: TailscaleSyncClient.readBearerFromKeychain() != nil
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Sync & storage",
                    message: "Keep the existing Tailscale server configuration reachable while making its trust boundary clear."
                )

                SettingsSection(title: "Tailscale sync", icon: .security) {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Replace saved server URL", text: $syncServerURL)
                            .textFieldStyle(.roundedBorder)
#if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
#endif
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityLabel("Saved server URL replacement")
                            .accessibilityValue(localReadiness.urlState.title)
                        Text("The saved URL stays hidden. Enter a replacement here; only its approved or rejected state is shown.")
                            .font(LifeOSFont.inter(12))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Transitional bearer is read-only from Keychain; identity migration is pending. LifeOS exposes no token editor.")
                            .font(LifeOSFont.inter(12))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(syncStatusLabel)
                            .font(LifeOSFont.inter(12, weight: .semiBold))
                            .foregroundStyle(localReadiness.canAttemptConnection ? LifeOSTokens.success : LifeOSTokens.warning)
                        Button {
                            runConnectionPreflight()
                        } label: {
                            HStack(spacing: 7) {
                                if isCheckingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    LifeOSIcon(.refresh)
                                        .frame(width: 15, height: 15)
                                }
                                Text(isCheckingConnection ? "Checking secure connection…" : "Check secure connection")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isCheckingConnection || !localReadiness.canAttemptConnection)
                        .accessibilityIdentifier("settings-sync-check-connection")

                        if let connectionPreflight {
                            HStack(alignment: .top, spacing: 8) {
                                LifeOSIcon(connectionPreflight == .reachable ? .verified : .warning)
                                    .frame(width: 15, height: 15)
                                    .foregroundStyle(connectionPreflightColor(connectionPreflight))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connectionPreflightTitle(connectionPreflight))
                                        .font(LifeOSFont.inter(12, weight: .semiBold))
                                        .foregroundStyle(connectionPreflightColor(connectionPreflight))
                                    Text(connectionPreflightDetail(connectionPreflight))
                                        .font(LifeOSFont.inter(12))
                                        .foregroundStyle(LifeOSTokens.tertiaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("settings-sync-connection-result")
                        }

                        Text("This sends one authenticated, read-only request to the approved Windows gateway. It does not change or reveal credentials.")
                            .font(LifeOSFont.inter(11))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsSection(title: "Local readiness", icon: .verified) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Approved signed host",
                            detail: "Release configuration is checked without displaying the approved hostname.",
                            status: localReadiness.approvedHostConfigured ? "Configured" : "Missing",
                            icon: .security,
                            statusColor: localReadiness.approvedHostConfigured ? LifeOSTokens.success : LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Server URL validation",
                            detail: "The URL must be HTTPS, host-allowlisted, and free of paths, query, or fragment data.",
                            status: localReadiness.urlState.title,
                            icon: .documents,
                            statusColor: localReadiness.urlState == .valid ? LifeOSTokens.success : LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Keychain authorization",
                            detail: "The exact transitional bearer is read-only and never displayed, copied, or edited here.",
                            status: localReadiness.bearerAvailable ? "Present · hidden" : "Missing",
                            icon: .security,
                            statusColor: localReadiness.bearerAvailable ? LifeOSTokens.success : LifeOSTokens.warning
                        )
                    }
                }

                SettingsSection(title: "Trust state", icon: .refresh) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Windows server",
                            detail: "Authoritative store; secure deployment gate is still pending",
                            status: "Pending",
                            icon: .security,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Device identity",
                            detail: "Transitional read-only bearer remains in Keychain",
                            status: "Migration pending",
                            icon: .security,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Local records",
                            detail: "Remain local until an authenticated sync path succeeds",
                            status: "Local first",
                            icon: .documents,
                            statusColor: LifeOSTokens.success
                        )
                    }
                }

                SettingsSection(title: "Local storage", icon: .documents) {
                    Text("Calendar, tax documents, and app preferences remain on this device unless an explicitly configured, authenticated sync path is available.")
                        .font(LifeOSFont.inter(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Sync & Storage")
        .task(id: syncServerURL) {
            cancelConnectionPreflight()
            connectionPreflight = nil
        }
        .onDisappear {
            cancelConnectionPreflight()
        }
    }

    private func runConnectionPreflight() {
        guard !isCheckingConnection, localReadiness.canAttemptConnection else { return }
        connectionPreflightTask?.cancel()
        connectionPreflightGeneration &+= 1
        let generation = connectionPreflightGeneration
        let requestedServerURL = syncServerURL
        let client = syncClient
        isCheckingConnection = true
        connectionPreflight = nil
        connectionPreflightTask = Task { @MainActor in
            defer {
                if connectionPreflightGeneration == generation {
                    isCheckingConnection = false
                }
            }

            let result = await client.checkConnection()
            guard !Task.isCancelled,
                  connectionPreflightGeneration == generation,
                  syncServerURL == requestedServerURL,
                  let result else { return }

            guard !Task.isCancelled,
                  connectionPreflightGeneration == generation,
                  syncServerURL == requestedServerURL else { return }
            connectionPreflight = result
        }
    }

    private func cancelConnectionPreflight() {
        connectionPreflightGeneration &+= 1
        connectionPreflightTask?.cancel()
        connectionPreflightTask = nil
        isCheckingConnection = false
    }

    private func connectionPreflightTitle(_ state: TailscaleConnectionPreflightState) -> String {
        switch state {
        case .reachable: "Windows gateway reachable"
        case .configurationRequired: "Secure configuration required"
        case .authenticationRejected: "Authorization rejected"
        case .serverUnavailable: "Windows gateway unavailable"
        case .networkUnavailable: "Tailscale network unavailable"
        case .invalidResponse: "Gateway response rejected"
        }
    }

    private func connectionPreflightDetail(_ state: TailscaleConnectionPreflightState) -> String {
        switch state {
        case .reachable:
            "The approved gateway accepted the read-only request. This does not prove that every provider is connected."
        case .configurationRequired:
            "The signed approved-host configuration, server URL, or transitional Keychain authorization is missing or invalid."
        case .authenticationRejected:
            "The gateway is reachable, but it did not authorize this device request. No credential was changed."
        case .serverUnavailable:
            "The approved gateway returned a temporary server or rate-limit failure. Try again after checking the Windows services."
        case .networkUnavailable:
            "The approved gateway could not be reached. Check Tailscale on this device and the Windows PC, then retry."
        case .invalidResponse:
            "The response did not satisfy the fail-closed transport contract. No returned data was accepted."
        }
    }

    private func connectionPreflightColor(_ state: TailscaleConnectionPreflightState) -> Color {
        state == .reachable ? LifeOSTokens.success : LifeOSTokens.warning
    }

    private var syncStatusLabel: String {
        guard lastSyncTimestamp > 0 else { return localReadiness.title }
        let date = Date(timeIntervalSince1970: lastSyncTimestamp)
        return "Last successful local sync \(date.formatted(date: .abbreviated, time: .shortened)) · \(localReadiness.title)"
    }
}

private struct PrivacySecuritySettingsView: View {
    private let signing = SigningStatus.current()
    private let appGroup = AppGroupSettingsSnapshot.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Privacy, security & signing",
                    message: "These controls explain where data lives and whether this build can be trusted."
                )

                SettingsSection(title: "Privacy & security", icon: .security) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Local safeguards",
                            detail: "Protected local storage is used where the feature supports it",
                            status: "Active",
                            icon: .verified,
                            statusColor: LifeOSTokens.success
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "App Group shared storage",
                            detail: appGroup.detail,
                            status: appGroup.state.title,
                            icon: appGroup.state == .configured ? .verified : .warning,
                            statusColor: appGroup.state == .configured
                                ? LifeOSTokens.success
                                : LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Windows server gate",
                            detail: "BitLocker and identity migration are not yet verified",
                            status: "Pending",
                            icon: .security,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Raw secrets",
                            detail: "No provider or bank key entry, reveal, or copy path in this client",
                            status: "Blocked",
                            icon: .verified,
                            statusColor: LifeOSTokens.success
                        )
                    }
                }

                TruthfulSetupNote(text: "Local safeguards do not certify the remote server. Do not connect provider or bank accounts until the Windows deployment, disk-encryption, and device-identity gates have been reviewed.")

                SettingsSection(title: "Calendar widget storage", icon: .calendar) {
                    Text(appGroup.widgetGateDetail)
                        .font(LifeOSFont.inter(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: "Data boundary", icon: .documents) {
                    Text("Calendar items and local-first nutrition records stay on this device until an explicitly configured, authenticated sync path succeeds. Finance, Fitness, and Usage remain unavailable when their reviewed sources are not connected.")
                        .font(LifeOSFont.inter(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: "Signing", icon: signingIcon) {
                    SettingsStatusRow(
                        title: "Code signing",
                        detail: "\(signingModeLabel) · \(signing.guidance)",
                        status: signingLabel,
                        icon: signingIcon,
                        statusColor: signingColor
                    )
                    Text("Automatic self-signing is unavailable by Apple platform design.")
                        .font(LifeOSFont.inter(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Privacy & Security")
    }

    private var signingLabel: String {
        guard let days = signing.daysRemaining else { return "Signing expiration unavailable" }
        switch signing.state {
        case .expired:
            return "Signing expired"
        case .expiringSoon:
            return "Signing expiring: \(days) day\(days == 1 ? "" : "s") remaining"
        case .valid:
            return "Signing: \(days) day\(days == 1 ? "" : "s") remaining"
        case .unknown:
            return "Signing expiration unavailable"
        }
    }

    private var signingModeLabel: String {
        switch signing.mode {
        case .personalTeam: "Personal Team"
        case .developerProgram: "Apple Developer Program"
        case .sideloaded: "Sideloaded profile"
        case .unknown: "Signing mode unavailable"
        }
    }

    private var signingIcon: LifeOSIconName {
        if signing.state == .expired { return .warning }
        if signing.state == .valid { return .verified }
        return .security
    }

    private var signingColor: Color {
        switch signing.state {
        case .expired: LifeOSTokens.danger
        case .expiringSoon, .unknown: LifeOSTokens.warning
        case .valid: LifeOSTokens.success
        }
    }
}

private struct SettingsIntro: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LifeOSFont.spaceGrotesk(22, weight: .bold))
            Text(message)
                .font(LifeOSFont.inter(14))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let detail: String
    let status: String
    let icon: LifeOSIconName
    let statusColor: Color

    var body: some View {
        HStack(spacing: 10) {
            LifeOSIcon(icon)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LifeOSFont.inter(14, weight: .semiBold))
                Text(detail)
                    .font(LifeOSFont.inter(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(status)
                .font(LifeOSFont.inter(11, weight: .semiBold))
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-status-\(accessibilityID)")
        .accessibilityLabel(Text("\(title) · \(status)"))
        .accessibilityValue(Text("\(status). \(detail)"))
    }

    private var accessibilityID: String {
        title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "→", with: "-")
    }
}

private struct TruthfulSetupNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LifeOSIcon(.warning)
                .foregroundStyle(LifeOSTokens.warning)
                .frame(width: 16, height: 16)
            Text(text)
                .font(LifeOSFont.inter(12))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.warning.opacity(0.07), in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.warning.opacity(0.24), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: LifeOSIconName
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LifeOSIcon(icon).frame(width: 18, height: 18)
                Text(title)
            }
            .font(LifeOSFont.inter(15, weight: .semiBold))
            .foregroundStyle(LifeOSTokens.accent)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .accessibilityElement(children: .contain)
    }
}
