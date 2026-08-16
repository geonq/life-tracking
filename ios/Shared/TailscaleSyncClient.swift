import Foundation

public enum TailscaleSyncError: Error, Equatable, Sendable {
    case notConfigured
    case invalidServerURL
    case invalidBarcode
    case invalidResponse
    case httpError(Int)
    case responseTooLarge
    case invalidInstitutionId
    case invalidRequisitionId
    case invalidConsentURL
    case requisitionAlreadyLinking
    case gatewayNotConfigured
}

/// The gateway's authoritative GoCardless requisition state for one consent
/// attempt. Rendered directly; never widened to "connected" client-side.
public enum BankConsentState: String, Equatable, Sendable {
    case created
    case linkOpened = "link_opened"
    case linked
    case expired
    case error
}

/// The one-time consent link returned by `POST /finance/connect`. The phone
/// never receives a GoCardless credential -- only an https consent URL to
/// open and an opaque requisition id to poll.
public struct BankConsentLink: Equatable, Sendable {
    public let consentUrl: URL
    public let requisitionId: String

    public init(consentUrl: URL, requisitionId: String) {
        self.consentUrl = consentUrl
        self.requisitionId = requisitionId
    }
}

/// A deliberately coarse connection result. It is safe to render because it
/// never carries a hostname, credential, response body, or underlying error text.
public enum TailscaleConnectionPreflightState: String, Equatable, Sendable {
    case reachable
    case configurationRequired = "configuration_required"
    case authenticationRejected = "authentication_rejected"
    case serverUnavailable = "server_unavailable"
    case networkUnavailable = "network_unavailable"
    case invalidResponse = "invalid_response"
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

/// Reads the private server URL from UserDefaults. Tailscale Serve supplies the
/// device identity to the loopback-only gateway; LifeOS deliberately does not
/// mint, store, or forward a bearer or any `Tailscale-User-*` header.
public actor TailscaleSyncClient {
    static let serverURLDefaultsKey = "LifeOS.Sync.ServerURL"
    static let approvedHostsInfoPlistKey = "LIFEOS_SYNC_APPROVED_HOSTS"

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
        Self.validatedServerURL(serverURLString, approvedHosts: approvedHosts) != nil
    }

    private var serverURLString: String {
        defaults.string(forKey: Self.serverURLDefaultsKey) ?? ""
    }

    private func baseURL() throws -> URL {
        guard !serverURLString.isEmpty else { throw TailscaleSyncError.notConfigured }
        guard let url = Self.validatedServerURL(serverURLString, approvedHosts: approvedHosts) else { throw TailscaleSyncError.invalidServerURL }
        return url
    }

    static func configuredApprovedHosts(bundle: Bundle = .main) -> Set<String> {
        guard let raw = bundle.object(forInfoDictionaryKey: approvedHostsInfoPlistKey) as? String,
              !raw.contains("$(") else { return [] }
        return Set(raw.split(separator: ",").compactMap { value in
            let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.validatedTailnetHost(host) != nil else { return nil }
            return host
        })
    }

    static func validatedServerURL(_ rawValue: String, approvedHosts: Set<String>) -> URL? {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !((0...0x1F).contains($0.value) || $0.value == 0x7F)
              }),
              !rawValue.contains("?"), !rawValue.contains("#") else { return nil }
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || components.port == 443 || components.port == 8420,
              let host = components.host?.lowercased(),
              Self.validatedTailnetHost(host) != nil,
              approvedHosts.contains(host) else { return nil }
        return components.url
    }

    private static func validatedTailnetHost(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty, rawValue.count <= 253,
              rawValue == rawValue.lowercased(),
              rawValue.hasSuffix(".ts.net"), rawValue.count > ".ts.net".count,
              rawValue.unicodeScalars.allSatisfy({ $0.value < 0x80 }) else { return nil }
        let labels = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3,
              labels.allSatisfy({ label in
                  guard (1...63).contains(label.count),
                        label.first?.isLetter == true || label.first?.isNumber == true,
                        label.last?.isLetter == true || label.last?.isNumber == true else { return false }
                  return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
              }) else { return nil }
        return rawValue
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

    /// GoCardless institution ids are short ASCII catalog keys sent in the
    /// consent-initiation body. Reuses the printable-ASCII, no-whitespace
    /// shape already proven for the Calendar idempotency key.
    static func validatedInstitutionId(_ rawValue: String) -> String? {
        guard (1...128).contains(rawValue.utf8.count),
              rawValue.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return rawValue
    }

    /// The gateway-issued requisition id is carried as a URL PATH component
    /// (not a query string: `validatedServerURL` rejects any `?`). Fails
    /// closed on anything that is not a simple printable-ASCII token so it
    /// can never be used to smuggle an extra path segment or traversal.
    static func validatedRequisitionId(_ rawValue: String) -> String? {
        guard (1...128).contains(rawValue.utf8.count),
              rawValue.unicodeScalars.allSatisfy({
                  $0.value < 0x80 && ($0.properties.isAlphabetic || ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "-" || $0 == "_")
              }) else { return nil }
        return rawValue
    }

    /// The bank consent URL is the one place this client ever opens a
    /// gateway-supplied destination in a browser. It must be https with a
    /// non-empty host and free of embedded credentials, control characters,
    /// or whitespace -- fail closed rather than open an unvetted URL.
    static func validatedConsentURL(_ rawValue: String) -> URL? {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !((0...0x1F).contains($0.value) || $0.value == 0x7F)
              }) else { return nil }
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    /// Builds a request for the verified Tailscale Serve origin. Authentication
    /// is supplied by the tailnet transport; the client deliberately adds no
    /// Authorization or Tailscale identity headers.
    nonisolated static func gatewayRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }

    nonisolated static func conditionalCalendarRequest(
        url: URL,
        body: Data,
        ifMatch: String,
        idempotencyKey: String
    ) -> URLRequest? {
        guard let etag = validatedCalendarETag(ifMatch),
              let key = validatedCalendarIdempotencyKey(idempotencyKey) else { return nil }
        var request = Self.gatewayRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    /// Builds the one POST this client ever issues: bank consent initiation.
    /// Still carries no Authorization or Tailscale identity header -- the
    /// tailnet transport is the only authentication boundary, unchanged from
    /// every read-only request.
    nonisolated static func bankConsentRequest(url: URL, institutionId: String) -> URLRequest? {
        guard let validatedId = validatedInstitutionId(institutionId),
              let body = try? JSONSerialization.data(withJSONObject: ["institutionId": validatedId]) else { return nil }
        var request = Self.gatewayRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    nonisolated static func contentLengthIsAllowed(_ rawValue: String?, maximumBytes: Int) -> Bool {
        guard let rawValue else { return true }
        guard let count = Int(rawValue), count >= 0 else { return false }
        return count <= maximumBytes
    }

    private func request(url: URL) -> URLRequest {
        Self.gatewayRequest(url: url)
    }

    private func calendarRequest(url: URL) -> URLRequest {
        request(url: url)
    }

    // MARK: - Calendar

    public func fetchCalendar() async throws -> Data {
        try await fetchCalendarResource().data
    }

    public func fetchCalendarResource() async throws -> CalendarRemoteResource {
        let url = try baseURL().appendingPathComponent("calendar")
        let (data, response) = try await calendarRequest(calendarRequest(url: url))
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
        guard let request = Self.conditionalCalendarRequest(
            url: url, body: data, ifMatch: ifMatch, idempotencyKey: idempotencyKey
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
        let (data, response) = try await session.data(for: request(url: url))
        try Self.checkHTTPStatus(response)
        return data
    }

    // MARK: - Read-only provider usage

    public func fetchUsage() async throws -> Data {
        try await fetchBoundedReadOnly(pathComponents: ["usage"])
    }

    /// Performs one bounded, read-only request through the same
    /// production boundary used by Usage. Cancellation returns no result so a
    /// disappearing or superseded view never renders a cancellation as a
    /// connection failure. The result intentionally contains no endpoint,
    /// credential, response body, or raw error description.
    public func checkConnection() async -> TailscaleConnectionPreflightState? {
        do {
            let url = try baseURL().appendingPathComponent("usage")
            let request = request(url: url)
            return await Self.performConnectionPreflight(session: session, request: request,
                                                         maximumBytes: Self.maximumReadOnlyResponseBytes)
        } catch {
            return Self.connectionPreflightState(for: error)
        }
    }

    nonisolated static func connectionPreflightState(for error: Error) -> TailscaleConnectionPreflightState? {
        guard !Self.isCancellation(error) else { return nil }
        if let syncError = error as? TailscaleSyncError {
            switch syncError {
            case .notConfigured, .invalidServerURL:
                return .configurationRequired
            case .httpError(401), .httpError(403):
                return .authenticationRejected
            case .httpError(let status) where status == 408 || status == 429 || (500...599).contains(status):
                return .serverUnavailable
            case .invalidBarcode, .invalidResponse, .responseTooLarge, .httpError,
                 .invalidInstitutionId, .invalidRequisitionId, .invalidConsentURL,
                 .requisitionAlreadyLinking, .gatewayNotConfigured:
                return .invalidResponse
            }
        }
        if error is URLError {
            return (error as? URLError)?.code == .timedOut ? .serverUnavailable : .networkUnavailable
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorTimedOut ? .serverUnavailable : .networkUnavailable
        }
        return .invalidResponse
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    nonisolated private static func performConnectionPreflight(
        session: URLSession,
        request: URLRequest,
        maximumBytes: Int
    ) async -> TailscaleConnectionPreflightState? {
        do {
            try Task.checkCancellation()
            _ = try await performBoundedReadOnly(session: session, request: request, maximumBytes: maximumBytes)
            try Task.checkCancellation()
            return .reachable
        } catch {
            return Self.connectionPreflightState(for: error)
        }
    }

#if DEBUG
    /// Test-only transport seam. It is omitted from Release builds so no
    /// production caller can inject an arbitrary session or endpoint.
    nonisolated static func performConnectionPreflightForTesting(
        session: URLSession,
        request: URLRequest,
        maximumBytes: Int = 1_048_576
    ) async -> TailscaleConnectionPreflightState? {
        await performConnectionPreflight(session: session, request: request, maximumBytes: maximumBytes)
    }
#endif

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

    /// Reads the Tailscale-identity-verified Python gateway route. The gateway, not the loopback-only
    /// Node API, owns `/finance/summary` and proxies it to `/api/finance/summary`.
    public func fetchFinanceSummary() async throws -> FinanceSummary {
        let data = try await fetchBoundedReadOnly(pathComponents: ["finance", "summary"])
        return try FinanceSummary.decode(data)
    }

    // MARK: - Bank consent initiation (the only mutating, parameterized gateway calls)

    /// Starts a GoCardless bank-consent requisition via the gateway's
    /// `POST /finance/connect`. The phone sends only the catalog institution
    /// id and receives back a one-time https consent URL plus an opaque
    /// requisition id -- never a GoCardless credential or access token.
    public func requestBankConsent(institutionId: String) async throws -> BankConsentLink {
        guard Self.validatedInstitutionId(institutionId) != nil else { throw TailscaleSyncError.invalidInstitutionId }
        let url = try baseURL().appendingPathComponent("finance/connect")
        guard let request = Self.bankConsentRequest(url: url, institutionId: institutionId) else {
            throw TailscaleSyncError.invalidInstitutionId
        }
        let (data, response) = try await boundedMutatingRequest(request)
        return try Self.parseBankConsentLinkResponse(data: data, response: response)
    }

    /// Polls the gateway for the current requisition state at
    /// `GET /finance/connect/status/<requisitionId>`. The id is carried as a
    /// path component (not a query string) because `validatedServerURL`
    /// rejects any URL containing `?`; it is validated the same way the
    /// Calendar idempotency key is before it is ever appended to a path.
    public func bankConsentStatus(requisitionId: String) async throws -> BankConsentState {
        guard let validatedId = Self.validatedRequisitionId(requisitionId) else {
            throw TailscaleSyncError.invalidRequisitionId
        }
        let data = try await fetchBoundedReadOnly(pathComponents: ["finance", "connect", "status", validatedId])
        return try Self.parseBankConsentStatusResponse(data: data)
    }

    /// Parses the consent-initiation response without performing I/O so the
    /// contract can be exercised by tests against the production boundary.
    /// 409 means a live requisition already exists; 503 means the gateway
    /// has no GoCardless key configured. Both fail closed with a typed,
    /// renderable error instead of a raw status/body.
    nonisolated static func parseBankConsentLinkResponse(data: Data, response: HTTPURLResponse) throws -> BankConsentLink {
        if response.statusCode == 409 { throw TailscaleSyncError.requisitionAlreadyLinking }
        if response.statusCode == 503 { throw TailscaleSyncError.gatewayNotConfigured }
        try checkHTTPStatus(response)
        guard data.count <= maximumReadOnlyResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawConsentUrl = object["consentUrl"] as? String,
              let rawRequisitionId = object["requisitionId"] as? String else {
            throw TailscaleSyncError.invalidResponse
        }
        guard let consentUrl = validatedConsentURL(rawConsentUrl) else { throw TailscaleSyncError.invalidConsentURL }
        guard let requisitionId = validatedRequisitionId(rawRequisitionId) else { throw TailscaleSyncError.invalidRequisitionId }
        return BankConsentLink(consentUrl: consentUrl, requisitionId: requisitionId)
    }

    /// Parses the status-poll response without performing I/O.
    nonisolated static func parseBankConsentStatusResponse(data: Data) throws -> BankConsentState {
        guard data.count <= maximumReadOnlyResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawState = object["state"] as? String,
              let state = BankConsentState(rawValue: rawState) else {
            throw TailscaleSyncError.invalidResponse
        }
        return state
    }

    /// Sends the one bounded, non-GET request this client ever issues. Mirrors
    /// the read-only bound (same byte cap, same Content-Length preflight) so
    /// the mutating path carries no weaker guarantee than the GET paths.
    nonisolated private static func performBoundedMutating(
        session: URLSession,
        request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TailscaleSyncError.invalidResponse }
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length")
        guard Self.contentLengthIsAllowed(declaredLength, maximumBytes: maximumBytes) else {
            throw TailscaleSyncError.responseTooLarge
        }
        let data = try await Self.collectBounded(bytes, maximumBytes: maximumBytes)
        return (data, http)
    }

    private func boundedMutatingRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Self.performBoundedMutating(session: session, request: request,
                                              maximumBytes: Self.maximumReadOnlyResponseBytes)
    }

    // MARK: - Read-only Clipper analytics

    /// Reads the Tailscale-identity-verified gateway route. The gateway owns
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
        return try await Self.performBoundedReadOnly(session: session, request: request(url: url),
                                                     maximumBytes: Self.maximumReadOnlyResponseBytes)
    }

    nonisolated private static func performBoundedReadOnly(
        session: URLSession,
        request: URLRequest,
        maximumBytes: Int
    ) async throws -> Data {
        guard request.httpMethod == "GET" else { throw TailscaleSyncError.invalidResponse }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TailscaleSyncError.invalidResponse }
        try Self.checkHTTPStatus(http)
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length")
        guard Self.contentLengthIsAllowed(declaredLength, maximumBytes: maximumBytes) else {
            throw TailscaleSyncError.responseTooLarge
        }
        return try await Self.collectBounded(bytes, maximumBytes: maximumBytes)
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

        let request = request(url: wsURL)
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
