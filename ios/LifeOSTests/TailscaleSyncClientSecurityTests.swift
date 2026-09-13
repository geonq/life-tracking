import Foundation
import CryptoKit
import XCTest
@testable import LifeOS

private final class PreflightURLProtocol: URLProtocol {
    enum ResponseMode {
        case success
        case oversized
        case missingContentType
        case wrongContentType
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
    private static var onStop: (() -> Void)?

    static func configure(
        _ mode: ResponseMode,
        onRequest: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        lock.lock()
        responseMode = mode
        requests = []
        bodyWasDelivered = false
        requestWasStopped = false
        self.onRequest = onRequest
        self.onStop = onStop
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
        let callback = onStop
        onStop = nil
        lock.unlock()
        callback?()
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
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": "1048577",
                ]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        case .missingContentType:
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
        case .wrongContentType:
            let body = Data("ok".utf8)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "Content-Length": String(body.count),
                ]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.markBodyDelivered()
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .success:
            let body = Data("ok".utf8)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Content-Length": String(body.count),
                ]
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
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": "2",
                ]
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

    private func injectedClient(session: URLSession) -> TailscaleSyncClient {
        let suiteName = "LifeOS.TailscaleSyncClientSecurityTests.reader." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://lifeos.example-tailnet.ts.net:8420", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        return TailscaleSyncClient(
            session: session,
            defaults: defaults,
            approvedHosts: ["lifeos.example-tailnet.ts.net"]
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

    @MainActor
    func testVisualFixtureSyncStorageViewLeavesProductionDefaultsUntouched() {
        let defaults = UserDefaults.standard
        let serverURLBefore = defaults.object(forKey: TailscaleSyncClient.serverURLDefaultsKey) as? String
        let lastSuccessBefore = defaults.object(forKey: "LifeOS.Sync.LastSuccess") as? Double

        let view = SyncStorageSettingsView(usesVisualFixtures: true)
        _ = view.body

        XCTAssertEqual(
            defaults.object(forKey: TailscaleSyncClient.serverURLDefaultsKey) as? String,
            serverURLBefore
        )
        XCTAssertEqual(
            defaults.object(forKey: "LifeOS.Sync.LastSuccess") as? Double,
            lastSuccessBefore
        )
    }

    @MainActor
    func testVisualFixtureSyncStoragePreflightRejectsHostileCheckerWithoutCallingIt() async {
        var checkerCalls = 0
        let configuration = SyncStorageSettingsConfiguration.visualFixture(
            connectionChecker: {
                checkerCalls += 1
                return .reachable
            }
        )

        XCTAssertTrue(configuration.usesVisualFixtures)
        XCTAssertFalse(configuration.allowsConnectionPreflight)
        XCTAssertTrue(configuration.approvedHosts.isEmpty)

        let result = await configuration.checkConnection()

        XCTAssertNil(result)
        XCTAssertEqual(checkerCalls, 0)
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

    func testJSONContentTypeRequiresApplicationJSONAndAllowsParameters() {
        XCTAssertTrue(TailscaleSyncClient.isJSONContentType("application/json"))
        XCTAssertTrue(TailscaleSyncClient.isJSONContentType("Application/JSON; charset=utf-8"))
        XCTAssertTrue(TailscaleSyncClient.isJSONContentType(" application/json ; charset=UTF-8 "))
        XCTAssertFalse(TailscaleSyncClient.isJSONContentType(nil))
        XCTAssertFalse(TailscaleSyncClient.isJSONContentType(""))
        XCTAssertFalse(TailscaleSyncClient.isJSONContentType("text/plain"))
        XCTAssertFalse(TailscaleSyncClient.isJSONContentType("application/json, text/plain"))
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

    func testReadOnlyDocumentsReaderRejectsOversizedAndNonJSONResponses() async throws {
        let session = preflightSession()
        defer { session.invalidateAndCancel() }
        let client = injectedClient(session: session)

        PreflightURLProtocol.configure(.success)
        let success = try await client.fetchDocuments()
        XCTAssertEqual(success, Data("ok".utf8))
        XCTAssertEqual(PreflightURLProtocol.snapshot().requests.first?.url?.path, "/documents")

        PreflightURLProtocol.configure(.oversized)
        do {
            _ = try await client.fetchDocuments()
            XCTFail("an oversized documents response must fail closed")
        } catch let error as TailscaleSyncError {
            XCTAssertEqual(error, .responseTooLarge)
        } catch {
            XCTFail("unexpected oversized-response error: \(error)")
        }

        for mode in [PreflightURLProtocol.ResponseMode.missingContentType,
                     .wrongContentType] {
            PreflightURLProtocol.configure(mode)
            do {
                _ = try await client.fetchDocuments()
                XCTFail("a non-JSON documents response must fail closed")
            } catch let error as TailscaleSyncError {
                XCTAssertEqual(error, .invalidResponse)
            } catch {
                XCTFail("unexpected content-type error: \(error)")
            }
        }
    }

    func testConnectionPreflightCancellationStopsURLSessionWithoutRenderingFailure() async throws {
        let requestStarted = expectation(description: "preflight request started")
        let requestStopped = expectation(description: "preflight request stopped")
        PreflightURLProtocol.configure(
            .hanging,
            onRequest: { requestStarted.fulfill() },
            onStop: { requestStopped.fulfill() }
        )
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
        await fulfillment(of: [requestStopped], timeout: 1)

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

        let validETag = #""calendar-v1-r0-valid""#
        let validResponse = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json; charset=utf-8",
                "ETag": validETag,
            ]
        )!
        let resource = try TailscaleSyncClient.parseCalendarFetchResponse(
            data: calendarJSON,
            response: validResponse
        )
        XCTAssertEqual(resource.data, calendarJSON)
        XCTAssertEqual(resource.etag, validETag)

        for headers in [
            ["ETag": validETag],
            ["Content-Type": "text/plain", "ETag": validETag],
        ] {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
            XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarFetchResponse(
                data: calendarJSON,
                response: response
            )) { error in
                XCTAssertEqual(error as? TailscaleSyncError, .invalidResponse)
            }
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
                response: HTTPURLResponse(url: url, statusCode: 412, httpVersion: nil, headerFields: ["ETag": conflictETag, "Content-Type": "application/json"])!
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
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["ETag": validETag, "Content-Type": "application/json"])!
            XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarPushResponse(data: calendarJSON, response: response)) { error in
                guard let calendarError = error as? CalendarSyncError,
                      case .calendarConflict(let data, let etag) = calendarError else {
                    return XCTFail("status must produce an authoritative conflict")
                }
                XCTAssertEqual(data, self.calendarJSON)
                XCTAssertEqual(etag, validETag)
            }
        }

        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": validETag, "Content-Type": "application/json"])!
        let resource = try TailscaleSyncClient.parseCalendarPushResponse(data: calendarJSON, response: success)
        XCTAssertEqual(resource.data, calendarJSON)
        XCTAssertEqual(resource.etag, validETag)

        let missingSuccessETag = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarPushResponse(data: calendarJSON, response: missingSuccessETag)) { error in
            XCTAssertEqual(error as? CalendarSyncError, .missingETag)
        }

        let invalidConflict = HTTPURLResponse(url: url, statusCode: 412, httpVersion: nil, headerFields: ["ETag": validETag, "Content-Type": "application/json"])!
        XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarPushResponse(data: Data(#"{"schemaVersion":2,"items":[]}"#.utf8), response: invalidConflict)) { error in
            XCTAssertEqual(error as? TailscaleSyncError, .invalidResponse)
        }

        let wrongConflictContentType = HTTPURLResponse(url: url, statusCode: 412, httpVersion: nil, headerFields: ["ETag": validETag, "Content-Type": "text/plain"])!
        XCTAssertThrowsError(try TailscaleSyncClient.parseCalendarPushResponse(data: calendarJSON, response: wrongConflictContentType)) { error in
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

    func testFinanceImportedReceiptResponseAcceptsCommittedAndUnknownStates() throws {
        let url = URL(string: "https://lifeos.example-tailnet.ts.net:8420/finance/imported/receipt/key")!
        let committedBody = try JSONEncoder.lifeOS.encode(
            FinanceImportedCommitReceipt(state: .committed, revision: 4)
        )
        let committedResponse = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let committed = try TailscaleSyncClient.parseFinanceImportedReceiptResponse(
            data: committedBody,
            response: committedResponse
        )
        XCTAssertEqual(committed, try FinanceImportedCommitReceipt(state: .committed, revision: 4))

        let unknownBody = try JSONEncoder.lifeOS.encode(
            FinanceImportedCommitReceipt(state: .unknown, revision: nil)
        )
        let unknown = try TailscaleSyncClient.parseFinanceImportedReceiptResponse(
            data: unknownBody,
            response: committedResponse
        )
        XCTAssertEqual(unknown, try FinanceImportedCommitReceipt(state: .unknown, revision: nil))

        let extraField = Data(#"{"revision":4,"state":"committed","fingerprint":"private"}"#.utf8)
        XCTAssertThrowsError(try TailscaleSyncClient.parseFinanceImportedReceiptResponse(
            data: extraField,
            response: committedResponse
        )) { error in
            XCTAssertEqual(error as? FinanceImportedSyncError, .invalidResponse)
        }

        let invalidRevision = Data(#"{"revision":null,"state":"committed"}"#.utf8)
        XCTAssertThrowsError(try TailscaleSyncClient.parseFinanceImportedReceiptResponse(
            data: invalidRevision,
            response: committedResponse
        )) { error in
            XCTAssertEqual(error as? FinanceImportedSyncError, .invalidResponse)
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

    private func fitnessEnvelope(at now: Date) throws -> FitnessObservationEnvelope {
        let observedAt = now.addingTimeInterval(-20)
        let heartRate = try FitnessObservationValue(
            metric: .heartRate,
            value: 61.5,
            unit: .beatsPerMinute,
            observedAt: observedAt
        )
        let hrv = try FitnessObservationValue(
            metric: .heartRateVariability,
            value: 48,
            unit: .milliseconds,
            observedAt: observedAt
        )
        let sleep = try FitnessObservationValue(
            metric: .sleepDuration,
            value: 7_200,
            unit: .seconds,
            observedAt: observedAt
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = FitnessObservationDay(
            date: calendar.startOfDay(for: now),
            values: [sleep]
        )
        let workout = FitnessObservationWorkout(
            activityTypeRawValue: 37,
            startAt: now.addingTimeInterval(-1_800),
            endAt: now.addingTimeInterval(-1_200),
            durationSeconds: 600,
            activeEnergyKilocalories: 120
        )
        return try FitnessObservationEnvelope(
            state: .observed,
            generatedAt: now,
            observedAt: observedAt,
            metrics: [heartRate, hrv],
            days: [day],
            workouts: [workout]
        )
    }

    func testFitnessObservationContractRoundTripsBoundedSourceBackedValues() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let envelope = try fitnessEnvelope(at: now)
        let data = try envelope.encoded(now: now)
        let decoded = try FitnessObservationEnvelope.decode(data, now: now)

        XCTAssertEqual(decoded, envelope)
        XCTAssertLessThanOrEqual(data.count, FitnessObservationEnvelope.maximumEncodedBytes)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("deviceidentifier"))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("score"))
    }

    func testFitnessObservationContractRejectsUnknownFutureWrongUnitAndOversizedPayloads() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let envelope = try fitnessEnvelope(at: now)
        let encoded = try envelope.encoded(now: now)

        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        unknown["unexpected"] = true
        let unknownData = try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
        XCTAssertThrowsError(try FitnessObservationEnvelope.decode(unknownData, now: now)) { error in
            XCTAssertEqual(error as? FitnessObservationContractError, .malformed)
        }

        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        future["generatedAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let futureData = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        XCTAssertThrowsError(try FitnessObservationEnvelope.decode(futureData, now: now)) { error in
            XCTAssertEqual(error as? FitnessObservationContractError, .futureTimestamp)
        }

        var wrongUnit = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var values = try XCTUnwrap(wrongUnit["metrics"] as? [[String: Any]])
        values[0]["unit"] = "seconds"
        wrongUnit["metrics"] = values
        let wrongUnitData = try JSONSerialization.data(withJSONObject: wrongUnit, options: [.sortedKeys])
        XCTAssertThrowsError(try FitnessObservationEnvelope.decode(wrongUnitData, now: now)) { error in
            XCTAssertEqual(error as? FitnessObservationContractError, .invalidValue)
        }

        let oversized = Data(repeating: 0x20, count: FitnessObservationEnvelope.maximumEncodedBytes + 1)
        XCTAssertThrowsError(try FitnessObservationEnvelope.decode(oversized, now: now)) { error in
            XCTAssertEqual(error as? FitnessObservationContractError, .oversized)
        }
    }

    func testFitnessObservationClientRequestIsBoundedPOSTAndCarriesNoCredentialHeaders() {
        let url = URL(string: "https://lifeos.example-tailnet.ts.net:8420/fitness/observation")!
        let body = Data(#"{"state":"observed"}"#.utf8)
        let request = TailscaleSyncClient.fitnessObservationRequest(url: url, body: body)

        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url, url)
        XCTAssertEqual(request?.httpBody, body)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        if let request {
            assertNoCredentialHeaders(request)
        }
        XCTAssertNil(TailscaleSyncClient.fitnessObservationRequest(
            url: url,
            body: Data(repeating: 0x20, count: FitnessObservationEnvelope.maximumEncodedBytes + 1)
        ))
    }

    func testFitnessObservationMappingIsDateAwareAndLeavesUnsupportedScoresUnavailable() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let envelope = try fitnessEnvelope(at: now)
        let snapshot = envelope.snapshot(for: now, now: now, calendar: calendar)

        XCTAssertEqual(snapshot.source.status, .connected)
        XCTAssertTrue(snapshot.healthMonitor[0].isValueAvailable)
        XCTAssertFalse(snapshot.healthMonitor[1].isValueAvailable)
        XCTAssertTrue(snapshot.healthMonitor[2].isValueAvailable)
        XCTAssertTrue(snapshot.sleep.isValueAvailable)
        XCTAssertEqual(snapshot.workouts.count, 1)
        XCTAssertFalse(snapshot.readiness.isValueAvailable)
        XCTAssertFalse(snapshot.strain.isValueAvailable)
        XCTAssertFalse(snapshot.stress.isValueAvailable)
        XCTAssertFalse(snapshot.energyReserve.isValueAvailable)

        let otherDay = calendar.date(byAdding: .day, value: -1, to: now)!
        let otherDaySnapshot = envelope.snapshot(for: otherDay, now: now, calendar: calendar)
        XCTAssertEqual(otherDaySnapshot.source.status, .connected)
        XCTAssertFalse(otherDaySnapshot.sleep.isValueAvailable)
        XCTAssertTrue(otherDaySnapshot.healthMonitor.allSatisfy { !$0.isValueAvailable })
        XCTAssertTrue(otherDaySnapshot.workouts.isEmpty)
    }

    func testFitnessObservationMappingPreservesStaleUnavailableAndFixtureStates() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let stale = try FitnessObservationEnvelope(
            state: .stale,
            generatedAt: now.addingTimeInterval(-16 * 60),
            observedAt: now.addingTimeInterval(-16 * 60)
        )
        let unavailable = try FitnessObservationEnvelope(
            state: .unavailable,
            generatedAt: now,
            observedAt: now
        )

        XCTAssertEqual(stale.snapshot(for: now, now: now).source.status, .stale)
        XCTAssertEqual(unavailable.snapshot(for: now, now: now).source.status, .unavailable)
        XCTAssertFalse(FitnessObservationSyncPolicy.allowsNetwork(usesVisualFixtures: true))
        XCTAssertTrue(FitnessObservationSyncPolicy.allowsNetwork(usesVisualFixtures: false))
    }
}
