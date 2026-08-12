import XCTest
@testable import LifeOS

final class TailscaleSyncClientSecurityTests: XCTestCase {
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
}
