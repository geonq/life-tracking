# Core packets
Exact file lists: 14-OWNERSHIP.json. Existing symbols are in source anchors; new APIs explicitly named here.
Tests named below are implemented with the packet but run only at wave boundaries unless integrity is at risk.
All migrations preserve original data and are idempotent on restart. No worker changes files belonging to another packet.

## P00 — baseline and capability reconciliation
Purpose: establish a trusted checkpoint and stop repeating completed work.
Read actual git SHA/status and receipts; create requirements.json with ID, feature, ownerPacket,
sourceStatus, evidenceClass, evidencePath, evidenceSHA, environmentBlocker and nextAction.
Import legacy registry/reference rows if present; preserve IDs/aliases; add missing explicit user features.
Do not mark unverified rows absent. Resolve 5dae724/d3e62b7 and untracked D1 in coordination prose.
Read signing/profile/entitlements without deploying; record capability allowed/denied/unknown.
No source edits or builds needed. Acceptance: no contradiction between current SHA and new ledger,
all feature families in 00-INDEX mapped, D1 fingerprint preserved, U1–U5 isolated.
After final go, controller may commit/push docs checkpoint; not during this planning task.

## P01 — contracts/engine
Create SyncOperation, SyncAck, SyncMembership, SyncConflict, SyncFrontier and validated decoding.
Create SyncWireCodec.encodeSignedFrame/verifyFrame and golden Swift/TypeScript/Python byte vectors.
SyncIdentityStore.loadOrCreateKey/enroll/revoke: Keychain private key, explicit trust.
SyncDomainAdapter: pendingPage, applyRemote, acknowledgement, recover, checkpoint; async Sendable.
SyncEngine.resume/stop/synchronizeOnce drains per-domain FIFO pages with one request in flight per endpoint.
SyncTransport.exchange is HTTPS exact endpoint + signed bytes, cancellation/body/content-type bounds.
Do not add parallel universal domain persistence; engine discovers durable operations from adapters.
Algorithm and failure rules: 02 and 15. Memory O(pageBytes+enrolledDevices); network O(new operations).
Acceptance: forged/replayed frames rejected; reordered and duplicate delivery converges;
same ID/different hash blocked; canceled task cannot ACK/apply; generated contracts agree byte-for-byte.

## P02 — relay and gateway
Create replication.py ReplicationStore.append/read_page/ack/checkpoint/enroll and validate_signed_request.
SQLite schema: operations PK(dataset,mutationID), unique(origin,sequence), blobs(hash), acks, membership.
Explicit transactions; blob limits/hash before publication, bounded SQLite reads, lock/busy handling.
Mac main.py exposes /replication/v1/hello, /exchange, /blob, /ack, /health using same pure store.
Windows main.py registers same handlers behind existing trusted-edge gate.
Mac authentication uses signatures directly; NEVER import Windows launcher or skip auth for loopback.
Install script checks exact tailscale executable/service, takes config snapshot, creates private Serve path
without replacing unrelated routes, installs user LaunchAgent, records rollback/uninstall steps.
No bank secrets/upstream bank calls on Mac. Request limits and concurrency 4, single DB writer.
Acceptance locally: untrusted local request rejected, process restart preserves receipts,
mixed Swift-origin fixtures verify, cap/disk-full/duplicate handling; real relay proof later Mac/iPhone.
P16 owns app endpoint registration. Adding cryptography requires pinned version/hash/license in requirements.lock.

## P03 — calendar/finance durable integration
Extend current store envelopes additively with pending operations/replication version/receipts.
CalendarStore.commitReplicatedMutation becomes atomic save+receipt path; CalendarCoordinator.performPersist uses it.
CalendarCoordinator incoming path invokes causal merge and retains conflict, not raw timestamp LWW.
Retain CalendarRemoteMergePolicy validation and peer fence. Nearby transport cannot write old snapshots once v1 active.
FinanceImportedTransactionStore preserves existing pending-request bytes and IDs; wrap existing receipt lineage.
FinanceRecurringPaymentStore.saveOverride/clearOverride, investment merge/upsertAccountSnapshot,
budget/allocation/preferences save paths include outbound receipt in same file transaction.
New adapters enumerate domain envelopes and apply validated remote operation through existing store actor.
No migration drops old pending attempts; mark legacy pending import as awaiting its original gateway ACK.
Write amplification initially O(store size) for existing JSON stores, bounded by their current caps;
do not claim O(1) durable saves. Index receipt IDs in memory, rebuild O(n) on open.
Acceptance: save/restart/replay, concurrent edit/delete, legacy pending attempt survives, no wall-clock victory.
Changing money semantics belongs P09; this packet only durability/replication.

## P04 — remaining local records
FitnessTrainingStore already has mutation receipts; extend/reuse execute/persistCandidate envelope.
NutritionMealStore.addConfirmed/correct/softDelete, goals, SupplementStore.mutate,
journal/lifestyle writes must atomically include replicated receipt.
Record kind is explicit, e.g. trainingSession/meal/supplementOccurrence/journal/lifestyle/goal.
Same-record concurrent correction creates conflict; independent records union by stable ID.
Do not synchronize HealthKit anchors or permission state; observations are a separate qualified input.
Acceptance: eight-day offline log, repeated receipt replay, workout finish once, nutrition correction,
supplement completion once, crash between journal/store steps, pending records never compacted.

## P05 — existing D1 candidate
Review existing PlanningGraphProjector.project, PlanningReferenceResolver.resolve,
PlanningSpatialIndex.rebuild/query, PlanningCanvasReducer.apply and session commit/undo/retry.
Keep scanner non-regex and bounded; no graph rebuild on transient drag, preserve extension fields and order.
Resolve actual defects only. D1 model/history cap 100 commands/16MiB and generation checks must remain.
Acceptance: existing historical results reconciled by hash or one relevant batched lane; exact same source is not retested repeatedly.
Do not build UI here; P06 requires accepted session contract. Retain all eight current files.

## P06 — native graph, observer and vault adapters
PlanningCanvasViewport.worldPoint/screenPoint/zoom/fit; formula in 03; pure value type.
PlanningGestureBridge routes platform input to begin/update/cancel/commit; single gesture owner.
PlanningCanvasView layers Canvas edges and SwiftUI visible nodes; index query includes small overscan.
PlanningNodeInspector edits typed draft; PlanningNoteView edits bounded Markdown with explicit save.
PlanningProjectCoordinator.open/selectNode/commit/connectNotes/resolveConflict owns session and selected path.
PlanningVaultObserver.invalidate(path) coalesces events and re-reads hash through store.
PlanningSyncAdapter publishes content-versioned proposals through existing stage/publish; no remote filesystem writes.
Modify VaultAccess/Store only for observer/proposal seam; preserve descriptor-relative security and journals.
Migration: no bulk vault conversion. Unknown shape extensions remain intact; generic rectangle fallback.
Acceptance: pan/zoom has no persistence; drag commits once; focal point invariant; two notes same basename
remain ambiguous; concurrent Obsidian edit creates conflict; restart retains draft; real vault round trip later.

## Interface ownership amendments
P01 owns protocol signatures. P03/P04/P06/P13 implement domain adapters without editing protocol files.
If an implementation requires a new protocol field, stop that dependent packet and send a concrete schema amendment to P01.
P16 owns an early membership-only substep after P01/P07 files exist, before W1 compile; final composition follows dependencies.
P00 resolves the existing legacy registry location before writing new ledger; if absent, record absent and seed requirements from
target design docs + this index + explicit user requirements. Never claim 258 mapped rows without finding the source registry.
