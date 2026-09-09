import AppIntents
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum LifeOSAutomationHealthRefreshState: String, Codable, Equatable, Sendable {
    case refreshed
    case current
    case stale
    case partial
    case unavailable
}

/// The app shell registers the one existing HealthKit refresh authority here.
/// The registry carries no navigation or health data state and is empty until
/// the live iOS app has created its owned controller and repository.
@MainActor
final class LifeOSAutomationRefreshRegistry {
    static let shared = LifeOSAutomationRefreshRegistry()

    private var registeredHealthRefresh: (@MainActor @Sendable () async throws -> LifeOSAutomationHealthRefreshState)?

    func registerHealthRefresh(
        _ refresh: @escaping @MainActor @Sendable () async throws -> LifeOSAutomationHealthRefreshState
    ) {
        registeredHealthRefresh = refresh
    }

    func refreshHealth() async throws -> LifeOSAutomationHealthRefreshState {
        guard let registeredHealthRefresh else { return .unavailable }
        return try await registeredHealthRefresh()
    }
}

enum LifeOSAutomationNavigation {
    static let fitnessURL = URL(string: "lifeos://fitness")!
    static let settingsURL = URL(string: "lifeos://settings")!

    @MainActor
    static func open(_ url: URL) {
#if os(iOS)
        UIApplication.shared.open(url)
#elseif os(macOS)
        _ = NSWorkspace.shared.open(url)
#endif
    }
}

/// Versioned JSON is the Shortcut value (use Get Dictionary from Input); the
/// dialog is human-readable. Only coarse, allowlisted facts cross this boundary.
/// No provider payload, URL, identifier, error description or health sample does.
struct LifeOSAutomationReport: Encodable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case success, partial, unavailable }
    enum Action: String, Codable, Sendable { case morning, reauthentication, zeppGuidance }
    struct Step: Codable, Equatable, Sendable {
        let operation: String
        let status: Status
        let code: String
        let message: String
    }

    let schemaVersion: Int = 1
    let action: Action
    let steps: [Step]
    var status: Status {
        if steps.allSatisfy({ $0.status == .success }) && !steps.isEmpty { return .success }
        return steps.contains { $0.status != .unavailable } ? .partial : .unavailable
    }
    var dialog: String { steps.map(\.message).joined(separator: "\n") }

    // Encode the aggregate as well as individual outcomes, so Shortcuts can
    // branch on status without interpreting prose. Never encode dependencies.
    private enum CodingKeys: String, CodingKey { case schemaVersion, action, status, steps }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(action, forKey: .action)
        try container.encode(status, forKey: .status)
        try container.encode(steps, forKey: .steps)
    }
    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Per-invocation dependencies keep tests offline without mutable global hooks.
/// The health boundary exposes only a coarse refresh outcome, never sample
/// access or a provider payload.
struct LifeOSAutomationDependencies: Sendable {
    var usesVisualFixtures: Bool
    var isConfigured: @Sendable () async -> Bool
    var fetchFinance: @Sendable () async throws -> FinanceSummary
    var checkConnection: @Sendable () async -> TailscaleConnectionPreflightState?
    var signing: @Sendable () -> SigningStatus
    var now: @Sendable () -> Date
    var isMac: Bool
    var refreshHealthKit: (@Sendable () async throws -> LifeOSAutomationHealthRefreshState)? = nil

    static func fixturesEnabled(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("-LifeOSVisualFixtures") || environment["LIFEOS_VISUAL_FIXTURES"] == "1"
    }

    static var live: Self {
        let client = TailscaleSyncClient()
        return Self(
            usesVisualFixtures: fixturesEnabled(arguments: ProcessInfo.processInfo.arguments,
                                               environment: ProcessInfo.processInfo.environment),
            isConfigured: { await client.isConfigured },
            fetchFinance: { try await client.fetchFinanceSummary() },
            checkConnection: { await client.checkConnection() },
            signing: { .current() }, now: { .now },
            isMac: {
#if os(macOS)
                true
#else
                false
#endif
            }(),
            refreshHealthKit: {
                try await LifeOSAutomationRefreshRegistry.shared.refreshHealth()
            }
        )
    }
}

enum LifeOSAutomationStatus {
    typealias Step = LifeOSAutomationReport.Step
    static let openZeppDialog = "Open Zepp manually on your iPhone and sync your strap there. Enable Zepp sharing to Apple Health, then open Fitness in LifeOS to review permissions and data freshness. This action opens LifeOS for guidance; it does not open Zepp, start sync, or confirm sync completion."
    static let foregroundStatus = "This is a foreground status check; background sync, cross-device persistence and widget refresh are not confirmed."
    static let zepp = "Zepp: automatic sync is not available through LifeOS. Open Zepp on your iPhone and sync manually; Apple Health sharing must be enabled."
    static let handoff = "USB events and personal-team reinstall are manual. Connect the iPhone to the Mac, complete device trust, Developer Mode and signing prompts in Xcode, then rebuild/reinstall using the existing app identity. This action only reports metadata; it cannot detect a cable, renew signing or install a build."
    static let authHandoff = "Tailscale login and bank consent renewal are manual. Open Tailscale to review its login and LifeOS Settings → Bank connections to review or resume consent. These are separate from Apple code signing; this action renews no login, consent or credential."
    static let scope = Step(operation: "scope", status: .unavailable, code: "foreground_only", message: foregroundStatus)
    static let zeppStep = Step(operation: "zepp", status: .unavailable, code: "manual_sync_required", message: zepp)

    static func finance(_ state: FinanceObservationState) -> String {
        switch state {
        case .observed:
            return "Enable Banking: a recent observed summary was retrieved from Windows. The gateway may refresh or return cached observations; completion of a new bank refresh is not confirmed."
        case .partial:
            return "Enable Banking: partial summary retrieved; some accounts or values are unavailable. Completion of a new bank refresh is not confirmed."
        case .stale:
            return "Enable Banking: stored summary is stale; a fresh bank sync is not confirmed."
        case .demo, .loading, .error, .unavailable:
            return "Enable Banking: current data is not confirmed. Check the connection and consent in LifeOS Settings."
        }
    }

    static func signing(_ status: SigningStatus, isMac: Bool) -> String {
        let device = isMac ? "This Mac build only, not the connected iPhone." : "This iPhone build only."
        return "\(device) \(status.stateTitle). \(status.guidance) Bundle metadata only; USB connection, device trust and successful renewal are not verified."
    }

    static func fixture(_ action: LifeOSAutomationReport.Action) -> LifeOSAutomationReport {
        .init(action: action, steps: [
            .init(operation: "fixture", status: .unavailable, code: "fixtures_enabled",
                  message: "Visual fixtures are enabled. No live network, health or signing check was performed.")
        ])
    }

    static func healthKit(_ state: LifeOSAutomationHealthRefreshState, isMac: Bool = false) -> Step {
        let status: LifeOSAutomationReport.Status
        let message: String
        switch state {
        case .refreshed:
            status = .success
            message = "HealthKit: the app-owned reconciliation completed and retained source data is available. This does not confirm Zepp sync completion."
        case .current:
            status = .success
            message = "HealthKit: current retained source data is available; a new reconciliation completion was not observed. This does not confirm Zepp sync completion."
        case .stale:
            status = .partial
            message = "HealthKit: retained source data is stale. This does not confirm Zepp sync completion."
        case .partial:
            status = .partial
            message = "HealthKit: only a partial retained result is available. This does not confirm Zepp sync completion."
        case .unavailable:
            status = .unavailable
            message = isMac
                ? "HealthKit is unavailable in the Mac build; no iOS HealthKit refresh was attempted. This does not confirm Zepp sync completion."
                : "HealthKit: no current result is available from the app-owned refresh authority. Review Health access and Fitness; this does not confirm Zepp sync completion."
        }
        return .init(operation: "healthKit", status: status, code: state.rawValue, message: message)
    }

    static func morning(_ dependencies: LifeOSAutomationDependencies) async throws -> LifeOSAutomationReport {
        try Task.checkCancellation()
        guard !dependencies.usesVisualFixtures else { return fixture(.morning) }
        let configured = await dependencies.isConfigured()
        try Task.checkCancellation()
        let banking: Step
        if configured {
            do {
                let summary = try await dependencies.fetchFinance()
                try Task.checkCancellation()
                let state = summary.financeAssessment(now: dependencies.now(), staleAfter: 15 * 60).state
                let status: LifeOSAutomationReport.Status
                switch state {
                case .observed: status = .success
                case .partial, .stale: status = .partial
                case .demo, .loading, .error, .unavailable: status = .unavailable
                }
                banking = .init(operation: "finance", status: status, code: state.rawValue, message: finance(state))
            } catch {
                try Task.checkCancellation()
                // Includes transport-level cancellation even when the enclosing
                // Swift task hasn't been cancelled. Never swallow or echo it.
                guard let failure = TailscaleSyncClient.connectionPreflightState(for: error) else {
                    throw CancellationError()
                }
                banking = connection(failure, operation: "finance")
            }
        } else {
            banking = connection(.configurationRequired, operation: "finance")
        }
        let healthKitStep: Step
        if let refreshHealthKit = dependencies.refreshHealthKit {
            do {
                let state = try await refreshHealthKit()
                try Task.checkCancellation()
                healthKitStep = healthKit(state, isMac: dependencies.isMac)
            } catch {
                if isCancellation(error) { throw CancellationError() }
                try Task.checkCancellation()
                healthKitStep = healthKit(.unavailable, isMac: dependencies.isMac)
            }
        } else {
            healthKitStep = healthKit(.unavailable, isMac: dependencies.isMac)
        }
        try Task.checkCancellation()
        return .init(action: .morning, steps: [banking, zeppStep, healthKitStep, scope])
    }

    static func reauthentication(_ dependencies: LifeOSAutomationDependencies) async throws -> LifeOSAutomationReport {
        try Task.checkCancellation()
        guard !dependencies.usesVisualFixtures else { return fixture(.reauthentication) }
        let configured = await dependencies.isConfigured()
        try Task.checkCancellation()
        let gateway: TailscaleConnectionPreflightState
        if configured {
            let result = await dependencies.checkConnection()
            try Task.checkCancellation()
            guard let result else { throw CancellationError() }
            gateway = result
        } else { gateway = .configurationRequired }
        let signingStatus = dependencies.signing()
        try Task.checkCancellation()
        let signingOutcome: LifeOSAutomationReport.Status
        switch signingStatus.state {
        case .valid: signingOutcome = .success
        case .expired, .expiringSoon: signingOutcome = .partial
        case .unknown: signingOutcome = .unavailable
        }
        return .init(action: .reauthentication, steps: [
            connection(gateway, operation: "gateway"),
            .init(operation: "signing", status: signingOutcome, code: signingStatus.state.rawValue,
                  message: signing(signingStatus, isMac: dependencies.isMac)),
            .init(operation: "reauthentication", status: .unavailable, code: "manual_action_required", message: authHandoff),
            .init(operation: "usb", status: .unavailable, code: "cable_event_not_observed", message: handoff)
        ])
    }

    private static func connection(_ state: TailscaleConnectionPreflightState, operation: String) -> Step {
        let message: String
        switch state {
        case .reachable:
            message = "Tailscale gateway: reachable for this request. Bank consent, provider refresh and cross-device sync are not verified."
        case .configurationRequired:
            message = "Connection unavailable: no approved server is configured. Review LifeOS Settings."
        case .authenticationRejected:
            message = "Gateway authentication rejected. Review Tailscale login and LifeOS Settings; bank consent status is not determined by this response."
        case .serverUnavailable:
            message = "Windows server unavailable or busy. A refresh is not confirmed; try again later."
        case .networkUnavailable:
            message = "Network unavailable. Review Tailscale and the Windows connection in LifeOS Settings."
        case .invalidResponse:
            message = "The server response could not be verified. Review the connection in LifeOS Settings."
        }
        return .init(operation: operation, status: state == .reachable ? .success : .unavailable,
                     code: state.rawValue, message: message)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

#if os(iOS)
extension LifeOSAutomationHealthRefreshState {
    static func evaluated(
        snapshot: HealthKitIntegrationSnapshot,
        projection: HealthKitFitnessProjection?,
        didCompleteRefresh: Bool
    ) -> Self {
        guard snapshot.authorizationState == .readIndeterminate,
              let projection else { return .unavailable }

        let metricProjections = Array(projection.metrics.values)
        let hasData = metricProjections.contains { !$0.observations.isEmpty } ||
            !projection.sleep.samples.isEmpty || !projection.workouts.isEmpty
        let hasPartialState = !projection.issues.isEmpty ||
            metricProjections.contains { state in
                state.state == .partial || state.state == .conflict || state.state == .error
            } || projection.sleep.state == .partial ||
            projection.sleep.state == .conflict || projection.sleep.state == .error
        let observerWasPartial = switch snapshot.lastObserverCompletion {
        case .partialSuccess, .failure, .timedOut: true
        default: false
        }
        if hasPartialState || observerWasPartial { return .partial }
        guard hasData else { return .unavailable }

        let hasStaleState = metricProjections.contains { state in
            state.state == .stale || state.syncState == .stale
        } || projection.sleep.state == .stale || projection.sleep.syncState == .stale
        if hasStaleState { return .stale }
        return didCompleteRefresh ? .refreshed : .current
    }
}
#endif

struct LifeOSMorningStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Morning Data Refresh Status"
    static var description = IntentDescription("Request the existing Windows finance summary and report its freshness plus manual Zepp/HealthKit steps. Returns versioned JSON for Get Dictionary from Input. New bank refresh completion is not guaranteed.")
    static var openAppWhenRun: Bool = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    private var dependencies: LifeOSAutomationDependencies?
    init() {}
    init(dependencies: LifeOSAutomationDependencies) { self.dependencies = dependencies }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let report = try await LifeOSAutomationStatus.morning(dependencies ?? .live)
        try Task.checkCancellation()
        return .result(value: try report.json(), dialog: IntentDialog(stringLiteral: report.dialog))
    }
}

// Retain the intent's type identity for previously saved Shortcuts. The intent
// opens the existing LifeOS Fitness destination for guidance; it never opens
// Zepp, starts a sync, or claims that Zepp sync completed.
struct LifeOSOpenZeppForSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "Zepp Manual Sync Guidance"
    static var description = IntentDescription("Open LifeOS for manual Zepp instructions on iPhone. Does not open Zepp, start or verify sync. Returns versioned JSON.")
    static var openAppWhenRun: Bool = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    private var navigation: (@Sendable () async -> Void)? = nil

    init() {}
    init(navigation: @escaping @Sendable () async -> Void) { self.navigation = navigation }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try Task.checkCancellation()
        let report = LifeOSAutomationReport(action: .zeppGuidance, steps: [
            .init(operation: "zepp", status: .unavailable, code: "manual_sync_required",
                  message: LifeOSAutomationStatus.openZeppDialog)
        ])
        if let navigation { await navigation() }
        else { await LifeOSAutomationNavigation.open(LifeOSAutomationNavigation.fitnessURL) }
        try Task.checkCancellation()
        return .result(value: try report.json(), dialog: IntentDialog(stringLiteral: report.dialog))
    }
}

struct LifeOSUSBRefreshStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Connection & Signing Status"
    static var description = IntentDescription("Manually check gateway reachability and this device's signing metadata, then follow connection and signing guidance. USB events, personal-team reinstall, Tailscale login and bank consent renewal remain manual. Returns versioned JSON.")
    static var openAppWhenRun: Bool = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    private var dependencies: LifeOSAutomationDependencies?
    private var navigation: (@Sendable () async -> Void)? = nil
    init() {}
    init(dependencies: LifeOSAutomationDependencies, navigation: (@Sendable () async -> Void)? = nil) {
        self.dependencies = dependencies
        self.navigation = navigation
    }
    init(navigation: @escaping @Sendable () async -> Void) { self.navigation = navigation }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let report = try await LifeOSAutomationStatus.reauthentication(dependencies ?? .live)
        try Task.checkCancellation()
        if let navigation { await navigation() }
        else { await LifeOSAutomationNavigation.open(LifeOSAutomationNavigation.settingsURL) }
        try Task.checkCancellation()
        return .result(value: try report.json(), dialog: IntentDialog(stringLiteral: report.dialog))
    }
}

struct LifeOSAutomationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LifeOSMorningStatusIntent(),
                    phrases: ["Check morning data in \(.applicationName)"],
                    shortTitle: "Morning Status", systemImageName: "sun.max")
        AppShortcut(intent: LifeOSOpenZeppForSyncIntent(),
                    phrases: ["Get Zepp sync guidance in \(.applicationName)"],
                    shortTitle: "Zepp Manual Sync Guidance", systemImageName: "arrow.up.forward.app")
        AppShortcut(intent: LifeOSUSBRefreshStatusIntent(),
                    phrases: ["Check connection and signing status in \(.applicationName)"],
                    shortTitle: "Connection & Signing Status", systemImageName: "checkmark.shield")
    }
}
