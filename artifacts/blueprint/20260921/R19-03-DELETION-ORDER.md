# R19-03 — deletion preparation, creation command and durable order

> R20-06-DISPATCH.md explicitly supersedes the five reviewed topics and related field additions; this R19 sheet remains authoritative only where retained. Prior readiness is historical.
Supersedes R18-02 circular DeletionContextV8 preparation and R18-01 undefined prepareDeletion command.
R18 target variants/order/caps, native IDs, marker/proof hashes and domain ownership remain unless changed here/R19-04/05.
P01 declares values/ports; P18 LifeOSDataManagement owns operation setup and journal; coordinator owns receipt CAS.

## Exact inputs and conversion

`DeletionPrepareInput19={receiptID:UUID,operationID:UUID,authorityID:UUID,fenceID:UUID,workPlanHash:H,targetIndex:U32,target:DeletionTargetV8,targetKey:H}`.
TargetKey MUST recompute from target. Input includes no expectedBeforeHash/scopeVersion and never computes state outside owner fence.
`DeletionPrepared19={inputHash:H,beforeHash:H,scopeVersion:U64,preparationHash:H}`.
inputHash=H("LifeOS/deletion-prepare-input/v19",input); preparationHash=H("LifeOS/deletion-prepared/v19",prepared excluding preparationHash).
`DeletionApplyContext19={input:DeletionPrepareInput19,prepared:DeletionPrepared19}`; exact objects, not optional flattened fields.
`makeDeletionApplyContext(input:DeletionPrepareInput19,prepared:DeletionPrepared19) throws -> DeletionApplyContext19` validates hashes/target/IDs only.
`prepareDeletion(_ input:DeletionPrepareInput19) async throws -> DeletionPrepared19`
`applyDeletion(_ context:DeletionApplyContext19) async throws -> DeletionAppliedV8`
`inspectDeletion(_ context:DeletionApplyContext19) async throws -> DeletionInspection19`
Inspection19 tagged `{state:State,applied:DeletionAppliedV8?}`; state before=1,applied=2,changed=3; applied required ONLY2.
R18's three target+context overloads are retired. Whole-store deletion still calls owner's deletePack internally, never direct UI call.
Prepare verifies dataset fence, pauses/drains relevant writer, captures canonical beforeHash + durable scopeVersion and stores prepared token once.
Same input after response loss returns original stored Prepared, even if effect already applied. Different input for same target operation fails idCollision.
Apply checks existing exact marker FIRST; matching marker returns it. Otherwise rechecks original beforeHash/version under same fence.
Changed state returns staleTarget; never recapture a new beforeHash for an existing intent or silently broaden deletion.
Inspection needs persisted prepared context; hash-equivalent empty state without matching intent is not proof of this operation's deletion.

## Exact receipt creation command

Add Action `prepareDeletion` to R18-05 ReceiptCommandV8; all existing action strings unchanged.
Arguments EXACT `{identity:IdentityV8,operationKind:4,workPlanHash:H,fenceID:UUID,setupHash:H}`.
expectedSequence/head both null; attempt0 for new operation. Existing receipt retry follows same requestHash/evidence rules.
Generic prepare permits ONLY Ops1..3 and phase10; prepareDeletion permits ONLY Op4 and initial phase35.
Initial deletion cursor.intentID=fenceID, nextTarget=0,targetCount=plan.targets.count,lastTargetProofHash=null.
Both prepare actions are exempt from required expected pair; every other action requires both values.
RequestHash uses unchanged LifeOS/receipt-command/v8 domain over full object including new action/arguments.
`LifeOSReceiptCoordinator.prepareDeletion(_ command:ReceiptCommandV8,setup:VerifiedDeletionSetup19) throws -> RetryOutcomeV8`.
VerifiedDeletionSetup19 is internal/non-Codable and constructed by P18 after rereading verified plan+journal/fence from disk.
Caller may not create phase35 with only a hash or declaration that setup exists.

## Canonical plan and initial journal

R19 WorkPlan includes restoreUnits=[] for deletion. Validate complete plan/size/hash before filesystem mutation or remote request.
Allocate operationID/fenceID once; derive receipt/prepared IDs under existing R9 identity rules. Never regenerate on retry.
`DeletionSetup19={identity:IdentityV8,receiptID:UUID,operationID:UUID,attempt:U16,authorityID:UUID,fenceID:UUID,workPlan:WorkPlanV8,setupHash:H}`.
setupHash=H("LifeOS/deletion-setup/v19",setup excluding setupHash); <=2MiB plus4096 metadata, no source payload.
Journal uses R18 proofs/chain but schemaVersion19, adds required setup:DeletionSetup19 and pending:DeletionApplyContext19?;
removes old prepared:DeletionIntentV8? field. Keeps receiptID,operationID,fenceID,workPlanHash,proofs,fenceClosed,journalHash.
Add required fenceState: holding=1,settled=2,released=3 and completion:DeletionCompletion19? (R19-05).
Journal cap remains16MiB including plan and proofs; journalHash=H("LifeOS/deletion-journal/v19",journal excluding journalHash/completion).
Completion is excluded here to avoid circular hash; R19-05 defines immutable terminal journal projection and signature binding.
Local setup journal is sole durable admission fence; ephemeral per-owner locks are derived from it at startup.

## Ordered operation and recovery

1. Obtain exclusive P18 process/interprocess lock. Check previous journal terminal/settled and reserve receipt/file capacity.
2. Validate canonical plan, source ownership and explicit user deletion intent; stop scheduling local writers and await owned in-flight work.
3. Write initial journal (setup,proofs=[],pending=null,fenceState=holding,fenceClosed=false,completion=null), fsync file+parent.
   This atomically publishes plan AND initial fence. No separate plan file can race journal creation.
4. Reread/verify journal/setup; authorize aggregate receipt transaction for prepareDeletion; commit phase35 + retryEvidence durably.
5. Only after4 prepare first target through owner port. Remote prepare occurs here, before any target effect.
6. Persist pending full context+recomputed journalHash; fsync. Apply exact context; inspect marker/post-state; append proof/clear pending atomically.
7. Advance receipt one target after proof durability. Repeat; finalize with R19-05/06 only when targetCount reached.
Every startup recovers this journal before enabling producers, including when no matching receipt yet exists.

|crash boundary|deterministic action|
|---|---|
|before3|no durable fence/effects; discard only owned incomplete temp; no claimed operation|
|after3 before4|verify setup; recreate identical prepareDeletion command; commit35 then resume; do not issue effects without35|
|during aggregate receipt replacement|R17 authority intent recovery first; use exact original request and R18 retry evidence|
|after4 before prepare response|call prepare with same input; owner returns persisted Prepared or creates it once while fenced|
|after prepare before6 intent|same prepare lookup; no effect permitted before central pending commit|
|after6 before/after effect|inspect context: before→apply; applied→proof; changed→staleTarget; no blanket delete retry|
|after proof before advance|verify chain+plan and advance once from receipt count; original target not replayed|
|receipt exists, journal absent/invalid|deletionRecoveryMissing/corruptLog; preserve state, prevent producers, no empty reconstruction|
|journal and receipt identities conflict|receiptIdentityConflict; no mutation or inferred new operation|

Task cancellation/disk-full retains durable phase/fence. Explicit abandon first reconciles all pending effects and writes terminal91.
Remote fence must be settled/released through R19-04 before local release on abandon; offline leaves abandonment pending and visibly incomplete.
Successful deletion keeps remote collectors disabled and replication revoked; local fence releases after60 as a separate idempotent step.
Do not reuse journal until prior terminal proof is retained/pruned under R19-05; only one active deletion per dataset.

## Planned verification

P01 command tag/phase matrix, complete context hash vectors, mismatch beforeHash and domain-native string IDs.
P18 crash each numbered boundary; phase35 never references missing plan; apply never precedes pending durability.
Domain/remote tests assert lost prepare response returns original token, changed state blocks, empty store still produces one proof.
No code/build/test execution performed here.
