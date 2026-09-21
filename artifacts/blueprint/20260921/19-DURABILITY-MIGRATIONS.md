# Durability, migration and exceptional-state contract
Applies to every mutating packet; existing stronger domain validation/caps remain in force.

## M1 — existing JSON envelope (P03/P04)
1. Acquire existing in-process lock plus interprocess file lock if intents/extensions share writes.
2. Read bounded latest bytes inside lock; missing initial store is distinct from corrupt existing store.
3. Validate legacy schema/domain values. Unknown newer schema opens read-only with explicit error.
4. Build additive envelope preserving IDs, timestamps, unknown compatible fields, pending attempt bytes.
5. Add replication schema=1, stable storeID, per-origin sequence, receipts, conflicts and pending entries.
6. Write one exclusive backup of original bytes with hash; verify before switching; never overwrite recovery backup.
7. Encode candidate to exclusive sibling temp; set protection/permissions; flush; bounded decode/validate.
8. Atomic replacement followed by directory durability where supported; replace current memory only after success.
9. Record migration version in same envelope. Reopening version1 is no-op; never reset sequence/outbox.
No old binary may write new envelopes unless proven lossless round-trip. Block downgrades, preserve export path.
No default [] on corrupt file. Present recoverable error with previous valid file intact.

## M2 — local operation commit
Validate command and base under lock; equal state => no-op, no sequence allocation, no widget refresh.
Create candidate + mutationID + incremented per-store stream sequence + receipt in same envelope.
Persist as M1 steps7–8; only then publish local save. No extra separate outbox file for the same domain.
Existing training/import/planning journals retain their transaction boundary; adapt, do not duplicate journals.
Prepared data may be computed outside lock, but recheck base version before commit.
Overflow, capacity, invalid data, revoked admission fence => reject without changing previous envelope.
Cancellation before transaction => no write; cancellation during/after durable commit => return/retain receipt.
Do not lie that committed data was cancelled. Repeated user retry uses same mutationID and payload hash.
Same ID/different hash => hard conflict; same ID/same hash => original receipt without mutation.

## M3 — remote apply / conflicts
Authenticate and validate bounds before domain decode; then acquire domain writer lock.
Look up durable receipt, verify causal parents and base; missing parent => blocked record, no applied ACK.
Do not implement arbitrary three-way field merge in this release. Binding default: same-entity concurrent edit conflicts.
Disjoint entity operations commute by stable ID; sequential causal updates replace only after validation.
Delete/edit concurrency retains both branches. Calendar series+exceptions form one command aggregate.
Unknown payload/schema quarantines bounded bytes, never applied ACK. Rejected data is not a successful merge.
Store conflict payloads and receipt atomically; retainedConflict ACK only after full branches durable.
Resolver uses explicit user selection, creates new mutation naming both parents; never mutate old operation.
This supersedes vague automatic disjoint-field/text-hunk merge promises in revision1.
Planning same-file concurrent edits always retain base/ours/theirs; independent files may publish separately.
Already-present content hash is no-op success with receipt; missing cloud-provider file is not proof of deletion.

## M4 — planning multi-file operations
Use existing stage/publish journal. A note and Canvas edit are not magically filesystem-atomic together.
Link notes edits source Markdown only; add Canvas arrow is a separate command with separate receipt.
Create project stages index.md and map.canvas with parent creation record; UI shows pending until both published.
Crash recovers through existing publication journal; do not invent a cross-file rename transaction.
Observer callback only invalidates; re-read via coordinated store after250ms debounce.
Unpublished draft survives observer update; conflicting external bytes never overwrite editor buffer.
Do not store an entire vault snapshot in memory or replicate device-specific bookmarks.

## M5 — transport SQLite / compaction (P02)
BEGIN IMMEDIATE; verify identity epoch again under writer admission fence; insert immutable rows+receipts;
COMMIT with synchronous=FULL; only then sign stored response. Writer queue4, busy_timeout1000ms.
Operation unique(dataset,mutationID); sequence unique(dataset,domain,storeID,origin,sequence).
BEGIN failure => busy retry; partial row batch returns explicit per-item results only for actually committed rows.
Rejected items may coexist with accepted items if transaction semantics/vector specify it; CP-B seals response schema.
Compaction needs Mac+iPhone applied/retainedConflict frontiers AND Windows stored frontier, plus tombstone age>=30d.
Retained conflict CONTENT cannot compact until resolved even if its receipt is acknowledged.
During Windows outage no pending history eviction. Capacity blocks further durable saves honestly; preserve existing data.
Checkpoint materializes content+frontiers+receipt hashes; validate before deleting covered rows in one transaction.
Reseed revoked device via signed new epoch/checkpoint; stale cursor never causes local empty-store replacement.
WAL checkpoint at16MiB or idle shutdown; no VACUUM/full rewrite per edit.

## M6 — tax/cache/widgets/HealthKit
Tax raw-cache migration: backup→protected cache write+verify→sanitized main envelope atomic replace→mark migration.
Restart after cache creation verifies hash and resumes; never delete sole raw copy before durable sanitized+cache files.
Original user PDFs are never auto-deleted. OCR cache eligibility=accepted age30d and no pending/conflict references.
Widgets: additive schema, unsupported newer snapshot => placeholder, never overwrite producer with placeholder.
Publisher uses content digest+domain revision, excludes generatedAt from change digest; preserve old snapshot on failure.
HealthKit: persist sample changes before anchor; if impossible atomically, replay old anchor with UUID/source dedup.
HK write retry ambiguity => pending confirmation/query; read-denied is not proof prior workout absent.
Windows rollback restores compatible binary/config only; never rolls data behind acknowledged operations.

## Evidence at wave boundaries
M1/M2 interrupted write at every boundary, old/new schema reopen, duplicate retry, disk-full, unchanged no-op.
M3 reordered parents, concurrent deletion, unauthorized receipt, unsupported payload, stale UI generation.
M4 iCloud external edit and provider unavailable; M5 process restart, ACK loss,8-day outage/replay/GC.
M6 raw publication exclusion, widget old snapshot readability, HealthKit ambiguous completion.
Use disposable copies before applying migrations to personal data; no additional per-keystroke test runs.
