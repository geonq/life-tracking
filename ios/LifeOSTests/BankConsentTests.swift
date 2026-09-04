import Foundation
import XCTest
@testable import LifeOS

/// Contract tests for bank-consent initiation. These exercise the same
/// I/O-free parse/validate boundary proven by `TailscaleSyncClientSecurityTests`:
/// no live network, no credential, just the response-shape and validation
/// guarantees that must hold before a consent URL is ever opened or a
/// connection id is ever sent back to the gateway.
final class BankConsentTests: XCTestCase {
    private let url = URL(string: "https://lifeos.example-tailnet.ts.net/finance/connect")!

    private func response(status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - institutionId validation (request body)

    func testInstitutionIdValidationFailsClosedOnEmptyOversizedOrControlCharacters() {
        XCTAssertEqual(TailscaleSyncClient.validatedInstitutionId("sparkasse_leipzig"), "sparkasse_leipzig")
        XCTAssertEqual(TailscaleSyncClient.validatedInstitutionId("revolut_personal"), "revolut_personal")
        for value in ["", " ", "bad id", "bad\nid", "bad\tid", String(repeating: "x", count: 129)] {
            XCTAssertNil(TailscaleSyncClient.validatedInstitutionId(value), value)
        }
    }

    func testBankConsentRequestRejectsInvalidInstitutionIdBeforeBuildingRequest() {
        XCTAssertNil(TailscaleSyncClient.bankConsentRequest(url: url, institutionId: ""))
        XCTAssertNil(TailscaleSyncClient.bankConsentRequest(url: url, institutionId: "bad id"))
    }

    func testBankConsentRequestIsPOSTWithJSONBodyAndNoCredentialHeaders() throws {
        let request = try XCTUnwrap(TailscaleSyncClient.bankConsentRequest(url: url, institutionId: "sparkasse_leipzig"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Tailscale-User-Login"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["institutionId": "sparkasse_leipzig"])
    }

    // MARK: - connectionId validation (path component, not query string)

    func testConnectionIdValidationAcceptsSimpleTokensAndRejectsPathInjectionShapes() {
        XCTAssertEqual(TailscaleSyncClient.validatedConnectionId("req-abc123_XYZ"), "req-abc123_XYZ")
        for value in [
            "", " ", "req/../etc", "req/other", "req?x=1", "req#frag",
            "req id", "req\nid", "req\u{0}id", String(repeating: "a", count: 129),
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedConnectionId(value), value)
        }
    }

    // MARK: - consentUrl validation (fail closed before ever opening a browser)

    func testConsentURLValidationRequiresHTTPSAndNonEmptyHost() {
        XCTAssertNotNil(TailscaleSyncClient.validatedConsentURL("https://bank.example.com/consent/abc"))
        for value in [
            "",
            "http://bank.example.com/consent",
            "ftp://bank.example.com/consent",
            "https://",
            "https:///consent",
            "https://user:pass@bank.example.com/consent",
            "https://bank.example.com/consent#fragment",
            "javascript:alert(1)",
            " https://bank.example.com/consent",
            "https://bank.example.com/consent\n",
            "https://bank.example.com/\u{0}consent",
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedConsentURL(value), value)
        }
    }

    func testPendingConsentLinkStoreRoundTripsOnlyValidatedOpaqueLink() throws {
        let suite = "LifeOS.BankConsentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let link = BankConsentLink(
            consentUrl: try XCTUnwrap(URL(string: "https://bank.example.com/consent?session=opaque")),
            connectionId: "eb-opaque-123"
        )

        BankConsentPendingLinkStore.save(link, institutionId: "sparkasse_leipzig", defaults: defaults)

        XCTAssertEqual(
            BankConsentPendingLinkStore.load(institutionId: "sparkasse_leipzig", defaults: defaults),
            link
        )
        BankConsentPendingLinkStore.clear(institutionId: "sparkasse_leipzig", defaults: defaults)
        XCTAssertNil(BankConsentPendingLinkStore.load(institutionId: "sparkasse_leipzig", defaults: defaults))
    }

    func testPendingConsentLinkStoreRejectsMalformedPersistedValues() throws {
        let suite = "LifeOS.BankConsentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["consentUrl": "http://untrusted.example/consent#fragment", "connectionId": "../escape"],
            forKey: "LifeOS.Finance.PendingConsent.sparkasse_leipzig"
        )

        XCTAssertNil(BankConsentPendingLinkStore.load(institutionId: "sparkasse_leipzig", defaults: defaults))
    }

    // MARK: - consent-link response parsing

    func testParseBankConsentLinkResponseSucceedsOnValidShape() throws {
        let body = Data(#"{"consentUrl":"https://bank.example.com/consent/abc","connectionId":"req-1"}"#.utf8)
        let link = try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))
        XCTAssertEqual(link.consentUrl, URL(string: "https://bank.example.com/consent/abc"))
        XCTAssertEqual(link.connectionId, "req-1")
    }

    func testParseBankConsentLinkResponseRejectsNonHTTPSConsentURL() {
        let body = Data(#"{"consentUrl":"http://bank.example.com/consent/abc","connectionId":"req-1"}"#.utf8)
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .invalidConsentURL)
        }
    }

    func testParseBankConsentLinkResponseRejectsMissingHost() {
        let body = Data(#"{"consentUrl":"https:///consent/abc","connectionId":"req-1"}"#.utf8)
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .invalidConsentURL)
        }
    }

    func testParseBankConsentLinkResponseRejectsMalformedConnectionId() {
        let body = Data(#"{"consentUrl":"https://bank.example.com/consent/abc","connectionId":"bad id"}"#.utf8)
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .invalidConnectionId)
        }
    }

    func testParseBankConsentLinkResponseRejectsMissingFieldsOrUnparsableBody() {
        for body in [
            Data(#"{"consentUrl":"https://bank.example.com/consent/abc"}"#.utf8),
            Data(#"{"connectionId":"req-1"}"#.utf8),
            Data("not json".utf8),
            Data(),
        ] {
            XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))) { error in
                XCTAssertEqual(error as? TailscaleSyncError, .invalidResponse)
            }
        }
    }

    func testParseBankConsentLinkResponseMaps409ToAlreadyLinking() {
        let body = Data()
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 409))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .connectionAlreadyLinking)
        }
    }

    func testParseBankConsentLinkResponseMaps503ToGatewayNotConfigured() {
        let body = Data()
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 503))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .gatewayNotConfigured)
        }
    }

    func testParseBankConsentLinkResponseSurfacesOtherNonSuccessAsHTTPError() {
        let body = Data()
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 400))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .httpError(400))
        }
    }

    // MARK: - status-poll response parsing

    func testParseBankConsentStatusResponseDecodesEachKnownState() throws {
        for (raw, expected) in [
            ("created", BankConsentState.created),
            ("link_opened", BankConsentState.linkOpened),
            ("linked", BankConsentState.linked),
            ("expired", BankConsentState.expired),
            ("revoked", BankConsentState.revoked),
            ("error", BankConsentState.error),
        ] {
            let body = Data(#"{"state":"\#(raw)"}"#.utf8)
            let state = try TailscaleSyncClient.parseBankConsentStatusResponse(data: body)
            XCTAssertEqual(state, expected, raw)
        }
    }

    func testRevokedGatewayStateRemainsDistinctInSettingsLifecycle() throws {
        let link = BankConsentLink(
            consentUrl: URL(string: "https://bank.example.com/consent?session=opaque")!,
            connectionId: "eb-opaque-123"
        )

        let revoked = BankConsentRowState.fromGatewayState(.revoked, preserving: link)
        XCTAssertEqual(revoked, .revoked)
        XCTAssertEqual(revoked.lifecyclePhase, .revoked)
        XCTAssertEqual(revoked.lifecyclePhase.title, "Connection revoked")
        XCTAssertTrue(revoked.lifecyclePhase.canRetry)
        XCTAssertNotEqual(revoked.lifecyclePhase, .expired)
        XCTAssertNotEqual(revoked.lifecyclePhase, .failed)

        XCTAssertEqual(
            BankConsentRowState.fromGatewayState(.expired, preserving: link),
            .expired
        )
        XCTAssertEqual(
            BankConsentRowState.fromGatewayState(.error, preserving: link),
            .error(link)
        )
    }

    func testParseBankConsentStatusResponseRejectsUnknownStateOrMalformedBody() {
        for body in [
            Data(#"{"state":"unknown_state"}"#.utf8),
            Data(#"{"nope":"linked"}"#.utf8),
            Data("not json".utf8),
            Data(),
        ] {
            XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentStatusResponse(data: body)) { error in
                XCTAssertEqual(error as? TailscaleSyncError, .invalidResponse)
            }
        }
    }

    // MARK: - connection-preflight classification stays exhaustive and honest

    func testConnectionPreflightClassifiesNewBankConsentErrorsAsInvalidResponseNotReachable() {
        for error in [
            TailscaleSyncError.invalidInstitutionId,
            .invalidConnectionId,
            .invalidConsentURL,
            .connectionAlreadyLinking,
            .gatewayNotConfigured,
        ] {
            XCTAssertEqual(TailscaleSyncClient.connectionPreflightState(for: error), .invalidResponse)
        }
    }

    // MARK: - Settings lifecycle and diagnostics projections

    func testBankConsentLifecycleKeepsCallbackReturnSeparateFromLinked() {
        XCTAssertEqual(BankConsentLifecyclePhase.awaitingConsent.title, "Consent pending")
        XCTAssertEqual(BankConsentLifecyclePhase.returningFromConsent.title, "Returning from consent")
        XCTAssertNotEqual(
            BankConsentLifecyclePhase.returningFromConsent,
            BankConsentLifecyclePhase.linked
        )
        XCTAssertTrue(BankConsentLifecyclePhase.returningFromConsent.canRetry)
        XCTAssertFalse(BankConsentLifecyclePhase.checking.canRetry)
        XCTAssertFalse(BankConsentLifecyclePhase.linked.canRetry)
    }

    func testBankConsentRecoveryRetainsPendingLinkForTransientFailureAndAlreadyLinking() {
        let link = BankConsentLink(
            consentUrl: URL(string: "https://bank.example.com/consent?session=opaque")!,
            connectionId: "eb-opaque-123"
        )

        XCTAssertEqual(
            BankConsentRowState.recoveredState(for: .httpError(503), preserving: link),
            .error(link)
        )
        XCTAssertEqual(
            BankConsentRowState.recoveredState(for: .connectionAlreadyLinking, preserving: link),
            .alreadyLinking(link)
        )
        XCTAssertEqual(
            BankConsentRowState.recoveredState(for: .httpError(503)),
            .error(nil)
        )
    }

    func testVisualFixtureSettingsNeverSchedulesFinancePreflight() {
        XCTAssertFalse(SettingsFixturePolicy.shouldRunFinanceGatewayPreflight(usesVisualFixtures: true))
        XCTAssertTrue(SettingsFixturePolicy.shouldRunFinanceGatewayPreflight(usesVisualFixtures: false))
    }

    func testGatewayIdentityPresentationDoesNotClaimRuntimeEnforcementWithoutPreflight() {
        XCTAssertEqual(
            SyncGatewayRuntimePresentation.identityStatusTitle(for: nil),
            "Required by configuration"
        )
        XCTAssertEqual(
            SyncGatewayRuntimePresentation.identityStatusTitle(for: .reachable),
            "Verified for this session"
        )
        XCTAssertFalse(SyncGatewayRuntimePresentation.identityIsVerified(for: nil))
        XCTAssertTrue(SyncGatewayRuntimePresentation.identityIsVerified(for: .reachable))
        XCTAssertTrue(
            SyncGatewayRuntimePresentation.identityStatusDetail(for: nil)
                .contains("no current runtime preflight")
        )
    }

    func testProviderLifecyclePreservesAuthorizationAndFailureStates() {
        let observedProvenance = Provenance(
            source: "provider-observation",
            observedAt: Date.now,
            quality: .observed,
            connector: .healthy
        )
        let observed = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Codex",
            windows: [],
            provenance: observedProvenance
        )

        XCTAssertEqual(
            SettingsProviderLifecycle.resolve(snapshot: observed, connector: .healthy),
            .authorized
        )
        XCTAssertEqual(
            SettingsProviderLifecycle.resolve(snapshot: observed, connector: .refreshDue),
            .refreshDue
        )
        XCTAssertEqual(
            SettingsProviderLifecycle.resolve(snapshot: observed, connector: .reauthRequired),
            .reauthRequired
        )
        XCTAssertEqual(
            SettingsProviderLifecycle.resolve(snapshot: observed, connector: .revoked),
            .revoked
        )
        XCTAssertEqual(
            SettingsProviderLifecycle.resolve(snapshot: observed, connector: .rateLimited),
            .rateLimited
        )
        XCTAssertEqual(
            SettingsProviderLifecycle.resolve(snapshot: observed, connector: .error),
            .failed
        )
        XCTAssertEqual(
            SettingsProviderLifecycle.resolve(snapshot: nil, connector: nil),
            .unavailable
        )
    }

    func testPreflightPresentationIsExplicitAndNeverContainsRawEndpointData() {
        XCTAssertEqual(
            TailscaleConnectionPreflightState.authenticationRejected.settingsTitle,
            "Tailscale device identity rejected"
        )
        XCTAssertTrue(
            TailscaleConnectionPreflightState.authenticationRejected.settingsDetail.contains("No credential")
        )
        XCTAssertFalse(
            TailscaleConnectionPreflightState.authenticationRejected.settingsDetail.contains("https://")
        )

        let report = SettingsRedactedDiagnostics(
            gateway: .authenticationRejected,
            providers: [.reauthRequired, .revoked, .rateLimited],
            finance: .stale,
            health: .requestRequired,
            appGroup: .placeholder,
            signing: SigningStatus(mode: .unknown, expirationDate: nil),
            failure: .authentication
        )
        XCTAssertTrue(report.text.contains("gateway=authentication_rejected"))
        XCTAssertTrue(report.text.contains("failure=authentication"))
        XCTAssertTrue(report.text.contains("No endpoints"))
        for untrustedValue in [
            "https://untrusted.invalid",
            "credential=REDACTED",
            "account-label-from-response",
            "observed-value-from-response"
        ] {
            XCTAssertFalse(report.text.contains(untrustedValue), untrustedValue)
        }
    }

    func testUntrustedFailureTextCollapsesToSafeClassOnly() {
        let raw = "HTTP 401 https://untrusted.invalid/path?credential=REDACTED"
        let failure = SettingsFailureClass.classify(untrustedMessage: raw)
        XCTAssertEqual(failure, .authentication)
        XCTAssertFalse(failure.detail.contains("untrusted.invalid"))
        XCTAssertFalse(failure.detail.contains("REDACTED"))
    }
}
