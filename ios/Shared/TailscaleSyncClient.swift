import Foundation
import Security

public enum TailscaleSyncError: Error, Equatable, Sendable {
    case notConfigured
    case invalidServerURL
    case invalidBarcode
    case invalidResponse
    case httpError(Int)
    case responseTooLarge
}

public enum CalendarSyncError: Error, Equatable, Sendable {
    case missingIfMatch
    case missingETag
    case malformedETag
    case invalidIdempotencyKey
    case calendarConflict(data: Data, etag: String)
}

public struct CalendarRemoteResource: Equatable, Sendable {
    public let data: Data
    public let etag: String

    public init(data: Data, etag: String) {
        self.data = data
        self.etag = etag
    }
}

/// `URLSessionWebSocketTask` on this toolchain never delivers its handshake or `receive()`
/// completions -- not even a failure -- unless the owning `URLSession` has an actual
/// `URLSessionWebSocketDelegate` attached. Verified by isolated reproduction: identical
/// requests against `URLSession.shared` (no delegate) and a custom session with no delegate
/// both hang forever with zero callback, zero socket ever opened; the only difference that
/// fixed it was attaching this delegate. It doesn't need to do anything itself -- its mere
/// presence is what unblocks event delivery.
final class StrictSyncSessionDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The configured private endpoint is canonical, so any redirect is treated as
        // a configuration failure instead of silently crossing a trust boundary.
        completionHandler(nil)
    }
}

/// Reads the private server URL from UserDefaults and the temporary gateway bearer
/// read-only from Keychain. LifeOS deliberately exposes no credential writer or UI.
/// This compatibility path remains required until the gateway enforces Tailscale node
/// identity and its negative peer tests pass.
public actor TailscaleSyncClient {
    static let serverURLDefaultsKey = "LifeOS.Sync.ServerURL"
    static let approvedHostsInfoPlistKey = "LIFEOS_SYNC_APPROVED_HOSTS"
    static let bearerKeychainService = "com.hermes.lifeos.sync"
    static let bearerKeychainAccount = "transitional-gateway-bearer-v1"

    private let session: URLSession
    private let defaults: UserDefaults
    private let approvedHosts: Set<String>
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var listening = false
    private var onChange: ((String) -> Void)?

    private static let backoffSteps: [UInt64] = [2, 5, 15, 30] // seconds, capped
    private static let maximumReadOnlyResponseBytes = 1_048_576
    static let maximumCalendarResourceBytes = 256 * 1024
    static let calendarTimeout: TimeInterval = 8

    public init(
        defaults: UserDefaults = .standard
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = Self.calendarTimeout
        configuration.timeoutIntervalForResource = Self.calendarTimeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration,
                                  delegate: StrictSyncSessionDelegate(),
                                  delegateQueue: nil)
        self.defaults = defaults
        self.approvedHosts = Self.configuredApprovedHosts()
    }

    public var isConfigured: Bool {
        guard Self.validatedServerURL(serverURLString, approvedHosts: approvedHosts) != nil else { return false }
        return Self.readBearerFromKeychain() != nil
    }

    private var serverURLString: String {
        defaults.string(forKey: Self.serverURLDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func baseURL() throws -> URL {
        guard !serverURLString.isEmpty else { throw TailscaleSyncError.notConfigured }
        guard let url = Self.validatedServerURL(serverURLString, approvedHosts: approvedHosts) else { throw TailscaleSyncError.invalidServerURL }
        return url
    }

    private func bearer() throws -> String {
        guard let bearer = Self.readBearerFromKeychain() else {
            throw TailscaleSyncError.notConfigured
        }
        return bearer
    }

    static func configuredApprovedHosts(bundle: Bundle = .main) -> Set<String> {
        guard let raw = bundle.object(forInfoDictionaryKey: approvedHostsInfoPlistKey) as? String,
              !raw.contains("$(") else { return [] }
        return Set(raw.split(separator: ",").compactMap { value in
            let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard host.hasSuffix(".ts.net"), host.count > ".ts.net".count,
                  URL(string: "https://\(host)")?.host == host else { return nil }
            return host
        })
    }

    static func validatedServerURL(_ rawValue: String, approvedHosts: Set<String>) -> URL? {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || components.port == 443 || components.port == 8420,
              let host = components.host?.lowercased(), approvedHosts.contains(host),
              host.hasSuffix(".ts.net"), host.count > ".ts.net".count else { return nil }
        return components.url
    }

    static func validatedBearer(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ["replace-me", "changeme", "token", "your-token", "[redacted]"]
        guard (32...512).contains(value.utf8.count), value == rawValue,
              !placeholders.contains(value.lowercased()),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !value.contains("$("), !value.contains("${") else { return nil }
        return value
    }

    /// ETags are treated as opaque strong quoted values. Weak tags, lists,
    /// escaped quotes, controls, and unquoted values fail closed.
    static func validatedCalendarETag(_ rawValue: String?) -> String? {
        guard let rawValue, rawValue.count >= 3, rawValue.first == "\"", rawValue.last == "\"",
              rawValue.unicodeScalars.dropFirst().dropLast().allSatisfy({
                  $0.value >= 0x21 && $0.value <= 0x7E && $0.value != 0x22 && $0.value != 0x5C
              }) else { return nil }
        return rawValue
    }

    static func validatedCalendarIdempotencyKey(_ rawValue: String?) -> String? {
        guard let rawValue, (1...128).contains(rawValue.utf8.count),
              rawValue.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return rawValue
    }

    /// A fixed, read-only lookup. The app never creates, updates, deletes, logs, or
    /// exposes this item. Asking for every match lets an unexpected ambiguous result
    /// fail closed instead of choosing an arbitrary credential.
    nonisolated static func readBearerFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: bearerKeychainService,
            kSecAttrAccount: bearerKeychainAccount,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let matches = result as? [Data], matches.count == 1,
              let value = String(data: matches[0], encoding: .utf8) else { return nil }
        return validatedBearer(value)
    }

    nonisolated static func authenticatedRequest(url: URL, bearer: String) -> URLRequest? {
        guard let bearer = validatedBearer(bearer) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated static func conditionalCalendarRequest(
        url: URL,
        bearer: String,
        body: Data,
        ifMatch: String,
        idempotencyKey: String
    ) -> URLRequest? {
        guard let etag = validatedCalendarETag(ifMatch),
              let key = validatedCalendarIdempotencyKey(idempotencyKey),
              var request = authenticatedRequest(url: url, bearer: bearer) else { return nil }
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    nonisolated static func contentLengthIsAllowed(_ rawValue: String?, maximumBytes: Int) -> Bool {
        guard let rawValue else { return true }
        guard let count = Int(rawValue), count >= 0 else { return false }
        return count <= maximumBytes
    }

    private func request(url: URL) throws -> URLRequest {
        guard let request = Self.authenticatedRequest(url: url, bearer: try bearer()) else {
            throw TailscaleSyncError.notConfigured
        }
        return request
    }

    private func calendarRequest(url: URL) throws -> URLRequest {
        try request(url: url)
    }

    // MARK: - Calendar

    public func fetchCalendar() async throws -> Data {
        try await fetchCalendarResource().data
    }

    public func fetchCalendarResource() async throws -> CalendarRemoteResource {
        let url = try baseURL().appendingPathComponent("calendar")
        let (data, response) = try await calendarRequest(try calendarRequest(url: url))
        return try Self.parseCalendarFetchResponse(data: data, response: response)
    }

    /// Kept as a compatibility trap for old callers: Calendar PUT is never
    /// allowed without both an authoritative ETag and stable idempotency key.
    public func pushCalendar(_ data: Data) async throws {
        throw CalendarSyncError.missingIfMatch
    }

    @discardableResult
    public func pushCalendar(_ data: Data, ifMatch: String, idempotencyKey: String) async throws -> CalendarRemoteResource {
        guard Self.validatedCalendarETag(ifMatch) != nil else { throw CalendarSyncError.malformedETag }
        guard Self.validatedCalendarIdempotencyKey(idempotencyKey) != nil else { throw CalendarSyncError.invalidIdempotencyKey }
        guard data.count <= Self.maximumCalendarResourceBytes, Self.isCalendarJSON(data) else {
            throw data.count > Self.maximumCalendarResourceBytes ? TailscaleSyncError.responseTooLarge : TailscaleSyncError.invalidResponse
        }
        let url = try baseURL().appendingPathComponent("calendar")
        let bearer = try bearer()
        guard let request = Self.conditionalCalendarRequest(
            url: url, bearer: bearer, body: data, ifMatch: ifMatch, idempotencyKey: idempotencyKey
        ) else { throw TailscaleSyncError.notConfigured }
        let (responseData, response) = try await calendarRequest(request)
        return try Self.parseCalendarPushResponse(data: responseData, response: response)
    }

    /// Parses a successful Calendar GET without performing I/O. Kept internal so
    /// tests can prove the response boundary without introducing a production
    /// transport/credential injection seam.
    nonisolated static func parseCalendarFetchResponse(data: Data, response: HTTPURLResponse) throws -> CalendarRemoteResource {
        guard data.count <= maximumCalendarResourceBytes else { throw TailscaleSyncError.responseTooLarge }
        try checkHTTPStatus(response)
        guard let etag = validatedCalendarETag(response.value(forHTTPHeaderField: "ETag")) else {
            throw response.value(forHTTPHeaderField: "ETag") == nil ? CalendarSyncError.missingETag : CalendarSyncError.malformedETag
        }
        guard isCalendarJSON(data) else { throw TailscaleSyncError.invalidResponse }
        return CalendarRemoteResource(data: data, etag: etag)
    }

    /// Parses a Calendar PUT result without performing I/O. Conflict responses
    /// must carry authoritative valid truth; ordinary non-2xx responses are
    /// surfaced as HTTP errors even when they intentionally have no ETag/body.
    nonisolated static func parseCalendarPushResponse(data: Data, response: HTTPURLResponse) throws -> CalendarRemoteResource {
        if response.statusCode == 412 || response.statusCode == 428 {
            guard data.count <= maximumCalendarResourceBytes else { throw TailscaleSyncError.responseTooLarge }
            let rawETag = response.value(forHTTPHeaderField: "ETag")
            guard let etag = validatedCalendarETag(rawETag) else {
                throw rawETag == nil ? CalendarSyncError.missingETag : CalendarSyncError.malformedETag
            }
            guard isCalendarJSON(data) else { throw TailscaleSyncError.invalidResponse }
            throw CalendarSyncError.calendarConflict(data: data, etag: etag)
        }

        try checkHTTPStatus(response)
        guard data.count <= maximumCalendarResourceBytes else { throw TailscaleSyncError.responseTooLarge }
        let rawETag = response.value(forHTTPHeaderField: "ETag")
        guard let etag = validatedCalendarETag(rawETag) else {
            throw rawETag == nil ? CalendarSyncError.missingETag : CalendarSyncError.malformedETag
        }
        guard isCalendarJSON(data) else { throw TailscaleSyncError.invalidResponse }
        return CalendarRemoteResource(data: data, etag: etag)
    }

    private func calendarRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TailscaleSyncError.invalidResponse }
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length")
        guard Self.contentLengthIsAllowed(declaredLength, maximumBytes: Self.maximumCalendarResourceBytes) else {
            throw TailscaleSyncError.responseTooLarge
        }
        let data = try await Self.collectBounded(bytes, maximumBytes: Self.maximumCalendarResourceBytes)
        return (data, http)
    }

    nonisolated private static func isCalendarJSON(_ data: Data) -> Bool {
        guard data.count <= maximumCalendarResourceBytes,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemaVersion = value["schemaVersion"] as? Int,
              schemaVersion == 1,
              value["items"] is [Any] else { return false }
        return true
    }

    // MARK: - Tax documents (bonus; mechanical GET/POST parity with calendar)

    public func fetchDocuments() async throws -> Data {
        let url = try baseURL().appendingPathComponent("documents")
        let (data, response) = try await session.data(for: try request(url: url))
        try Self.checkHTTPStatus(response)
        return data
    }

    // MARK: - Read-only provider usage

    public func fetchUsage() async throws -> Data {
        try await fetchBoundedReadOnly(pathComponents: ["usage"])
    }

    /// Read-only barcode lookup. The gateway is expected to authenticate the
    /// tailnet request and proxy this path to the loopback Node API's
    /// `/api/nutrition/barcode/{canonical}` route. No provider request is made
    /// by the phone and no raw upstream payload crosses this boundary.
    public func fetchNutritionBarcode(_ input: String) async throws -> NutritionBarcodeLookup {
        guard let barcode = NutritionBarcodeNormalizer.normalize(input) else { throw TailscaleSyncError.invalidBarcode }
        let data = try await fetchBoundedReadOnly(pathComponents: ["nutrition", "barcode", barcode])
        do {
            return try JSONDecoder().decode(NutritionBarcodeLookup.self, from: data)
        } catch {
            throw TailscaleSyncError.invalidResponse
        }
    }

    // MARK: - Read-only finance summary

    /// Reads the authenticated Python gateway route. The gateway, not the loopback-only
    /// Node API, owns `/finance/summary` and proxies it to `/api/finance/summary`.
    public func fetchFinanceSummary() async throws -> FinanceSummary {
        let data = try await fetchBoundedReadOnly(pathComponents: ["finance", "summary"])
        return try FinanceSummary.decode(data)
    }

    // MARK: - Read-only Clipper analytics

    /// Reads the authenticated gateway route. The gateway owns
    /// `/clipper/summary` and remains unavailable until a reviewed provider
    /// connector supplies the provider-neutral snapshot; the client never
    /// scrapes a platform or accepts provider credentials.
    public func fetchClipperSnapshot() async throws -> ClipperSnapshot {
        let data = try await fetchBoundedReadOnly(pathComponents: ["clipper", "summary"])
        return try ClipperSnapshot.decode(data)
    }

    private func fetchBoundedReadOnly(pathComponents: [String]) async throws -> Data {
        let url = try pathComponents.reduce(baseURL()) { partial, component in
            partial.appendingPathComponent(component)
        }
        let (bytes, response) = try await session.bytes(for: try request(url: url))
        try Self.checkHTTPStatus(response)
        let declaredLength = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length")
        guard Self.contentLengthIsAllowed(declaredLength, maximumBytes: Self.maximumReadOnlyResponseBytes) else {
            throw TailscaleSyncError.responseTooLarge
        }
        return try await Self.collectBounded(bytes, maximumBytes: Self.maximumReadOnlyResponseBytes)
    }

    nonisolated static func collectBounded<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumBytes: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(max(maximumBytes, 0), 64 * 1024))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw TailscaleSyncError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    // MARK: - Change stream

    /// Starts listening on /ws for change notifications, invoking `onChange` with the
    /// message `type` string ("calendar_changed" / "documents_changed") for each frame.
    /// Reconnects with capped exponential backoff on drop. No-ops if not configured.
    public func connectChangeStream(onChange: @escaping (String) -> Void) {
        guard isConfigured else { return }
        self.onChange = onChange
        guard !listening else { return }
        listening = true
        reconnectAttempt = 0
        startSocket()
    }

    public func stopChangeStream() {
        listening = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func startSocket() {
        guard listening, let base = try? baseURL() else { return }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        components.path += components.path.hasSuffix("/") ? "ws" : "/ws"
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let wsURL = components.url else { return }

        guard let request = try? request(url: wsURL) else { return }
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        receiveNext()
    }

    private func receiveNext() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handleReceive(result) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            reconnectAttempt = 0
            if case .string(let text) = message, let type = Self.messageType(from: text) {
                onChange?(type)
            }
            receiveNext()
        case .failure:
            webSocketTask = nil
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard listening else { return }
        let index = min(reconnectAttempt, Self.backoffSteps.count - 1)
        let delaySeconds = Self.backoffSteps[index]
        reconnectAttempt += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            await self?.startSocket()
        }
    }

    private static func messageType(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["type"] as? String
    }

    private static func checkHTTPStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else { throw TailscaleSyncError.httpError(http.statusCode) }
    }
}
