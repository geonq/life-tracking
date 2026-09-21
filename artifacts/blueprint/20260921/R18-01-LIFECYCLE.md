# R18-01 — phase completion, resumability and compaction

> R19-07-DISPATCH.md supersedes the six topics under review; use R19 active-schema and capacity rules. This R18 sheet is retained only where expressly compatible.

Normative replacement for R17-01 phase edges/terminal wording and R17-02 terminal compaction rules.
Retain R17 cursor wire objects, phase numbers, hash notation and finalization/binding objects except explicit R18 amendments.
P01 declares validators in ios/Shared/SyncContract.swift and ios/Sync/SyncWireCodec.swift; P18 implements coordinator.
`isTerminalForCompaction(_ phase: LifeOSReceiptPhaseV8) -> Bool` returns true ONLY for 60,90,91.
`isResumable(_ phase: LifeOSReceiptPhaseV8) -> Bool` returns true ONLY for 10,20,30,35,40,50.
Cursor kind=terminal is a representation tag, NOT a lifecycle classification. Outcomes40/50 remain resumable.
Never use `cursor.kind == .terminal` to select pruning, work-plan removal or scheduling behavior.

## Exhaustive edge table

Every row additionally requires identity/attempt equality, valid current chain, expected-head CAS and valid workPlanHash.
No edge not listed here is legal; numeric operation kinds are R17 recovery1/export2/restore3/deletion4.

|from|operation|to|command and required durable evidence|
|---|---|---|---|
|null|1,2,3|10|prepare; immutable work plan committed before any effect; nextUnit0|
|null|4|35|prepareDeletion; R18-02 target plan and fence committed before effects; nextTarget0|
|10|1,2,3|10|advanceStage; exactly one pack completed; nextUnit=previous+1; verified pack/projection marker|
|10|1,2,3|20|recordPreEmissionFinalization; nextUnit=count; verify every planned marker, full immutable source/manifest/plan|
|20|2|30|beginEmission; matching PreRecord; nextOrdinal0,endOffset0,lastHash null|
|20|1,3|40|finalizeArtifact; all projection markers and source file verification; finalization persisted atomically|
|30|2|30|advanceEmission; nextOrdinal=previous+1; writer durability proof matches exact next planned frame|
|30|2|40|finalizeArtifact; nextOrdinal=totalFrameCount; sole footer and published sink verified; all staged work complete|
|35|4|35|advanceDeletion; one next target proof durable and verified, including final widget target|
|35|4|40|finalizeArtifact; nextTarget=targetCount; complete proof fold and completed deletion fence|
|40|all|50|bindArtifact; complete verified FinalizationV7, expectedFinalizationHash equality; no effects replayed|
|50|all|60|commitBound; complete BindingV7; typed expected file/identity/binding hashes all equal|
|10,20,30,35,40,50|all applicable above|90|failPermanently; explicit nonretryable reason and known durable prefix; rules below|
|10,20,30,35,40,50|all applicable above|91|abandon; explicit user request, settled effects and known durable prefix; rules below|
|60,90,91|all|none|read/retry/prune only; no reset, resume, failure or cancellation transition|

Identical retry may return existing success under R18-05; it is not a same-phase edge or a new transition.
Only progress10/30/35 may self-transition. Zero-unit staging may advance10→20 without a synthetic pack marker.
Transient I/O, sleep, task cancellation, disk-full and locked keys return typed errors without changing phase.
No failure transition may be fabricated when chain/identity/cursor evidence itself is corrupt: preserve bytes and report error.
`failPermanently(id,expectedHead,reason)` accepts only `permanentFailure` or verified `sourceChanged`.
`abandon(id,expectedHead)` uses `userCancelled`; no other API implicitly abandons an operation.
Before either terminal transition: stop scheduling work, await owned in-flight call, reconcile any ambiguous effect/receipt boundary.
If reconciliation cannot determine the durable prefix, return its error and retain current resumable receipt; never guess lastWork.
At40/50 abandonment does not delete published files or undo projections/deletions. UI reports partial/performed effects truthfully.

## Snapshot and validation rules

Use existing `validateReceiptCursorV8(...)` signature from R17-01, with R18-02 WorkPlan targets and R18-05 command context.
`validatePhaseEdgeV8(previous: SnapshotV8?, candidate: SnapshotV8, operation: Op, completion: DurableCompletionV8?) throws` is pure.
It checks the table before command-specific validation; P18 alone constructs completion after re-reading owned durable proofs.
10/20/30/35: errorCode null, no FinalizationV7 or BindingV7; PreRecord only20/30 and operation1..3.
40: finalization required, binding null, terminal.outcome40; 50/60: both required, matching terminal.outcome.
90/91: errorCode required and equal in cursor/snapshot; finalization/binding copied exactly from prior snapshot, never manufactured.
On failure/cancel, lastWork copies the prior nonterminal cursor or prior terminal.lastWork for40/50; no nested terminal cursors.
Every cursor identity/operation, record receiptID/attempt, plan hash and finalization/binding hash reference must agree.
`lastWork=null` remains legal only for authenticated migrated zero-effect failure; it is never emitted by new operations.
Successful40/50/60 always retain complete lastWork (index=count or ordinal=total); completion cannot be inferred from caller count alone.
`finalizeArtifact` revalidates ALL plan effects and published sink/source or deletion fold before issuing40.
`bindArtifact` and `commitBound` revalidate immutable finalization/binding and absence of unresolved authority/file intents.
Public operation success is phase60 only. Phase40/50 results are progress, not successful user export/restore/deletion.

## Compaction and recovery

Regular chain compaction is legal for every valid phase; it retains the full work plan at10/20/30/35/40/50.
Only60/90/91 may replace arrays with a plan digest summary; only these phases count toward the terminal256 cap.
40/50 count toward the active8 cap, keep PreRecord/Finalization/Binding and all material needed to finish the next edge.
Reopen40 validates finalization then binds; reopen50 validates binding then commits. Neither replays domain mutations.
Reopen90/91 never resumes effects; explicitly starting again allocates new operation/receipt IDs after domain state reconciliation.
Compaction/pruning preserve R18-05 retry evidence/window outcome. No automatic receipt-history reset at capacity.
Deletion proofs required while resumable cannot be removed by deleting recoveryImports or by receipt compaction.

## Planned verification (not executed)

P01 SyncProtocolTests: exhaustive phase×operation edge matrix, forbidden terminal resumes, mismatched nullability and counts.
P18 CompletionFlowsTests: crash at40/50, compact/reopen then finish exactly once; plan arrays survive both phases.
Inject pending sink/domain effect before abandon: unresolved state stays resumable; reconciled state records accurate lastWork.
Reject premature40 when one marker, footer sync, widget publication or trust-fence step is missing.
At60/90/91, compact/prune then confirm no effect replay and correct R18-05 retry response.
