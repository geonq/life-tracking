import SwiftUI
#if os(iOS)
import SafariServices
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

/// HealthKit sharing is a separate privacy decision from read access. The
/// settings surface keeps that distinction visible and only exposes the
/// request action when the app supplies an explicit user-authored handler.
struct HealthWriteAccessSettings: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case unavailable
        case notRequested
        case requestPending
        case authorized
        case denied
        case restricted
        case protectedDataUnavailable
        case error
    }

    let state: State

    init(state: State) {
        self.state = state
    }

    static var platformDefault: Self { Self(state: .unavailable) }

    var title: String {
        switch state {
        case .unavailable: "Unavailable"
        case .notRequested: "Permission required"
        case .requestPending: "Waiting for Apple Health"
        case .authorized: "Write access available"
        case .denied: "Write access denied"
        case .restricted: "Restricted"
        case .protectedDataUnavailable: "Device locked"
        case .error: "Could not check"
        }
    }

    var detail: String {
        switch state {
        case .unavailable:
            "HealthKit sharing is not available in this app context."
        case .notRequested:
            "Allow LifeOS to share only explicit manual values such as water, caffeine, and body measurements."
        case .requestPending:
            "Complete the Apple Health sharing sheet. No value is written by this permission request."
        case .authorized:
            "Apple Health sharing is available for the supported manual values; every save is still rechecked."
        case .denied:
            "Apple Health sharing was denied or is unavailable. Review Health access in the system settings if needed."
        case .restricted:
            "Health data sharing is restricted on this device."
        case .protectedDataUnavailable:
            "Unlock the iPhone before LifeOS retries HealthKit sharing."
        case .error:
            "HealthKit sharing status could not be interpreted. Retry from this screen."
        }
    }

    var buttonTitle: String {
        switch state {
        case .authorized, .denied: "Review Health write access"
        case .requestPending: "Waiting…"
        default: "Allow Health writes"
        }
    }

    var allowsRequest: Bool {
        switch state {
        case .requestPending, .unavailable, .restricted, .protectedDataUnavailable:
            false
        default:
            true
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
        // HealthKit error descriptions originate at an OS/framework boundary
        // and are not a support-safe diagnostic channel.  The Settings copy
        // uses the fixed state detail above rather than rendering a raw
        // localized error that could contain private implementation data.
        return Self(state: state)
    }
}

extension HealthWriteAccessSettings {
    static func from(snapshot: HealthKitIntegrationSnapshot) -> Self {
        if snapshot.isWriteRequestInFlight {
            return Self(state: .requestPending)
        }

        let state: State
        switch snapshot.writeAuthorizationState {
        case .unavailable:
            state = .unavailable
        case .restricted, .revoked:
            state = .restricted
        case .protectedDataUnavailable:
            state = .protectedDataUnavailable
        case .writeNotDetermined, .notRequested, .requestRequired, .requestPending:
            state = .notRequested
        case .writeAuthorized:
            state = .authorized
        case .writeDenied:
            state = .denied
        case .readIndeterminate, .error:
            state = .error
        }
        return Self(state: state)
    }
}
#endif

/// A deliberately small failure vocabulary for Settings.  Error bodies,
/// endpoints, account identifiers, and provider messages are never rendered
/// or copied; callers may retain only the class and its recovery guidance.
enum SettingsFailureClass: String, Equatable, Sendable {
    case configuration
    case authentication
    case authorization
    case expired
    case refreshRequired
    case revoked
    case rateLimited
    case unavailable
    case invalidResponse
    case unknown

    var title: String {
        switch self {
        case .configuration: "Configuration required"
        case .authentication: "Identity rejected"
        case .authorization: "Authorization required"
        case .expired: "Session expired"
        case .refreshRequired: "Refresh required"
        case .revoked: "Connection revoked"
        case .rateLimited: "Retry later"
        case .unavailable: "Service unavailable"
        case .invalidResponse: "Response rejected"
        case .unknown: "Attention required"
        }
    }

    var detail: String {
        switch self {
        case .configuration:
            "The approved gateway or provider configuration is missing. No connection was changed."
        case .authentication:
            "The gateway rejected this device identity. No credential was changed."
        case .authorization:
            "The provider needs an explicit authorization step before it can be used."
        case .expired:
            "The provider session expired. Start a fresh consent or authorization flow."
        case .refreshRequired:
            "The retained observation needs a fresh read before it can be treated as current."
        case .revoked:
            "The provider connection was revoked. Reconnect through the gateway to restore it."
        case .rateLimited:
            "The provider asked the gateway to slow down. Wait, then retry the read-only refresh."
        case .unavailable:
            "The gateway or provider could not be reached. Existing observations remain source-labelled."
        case .invalidResponse:
            "The response failed the typed boundary checks. No returned data was accepted."
        case .unknown:
            "The operation did not complete. Retry; only a redacted failure class is retained."
        }
    }

    var recoveryTitle: String {
        switch self {
        case .configuration, .authorization, .expired, .revoked:
            "Review setup"
        case .refreshRequired, .authentication, .unavailable, .rateLimited, .invalidResponse, .unknown:
            "Retry"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .refreshRequired, .authentication, .unavailable, .rateLimited, .invalidResponse, .unknown:
            true
        case .configuration, .authorization, .expired, .revoked:
            false
        }
    }

    static func classify(_ error: Error?) -> Self {
        guard let error else { return .unknown }
        if let syncError = error as? TailscaleSyncError {
            switch syncError {
            case .notConfigured, .invalidServerURL, .gatewayNotConfigured:
                return .configuration
            case .httpError(401), .httpError(403):
                return .authentication
            case .httpError(408), .httpError(429):
                return syncError == .httpError(429) ? .rateLimited : .unavailable
            case .httpError(let status) where (500...599).contains(status):
                return .unavailable
            case .connectionAlreadyLinking:
                return .authorization
            case .invalidInstitutionId, .invalidConnectionId, .invalidConsentURL,
                 .invalidBarcode, .invalidResponse, .responseTooLarge, .requestTooLarge:
                return .invalidResponse
            case .httpError:
                return .unknown
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .unavailable : .unavailable
        }
        return .unknown
    }

    /// Coordinator error strings are untrusted input.  This classifier may
    /// inspect a few coarse keywords but never returns the original message.
    static func classify(untrustedMessage: String?) -> Self {
        guard let message = untrustedMessage?.lowercased(), !message.isEmpty else { return .unknown }
        if message.contains("reauth")
            || message.contains("authorization")
            || message.contains("consent") {
            return .authorization
        }
        if message.contains("401") || message.contains("403") || message.contains("auth") {
            return .authentication
        }
        if message.contains("429") || message.contains("rate") || message.contains("limit") {
            return .rateLimited
        }
        if message.contains("expired") || message.contains("expiry") {
            return .expired
        }
        if message.contains("revok") {
            return .revoked
        }
        if message.contains("config") || message.contains("not configured") {
            return .configuration
        }
        if message.contains("unavailable") || message.contains("network") || message.contains("timeout") {
            return .unavailable
        }
        if message.contains("response") || message.contains("decode") || message.contains("invalid") {
            return .invalidResponse
        }
        return .unknown
    }
}

/// State exposed by a connection row.  Observation quality and connector
/// lifecycle are intentionally separate: a stale retained observation is not
/// the same thing as a healthy provider, and a revoked connector is not merely
/// an empty row.
enum SettingsProviderLifecycle: String, Equatable, Sendable {
    case unavailable
    case authorized
    case refreshDue
    case reauthRequired
    case revoked
    case rateLimited
    case failed

    var title: String {
        switch self {
        case .unavailable: "Unavailable"
        case .authorized: "Authorized"
        case .refreshDue: "Refresh due"
        case .reauthRequired: "Re-auth required"
        case .revoked: "Revoked"
        case .rateLimited: "Rate limited"
        case .failed: "Connection error"
        }
    }

    var failureClass: SettingsFailureClass? {
        switch self {
        case .unavailable: .unavailable
        case .authorized: nil
        case .refreshDue: .refreshRequired
        case .reauthRequired: .authorization
        case .revoked: .revoked
        case .rateLimited: .rateLimited
        case .failed: .unknown
        }
    }

    var canRetry: Bool {
        switch self {
        case .authorized, .reauthRequired, .revoked: false
        case .unavailable, .refreshDue, .rateLimited, .failed: true
        }
    }

    var retryTitle: String {
        switch self {
        case .reauthRequired, .revoked: "Review authorization"
        case .refreshDue, .rateLimited: "Retry refresh"
        case .unavailable, .failed: "Retry connection"
        case .authorized: "Refresh"
        }
    }

    var recoveryDetail: String {
        switch self {
        case .authorized:
            "The gateway has an authorized provider session; each observation keeps its own freshness."
        case .refreshDue:
            "The last provider observation is retained, but a read-only refresh is due."
        case .reauthRequired:
            "The provider needs authorization again. Raw credentials remain on the Windows gateway."
        case .revoked:
            "The provider connection was revoked. Reconnect through its reviewed gateway flow."
        case .rateLimited:
            "The provider is rate limiting requests. Wait before retrying; no data is fabricated."
        case .failed:
            "The provider request failed. Retry the read-only refresh; the client keeps no raw error body."
        case .unavailable:
            "No validated provider session or observation is available."
        }
    }

    static func resolve(
        snapshot: ProviderSnapshot?,
        connector: ConnectorState?
    ) -> Self {
        let connector = connector ?? snapshot?.provenance.connector ?? .unavailable
        switch connector {
        case .reauthRequired: return .reauthRequired
        case .revoked: return .revoked
        case .rateLimited: return .rateLimited
        case .error: return .failed
        case .disabled, .unavailable: return .unavailable
        case .refreshDue: return .refreshDue
        case .healthy:
            return snapshot?.provenance.quality == .observed ? .authorized : .unavailable
        }
    }
}

extension TailscaleConnectionPreflightState {
    var settingsTitle: String {
        switch self {
        case .reachable: "Windows gateway reachable"
        case .configurationRequired: "Secure configuration required"
        case .authenticationRejected: "Tailscale device identity rejected"
        case .serverUnavailable: "Windows gateway unavailable"
        case .networkUnavailable: "Tailscale network unavailable"
        case .invalidResponse: "Gateway response rejected"
        }
    }

    var settingsDetail: String {
        switch self {
        case .reachable:
            "The approved gateway accepted the read-only request with Tailscale device identity. This does not prove that any provider is connected."
        case .configurationRequired:
            "The signed approved-host configuration or HTTPS server URL is missing or invalid."
        case .authenticationRejected:
            "The gateway is reachable, but it rejected this device's Tailscale identity. No credential was changed."
        case .serverUnavailable:
            "The approved gateway returned a temporary server or rate-limit failure. Check the Windows services, then retry."
        case .networkUnavailable:
            "The approved gateway could not be reached. Check Tailscale on this device and the Windows PC, then retry."
        case .invalidResponse:
            "The response did not satisfy the fail-closed transport contract. No returned data was accepted."
        }
    }

    var settingsIsRetryable: Bool {
        self != .configurationRequired
    }
}

/// The app-side phases around the gateway-owned bank callback.  The callback
/// itself stays on Windows; the phone only stores the validated opaque link,
/// observes Safari dismissal, and polls the gateway for its authoritative
/// state.
enum BankConsentLifecyclePhase: String, Equatable, Sendable {
    case idle
    case opening
    case awaitingConsent
    case returningFromConsent
    case checking
    case linked
    case expired
    case alreadyLinking
    case gatewayNotConfigured
    case failed

    var title: String {
        switch self {
        case .idle: "Not started"
        case .opening: "Opening consent"
        case .awaitingConsent: "Consent pending"
        case .returningFromConsent: "Returning from consent"
        case .checking: "Checking status"
        case .linked: "Linked"
        case .expired: "Consent expired"
        case .alreadyLinking: "Already linking"
        case .gatewayNotConfigured: "Gateway not configured"
        case .failed: "Connection error"
        }
    }

    var canRetry: Bool {
        switch self {
        case .opening, .checking, .linked: false
        case .idle, .awaitingConsent, .returningFromConsent, .expired,
             .alreadyLinking, .gatewayNotConfigured, .failed: true
        }
    }
}

/// Copyable diagnostics contain only enum states and safe counts.  The report
/// is intentionally useful for support while being useless as a credential or
/// provider-data export.
struct SettingsRedactedDiagnostics: Equatable, Sendable {
    let gateway: TailscaleConnectionPreflightState?
    let providers: [SettingsProviderLifecycle]
    let finance: FinanceSettingsReadiness?
    let health: HealthReadAccessSettings.State?
    let appGroup: AppGroupSettingsState?
    let signing: SigningStatus?
    let failure: SettingsFailureClass?

    init(
        gateway: TailscaleConnectionPreflightState? = nil,
        providers: [SettingsProviderLifecycle] = [],
        finance: FinanceSettingsReadiness? = nil,
        health: HealthReadAccessSettings.State? = nil,
        appGroup: AppGroupSettingsState? = nil,
        signing: SigningStatus? = nil,
        failure: SettingsFailureClass? = nil
    ) {
        self.gateway = gateway
        self.providers = providers
        self.finance = finance
        self.health = health
        self.appGroup = appGroup
        self.signing = signing
        self.failure = failure
    }

    var summary: String {
        lines.joined(separator: " · ")
    }

    var text: String {
        (["LifeOS redacted diagnostics"] + lines + [
            "No endpoints, URLs, account identifiers, balances, provider payloads, credentials, tokens, or raw error text are included."
        ]).joined(separator: "\n")
    }

    private var lines: [String] {
        var result: [String] = []
        if let gateway {
            result.append("gateway=\(gateway.rawValue)")
        }
        if !providers.isEmpty {
            let counts = Dictionary(grouping: providers, by: \.rawValue)
                .map { "\($0.key):\($0.value.count)" }
                .sorted()
                .joined(separator: ",")
            result.append("providers=\(counts)")
        }
        if let finance { result.append("finance=\(finance.rawValue)") }
        if let health { result.append("health=\(String(describing: health))") }
        if let appGroup { result.append("app_group=\(appGroup.rawValue)") }
        if let signing {
            result.append("signing_mode=\(signing.mode.rawValue)")
            result.append("signing_state=\(signing.state.rawValue)")
        }
        if let failure { result.append("failure=\(failure.rawValue)") }
        if result.isEmpty { result.append("scope=not_checked") }
        return result
    }
}

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
    let lifecycle: SettingsProviderLifecycle
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
                lifecycle: .resolve(snapshot: nil, connector: connector),
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
            lifecycle: .resolve(snapshot: snapshot, connector: resolvedConnector),
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

    static func resolve(
        serverURL: String,
        approvedHosts: Set<String>
    ) -> Self {
        let urlState: SyncSettingsURLState
        if serverURL.isEmpty {
            urlState = .missing
        } else if TailscaleSyncClient.validatedServerURL(serverURL, approvedHosts: approvedHosts) != nil {
            urlState = .valid
        } else {
            urlState = .invalid
        }
        return Self(
            approvedHostConfigured: !approvedHosts.isEmpty,
            urlState: urlState
        )
    }

    var canAttemptConnection: Bool {
        approvedHostConfigured && urlState == .valid
    }

    var title: String {
        if !approvedHostConfigured { return "Approved signed host missing" }
        switch urlState {
        case .missing: return "Server URL missing"
        case .invalid: return "Server URL rejected"
        case .valid:
            return "Ready for Tailscale identity preflight"
        }
    }
}

/// Settings must be safe to render in screenshot/visual-fixture launches.
/// This policy is shared by the view's task and its manual action guard so a
/// future refactor cannot reintroduce a network call on fixture navigation.
enum SettingsFixturePolicy {
    static func shouldRunFinanceGatewayPreflight(usesVisualFixtures: Bool) -> Bool {
        !usesVisualFixtures
    }
}

/// A configured route is not the same thing as a verified runtime path. Keep
/// the status copy tied to the latest read-only preflight, if one exists.
enum SyncGatewayRuntimePresentation {
    static func identityStatusTitle(for preflight: TailscaleConnectionPreflightState?) -> String {
        guard let preflight else { return "Required by configuration" }
        return preflight == .reachable ? "Verified for this session" : "Not verified"
    }

    static func identityStatusDetail(for preflight: TailscaleConnectionPreflightState?) -> String {
        guard let preflight else {
            return "Tailscale Serve identity is required by configuration; no current runtime preflight has verified enforcement."
        }
        guard preflight == .reachable else {
            return "\(preflight.settingsTitle). Runtime identity enforcement is not verified for this session."
        }
        return "The latest read-only preflight succeeded with the approved gateway. This verifies the current session only, not deployment or provider connectivity."
    }

    static func identityIsVerified(for preflight: TailscaleConnectionPreflightState?) -> Bool {
        preflight == .reachable
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
    @ObservedObject private var clipperCoordinator: ClipperCoordinator
    private let healthReadAccess: HealthReadAccessSettings
    private let requestHealthReadAccess: (@MainActor () async -> Void)?
    private let requestHealthWriteAccess: (@MainActor () async -> Void)?
    private let retainedHealthData: RetainedHealthDataSettings
    private let healthWriteAccess: HealthWriteAccessSettings
    private let usesVisualFixtures: Bool
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

    private var clipperReadiness: SettingsReadiness {
        .clipper(clipperCoordinator.state)
    }

    private var categories: [SettingsCategory] {
        [
            .init(id: "providers", title: "AI providers", subtitle: "Codex, Claude, GLM, DeepSeek, Google AI Studio", readiness: .providers(usageSettings.readiness), icon: .assistant, color: LifeOSTokens.Module.usage),
            .init(id: "finance", title: "Bank connections", subtitle: "Sparkasse, Revolut Personal / Business, Trade Republic, and consent", readiness: .finance(financeSettings.readiness), icon: .bankConnections, color: LifeOSTokens.Module.finance),
            .init(id: "clipper", title: "Clipper", subtitle: "Transit capture via the Windows gateway source", readiness: clipperReadiness, icon: .clipper, color: LifeOSTokens.Module.business),
            .init(id: "health", title: "Health & devices", subtitle: "Helio → Zepp → Apple Health / HealthKit", readiness: .healthRead(healthReadAccess.state), icon: .health, color: LifeOSTokens.Module.fitness),
            .init(id: "sync", title: "Sync & storage", subtitle: "Tailscale device identity, Windows authority, and local data", readiness: .identityPending, icon: .refresh, color: LifeOSTokens.Module.tax),
            .init(id: "privacy", title: "Privacy & security", subtitle: "Local safeguards, signing, and unresolved server gates", readiness: .localSafeguards, icon: .security, color: LifeOSTokens.warning)
        ]
    }

    #if os(iOS)
    init(
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator,
        clipperCoordinator: ClipperCoordinator,
        healthReadAccess: HealthReadAccessSettings,
        requestHealthReadAccess: (@MainActor () async -> Void)?,
        retainedHealthData: RetainedHealthDataSettings,
        healthKitController: HealthKitIntegrationController,
        healthKitFitnessRepository: HealthKitFitnessRepository,
        requestHealthWriteAccess: (@MainActor () async -> Void)? = nil,
        healthWriteAccess: HealthWriteAccessSettings = .platformDefault,
        usesVisualFixtures: Bool = false
    ) {
        _usageCoordinator = ObservedObject(wrappedValue: usageCoordinator)
        _financeCoordinator = ObservedObject(wrappedValue: financeCoordinator)
        _clipperCoordinator = ObservedObject(wrappedValue: clipperCoordinator)
        self.healthReadAccess = healthReadAccess
        self.requestHealthReadAccess = requestHealthReadAccess
        self.requestHealthWriteAccess = requestHealthWriteAccess
        self.retainedHealthData = retainedHealthData
        self.healthWriteAccess = healthWriteAccess
        self.usesVisualFixtures = usesVisualFixtures
        self.healthKitController = healthKitController
        self.healthKitFitnessRepository = healthKitFitnessRepository
    }
    #else
    init(
        usageCoordinator: UsageCoordinator,
        financeCoordinator: FinanceCoordinator,
        clipperCoordinator: ClipperCoordinator,
        healthReadAccess: HealthReadAccessSettings = .platformDefault,
        requestHealthReadAccess: (@MainActor () async -> Void)? = nil,
        retainedHealthData: RetainedHealthDataSettings = .unavailable,
        requestHealthWriteAccess: (@MainActor () async -> Void)? = nil,
        healthWriteAccess: HealthWriteAccessSettings = .platformDefault,
        usesVisualFixtures: Bool = false
    ) {
        _usageCoordinator = ObservedObject(wrappedValue: usageCoordinator)
        _financeCoordinator = ObservedObject(wrappedValue: financeCoordinator)
        _clipperCoordinator = ObservedObject(wrappedValue: clipperCoordinator)
        self.healthReadAccess = healthReadAccess
        self.requestHealthReadAccess = requestHealthReadAccess
        self.requestHealthWriteAccess = requestHealthWriteAccess
        self.retainedHealthData = retainedHealthData
        self.healthWriteAccess = healthWriteAccess
        self.usesVisualFixtures = usesVisualFixtures
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
                                refreshAction: usesVisualFixtures ? nil : { await usageCoordinator.refresh() }
                            )
                        } label: {
                            SettingsHubCard(category: categories[0])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-providers")

                        NavigationLink {
                            FinanceConnectionsSettingsView(
                                snapshot: financeSettings,
                                refreshAction: usesVisualFixtures ? nil : { await financeCoordinator.refresh() },
                                usesVisualFixtures: usesVisualFixtures
                            )
                        } label: {
                            SettingsHubCard(category: categories[1])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-finance")

                        NavigationLink {
                            ClipperConnectionSettingsView(
                                state: clipperCoordinator.state,
                                lastUpdated: clipperCoordinator.lastUpdated,
                                errorMessage: clipperCoordinator.errorMessage,
                                refreshAction: usesVisualFixtures ? nil : { await clipperCoordinator.refresh() }
                            )
                        } label: {
                            SettingsHubCard(category: categories[2])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-clipper")

                        NavigationLink {
#if os(iOS)
                            HealthDevicesSettingsView(
                                healthReadAccess: healthReadAccess,
                                requestHealthReadAccess: requestHealthReadAccess,
                                requestHealthWriteAccess: requestHealthWriteAccess,
                                retainedHealthData: retainedHealthData,
                                healthWriteAccess: healthWriteAccess,
                                healthKitController: healthKitController,
                                healthKitFitnessRepository: healthKitFitnessRepository
                            )
#else
                            HealthDevicesSettingsView(
                                healthReadAccess: healthReadAccess,
                                requestHealthReadAccess: requestHealthReadAccess,
                                requestHealthWriteAccess: requestHealthWriteAccess,
                                retainedHealthData: retainedHealthData,
                                healthWriteAccess: healthWriteAccess
                            )
#endif
                        } label: {
                            SettingsHubCard(category: categories[3])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-health")

                        NavigationLink {
                            SyncStorageSettingsView()
                        } label: {
                            SettingsHubCard(category: categories[4])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-sync")

                        NavigationLink {
                            PrivacySecuritySettingsView()
                        } label: {
                            SettingsHubCard(category: categories[5])
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
    let color: Color
}

private enum SettingsReadiness: Equatable {
    case providers(UsageSettingsHubReadiness)
    case finance(FinanceSettingsReadiness)
    case clipper(ClipperLoadState)
    case serverGatePending
    case consentRequired
    case healthRead(HealthReadAccessSettings.State)
    case identityPending
    case localSafeguards

    var title: String {
        switch self {
        case .providers(let readiness): readiness.title
        case .finance(let readiness): readiness.title
        case .clipper(let state):
            switch state {
            case .demo: "Demo fixtures active"
            case .loading: "Checking gateway"
            case .observed: "Connected"
            case .stale: "Stale · refresh available"
            case .unavailable: "Not connected"
            }
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
        case .clipper(.observed):
            LifeOSTokens.success
        case .clipper(.demo), .clipper(.loading):
            LifeOSTokens.info
        case .clipper(.stale), .clipper(.unavailable):
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
                    .fill(category.color.opacity(0.13))
                LifeOSIcon(category.icon)
                    .foregroundStyle(category.color)
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
                colors: [LifeOSTokens.surface, category.color.opacity(isHovering || isFocused ? 0.06 : 0.022)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: LifeOSTokens.cardShape
        )
        .overlay(
            LifeOSTokens.cardShape.stroke(
                isHovering || isFocused ? category.color.opacity(0.48) : LifeOSTokens.quietBorder,
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
    let revokeAction: ((Provider) async -> Void)?

    init(
        snapshot: UsageSettingsSnapshot = .unavailable,
        refreshAction: (() async -> Void)? = nil,
        revokeAction: ((Provider) async -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.refreshAction = refreshAction
        self.revokeAction = revokeAction
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
                                status: provider.lifecycle.title,
                                icon: providerIdentityIcon(provider.provider),
                                statusColor: providerLifecycleColor(provider.lifecycle),
                                iconColor: providerIdentityColor(provider.provider),
                                iconAccessibilityLabel: "\(provider.provider.displayName) provider identity"
                            )
                            if provider.lifecycle != .authorized {
                                SettingsProviderRecoveryRow(
                                    provider: provider,
                                    refreshAction: refreshAction,
                                    revokeAction: revokeAction
                                )
                            }
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

                SettingsDiagnosticsView(
                    diagnostics: SettingsRedactedDiagnostics(
                        providers: snapshot.providers.map(\.lifecycle),
                        failure: snapshot.errorMessage.map { SettingsFailureClass.classify(untrustedMessage: $0) }
                    )
                )

                TruthfulSetupNote(text: "Provider rows reflect only UsageCoordinator observations and connector state. Provider keys remain on the Windows Hermes server; there is no paste, reveal, or copy path for raw keys. Revoke and reauthorization remain gateway-owned; this client never receives a raw token.")
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
        let lifecycle = "Lifecycle: \(provider.lifecycle.title)"
        switch provider.state {
        case .observed:
            return "\(lifecycle) · \(source) · \(freshness) · \(connector)"
        case .partial:
            return "\(lifecycle) · \(source) · \(freshness) · some windows are unavailable"
        case .stale:
            return "\(lifecycle) · \(source) · last observed \(observedAtLabel(provider.observedAt)) · \(connector)"
        case .unavailable:
            return "\(lifecycle) · \(source) · no current observation"
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

    private func providerIdentityIcon(_ provider: Provider) -> LifeOSIconName {
        switch provider {
        case .codex: .usage
        case .claude: .assistant
        case .glm: .graphUp
        case .deepseek: .search
        case .googleAIStudio: .business
        }
    }

    private func providerIdentityColor(_ provider: Provider) -> Color {
        switch provider {
        case .codex: LifeOSTokens.accent
        case .claude: .lifeOSOrange500
        case .glm: .lifeOSViolet500
        case .deepseek: .lifeOSTeal500
        case .googleAIStudio: .lifeOSPink500
        }
    }

    private func providerLifecycleColor(_ lifecycle: SettingsProviderLifecycle) -> Color {
        switch lifecycle {
        case .authorized: LifeOSTokens.success
        case .refreshDue: LifeOSTokens.info
        case .reauthRequired, .revoked, .rateLimited, .failed, .unavailable:
            LifeOSTokens.warning
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

private struct SettingsProviderRecoveryRow: View {
    let provider: ProviderConnectionSettings
    let refreshAction: (() async -> Void)?
    let revokeAction: ((Provider) async -> Void)?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(provider.lifecycle.recoveryDetail)
                .font(LifeOSFont.inter(11))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if provider.lifecycle.canRetry, let refreshAction {
                    Button {
                        guard !isRunning else { return }
                        isRunning = true
                        Task {
                            await refreshAction()
                            isRunning = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isRunning {
                                ProgressView().controlSize(.small)
                            } else {
                                LifeOSIcon(.refresh).frame(width: 13, height: 13)
                            }
                            Text(provider.lifecycle.retryTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(LifeOSTokens.accent)
                    .disabled(isRunning)
                    .accessibilityIdentifier("settings-provider-retry-\(provider.provider.rawValue)")
                }

                if provider.lifecycle != .unavailable {
                    if let revokeAction {
                        Button("Revoke", role: .destructive) {
                            Task { await revokeAction(provider.provider) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings-provider-revoke-\(provider.provider.rawValue)")
                    } else {
                        HStack(spacing: 6) {
                            LifeOSIcon(.security).frame(width: 13, height: 13)
                            Text("Revoke in gateway")
                        }
                            .font(LifeOSFont.inter(11, weight: .semiBold))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .accessibilityLabel("Revoke is managed by the Windows gateway")
                    }
                }
            }
        }
        .padding(.leading, 38)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
    }
}

struct ClipperConnectionSettingsView: View {
    let state: ClipperLoadState
    let lastUpdated: Date?
    let errorMessage: String?
    let refreshAction: (() async -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Clipper connection",
                    message: "Transit data is read from the Windows Hermes gateway. There is no credential, capture, or storage path in this app."
                )

                SettingsSection(title: "Connection status", icon: .clipper) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Clipper source",
                            detail: clipperDetail,
                            status: readinessTitle,
                            icon: .clipper,
                            statusColor: readinessColor
                        )
                        if let lastUpdated {
                            Divider().padding(.leading, 38)
                            SettingsStatusRow(
                                title: "Latest source update",
                                detail: "Snapshot timestamp reported by the gateway.",
                                status: lastUpdated.formatted(date: .abbreviated, time: .shortened),
                                icon: .refresh,
                                statusColor: LifeOSTokens.tertiaryText
                            )
                        }
                        if let errorMessage, !errorMessage.isEmpty {
                            let failure = SettingsFailureClass.classify(untrustedMessage: errorMessage)
                            Divider().padding(.leading, 38)
                            SettingsStatusRow(
                                title: "Last error",
                                detail: failure.detail,
                                status: failure.title,
                                icon: .warning,
                                statusColor: LifeOSTokens.warning
                            )
                        }
                    }
                }

                SettingsSection(title: "Dependency", icon: .bankConnections) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Tailscale sync",
                            detail: "The gateway is reachable only through the sync path configured under Sync & storage. If that shows not ready, Clipper cannot connect.",
                            status: "Required",
                            icon: .refresh,
                            statusColor: LifeOSTokens.tertiaryText
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Gateway route",
                            detail: "GET /clipper/summary on the Windows gateway. Until a real source feeds it, the route reports an honest typed-unavailable snapshot.",
                            status: state == .unavailable ? "Source not connected" : "Serving",
                            icon: .clipper,
                            statusColor: state == .unavailable ? LifeOSTokens.warning : LifeOSTokens.success
                        )
                    }
                }

                if let refreshAction {
                    Button {
                        Task { await refreshAction() }
                    } label: {
                        HStack(spacing: 8) {
                            if state == .loading {
                                ProgressView().controlSize(.small)
                            } else {
                                LifeOSIcon(.refresh).frame(width: 15, height: 15)
                            }
                            Text(state == .loading ? "Checking gateway…" : "Refresh Clipper connection")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSTokens.accent)
                    .disabled(state == .loading)
                    .accessibilityIdentifier("settings-clipper-refresh")
                }

                SettingsDiagnosticsView(
                    diagnostics: SettingsRedactedDiagnostics(
                        failure: errorMessage.map { SettingsFailureClass.classify(untrustedMessage: $0) }
                    )
                )

                TruthfulSetupNote(text: "Rows reflect only ClipperCoordinator observations. No demo or placeholder transit data exists outside explicit fixture builds; unavailable means not connected.")
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Clipper")
    }

    private var readinessTitle: String {
        switch state {
        case .demo: "Demo fixtures"
        case .loading: "Checking"
        case .observed: "Connected"
        case .stale: "Stale"
        case .unavailable: "Not connected"
        }
    }

    private var readinessColor: Color {
        switch state {
        case .demo, .loading: LifeOSTokens.info
        case .observed: LifeOSTokens.success
        case .stale, .unavailable: LifeOSTokens.warning
        }
    }

    private var clipperDetail: String {
        switch state {
        case .demo:
            return "Fixture build active; production source is bypassed."
        case .loading:
            return "Contacting the gateway for a fresh snapshot."
        case .observed:
            return "Fresh snapshot observed from the gateway source."
        case .stale:
            return "Last observation aged out; refresh to re-check."
        case .unavailable:
            return "No current observation. The gateway route answers honestly until a source is wired."
        }
    }
}

#if os(iOS)
/// Opens the gateway-issued consent URL in an in-app Safari sheet. LifeOS
/// never renders bank credential UI itself -- the bank's own hosted consent
/// page is shown verbatim inside the system browser surface.
private struct BankConsentSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#endif

/// Honest, coarse per-row state for one catalog connector's consent attempt.
/// Mirrors `TailscaleConnectionPreflightState`: never claims "connected"
/// without an authoritative `linked` status from the gateway.
enum BankConsentRowState: Equatable {
    case idle
    case openingConsent
    case awaitingConsent(BankConsentLink)
    case returningFromConsent(BankConsentLink)
    case checkingStatus(BankConsentLink)
    case linked
    case expired
    case alreadyLinking(BankConsentLink?)
    case gatewayNotConfigured
    case error(BankConsentLink?)

    static func recoveredState(
        for error: TailscaleSyncError,
        preserving link: BankConsentLink? = nil
    ) -> Self {
        switch error {
        case .connectionAlreadyLinking:
            return .alreadyLinking(link)
        case .gatewayNotConfigured:
            return .gatewayNotConfigured
        default:
            return .error(link)
        }
    }

    var lifecyclePhase: BankConsentLifecyclePhase {
        switch self {
        case .idle: .idle
        case .openingConsent: .opening
        case .awaitingConsent: .awaitingConsent
        case .returningFromConsent: .returningFromConsent
        case .checkingStatus: .checking
        case .linked: .linked
        case .expired: .expired
        case .alreadyLinking: .alreadyLinking
        case .gatewayNotConfigured: .gatewayNotConfigured
        case .error: .failed
        }
    }
}

@MainActor
private final class BankConsentRowController: ObservableObject {
    @Published var state: BankConsentRowState = .idle
    @Published var showSafari = false
    private var task: Task<Void, Never>?
    private let client: TailscaleSyncClient
    private let institutionId: String

    init(client: TailscaleSyncClient, institutionId: String) {
        self.client = client
        self.institutionId = institutionId
    }

    func start(institutionId: String) {
        task?.cancel()
        // A pending opaque handoff is recoverable state. Re-check it before
        // asking the gateway for another link so a transient failure or a
        // 409-already-linking response cannot strand the consent session.
        if let pending = BankConsentPendingLinkStore.load(institutionId: self.institutionId) {
            state = .awaitingConsent(pending)
            refreshStatus()
            return
        }
        state = .openingConsent
        task = Task { [client] in
            do {
                let link = try await client.requestBankConsent(institutionId: institutionId)
                guard !Task.isCancelled else { return }
                BankConsentPendingLinkStore.save(link, institutionId: self.institutionId)
                self.state = .awaitingConsent(link)
#if os(iOS)
                self.showSafari = true
#elseif os(macOS)
                NSWorkspace.shared.open(link.consentUrl)
#endif
            } catch {
                guard !Task.isCancelled else { return }
                self.state = Self.rowState(for: error)
            }
        }
    }

    func restorePendingConsent() {
        guard case .idle = state,
              let link = BankConsentPendingLinkStore.load(institutionId: institutionId) else { return }
        state = .awaitingConsent(link)
        refreshStatus()
    }

    func openConsent() {
        guard case .awaitingConsent(let link) = state else { return }
#if os(iOS)
        showSafari = true
#elseif os(macOS)
        NSWorkspace.shared.open(link.consentUrl)
#endif
    }

    /// Safari dismissal is only a local callback boundary. It does not mean
    /// that the bank linked successfully; the gateway must still be polled.
    func consentDidDismiss() {
        guard case .awaitingConsent(let link) = state else { return }
        state = .returningFromConsent(link)
        refreshStatus()
    }

    /// Retries the current opaque consent session when one exists. Without a
    /// retained link, the only safe recovery is a new gateway request.
    func retry() {
        switch state {
        case .awaitingConsent:
            openConsent()
        case .alreadyLinking(let link), .error(let link):
            if link != nil {
                refreshStatus()
            } else {
                start(institutionId: institutionId)
            }
        case .idle, .expired:
            start(institutionId: institutionId)
        default:
            break
        }
    }

    var hasPendingLinkForRecovery: Bool {
        switch state {
        case .awaitingConsent, .returningFromConsent, .checkingStatus:
            true
        case .alreadyLinking(let link), .error(let link):
            link != nil
        default:
            false
        }
    }

    func refreshStatus() {
        let link: BankConsentLink
        switch state {
        case .awaitingConsent(let pending), .returningFromConsent(let pending):
            link = pending
        case .alreadyLinking(let pending), .error(let pending):
            guard let pending else { return }
            link = pending
        default:
            return
        }
        task?.cancel()
        state = .checkingStatus(link)
        task = Task { [client] in
            do {
                let result = try await client.bankConsentStatus(connectionId: link.connectionId)
                guard !Task.isCancelled else { return }
                switch result {
                case .linked:
                    // Retain only the opaque handoff so a later Settings
                    // visit can re-check the gateway and render Linked again.
                    self.state = .linked
                case .expired:
                    BankConsentPendingLinkStore.clear(institutionId: self.institutionId)
                    self.state = .expired
                case .error:
                    // The gateway may report a temporary provider failure;
                    // keep the opaque link so the user can retry status or
                    // reopen the hosted consent flow without starting over.
                    self.state = .error(link)
                case .created, .linkOpened: self.state = .awaitingConsent(link)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.state = Self.rowState(for: error, preserving: link)
            }
        }
    }

    func reset() {
        task?.cancel()
        state = .idle
        showSafari = false
    }

    deinit {
        task?.cancel()
    }

    static func rowState(for error: Error, preserving link: BankConsentLink? = nil) -> BankConsentRowState {
        guard let syncError = error as? TailscaleSyncError else { return .error(link) }
        return BankConsentRowState.recoveredState(for: syncError, preserving: link)
    }
}

private struct BankConsentConnectRow: View {
    let descriptor: FinanceConnectorDescriptor
    let syncClient: TailscaleSyncClient
    let gatewayPreflight: TailscaleConnectionPreflightState?
    let onLinked: (() async -> Void)?
    @StateObject private var controller: BankConsentRowController

    init(
        descriptor: FinanceConnectorDescriptor,
        syncClient: TailscaleSyncClient,
        gatewayPreflight: TailscaleConnectionPreflightState?,
        onLinked: (() async -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.syncClient = syncClient
        self.gatewayPreflight = gatewayPreflight
        self.onLinked = onLinked
        _controller = StateObject(wrappedValue: BankConsentRowController(
            client: syncClient,
            institutionId: descriptor.kind.rawValue
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                controller.retry()
            } label: {
                HStack(spacing: 7) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        LifeOSIcon(.security).frame(width: 14, height: 14)
                    }
                    Text(buttonLabel)
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(LifeOSTokens.accent)
            .disabled(!canTap)
            .accessibilityIdentifier("settings-finance-connect-\(descriptor.kind.rawValue)")

            HStack(alignment: .top, spacing: 6) {
                LifeOSIcon(statusIcon)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.lifecyclePhase.title)
                        .font(LifeOSFont.inter(11, weight: .semiBold))
                        .foregroundStyle(statusColor)
                    Text(statusDetail)
                        .font(LifeOSFont.inter(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-finance-connect-status-\(descriptor.kind.rawValue)")

            if controller.hasPendingLinkForRecovery {
                Button("Re-check status") {
                    controller.refreshStatus()
                }
                .font(LifeOSFont.inter(11, weight: .semiBold))
                .buttonStyle(.plain)
                .foregroundStyle(LifeOSTokens.accent)
                .disabled(isBusy)
                .accessibilityIdentifier("settings-finance-connect-recheck-\(descriptor.kind.rawValue)")
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
#if os(iOS)
        .sheet(isPresented: $controller.showSafari, onDismiss: {
            controller.consentDidDismiss()
        }) {
            if case .awaitingConsent(let link) = controller.state {
                BankConsentSafariView(url: link.consentUrl)
            } else if case .checkingStatus(let link) = controller.state {
                BankConsentSafariView(url: link.consentUrl)
            } else if case .returningFromConsent(let link) = controller.state {
                BankConsentSafariView(url: link.consentUrl)
            }
        }
#endif
        .onAppear {
            if gatewayReady { controller.restorePendingConsent() }
        }
        .onChange(of: gatewayPreflight) { _, _ in
            if gatewayReady {
                controller.restorePendingConsent()
            } else {
                controller.reset()
            }
        }
        .onChange(of: controller.state) { previous, current in
            guard previous != current, case .linked = current, let onLinked else { return }
            Task { await onLinked() }
        }
    }

    private var isBusy: Bool {
        switch controller.state {
        case .openingConsent, .returningFromConsent, .checkingStatus: true
        default: false
        }
    }

    private var gatewayReady: Bool { gatewayPreflight == .reachable }

    private var canTap: Bool {
        guard gatewayReady, !isBusy else { return false }
        switch controller.state {
        case .linked, .gatewayNotConfigured: return false
        default: return true
        }
    }

    private var buttonLabel: String {
        guard let gatewayPreflight else { return "Check gateway first" }
        guard gatewayPreflight == .reachable else { return "Gateway unavailable" }
        switch controller.state {
        case .idle, .expired: return "Connect"
        case .openingConsent: return "Opening consent…"
        case .awaitingConsent: return "Continue consent"
        case .returningFromConsent: return "Verifying callback…"
        case .checkingStatus: return "Checking status…"
        case .linked: return "Linked"
        case .alreadyLinking(let link), .error(let link):
            return link == nil ? "Retry connection" : "Re-check status"
        case .gatewayNotConfigured: return "Gateway required"
        }
    }

    private var statusIcon: LifeOSIconName {
        switch controller.state {
        case .linked: .verified
        case .error(_), .expired, .alreadyLinking(_), .gatewayNotConfigured: .warning
        default: .security
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .linked: LifeOSTokens.success
        case .error(_), .expired, .alreadyLinking(_), .gatewayNotConfigured: LifeOSTokens.warning
        default: LifeOSTokens.tertiaryText
        }
    }

    private var statusDetail: String {
        guard let gatewayPreflight else {
            return "Run the read-only gateway preflight before opening a consent page."
        }
        guard gatewayPreflight == .reachable else {
            return "\(gatewayPreflight.settingsTitle). \(gatewayPreflight.settingsDetail)"
        }
        switch controller.state {
        case .idle:
            return "No consent requested yet. Tap Connect to open \(descriptor.displayName)'s hosted consent page."
        case .openingConsent:
            return "Requesting a one-time consent link from the gateway."
        case .awaitingConsent:
            return "Waiting on the bank's consent page. Re-check status once you finish or return to the app."
        case .returningFromConsent:
            return "The bank page closed. The gateway callback is still being verified; no link is assumed."
        case .checkingStatus:
            return "Checking the connection state with the gateway."
        case .linked:
            return "The gateway reports this connection as linked. Refresh is read-only; revoke remains gateway-owned."
        case .expired:
            return "The consent link expired before it was completed. Tap Connect to request a new one."
        case .alreadyLinking(let link):
            if link != nil {
                return "A connection is already in progress. The pending session is retained; re-check status or reopen consent after the gateway allows it."
            }
            return "A connection is already in progress for this connector. Retry once the gateway can expose its status."
        case .gatewayNotConfigured:
            return "The gateway has no Enable Banking configuration. Nothing was linked."
        case .error(let link):
            if link != nil {
                return "The status check failed temporarily. The pending session is retained; re-check status instead of starting over."
            }
            return "The gateway rejected the request. Nothing was linked; retry the connection when the gateway is ready."
        }
    }
}

private struct FinanceConnectionsSettingsView: View {
    let snapshot: FinanceSettingsSnapshot
    let refreshAction: (() async -> Void)?
    let usesVisualFixtures: Bool
    private let catalog = FinanceConnectorCatalog.defaults
    private let syncClient = TailscaleSyncClient()
    @State private var gatewayPreflight: TailscaleConnectionPreflightState?
    @State private var isCheckingGateway = false
    @State private var gatewayPreflightTask: Task<Void, Never>?

    init(
        snapshot: FinanceSettingsSnapshot = .unavailable,
        refreshAction: (() async -> Void)? = nil,
        usesVisualFixtures: Bool = false
    ) {
        self.snapshot = snapshot
        self.refreshAction = refreshAction
        self.usesVisualFixtures = usesVisualFixtures
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
                                statusColor: summaryColor,
                                iconColor: Color.lifeOSFinanceGreen,
                                iconAccessibilityLabel: "Finance summary"
                            )
                            Divider().padding(.leading, 38)
                            SettingsStatusRow(
                                title: "Transaction observations",
                                detail: snapshot.transactionDetail,
                                status: snapshot.transactionTitle,
                                icon: .documents,
                                statusColor: snapshot.transactionsAvailability == .observed
                                    ? LifeOSTokens.success
                                    : LifeOSTokens.warning,
                                iconColor: LifeOSTokens.info,
                                iconAccessibilityLabel: "Transaction observations"
                            )
                    }
                }

                SettingsSection(title: "Gateway preflight", icon: .security) {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsStatusRow(
                            title: "Read-only secure gateway check",
                            detail: gatewayPreflightDetail,
                            status: gatewayPreflightTitle,
                            icon: gatewayPreflight == .reachable ? .verified : .security,
                            statusColor: gatewayPreflight == .reachable ? LifeOSTokens.success : LifeOSTokens.warning,
                            iconColor: gatewayPreflight == .reachable ? LifeOSTokens.success : LifeOSTokens.warning,
                            iconAccessibilityLabel: "Secure gateway preflight"
                        )

                        Button {
                            runGatewayPreflight()
                        } label: {
                            HStack(spacing: 7) {
                                if isCheckingGateway {
                                    ProgressView().controlSize(.small)
                                } else {
                                    LifeOSIcon(.refresh).frame(width: 14, height: 14)
                                }
                                Text(isCheckingGateway ? "Checking secure gateway…" : "Re-check secure gateway")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(LifeOSTokens.accent)
                        .disabled(isCheckingGateway || usesVisualFixtures)
                        .accessibilityIdentifier("settings-finance-gateway-preflight")
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
                            VStack(spacing: 0) {
                                SettingsStatusRow(
                                        title: descriptor.displayName,
                                    detail: "\(accessMethodTitle(descriptor.accessMethod)) · \(descriptor.recommendation)",
                                    status: gateTitle(descriptor.risk),
                                    icon: connectorIcon(descriptor.kind),
                                    statusColor: connectorRiskColor(descriptor.risk),
                                    iconColor: connectorColor(descriptor.kind),
                                    iconAccessibilityLabel: "\(descriptor.displayName) connection"
                                )
                                if supportsInAppConsent(descriptor.accessMethod) {
                                    BankConsentConnectRow(
                                        descriptor: descriptor,
                                        syncClient: syncClient,
                                        gatewayPreflight: gatewayPreflight,
                                        onLinked: refreshAction
                                    )
                                }
                            }
                            if descriptor.id != catalog.last?.id {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }

                SettingsDiagnosticsView(
                    diagnostics: SettingsRedactedDiagnostics(
                        gateway: gatewayPreflight,
                        finance: snapshot.readiness
                    )
                )

                NavigationLink {
                    SyncStorageSettingsView()
                } label: {
                    HStack(spacing: 8) {
                        LifeOSIcon(.security).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open secure Sync setup")
                                .font(LifeOSFont.inter(13, weight: .semiBold))
                            Text("Review the signed host, URL validation, and Tailscale device-identity gateway.")
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
        .task {
            guard SettingsFixturePolicy.shouldRunFinanceGatewayPreflight(usesVisualFixtures: usesVisualFixtures) else { return }
            runGatewayPreflight()
        }
        .onDisappear {
            gatewayPreflightTask?.cancel()
            gatewayPreflightTask = nil
            isCheckingGateway = false
        }
    }

    private func runGatewayPreflight() {
        guard SettingsFixturePolicy.shouldRunFinanceGatewayPreflight(usesVisualFixtures: usesVisualFixtures),
              !isCheckingGateway else { return }
        gatewayPreflightTask?.cancel()
        isCheckingGateway = true
        gatewayPreflight = nil
        gatewayPreflightTask = Task { @MainActor in
            let result = await syncClient.checkConnection()
            guard !Task.isCancelled else { return }
            gatewayPreflight = result
            isCheckingGateway = false
        }
    }

    private var gatewayPreflightTitle: String {
        if usesVisualFixtures { return "Disabled in fixture mode" }
        if isCheckingGateway { return "Checking" }
        guard let gatewayPreflight else { return "Not checked" }
        return gatewayPreflight.settingsTitle
    }

    private var gatewayPreflightDetail: String {
        if usesVisualFixtures {
            return "Visual fixture mode keeps the gateway preflight offline; no network request is made on navigation or by this control."
        }
        if isCheckingGateway {
            return "One bounded read-only request is in flight; no finance or bank connection is changed."
        }
        guard let gatewayPreflight else {
            return "Run the read-only preflight before opening a bank consent page."
        }
        return gatewayPreflight.settingsDetail
    }

    /// The current gateway-mediated consent flow is Enable Banking only.
    /// Official OAuth connectors need their own reviewed server adapter; they
    /// never get routed through the bank-consent endpoint by accident.
    private func supportsInAppConsent(_ method: FinanceAccessMethod) -> Bool {
        method.usesEnableBankingConsent
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
        case .consentRequired: "Consent-based connector"
        case .accountEligibilityRequired: "Eligibility + OAuth required"
        case .manualImportOnly: "Manual import only"
        }
    }

    private func connectorIcon(_ kind: FinanceConnectorKind) -> LifeOSIconName {
        switch kind {
        case .sparkasse: .bankConnections
        case .revolutPersonal: .finance
        case .revolutBusiness: .business
        case .tradeRepublic: .investments
        case .paypalPersonal: .cashFlow
        }
    }

    /// Identity color differentiates connectors; the adjacent status dot and
    /// status text remain reserved for connection/risk state.
    private func connectorColor(_ kind: FinanceConnectorKind) -> Color {
        switch kind {
        case .sparkasse: .lifeOSFinanceGreen
        case .revolutPersonal: .lifeOSTeal500
        case .revolutBusiness: LifeOSTokens.Module.business
        case .tradeRepublic: .lifeOSPurple500
        case .paypalPersonal: .lifeOSBlue500
        }
    }

    private func connectorRiskColor(_ risk: FinanceConnectorRisk) -> Color {
        switch risk {
        case .consentRequired: LifeOSTokens.warning
        case .accountEligibilityRequired: LifeOSTokens.info
        case .manualImportOnly: LifeOSTokens.secondaryText
        }
    }
}

private struct HealthDevicesSettingsView: View {
    private let snapshot = HelioDeviceSettingsSnapshot.current
    let healthReadAccess: HealthReadAccessSettings
    let requestHealthReadAccess: (@MainActor () async -> Void)?
    let requestHealthWriteAccess: (@MainActor () async -> Void)?
    let retainedHealthData: RetainedHealthDataSettings
    let healthWriteAccess: HealthWriteAccessSettings
#if os(iOS)
    @State private var isWriteAuthorizationConfirmationPresented = false
#endif
#if os(iOS)
    @ObservedObject private var healthKitController: HealthKitIntegrationController
    @ObservedObject private var healthKitFitnessRepository: HealthKitFitnessRepository
#endif

 #if os(iOS)
    init(
        healthReadAccess: HealthReadAccessSettings,
        requestHealthReadAccess: (@MainActor () async -> Void)?,
        requestHealthWriteAccess: (@MainActor () async -> Void)?,
        retainedHealthData: RetainedHealthDataSettings,
        healthWriteAccess: HealthWriteAccessSettings,
        healthKitController: HealthKitIntegrationController,
        healthKitFitnessRepository: HealthKitFitnessRepository
    ) {
        self.healthReadAccess = healthReadAccess
        self.requestHealthReadAccess = requestHealthReadAccess
        self.requestHealthWriteAccess = requestHealthWriteAccess
        self.retainedHealthData = retainedHealthData
        self.healthWriteAccess = healthWriteAccess
        _healthKitController = ObservedObject(wrappedValue: healthKitController)
        _healthKitFitnessRepository = ObservedObject(wrappedValue: healthKitFitnessRepository)
    }
#else
    init(
        healthReadAccess: HealthReadAccessSettings,
        requestHealthReadAccess: (@MainActor () async -> Void)?,
        requestHealthWriteAccess: (@MainActor () async -> Void)?,
        retainedHealthData: RetainedHealthDataSettings,
        healthWriteAccess: HealthWriteAccessSettings
    ) {
        self.healthReadAccess = healthReadAccess
        self.requestHealthReadAccess = requestHealthReadAccess
        self.requestHealthWriteAccess = requestHealthWriteAccess
        self.retainedHealthData = retainedHealthData
        self.healthWriteAccess = healthWriteAccess
    }
#endif

#if os(iOS)
    private var resolvedHealthReadAccess: HealthReadAccessSettings {
        HealthReadAccessSettings.from(snapshot: healthKitController.snapshot)
    }

    private var resolvedHealthWriteAccess: HealthWriteAccessSettings {
        HealthWriteAccessSettings.from(snapshot: healthKitController.snapshot)
    }

    private var resolvedRetainedHealthData: RetainedHealthDataSettings {
        guard let projection = healthKitFitnessRepository.projection else { return .unavailable }
        return .from(projection: projection)
    }
#else
    private var resolvedHealthReadAccess: HealthReadAccessSettings { healthReadAccess }
    private var resolvedHealthWriteAccess: HealthWriteAccessSettings { healthWriteAccess }
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
#if os(iOS)
                        if let requestHealthWriteAccess {
                            Divider().padding(.leading, 38)
                            SettingsStatusRow(
                                title: "Apple Health write access",
                                detail: resolvedHealthWriteAccess.detail,
                                status: resolvedHealthWriteAccess.title,
                                icon: .security,
                                statusColor: healthWriteAccessStatusColor
                            )
                            .accessibilityIdentifier("settings-health-write-status")

                            Button {
                                isWriteAuthorizationConfirmationPresented = true
                            } label: {
                                HStack(spacing: 8) {
                                    if resolvedHealthWriteAccess.state == .requestPending {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(resolvedHealthWriteAccess.buttonTitle)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(LifeOSTokens.accent)
                            .disabled(!resolvedHealthWriteAccess.allowsRequest)
                            .accessibilityIdentifier("settings-health-request-write-access")
                            .accessibilityHint("Opens a confirmation before the Apple Health sharing permission sheet")
                            .confirmationDialog(
                                "Allow LifeOS to write selected Health values?",
                                isPresented: $isWriteAuthorizationConfirmationPresented,
                                titleVisibility: .visible
                            ) {
                                Button("Continue to Apple Health") {
                                    Task { @MainActor in await requestHealthWriteAccess() }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("LifeOS will request sharing access only for explicit manual values. It will not write a sample as part of this permission request.")
                            }
                            .padding(.vertical, 10)
                        }
#endif
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

                TruthfulSetupNote(text: "HealthKit reads and separately confirmed writes are iPhone-only. Writes are limited to explicit manual values and every save is rechecked. Battery, firmware, pairing, reboot, configuration, private BLE control, and a verified Zepp launch route remain unavailable or Zepp-only until a supported interface is proven. Demo fixtures remain separate from observed device data.")
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

    private var healthWriteAccessStatusColor: Color {
        switch resolvedHealthWriteAccess.state {
        case .authorized:
            LifeOSTokens.info
        case .denied, .restricted, .error:
            LifeOSTokens.danger
        case .notRequested, .requestPending, .protectedDataUnavailable, .unavailable:
            LifeOSTokens.warning
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
    @AppStorage(TailscaleSyncClient.serverURLDefaultsKey)
    private var syncServerURL = TailscaleSyncClient.configuredDefaultServerURL()
    @AppStorage("LifeOS.Sync.LastSuccess") private var lastSyncTimestamp: Double = 0
    @State private var connectionPreflight: TailscaleConnectionPreflightState?
    @State private var isCheckingConnection = false
    @State private var connectionPreflightTask: Task<Void, Never>?
    @State private var connectionPreflightGeneration = 0

    private var localReadiness: SyncSettingsReadiness {
        SyncSettingsReadiness.resolve(
            serverURL: syncServerURL,
            approvedHosts: TailscaleSyncClient.configuredApprovedHosts()
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Sync & storage",
                    message: "The loopback-only Windows gateway is configured to require Tailscale device identity through Tailscale Serve. The current session is shown below only after a read-only preflight. LifeOS sends no bearer or token."
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
                        Text("Tailscale Serve supplies the device identity to the loopback-only gateway. LifeOS never stores or edits a bearer or token.")
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

                        Text("This sends one read-only request to the approved Windows gateway. The loopback-only gateway verifies Tailscale device identity; LifeOS sends no bearer or Tailscale identity headers.")
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
                            detail: "The URL must be HTTPS on an approved .ts.net host, use port 443 or 8420, and have no path, query, or fragment data.",
                            status: localReadiness.urlState.title,
                            icon: .documents,
                            statusColor: localReadiness.urlState == .valid ? LifeOSTokens.success : LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Tailscale device identity",
                            detail: SyncGatewayRuntimePresentation.identityStatusDetail(for: connectionPreflight),
                            status: SyncGatewayRuntimePresentation.identityStatusTitle(for: connectionPreflight),
                            icon: .security,
                            statusColor: SyncGatewayRuntimePresentation.identityIsVerified(for: connectionPreflight)
                                ? LifeOSTokens.success
                                : LifeOSTokens.warning
                        )
                    }
                }

                SettingsSection(title: "Trust state", icon: .refresh) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Windows server",
                            detail: "Authoritative store behind the loopback-only gateway; secure deployment gate is still pending",
                            status: "Pending",
                            icon: .security,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Device identity",
                            detail: SyncGatewayRuntimePresentation.identityStatusDetail(for: connectionPreflight),
                            status: SyncGatewayRuntimePresentation.identityStatusTitle(for: connectionPreflight),
                            icon: .security,
                            statusColor: SyncGatewayRuntimePresentation.identityIsVerified(for: connectionPreflight)
                                ? LifeOSTokens.success
                                : LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Local records",
                            detail: "Remain local until a Tailscale-identity-verified sync path succeeds",
                            status: "Local first",
                            icon: .documents,
                            statusColor: LifeOSTokens.success
                        )
                    }
                }

                SettingsSection(title: "Local storage", icon: .documents) {
                    Text("Calendar, tax documents, and app preferences remain on this device unless an explicitly configured, Tailscale-identity-verified sync path is available.")
                        .font(LifeOSFont.inter(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsDiagnosticsView(
                    diagnostics: SettingsRedactedDiagnostics(gateway: connectionPreflight)
                )
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Sync & Storage")
        .onAppear {
            let fallback = TailscaleSyncClient.configuredDefaultServerURL()
            if syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !fallback.isEmpty {
                syncServerURL = fallback
            }
        }
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
        case .authenticationRejected: "Tailscale device identity rejected"
        case .serverUnavailable: "Windows gateway unavailable"
        case .networkUnavailable: "Tailscale network unavailable"
        case .invalidResponse: "Gateway response rejected"
        }
    }

    private func connectionPreflightDetail(_ state: TailscaleConnectionPreflightState) -> String {
        switch state {
        case .reachable:
            "The approved gateway accepted the read-only request with Tailscale device identity. This does not prove that every provider is connected."
        case .configurationRequired:
            "The signed approved-host configuration or HTTPS server URL is missing or invalid."
        case .authenticationRejected:
            "The gateway is reachable, but it rejected this device's Tailscale identity. No credential was changed."
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
                    Text("Calendar items and local-first nutrition records stay on this device until an explicitly configured, Tailscale-identity-verified sync path succeeds. Finance, Fitness, and Usage remain unavailable when their reviewed sources are not connected.")
                        .font(LifeOSFont.inter(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsDiagnosticsView(
                    diagnostics: SettingsRedactedDiagnostics(
                        appGroup: appGroup.state,
                        signing: signing
                    )
                )

                SettingsSection(title: "Signing", icon: signingIcon) {
                    SettingsStatusRow(
                        title: "Code signing",
                        detail: "\(signing.modeTitle) · \(signing.guidance)",
                        status: signing.stateTitle,
                        icon: signingIcon,
                        statusColor: signingColor
                    )
                    Text("Automatic self-signing is unavailable by Apple platform design. \(signing.evidenceBoundary)")
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
                .font(LifeOSFont.title())
                .tracking(-0.2)
            Text(message)
                .font(LifeOSFont.bodyText())
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
    let iconColor: Color
    let iconAccessibilityLabel: String?

    init(
        title: String,
        detail: String,
        status: String,
        icon: LifeOSIconName,
        statusColor: Color,
        iconColor: Color = LifeOSTokens.tertiaryText,
        iconAccessibilityLabel: String? = nil
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        self.icon = icon
        self.statusColor = statusColor
        self.iconColor = iconColor
        self.iconAccessibilityLabel = iconAccessibilityLabel
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                LifeOSIcon(icon)
                    .foregroundStyle(iconColor)
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LifeOSFont.inter(14, weight: .semiBold))
                Text(detail)
                    .font(LifeOSFont.inter(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            // §4.2: semantic dot + axis text instead of colored text alone.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(status)
                    .font(LifeOSFont.axis())
                    .tracking(0.2)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-status-\(accessibilityID)")
        .accessibilityLabel(Text("\(title) · \(status)\(iconAccessibilityLabel.map { " · \($0)" } ?? "")"))
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

private struct SettingsDiagnosticsView: View {
    let diagnostics: SettingsRedactedDiagnostics
    @State private var didCopy = false

    var body: some View {
        SettingsSection(title: "Safe diagnostics", icon: .documents) {
            VStack(alignment: .leading, spacing: 10) {
                Text(diagnostics.summary)
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-redacted-diagnostics-summary")

                Text("Only lifecycle states and failure classes are included. URLs, endpoints, account data, balances, provider payloads, credentials, tokens, and raw error text are excluded.")
                    .font(LifeOSFont.metadata())
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    copyDiagnostics()
                } label: {
                    HStack(spacing: 7) {
                        LifeOSIcon(didCopy ? .verified : .documents)
                            .frame(width: 14, height: 14)
                        Text(didCopy ? "Copied redacted summary" : "Copy redacted diagnostics")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(LifeOSTokens.accent)
                .accessibilityIdentifier("settings-copy-redacted-diagnostics")
                .accessibilityHint(Text("Copies only lifecycle states and safe failure classes; no secrets or provider data."))
            }
        }
    }

    private func copyDiagnostics() {
#if os(iOS)
        UIPasteboard.general.string = diagnostics.text
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.text, forType: .string)
#endif
        didCopy = true
    }
}

private struct TruthfulSetupNote: View {
    let text: String

    var body: some View {
        // §5.2: the warning is a 6pt dot on a flat card — no tinted fill,
        // hairline border only. Copy is product truth and stays verbatim.
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(LifeOSTokens.warning)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(LifeOSFont.metadata())
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: LifeOSIconName
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // §5.2: sections stop shouting — neutral icon + callout-weight title.
            HStack(spacing: 8) {
                LifeOSIcon(icon)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .frame(width: 18, height: 18)
                Text(title)
                    .foregroundStyle(LifeOSTokens.primaryText)
            }
            .font(LifeOSFont.callout().weight(.semibold))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .contain)
    }
}
