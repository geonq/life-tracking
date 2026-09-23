# P04 CP-B durable training adapter contract

Updated 2026-09-23. Source reviewed at ebef1ac; coordination base 2ce8eee.
Status: batches A-D may execute against explicitly injected bindings and
fixtures. Production registration (E) is blocked by descriptor authority and
legacy-dataset reconciliation. Do not claim live sync or remote ACK success.

## Fixed wire/storage boundary

- SyncStoreKind.training maps to SyncDomain.fitness. Never use the kind string
  as SyncOperation.storeID; storeID remains a canonical UUID.
- SyncOperation and SyncPayload remain schema 1. FitnessPayload remains schema
  1 with tag training. Wire4TrainingSession is a type name, not a schema.
- TrainingLedgerEnvelope is local schema 2. Add a deliberate local schema 3
  migration. Preserve existing codecs, canonical JSON, signatures and bytes.
- FitnessSyncAdapter currently supplies payload encoding only. Do not infer
  that CalendarSyncAdapter command, delete, or compaction semantics transfer.

## Schema-3 replication state

Add TrainingReplicationState with:
- binding: datasetID, epoch, storeID, localOriginID, keyID;
- bootstrapMap: durable TrainingBootstrapEntry values;
- pendingIntents: ordered durable TrainingSyncIntent values;
- entityKeys: recordID to entityID mappings retained after deletion;
- ledger: SyncAdapterEnvelope containing durable outbox, frontier,
  acknowledgement, receipt and entity-head state.
Add optional replication state to the training envelope. Binding identity
fields are canonical strings. Keep existing strongly typed training IDs where
the current domain already provides them.

TrainingBootstrapEntry stores recordID, mutationID, entityID and payloadHash.
TrainingEntityKey stores recordID and entityID. TrainingSyncIntent stores
mutationID, recordID, operation kind and the exact canonical SyncPayload.
Use Codable, Equatable and Sendable as supported by adjacent domain types.

Define one entity identity function:
entityID(for recordID: TrainingRecordID) throws -> String
= SyncWireCodec.hash(domain: LifeOS/training-entity/v1,
canonical: SyncWireCodec.canonicalJSON(recordID.rawValue)).
Freeze it with a literal golden fixture; do not derive IDs from display text.

## Migration, binding and bootstrap

- Schema 1 keeps its legacy decoder, fractional dates and legacy fingerprint
  version; reject nonempty legacy queues. Schema 2 preserves all values and
  replay barriers. Unknown versions fail closed.
- Schema 3 with no binding remains usable locally. Binding is a later explicit
  transaction; reopening the same binding reuses its exact map and intents.
  Any dataset/store/origin/key/epoch change is an explicit migration error.
- bindReplication(binding) persists binding, bootstrap IDs, immutable payloads,
  entity keys and initial intents in the same existing locked file transaction.
  Generate one UUID mutationID for each currently retained session exactly
  once. Discarded sessions remain retained and are included.
- Preserve existing record UUIDs. Never infer command history from receipts.
  Reject duplicate record IDs, entity-ID collisions, or generated mutation IDs
  colliding with live receipts, retired IDs, bootstrap IDs or existing ops.
- Failed validation/write changes no domain or replication bytes. Reopen after a
  committed bind reuses its exact state.
- Historical deletes cannot be reconstructed: old receipts do not retain
  command kind/post-image and retired receipts retain only IDs. Never synthesize
  deletes from absence. Binding to a populated remote dataset needs explicit
  reconciliation evidence; otherwise stop before activation.

## Local command to durable intent

- begin -> bootstrap of the exact committed session.
- update, finish, discard, link and unlink -> put of the exact committed
  session. Discard remains a retained session.
- delete -> delete with schema-1 empty payload: SHA-256 of empty bytes, count 0,
  inline empty string, nil blobHash. Retain recordID/entityID mapping.
- ordinary operation mutationID equals the canonical supplied command ID.
  Bootstrap IDs are generated and persisted in the bootstrap map.
- Conflict/blocked results create no intent or sequence. An exact command retry
  returns its prior receipt and never appends a second intent.
- Before a successful local receipt, one atomic transaction persists the
  post-image/removal, existing command receipt/fingerprint, immutable intent,
  entity mapping and unchanged replication evidence. A local receipt means
  locally saved, not remotely synchronized. Payload validation/size failure
  prevents the domain mutation too.

## Signing, sequencing and outbox

Implement sealPendingIntents(identity:signingSeed:limit:) synchronously inside
the existing file-lock transaction; acquire identity/key before entering it.
Use the SyncIdentityStore replication Ed25519 key and SyncWireCodec signing;
never use the receipt-authority key. Validate public-key hash against binding.
Signing seed is transient and is never persisted, encoded or logged.

For the oldest bounded intent prefix: allocate nextSequence per
(datasetID, epoch, storeID, originID); derive sorted unique parents from current
entity heads and baseHash from current entity version; bootstrap has neither.
Sign, validate and bound each operation. Atomically append signed outbox bytes,
update entity heads/version/deleted state, remove sealed intents and advance
sequence. Return only after verified persistence. Failed transaction advances
nothing. Restart retransmits identical signed bytes; it never resigns or
reallocates. Unsigned offline intents allocate no sequence. Exhaustion fails
before mutation. A pending local intent blocks remote overwrite of that entity.

## Remote apply, receipts and retention

Implement every SyncDomainAdapter requirement; do not use no-op delivery
defaults. Before apply, verify roster authorization, signature, binding/domain,
payload hash and entity mapping; reject mutation/sequence reuse with different
bytes; require contiguous predecessor and existing causal parents/base.
Divergent branches remain explicit conflicts. Validate the entire candidate
training ledger, including the single active/paused session rule and imported
workout ownership. Unknown/unmapped delete and domain-invariant collisions
block or retain conflict; they are not applied ACKs.

Persist domain change, operation, entity state and SyncOperationReceipt
together before returning an ACK-eligible result. Exact replay returns the
stored disposition without re-execution. Preserve SyncEngine ordering: signed
ACK follows durable apply receipt; authenticated remote ACK/frontier persistence
precedes outbound ACK-page retirement.

CP-B performs no compaction of operation bodies, tombstones, mappings, conflict
branches or replay receipts. Gateway acceptance is not proof another device
applied data. Capacity exhaustion fails closed; never silently evict evidence.

clearReceiptJournalAfterExport() is local command-receipt compaction only:
move command IDs to the retired-ID index; preserve pending intents and all
replication state byte-for-byte; never clear tombstones/outbox/ACKs or advance
frontiers. Export is not a sync acknowledgement. Later GC needs a separate
recovery/checkpoint contract.

## Bounded implementation batches

A. Schema/key map: FitnessTrainingStore.swift, new
   ios/Shared/TrainingReplicationState.swift, FitnessTrainingStoreTests.swift.
   Tests: v1/v2 preservation, v3 round-trip, bind/restart ID stability,
   collision rejection, ambiguous legacy attachment blocked.
B. Command capture: exact scope and invariants are in
   tasks/p04-cpb-batch-b-amendment.md; that amendment supersedes this short
   summary and is authoritative. Keep the embedded adapter ledger empty.
C. Sealing: new ios/Sync/TrainingSyncAdapter.swift plus FitnessSyncTests.
   Tests: literal entity/payload/signature bytes, failed transaction no sequence
   hole, restart byte identity, key mismatch and overflow.
D. Remote apply: store applyReplicationOperation and adapter methods. Tests:
   valid put/delete, replay, equivocation, sequence gaps, stale base, pending
   local edit, active-session/imported-key collision, ACK failure/restart.
E. Registration: new composition only after both gates below are resolved.
   Test authorized descriptor accepted; wrong kind/domain/version/UUID/key
   rejected; shared actor used; registration starts no network activity.

## Unresolved activation gates, invariants and cost

- Trusted descriptor membership: current composition does not establish who may
  own/register a training descriptor. Require verified persisted membership;
  never generate independent store UUIDs on each device.
- Legacy remote reconciliation: populated remote datasets may contain deletions
  unrecoverable from old local receipts. Require explicit evidence or block
  binding; absence is never a remote delete.
- Keep batches A-D injected and unregistered until both gates are resolved.
- No await under file lock. No timestamp merge, silent schema fallback,
  automatic identity replacement or guessed historical delete.
- Maintained lookup indexes give expected O(1) record/entity/mutation/sequence
  lookup. Rebuild and validation are O(N + payload bytes). Whole-file writes
  are O(ledger bytes); current sorting can be O(N log N). Do not claim the
  current store is O(N)-only or add nested scans.
- Bound intents, operations and maps against the existing envelope ceiling.
  Stop on bad binding, key/epoch mismatch, corrupt state, missing parents,
  unsupported payload, unresolved reconciliation or capacity exhaustion.
