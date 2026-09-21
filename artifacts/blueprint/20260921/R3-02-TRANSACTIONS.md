# Transaction/order, identity and schema handoff
## Local mutation
UI validates draft→freeze mutationID and typed payload→store lock+latest read→base check→allocate sequence→
reduce candidate→write candidate domain+SyncAdapterEnvelope in SAME commit→publish local receipt→sign frozen op→send.
Signing may occur after commit; unsigned entry freezes keyID/epoch/content/sequence; never sign later entity state.
Lock unavailable/invalid/capacity rejects, previous bytes intact. No-op allocates no sequence/receipt.
Non-suspending transaction region; before/after awaited I/O verify generation/base; no network within lock.
Every legacy mutation API must enter this transaction after cutover; no bypass save() overwriting replication field.

## Incoming operations
Verify endpoint frame→operation signer/current epoch→logical store/payload type/size/hash→durable inbox commit.
Then apply from inbox using domain writer: dedup operationHash→known parent/base→validate current DTO→reduce→
domain+applied receipt/conflict atomically commit→sign applied/retainedConflict ACK→transmit.
Received frontier means inbox persisted; applied means domain or FULL conflict branches persisted.
Missing parent retains inbox and blocks apply, never applied ACK; request missing prefix via received frontier.
Same mutationID/same hash no-op; same ID/different hash idCollision; same stream sequence/different mutation idCollision.
Initial bootstrap identical entity payload hash idempotently joins parents; differing initial content retains conflict.
Parents must belong same entity/store; reject graph cycle using causal indexed ancestry; cap8parents/8branches.
No implicit field/text merge: disjoint entities commute, same entity conflicting edits retained for explicit resolution.

## Server SQLite transaction
Schema version pragma user_version1; no Swift domain reduction in Python server.
operations(dataset_id,mutation_id PK pair,store_id,origin_id,sequence_decimal,sequence_sort BLOB8,
operation_hash,encoded_operation BLOB,payload_hash,epoch,key_id); UNIQUE(dataset_id,store_id,origin_id,sequence_sort).
acks(dataset_id,mutation_id,replica_id,level PRIMARY KEY quartet,operation_hash,encoded_ack BLOB).
blobs(dataset_id,store_id,hash PRIMARY KEY triple,byte_count,path,complete); never user-controlled path.
membership(dataset_id PRIMARY KEY,epoch,hash,encoded_membership BLOB).
No unsigned operations in server DB. Immutable encoded bytes preserved verbatim, not reserialized for signature checks.
BEGIN IMMEDIATE→recheck trust epoch/revocation fence→validate rows→insert accepted rows+stored ACK material→COMMIT→reply.
Rejected input rows explicitly listed; failed DB commit rejects whole batch, emits no new receipts.
Stored receipt signing fields freeze in transaction; sign after commit before returning, retry recreates same receipt.
Serialize one writer; busy_timeout1000ms; WAL/synchronousFULL; no per-write VACUUM.
Sequence sort is unsigned8byte big endian so order correct above2^63/2^53; decimal string wire preserved.

## Membership and key lifecycle
Dataset owner signing key distinct from device keys, pinned by physical fingerprint at initial setup.
Owner key in Mac Keychain device-only; relay/server cannot enroll or revoke independently.
Mac relay key uses user Keychain via a reviewed native credential handoff; Python Keychain bridge CP-K must seal exact API.
Windows server key uses existing protected secret facility after CP-K mapping, never plaintext repo/env arguments.
Graceful rotation: stop new edits→sign/drain pending→checkpoint approved→owner signs epoch+1→install atomically.
Do not delete old receipts/backups; previously accepted operation bytes remain evidence.
Emergency revoke: block old signer/unsigned entries. No new old-epoch admission, even if sequence is small.
Existing authenticated content remains local; owner explicitly resolves/reissues blocked edits with new IDs/current epoch.
New epoch reseeds trusted checkpoint before forwarding pending work; returning revoked replica cannot resurrect edits.
No automatic old-key re-signing, sequence reuse or silently dropping gaps.

## Compaction/checkpoint safety
Checkpoint archive schema CP-S per-store must be sealed before implementing GC; until then GC disabled safely.
Require Windows stored + both Apple applied/conflict signatures through every covered stream; age>=30d tombstones.
Unresolved conflict content, inbox missing parent and pending outbox NEVER eligible even with old timestamp.
Checkpoint payload preserves current entity versions, tombstones, receipt identity and retained conflicts.
Write/verify checkpoint first; prune eligible rows same transaction only after durable archive/reference checks.
History caps stop writes with capacity; do not evict unacknowledged rows. Full Windows outage keeps data.
WAL checkpoint16MiB, bounded blob leasing; incomplete unreferenced uploads expire24h only.

## Still explicit planner gates
CP-W: audited duplicate-key/canonical encoder and cryptographic golden vectors, no inference by Luna.
CP-K: exact native/protected credential bridge and rotation/reseed install transaction review.
CP-S: domain payload encode/decode and checkpoint archive schemas bound to current source DTOs in R3-04.
These are unresolved pre-code decisions; outer schemas are fully enumerated, whole implementation is not READY.

## Revision10 supersession

R10-01 seals the Planning SQLite/file-journal transaction and R10-03 seals calendar intent and sequence
allocation; those sheets replace any conflicting ordering or builder assumptions here.
