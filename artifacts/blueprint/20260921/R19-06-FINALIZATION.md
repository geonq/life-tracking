# R19-06 — deterministic new-operation finalization and publication

> R20-06-DISPATCH.md explicitly supersedes the five reviewed topics and related field additions; this R19 sheet remains authoritative only where retained. Prior readiness is historical.
Supersedes R16 FinalizedArchiveV8 fields, R18-04 zero-argument finalize and R18-05 unspecified stable sink time.
Retains R18 writer append, R17 exact frame/footer bytes/recovery, R15 V7 finalization/binding object fields and nondeletion hash domains.
P01 declares public values/pure identity functions; P18 writer/coordinator owns persistence/publication. No new source/sink sidecar.
Timestamp means signed UTC milliseconds, never fs metadata modification/birth time. No claim a timestamp itself proves storage durability.

## Stable source of time and identity

R19 IdentityV8 adds required `preparedAt:timestamp` and `installationID:UUID` to R17 fields.
Sample preparedAt ONCE before first prepare; persist with sequence0; unpublished candidate on retry can be reused only if identical identity.
After a durable setup exists, every retry/reopen uses its original time. For deletion copy from DeletionSetup19.identity.preparedAt.
`durableAt=preparedAt` and `boundAt=preparedAt` for NEW operations: logical operation time, NOT measured finish time.
UI duration/finished display must use separately observed telemetry if present, never label this stable identity timestamp as actual completion time.
This explicit logical-time convention avoids sampling after an external effect. R18 phrase stable sink time now means this stable operation timestamp.
Historical V6/V7 migration keeps original validated B.boundAt/durableAt per R18-03; never replace them with new current time.
`finalizationID=UUIDv5(namespace:receiptID,name:F("LifeOS/finalization-id/v19",CJ({attempt,preparedArtifactID,operationKind})))`.
`bindingRecordID=UUIDv5(namespace:receiptID,name:F("LifeOS/binding-id/v19",CJ({attempt,finalizationID})))`.
Same finalizationID used by PreRecord; PreRecord.createdAt=preparedAt. No random UUID allocation during finalize/bind/reopen.
R19-03 Setup identity includes the same new fields; setupHash authenticates them before receipt publication.

## Complete publication preparation (persist before external publication)

PublicationPreparation19 is EXACT:
`{schemaVersion:19,receiptID:UUID,operationID:UUID,attempt:U16,preparedArtifactID:UUID,operationKind:Op,finalizationID:UUID,bindingRecordID:UUID,archiveID:UUID?,archiveHash:H?,manifestRootHash:H?,workPlanHash:H,completionRoot:H?,deletionCompletionHash:H?,relativePath:String,representation:String,protection:String,retention:String,byteCount:U64,fileCount:U32,chunkCount:U32,artifactFileHash:H?,artifactIdentityHash:H,durableAt:timestamp,boundAt:timestamp,sinkCommitID:H,preparationHash:H}`.
All nullable keys explicit. Op2 completionRoot/deletionCompletionHash=null; Op3 completionRoot=R19-02 root; Op1 completionRoot=existing verified replication marker fold.
Op4 completionRoot=null, deletionCompletionHash=R19-05 completionHash, archiveID/archiveHash/manifestRootHash/artifactFileHash=null.
Op1/2/3 artifactFileHash hashes ORIGINAL source/export bytes; all archive fields required; preparedArtifactID always required for new operations.
Op4 byteCount/fileCount/chunkCount=0, relativePath=`DataManagement/delete-journal.json`, representation=`logical.deletion.v19`.
Other representation/protection/retention exactly from verified immutable work/source descriptor, never caller guesses/defaults at finalization.
For Op4 artifactIdentityHash R19-05; for others R15 identity preimage. Include full archive/file/count/path identity in preparation.
`sinkCommitID=H("LifeOS/sink-commit/v19",preparation excluding sinkCommitID/preparationHash)`.
`preparationHash=H("LifeOS/publication-preparation/v19",preparation excluding preparationHash)`; no circular reference.
Preparation<=4096 CJ bytes; all strings use retained closed representation/protection/retention enums and path cap128.
SnapshotV8 gains required nullable `publicationPreparation:PublicationPreparation19?`; included in transition/anchor hash via complete snapshot.
Add ReceiptCommand Action `preparePublication`, arguments exactly `{preparation:PublicationPreparation19}`, expected head/sequence required.
Legal self-edge20→20 for Op1/3,30→30 for Op2,35→35 for Op4 ONLY this command; cursor unchanged, full verified work required.
Extend R18-01 prohibition on other self-transitions specifically by these three validated preparation edges; generic same-phase updates still forbidden.
Result.detailKind=publication, detail=PublicationPreparation19; extend closed Result detail union, cap unchanged12288/evidence13312.
Snapshot may contain preparation only after completed work; immutable thereafter; every40/50/60 requires it for new operations.
For Op4 preparePublication snapshot ALSO stores complete DeletionCompletion19; no separate proof-only transition needed.
preparePublication commit precedes sink publication and40. It becomes last retry evidence normally; changed preparation after commit is receiptIdentityConflict.
Before publication P18 verifies prospective snapshot/transition/result/evidence caps; no effect if encoded record cannot be retained.

## Exact writer result and methods

`LifeOSFinalizedArchiveV8` replaces R16 shape with `{relativePath:String,byteCount:U64,artifactFileHash:H,archiveHash:H,manifestRootHash:H,sinkCommitID:H,durableAt:timestamp,preparationHash:H}`.
This is internal-init Sendable capability, not externally decodable proof. P18 constructs only after verification/file+parent sync.
`LifeOSArchiveSinkV8.finalize(preparation:PublicationPreparation19) throws -> LifeOSFinalizedArchiveV8` replaces finalize().
`LifeOSFileArchiveSinkV8` verifies completed plan/bytes/count/hash against persisted preparation, fsyncs partial, publishes without overwriting foreign final bytes,
fsyncs parent, reopens/verifies exact final object and returns preparation's stable identity/time with actual verified hashes/counts.
Never writes an extra footer. Existing final path identical→repeat fsync/verify and same result; different→sinkFinalArtifactMismatch.
`inspectCompletedArtifact(plan:) throws -> VerifiedArtifactDescriptor19` computes bounded streaming hashes/counts on fully verified partial/source, no rename.
Descriptor19={relativePath,byteCount,fileCount,chunkCount,artifactFileHash,archiveHash,manifestRootHash,representation,protection,retention}; internal init only.
Coordinator `preparePublication(receiptID:expectedHeadHash:)` builds preparation from descriptor + durable identity + complete domain proof; persists it first.
R17 reconcileSinkAhead no longer invokes finalize implicitly. It adopts verified frames and returns finalArtifact=null until preparation exists.
If footer complete but preparation absent it returns aligned completed cursor; coordinator preparesPublication, then calls explicit finalize(preparation:).
If final file already exists with matching stored preparation, reopen verifies it and returns same finalized result; no new time/ID is sampled.

## Exact command construction and call order

P01 defines `makeFinalizationInput(preparation:PublicationPreparation19,expectedHeadHash:H) -> LifeOSReceiptArtifactFinalizationInputV7`.
Input19 alias retains V7 name but exact fields = ALL FinalizationV7 fields excluding finalizationHash, plus expectedHeadHash; schemaVersion7.
Copy receiptID/attempt/op/IDs/path/counts/policies/hashes/sinkCommitID/durableAt from preparation; recompute artifactIdentityHash; no input fields sourced from clock.
P18 finalize rechecks internal sink capability OR source/domain/deletion completion and persisted preparation equality before constructing input.
`finalizeArtifact` command expected pair is durable preparePublication head; input.expectedHeadHash identical; no intervening receipt command permitted.
FinalizationHash uses unchanged LifeOS/receipt-finalization/v7 preimage. FinalizationIDs/preparedArtifactID never null for new ops.
`makeBinding(preparation:PublicationPreparation19,finalization:FinalizationV7) throws -> BindingV7` copies exact R15 fields,
uses preparation.bindingRecordID/boundAt, finalization ID/hash; BindingV7 hash unchanged LifeOS/receipt-binding/v7.
bind command at40 arguments expectedFinalizationHash only; commit command at50 typed expected file/identity/binding hashes from stored binding.
Success only60. Retry window still most recent successful command; expired earlier commands cause state reconciliation, never effect replay.
Op2: complete frame adoption -> preparePublication -> finalize(preparation:) -> finalizeArtifact40 -> bind50 -> commit60.
Op1/3: complete verified domain proofs/source -> preparePublication -> reverify source/proofs ->40 ->50 ->60; no archive re-publication.
Op4: R19-05 settled completion -> preparePublication -> reverify completion/fence ->40 ->50 ->60 ->local fence release.

## Reopen and lost-response table

|durable state|action|
|---|---|
|complete work, no preparation|verify immutable bytes/proofs; derive IDs/time from persisted identity; commit identical preparation once|
|preparation durable, partial not published|verify partial matches preparation, finalize; retain preparation on any I/O failure|
|published final before40|verify final bytes and preparation, fsync file/parent, reconstruct identical finalizeArtifact command from preparation head|
|preparePublication response lost|same command returns stored evidence; caller may instead read current preparation and continue explicitly|
|finalize response lost and phase40|identical request replays FinalizationV7; reopening reads it and constructs bind with current40 head|
|between40/50|stored finalization+preparation produce same bindingID/time/fields; no file/domain effects repeated|
|bind response lost and phase50|replay stored binding; reopen constructs commit with current50 head and stored typed hashes|
|between50/60|validate binding/authority intents then commit exactly once; response lost at60 replays commit result|
|original retry superseded/pruned|R18 typed expired outcome; load current state/retained summary, never manufacture original full response|
|final bytes without matching preparation|receiptRecoveryNeedsPreparation; preserve file, no adoption from mtime/filename alone|

Compaction retains identity/preparation at all resumable phases; terminal logs keep preparation summary sufficient for hash verification.
R19 new snapshot/identity shapes are schema refinement before implementation; observed older V8 handled read-only, not silently relabeled.
V6/V7 migration retains historical identity/time/hash validation and marks provenance; no new-operation IDs imposed on historical bound artifacts.
Planned checks: crash every preparation/publication/40/50/60 boundary; repeated command bytes/IDs/time identical after reopen; clock jumps have no effect.
No application code or tests executed; these are implementation instructions, not runtime proof.

## Revised encoded capacity (supersedes conflicting R18 limits)

New fields are part of snapshots/anchors, not duplicated top-level log projections. No unbounded receipt proof array enters Snapshot.
Set snapshot<=16384, transition<=24576, anchor<=24576, result<=24576, retryEvidence<=25600 CJ bytes.
Keep max32 retained transitions; compact before33. Active Log<=4MiB, WorkPlan<=2MiB; compact terminal Log<=65536; File<=64MiB.
At8 active: plans16MiB + transitions6MiB + anchors/evidence<0.4MiB + fixed overhead<=1MiB;256 terminal logs<=16MiB; total<40MiB.
Retired summaries<=8192 count toward same terminal256 cap. Reserve prospective exact encoded bytes; count cap never overrides byte cap.
Max426406 frame/lifecycle transitions plus preparation require<13326 compactions; sequences remain U64, cursor remains resumable.
Terminal compaction retains FULL PublicationPreparation19 (<=4096), full deletion completion if present and last retry evidence.
R19-05 terminal32768 reference is replaced by65536 here. R18 result/evidence caps quoted earlier are superseded by this section.
Bounded storage cost is explicit; no claim O(1) whole-file persistence. Full64MiB allocation is not required: stream canonical file encoding/hashing.
