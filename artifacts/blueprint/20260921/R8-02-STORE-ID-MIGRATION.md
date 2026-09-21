# R8 store-ID compatibility contract

Planning-only. R3 signed operations used UUID strings; R7 domain envelopes use `SyncStoreKind.rawValue`. The signed
operation bytes remain authoritative and are never rewritten during this migration.

## Versioned shapes

```swift
public enum SyncStoreIDEncodingV4: String, Codable, Sendable { case legacyUUIDV1, kindRawValueV2 }
public struct SyncStoreAliasV4: Codable, Equatable, Sendable {
 public let kind: SyncStoreKind; public let legacyStoreUUID: UUID; public let canonicalID: String
 public let aliasVersion: Int; public let aliasHash: String
}
public struct SyncStoreAliasTableV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let datasetID: String
 public let entries: [SyncStoreAliasV4]; public let tableHash: String
}
public struct SyncStoreAliasEnvelopeV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let datasetID: String
 public let table: SyncStoreAliasTableV4; public let ownerKeyID: String; public let signature: String
}
public struct SyncStoreReferenceV4: Codable, Equatable, Sendable {
 public let encoding: SyncStoreIDEncodingV4; public let rawID: String; public let kind: SyncStoreKind
 public let legacyStoreUUID: UUID?
}
public struct SyncStreamIDV4: Codable, Equatable, Sendable {
 public let kind: SyncStoreKind; public let storeUUID: UUID; public let originID: String
}
public struct SyncOperationCompatibilityV4: Codable, Equatable, Sendable {
 public let wireVersion: Int; public let signedOperationBase64URL: String; public let reference: SyncStoreReferenceV4
}
public enum SyncStoreIDMigrationError: Error, Sendable {
 case unknownLegacyUUID, unknownKind, aliasCollision, aliasHashMismatch, aliasSignatureInvalid
 case datasetMismatch, nonCanonicalID, signedBytesChanged, streamMismatch, checkpointMismatch
 case unsupportedEncoding, duplicateAlias, missingLegacyMapping
}
```

`canonicalID` is exactly `kind.rawValue`; `legacyStoreUUID` is the UUID already stored in the R3 envelope or stream
descriptor. The table has exactly 17 unique entries, sorted by `kind.rawValue`, and is persisted inside the V4 trust
record. The final `SyncAdapterEnvelopeV2` declaration gains exactly two required identity fields,
`storeIDEncoding: SyncStoreIDEncodingV4` and `aliasTableHash: String`; the bytes of the alias table are not duplicated
there. The envelope field is only a reference to the owner-signed table in `trust.json`, so there is no alias sidecar or
second store-ID authority. `aliasHash` and
`tableHash` use the R8-03 domain-framed derivations with their hash fields omitted from the preimage. Owner signing uses
`UTF8("LifeOS/store-alias/v4") + NUL + UInt32BE(C.count) + C`, with C the canonical envelope without `signature`.

Equivalent transported shapes use these exact JSON keys (Python and TypeScript must retain the strings):
```ts
type SyncStoreReferenceV4 = { encoding:"legacyUUIDV1"|"kindRawValueV2"; rawID:string;
  kind:string; legacyStoreUUID:string|null };
type SyncStoreAliasV4 = { kind:string; legacyStoreUUID:string; canonicalID:string;
  aliasVersion:number; aliasHash:string };
type SyncStreamIDV4 = { kind:string; storeUUID:string; originID:string };
type SyncOperationCompatibilityV4 = { wireVersion:1|2; signedOperationBase64URL:string;
  reference:SyncStoreReferenceV4 };
```
For `wireVersion == 1`, `signedOperationBase64URL` is the existing signed JSON with `storeID` equal to a lower-case
UUID; for `wireVersion == 2`, it is the same operation schema with `storeID == kind.rawValue` and the declared encoding.
V1 signature input is unchanged; V2 signs its own declared version. The compatibility frame is a projection, not a new
authority: a V1 operation is never decoded, re-encoded or re-signed merely to add `kind`.

The transport negotiation has one exact header shape:
```swift
public struct SyncHandshakeV4: Codable, Sendable {
 public let protocolVersion: Int; public let datasetID: String; public let originID: String
 public let storeIDEncoding: SyncStoreIDEncodingV4; public let aliasTableHash: String; public let nonce: String
}
public struct SyncRequestV4: Codable, Sendable {
 public let requestID: UUID; public let stream: SyncStreamIDV4; public let after: SyncFrontierPosition
 public let limit: UInt16; public let idempotencyKey: String; public let storeIDEncoding: SyncStoreIDEncodingV4
 public let aliasTableHash: String; public let signature: String
}
```
Handshake bytes are `Frame("LifeOS/sync-handshake/v4", CanonicalJSON(handshake))`; request bytes are
`Frame("LifeOS/sync-request/v4", CanonicalJSON(request without signature))`. Both signatures are Ed25519 by the enrolled
device key. A request is accepted only after dataset, nonce, alias hash, encoding and stream alias validation; retrying
the same `idempotencyKey` returns the original page/ACK and never advances a frontier twice.

## Deterministic migration

```swift
public enum SyncStoreIDResolver {
 public static func resolve(_ reference: SyncStoreReferenceV4, aliases: SyncStoreAliasTableV4)
   throws -> SyncStoreReferenceV4
 public static func projectLegacyOperation(_ bytes: Data, aliases: SyncStoreAliasTableV4)
   throws -> (original: Data, reference: SyncStoreReferenceV4)
 public static func migrateFrontier(_ frontier: SyncFrontier, aliases: SyncStoreAliasTableV4)
   throws -> SyncFrontierV4
 public static func validateCheckpoint(_ checkpoint: SyncCheckpoint, stream: SyncStreamIDV4) throws
}
public struct SyncFrontierV4: Codable, Equatable, Sendable {
 public let streams: [SyncFrontierStreamV4]
}
public struct SyncFrontierStreamV4: Codable, Equatable, Sendable {
 public let stream: SyncStreamIDV4; public let position: SyncFrontierPosition
}
```

On first upgrade, P01 reads each existing domain envelope's `storeUUID`; if it is absent, it reads the retained R3
stream descriptor. It creates the alias table in memory, verifies every UUID is one-to-one with the closed kind set,
then writes `SyncTrustRecordV4` and each `SyncAdapterEnvelopeV2` atomically. A genuinely new store may use
`deterministicStoreUUID(datasetID:kind:)` from R8-03, but an existing UUID is never replaced. Missing historical UUID is
`missingLegacyMapping`, not a guess. Migration preserves `through`, `acknowledgedThrough`, operation hashes and
checkpoint bytes exactly; only an index/projection gains the resolved kind.

The resolver verifies a V1 signature against the original bytes before lookup. It then maps UUID → kind and requires
that the wrapper kind, alias UUID and dataset agree. For V2 it maps kind → alias UUID and requires the declared
`legacyStoreUUID` when present. Duplicate kind/UUID, changed raw bytes, unknown alias, noncanonical UUID, mismatched
checkpoint stream or table hash aborts the transaction and leaves the old files untouched.

## Stream, checkpoint and transport behavior

`SyncStreamIDV4` is the frontier key; `SyncFrontierV4` is the only post-migration frontier representation. Its stream
array is sorted by `(kind.rawValue,storeUUID,originID)` and capped at eight. During a
single migration transaction, R3 UUID-keyed positions are translated to `SyncStreamIDV4` without changing sequence
values. `SyncCheckpoint` hashes continue to cover the original operation bytes and legacy UUID; the resolver checks the
alias rather than recomputing that signed hash. An unknown alias prevents advance and returns `checkpointMismatch`.

The handshake carries `storeIDEncoding`, `aliasTableHash`, dataset ID and protocol version. A V1 peer receives UUID
IDs and no alias table; a V2 peer receives kind IDs plus the owner-signed alias-table hash. `SyncRequestV4` signatures
include the negotiated encoding and alias hash. A hash mismatch, unsupported encoding or peer that changes encoding
mid-stream is rejected before any inbox write. Transport ACKs identify the stream by `(kind, storeUUID, originID)`;
retries reuse the operation idempotency key and never allocate a second sequence.

P01 owns the resolver and alias migration. P02 owns only HTTP/relay negotiation and must pass raw signed bytes through;
P03/P04/P13 adapters validate their own `kind/storeUUID` envelope before projection. `SyncEnvelopeMigrator` owns the
one-time file rewrite; rollback is the untouched pre-migration file and can be retried until every alias validates.

## Revision9 supersession

R9-04 replaces the one-time rewrite sentence with the durable 18-path journal, owner-signed fence, phase cursor,
mixed-set recovery and exact `SyncTrustStore` methods. R9-05 is authoritative for the signed handshake/HTTP carrier.
