import Foundation
import CryptoKit
import XCTest
@testable import LifeOS

private final class PreflightURLProtocol: URLProtocol {
    enum ResponseMode {
        case success
        case oversized
        case redirect
        case hanging
        /// Declares a small, allowed Content-Length but then streams a body
        /// past the byte bound anyway -- the attack a truthful
        /// declared-length check alone cannot catch.
        case lyingContentLength
    }

    struct Snapshot {
        let requests: [URLRequest]
        let bodyWasDelivered: Bool
        let requestWasStopped: Bool
    }

    private static let lock = NSLock()
    private static var responseMode: ResponseMode = .success
    private static var requests: [URLRequest] = []
    private static var bodyWasDelivered = false
    private static var requestWasStopped = false
    private static var onRequest: (() -> Void)?

    static func configure(_ mode: ResponseMode, onRequest: (() -> Void)? = nil) {
        lock.lock()
        responseMode = mode
        requests = []
        bodyWasDelivered = false
        requestWasStopped = false
        self.onRequest = onRequest
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(requests: requests, bodyWasDelivered: bodyWasDelivered,
                        requestWasStopped: requestWasStopped)
    }

    private static func currentMode() -> ResponseMode {
        lock.lock()
        defer { lock.unlock() }
        return responseMode
    }

    private static func recordRequest(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        let callback = onRequest
        onRequest = nil
        lock.unlock()
        callback?()
    }

    private static func markBodyDelivered() {
        lock.lock()
        bodyWasDelivered = true
        lock.unlock()
    }

    private static func markStopped() {
        lock.lock()
        requestWasStopped = true
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        Self.recordRequest(request)

        switch Self.currentMode() {
        case .hanging:
            // Leave the request pending so cancellation can be exercised without
            // making a real network connection.
            return
        case .redirect:
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: nil,
                headerFields: [
                    "Location": "https://other.example.com/usage",
                    "Content-Length": "0",
                ]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        case .oversized:
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "1048577"]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        case .success:
            let body = Data("ok".utf8)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": String(body.count)]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.markBodyDelivered()
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .lyingContentLength:
            // Declared length is well within the 1_048_576-byte bound, but the
            // actual body streamed is one byte past it.
            let body = Data(repeating: 0x41, count: 1_048_576 + 1)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "2"]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.markBodyDelivered()
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.markStopped()
    }
}

final class TailscaleSyncClientSecurityTests: XCTestCase {
    private let calendarJSON = Data(#"{"items":[],"schemaVersion":1}"#.utf8)

    private func importedRecord(
        id: UUID = UUID(),
        amountCents: Int = -1_890,
        category: FinanceTransactionCategory? = nil,
        sourceRevision: Int = 0
    ) throws -> FinanceImportedSyncRecord {
        let now = Date(timeIntervalSince1970: 1_786_449_600)
        return try FinanceImportedSyncRecord(
            recordID: id,
            sourceRevision: sourceRevision,
            bookedAt: now.addingTimeInterval(-120),
            amountCents: amountCents,
            description: "Restaurant",
            categoryOverride: category,
            sourceCategory: "Food",
            providerCode: nil,
            source: .tradeRepublicCSV,
            importedAt: now.addingTimeInterval(-60),
            kind: .cash,
            investment: nil
        )
    }

    private func importedResponse(
        statusCode: Int = 200,
        snapshot: FinanceImportedSyncSnapshot? = nil,
        body: Data? = nil,
        revision: Int? = nil,
        contentType: String = "application/json",
        extraHeaders: [String: String] = [:]
    ) throws -> (Data, HTTPURLResponse) {
        let resolvedSnapshot = try snapshot ?? FinanceImportedSyncSnapshot(revision: revision ?? 0, records: [], tombstones: [])
        let resolvedBody = try body ?? JSONEncoder.lifeOS.encode(resolvedSnapshot)
        let resolvedRevision = revision ?? resolvedSnapshot.revision
        let digest = SHA256.hash(data: resolvedBody).map { String(format: "%02x", $0) }.joined()
        var headers = [
            "Content-Type": contentType,
            "ETag": "\"finance-imported-v2-r\(resolvedRevision)-\(digest)\"",
            "X-LifeOS-Revision": String(resolvedRevision),
            "X-LifeOS-Schema-Version": "2",
        ]
        headers.merge(extraHeaders) { _, incoming in incoming }
        return (
            resolvedBody,
            HTTPURLResponse(
                url: URL(string: "https://lifeos.example-tailnet.ts.net:8420/finance/imported")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }

    private func preflightRequest() throws -> URLRequest {
        let url = URL(string: "https://lifeos.example-tailnet.ts.net:8420/usage")!
        return TailscaleSyncClient.gatewayRequest(url: url)
    }

    private func assertNoCredentialHeaders(_ request: URLRequest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), file: file, line: line)
        for field in [
            "Tailscale-User-Login",
            "Tailscale-User-Name",
            "Tailscale-User-Profile-Picture"
        ] {
            XCTAssertNil(request.value(forHTTPHeaderField: field), "unexpected \(field)", file: file, line: line)
        }
    }

    private func preflightSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreflightURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: StrictSyncSessionDelegate(),
            delegateQueue: nil
        )
    }

    func testServerURLAcceptsOnlyCanonicalPrivateHTTPSOrigin() {
        let approved: Set<String> = ["lifeos.example-tailnet.ts.net"]
        XCTAssertNotNil(TailscaleSyncClient.validatedServerURL("https://lifeos.example-tailnet.ts.net", approvedHosts: approved))
        XCTAssertNotNil(TailscaleSyncClient.validatedServerURL("https://lifeos.example-tailnet.ts.net:443", approvedHosts: approved))
        XCTAssertNotNil(TailscaleSyncClient.validatedServerURL("https://lifeos.example-tailnet.ts.net:8420", approvedHosts: approved))
        for value in [
            "http://lifeos.example-tailnet.ts.net:8420",
            "https://example.com",
            "https://user:password@lifeos.example-tailnet.ts.net",
            "https://lifeos.example-tailnet.ts.net/path",
            "https://lifeos.example-tailnet.ts.net?redirect=https://example.com",
            "https://lifeos.example-tailnet.ts.net#fragment",
            "https://lifeos.example-tailnet.ts.net:9443",
            "https://lifeos.example-tailnet.ts.net:80",
            "https://lifeos.example-tailnet.ts.net.",
            "https://lifeos..example-tailnet.ts.net",
            "https://lifeos.example_tailnet.ts.net",
            "https://lifeos.example-tailnet.ts.net/\n",
            " https://lifeos.example-tailnet.ts.net",
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedServerURL(value, approvedHosts: approved), value)
        }
        XCTAssertNil(TailscaleSyncClient.validatedServerURL("https://other.example-tailnet.ts.net:8420", approvedHosts: approved))
    }

    func testReadinessRequiresOnlySignedHostAndValidatedURL() {
        let approved: Set<String> = ["lifeos.example-tailnet.ts.net"]
        let ready = SyncSettingsReadiness.resolve(
            serverURL: "https://lifeos.example-tailnet.ts.net:8420",
            approvedHosts: approved
        )
        XCTAssertTrue(ready.approvedHostConfigured)
        XCTAssertEqual(ready.urlState, .valid)
        XCTAssertTrue(ready.canAttemptConnection)
        XCTAssertEqual(ready.title, "Ready for Tailscale identity preflight")

        let invalid = SyncSettingsReadiness.resolve(
            serverURL: "https://other.example-tailnet.ts.net:8420",
            approvedHosts: approved
        )
        XCTAssertEqual(invalid.urlState, .invalid)
        XCTAssertFalse(invalid.canAttemptConnection)
    }

    func testEveryGatewayRESTAndWebSocketRequestSendsNoCredentialHeaders() throws {
        let base = URL(string: "https://lifeos.example-tailnet.ts.net:8420")!
        let urls = [
            base.appendingPathComponent("calendar"),
            base.appendingPathComponent("documents"),
            base.appendingPathComponent("usage"),
            base.appendingPathComponent("finance/summary"),
            base.appendingPathComponent("finance/imported"),
            base.appendingPathComponent("clipper/summary"),
            base.appendingPathComponent("nutrition/barcode/4006381333931"),
            URL(string: "wss://lifeos.example-tailnet.ts.net:8420/ws")!,
        ]
        for url in urls {
            let request = TailscaleSyncClient.gatewayRequest(url: url)
            XCTAssertEqual(request.httpMethod, "GET")
            assertNoCredentialHeaders(request)
        }
    }

    func testBoundedCollectorRejectsBeforeAccumulatingPastLimit() async {
        let stream = AsyncStream<UInt8> { continuation in
            for value in [UInt8(1), 2, 3, 4, 5] { continuation.yield(value) }
            continuation.finish()
        }
        do {
            _ = try await TailscaleSyncClient.collectBounded(stream, maximumBytes: 4)
            XCTFail("collector must reject the first byte beyond its bound")
        } catch let error as TailscaleSyncError {
            XCTAssertEqual(error, .responseTooLarge)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRedirectDelegateRejectsRedirect() {
        let delegate = StrictSyncSessionDelegate()
        let response = HTTPURLResponse(
            url: URL(string: "https://lifeos.example-tailnet.ts.net/calendar")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://other.example.com/calendar"]
        )!
        let task = URLSession.shared.dataTask(with: response.url!)
        var redirectedRequest: URLRequest?
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://other.example.com/calendar")!)) {
            redirectedRequest = $0
        }
        XCTAssertNil(redirectedRequest)
    }

    func testDeclaredContentLengthFailsClosedBeforeReadingBody() {
        XCTAssertTrue(TailscaleSyncClient.contentLengthIsAllowed(nil, maximumBytes: 4))
        XCTAssertTrue(TailscaleSyncClient.contentLengthIsAllowed("4", maximumBytes: 4))
        XCTAssertFalse(TailscaleSyncClient.contentLengthIsAllowed("5", maximumBytes: 4))
        XCTAssertFalse(TailscaleSyncClient.contentLengthIsAllowed("-1", maximumBytes: 4))
        XCTAssertFalse(TailscaleSyncClient.contentLengthIsAllowed("invalid", maximumBytes: 4))
    }

    func testConnectionPreflightTransportMakesOneBoundedAuthenticatedGETWithoutMutation() async throws {
        let defaults = UserDefaults(suiteName: "LifeOS.TailscaleSyncClientSecurityTests.transport.\(UUID().uuidString)")!
        defaults.set("unchanged", forKey: "sentinel")
        PreflightURLProtocol.configure(.success)
        let session = preflightSession()
        defer { session.invalidateAndCancel() }

        let result = await TailscaleSyncClient.performConnectionPreflightForTesting(
            session: session,
            request: try preflightRequest()
        )
        XCTAssertEqual(result, .reachable)

        let snapshot = PreflightURLProtocol.snapshot()
        XCTAssertEqual(snapshot.requests.count, 1)
        let request = try XCTUnwrap(snapshot.requests.first)
        XCTAssertEqual(request.url?.path, "/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        assertNoCredentialHeaders(request)
        XCTAssertTrue(snapshot.bodyWasDelivered, "successful response body must be consumed")
        XCTAssertEqual(defaults.string(forKey: "sentinel"), "unchanged")
        XCTAssertNil(defaults.object(forKey: TailscaleSyncClient.serverURLDefaultsKey))
    }

    func testConnectionPreflightTransportRejectsOversizedResponseBeforeBodyAndRedirect() async throws {
        let session = preflightSession()
        defer { session.invalidateAndCancel() }

        PreflightURLProtocol.configure(.oversized)
        let oversized = await TailscaleSyncClient.performConnectionPreflightForTesting(
            session: session,
            request: try preflightRequest()
        )
        XCTAssertEqual(oversized, .invalidResponse)
        let oversizedSnapshot = PreflightURLProtocol.snapshot()
        XCTAssertEqual(oversizedSnapshot.requests.count, 1)
        XCTAssertFalse(oversizedSnapshot.bodyWasDelivered)

        PreflightURLProtocol.configure(.redirect)
        let redirected = await TailscaleSyncClient.performConnectionPreflightForTesting(
            session: session,
            request: try preflightRequest()
        )
        XCTAssertEqual(redirected, .invalidResponse)
        let redirectedSnapshot = PreflightURLProtocol.snapshot()
        XCTAssertEqual(redirectedSnapshot.requests.count, 1)
        XCTAssertFalse(redirectedSnapshot.bodyWasDelivered)
    }

    func testConnectionPreflightCancellationStopsURLSessionWithoutRenderingFailure() async throws {
        let requestStarted = expectation(description: "preflight request started")
        PreflightURLProtocol.configure(.hanging) {
            requestStarted.fulfill()
        }
        let session = preflightSession()
        defer { session.invalidateAndCancel() }
        let request = try preflightRequest()
        let operation = Task {
            await TailscaleSyncClient.performConnectionPreflightForTesting(
                session: session,
                request: request
            )
        }

        await fulfillment(of: [requestStarted], timeout: 1)
        operation.cancel()
        let result = await operation.value

        XCTAssertNil(result)
        let snapshot = PreflightURLProtocol.snapshot()
        XCTAssertEqual(snapshot.requests.count, 1)
        XCTAssertTrue(snapshot.requestWasStopped)
    }

    func testConnectionPreflightClassifiesFailuresWithoutCarryingSensitiveContext() {
        XCTAssertEqual(
            TailscaleSyncClient.connectionPreflightState(for: TailscaleSyncError.notConfigured),
            .configurationRequired
        )
        XCTAssertEqual(
            TailscaleSyncClient.connectionPreflightState(for: TailscaleSyncError.invalidServerURL),
            .configurationRequired
        )
        for status in [401, 403] {
            XCTAssertEqual(
                TailscaleSyncClient.connectionPreflightState(for: TailscaleSyncError.httpError(status)),
                .authenticationRejected
            )
        }
        for status in [408, 429, 500, 503, 599] {
            XCTAssertEqual(
                TailscaleSyncClient.connectionPreflightState(for: TailscaleSyncError.httpError(status)),
                .serverUnavailable
            )
        }
        XCTAssertEqual(
            TailscaleSyncClient.connectionPreflightState(for: TailscaleSyncError.httpError(302)),
            .invalidResponse
        )
        XCTAssertEqual(
            TailscaleSyncClient.connectionPreflightState(for: TailscaleSyncError.responseTooLarge),
            .invalidResponse
        )
        XCTAssertEqual(
            TailscaleSyncClient.connectionPreflightState(for: URLError(.cannotConnectToHost)),
            .networkUnavailable
        )
        XCTAssertEqual(
            TailscaleSyncClient.connectionPreflightState(for: URLError(.timedOut)),
            .serverUnavailable
        )
        XCTAssertNil(TailscaleSyncClient.connectionPreflightState(for: CancellationError()))
        XCTAssertNil(TailscaleSyncClient.connectionPreflightState(for: URLError(.cancelled)))

        struct UnexpectedFailure: Error {}
        XCTAssertEqual(
            TailscaleSyncClient.connectionPreflightState(for: UnexpectedFailure()),
            .invalidResponse
        )
    }

    func testCalendarETagAndIdempotencyValidationFailClosed() {
        XCTAssertEqual(TailscaleSyncClient.validatedCalendarETag(#""calendar-v1-r0-abc""#), #""calendar-v1-r0-abc""#)
        for value in [nil, "", "calendar-v1-r0-abc", "W/\"calendar-v1-r0-abc\"", "\"one\", \"two\"", "\"bad\\quote\""] {
            XCTAssertNil(TailscaleSyncClient.validatedCalendarETag(value), value ?? "nil")
        }
        XCTAssertEqual(TailscaleSyncClient.validatedCalendarIdempotencyKey("calendar-1"), "calendar-1")
        for value in [nil, "", " ", "bad\nkey", String(repeating: "x", count: 129)] {
            XCTAssertNil(TailscaleSyncClient.validatedCalendarIdempotencyKey(value), value ?? "nil")
        }
    }

    func testUnconditionalCalendarPushIsRejectedBeforeTransport() async {
        let defaults = UserDefaults(suiteName: "LifeOS.TailscaleSyncClientSecurityTests.\(UUID().uuidString)")!
        defaults.set("https://lifeos.example-tailnet.ts.net", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        let client = TailscaleSyncClient(defaults: defaults)
        do {
            try await client.pushCalendar(calendarJSON)
            XCTFail("unconditional push must fail closed")
        } catch let error as CalendarSyncError {
            XCTAssertEqual(error, .missingIfMatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCalendarFetchRequiresETagAndRejectsOversizedResource() throws {
        let calendarJSON = self.calendarJSON
        let url = URL(string: "https://lifeos.example-tailnet.ts.net/calendar")!
        do {
            _ = try TailscaleSyncClient.parseCalendarFetchResponse(
                data: calendarJSON,
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
            XCTFail("missing ETag must fail closed")
        } catch let error as CalendarSyncError {
            XCTAssertEqual(error, .missingETag)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try TailscaleSyncClient.parseCalendarFetchResponse(
                data: Data(repeating: 0x20, count: TailscaleSyncClient.maximumCalendarResourceBytes + 1),
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": #""calendar-v1-r0-oversized""#])!
            )
            XCTFail("oversized Calendar resource must fail closed")
        } catch let error as TailscaleSyncError {
            XCTAssertEqual(error, .responseTooLarge)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConditionalCalendarPushCarriesETagAndIdempotencyAndReturnsAuthoritativeConflict() throws {
        let calendarJSON = self.calendarJSON
        let conflictETag = #""calendar-v1-r2-authoritative""#
        let url = URL(string: "https://lifeos.example-tailnet.ts.net/calendar")!
        let request = try XCTUnwrap(TailscaleSyncClient.conditionalCalendarRequest(
            url: url,
            body: calendarJSON,
            ifMatch: #""calendar-v1-r1-stale""#,
            idempotencyKey: "calendar-replay-1"
        ))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), #""calendar-v1-r1-stale""#)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "calendar-replay-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, calendarJSON)
        assertNoCredentialHeaders(request)
        do {
            _ = try TailscaleSyncClient.parseCalendarPushResponse(
                data: calendarJSON,
                response: HTTPURLResponse(url: url, statusCode: 412, httpVersion: nil, headerFields: ["ETag": conflictETag])!
            )
            XCTFail("stale Calendar PUT must return a conflict")
        } catch let error as CalendarSyncError {
            guard case .calendarConflict(let data, let etag) = error else {
                return XCTFail("expected authoritative Calendar conflict, got \(error)")
            }
            XCTAssertEqual(data, calendarJSON)
            XCTAssertEqual(etag, conflictETag)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCalendarPushNonConflictHTTPErrorDoesNotRequireETag() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://lifeos.example-tailnet.ts.net/calendar")!,
            statusCode: 413,
            httpVersion: nil,
            headerFields: nil
        )!
        XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarPushResponse(data: Data(#"{"error":"body_too_large"}"#.utf8), response: response)) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .httpError(413))
        }
    }

    func testCalendarPushRequiresAuthoritativeConflictAndSuccessShape() throws {
        let url = URL(string: "https://lifeos.example-tailnet.ts.net/calendar")!
        let validETag = #""calendar-v1-r3-authoritative""#

        for status in [412, 428] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["ETag": validETag])!
            XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarPushResponse(data: calendarJSON, response: response)) { error in
                guard let calendarError = error as? CalendarSyncError,
                      case .calendarConflict(let data, let etag) = calendarError else {
                    return XCTFail("status must produce an authoritative conflict")
                }
                XCTAssertEqual(data, self.calendarJSON)
                XCTAssertEqual(etag, validETag)
            }
        }

        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": validETag])!
        let resource = try TailscaleSyncClient.parseCalendarPushResponse(data: calendarJSON, response: success)
        XCTAssertEqual(resource.data, calendarJSON)
        XCTAssertEqual(resource.etag, validETag)

        let missingSuccessETag = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarPushResponse(data: calendarJSON, response: missingSuccessETag)) { error in
            XCTAssertEqual(error as? CalendarSyncError, .missingETag)
        }

        let invalidConflict = HTTPURLResponse(url: url, statusCode: 412, httpVersion: nil, headerFields: ["ETag": validETag])!
        XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarPushResponse(data: Data(#"{"schemaVersion":2,"items":[]}"#.utf8), response: invalidConflict)) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .invalidResponse)
        }
    }

    func testFinanceImportedRequestUsesOnlyConditionalHeaders() throws {
        let url = URL(string: "https://lifeos.example-tailnet.ts.net:8420/finance/imported")!
        let body = Data(#"{"schemaVersion":2,"baseRevision":0,"operations":[]}"#.utf8)
        let etag = #""finance-imported-v2-r0-0000000000000000000000000000000000000000000000000000000000000000""#
        let request = try XCTUnwrap(TailscaleSyncClient.conditionalFinanceImportedRequest(
            url: url,
            body: body,
            ifMatch: etag,
            idempotencyKey: "finance-import-1"
        ))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), etag)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "finance-import-1")
        XCTAssertEqual(Set(request.allHTTPHeaderFields?.map(\.key) ?? []), ["Content-Type", "If-Match", "Idempotency-Key"])
        XCTAssertEqual(request.httpBody, body)
        assertNoCredentialHeaders(request)
    }

    func testFinanceImportedETagAndIdempotencyValidationFailClosed() {
        let valid = #""finance-imported-v2-r0-0000000000000000000000000000000000000000000000000000000000000000""#
        XCTAssertEqual(TailscaleSyncClient.validatedFinanceImportedETag(valid), valid)
        XCTAssertEqual(TailscaleSyncClient.financeImportedETagRevision(valid), 0)
        for value in [
            nil,
            "",
            "finance-imported-v2-r0-deadbeef",
            "W/\"finance-imported-v2-r0-0000000000000000000000000000000000000000000000000000000000000000\"",
            "\"finance-imported-v2-r01-0000000000000000000000000000000000000000000000000000000000000000\"",
            "\"finance-imported-v2-r0-000000000000000000000000000000000000000000000000000000000000000G\"",
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedFinanceImportedETag(value), value ?? "nil")
        }
        XCTAssertNil(TailscaleSyncClient.validatedFinanceImportedIdempotencyKey("bad\nkey"))
        XCTAssertNil(TailscaleSyncClient.validatedFinanceImportedIdempotencyKey(String(repeating: "x", count: 129)))
    }

    func testFinanceImportedResponseAcceptsSuccessAndSurfacesAuthoritativeConflict() throws {
        let record = try importedRecord(category: .groceries, sourceRevision: 3)
        let snapshot = try FinanceImportedSyncSnapshot(revision: 3, records: [record], tombstones: [])
        let successPayload = try importedResponse(snapshot: snapshot)
        let success = try TailscaleSyncClient.parseFinanceImportedResponse(
            data: successPayload.0,
            response: successPayload.1
        )
        XCTAssertEqual(success.snapshot, snapshot)
        XCTAssertEqual(success.etag, successPayload.1.value(forHTTPHeaderField: "ETag"))
        XCTAssertFalse(success.wasReplay)

        let conflictPayload = try importedResponse(
            statusCode: 412,
            snapshot: snapshot,
            extraHeaders: ["X-LifeOS-Conflict": "true"]
        )
        XCTAssertThrowsError(try TailscaleSyncClient.parseFinanceImportedResponse(
            data: conflictPayload.0,
            response: conflictPayload.1
        )) { error in
            guard case .conflict(let conflictSnapshot, let conflictETag) = error as? FinanceImportedSyncError else {
                return XCTFail("expected typed authoritative finance conflict, got \(error)")
            }
            XCTAssertEqual(conflictSnapshot, snapshot)
            XCTAssertEqual(conflictETag, conflictPayload.1.value(forHTTPHeaderField: "ETag"))
        }
    }

    func testFinanceImportedResponseRejectsWrongContentTypeStatusAndRevision() throws {
        let valid = try importedResponse()
        let wrongType = try importedResponse(contentType: "text/plain")
        XCTAssertThrowsError(try TailscaleSyncClient.parseFinanceImportedResponse(data: wrongType.0, response: wrongType.1)) { error in
            XCTAssertEqual(error as? FinanceImportedSyncError, .invalidContentType)
        }

        let serverError = try importedResponse(statusCode: 503)
        XCTAssertThrowsError(try TailscaleSyncClient.parseFinanceImportedResponse(data: serverError.0, response: serverError.1)) { error in
            XCTAssertEqual(error as? FinanceImportedSyncError, .httpError(503))
        }

        var mismatchedHeaders = valid.1.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        mismatchedHeaders["X-LifeOS-Revision"] = "1"
        let mismatched = HTTPURLResponse(
            url: valid.1.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: mismatchedHeaders
        )!
        XCTAssertThrowsError(try TailscaleSyncClient.parseFinanceImportedResponse(data: valid.0, response: mismatched)) { error in
            XCTAssertEqual(error as? FinanceImportedSyncError, .invalidRevision)
        }
    }

    func testFinanceImportedResponseRejectsUnknownSchemaAndOversizedBody() throws {
        let valid = try importedResponse()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid.0) as? [String: Any])
        object["schemaVersion"] = 99
        let unknownSchemaBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let unknownSchema = try importedResponse(body: unknownSchemaBody)
        XCTAssertThrowsError(try TailscaleSyncClient.parseFinanceImportedResponse(
            data: unknownSchema.0,
            response: unknownSchema.1
        )) { error in
            XCTAssertEqual(error as? FinanceImportedSyncError, .invalidResponse)
        }

        let oversizedBody = Data(repeating: 0x20, count: TailscaleSyncClient.maximumFinanceImportedResponseBytes + 1)
        let oversizedResponse = HTTPURLResponse(
            url: valid.1.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        XCTAssertThrowsError(try TailscaleSyncClient.parseFinanceImportedResponse(
            data: oversizedBody,
            response: oversizedResponse
        )) { error in
            XCTAssertEqual(error as? FinanceImportedSyncError, .responseTooLarge)
        }
    }

    // MARK: - Additional negatives for SY-02

    /// A non-approved host, a host that merely *contains* the approved
    /// hostname as a substring, and a host that carries the approved
    /// hostname as a prefix of an attacker-controlled domain must all be
    /// refused. `validatedServerURL` matches on exact `Set` membership of
    /// the parsed host, so none of these can slip through as a loose
    /// "starts with" / "contains" match.
    func testLookAlikeAndSubstringHostsAreRejected() {
        let approved: Set<String> = ["lifeos.example-tailnet.ts.net"]
        for value in [
            // Approved host as a prefix of an attacker-controlled domain.
            "https://lifeos.example-tailnet.ts.net.evil.com",
            // Approved host as a suffix of a different, unapproved label.
            "https://evillifeos.example-tailnet.ts.net",
            // Approved host with an attacker-controlled subdomain prepended.
            "https://sub.lifeos.example-tailnet.ts.net",
            // Approved host as a substring inside a longer unapproved label.
            "https://notlifeos.example-tailnet.ts.net",
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedServerURL(value, approvedHosts: approved), value)
        }
    }

    /// The exact look-alike shape called out for the real production host
    /// configured in `project.yml` (`LIFEOS_SYNC_APPROVED_HOSTS`).
    func testRealProductionHostLookAlikeIsRejected() {
        let approved: Set<String> = ["geonqserver.tail5f8789.ts.net"]
        XCTAssertNotNil(TailscaleSyncClient.validatedServerURL("https://geonqserver.tail5f8789.ts.net", approvedHosts: approved))
        for value in [
            "https://geonqserver.tail5f8789.ts.net.evil.com",
            "http://geonqserver.tail5f8789.ts.net",
            "https://geonqserver.tail5f8789.ts.net:8421",
            "https://geonqserver.tail5f8789.ts.net/health",
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedServerURL(value, approvedHosts: approved), value)
        }
    }

    /// There is no parameter or seam anywhere in `TailscaleSyncClient` that
    /// lets a caller attach a custom header to an outgoing request, so a
    /// forged identity header (e.g. a spoofed `Tailscale-User-Login`) has no
    /// injection point to begin with. Proving the built request carries no
    /// headers at all is the strongest available evidence of that: nothing
    /// downstream can ever read a caller-forged value because nothing is
    /// ever there to read.
    func testGatewayRequestCarriesNoHeadersAtAllSoNoForgedHeaderCanBeInjected() {
        let url = URL(string: "https://lifeos.example-tailnet.ts.net:8420/usage")!
        let request = TailscaleSyncClient.gatewayRequest(url: url)
        XCTAssertTrue(request.allHTTPHeaderFields?.isEmpty ?? true,
                      "a GET gateway request must carry zero headers -- there is no caller-supplied header surface to forge")
    }

    /// `performBoundedReadOnly` (the shared transport underneath every
    /// read-only endpoint: usage, finance summary, clipper summary, the
    /// nutrition-barcode lookup, bank-consent status polling, and the
    /// connection preflight) explicitly rejects a non-GET request before
    /// touching the network. This is the read-only boundary this client
    /// actually enforces -- note that the client as a whole is not fully
    /// read-only (Calendar push is a validated conditional PUT and bank
    /// consent initiation is a validated POST), so this test proves the
    /// property scoped to where the code actually enforces it.
    func testBoundedReadOnlyTransportRejectsNonGETMethodBeforeAnyNetworkCall() async throws {
        var request = try preflightRequest()
        request.httpMethod = "PUT"
        PreflightURLProtocol.configure(.success)
        let session = preflightSession()
        defer { session.invalidateAndCancel() }

        let result = await TailscaleSyncClient.performConnectionPreflightForTesting(
            session: session,
            request: request
        )
        XCTAssertEqual(result, .invalidResponse)
        let snapshot = PreflightURLProtocol.snapshot()
        XCTAssertEqual(snapshot.requests.count, 0,
                       "a non-GET request must be rejected before it ever reaches the network layer")
    }

    /// The declared-length preflight check alone cannot catch a server that
    /// lies about `Content-Length`. This proves the second, independent
    /// backstop: `collectBounded`'s streaming accumulation bound rejects the
    /// response once actual bytes exceed `maximumReadOnlyResponseBytes`,
    /// even though the declared length claimed the response was small.
    func testStreamingCollectorRejectsAResponseThatLiesAboutItsDeclaredLength() async throws {
        PreflightURLProtocol.configure(.lyingContentLength)
        let session = preflightSession()
        defer { session.invalidateAndCancel() }

        let result = await TailscaleSyncClient.performConnectionPreflightForTesting(
            session: session,
            request: try preflightRequest()
        )
        XCTAssertEqual(result, .invalidResponse)
        let snapshot = PreflightURLProtocol.snapshot()
        XCTAssertEqual(snapshot.requests.count, 1)
    }
}
