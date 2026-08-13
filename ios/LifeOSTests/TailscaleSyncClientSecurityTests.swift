import Foundation
import XCTest
@testable import LifeOS

private final class PreflightURLProtocol: URLProtocol {
    enum ResponseMode {
        case success
        case oversized
        case redirect
        case hanging
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
        }
    }

    override func stopLoading() {
        Self.markStopped()
    }
}

final class TailscaleSyncClientSecurityTests: XCTestCase {
    private let calendarJSON = Data(#"{"items":[],"schemaVersion":1}"#.utf8)

    private func preflightRequest() throws -> URLRequest {
        let url = URL(string: "https://lifeos.example-tailnet.ts.net:8420/usage")!
        return try XCTUnwrap(TailscaleSyncClient.authenticatedRequest(
            url: url,
            bearer: String(repeating: "p", count: 32)
        ))
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
        ] {
            XCTAssertNil(TailscaleSyncClient.validatedServerURL(value, approvedHosts: approved), value)
        }
        XCTAssertNil(TailscaleSyncClient.validatedServerURL("https://other.example-tailnet.ts.net:8420", approvedHosts: approved))
    }

    func testEveryGatewayPathBuildsOnlyAnAuthenticatedRequest() throws {
        let base = URL(string: "https://lifeos.example-tailnet.ts.net:8420")!
        let bearer = String(repeating: "a", count: 32)
        let urls = [
            base.appendingPathComponent("calendar"),
            base.appendingPathComponent("documents"),
            base.appendingPathComponent("usage"),
            base.appendingPathComponent("finance/summary"),
            base.appendingPathComponent("clipper/summary"),
            base.appendingPathComponent("nutrition/barcode/4006381333931"),
            URL(string: "wss://lifeos.example-tailnet.ts.net:8420/ws")!,
        ]
        for url in urls {
            let request = try XCTUnwrap(TailscaleSyncClient.authenticatedRequest(url: url, bearer: bearer))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(bearer)")
        }
    }

    func testBearerValidationAndWebSocketRequestFailClosed() {
        XCTAssertNil(TailscaleSyncClient.validatedBearer(nil))
        XCTAssertNil(TailscaleSyncClient.validatedBearer("token"))
        XCTAssertNil(TailscaleSyncClient.validatedBearer(String(repeating: "a", count: 31)))
        XCTAssertNil(TailscaleSyncClient.validatedBearer(String(repeating: "a", count: 32) + "\n"))
        XCTAssertNil(TailscaleSyncClient.validatedBearer(String(repeating: "a", count: 513)))
        let valid = String(repeating: "b", count: 32)
        XCTAssertEqual(TailscaleSyncClient.validatedBearer(valid), valid)
        let socketURL = URL(string: "wss://lifeos.example-tailnet.ts.net/ws")!
        let request = TailscaleSyncClient.authenticatedRequest(url: socketURL, bearer: valid)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer \(valid)")
        XCTAssertNil(TailscaleSyncClient.authenticatedRequest(url: socketURL, bearer: "invalid"))
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
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("Bearer "))
        XCTAssertEqual(authorization.utf8.count, "Bearer ".utf8.count + 32)
        XCTAssertFalse(String(describing: result).contains(String(repeating: "p", count: 32)))
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
            bearer: String(repeating: "a", count: 32),
            body: calendarJSON,
            ifMatch: #""calendar-v1-r1-stale""#,
            idempotencyKey: "calendar-replay-1"
        ))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), #""calendar-v1-r1-stale""#)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "calendar-replay-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, calendarJSON)
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
}
