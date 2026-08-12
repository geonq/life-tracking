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
    public static let serverURLDefaultsKey = "LifeOS.Sync.ServerURL"
    public static let approvedHostsInfoPlistKey = "LIFEOS_SYNC_APPROVED_HOSTS"
    public static let bearerKeychainService = "com.hermes.lifeos.sync"
    public static let bearerKeychainAccount = "transitional-gateway-bearer-v1"

    private let session: URLSession
    private let defaults: UserDefaults
    private let approvedHosts: Set<String>
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var listening = false
    private var onChange: ((String) -> Void)?

    private static let backoffSteps: [UInt64] = [2, 5, 15, 30] // seconds, capped
    private static let maximumReadOnlyResponseBytes = 1_048_576

    public init(defaults: UserDefaults = .standard) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration,
                                  delegate: StrictSyncSessionDelegate(),
                                  delegateQueue: nil)
        self.defaults = defaults
        self.approvedHosts = Self.configuredApprovedHosts()
    }

    public var isConfigured: Bool {
        Self.validatedServerURL(serverURLString, approvedHosts: approvedHosts) != nil
            && Self.readBearerFromKeychain() != nil
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

    public static func configuredApprovedHosts(bundle: Bundle = .main) -> Set<String> {
        guard let raw = bundle.object(forInfoDictionaryKey: approvedHostsInfoPlistKey) as? String,
              !raw.contains("$(") else { return [] }
        return Set(raw.split(separator: ",").compactMap { value in
            let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard host.hasSuffix(".ts.net"), host.count > ".ts.net".count,
                  URL(string: "https://\(host)")?.host == host else { return nil }
            return host
        })
    }

    public static func validatedServerURL(_ rawValue: String, approvedHosts: Set<String>) -> URL? {
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

    public static func validatedBearer(_ rawValue: String?) -> String? {
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

    // MARK: - Calendar

    public func fetchCalendar() async throws -> Data {
        let url = try baseURL().appendingPathComponent("calendar")
        let (data, response) = try await session.data(for: try request(url: url))
        try Self.checkHTTPStatus(response)
        return data
    }

    public func pushCalendar(_ data: Data) async throws {
        let url = try baseURL().appendingPathComponent("calendar")
        var request = try request(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try Self.checkHTTPStatus(response)
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
