# HTTP, authentication and exact failures
P01 client; P02 handlers. All endpoints exact, no query, suffix aliases, redirect or path normalization.
No bearer cookies/UserDefaults secrets. TLS exact enrolled origin + independently signed operation/frame.

|Method/path|Input|Output|Authentication|
|---|---|---|---|
|POST /replication/v1/challenge|SyncChallengeRequest|SyncChallenge|No domain access; only one-use nonce issuance|
|POST /replication/v1/hello|Frame(SyncHelloRequest)|Frame(SyncHelloResponse)|Current enrolled signer|
|POST /replication/v1/exchange|Frame(SyncExchangeRequest)|Frame(SyncExchangeResponse)|Current enrolled signer|
|POST /replication/v1/ack|Frame(SyncAck)|Frame(SyncAck)|Signer must equal receipt replicaID; returns same accepted receipt|
|POST /replication/v1/blob|Frame(BlobChunk)|Frame(BlobResult)|Current enrolled signer, permitted store|
|POST /replication/v1/blob/read|Frame(BlobRead)|Frame(BlobChunk)|Current enrolled signer, permitted store|
|GET /replication/v1/health|empty|{"schemaVersion":1,"status":"ok"}|No data/version/identity metadata exposed|
No network enrollment/checkpoint installation in v1; owner setup and checkpoint local store API only.
Membership updated via reviewed local configuration with owner signature; API cannot self-enroll.

## Framing
Headers: Content-Type: application/json; charset=utf-8; Accept: application/json.
Reject non-JSON MIME, nonidentity Content-Encoding, duplicate framing/auth headers, Transfer-Encoding+Content-Length ambiguity.
Host exact listener/public configured host; P02 existing trusted edge gate retained on Windows.
Cache-Control:no-store, X-Content-Type-Options:nosniff on all replies; no CORS authorization bypass.
Raw signed envelope body cap2097152 bytes; decoded frame body cap1048576; headers aggregate32768.
Challenge input1024bytes/reply1024; health256; operation inline65536decoded; chunks262144decoded.
At most4 admitted requests, queue at most4, then429 before body ingestion. Aggregate spool256MiB/50000ops.
Read body incrementally; integer Content-Length precheck does not replace actual streaming bound.
HTTP request Idempotency-Key not used; immutable (datasetID,mutationID,operationHash) owns idempotency.
requestID binds response only; each retry uses NEW challenge/requestID, same persisted operations.

## One-use replay rule (supersedes revision1 nonce TTL cache)
Server generates32byte random nonce, binds datasetID+senderID+boot generation, expires monotonic120s.
Outstanding nonce cap4096 globally/64 per sender; issuance16/s globally and2/s sender,429 on excess.
Validate signature before consuming nonce; reserve/consume under serialized admission fence before transaction.
A reserved nonce cannot run twice. Failed/cancelled request still consumes it; retry new challenge.
Server restart invalidates all outstanding challenges; copied old frame rejected, no wall-clock replay ordering.
Unsigned401 on missing/forged trust has constant body {"schemaVersion":1,"code":"unauthenticated"}.
Once authenticated, errors are signed SyncError frames with matching request identity.
Operation signature verified after frame; relay cannot rewrite origin operation or app-level applied ACK.

## Status/error taxonomy (closed SyncError.code)
400 invalidInput, hashMismatch;401 unauthenticated;403 revoked;
409 replay, missingParent, conflict, staleBase, membershipMismatch, idCollision;
413 capacity;415 unsupportedMedia;422 unsupportedSchema;429 busy;
503 offline, identityUnavailable, corruptStore;504 timedOut;507 diskFull.
cancelled is local only; never pretend a durably committed operation cancelled.
Unsigned untrusted errors must not drive destructive local action. No plaintext server message displayed verbatim.
Domain concurrent edit is retainedConflict ACK; HTTP409 only admission/explicit unresolved operation rejection.
Mixed exchange results only for atomic batch committed outcome; whole storage failure returns507/503, no stored ACK.

## Retry and timeout
URLSession overall30s/request, connect/resource deadline bounded; blob requests also30s, no upload retry loop.
GET-equivalent signed reads and immutable operation submission safely retry after offline/busy/timeouts.
Backoff full jitter uniform[0,min(60,2^attempt)]seconds with base1; foreground max5 attempts/exchanges then pending.
Retry-After integer1...900 may delay until that duration; no busy looping. Resume on next foreground/manual/network event.
Auth/epoch/schema/hash failures halt endpoint, preserve local pending; never downgrade to legacy unauthenticated route.
Cancellation before transaction no write; after commit uncertain client status resolves by same mutation replay.
Disk-full preserves prior stores/receipts; do not delete pending operations or current user data to admit request.

## Revision10 supersession

R10-02 is the executable route-carrier contract and overrides this sheet wherever it leaves a header,
payload, signature, session or error mapping implicit.
