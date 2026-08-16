import Foundation
import XCTest
@testable import LifeOS

/// Contract tests for bank-consent initiation. These exercise the same
/// I/O-free parse/validate boundary proven by `TailscaleSyncClientSecurityTests`:
/// no live network, no credential, just the response-shape and validation
/// guarantees that must hold before a consent URL is ever opened or a
/// requisition id is ever sent back to the gateway.
final class BankConsentTests: XCTestCase {
    private let url = URL(string: "https://lifeos.example-tailnet.ts.net/finance/connect")!

    private func response(status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - institutionId validation (request body)

    func testInstitutionIdValidationFailsClosedOnEmptyOversizedOrControlCharacters() {
        XCTAssertEqual(TailscaleSyncClient.validatedInstitutionId("sparkasse"), "sparkasse")
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
        let request = try XCTUnwrap(TailscaleSyncClient.bankConsentRequest(url: url, institutionId: "sparkasse"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Tailscale-User-Login"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["institutionId": "sparkasse"])
    }

    // MARK: - requisitionId validation (path component, not query string)

    func testRequisitionIdValidationAcceptsSimpleTokensAndRejectsPathInjectionShapes() {
        XCTAssertEqual(TailscaleSyncClient.validatedRequisitionId("req-abc123_XYZ"), "req-abc123_XYZ")
        for value in [
            "", " ", "req/../etc", "req/other", "req?x=1", "req#frag",
            "req id", "req\nid", "req\u{0}id", String(repeating: "a", count: 129),
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedRequisitionId(value), value)
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
            "javascript:alert(1)",
            " https://bank.example.com/consent",
            "https://bank.example.com/consent\n",
            "https://bank.example.com/\u{0}consent",
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedConsentURL(value), value)
        }
    }

    // MARK: - consent-link response parsing

    func testParseBankConsentLinkResponseSucceedsOnValidShape() throws {
        let body = Data(#"{"consentUrl":"https://bank.example.com/consent/abc","requisitionId":"req-1"}"#.utf8)
        let link = try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))
        XCTAssertEqual(link.consentUrl, URL(string: "https://bank.example.com/consent/abc"))
        XCTAssertEqual(link.requisitionId, "req-1")
    }

    func testParseBankConsentLinkResponseRejectsNonHTTPSConsentURL() {
        let body = Data(#"{"consentUrl":"http://bank.example.com/consent/abc","requisitionId":"req-1"}"#.utf8)
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .invalidConsentURL)
        }
    }

    func testParseBankConsentLinkResponseRejectsMissingHost() {
        let body = Data(#"{"consentUrl":"https:///consent/abc","requisitionId":"req-1"}"#.utf8)
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .invalidConsentURL)
        }
    }

    func testParseBankConsentLinkResponseRejectsMalformedRequisitionId() {
        let body = Data(#"{"consentUrl":"https://bank.example.com/consent/abc","requisitionId":"bad id"}"#.utf8)
        XCTAssertThrowsError(try TailscaleSyncClient.parseBankConsentLinkResponse(data: body, response: response(status: 200))) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .invalidRequisitionId)
        }
    }

    func testParseBankConsentLinkResponseRejectsMissingFieldsOrUnparsableBody() {
        for body in [
            Data(#"{"consentUrl":"https://bank.example.com/consent/abc"}"#.utf8),
            Data(#"{"requisitionId":"req-1"}"#.utf8),
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
            XCTAssertEqual(error as? TailscaleSyncError, .requisitionAlreadyLinking)
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
            ("error", BankConsentState.error),
        ] {
            let body = Data(#"{"state":"\#(raw)"}"#.utf8)
            let state = try TailscaleSyncClient.parseBankConsentStatusResponse(data: body)
            XCTAssertEqual(state, expected, raw)
        }
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
            .invalidRequisitionId,
            .invalidConsentURL,
            .requisitionAlreadyLinking,
            .gatewayNotConfigured,
        ] {
            XCTAssertEqual(TailscaleSyncClient.connectionPreflightState(for: error), .invalidResponse)
        }
    }
}
