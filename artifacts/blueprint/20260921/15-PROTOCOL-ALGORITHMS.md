# Concrete protocol and algorithm decisions
These are proposed v1 interfaces. Existing domain validation remains mandatory after transport verification.

## Byte contract
Wire JSON outer frame: version=1, datasetID, deviceID, epoch, nonce(base64url),
method, path, body(base64url), bodySHA256(hex), signature(base64url).
Reject duplicate JSON keys, unknown required schema, invalid UTF-8/UUID/lengths before domain decoding.
Signature bytes: UTF8("LifeOS/replication/request/v1") followed by each field as
UInt32 big-endian byte length + exact UTF8 bytes: datasetID, deviceID, decimal epoch, nonce,
uppercase method, exact path without query, lowercase bodySHA256.
Body hash is over decoded exact body bytes; verify before decoding body JSON.
Response domain separator differs; fields nonce, status decimal, datasetID, epoch, bodySHA256.
Operation signature separately binds origin, sequence, entity, domain, parents sorted lexically,
base version, operation kind, payloadSchema and payload hash. Preserve original bytes through relay.
Canonical UUID lower-case; numeric sequence decimal string (avoid JS >2^53 truncation).
Amounts serialize minor units as decimal strings with currency/exponent; quantities/prices Decimal strings.
CryptoKit and Python cryptography Ed25519 verification use golden fixtures, not custom crypto.
HTTP framing size checked before reading body; streaming hash then bounded allocation/parse.
Constant-time signature library; no secrets in URLs, command args, logs or Info.plist.

## SyncDomainAdapter proposed Swift interface
protocol SyncDomainAdapter: Sendable {
  var domain: SyncDomain { get }
  func recover() async throws
  func pendingPage(after: SyncCursor?, limit: Int) async throws -> SyncPage
  func applyRemote(_ operation: SyncOperation) async throws -> SyncApplyReceipt
  func recordAcknowledgement(_ ack: SyncAck) async throws
  func checkpoint(_ frontier: SyncFrontier) async throws -> SyncCheckpointReceipt
}
SyncApplyReceipt: mutationID, payloadHash, disposition(applied/conflicted/alreadyApplied/rejected),
entityVersion, durableReceiptID. Rejected is not an applied ACK.
Each operation sequence stream is per dataset/domain/origin, preventing filtered domains from creating ACK gaps.
Replica cursor stores highest contiguous sequence and bounded gaps, never maximum observed sequence alone.
Limit gaps to 1024; request missing prefix or checkpoint instead of growing memory unbounded.

## Local transaction
Within one store writer lock/actor non-suspending section:
load latest durable envelope → validate command/base → create mutation + sequence → reduce →
encode candidate state+receipt+pending entry → atomic protected replace → publish in-memory result.
If store already implements receipt journal, use its commit boundary; do not double-log.
No awaited external work inside the transaction; prepare photo/JSON and validation first.
Files need interprocess coordination if widget/intents can write same domain.
Existing actor isolation alone is not a cross-process lock. Route widget intents through coordinated store.
Durability requires file+directory sync where supported; errors retain previous file/recovery marker.
Sequence allocation is scoped to durable store; receipt and sequence rollback together on failed save.

## Remote apply
verify trust/epoch/signature/limits → lookup mutationID → compare payload hash →
check known parents/base → validate domain payload → store reducer+receipt atomically.
Missing parent: queue blocked, fetch parent; do not interpret as concurrent base-less write.
Concurrent: retain branches and conflict metadata; deterministic presentation chooses stable sorted ID,
but UI labels unresolved conflict and does not assert this provisional branch is resolved.
Resolution command names both parents and selected/merged valid payload; new operation ID.
Disjoint field groups may merge deterministically; aggregate version hash includes sorted parent IDs.
Calendar time+recurrence one group; money/account/currency one group; workout exercise/set unit one group.
Invalid remote data rejected with bounded reason code, never raw payload log.
Idempotency check O(1) expected in memory / O(log n) DB index; persistence costs include encoding and fsync.

## Replica roles and ACKs
Apple app = applying replica. Mac relay/Windows gateway = durable storing replica.
stored ACK means transaction committed to transport DB, not Swift domain application.
applied ACK means durable app projection or explicit retained conflict, not successful network receipt.
Compaction requires both applying replicas applied/conflicted plus Windows stored receipt.
Mac relay durable receipt may cover temporary transmission, never replace Windows ACK for final GC.
During outage all unacknowledged Windows operations remain retained even if Apple devices converge.
Retained conflict includes full branch content until resolved; no GC of unresolved content.
Enrollment membership max8, initial Mac/iPhone/Windows roles; fourth device requires user enrollment.
Epoch changes carry signed owner-approved membership; clocks cannot enroll or revoke devices.

## Exchange
Client submits per-domain contiguous frontiers and up to128 pending operations /1MiB.
Server verifies and persists accepted rows in one bounded transaction, returns receipts + next page.
Signed cursor binds dataset, domain, frontier and membership epoch; stale cursor requests restart,
never empties local store. Pagination fixed stable sequence order.
One failed operation has an explicit result; no blanket “all accepted” on partially committed batch.
Fetch direction and push direction both advance until no changes, cancellation or five-cycle budget.
Only stored/applied ACK advances respective frontier.
Exponential backoff uses injectable monotonic time, no wall-clock ordering or busy-loop retries.

## File payloads
Large bounded document bytes uploaded as content-addressed blob before referencing operation.
Blob cap = domain file limit, absolute ceiling 32MiB; chunk max256KiB, aggregate request <=1MiB.
Validate length/hash, write exclusive temp under protected directory, atomic rename, no user filename.
One upload at a time; incomplete uploads have leases. Only unreferenced expired upload temp can expire.
Committed blobs retained by operation/conflict/checkpoint refs; no deletion based solely on age.
Planning application uses base content hash CAS via Packet C, not direct blob-to-file copy.
Tax raw pages/originals never valid replication blob types.

## Eight-day test schedule (injected clock, disposable stores)
Day0: initial paired seed, provider snapshots, backups, acknowledged frontier.
Days1–2: Windows disabled; Apple edits distinct entities, cross-sync.
Day3: both disconnected; concurrent event edit, delete/edit, note text changes, workout finish.
Day4: kill after local durable commit before send; restart; duplicate/out-of-order requests.
Day5: disk-full during temp write; previous store readable; pending draft retained.
Day6: revoke a temporary test key; in-flight write rejected at commit fence.
Day7: reconnect Apple; conflicts visible; no tombstone resurrection; resolve with new operation.
Day8: Windows resumes; replay twice; hashes/records converge; compaction respects all ACKs.
No system date change; provider freshness tested against injected clock.
Pass: every locally acknowledged edit accounted for as applied or explicit conflict, zero silent losses.

## Complexity budgets
n=domain records, b=encoded bytes, v/e=graph nodes/edges, p=page size, d<=8 devices.
Store snapshot write O(b), memory O(b); preserve existing hard caps and measure write amplification.
Indexed incremental transport insert O(log n), page read O(log n+p); causal compare O(d+parents).
Finance normalization O(b); grouping expected O(n); chronological ordering O(n log n).
Calendar overlap layout O(n log n); recurrence O(visible occurrences) within cap.
Markdown scan O(b); graph build O(b+v+e), bounded radix BVH O(v+e), worst overlap query O(v+e).
Viewport transform O(1); visible draw O(visible nodes+edges); node drag O(selected nodes), bounded selection 256.
Orb O(192) per frame; no per-frame durable writes.
Health anchored ingestion O(new samples), dedup expected O(1)/sample; history queries indexed/bounded.
Do not rewrite all JSON stores for asymptotics without measured cap failure; scope that as an Astra amendment.
