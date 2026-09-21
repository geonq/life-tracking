# R20-05 — observation routes in the authenticated transport

Supersedes R10/R11 closed-route omission and R4-15 Frame(...) shorthand; preserves SignedHealthObservation's original signed bytes.
P01 DTO/codec/SyncTransport; P02 gateway replication.py/main.py and mac-relay/main.py; P11 publisher in HealthKitAdapter.swift.
P16 composes publisher; P11 HealthKitProductionBridge.swift only calls it on iOS. No second health history store or receipt key usage.

## Authoritative route union

All paths below start /replication/v1; suffix shown is exact, no trailing slash/query/alias/redirect.

|method/suffix|tag|request/response raw caps|authentication|
|---|---|---|---|
|POST /challenge|none|1024/1024|R10 challenge rate limit, no user data|
|POST /hello|hello|32768/32768|R10 request/R11 response and current enrolled member|
|POST /exchange|exchange|2097152/2097152|current permitted replication member|
|POST /ack|ack|262144/262144|current permitted receipt signer|
|POST /blob|blob.put or admin.blob.put|524288/65536|replicated store OR R20-02 admin admission, never both|
|POST /blob/read|blob.read or admin.blob.read|32768/524288|matching scoped authorization|
|POST /data/manage|data.manage|65536/65536|Windows app admin capability, R20-01/03 actions|
|POST /observation|observation.put|262144/262144|selected iPhone app origin + health projection access|
|POST /observation/read|observation.read|32768/262144|enrolled app with health projection read access|
|GET /health|health|0/256|fixed unsigned R10 health body|

This union is final over R19's statement that ONLY data/manage extends the route list. No other route is added.
R11 decoded blob chunk cap262144, exchange cap1048576 and ordinary route payload caps retained.
Observation decoded body<=131072; signed wrapper<=180224; full observation payload<=196608; header total32768.
131072 raw bytes ->174763 unpadded base64url chars; wrapper/outer metadata<=16384 ->191147<262144. Check each cap before allocation.
If existing FitnessObservationEnvelope exceeds128KiB reject capacity; never drop selected fields to create a misleading snapshot.

## Exact request/response payloads

`ObservationPut20={schemaVersion:20,datasetID:UUID,observation:SignedHealthObservation}`.
`ObservationRead20={schemaVersion:20,datasetID:UUID,originID:UUID}`.
`ObservationResult20={schemaVersion:20,datasetID:UUID,originID:UUID,observation:SignedHealthObservation?}`.
Both put and read return ObservationResult20; put requires nonnull; read permits explicit null ONLY verified absence for selected authorized origin.
Unknown/missing/extra keys, wrong version, omitted nullable field, JSON body null alone, unverified HTTP204 or empty body are invalid.
Preserve original SignedHealthObservation exactly: schemaVersion1,datasetID,originID,keyID,sequence,body,bodyHash,signature.
sequence is canonical unsigned decimal string, base64url body is opaque exact FitnessObservationEnvelope.encoded() bytes, bodyHash raw SHA256.
Inner signature remains R4-08 F("LifeOS/observation/v1",CJ(wrapper without top-level signature)); no R20 resigning of original content.
Response originID/datasetID must equal request, nested values must agree; inner keyID must match selected origin's authorized app key.
Outer request is SyncHTTPEnvelopeV6<ObservationPut20/ObservationRead20> with exact tags above and epoch U64 as R11.
Outer response is SyncHTTPResponseEnvelopeV6<ObservationResult20>; no nested old SyncSignedFrame or duplicate Frame wrapper.
R10 detached request signature covers method/path/contentType/session/request/nonce/epoch/raw body hash; R11 response signature covers headers/status/body.
All required identity headers must match envelope. Both outer server/relay signature and inner iPhone signature must verify before projection.
Nested signature retention is exact; canonicalizing outer JSON cannot rewrite raw body bytes or change inner decoded payload hash.

## Concrete API and signature permissions

`SyncTransport.putObservation(_ request:ObservationPut20,endpoint:SyncEndpoint) async throws -> ObservationResult20`.
`SyncTransport.readObservation(_ request:ObservationRead20,endpoint:SyncEndpoint) async throws -> ObservationResult20`.
P02 `put_observation(request:ObservationPut20,frame:VerifiedHTTPFrameV6)` and `read_observation(request:ObservationRead20,frame:VerifiedHTTPFrameV6)` return SyncHTTPResponseV6.
Both gateway and Mac relay use these declarations, R11 session persistence, and the existing observations SQLite cache table.
P01 SyncIdentityStore app role may sign HTTP frame on these two exact paths plus inner observation for its own selected iPhone identity.
Owner role cannot sign observation/frame; receiptOwner/receiptDevice cannot sign HTTP or observation; relay cannot create inner iPhone records.
Relay signer CLI may sign outer authenticated RESPONSE frame for these paths only through existing typed frame validation, status/body/session verified.
Windows storing signer has same response permission; neither may rewrite/sign a different inner observation as origin.
Mac reader app can sign read request but cannot upload another device's observation by claiming its origin; authenticated sender must equal upload origin.
Use `ObservationAccess20={schemaVersion:20,datasetID:UUID,epoch:U64,originID:UUID,originKeyID:H,readerKeyIDs:[H],ownerKeyID:H,signature:Data}`.
At most8 unique readers, sorted keyID; origin is current applying member and every reader current applying member. Explicit setup includes selected iPhone.
Owner signs F("LifeOS/observation-access/v20",CJ(policy without signature)); P01 adds typed SyncIdentityStore.signObservationAccess(policy), owner role only.
This is a separate typed policy signature, not a new generic SyncSignedKind/CLI sign permission. Size<=2048 bytes.
SyncTrustRecord local container gains required nullable observationAccess20; owner pin verifies policy, epoch/dataset must equal current trust.
Persist via SyncTrustStore.installObservationAccess(policy) under trust writer fence; local operator/explicit setup import only, no network policy installation route.
Old trust container decodes with its ORIGINAL codec, migrates local container by adding null policy without rewriting membership/signatures; null denies both routes.
Key rotation/epoch update invalidates old policy until freshly owner-signed; historical policy cannot authorize a live request.
Read requires sender key in readerKeyIDs and requested origin equal originID; put requires sender=originID/keyID. No implicit all-member health permission.
P16 supplies foreground selected-iPhone/reader confirmation; P17 imports policy to existing protected gateway trust; P02 relay uses same owner-signed policy.
Do not infer origin or access from displayName/discovery/query body, possession of Tailscale credentials, or an unsigned config change.
Hello capability adds observation.v20; absent capability->unsupported, retain pending, do not fall back to unsigned endpoint.

## Nonce transaction, cache and cancellation

Use R11 request reservation and durable response+nextNonce for EVERY success/error, including nullable read and stale-sequence put.
An identical session/request/nonce/body retry returns identical cached signed bytes and same nextNonce; no second mutation or fresh nonce on cached replay.
New attempt after expiry/new session uses a fresh nonce/requestID but same inner signed observation; its sequence/bodyHash owns data idempotency.
Server compares sequence numerically (8-byte big-endian SQLite key), never lexical text or wall-clock observedAt.
Higher sequence: validate original signature/body/domain bounds, commit latest observation before response success.
Equal sequence/equal signed content: no-op; equal sequence/different body/signature identity ->409 idCollision; lower sequence returns stored latest, not submitted stale echo.
Put result must be nonnull and sequence>=submitted. Selected-origin mismatch/revoked identity ->403; bad signature401; malformed400; oversize413.
Read performs serialized cache snapshot; no row ->authenticated explicit null; corrupt row503, never null; offline/timeouts throw.
Crash after observation commit before response cache: reserved request recovery reexecutes idempotent put/read then persists one new signed response/nonce before send.
Crash after response cache commit: replay cached exact bytes. No half-advanced nonce state may accept a different body for old requestID.
Cancellation before effect yields signed R11 499 with nextNonce; after commit complete success or recover durable state, never pretend persisted observation was rolled back.
Client installs nextNonce only after outer verification under request fence; then verifies inner before touching UI/cache. Inner failure blocks projection and surfaces invalid observation.
Publisher clears pending only for same current sequence/bodyHash; higher returned valid sequence advances local allocator under actor, preserves newer local source for re-publication.
Task cancellation/generation changes after await cannot clear a newer pending record. R4-15 coalescing and file durability rules remain.

## Outage and reconcile ownership

HealthKit source/anchor remains iPhone local. Mac/Windows cache is replaceable read-only observation; no tombstone/replicated store/ACK frontier introduced.
Windows reconnection uses selected iPhone publisher and verified cache reconciliation, not an unauthorized Mac app origin impersonation.
Mac may display cached verified latest while Windows unavailable via enrolled relay; stale labels use original observation time/provenance.
P11 publisher signs on iPhone only (#if os(iOS)); P01/P02 transport/read DTOs compile cross-platform without HealthKit imports.
P16 Mac composition reads through SyncTransport and validates existing FitnessObservationEnvelope before display; never instantiates a HealthKit writer.
Planned checks: authenticated null, cache corruption, altered inner signature, stale put, equal-sequence conflict, lost responses/nonce, relay signer misuse, outage return.
Physical HealthKit/Zepp comparison and SDK compilation remain execution evidence; this transport does not claim proprietary Zepp accuracy.
