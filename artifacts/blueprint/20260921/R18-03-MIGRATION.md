# R18-03 — historical binding verification and V8 migration

> R19-07-DISPATCH.md supersedes the six topics under review; use R19 active-schema and capacity rules. This R18 sheet is retained only where expressly compatible.

Supersedes R15-01 scalar-as-file-hash shim and R17-02 sentence routing V6 through that shim.
Retains R11-04/R12-02 exact ORIGINAL V6 hash preimages; retains R17 V7 phase mapping and authenticated V8 rebase.
P01 version-specific codecs in SyncWireCodec.swift; P18 migration in LifeOSReceiptCoordinator.swift; no source edits now.

## Format discrimination (before effects)

`decodeHistoricalReceipt(bytes: Data) throws -> VerifiedHistoricalReceipt` dispatches on schemaVersion and exact field set.
`HistoricalReceiptFormat` is v6InlineBinding, v6BindingRecord, v7Log, v8Log; no value-based guessing or fallback after invalid decoding.
v6InlineBinding is the R11 V6 receipt with full binding and WITHOUT bindingRecordHash fields in original transitions.
v6BindingRecord is R12 FileV6/LogV6 with complete bindingRecord and transition bindingRecordHash slots, including explicit null before bound.
Do not accept a mixture of R11 and R12 transition schemas in one chain. A validated R12 checkpoint must retain its binding record.
An object containing both inline and record forms is receiptMigrationAmbiguous, even if one digest happens to match file bytes.
No documented V6 raw-file-hash format exists in this blueprint. Digest-only V6 bound/committed records are receiptMigrationNeedsBinding.
A V6 scalar without binding is legal ONLY in pre-binding phases where its historical schema permits null; no successful binding inferred.
Unknown version/keys/representation→receiptMigrationUnsupportedFormat; missing evidence→named evidence error, malformed chain→corruptLog.
Do not reinterpret V5 as V6; preserve it and return receiptMigrationUnsupportedFormat for separate explicitly specified historical migration.

## Exact original checks

For R11 binding B, compute:
`oldBindingHash=H("LifeOS/artifact-binding/v6",{schemaVersion:6,receiptID,preparedArtifactID,artifactKind,relativePath,manifestHash,archiveHash,byteCount,fileCount,chunkCount,representation,protection,retention})`.
Values come from B unchanged using V6 canonical integer/date adapters; exclude artifactHash and boundAt exactly as R11.
Require B.artifactHash==oldBindingHash and every original bound/committed transition artifactHash equal this digest.
For R12 record R, ALSO compute:
`oldRecordHash=H("LifeOS/receipt-binding-record/v6",{schemaVersion:6,receiptID,attempt,firstBoundSequence,binding:B})`.
Require R.bindingRecordHash and all original bound/committed transition references equal oldRecordHash.
Validate original transition chain/anchor with original versioned preimages BEFORE constructing any new objects.
Validate IDs, prepared ID, counts, path, retention/protection and original deterministic boundAt; never substitute current time.
`artifactFileHash=hex(SHA256(original raw artifact bytes))` is computed independently through bounded streaming verification.
It is NOT compared to oldBindingHash: those hashes intentionally describe different things.
R11/R12 digest and raw file hash both survive as distinct provenance fields, never one overloaded scalar.

## Deterministic conversion

`migrateHistoricalReceiptFile(bytes:Data,evidence:VerifiedMigrationEvidenceV8,authority:ReceiptAuthority) throws -> FileV8` is the sole persistence converter.
Evidence is internally constructed from verified original artifacts, domain markers, plans and complete original chain; not decoded caller assertions.
V6 phase mapping: prepared/mapped/projecting→10 with authenticated pack progress; streaming→10 or30 only from exact verified work kind;
finalizing→20 only if manifest/plan/work verification complete (deletion finalizing→35 with completed target prefix); bound→50; committed→60.
deleting→35 using verified deletion plan/markers. R10 V6 interrupted/failed are RETRYABLE, not V8 terminal failures.
For interrupted/failed, locate last verified active state/attempt prefix and map it to10/20/30/35/40/50 without incrementing attempt or replaying effects.
If anchor/history/evidence cannot identify that state, receiptMigrationNeedsEvidence; do not convert retryable work to90.
rejected→90 with permanentFailure and verified lastWork. V6 has no cancelled phase: errorCode cancelled on interrupted preserves resumability.
Unknown synonyms such as completed/terminal are NOT silently accepted unless original codec explicitly declares them.
R18-01 terminal rules apply after mapping; absent required work cursor/plan→receiptMigrationNeedsEvidence, never reset cursor0.
For archive operations obtain archiveID and manifestRootHash from verified source manifest; source original manifestHash must validate using its historical algorithm.
Construct V7-shaped FinalizationV7/BindingV7 as an IN-MEMORY bridge only; no intermediate V7 file or second authority transaction.
finalizationID=UUIDv5(namespace:receiptID,name:UTF8("LifeOS/v6-to-v8/finalization")); bindingRecordID uses name "LifeOS/v6-to-v8/binding".
receiptID,operationID,preparedArtifactID,attempt,targetID,parent IDs remain identical; UUID allocation must not change receipt identity.
Finalization fields copy verified B path/representation/protection/retention/counts; durableAt=B.boundAt; archive fields from verified source.
artifactIdentityHash recomputed using R15 V7 identity preimage; artifactFileHash independently computed as above.
sinkCommitID="migration-v6:"+lowercase receiptID; finalizationHash and bindingRecordHash recomputed with R15 V7 domains.
Binding copies new finalizationID/hash, exact new file/identity hashes, B.boundAt and all retained B value fields.
Deletion has no raw archive: verify original deletion intent/markers and historical binding, construct logical R15 finalization with null archive/file hashes.
If a valid old deletion proof cannot be reconstructed, receiptMigrationNeedsEvidence; never invent an empty-file digest.
Every V6 enum from R10 is accounted for above; sourcePhase preserves the ORIGINAL state even when mappingRule=v6-resume.
Phases before40 carry no finalization/binding; phase40 requires verified finalization only;50/60 require both.
V7 follows R17-02 mapping without the V6 bridge. Existing R18-shaped V8 is validated/reused; pre-R18 V8 schema handling is the explicit read-only branch in R18-05.

## Migration provenance and rebase

Replace MigrationV8 with exact object:
`{sourceVersion:Int,sourceFormat:String,sourceFileHash:H,sourceReceiptHeadHash:H,sourceAnchorHash:H?,sourcePhase:String,sourceCursorHash:H,mappingRule:String,sourceBindingHash:H?,sourceBindingRecordHash:H?,sourceArtifactFileHash:H?}`.
sourceVersion6/7; sourceFormat exactly v6InlineBinding/v6BindingRecord/v7Log; sourcePhase original codec's canonical textual enum spelling.
mappingRule `v6-stage|v6-emit|v6-manifest|v6-delete|v6-bound|v6-commit|v6-resume|v6-reject` or R17 V7 rule with `v7-` prefix.
sourceFileHash hashes original complete receipt-container bytes; sourceArtifactFileHash hashes original archive bytes, null for deletion/pre-artifact.
Binding hash fields required only when original binding/record exists; never infer a missing record hash from a different schema.
Anchor throughHash=H("LifeOS/receipt-migration-head/v8",{receiptID,sourceFileHash,sourceReceiptHeadHash,snapshot,workPlanHash}).
The signed R18 anchor contains complete MigrationV8 plus retry evidence=null; old chain is verified, not rewritten with new hashes.
Retain original source bytes until R17 authority retirement proves successful canonical replacement. Any error leaves sources unchanged.
Unknown/ambiguous/missing-evidence errors are explicit blocked migrations; they do not authorize dropping a receipt.

## Legacy archive bytes and interruption

LIFEOSAR/LIFEMNF legacy versus LOS8 dispatch stays R17-03; detected-invalid format never falls back.
Bound/committed legacy archives remain unwrapped and their raw bytes/hash unchanged; the binding retains historical representation.
Only active unwrapped export may use R17-02 owned .v8 partial conversion; stream-verify old prefix and wrap exact inner records.
Verify source receipt/binding BEFORE wrapping; original raw hash stays in migration provenance, new wrapped raw hash used in new finalization only.
Interrupted candidate creation uses verified matching prefix and source identity; no overwrite of old partial or blind append.
If legacy representation/manifest codec unsupported, return receiptMigrationUnsupportedFormat; if required file absent, receiptMigrationNeedsArtifactFile.
If decoded binding mismatches its own hash/chain, corruptLog; if verified artifact differs from bound counts/manifest, artifactIdentityConflict.
Hashing/verification O(total bytes+transitions), memory O(one bounded frame+receipt cap); no full archive allocation.

## Planned verification

P01 SyncProtocolTests: fixed original R11/R12 preimages, hash-of-binding deliberately unequal to raw-file hash, mixed-format rejection.
P18 CompletionFlowsTests: valid inline/record V6 bound+committed migrate to50/60 preserving IDs and every artifact field.
Test pre-binding nulls, missing binding/file, corrupt old chain, unknown version, logical deletion and each V7 phase.
Crash before/after candidate replacement/authority commit; reopen yields one canonical receipt identity and retained provenance.
Legacy terminal archive byte hash unchanged; active conversion yields different raw hash but same semantic archive identity.
