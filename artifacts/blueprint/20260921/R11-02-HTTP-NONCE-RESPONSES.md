# R11 authenticated HTTP nonce renewal and response signatures

Planning-only. This sheet supersedes the nonce and response portions of R10-02. Challenge and health stay
special; every authenticated route after hello carries and signs a request nonce and a newly issued response nonce.

## Carrier and session state

```swift
public struct SyncHTTPResponseEnvelopeV6<Payload: Codable & Sendable>: Codable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let sessionID: UUID; public let requestID: UUID
 public let requestNonce: String; public let nextNonce: String; public let epoch: UInt64; public let payload: Payload
}
public struct SyncHTTPRequestStateV6: Sendable {
 public let sessionID: UUID; public let requestID: UUID; public let requestNonce: String; public let epoch: UInt64
 public let route: String; public let bodyHash: String
}
public struct SyncSessionNonceStateV6: Codable, Sendable {
 public let sessionID: UUID; public let currentNonce: String; public let epoch: UInt64
 public let expiresAt: Int64; public let lastRequestID: UUID?
}
```

Nonces are 32 random bytes encoded as unpadded base64url, exactly 43 characters, TTL 120 seconds, and
never reused within a session. Responses use headers `X-LifeOS-Session`, `X-LifeOS-Request-ID`,
`X-LifeOS-Request-Nonce`, `X-LifeOS-Next-Nonce`, `X-LifeOS-Epoch`, `X-LifeOS-Signature`; the body repeats
all five carrier values. `Content-Type`, `Content-Length`, `Cache-Control` and `X-Content-Type-Options` are
also signed. The signature header itself is excluded from the header list.

## Canonical response signature

`SyncHTTPV6.responseSigningBytes(status: Int, headers: [(String,String)], body: Data) throws -> Data`
returns `Frame("LifeOS/sync-http-response/v6", CanonicalJSON({status,headers,sessionID,requestID,
requestNonce,nextNonce,epoch,bodyHash}))`. `status` is a 3-digit integer; header names are lower-case,
trimmed single spaces are normalized, the signed list is sorted by name then value, duplicates are rejected,
and `bodyHash=hex(SHA256(rawBody))`. Canonical JSON uses sorted keys, no duplicate keys/nonfinite numbers,
NFC strings and decimal strings for UInt64 values. `Frame` is domain UTF-8, NUL, UInt32BE length, payload.

The exact client entry point is:

```swift
public enum SyncHTTPV6 {
 public static func verifyResponse(_ response: SyncHTTPResponseV6, for request: SyncHTTPRequestStateV6,
   trust: SyncTrustRecord) throws -> SyncHTTPResponseV6
 public static func responseSigningBytes(status: Int, headers: [(String,String)], body: Data) throws -> Data
}
public actor SyncSessionNonceStoreV6 {
 public func consumeResponse(_ response: SyncHTTPResponseV6, for request: SyncHTTPRequestStateV6) throws
 public func current(_ sessionID: UUID) throws -> SyncSessionNonceStateV6
}
```

## Transaction, retry and verification order

After hello, the server reserves the request nonce and request ID in its session store, executes the route,
generates `nextNonce`, signs the complete response, stores the response bytes and advances `currentNonce`
in one durable transaction, then sends. A retry with the same `(sessionID,requestID,requestNonce,bodyHash)`
returns the cached signed response byte-for-byte. A cancelled handler emits a signed 499 error and still
advances the nonce. Cancellation after send is a client-side cancellation only; the response remains durable.

The client checks raw body size/content type, required carrier headers, echoed session/request ID/nonce/epoch,
nonce shape and body equality before decoding; verifies the enrolled server key and response signature; then
atomically installs `nextNonce` only if the request state is current. `nonceMismatch` is the only signed recovery
case: after member/session verification the server atomically invalidates the stale current nonce, generates a
fresh recovery nonce, and carries that fresh value as `nextNonce`; it never reissues an older nonce. Missing,
replayed, expired, wrong-epoch or invalidly signed responses fail closed with `responseNonceMismatch`,
`responseReplay`, `responseEpochMismatch` or `responseSignatureInvalid`; no payload is projected. A valid
member request with a stale nonce receives signed 409 `nonceMismatch`; unauthenticated requests receive unsigned
401 with no nonce disclosure. The server never exposes a private key or bearer token to a route handler.

`POST /hello` returns the first `nextNonce` and establishes the state; `/exchange`, `/ack`, `/blob`, and
`/blob/read` use the common carrier on both success and typed error. `/challenge` and `/health` do not use a
session and never rotate a nonce. P01 owns canonical bytes/verification and P02 owns session persistence and
route responses. Any R10 handler without these response fields is a compile-time contract failure.
