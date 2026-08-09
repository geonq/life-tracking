import Foundation

public enum TailscaleSyncError: Error, Equatable, Sendable {
    case notConfigured
    case invalidServerURL
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
private final class StrictSyncSessionDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Authorization must never cross a redirect boundary. The configured private
        // endpoint is canonical, so any redirect is treated as a configuration failure.
        completionHandler(nil)
    }
}

/// Reads server URL / auth token from UserDefaults. Tailscale sync is opt-in:
/// if either key is unset/empty, calls simply no-op (fetch/push throw `.notConfigured`,
/// which callers are expected to treat as "sync disabled" rather than a real failure).
public actor TailscaleSyncClient {
    public static let serverURLDefaultsKey = "LifeOS.Sync.ServerURL"
    public static let tokenDefaultsKey = "LifeOS.Sync.Token"
    public static let approvedHostsInfoPlistKey = "LIFEOS_SYNC_APPROVED_HOSTS"

    private let session: URLSession
    private let defaults: UserDefaults
    private let approvedHosts: Set<String>
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var listening = false
    private var onChange: ((String) -> Void)?

    private static let backoffSteps: [UInt64] = [2, 5, 15, 30] // seconds, capped
    private static let maximumReadOnlyResponseBytes = 1_048_576

    public init(defaults: UserDefaults = .standard,
                approvedHosts: Set<String> = TailscaleSyncClient.configuredApprovedHosts()) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(
            configuration: configuration,
            delegate: StrictSyncSessionDelegate(),
            delegateQueue: nil
        )
        self.defaults = defaults
        self.approvedHosts = approvedHosts
    }

    public var isConfigured: Bool {
        Self.validatedServerURL(serverURLString, approvedHosts: approvedHosts) != nil && Self.validatedToken(token) != nil
    }

    private var serverURLString: String {
        defaults.string(forKey: Self.serverURLDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var token: String {
        defaults.string(forKey: Self.tokenDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func baseURL() throws -> URL {
        guard !serverURLString.isEmpty, !token.isEmpty else { throw TailscaleSyncError.notConfigured }
        guard let url = Self.validatedServerURL(serverURLString, approvedHosts: approvedHosts) else { throw TailscaleSyncError.invalidServerURL }
        guard Self.validatedToken(token) != nil else { throw TailscaleSyncError.notConfigured }
        return url
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

    public static func validatedToken(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ["replace-me", "changeme", "token", "your-token", "[redacted]"]
        guard value.count >= 32, !placeholders.contains(value.lowercased()),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !value.contains("$("), !value.contains("${") else { return nil }
        return value
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Calendar

    public func fetchCalendar() async throws -> Data {
        let url = try baseURL().appendingPathComponent("calendar")
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try Self.checkHTTPStatus(response)
        return data
    }

    public func pushCalendar(_ data: Data) async throws {
        let url = try baseURL().appendingPathComponent("calendar")
        var request = authorizedRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try Self.checkHTTPStatus(response)
    }

    // MARK: - Tax documents (bonus; mechanical GET/POST parity with calendar)

    public func fetchDocuments() async throws -> Data {
        let url = try baseURL().appendingPathComponent("documents")
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try Self.checkHTTPStatus(response)
        return data
    }

    // MARK: - Read-only provider usage

    public func fetchUsage() async throws -> Data {
        try await fetchBoundedReadOnly(pathComponents: ["usage"])
    }

    // MARK: - Read-only finance summary

    /// Reads the authenticated Python gateway route. The gateway, not the loopback-only
    /// Node API, owns `/finance/summary` and proxies it to `/api/finance/summary`.
    public func fetchFinanceSummary() async throws -> FinanceSummary {
        let data = try await fetchBoundedReadOnly(pathComponents: ["finance", "summary"])
        return try FinanceSummary.decode(data)
    }

    private func fetchBoundedReadOnly(pathComponents: [String]) async throws -> Data {
        let url = try pathComponents.reduce(baseURL()) { partial, component in
            partial.appendingPathComponent(component)
        }
        let (bytes, response) = try await session.bytes(for: authorizedRequest(url: url))
        try Self.checkHTTPStatus(response)
        if let expected = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"),
           let count = Int(expected), count > Self.maximumReadOnlyResponseBytes {
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

        let request = authorizedRequest(url: wsURL)
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
