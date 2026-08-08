import Foundation

public enum TailscaleSyncError: Error, Equatable, Sendable {
    case notConfigured
    case invalidServerURL
    case httpError(Int)
}

/// `URLSessionWebSocketTask` on this toolchain never delivers its handshake or `receive()`
/// completions -- not even a failure -- unless the owning `URLSession` has an actual
/// `URLSessionWebSocketDelegate` attached. Verified by isolated reproduction: identical
/// requests against `URLSession.shared` (no delegate) and a custom session with no delegate
/// both hang forever with zero callback, zero socket ever opened; the only difference that
/// fixed it was attaching this delegate. It doesn't need to do anything itself -- its mere
/// presence is what unblocks event delivery.
private final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate {}

/// Reads server URL / auth token from UserDefaults. Tailscale sync is opt-in:
/// if either key is unset/empty, calls simply no-op (fetch/push throw `.notConfigured`,
/// which callers are expected to treat as "sync disabled" rather than a real failure).
public actor TailscaleSyncClient {
    public static let serverURLDefaultsKey = "LifeOS.Sync.ServerURL"
    public static let tokenDefaultsKey = "LifeOS.Sync.Token"

    private let session: URLSession
    private let defaults: UserDefaults
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var listening = false
    private var onChange: ((String) -> Void)?

    private static let backoffSteps: [UInt64] = [2, 5, 15, 30] // seconds, capped

    public init(session: URLSession? = nil, defaults: UserDefaults = .standard) {
        self.session = session ?? URLSession(configuration: .default, delegate: WebSocketSessionDelegate(), delegateQueue: nil)
        self.defaults = defaults
    }

    public var isConfigured: Bool {
        !serverURLString.isEmpty && !token.isEmpty
    }

    private var serverURLString: String {
        defaults.string(forKey: Self.serverURLDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var token: String {
        defaults.string(forKey: Self.tokenDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func baseURL() throws -> URL {
        guard isConfigured else { throw TailscaleSyncError.notConfigured }
        guard let url = URL(string: serverURLString) else { throw TailscaleSyncError.invalidServerURL }
        return url
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
