import CryptoKit
import Foundation

private final class SyncNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public actor SyncTransport {
    private let identity: SyncIdentityStore
    private let session: URLSession
    private let delegate: SyncNoRedirectDelegate
    private let nonceStore: SyncSessionNonceStoreV6
    private var nonceByEndpoint: [String: SyncChallenge] = [:]
    private var v6SessionByEndpoint: [String: SyncSessionNonceStateV6] = [:]

    public init(identity: SyncIdentityStore, session: URLSession? = nil) {
        self.identity = identity
        self.nonceStore = SyncSessionNonceStoreV6()
        if let session {
            self.session = session
            self.delegate = SyncNoRedirectDelegate()
        } else {
            let delegate = SyncNoRedirectDelegate()
            self.delegate = delegate
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    public func exchange(_ request: Data, endpoint: SyncEndpoint) async throws -> Data {
        try await perform(route: .exchange, body: request, endpoint: endpoint, maximumResponseBytes: 2_097_152)
    }

    public func exchange(request: SyncExchangeRequest, endpoint: SyncEndpoint) async throws -> SyncExchangeResponse {
        let body = try SyncWireCodec.canonicalJSON(request, maximumBytes: SyncContractConstants.maxBodyBytes)
        let response = try await exchange(body, endpoint: endpoint)
        return try SyncWireCodec.decodeStrict(
            SyncExchangeResponse.self,
            from: response,
            maximumBytes: SyncContractConstants.maxBodyBytes,
            requiredKeys: ["schemaVersion", "storeID", "results", "operations", "acknowledgements", "upper", "more"],
            validate: { try Self.validate($0, endpoint: endpoint, expectedStoreID: request.storeID) }
        )
    }

    public func establishSession(endpoint: SyncEndpoint, hello: SyncHelloRequestV6) async throws -> SyncHelloResponseV6 {
        let challenge = try await challengeV6(for: endpoint)
        let epoch = try SyncContractValidation.requireUnsigned(endpoint.epoch, positive: true)
        let state = SyncSessionNonceStateV6(
            sessionID: challenge.sessionID,
            currentNonce: challenge.nonce,
            epoch: epoch,
            expiresAt: challenge.expiresAt,
            lastRequestID: nil
        )
        try await nonceStore.install(state)
        v6SessionByEndpoint[endpoint.id] = state
        let response: SyncHelloResponseV6 = try await performV6(
            route: .hello,
            tag: "hello",
            payload: hello,
            responseType: SyncHelloResponseV6.self,
            endpoint: endpoint,
            requestBytesCap: 32_768,
            responseBytesCap: 32_768
        )
        guard response.sessionID == challenge.sessionID,
              response.epoch == endpoint.epoch else {
            throw SyncFailure.responseEpochMismatch
        }
        return response
    }

    public func exchangeV6(request: SyncExchangeRequestV6, endpoint: SyncEndpoint) async throws -> SyncExchangeResponseV6 {
        try await performV6(
            route: .exchange,
            tag: "exchange",
            payload: request,
            responseType: SyncExchangeResponseV6.self,
            endpoint: endpoint,
            requestBytesCap: 2_097_152,
            responseBytesCap: 2_097_152
        )
    }

    public func acknowledgeV6(request: SyncAckRequestV6, endpoint: SyncEndpoint) async throws -> SyncAckResponseV6 {
        try await performV6(
            route: .ack,
            tag: "ack",
            payload: request,
            responseType: SyncAckResponseV6.self,
            endpoint: endpoint,
            requestBytesCap: 262_144,
            responseBytesCap: 262_144
        )
    }

    public func putAdministrativeBlob(_ request: AdminBlobPut20, endpoint: SyncEndpoint) async throws -> AdminBlobPutResult20 {
        try await performV6(
            route: .blob,
            tag: "admin.blob.put",
            payload: request,
            responseType: AdminBlobPutResult20.self,
            endpoint: endpoint,
            requestBytesCap: 524_288,
            responseBytesCap: 65_536
        )
    }

    public func readAdministrativeBlob(_ request: AdminBlobRead20, endpoint: SyncEndpoint) async throws -> AdminBlobReadResult20 {
        try await performV6(
            route: .blobRead,
            tag: "admin.blob.read",
            payload: request,
            responseType: AdminBlobReadResult20.self,
            endpoint: endpoint,
            requestBytesCap: 32_768,
            responseBytesCap: 524_288
        )
    }

    public func putObservation(_ request: ObservationPut20, endpoint: SyncEndpoint) async throws -> ObservationResult20 {
        try await performV6(
            route: .observation,
            tag: "observation.put",
            payload: request,
            responseType: ObservationResult20.self,
            endpoint: endpoint,
            requestBytesCap: 262_144,
            responseBytesCap: 262_144
        )
    }

    public func readObservation(_ request: ObservationRead20, endpoint: SyncEndpoint) async throws -> ObservationResult20 {
        try await performV6(
            route: .observationRead,
            tag: "observation.read",
            payload: request,
            responseType: ObservationResult20.self,
            endpoint: endpoint,
            requestBytesCap: 32_768,
            responseBytesCap: 262_144
        )
    }

    public func manageData(_ body: Data, endpoint: SyncEndpoint) async throws -> Data {
        try await perform(route: .dataManage, body: body, endpoint: endpoint, maximumResponseBytes: 65_536)
    }

    public func health(endpoint: SyncEndpoint) async throws -> SyncHealth {
        let url = try validatedURL(route: .health, endpoint: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = SyncHTTPMethod.get.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = try await receive(request: request, maximumBytes: 256, endpoint: endpoint)
        return try SyncWireCodec.decodeStrict(
            SyncHealth.self,
            from: body,
            maximumBytes: 256,
            requiredKeys: ["schemaVersion", "status"],
            validate: {
                try SyncContractValidation.requireSchema($0.schemaVersion)
                guard $0.status == "ok" else { throw SyncFailure.invalidInput }
            }
        )
    }

    private func challengeV6(for endpoint: SyncEndpoint) async throws -> SyncChallengeResponseV6 {
        let identity = try await self.identity.identity()
        let body = try SyncWireCodec.canonicalJSON(
            SyncChallengeRequestV6(datasetID: endpoint.datasetID, originID: identity.deviceID),
            maximumBytes: 1_024
        )
        let url = try validatedURL(route: .challenge, endpoint: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = SyncHTTPMethod.post.rawValue
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let response = try await receiveResponse(request: request, maximumBytes: 1_024, endpoint: endpoint)
        guard response.status == 200 else { throw response.status == 429 ? SyncFailure.busy : SyncFailure.malformedResponse }
        return try SyncWireCodec.decodeStrict(
            SyncChallengeResponseV6.self,
            from: response.body,
            maximumBytes: 1_024,
            requiredKeys: ["sessionID", "nonce", "expiresAt"],
            validate: {
                let nonce = try Data(syncBase64URL: $0.nonce)
                guard nonce.count == SyncContractConstants.maxNonceBytes else { throw SyncFailure.invalidInput }
                guard $0.expiresAt > 0 else { throw SyncFailure.invalidInput }
            }
        )
    }

    private func performV6<RequestPayload: Codable & Sendable, ResponsePayload: Codable & Sendable>(
        route: SyncHTTPRoute,
        tag: String,
        payload: RequestPayload,
        responseType: ResponsePayload.Type,
        endpoint: SyncEndpoint,
        requestBytesCap: Int,
        responseBytesCap: Int
    ) async throws -> ResponsePayload {
        guard route != .challenge, route != .health else { throw SyncFailure.invalidInput }
        guard let current = v6SessionByEndpoint[endpoint.id] else { throw SyncFailure.capabilityUnavailable }
        let requestID = UUID()
        let epoch = try SyncContractValidation.requireUnsigned(endpoint.epoch, positive: true)
        let envelope = SyncHTTPEnvelopeV6(
            schemaVersion: 6,
            tag: tag,
            sessionID: current.sessionID,
            requestID: requestID,
            requestNonce: current.currentNonce,
            epoch: epoch,
            payload: payload
        )
        let body = try SyncWireCodec.canonicalJSON(envelope, maximumBytes: requestBytesCap)
        let unsignedHeaders = [
            SyncHTTPHeader(name: "host", value: endpoint.approvedHost),
            SyncHTTPHeader(name: "content-type", value: "application/json; charset=utf-8"),
            SyncHTTPHeader(name: "accept", value: "application/json"),
            SyncHTTPHeader(name: "content-length", value: String(body.count)),
            SyncHTTPHeader(name: "x-lifeos-session", value: current.sessionID.uuidString.lowercased()),
            SyncHTTPHeader(name: "x-lifeos-request-id", value: requestID.uuidString.lowercased()),
            SyncHTTPHeader(name: "x-lifeos-nonce", value: current.currentNonce),
            SyncHTTPHeader(name: "x-lifeos-epoch", value: endpoint.epoch)
        ]
        let carrier = try await self.identity.signHTTP(method: "POST", route: route.rawValue, headers: unsignedHeaders, body: body)
        let carrierData = try SyncWireCodec.canonicalJSON(carrier, maximumBytes: 16_384)
        guard let carrierValue = String(data: carrierData, encoding: .utf8) else { throw SyncFailure.invalidInput }
        let headers = unsignedHeaders + [SyncHTTPHeader(name: "x-lifeos-signature", value: carrierValue)]
        let url = try validatedURL(route: route, endpoint: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let response = try await receiveResponse(request: request, maximumBytes: responseBytesCap, endpoint: endpoint)
        let trust = SyncTrustRecord(
            datasetID: endpoint.datasetID,
            epoch: endpoint.epoch,
            endpointID: endpoint.id,
            serverKeyID: endpoint.serverKeyID,
            serverPublicKey: endpoint.serverPublicKey,
            members: []
        )
        let requestState = SyncHTTPRequestStateV6(
            sessionID: current.sessionID,
            requestID: requestID,
            requestNonce: current.currentNonce,
            epoch: epoch,
            route: route.rawValue,
            bodyHash: SyncWireCodec.sha256(body)
        )
        let verified = try SyncHTTPV6.verifyResponse(
            SyncHTTPResponseV6(
                status: response.status,
                headers: response.headers,
                body: response.body
            ),
            for: requestState,
            trust: trust
        )
        try await nonceStore.consumeResponse(verified, for: requestState)
        v6SessionByEndpoint[endpoint.id] = try await nonceStore.current(current.sessionID)
        let decoded: SyncHTTPResponseEnvelopeV6<ResponsePayload> = try SyncWireCodec.decodeStrict(
            SyncHTTPResponseEnvelopeV6<ResponsePayload>.self,
            from: verified.body,
            maximumBytes: responseBytesCap,
            requiredKeys: ["schemaVersion", "tag", "sessionID", "requestID", "requestNonce", "nextNonce", "epoch", "payload"],
            validate: {
                guard $0.schemaVersion == 6,
                      $0.tag == tag,
                      $0.sessionID == current.sessionID,
                      $0.requestID == requestID,
                      $0.requestNonce == current.currentNonce,
                      $0.epoch == epoch else { throw SyncFailure.malformedResponse }
                guard try Data(syncBase64URL: $0.nextNonce).count == SyncContractConstants.maxNonceBytes else { throw SyncFailure.responseNonceMismatch }
            }
        )
        return decoded.payload
    }

    private func perform(route: SyncHTTPRoute, body: Data, endpoint: SyncEndpoint, maximumResponseBytes: Int) async throws -> Data {
        guard body.count <= requestCap(for: route) else { throw SyncFailure.capacity }
        let challenge = try await challenge(for: endpoint)
        let identity = try await self.identity.identity()
        let requestID = UUID().uuidString.lowercased()
        let frame = SyncSignedFrame(
            schemaVersion: 1,
            datasetID: endpoint.datasetID,
            epoch: endpoint.epoch,
            endpointID: endpoint.id,
            senderID: identity.deviceID,
            keyID: identity.keyID,
            requestID: requestID,
            nonce: challenge.nonce,
            method: SyncHTTPMethod.post.rawValue,
            path: route.rawValue,
            status: 0,
            body: body.syncBase64URL,
            bodyHash: SyncWireCodec.sha256(body),
            signature: ""
        )
        let signedFrame = try await self.identity.signFrame(frame)
        let frameData = try SyncWireCodec.encodeSignedFrame(signedFrame)
        guard frameData.count <= requestCap(for: route) else { throw SyncFailure.capacity }
        let url = try validatedURL(route: route, endpoint: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = SyncHTTPMethod.post.rawValue
        request.httpBody = frameData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(frameData.count), forHTTPHeaderField: "Content-Length")
        request.setValue(endpoint.datasetID, forHTTPHeaderField: "X-LifeOS-Dataset")
        request.setValue(endpoint.epoch, forHTTPHeaderField: "X-LifeOS-Epoch")
        let responseBody = try await receive(request: request, maximumBytes: maximumResponseBytes, endpoint: endpoint)
        let response = try SyncWireCodec.decodeStrict(
            SyncSignedFrame.self,
            from: responseBody,
            maximumBytes: maximumResponseBytes,
            requiredKeys: ["schemaVersion", "datasetID", "epoch", "endpointID", "senderID", "keyID", "requestID", "nonce", "method", "path", "status", "body", "bodyHash", "signature"],
            validate: { try SyncWireCodec.validate($0) }
        )
        guard response.requestID == requestID,
              response.nonce == challenge.nonce,
              response.datasetID == endpoint.datasetID,
              response.epoch == endpoint.epoch,
              response.endpointID == endpoint.id,
              response.senderID == endpoint.id,
              response.status >= 200, response.status < 300 else {
            throw response.status == 401 || response.status == 403 ? SyncFailure.unauthenticated : SyncFailure.malformedResponse
        }
        let serverKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(syncBase64URL: endpoint.serverPublicKey))
        try SyncWireCodec.verifyFrame(response, publicKey: serverKey)
        return try Data(syncBase64URL: response.body)
    }

    private func challenge(for endpoint: SyncEndpoint) async throws -> SyncChallenge {
        let key = endpoint.id
        if let current = nonceByEndpoint[key], current.expiresInSeconds > 0 {
            nonceByEndpoint[key] = nil
        }
        let requestBody = try SyncWireCodec.canonicalJSON(
            SyncChallengeRequest(schemaVersion: 1, datasetID: endpoint.datasetID, senderID: (try await identity.identity()).deviceID),
            maximumBytes: 1_024
        )
        let url = try validatedURL(route: .challenge, endpoint: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = SyncHTTPMethod.post.rawValue
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(requestBody.count), forHTTPHeaderField: "Content-Length")
        let body = try await receive(request: request, maximumBytes: 1_024, endpoint: endpoint)
        let challenge = try SyncWireCodec.decodeStrict(
            SyncChallenge.self,
            from: body,
            maximumBytes: 1_024,
            requiredKeys: ["schemaVersion", "nonce", "expiresInSeconds"],
            validate: {
                try SyncContractValidation.requireSchema($0.schemaVersion)
                let nonce = try Data(syncBase64URL: $0.nonce)
                guard nonce.count == 32, $0.expiresInSeconds == 120 else { throw SyncFailure.invalidInput }
            }
        )
        nonceByEndpoint[key] = challenge
        return challenge
    }

    private func receive(request: URLRequest, maximumBytes: Int, endpoint: SyncEndpoint) async throws -> Data {
        try await receiveResponse(request: request, maximumBytes: maximumBytes, endpoint: endpoint).body
    }

    private func receiveResponse(request: URLRequest, maximumBytes: Int, endpoint: SyncEndpoint) async throws -> SyncHTTPResponseV6 {
        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await session.bytes(for: request, delegate: delegate)
        } catch is CancellationError {
            throw SyncFailure.cancelled
        } catch {
            throw SyncFailure.offline
        }
        let bytes = result.0
        let response = result.1
        guard let http = response as? HTTPURLResponse else { throw SyncFailure.malformedResponse }
        guard (200...599).contains(http.statusCode) else { throw SyncFailure.malformedResponse }
        if let contentLength = http.value(forHTTPHeaderField: "Content-Length") {
            guard let length = Int(contentLength), length >= 0 else { throw SyncFailure.malformedResponse }
            guard length <= maximumBytes else { throw SyncFailure.responseTooLarge }
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";", maxSplits: 1).first.map(String.init)
        guard contentType == "application/json" else { throw SyncFailure.unsupportedMedia }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 32_768))
        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw SyncFailure.responseTooLarge
                }
                data.append(byte)
            }
        } catch let failure as SyncFailure {
            throw failure
        } catch is CancellationError {
            throw SyncFailure.cancelled
        } catch {
            throw SyncFailure.offline
        }
        let headers = http.allHeaderFields.compactMap { key, value -> SyncHTTPHeader? in
            guard let name = key as? String, let text = value as? String else { return nil }
            return SyncHTTPHeader(name: name, value: text)
        }
        return SyncHTTPResponseV6(status: http.statusCode, headers: headers, body: data)
    }

    private func validatedURL(route: SyncHTTPRoute, endpoint: SyncEndpoint) throws -> URL {
        guard endpoint.origin.scheme?.lowercased() == "https",
              endpoint.origin.user == nil,
              endpoint.origin.password == nil,
              endpoint.origin.query == nil,
              endpoint.origin.fragment == nil,
              endpoint.origin.host?.lowercased() == endpoint.approvedHost.lowercased(),
              endpoint.origin.path.isEmpty || endpoint.origin.path == "/" else {
            throw SyncFailure.endpointNotApproved
        }
        return endpoint.origin.appendingPathComponent(route.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func requestCap(for route: SyncHTTPRoute) -> Int {
        switch route {
        case .challenge: return 1_024
        case .hello: return 32_768
        case .exchange: return 2_097_152
        case .ack: return 262_144
        case .blob: return 524_288
        case .blobRead: return 32_768
        case .dataManage: return 65_536
        case .observation: return 262_144
        case .observationRead: return 32_768
        case .health: return 0
        }
    }

    private static func validate(
        _ response: SyncExchangeResponse,
        endpoint: SyncEndpoint,
        expectedStoreID: String
    ) throws {
        try SyncContractValidation.requireSchema(response.schemaVersion)
        try SyncContractValidation.requireUUID(response.storeID)
        guard response.results.count <= 128,
              response.operations.count <= 128,
              response.acknowledgements.count <= 128 else { throw SyncFailure.capacity }
        try SyncWireCodec.validate(response.upper)
        try SyncWireCodec.verifyResponseRecords(response, endpoint: endpoint, expectedStoreID: expectedStoreID)
    }

    private static func validate(_ value: AdminBlobPutResult20) throws {
        try SyncContractValidation.requireSchema(value.schemaVersion)
        try SyncContractValidation.requireHash(value.blobHash)
    }

    private static func validate(_ value: AdminBlobReadResult20) throws {
        try SyncContractValidation.requireSchema(value.schemaVersion)
        try SyncContractValidation.requireHash(value.blobHash)
        try SyncContractValidation.requireHash(value.chunkHash)
        _ = try SyncContractValidation.requireBase64URL(value.bytesBase64URL, maximumDecodedBytes: 262_144)
    }

    private static func validate(_ value: ObservationResult20) throws {
        try SyncContractValidation.requireSchema(value.schemaVersion)
        try SyncContractValidation.requireUUID(value.datasetID)
        try SyncContractValidation.requireUUID(value.originID)
        if let observation = value.observation {
            try SyncWireCodec.validate(observation)
        }
    }
}

private extension Data {
    var syncBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(syncBase64URL value: String) throws {
        self = try SyncContractValidation.requireBase64URL(value)
    }
}
