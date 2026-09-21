# R18-05 — bounded durable retry semantics

> R19-07-DISPATCH.md supersedes the six topics under review; use R19 active-schema and capacity rules. This R18 sheet is retained only where expressly compatible.

Replaces R17-01 unlimited identical-preimage retry promise and R17-02/R17-07 compaction/pruning retry behavior.
Guarantee: the MOST RECENT successful receipt-changing command per retained receipt can be replayed exactly, across crash/compaction.
After a later successful command, older retries return a typed expired outcome. Pruning explicitly expires every retry for that receipt.
No time-dependent promise, unbounded response ledger or implicit re-execution of an old destructive command.
P01 owns types/canonical hashing; P18 coordinator owns dispatch and persistence. All R18 receipt-changing APIs use this envelope.

## Request/result identity

`ReceiptCommandV8={receiptID:UUID,operationID:UUID,attempt:U16,action:Action,expectedSequence:U64?,expectedHeadHash:H?,arguments:Arguments}`.
Action enum strings prepare,advanceStage,recordPreEmissionFinalization,beginEmission,advanceEmission,advanceDeletion,finalizeArtifact,bindArtifact,commitBound,failPermanently,abandon.
Arguments exactly:
- prepare: `{identity:IdentityV8,operationKind:Op,workPlanHash:H}`; workPlan passed separately and hash-verified; expected fields both null.
- advanceStage: `{nextUnit:U32,lastUnitHash:H}`; advanceDeletion: `{nextTarget:U32,lastTargetProofHash:H}`.
- recordPreEmissionFinalization: `{record:PreRecord}`; beginEmission: `{preEmissionFinalizationHash:H}`.
- advanceEmission: `{nextOrdinal:U64,endOffset:U64,durableFrameHash:H,recoveryAction:RecoveryAction?}`.
- finalizeArtifact: `{input:LifeOSReceiptArtifactFinalizationInputV7}`; input.expectedHeadHash must equal outer expectedHeadHash.
- bindArtifact: `{expectedFinalizationHash:H}`; commitBound: `{expectedArtifactHash:LifeOSExpectedArtifactHashV7}`.
- failPermanently: `{reason:String}` restricted R18-01; abandon: `{reason:"userCancelled"}`.
All nonprepare commands require expectedSequence/head both present. No omitted nullable keys or independent outer timestamp/request UUID. finalize input.durableAt is the previously verified stable sink time, retained unchanged on retry.
`requestHash=H("LifeOS/receipt-command/v8",command)`; full typed command <=8192 CJ bytes, validated before hashing/effects.
Same receipt/operation plus altered arguments is a different request, even when desired final state happens to match.
`MutationResultV8={receiptID:UUID,operationID:UUID,action:Action,phase:PhaseV8,sequence:U64,headHash:H,cursor:Cursor,detailKind:String,detail:Detail}`.
DetailKind none→null,finalization→FinalizationV7, binding→BindingV7; finalizeArtifact selects finalization, bindArtifact binding, all others none.
Result<=12288 CJ bytes. Public typed convenience methods unwrap detail only after matching action/detailKind.
Do not return an entire mutable FileV8/LogV8 as the retry result; loadCurrentReceipt is separate read API.
`RetryOutcomeV8` is `.applied(MutationResultV8) | .replayed(MutationResultV8) | .expired(RetryExpiredV8)`.
Expired={receiptID:UUID,operationID:UUID,phase:PhaseV8,headHash:H,reason:String}; reason superseded|pruned|migrated.
Expired contains current/terminal summary, not the unavailable original result. It authorizes no effect or automatic new operation ID.

## Exact persisted additions (wire format amendment)

`RetryEvidenceV8={requestHash:H,action:Action,expectedSequence:U64?,expectedHeadHash:H?,result:MutationResultV8,evidenceHash:H}`.
evidenceHash=H("LifeOS/receipt-retry-evidence/v8",evidence excluding evidenceHash); <=13312 bytes including result.
LogV8 gains required nullable `retryEvidence`; new successful command stores one evidence object, replacing prior one atomically.
TransitionV8 gains required `requestHash:H`; its existing transitionHash preimage includes requestHash.
AnchorV8 gains required nullable `retryEvidenceHash:H?`; anchor signature/hash binds it, but evidence stored ONCE in LogV8.
RetiredIDV8 gains required `retryDisposition:"pruned"`; retains original four identity/phase/head fields, no response payload.
For unanchored new logs evidence.result must equal last transition phase/cursor/head/sequence and requestHash/action semantics.
For compacted log evidence hash must equal anchor.retryEvidenceHash when no later transitions; later transition binds replacement evidence.requestHash.
Extend the closed receipt Error enum with receiptMigrationNeedsSchemaUpgrade,operationReuse,sourceChanged,deletionInProgress,staleTarget,capabilityUnavailable.
No circular hash: transition includes requestHash ONLY, then transitionHash computed, result constructed, evidence hashed, file committed.
Before compaction/prune verify complete evidence and result; snapshot/finalization detail equality checked, not only evidenceHash.
All fields above are normative R18 V8 schema refinement; do not silently decode previous shape with synthesized defaults.
Pre-R18 V8 lacking fields is decoded read-only by its original codec and returns receiptMigrationNeedsSchemaUpgrade after chain verification.
It is not silently amended under the same version, rehashed, pruned or restarted; original bytes remain intact. Mixed old/new shapes fail corruptLog.
This explicit unsupported-input branch is distinct from supported V6/V7 migration into final R18 V8, whose initial evidence=null.
No deployed pre-R18 V8 schema is assumed from a planning sheet. An observed one requires a specified authority rebase before mutation.

## Dispatch algorithm and crash ordering

Under the receipt actor/interprocess lock validate request schema and immutable identity, then resolve receipt/retired ID.
1. Retired ID match→expired(pruned); operation mismatch→receiptIdentityConflict; never recreate same receipt/operation.
2. Retained evidence requestHash equals request→verify result/evidence/chain, return replayed EXACT stored result, even with stale expected head.
3. Current head/sequence equals requested expected pair→validate next edge/evidence and perform command once.
4. Old expectedSequence less than current (or prepare against existing identity), no matching retained evidence→expired(superseded or migrated).
5. Equal sequence but different hash, future sequence, inconsistent nulls→headMismatch; no effect.
prepare on nonexistent receipt validates no matching operation ID in logs/retired IDs, creates identity once; conflicting operation reuse is operationReuse.
When retryEvidence=null due historical migration, mismatched old requests return expired(migrated), never claim replayed.
Command validates prospective result/evidence/file byte limits BEFORE effect. Persistence failure after effect uses existing recovery markers/sink scan.
Commit transition+snapshot+retryEvidence in ONE R17-07 aggregate replacement/authority transaction; only then return applied.
Response lost after durable commit→same request finds evidence and returns replayed without another transition or file sequence increment.
Do not process a second command for that receipt until prior owned call settles; client stores original request across retry and never guesses current-head replacement.
If caller advanced again, it explicitly forfeited exact replay of older response; expired tells it to reconcile current receipt instead.
Exceptions before commit have no retained success result; retry uses durable recovery then submits original request or receives explicit expired/current progress.
Recovery adoption uses same dispatch with per-frame CURRENT sequence/head; no stale original expected head across multiple adoptions.

## Compaction, prune and revised capacity

Compaction preserves last evidence byte-for-byte; signs anchor containing evidenceHash. No command window expires merely because log compacted.
Prune allowed only60/90/91; replace log by RetiredID plus retryDisposition pruned; immutable operation identity remains protected.
compact/prune maintenance APIs themselves use expected-head CAS; already-compact/already-pruned matching identity returns maintenance no-op.
They are not ReceiptCommandV8 actions, do not replace retry evidence and never promise replay of an old full-file response.
Replace R17-02 capacity constants: transition<=12288, max64 retained transitions, anchor<=12288, result<=12288, evidence<=13312.
Before transition65 compact then append. WorkPlan<=2MiB, each active log<=4MiB, terminal compact log<=32768, FileV8<=32MiB.
At8 active logs: plans16MiB + transitions6MiB + anchors98304 + evidence106496 + fixed overhead<=1MiB;
plus256 terminal summaries at32768=8MiB totals<32MiB. Prospective encoded file cap always checked; no cap waived by this estimate.
Terminal summary must fit32768 INCLUDING anchor/evidence/identity; remove only terminal plan arrays per R18-01, never required evidence.
Archive426406 transitions needs<6663 compactions at64, U64 sequences unchanged; no growth with lifetime transition count.

## Planned verification

P01 SyncProtocolTests: command preimages distinguish all inputs, nulls and recovery action; request/result tag mismatch rejected.
P18 CompletionFlowsTests: lose response after authority commit, compact, reopen, repeat original request→identical typed result/no duplicate effect.
Advance again then retry old request→expired(superseded); prune→expired(pruned); migrated old chain→expired(migrated).
Test prepare operation reuse, CAS conflict, cap before effects and terminal compaction including evidence at maximum encoded size.
