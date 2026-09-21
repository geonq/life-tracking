# R9 signed handshake and HTTP carrier

Planning-only. This sheet supersedes the R8-02 handshake signature shorthand. P01 owns canonical values, byte
framing and verification; P02 owns HTTP extraction, route/body binding and status mapping; P17 only forwards bytes.

## Exact envelope and carrier

```swift
public struct SyncHandshakeBodyV5: Codable, Sendable {
 public let schemaVersion: Int; public let protocolVersion: Int; public let datasetID: String; public let originID: String
 public let epoch: String; public let storeIDEncoding: SyncStoreIDEncodingV4; public let aliasTableHash: String
 public let nonce: String; public let requestID: UUID; public let issuedAt: Date; public let expiresAt: Date
 public let capabilities: [String]
}
public struct SyncHandshakeEnvelopeV5: Codable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let body: SyncHandshakeBodyV5
 public let signerKeyID: String; public let signature: String
}
public struct SyncDetachedSignatureCarrierV5: Codable, Sendable {
 public let schemaVersion: Int; public let algorithm: String; public let keyID: String
 public let signedBytesHash: String; public let signature: String
}
public struct SyncHTTPFrameV5: Codable, Sendable {
 public let schemaVersion: Int; public let method: String; public let route: String; public let contentType: String
 public let requestID: UUID; public let nonce: String; public let epoch: String; public let bodyHash: String
 public let bodyBase64URL: String
}
public struct VerifiedHTTPFrameV5: Sendable {
 public let frame: SyncHTTPFrameV5; public let body: Data; public let member: SyncMember
 public let handshake: SyncHandshakeEnvelopeV5
}
public enum SyncHandshakeErrorV5: Error, Sendable {
 case missingSignature, invalidSignature, unknownKey, revokedKey, replay, expiredNonce, expiredHandshake
 case datasetMismatch, epochMismatch, aliasMismatch, encodingMismatch, routeBodyMismatch
 case signedBytesHashMismatch, duplicateHeader, malformedCarrier, unsupportedAlgorithm, capacity, unsupportedMedia
}
public struct SyncHTTPResponseV5: Sendable { public let status: Int; public let body: Data; public let signed: Bool }
```

The handshake envelope is the canonical JSON body for `/replication/v1/hello`; the HTTP signature is detached in the
single `X-LifeOS-Signature` header containing canonical `SyncDetachedSignatureCarrierV5`. Header JSON is base64url,
not a second JSON parser input. `algorithm` is the literal `Ed25519`; key IDs are lower-case SHA-256 of raw public-key
bytes. `capabilities` is sorted unique ASCII strings, maximum 32; IDs are bounded by the existing R4 values.
`issuedAt/expiresAt` use UTC milliseconds and the lifetime is 120 seconds, checked against the challenge's monotonic
boot generation rather than trusting remote wall-clock ordering.

Inner handshake signing bytes are
`Frame("LifeOS/sync-handshake/v5",CanonicalJSON(body))`, where
`Frame(label,C)=UTF8(label)+0x00+UInt32BE(byteCount(C))+C`. The detached HTTP signing bytes are
`Frame("LifeOS/sync-http-frame/v5",CanonicalJSON({schemaVersion,method,route,contentType,requestID,nonce,epoch,
bodyHash}))`. `bodyHash=hex(SHA256(exact request body bytes))`; `signedBytesHash` is SHA-256 of the detached signing
bytes. The header's `signature` verifies those bytes with `keyID`; the envelope's `signature` verifies the inner bytes.
No signature is computed over a parsed/re-encoded body, URL-normalized route or decoded Unicode variant.

`bodyBase64URL` is an in-memory/fixture representation of the exact raw body for cross-language transport tests. It is
never accepted as a second on-wire body field; P02 computes it from the received bytes and treats `bodyHash` as the
authoritative commitment.

Equivalent Python/TypeScript shapes are exact mirrors: `SyncHandshakeBodyV5` has the 14 JSON keys above with
`issuedAt/expiresAt` strings; `SyncHandshakeEnvelopeV5` has `schemaVersion,tag,body,signerKeyID,signature`;
`SyncDetachedSignatureCarrierV5` has `schemaVersion,algorithm,keyID,signedBytesHash,signature`; and
`SyncHTTPFrameV5` has `schemaVersion,method,route,contentType,requestID,nonce,epoch,bodyHash,bodyBase64URL`.
Python uses frozen dataclasses and bytes only after base64url decoding; TypeScript uses readonly fields and branded
lower-case-hex/base64url strings. Neither calls a generic JSON parser before the restricted scanner.

## Relationship to the existing signed frame

R4's `SyncWireCodec.decodeSignedFrame(_ bytes:expected:trust:)` remains the operation/ACK/blob body verifier, but its
v5 signature is supplied as the detached carrier. Its final signature is
`decodeSignedFrame(body: Data, detached: SyncDetachedSignatureCarrierV5, expected: FrameExpectation,
trust: SyncTrustRecord) throws -> SyncSignedFrame`. The old inline `signature` member is accepted only by the
version-1 compatibility decoder; v5 rejects both an inline signature and a duplicate signature header. The existing
route/body checks remain: exact method/path, `Content-Type: application/json; charset=utf-8`, `bodyHash`, request ID,
nonce, endpoint and epoch are checked before the route-specific body decoder. The handshake adds the inner envelope
signature; it does not replace operation signatures or permit the relay to sign an operation.

## Verification and call path

The Python boundary is `validate_http_frame(method: str, route: str, headers: Mapping[str, str], body: bytes,
trust: SyncTrustRecord) -> VerifiedHTTPFrameV5`; Swift calls
`SyncWireCodec.decodeSignedFrame(body:detached:expected:trust:) throws -> SyncSignedFrame`. P02 handler signatures are
`hello(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`, `exchange(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`,
`acknowledge(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`, `put_blob(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`
and `read_blob(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`.

`P02.validate_http_frame(method,route,headers,body,trust) -> VerifiedHTTPFrameV5` performs, in order: (1) reject
unknown method/path, duplicate auth/framing headers, wrong host/content type or body over 2 MiB; (2) decode exactly one
detached carrier and require algorithm/key/hash lengths; (3) construct the canonical detached bytes from the raw method,
route, content type, request ID, nonce, epoch and raw body hash; (4) verify the current non-revoked member key; (5)
compare `signedBytesHash`; (6) reserve the one-use challenge nonce; (7) decode `SyncHandshakeEnvelopeV5`, verify its
inner signer key is the same enrolled origin and verify inner bytes; (8) check dataset, epoch, alias hash, encoding,
request ID and 120-second expiry; (9) decode the route-specific exchange/ACK/blob body; (10) pass only the immutable
`VerifiedHTTPFrameV5` to `SyncEngine`/`ReplicationStore`. No domain or nonce state is touched before step 6.

P01's exact public functions are `SyncWireCodec.handshakeSigningBytes(_:) throws -> Data`,
`SyncWireCodec.httpSigningBytes(_:) throws -> Data`, `SyncWireCodec.verifyHandshake(_:,trust:) throws -> SyncMember`
and `SyncWireCodec.verifyDetached(_:,bytes:member:) throws`. P02's exact functions are
`validate_http_frame(method: str, route: str, headers: Mapping[str, str], body: bytes, trust: SyncTrustRecord) -> VerifiedHTTPFrameV5`,
`issue_challenge(request: SyncChallengeRequest) -> SyncHTTPResponseV5`,
`hello(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`, `exchange(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`,
`acknowledge(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`, `put_blob(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`
and `read_blob(frame: VerifiedHTTPFrameV5) -> SyncHTTPResponseV5`; handlers receive `VerifiedHTTPFrameV5`, never a
user-supplied member object.

## Closed failures and retry

Map `missingSignature, invalidSignature, unknownKey, revokedKey` to unsigned/signed `401 unauthenticated`; `replay,
expiredNonce, expiredHandshake` to `409 replay`; `datasetMismatch, epochMismatch, aliasMismatch, encodingMismatch` to
`409 membershipMismatch`; `routeBodyMismatch, signedBytesHashMismatch, duplicateHeader, malformedCarrier` to `400
invalidInput`; `unsupportedAlgorithm` to `422 unsupportedSchema`; size/content failures to `413 capacity` or `415
unsupportedMedia`; busy/disk-full use existing `429/507`. Unauthenticated replies contain only the fixed unsigned
code; authenticated errors are signed v5 frames. A retry uses a fresh challenge/request ID/nonce but the same durable
operation hash and idempotency identity. A failed or cancelled authenticated request still consumes its nonce.

## Revision10 supersession

R10-02 is final for every HTTP route carrier, header/body layout, canonical bytes, verification order
and P02 dispatch/error mapping.
