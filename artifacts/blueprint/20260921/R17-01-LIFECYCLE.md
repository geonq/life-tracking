# R17-01 — complete receipt lifecycle

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Normative; replaces R16-01 in full and R15-01/02 cursor, transition and phase clauses.
P01 declares wire values/validators; P18 persists them. R17-02 defines the container.
Notation: `{a:T,b:T?}` means exactly those JSON keys; nullable keys are present as null.
U16/U32/U64 are unsigned decimal strings without leading zeroes; enum/version values are JSON numbers.
UUID is lowercase RFC4122 text; H is lowercase 64-hex SHA256; timestamp is signed UTC milliseconds.
Reject unknown/missing keys, duplicate keys, noncanonical integers, overflow and invalid enum values.
`CJ` is R13 canonical JSON; `F(d,b)=UTF8(d)||00||UInt32BE(length(b))||b`; `H(d,x)=hex(SHA256(F(d,CJ(x))))`.
All string paths are NFC relative allowlisted paths; artifact paths <=128 bytes, data-file paths <=512 bytes.
These abbreviations define types, not untyped dictionaries in implementation.
Public Swift spelling: Cursor=LifeOSReceiptCursorV8, PhaseV8=LifeOSReceiptPhaseV8, Op=LifeOSReceiptOperationKindV7,
PreRecord=LifeOSPreEmissionFinalizationV8, WorkPlanV8=LifeOSReceiptWorkPlanV8, ReceiptSnapshotV8=LifeOSReceiptSnapshotV8,
EmissionPlanV7=LifeOSEmissionPlanV7, FinalizationV7=LifeOSReceiptFinalizationV7, BindingV7=LifeOSReceiptBindingRecordV7.
R17-02 FileV8/LogV8/SnapshotV8/TransitionV8/AnchorV8/IdentityV8/MigrationV8/RetiredIDV8 prefix `LifeOSReceipt` to those base names;
AnchorV8 uses base `CompactionAnchorV8`, MigrationV8 uses `MigrationV8`; SnapshotV8 and ReceiptSnapshotV8 denote the SAME type.
Wire keys stay exactly as specified, independent of Swift spelling; Python/TS use equivalent closed typed objects.
R17-05/06 MutationV9,CheckpointV9,FenceV9 prefix `LifeOSAuthority`; all other V9 short schema names prefix `LifeOS`.
Do not retain two public declarations with the same semantic schema merely to preserve a historical abbreviated spelling.

## Complete cursor wire objects

`Cursor={schemaVersion:8,receiptID:UUID,operationKind:Op,kind:Kind,payload:Payload}`.
Op: recoveryImport=1,dataExport=2,dataRestore=3,dataDeletion=4 (R15 enum retained).
Kind: staging=1,manifestFinalized=2,emission=3,deletion=4,terminal=5.
Common fields occur only in the outer object; payload deliberately omits them; copies must not be emitted.
Payload is selected by kind, never by optional-field inference:

|kind|exact payload fields|
|---|---|
|staging|`{nextUnit:U32,unitCount:U32,workPlanHash:H,lastUnitHash:H?}`|
|manifestFinalized|`{preEmissionFinalizationHash:H}`|
|emission|`{nextOrdinal:U64,durableEndOffset:U64,durableFrameHash:H?,planHash:H}`|
|deletion|`{intentID:UUID,nextTarget:U32,targetCount:U32,workPlanHash:H,lastTargetProofHash:H?}`|
|terminal|`{outcome:Outcome,lastWork:WorkCursor?,finalizationHash:H?,bindingRecordHash:H?,errorCode:Error?}`|

WorkCursor is one complete Cursor with kind 1/2/3/4, never terminal; receiptID/Op must match.
Outcome: sinkFinalized=40,bound=50,committed=60,failed=90,cancelled=91.
Phase V8: staging=10,manifestFinalized=20,emitting=30,deleting=35,sinkFinalized=40,bound=50,committed=60,failed=90,cancelled=91.
This is a NEW phase enum; do not add undeclared values to V7. Phase numbers 10/20/30/40/50/60/90 retain V7 meanings.
Error is a closed ASCII enum from R17-04/05 plus `invalidVariant,phaseMismatch,invalidBounds,invalidNullability,invalidTransition,headMismatch,receiptIdentityConflict,corruptLog,capacity,permanentFailure,userCancelled`.

## Variant / phase / operation table

|Op|phase|kind|legal next phase|
|---|---|---|---|
|1,2,3|staging|staging|staging (one durable unit), manifestFinalized|
|1,2,3|manifestFinalized|manifestFinalized|2→emitting; 1,3→sinkFinalized after all projection markers and source verification|
|2|emitting|emission|emitting (exactly one durable frame), sinkFinalized|
|4|deleting|deletion|deleting (one durable target), sinkFinalized|
|all|sinkFinalized|terminal outcome=40|bound|
|all|bound|terminal outcome=50|committed|
|all|committed,failed,cancelled|terminal matching outcome|none; identical retry is no-op|

Every nonterminal phase may fail permanently or be explicitly abandoned into failed/cancelled.
Task cancellation, sleep, disk-full and transient I/O ONLY return an error; they preserve resumable phase/cursor.
Explicit `abandon(receiptID,expectedHead)` emits cancelled/userCancelled and freezes the lastWork; never rollback completed effects.
New work after abandonment uses a new operation/receipt ID, not a reset of this receipt. Attempt is immutable within V8.

## Bounds and nullability

Staging unit count is 0...26. Export unit is one fully staged pack, sorted registry order.
Import/restore unit is one fully verified/projected pack; R9 domain marker must be durable before advancement.
A unit may be retried internally; the pack cursor advances only after every child marker validates.
Deletion target count is 1...10,000; sorted `(storeID UTF8,entityID lowercase UUID)` targets have unique keys.
Both next indexes are inclusive 0...count; completed sentinel is count, never a nonexistent target reference.
lastUnitHash/lastTargetProofHash is null iff index=0. Hash is the completed pack/target marker hash.
An emission cursor points to the NEXT frame; range 0...totalFrameCount, offset=0/hash=null iff ordinal=0.
Pass/kind/pack/chunk/path are derived from immutable plan at nextOrdinal; they are NOT persisted duplicate cursor fields.
Successful terminal lastWork is the completed work cursor, not null; failure/cancel keeps the exact prior work cursor.
At outcome40 finalizationHash required/binding null; at50/60 both required; errorCode null.
At90/91 errorCode required; finalization/binding copied if already present, never synthesized or cleared.
For failed/cancel from a successful terminal phase, lastWork copies that terminal's lastWork (no nested terminal).
No failed/cancel transition is allowed from committed. lastWork is null only for a migrated pre-work failure with proof of no effects.

## Pre-finalization and durable completion

PreRecord (retains public name LifeOSPreEmissionFinalizationV8) is exactly:
`{schemaVersion:8,finalizationID:UUID,receiptID:UUID,operationKind:Op,archiveID:UUID,packCount:U16,fileCount:U32,manifestCount:U32,planHash:H,archiveHash:H,manifestRootHash:H,createdAt:timestamp,preEmissionFinalizationHash:H}`.
Its hash domain is `LifeOS/pre-emission-finalization/v8`, excluding its own hash. All archive Ops require it; deletion forbids it.
Persist it with manifestFinalized only after immutable source/staged objects and complete work plan verify.
Export ordering: stage all packs → manifest/root/archive hashes → plan → PreRecord → emission cursor 0 → frames.
Import/restore: verify source archive before projection; stage cursor tracks durable projection packs; PreRecord then binds that immutable source.
Those operations do NOT emit a duplicate archive. Their emission-plan hash describes source frame order and is verified on finalization.
Deletion uses its workPlanHash and complete target-marker fold; no archive/manifest/file hash is fabricated.
`finalizeArtifact` rejects unless export cursor=totalFrameCount and sink finalized, import/restore nextUnit=count and all markers verify,
or deletion nextTarget=count and each durable deletion marker verifies. Caller claims never establish completion.
R15-01 finalization/binding V7 field sets and v7 hash domains remain unchanged, including typed logical deletion.
Import/restore finalization describes immutable SOURCE bytes; application target-marker completion is additionally mandatory.

## One dispatcher and calls

`validateReceiptCursorV8(candidate:Cursor, phase:PhaseV8, operation:Op, receiptID:UUID, previous:ReceiptSnapshotV8?, work:WorkPlanV8, emission:EmissionPlanV7?, pre:PreRecord?, finalization:FinalizationV7?, binding:BindingV7?, durable:DurableCompletionV8?) throws`.
WorkPlanV8 is `{operationKind:Op,workPlanHash:H,unitHashes:[H],targetKeys:[{storeID:String,entityID:UUID}]}`;
export/import/restore use unitHashes <=26 and empty targets; deletion uses targets and empty unitHashes.
workPlanHash=H(`LifeOS/receipt-work-plan/v8`, object without hash); bind before first effect, never mutate.
DurableCompletionV8 is an in-memory capability constructed only by P18 verifier under its lock:
`{receiptID:UUID,workPlanHash:H,completedCount:U32,artifactFileHash:H?,finalizationHash:H?}`; never decode it from external input.
Dispatcher checks common identity and table first, then selected payload bounds, previous edge, plan position, evidence and record hashes.
`advanceStage(id,expectedHead,nextUnit,lastUnitHash)`, `advanceDeletion(id,expectedHead,nextTarget,lastTargetProofHash)` advance exactly one.
`advanceEmission(id,expectedHead,nextOrdinal,endOffset,durableFrameHash,recoveryAction)` advances exactly one.
`recordPreEmissionFinalization(record,expectedHead)`, `beginEmission(id,expectedHead)`, `finalizeArtifact(input,expectedHead)`,
`bindArtifact(id,expectedHead,expectedFinalizationHash)`, `commitBound(id,expectedHead,expectedArtifactHash)` and `abandon` all use the same dispatcher.
No recursive cursor hash or lastTransitionHash appears inside a cursor. A head belongs to the transition/container.
Same complete operation preimage and expected previous head returns existing result; other stale CAS returns headMismatch.
