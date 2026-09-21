# R10 HTTP carrier contracts

Planning-only. R10 supersedes the route/framing clauses of R3-01 and R9-05. P02 receives only a
verified carrier produced by P01; it must not infer a body layout, signature location or session
rule.

## Common envelope and headers

```swift
public struct SyncHTTPEnvelopeV6<Payload: Codable & Sendable>: Codable, Sendable {
 public let schemaVersion: Int       // exactly 6
 public let tag: String              // route tag, exact lowercase ASCII
 public let sessionID: UUID          // challenge allocates it; hello promotes it
 public let requestID: UUID          // unique per attempt
 public let nonce: String            // 32-byte random value, base64url
 public let epoch: String            // enrolled epoch, 1...128 ASCII
 public let payload: Payload
}
public struct SyncDetachedSignatureCarrierV6: Codable, Sendable {
 public let algorithm: String        // exactly "Ed25519"
 public let keyID: String            // 1...128 ASCII
 public let signedBytesHash: String  // 64 lowercase hex characters
 public let signatureBase64URL: String
}
public struct VerifiedHTTPFrameV6: Sendable {
 public let method: String; public let route: String
 public let sessionID: UUID; public let requestID: UUID; public let nonce: String
 public let epoch: String; public let body: Data; public let memberKeyID: String
}
public struct SyncHTTPResponseV6: Sendable {
 public let status: Int; public let headers: [(String,String)]; public let body: Data
}
```

Authenticated requests require exactly one each of `Host`, `Content-Type`, `Accept`, `Content-Length`,
`X-LifeOS-Session`, `X-LifeOS-Request-ID`, `X-LifeOS-Nonce`, `X-LifeOS-Epoch` and
`X-LifeOS-Signature`; `Content-Type` is `application/json; charset=utf-8`, `Content-Encoding` is
absent, and `Transfer-Encoding` is rejected. Header values are ASCII, case-normalized, and the
header/body UUID, nonce and epoch must be byte-for-byte equal. `Cache-Control: no-store` and
`X-Content-Type-Options: nosniff` are response headers. `Idempotency-Key` is forbidden; operation
hash plus mutation ID is the durable idempotency identity.

The signature header is base64url of canonical JSON for `SyncDetachedSignatureCarrierV6`. The exact
signed bytes are:

`Frame("LifeOS/sync-http/v6", CanonicalJSON({method,route,contentType,sessionID,requestID,nonce,epoch,bodyHash}))`

where `bodyHash=hex(SHA256(rawBody))`, `Frame` is ASCII domain + NUL + UInt32BE(payload byte count)
+ payload, and `CanonicalJSON` is UTF-8, sorted keys, no whitespace, no duplicate keys, no NaN/
infinity, decimal UInt64 strings, and NFC strings. The carrier signature is Ed25519 over those bytes;
`signedBytesHash` is SHA-256 of those bytes. Raw body bytes must equal canonical encoding of its
decoded envelope. Blob bytes are base64url inside JSON and are therefore covered too.

## Route layouts and hard limits

|Method/path|Body envelope payload|Request/response raw cap|session/auth|
|---|---|---:|---|
|`POST /replication/v1/challenge`|`SyncChallengeRequestV6` / `SyncChallengeResponseV6`|1 KiB|unsigned issuance only|
|`POST /replication/v1/hello`|`SyncHelloRequestV6` / `SyncHelloResponseV6`|32 KiB|challenge nonce + signed|
|`POST /replication/v1/exchange`|`SyncExchangeRequestV6` / `SyncExchangeResponseV6`|2 MiB|signed|
|`POST /replication/v1/ack`|`SyncAckRequestV6` / `SyncAckResponseV6`|256 KiB|signed|
|`POST /replication/v1/blob`|`SyncBlobPutRequestV6` / `SyncBlobPutResponseV6`|512 KiB|signed|
|`POST /replication/v1/blob/read`|`SyncBlobReadRequestV6` / `SyncBlobReadResponseV6`|64 KiB|signed|
|`GET /replication/v1/health`|empty / `SyncHealthResponseV6`|256 bytes|no session/signature|

Challenge is the only unsigned POST: it returns a session reference and one-use nonce, but no identity
or domain data. Its request/response are standalone canonical JSON, not `SyncHTTPEnvelopeV6`. The
hello request uses that `sessionID` and nonce; a successful hello keeps the same session ID and adds
the authenticated member/epoch. All later authenticated decoded envelopes are <=1 MiB and all domain
blobs <=32 MiB over repeated chunks.
The exchange has at most 64 submitted operations and 128 returned operations; ACK arrays are <=128;
blob `chunkBytes` is <=262,144. Headers total <=32 KiB. Health has no query, request body, identity
or epoch and returns only fixed `schemaVersion=6,status="ok"`.

## Exact payloads

```swift
public struct SyncChallengeRequestV6: Codable, Sendable {
 public let datasetID: String; public let originID: String
}
public struct SyncChallengeResponseV6: Codable, Sendable {
 public let sessionID: UUID; public let nonce: String; public let expiresAt: Int64
}
public struct SyncHelloRequestV6: Codable, Sendable {
 public let datasetID: String; public let originID: String; public let storeEncoding: String
 public let aliasTableHash: String; public let supportedSchemas: [Int]; public let capabilities: [String]
}
public struct SyncHelloResponseV6: Codable, Sendable {
 public let sessionID: UUID; public let serverOriginID: String; public let epoch: String
 public let aliasTableHash: String; public let expiresAt: Int64; public let capabilities: [String]
}
public struct SyncExchangeRequestV6: Codable, Sendable {
 public let streamID: String; public let after: SyncFrontier?; public let limit: UInt16
 public let submit: [SyncOperation]
}
public struct SyncOperationAdmissionV6: Codable, Sendable {
 public let operationHash: String; public let mutationID: UUID; public let disposition: String
 public let receiptID: UUID?
}
public struct SyncExchangeResponseV6: Codable, Sendable {
 public let accepted: [SyncOperationAdmissionV6]; public let operations: [SyncOperation]
 public let next: SyncFrontier?; public let hasMore: Bool
}
public struct SyncAckRequestV6: Codable, Sendable { public let ack: SyncAck }
public struct SyncAckResponseV6: Codable, Sendable { public let ack: SyncAck; public let acceptedAt: Int64 }
public struct SyncBlobPutRequestV6: Codable, Sendable {
 public let storeID: String; public let blobHash: String; public let totalBytes: UInt64
 public let offset: UInt64; public let chunkHash: String; public let bytesBase64URL: String
 public let isFinal: Bool
}
public struct SyncBlobPutResponseV6: Codable, Sendable {
 public let blobHash: String; public let nextOffset: UInt64; public let complete: Bool
}
public struct SyncBlobReadRequestV6: Codable, Sendable {
 public let storeID: String; public let blobHash: String; public let offset: UInt64; public let limit: UInt32
}
public struct SyncBlobReadResponseV6: Codable, Sendable {
 public let blobHash: String; public let offset: UInt64; public let bytesBase64URL: String
 public let chunkHash: String; public let isFinal: Bool
}
public struct SyncHealthResponseV6: Codable, Sendable { public let schemaVersion: Int; public let status: String }
public enum SyncHTTPV6 {
 public static func verifyRequest(method: String, route: String, headers: [(String,String)], body: Data,
   trust: SyncTrustRecord) throws -> VerifiedHTTPFrameV6
 public static func signResponse(status: Int, route: String, request: VerifiedHTTPFrameV6,
   body: Data, member: SyncMember) throws -> SyncHTTPResponseV6
 public static func canonicalSigningBytes(method: String, route: String, headers: [(String,String)],
   body: Data) throws -> Data
}
public enum ReplicationHTTPV6 {
 public static func handle(_ frame: VerifiedHTTPFrameV6) async throws -> SyncHTTPResponseV6
 public static func issueChallenge(_ request: SyncChallengeRequestV6) throws -> SyncHTTPResponseV6
 public static func health() -> SyncHTTPResponseV6
 public static func hello(_ request: SyncHelloRequestV6, frame: VerifiedHTTPFrameV6) async throws -> SyncHTTPResponseV6
 public static func exchange(_ request: SyncExchangeRequestV6, frame: VerifiedHTTPFrameV6) async throws -> SyncHTTPResponseV6
 public static func acknowledge(_ request: SyncAckRequestV6, frame: VerifiedHTTPFrameV6) async throws -> SyncHTTPResponseV6
 public static func putBlob(_ request: SyncBlobPutRequestV6, frame: VerifiedHTTPFrameV6) async throws -> SyncHTTPResponseV6
 public static func readBlob(_ request: SyncBlobReadRequestV6, frame: VerifiedHTTPFrameV6) async throws -> SyncHTTPResponseV6
}
```

`tag` is respectively `hello`, `exchange`, `ack`, `blob.put`, `blob.read`, and `health`; the
challenge has no envelope tag. Response envelopes echo request ID/session/nonce/epoch and carry the
route response payload. `SyncFrontier`,
`SyncOperation` and `SyncAck` keep their R3/R7 validated wire fields. A blob put validates offset,
total, decoded bytes and chunk hash before writing; overlapping bytes with a different hash are
`409 conflict`, while an identical retry returns the prior `nextOffset`.

## Verification, dispatch and errors

P01 exposes `SyncHTTPV6.verifyRequest(method:route:headers:body:trust:) throws -> VerifiedHTTPFrameV6`,
`SyncHTTPV6.signResponse(status:route:request:body:member:) throws -> SyncHTTPResponseV6`, and
`SyncHTTPV6.canonicalSigningBytes(method:route:headers:body:) throws -> Data`. P02 exposes
`ReplicationHTTPV6.handle(_ frame: VerifiedHTTPFrameV6) async throws -> SyncHTTPResponseV6`,
`ReplicationHTTPV6.issueChallenge(_ request: SyncChallengeRequestV6) throws -> SyncHTTPResponseV6`,
`ReplicationHTTPV6.health() -> SyncHTTPResponseV6`, and route functions `hello`, `exchange`,
`acknowledge`, `putBlob`, `readBlob` with the matching V6 payloads. These are the only
HTTP-to-engine entry points.

Verification order is: reject method/path/duplicate headers; stream-check length, MIME, host and cap;
decode the detached carrier; recompute raw-body hash and canonical signing bytes; verify a current,
non-revoked member key; compare `signedBytesHash`; reserve the one-use nonce under the session fence;
decode and cross-check the envelope; validate route payload/bounds; then dispatch. Health skips all
authenticated steps and returns the fixed unsigned response. P02 maps malformed carrier/body to 400,
signature/trust failures to 401/403, replay/session/epoch mismatch to 409, unsupported schema/media
to 422/415, size to 413, busy to 429, offline/timeout to 503/504 and disk-full to 507. Authenticated
errors are signed with the same request identity; untrusted errors contain only fixed code text.

The nonce is consumed even when handler work is cancelled or fails. A retry obtains a fresh challenge,
request ID and nonce but resubmits the same immutable operation hash. No handler reads a user-supplied
member, session or epoch after verification.

The Python gateway boundary uses the same field names and bytes:
`validate_http_frame(method: str, route: str, headers: Sequence[tuple[str,str]], body: bytes,
trust: SyncTrustRecord) -> VerifiedHTTPFrameV6`, `handle(frame: VerifiedHTTPFrameV6) ->
SyncHTTPResponseV6`, `issue_challenge(request: SyncChallengeRequestV6) -> SyncHTTPResponseV6` and
`health() -> SyncHTTPResponseV6`. TypeScript may generate transport types from these exact JSON keys;
the header sequence preserves duplicate arrivals until P01 rejects them, and it may not introduce a
second envelope or signature format. JSON responses always set the exact JSON
MIME, `Content-Length`, `Cache-Control:no-store` and `X-Content-Type-Options:nosniff` headers.

## R11 supersession

R10-02 remains historical request/carrier context. R11-02 is final for authenticated response envelopes,
per-route nonce renewal, response signature bytes and client/server retry semantics; R11-03 is final for route
caps. In a conflict, R11 requires raw response caps of 524,288 for `/blob/read`, decoded chunks of 262,144,
and the R11 response carrier on every authenticated route.
