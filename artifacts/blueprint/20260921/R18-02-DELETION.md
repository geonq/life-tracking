# R18-02 — complete deletion targets and durable proof

> R19-07-DISPATCH.md supersedes the six topics under review; use R19 active-schema and capacity rules. This R18 sheet is retained only where expressly compatible.

Replaces R17-01 UUID targetKeys and R7-05/R9-02 deletion ordering/marker clauses; retains the closed26-store registry.
P01 declares pure types/hash validation; P18 LifeOSDataManagement orchestrates; store owners implement descriptor ports.
Use R17 CJ/F/H/UUID/U32/U64 notation. IDs are NEVER coerced to UUID when the source domain uses strings.

## Exact tagged schema

`DeletionTargetV8={storeID:LifeOSDataStoreID,host:Host,kind:TargetKind,selector:Selector}`; Host apple=1,windows=2.
TargetKind entityUUID=1,nativeID=2,file=3,keyValue=4,wholeStore=5,trust=6,widgetRegeneration=7.
The selector has EXACT keys from its row, no nullable union of every case:

|kind|selector|constraints|
|---|---|---|
|1|`{entityID:UUID}`|only descriptor explicitly registered with UUID domain identity|
|2|`{namespace:String,id:String}`|namespace descriptor constant; id exact domain-native canonical value,1..256 UTF8 bytes|
|3|`{relativePath:String}`|1..512 UTF8, NFC, pinned descriptor-relative file; no absolute/dot-dot/symlink paths|
|4|`{suite:String,key:String}`|suite exact standard or validated App Group; key1..256 bytes, closed descriptor allowlist|
|5|`{}`|delete all current user contents, including an already-empty store; preserve infrastructure/audit markers|
|6|`{datasetID:UUID,scope:String}`|scope exactly replicationEnrollment; replicationTrust only|
|7|`{datasetID:UUID}`|widgetSnapshot only; publish canonical empty/redacted snapshot, never delete then leave stale cache|

All strings reject NUL/control characters; namespace/suite<=128 bytes. nativeID is validated by its domain codec, not normalized arbitrarily.
`targetKey=H("LifeOS/deletion-target/v8",target)`; target encoded <=1024 bytes; duplicate targetKey rejected.
WorkPlanV8 replaces `targetKeys` with `targets:[DeletionTargetV8]`; retains operationKind,workPlanHash,unitHashes.
Hash is H("LifeOS/receipt-work-plan/v8", complete object excluding workPlanHash). Archive operations require targets=[]; deletion unitHashes=[].
1..10000 targets, whole encoded work plan<=2MiB; byte cap wins over count. Check before mutation; never truncate.
A wholeStore overlaps every same-store/host selective target: reject overlapping plans, do not silently drop requests.
Host coverage comes from registry descriptors; unreachable Windows targets stay pending, never recorded as empty.

## Canonical plan and exact registry coverage

Sort by `(stage,registryOrdinal,host,kind,CJ(selector) UTF8 lexicographic)`; registryOrdinal is R7-05 enum order, NOT name order.
stage0 ordinary targets; stage1 replicationTrust; stage2 widgetRegeneration. Unique final widget target is mandatory.
Full delete plans one wholeStore per descriptor host for24 stores excluding replicationTrust/widgetSnapshot, then trust target(s), then widget.
Empty stores remain targets and produce proof. Windows usageLocal/clipperLocal are separate host targets; no silent local-only full delete.
trainingTemplates selective identity uses nativeID namespace `trainingTemplate`; retain stored string identifier unchanged.
calendar/finance/training/meals/etc use descriptor's validated native entity key; non-UUID finance keys use nativeID, never synthetic UUIDs.
taxRaw/nutritionPhotoOriginals/planningFiles use allowlisted file selectors for selective delete; full delete uses wholeStore.
usageLocal/clipperLocal Apple use keyValue selectors for selective reset; full delete uses wholeStore with closed key list.
planningJournal wholeStore clears user journal data through its SQLite owner; planningFiles clears owned cache/filesystem only, NOT external vault originals.
recoveryImports wholeStore removes old user import history, NOT current Receipts authority, this deletion's journal or audit key.
replicationTrust target revokes enrollment, endpoints and replication credentials AFTER all remote targets are proved, while retaining device receipt-authority key.
This is user-content deletion, not an audit-infrastructure factory reset. No sync can restart without explicit new enrollment.

## Exact adapter and fence API

Retain `LifeOSDataStoreAdapter.deletePack() async throws` as the sole wholeStore effect, idempotent when already empty.
Add `prepareDeletion(_ target: DeletionTargetV8, context: DeletionContextV8) async throws -> DeletionPreparedV8`;
`applyDeletion(_ target: DeletionTargetV8, context: DeletionContextV8) async throws -> DeletionAppliedV8`;
`inspectDeletion(_ target: DeletionTargetV8, context: DeletionContextV8) async throws -> DeletionAppliedV8?`.
Context={receiptID:UUID,operationID:UUID,fenceID:UUID,targetKey:H,expectedBeforeHash:H}; domain host port is authenticated/injected.
Prepared={beforeHash:H,scopeVersion:U64}; Applied={afterHash:H,markerHash:H}; each is typed, not caller-provided proof.
prepare takes descriptor's exclusive mutation fence; beforeHash hashes canonical current selected content (empty has a real hash).
apply wholeStore calls deletePack(); entity/native ID calls existing owner's validated delete by EXACT domain key;
file uses pinned nofollow unlink+parent fsync; keyValue uses existing durable preferences adapter write+readback, never synchronize() as proof.
If preferences cannot prove durable deletion, persist the deletion marker and cleared value in its existing file-backed persistence owner before returning.
trust invokes SyncTrustStore enrollment revocation and SyncIdentityStore.retire for replication roles; never retires receipt-authority key.
widget invokes P14 `WidgetSnapshotPublisher.publishAfterDeletion(fenceID:) async throws -> DeletionAppliedV8`.
P14 writes/fsyncs/atomically publishes empty/redacted App Group snapshot, verifies readback and requests WidgetCenter reload; render timing is external evidence.
Absent configured App Group returns capabilityUnavailable; no false final proof; deletion can resume after capability repair.
Store adapters retain `(receiptID,operationID,targetKey,beforeHash,afterHash,fenceID)` marker with the mutation in existing envelope/SQLite transaction.
For file/key/trust effects without atomic marker transaction, use central prepare→effect→inspect→proof sequence below; inspect proves exact absence/revocation.
Remote host performs the same idempotent context/marker check through authenticated P02 gateway adapter; failure/offline leaves current target pending.
Full deletion takes a dataset write fence, disables inbound projection/provider refresh and cancels/awaits active writers before enumeration.
Fence persists in deletion journal; startup recovers it before enabling any producer. No user/provider writes within scope until60 or explicit abandon.
Abandon releases local content fences only after effects settle; trust revoked state remains revoked. Failed remote deletion remains visibly incomplete.

## Durable journal and marker encoding

Use existing logical artifact `DataManagement/delete-journal.json` as a bounded canonical journal container, not a new source path.
`DeletionJournalV8={schemaVersion:8,receiptID:UUID,operationID:UUID,fenceID:UUID,workPlanHash:H,prepared:DeletionIntentV8?,proofs:[DeletionProofV8],fenceClosed:Bool,journalHash:H}`.
Intent={targetIndex:U32,targetKey:H,beforeHash:H,scopeVersion:U64}; at most one pending intent, index=proofs.count.
Proof={targetIndex:U32,targetKey:H,beforeHash:H,afterHash:H,markerHash:H,previousProofHash:H?,proofHash:H}.
proofHash=H("LifeOS/deletion-proof/v8",proof excluding proofHash); previous null only index0, otherwise preceding proofHash.
markerHash=H("LifeOS/deletion-marker/v8",{receiptID,operationID,fenceID,targetKey,beforeHash,afterHash}); adapters use this identical preimage.
Absent/empty afterHash=H("LifeOS/deletion-after/v8",{targetKey,state:"absent"}); widget uses state:"redacted",snapshotHash as third key.
Every other mutation marker afterHash must equal expected empty/absent postcondition; content hash alone cannot assert deletion.
journalHash=H("LifeOS/deletion-journal/v8",journal excluding journalHash); <=16MiB, proofs<=10000, proof<=1024 bytes.
P18 atomically replaces/fsyncs journal+parent under coordinator lock; journal is private/protected and excluded from own deletePack scope.
Before effect: persist intent. After effect: verify durable marker/postcondition, append proof and clear intent in ONE replacement; then advanceDeletion.
Crash before effect retries exact intent. Crash after effect re-inspects: proven absent/exact marker→persist proof; still exact pre-state→retry; other state→staleTarget.
Crash after proof before receipt advance: verify hash chain/target plan and advance once. Never repeat an acknowledged destructive mutation.
Recompute all proofs against plan at finalization; set fenceClosed=true durably after final widget proof; close input fence only after phase60.
Deletion finalization keeps null archive/file hashes per R15; sinkCommitID remains logical-deletion:<receiptID>; immutable journalHash bound by completed lastTargetProofHash chain.
Retain journal until receipt is terminal and retry policy permits pruning; do not remove active journal via recoveryImports deletion.
One deletion at a time per dataset; second active operation returns deletionInProgress. Selective operations use same serialized journal lifecycle.
Before reusing delete-journal.json for new work, require previous receipt60/90/91, explicit terminal prune per R18-05 and settled effect verification.
A retained resumable40/50 receipt blocks reuse. Prune makes the prior retry explicitly expired; no stale journal proof can be reused for a new receipt.
Complexity O(targets log targets + bytes deleted/verified), proof-fold O(targets); journal replacement is bounded, not claimed O(1).

## Planned verification / ownership

P03/P04/P06/P13/P12/P14 implement their owned domain ports; P18 owns orchestration/journal; P01 owns shared types, P02 host port.
P01 SyncProtocolTests: string template IDs, all seven variants, empty wholeStore, overlap/bounds/hash vectors and canonical ordering.
Domain tests: marker+mutation atomicity and same-context retry; files/keys/trust crash after effect before proof; changed pre-state rejected.
P18 CompletionFlowsTests: all26 stores, Windows offline/rejoin, trust last, widget last, empty registry data, crash each durable boundary.
Final receipt cannot reach40/60 while any target/proof/widget/fence requirement is missing. No application tests were run for this document.
