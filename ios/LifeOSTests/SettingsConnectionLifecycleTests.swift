import Foundation
import XCTest
@testable import LifeOS

/// ST-01 / ST-03 acceptance coverage.
///
/// ST-01 ("Settings OAuth/PKCE initiate/callback/pending/authorized/expiry/
/// failure/revoke/retry; no raw token") describes a flow that does not exist
/// in this codebase. LifeOS deliberately rejected a build-embedded bearer
/// design; connector authentication is Tailscale node/user identity, and the
/// only "OAuth" reference in the app is `FinanceAccessMethod.officialOAuth`,
/// an unimplemented classification for a future server-side connector (see
/// `Shared/FinanceDomain.swift`). There is no client-side authorization-code
/// exchange, PKCE verifier, callback handler, or token storage anywhere in
/// `Shared/` or `LifeOS/`. This file proves the property ST-01 actually cares
/// about -- that the *closest analogous lifecycle that does exist*
/// (`SettingsProviderLifecycle` / `SettingsFailureClass`, and separately the
/// gateway-mediated bank-consent lifecycle `BankConsentRowState` /
/// `BankConsentLifecyclePhase` covered in `BankConsentTests.swift`) never
/// fabricates a connected state, never leaks a raw credential-shaped string,
/// and keeps every reachable state distinct with bounded, non-spinning retry.
final class SettingsConnectionLifecycleTests: XCTestCase {

    // MARK: - ST-01: provider lifecycle is the only "auth" state machine in the app

    /// Load-bearing invariant: a lifecycle state is retryable in the UI if
    /// and only if its failure classification says the underlying error is
    /// retryable. If these ever disagree, the Settings retry button either
    /// offers to retry something that can never succeed (authorization/
    /// revoked) or silently withholds retry from something that could.
    func testSettingsProviderLifecycleCanRetryMatchesFailureClassRetryability() {
        for lifecycle in [
            SettingsProviderLifecycle.unavailable, .authorized, .refreshDue,
            .reauthRequired, .revoked, .rateLimited, .failed,
        ] {
            let expected = lifecycle.failureClass?.isRetryable ?? false
            XCTAssertEqual(lifecycle.canRetry, expected, "\(lifecycle) canRetry disagrees with its failureClass.isRetryable")
        }
    }

    func testSettingsProviderLifecycleStatesStayDistinctAndTitled() {
        let all: [SettingsProviderLifecycle] = [.unavailable, .authorized, .refreshDue, .reauthRequired, .revoked, .rateLimited, .failed]
        let titles = all.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two provider lifecycle states collapsed to the same title: \(titles)")
        for state in all {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.retryTitle.isEmpty)
            XCTAssertFalse(state.recoveryDetail.isEmpty)
        }
        // Revoked and reauth-required must never present as retryable in the
        // UI even though they are error-shaped: retrying cannot fix them,
        // only an explicit reauthorization flow can.
        XCTAssertFalse(SettingsProviderLifecycle.revoked.canRetry)
        XCTAssertFalse(SettingsProviderLifecycle.reauthRequired.canRetry)
        // Authorized never claims a failure class or a retry affordance.
        XCTAssertNil(SettingsProviderLifecycle.authorized.failureClass)
        XCTAssertFalse(SettingsProviderLifecycle.authorized.canRetry)
    }

    func testSettingsFailureClassTableIsInternallyConsistent() {
        let all: [SettingsFailureClass] = [
            .configuration, .authentication, .authorization, .expired, .refreshRequired,
            .revoked, .rateLimited, .unavailable, .invalidResponse, .unknown,
        ]
        for failure in all {
            XCTAssertFalse(failure.title.isEmpty)
            XCTAssertFalse(failure.detail.isEmpty)
            if failure.isRetryable {
                XCTAssertEqual(failure.recoveryTitle, "Retry", "\(failure) is retryable but doesn't say Retry")
            } else {
                XCTAssertEqual(failure.recoveryTitle, "Review setup", "\(failure) is not retryable but doesn't say Review setup")
            }
        }
        // configuration/authorization/expired/revoked require setup review,
        // not a spin loop -- this is what keeps retry bounded for the
        // states that a bare retry can never resolve.
        for terminal in [SettingsFailureClass.configuration, .authorization, .expired, .revoked] {
            XCTAssertFalse(terminal.isRetryable, "\(terminal) must not be blindly retryable")
        }
    }

    /// Exhaustive over every `TailscaleSyncError` case (the switch below is
    /// non-optional, so a newly added case fails to compile until classified
    /// here -- this is the regression guard against a future OAuth-shaped
    /// error case slipping in unclassified).
    func testSettingsFailureClassifyMapsEveryTailscaleSyncErrorCase() {
        func expected(_ error: TailscaleSyncError) -> SettingsFailureClass {
            switch error {
            case .notConfigured, .invalidServerURL, .gatewayNotConfigured: return .configuration
            case .httpError(401), .httpError(403): return .authentication
            case .httpError(429): return .rateLimited
            case .httpError(408): return .unavailable
            case .httpError(500), .httpError(503): return .unavailable
            case .connectionAlreadyLinking: return .authorization
            case .invalidInstitutionId, .invalidConnectionId, .invalidConsentURL,
                 .invalidBarcode, .invalidResponse, .responseTooLarge, .requestTooLarge:
                return .invalidResponse
            case .httpError: return .unknown
            }
        }
        let sample: [TailscaleSyncError] = [
            .notConfigured, .invalidServerURL, .gatewayNotConfigured,
            .httpError(401), .httpError(403), .httpError(429), .httpError(408),
            .httpError(500), .httpError(503), .httpError(418), .httpError(200),
            .connectionAlreadyLinking,
            .invalidInstitutionId, .invalidConnectionId, .invalidConsentURL,
            .invalidBarcode, .invalidResponse, .responseTooLarge, .requestTooLarge,
        ]
        for error in sample {
            XCTAssertEqual(SettingsFailureClass.classify(error), expected(error), "\(error)")
        }
        XCTAssertEqual(SettingsFailureClass.classify(nil), .unknown)
    }

    /// Coordinator-supplied failure strings are untrusted. This fuzzes a
    /// spread of credential-shaped inputs and proves the classifier only
    /// ever hands back one of the ten known classes -- never an echo of the
    /// input, which is how a raw token/URL could otherwise leak into a
    /// rendered Settings row or a diagnostics export.
    func testUntrustedFailureMessageClassificationNeverEchoesRawInput() {
        let adversarial: [(String, SettingsFailureClass)] = [
            ("HTTP 401 Bearer eyJhbGciOiJIUzI1NiJ9.secret.sig", .authentication),
            ("oauth reauthorization required for token abc123", .authorization),
            // "consent" is checked before "revok" by the classifier's
            // priority order, so this string classifies as authorization,
            // not revoked -- exercising that documented precedence.
            ("consent revoked by bank for connection eb-9f21", .authorization),
            ("rate limit exceeded, retry-after=30, key=sk-live-xyz", .rateLimited),
            ("session expired at 2026-09-06T12:00:00Z", .expired),
            ("gateway not configured: missing LIFEOS_SYNC_APPROVED_HOSTS", .configuration),
            ("network timeout contacting 100.64.1.2:8420", .unavailable),
            ("failed to decode response body: unexpected token", .invalidResponse),
            ("", .unknown),
            ("   ", .unknown),
        ]
        for (raw, expectedClass) in adversarial {
            let failure = SettingsFailureClass.classify(untrustedMessage: raw)
            XCTAssertEqual(failure, expectedClass, raw)
            // The only text a caller can retain is `.detail`; it must never
            // contain fragments of the untrusted source string.
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                XCTAssertFalse(failure.detail.contains("eyJ"), raw)
                XCTAssertFalse(failure.detail.contains("sk-live"), raw)
                XCTAssertFalse(failure.detail.contains("100.64"), raw)
                XCTAssertFalse(failure.detail.contains("eb-9f21"), raw)
            }
        }
    }

    /// Defect hunt: a provider whose connector has been revoked or is
    /// reauth-required must never resolve to `.observed`/`.authorized`, even
    /// when a prior snapshot was legitimately observed. This is exactly the
    /// "no state fabricates a connected-looking result" property ST-01 asks
    /// for, applied to the real lifecycle that stands in for OAuth here.
    func testProviderConnectionSettingsNeverPromotesRevokedOrReauthConnectorToObserved() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provenance = Provenance(source: "provider-observation", observedAt: now, quality: .observed, connector: .healthy)
        let window = UsageWindow(id: "w1", label: "5h", limit: 100, used: 10, provenance:
            Provenance(source: "provider-observation", observedAt: now, quality: .observed, connector: .healthy))
        let snapshot = ProviderSnapshot(provider: .codex, accountLabel: "SECRET-ACCOUNT-LABEL", windows: [window], provenance: provenance)

        for badConnector: ConnectorState in [.revoked, .reauthRequired, .rateLimited, .error] {
            let resolved = ProviderConnectionSettings.resolve(
                provider: .codex, snapshot: snapshot, connector: badConnector, now: now, staleAfter: 900
            )
            XCTAssertEqual(resolved.state, .stale, "\(badConnector) must resolve to stale, never observed")
            XCTAssertNotEqual(resolved.state, .observed)
        }
        // A genuinely healthy, fully-observed, fresh snapshot is the only
        // path to `.observed`.
        let healthy = ProviderConnectionSettings.resolve(
            provider: .codex, snapshot: snapshot, connector: .healthy, now: now, staleAfter: 900
        )
        XCTAssertEqual(healthy.state, .observed)
        // The account label is real user-facing data (rendered elsewhere in
        // Settings), but it must never appear in the redacted diagnostics
        // surface -- proven separately below.
        XCTAssertEqual(healthy.source, "Windows Hermes · Codex observation")
    }

    // MARK: - ST-03: gateway/bank-consent lifecycle stays distinct and honest

    func testBankConsentLifecyclePhaseTitlesStayDistinct() {
        let all: [BankConsentLifecyclePhase] = [
            .idle, .opening, .awaitingConsent, .returningFromConsent, .checking,
            .linked, .expired, .revoked, .alreadyLinking, .gatewayNotConfigured, .failed,
        ]
        let titles = all.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two bank-consent phases collapsed to the same title: \(titles)")
    }

    /// Load-bearing table: only phases that represent an in-flight network
    /// round trip (opening/checking) or a genuinely finished success
    /// (linked) must refuse retry. Everything else -- including terminal
    /// failures like revoked/expired -- must remain retryable so the user
    /// is never stuck, but retry is always a fresh, user-initiated tap, never
    /// an automatic loop.
    func testBankConsentLifecyclePhaseCanRetryTableIsExhaustive() {
        let nonRetryable: Set<BankConsentLifecyclePhase> = [.opening, .checking, .linked]
        for phase: BankConsentLifecyclePhase in [
            .idle, .opening, .awaitingConsent, .returningFromConsent, .checking,
            .linked, .expired, .revoked, .alreadyLinking, .gatewayNotConfigured, .failed,
        ] {
            XCTAssertEqual(phase.canRetry, !nonRetryable.contains(phase), "\(phase)")
        }
    }

    /// Defect hunt: recovering from a transport-layer error must never
    /// synthesize a success-shaped state (`.linked`) or an unrelated
    /// terminal state (`.expired`, `.revoked`) that the gateway did not
    /// actually report. Only the gateway's authoritative status poll
    /// (`fromGatewayState`) may produce those.
    func testBankConsentRecoveredStateNeverFabricatesLinkedOrExpiredOrRevoked() {
        let link = BankConsentLink(consentUrl: URL(string: "https://bank.example.com/consent?session=opaque")!, connectionId: "eb-1")
        let allErrors: [TailscaleSyncError] = [
            .notConfigured, .invalidServerURL, .invalidBarcode, .invalidResponse,
            .httpError(400), .httpError(401), .httpError(429), .httpError(500),
            .responseTooLarge, .requestTooLarge, .invalidInstitutionId,
            .invalidConnectionId, .invalidConsentURL, .connectionAlreadyLinking,
            .gatewayNotConfigured,
        ]
        for error in allErrors {
            let recovered = BankConsentRowState.recoveredState(for: error, preserving: link)
            switch recovered {
            case .linked, .expired, .revoked:
                XCTFail("\(error) must not recover into \(recovered)")
            default:
                break
            }
            // connectionAlreadyLinking and gatewayNotConfigured are the only
            // two errors with a dedicated recovery state; everything else is
            // generic `.error` and preserves the opaque link for re-check.
            switch error {
            case .connectionAlreadyLinking:
                XCTAssertEqual(recovered, .alreadyLinking(link))
            case .gatewayNotConfigured:
                XCTAssertEqual(recovered, .gatewayNotConfigured)
            default:
                XCTAssertEqual(recovered, .error(link))
            }
        }
    }

    func testTailscaleConnectionPreflightSettingsRetryableExcludesOnlyConfigurationRequired() {
        for state: TailscaleConnectionPreflightState in [
            .reachable, .configurationRequired, .authenticationRejected,
            .serverUnavailable, .networkUnavailable, .invalidResponse,
        ] {
            XCTAssertEqual(state.settingsIsRetryable, state != .configurationRequired, "\(state)")
        }
    }

    // MARK: - No raw secret escapes into the redacted diagnostics surface

    /// Builds a diagnostics report from every branch (gateway, providers,
    /// finance, health, appGroup, signing, failure) simultaneously and
    /// proves the emitted text is built entirely from enum `.rawValue`s and
    /// fixed copy -- never from a provider account label, snapshot source
    /// string, endpoint, or credential.
    func testSettingsRedactedDiagnosticsFullReportNeverLeaksProviderOrEndpointData() {
        let report = SettingsRedactedDiagnostics(
            gateway: .serverUnavailable,
            providers: [.authorized, .reauthRequired, .revoked, .rateLimited, .refreshDue, .failed, .unavailable],
            finance: .stale,
            health: .requestRequired,
            appGroup: .placeholder,
            signing: SigningStatus(mode: .unknown, expirationDate: nil),
            failure: .rateLimited
        )
        let leakMarkers = [
            "SECRET-ACCOUNT-LABEL", "https://", "Bearer ", "eyJ", "sk-", "100.64",
            "eb-9f21", "@", "Windows Hermes", "consent",
        ]
        for marker in leakMarkers {
            XCTAssertFalse(report.text.contains(marker), "diagnostics leaked marker: \(marker)\n\(report.text)")
        }
        XCTAssertTrue(report.text.contains("No endpoints, URLs, account identifiers"))
        XCTAssertTrue(report.text.contains("gateway=server_unavailable"))
        XCTAssertTrue(report.text.contains("failure=rateLimited"))
        // Provider counts are aggregated by class, never by individual
        // provider identity or account.
        XCTAssertTrue(report.text.contains("authorized:1"))
        XCTAssertTrue(report.text.contains("revoked:1"))
    }

    func testSettingsRedactedDiagnosticsEmptyReportIsExplicitNotSilent() {
        let empty = SettingsRedactedDiagnostics()
        XCTAssertTrue(empty.summary.contains("scope=not_checked"))
        XCTAssertTrue(empty.text.contains("scope=not_checked"))
    }

    func testSettingsLayoutRemainsReadableAtNarrowWidths() {
        XCTAssertEqual(SettingsLayout.maxContentWidth, 640)
        XCTAssertEqual(SettingsLayout.detailMaxWidth, 640)
        XCTAssertEqual(SettingsLayout.rowMinimumHeight, 56)
        XCTAssertEqual(SettingsLayout.rowInset, 12)
        XCTAssertEqual(SettingsLayout.contentWidth(for: 359), 359)
        XCTAssertEqual(SettingsLayout.contentWidth(for: 480), 480)
        XCTAssertEqual(SettingsLayout.contentWidth(for: 719), 640)
        XCTAssertEqual(SettingsLayout.contentWidth(for: 960), 640)
    }
}
