# R17-02 — V8 receipt container, migration and bounded compaction

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Replaces R16 V8 delta, R15-01 anchor/log/migration-active shape and R11 receipt capacity/cadence.
Retains R15-01 finalization/binding objects and hashes verbatim. P18 owns persistence; P01 canonical encoding.
All exact objects use R17-01 notation. No V7 anchor/cursor occurs inside an active V8 record.

## Exact wire schemas

FileV8 = `{schemaVersion:8,domain:Domain,migrationEpoch:U64,writeSequence:U64,logs:[LogV8],retiredIDs:[RetiredIDV8]}`.
Domain numeric: recovery=1,data=2,deletion=3; file mapping is R17-07. Reject other values.
LogV8 = `{schemaVersion:8,receiptID:UUID,operationKind:Op,attempt:U16,identity:IdentityV8,workPlan:WorkPlanV8,snapshot:SnapshotV8,headSequence:U64,headHash:H,anchor:AnchorV8?,transitions:[TransitionV8]}`.
IdentityV8 = `{operationID:UUID,preparedArtifactID:UUID,targetID:String,sourceManifestHash:H?,parentReceiptID:UUID?,parentTransitionHash:H?}`.
Identity is immutable, targetID <=128 UTF8 bytes; parent fields both null or both set. Preserve original identity, never derive from timestamps.
SnapshotV8 = `{phase:PhaseV8,cursor:Cursor,preEmissionFinalization:PreRecord?,finalization:FinalizationV7?,bindingRecord:BindingV7?,errorCode:Error?}`.
Snapshot is authoritative at anchor/transition; log.snapshot is an equality-checked projection.
TransitionV8 = `{schemaVersion:8,sequence:U64,transitionID:UUID,receiptID:UUID,operationKind:Op,attempt:U16,fromPhase:PhaseV8?,toPhase:PhaseV8,expectedHeadHash:H?,previousTransitionHash:H?,snapshot:SnapshotV8,recoveryAction:RecoveryAction?,createdAt:timestamp,transitionHash:H}`.
RecoveryAction is `sinkAheadAdopted=1`; truncation does not advance receipt state and has no receipt transition.
Hash=H(`LifeOS/receipt-transition/v8`, transition without transitionHash); no V7 domain with V8 bytes.
AnchorV8 = `{schemaVersion:8,anchorID:UUID,receiptID:UUID,operationKind:Op,attempt:U16,throughSequence:U64,throughHash:H,snapshot:SnapshotV8,migration:MigrationV8?,anchorHash:H,signerKeyID:String,signature:Data}`.
MigrationV8 = `{sourceVersion:7,sourceFileHash:H,sourceReceiptHeadHash:H,sourceAnchorHash:H?,sourcePhase:U8,sourceCursorHash:H,mappingRule:String}`.
Anchor hash=H(`LifeOS/receipt-anchor/v8`, anchor excluding anchorHash/signature); signature covers F(`LifeOS/receipt-anchor-signature/v8`, raw32(anchorHash)).
Device key must equal immutable authority's authorized key. signerKeyID <=64 ASCII; Ed25519 signatures exactly64 bytes/base64url no padding.
RetiredIDV8 = `{receiptID:UUID,operationID:UUID,terminalPhase:PhaseV8,terminalHeadHash:H}`; only60/90/91 permitted.
All lists sorted by lowercase receiptID except transitions by sequence. Duplicate ID across logs/retiredIDs is corruptLog.

## Chain and compaction

Fresh log starts sequence0, expected/previous=null, fromPhase=null and initial work cursor.
After anchor, first retained sequence=throughSequence+1 and previous/expected=throughHash; otherwise contiguous from0.
An empty transition list requires an anchor; head and snapshot then equal anchor throughHash/throughSequence/snapshot.
Regular compaction preserves the existing head hash/sequence, signs a complete anchor at head, removes all covered transitions.
It never creates an extra transition or changes cursor, identity, work plan, finalization or binding.
`compactReceipt(id,expectedHead)` validates complete chain, creates anchor, authorizes whole-file replacement (R17-07), then returns.
Order: encode new FileV8 → durable authority intent → fsynced replacement → parent fsync → authority commit.
No separate anchor file; a crash exposes old complete file or exact intended new complete file, resolved by R17-07.
Authority-log rotation is R17-06 and is independent. Neither operation may discard the other's recovery state.

## Capacity proof

At most8 active logs +256 terminal logs/retiredIDs per domain; new work at cap returns capacity before effects.
Transition <=8192 encoded bytes; snapshot <=6144, workPlan <=2MiB (10,000 bounded targets); anchor <=8192 excluding workPlan held once in log.
Retain at most128 transitions/log; before appending #129 compact to head anchor, then append.
Log <=4MiB, FileV8 <=32MiB. Check prospective byte size BEFORE starting work/next effect; compact eligible logs before capacity rejection.
Only deletion may need large workPlan; at most8×2MiB plans +8×(128×8192+8192) +256×16384 terminal summaries <29MiB plus <=1MiB file/identity overhead.
Terminal logs are compacted immediately; each compact terminal log <=16384 including its workPlan digest only.
For terminal logs, replace workPlan arrays by empty arrays and retain workPlanHash; validator uses completed snapshot and terminal proof, forbids resume.
For active logs workPlan arrays cannot be removed. WorkPlan hash recomputation is mandatory unless terminal-compacted.
R11 archive bounds retained:26 packs,106496 files,106752 data chunks. Data frames<=1+52+2×106496+106752=319797.
R17-03 permits <=4096 manifest chunks/pack and <=26 index chunks; carriers<=26×(4096+2)+(26+2)=106576.
Total frames<=426374 including one final footer; lifecycle/staging <=32, hence <=426406 transitions/export before compaction.
Sequences are U64; <3332 compactions at128 retained transitions; last cursor is always in anchor or latest transition.
Receipt size is independent of total archive frame count. No UInt32 ordinal overflow or 262144-transition dead end.
RetiredIDs are counted in256 cap; do not discard duplicate-operation protection automatically. Explicit history reset requires a new dataset/authority epoch.

## Deterministic V7 to V8

`migrateReceiptFileV7(bytes, verifiedArtifacts, verifiedWorkPlans, authorityKey) throws -> FileV8` is the only converter.
Validate original V7 chain/anchor/projections with its own versioned codec BEFORE conversion. Never reinterpret a V7 hash as V8.
Use authenticated rebasing: sign one V8 anchor with throughSequence=old head sequence, throughHash=new H(`LifeOS/receipt-migration-head/v8`, {receiptID,sourceFileHash,sourceReceiptHeadHash,snapshot,workPlanHash}).
MigrationV8 stores old hash evidence, source cursor hash=SHA256(CJ(old cursor)), original anchor hash/null and mappingRule below.
No old transition is rewritten. Preserve original whole-file bytes until authority retirement commits; anchor signature binds provenance afterward.
Each old phase has exactly these outcomes:

|V7 phase|rule and V8 result|
|---|---|
|staging|`stage` reconstruct next pack from authenticated staging markers; kind1/phase10 for Ops1..3; Op4→kind4/35 from deletion markers|
|manifestFinalized|`manifest` reconstruct PreRecord from verified manifest/plan and source/staging; kind2/20; Op4 invalid|
|emitting|`emit` Op2 only; match old ordinal/kind/pass against exact source plan and verified frame boundary; kind3/30|
|sinkFinalized|`sink` complete work evidence + valid FinalizationV7; kind5/40; binding null|
|bound|`bound` complete work evidence + finalization + verified binding; kind5/50|
|committed|`commit` same proofs + valid old terminal chain; kind5/60|
|failed|`fail` kind5/90 or91 iff old error explicitly cancelled; keep valid last work; no invented completion|

No other raw phase decodes as V7. Earlier V6 uses R15's V6 validation/mapping first, then this converter; ambiguous intermediate cursor returns receiptMigrationNeedsCursorUpgrade.
Missing identity/work markers/artifact/plan→receiptMigrationNeedsEvidence; contradicting evidence→corruptLog. Original bytes remain untouched on either.
V7 deletion staging/terminal handled above; Op4 manifest/emitting is invalid, not silently reclassified.
V7 import/restore emission is invalid unless an authenticated projection cursor exists; migrate by `project` to stage with verified pack markers, never replay archive frames as projection.
For manifest rule import/restore requires all projections complete; otherwise receiptMigrationNeedsEvidence.
For failed with no recoverable work cursor, lastWork=null only if no effect markers and original initial cursor proves zero work; otherwise block.

## Existing unwrapped archives

Do not rewrite a bound/committed archive. Detect LIFEOSAR/LIFEMNF legacy stream versus LOS8 wrapper by initial magic; never fallback after invalid detected format.
Source import/restore and migrated terminal exports use format-specific verified raw file hash unchanged; finalization representation preserves original format.
Active V7 unwrapped export migrates into a NEW owned partial artifact: stream-validate each exact old record, wrap its unchanged bytes,
fsync the new prefix, compute new offset/hash and rebase emission cursor. Keep old partial until new receipt/authority commit.
The new path is deterministically original owned partial path + `.v8`; confined same directory, exclusive create, refuse existing different bytes.
If wrapper candidate exists after crash, verify/reuse matching prefix; never append blindly or replace the old artifact.
After V8 receipt commit, only its wrapped candidate is resumable. Old partial becomes eligible for explicit owned-artifact cleanup.
No finalization/file hash is copied from unwrapped bytes into a wrapped artifact; semantic archiveHash is unchanged.
