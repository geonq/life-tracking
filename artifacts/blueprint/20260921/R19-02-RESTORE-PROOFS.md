# R19-02 — full-registry data-management completion

> R20-06-DISPATCH.md explicitly supersedes the five reviewed topics and related field additions; this R19 sheet remains authoritative only where retained. Prior readiness is historical.
Supersedes R18-01/R17-01 requirement to use SyncStoreKind projection markers for ALL restore packs.
R9-02 LifeOSProjectionMarkerV5 remains unchanged and exclusively covers replication/recovery-import projections (Op1).
Op3 full data restore uses the concrete proofs below; Op2 export uses staged-pack integrity, not a projection marker.
P01 declares all DTOs in SyncContract.swift, hashing in SyncWireCodec.swift and ports in SyncDomainAdapter.swift.
P18 orchestrates in LifeOSDataManagement.swift. Domain owners implement ports inside their existing allowed adapter/store files.
All objects follow R17 CJ/F/H and bound strings; `Host19` numeric apple=1/windows=2 matches R18, not R7 string wire encoding.

## Exact coverage and immutable units

Registry remains the exact26 LifeOSDataStoreID strings in R7-05 order. Do not add cases to SyncStoreKind.
Every store has apple host; usageLocal/clipperLocal additionally have windows host:28 host units grouped into26 pack units.
Apple means the selected target installation, not every device; bind targetHostID to pinned receipt installation UUID.
Windows targetHostID is enrolled server origin UUID. Never conflate two physical hosts sharing Host19.
`DataRestoreUnit19={storeID:LifeOSDataStoreID,host:Host19,targetHostID:UUID,packHash:H,sourceHash:H,policy:Policy19}`.
Policy19 replace=1,preserve=2,regenerate=3; sorted registryOrdinal then host then targetHostID; exactly28 units for full restore.
sourceHash=H("LifeOS/restore-host-source/v19",{storeID,host,packHash,entries:[verified file-entry descriptors in canonical path order]}).
Zero entries are explicitly hashed; missing/unreachable host is NOT zero entries. Archive must account for every required host.
WorkPlanV8 gains required `restoreUnits:[DataRestoreUnit19]`, empty except Op3; workPlanHash includes this field.
Op3 unitHashes remain26 packHash values in registry order. nextUnit remains a pack index0..26, not a28-host index.
R18 V8 without this R19 field is a historical read-only shape; no default insertion into already signed bytes.
V6/V7 conversion constructs the new field from verified source/registry; missing host evidence returns receiptMigrationNeedsEvidence.

## Policies, including local packs

Replace: calendar, financeImports/Recurring/Investments/Budgets/Allocations/Preferences/Travel, training/Templates, meals,
nutritionGoals, supplements, journal, lifestyle, barcodeRecords, planningJournal/Files, taxSanitized, usageLocal and clipperLocal.
TaxRaw/nutritionPhotoOriginals preserve iff preserveProtectedLocalAssets=true, otherwise replace after explicit local-asset consent.
Raw/photo bytes never travel to Windows or replication. planningFiles restores owned cache/filesystem only; external Obsidian vault originals untouched.
replicationTrust ALWAYS preserve live trust/credentials; archive metadata may be inspected but cannot enroll/revoke/replace keys implicitly.
recoveryImports ALWAYS preserve active/current audit authority and journals; archived legacy history remains an import artifact, not live authority replacement.
widgetSnapshot ALWAYS regenerate from accepted restored stores as the final projection, not replay a stale archived widget image.
This explicitly overrides old full-restore prose implying blind replacement of trust/history/widget packs.
Regeneration is deferred until all other packs' effects are durable; the pack cursor may remain at widgetSnapshot while later photo/history units stage.
P18 completes those later units once, then validates widget proof and advances remaining pack indices by inspecting existing markers; never reorder registry hashes.
Full restore obtains persistent dataset write fence before effects; no provider, sync projection or user writes until settled completion/abandon.

## Concrete port, context and durable proof

`RestorePrepareInput19={receiptID:UUID,operationID:UUID,preparedArtifactID:UUID,authorityID:UUID,workPlanHash:H,unit:DataRestoreUnit19}`.
`RestorePrepared19={inputHash:H,beforeHash:H,scopeVersion:U64}`; inputHash=H("LifeOS/restore-input/v19",input).
`RestoreApplyContext19={input:RestorePrepareInput19,prepared:RestorePrepared19}`; no caller-chosen beforeHash.
Ports on LifeOSDataStoreAdapter:
`prepareRestore(_ input:RestorePrepareInput19) async throws -> RestorePrepared19`
`applyRestore(_ context:RestoreApplyContext19, source:any LifeOSVerifiedPackReader19) async throws -> DataCompletionProof19`
`lookupRestoreProof(_ input:RestorePrepareInput19) async throws -> DataCompletionProof19?`
`inspectRestoreState(_ input:RestorePrepareInput19) async throws -> DataStoreState19`
Reader P01 protocol: `read(relativePath:String,offset:UInt64,limit:UInt32) throws -> Data`; limit<=1MiB, paths bound to unit entries.
DataStoreState19={contentHash:H,scopeVersion:U64}; contentHash hashes canonical descriptor-owned user state, excluding audit fields.
StateEntry19={relativePath:String,byteCount:U64,sha256:H}; paths unique/sorted UTF8; file values are exact bytes, structured values existing validated canonical writer bytes.
Key-value entries use descriptor key as relativePath and CJ(value) bytes; absent key/file contributes no entry. Never hash filesystem mtime or undefined dictionary order.
contentHash=H("LifeOS/data-store-state/v19",{storeID,host,targetHostID,entries:[StateEntry19]}); empty entries uses this same preimage.
Owners persist scopeVersion in existing envelope/SQLite metadata, initial0 on verified legacy migration; increment with each content mutation under fence, overflow→capacity.
Audit proof/journal changes do not increment content scopeVersion. Prepared captures before version; proof.scopeVersion is committed after version (unchanged for preserve).
R19 deletion beforeHash uses this same contentHash over the selected target scope; targetKey additionally included in deletion state preimage domain LifeOS/deletion-state/v19.
Whole-store empty postcondition still uses R18 deletion-after hash, intentionally distinct from contentHash; inspect verifies emptiness before constructing it.
Prepare takes owner's fence and captures state once. Context verifies inputHash, then compares scopeVersion/contentHash before apply.
Outcome19 applied=1,empty=2,preserved=3,regenerated=4. Empty means explicit replacement with verified empty source, never unavailable.
`DataCompletionProof19={schemaVersion:19,authorityID:UUID,receiptID:UUID,operationID:UUID,preparedArtifactID:UUID,workPlanHash:H,storeID:LifeOSDataStoreID,host:Host19,targetHostID:UUID,packHash:H,sourceHash:H,policy:Policy19,outcome:Outcome19,beforeHash:H,afterHash:H,scopeVersion:U64,adapterVersion:U16,proofHash:H,signerKeyID:H,signature:Data}`.
proofHash=H("LifeOS/data-completion/v19",proof excluding proofHash/signature); signerKeyID IS included.
Apple proof signed by R19-01 receiptDevice. Windows proof signed by enrolled server key under typed dataCompletion19 method R19-04.
Proof<=2048 CJ bytes, exactly one per receipt/store/host/targetHostID; typed validation rejects wrong policy/outcome/identity.
Preserved requires afterHash=beforeHash and verified current state unchanged; regenerated requires actual published widget content hash.
Applied/empty verify owner canonical projection of source equals afterHash; sourceHash alone is not after-state proof.

## Persistence, lookup and recovery

Proof and mutation commit atomically in existing owner's envelope/SQLite transaction where supported; marker lookup is keyed by receipt/unit.
P18 injects signing port and verified identity; owner constructs complete before/after fields before signing, never signs caller assertions.
For multi-file/key-value/raw/trust/widget ports, use P18 protected `DataManagement/restore-journal.json` intent→effect→readback→signed proof.
Journal19={schemaVersion:19,receiptID,operationID,workPlanHash,pending:RestoreApplyContext19?,proofs:[DataCompletionProof19],journalHash:H}; exact known fields, <=128KiB.
journalHash=H("LifeOS/restore-journal/v19",journal excluding journalHash); proofs sorted unit order,<=28; one pending intent.
Write journal atomically/file+parent sync before effect; only then apply existing owner's atomic restore; verify output before adding proof and clearing pending atomically.
Crash pending + exact before-state: retry; exact desired after-state: sync/readback/sign/store proof; any other state: staleTarget, no overwrite.
Preserve requires no effect but still writes proof; empty still invokes owner's validated clear and records proof; regenerated validates readback.
Lookup checks owner's committed marker first or journal port as registered, never searches unrelated files or assumes absent proof means no effect.
Recovery calls inspect with original context; proof fields and signature must match plan/current fenced state before cursor advances.
PackProof19={receiptID,workPlanHash,storeID,proofHashes:[H],packProofHash:H}; hashes ordered by host/targetHostID.
packProofHash=H("LifeOS/restore-pack-proof/v19",object excluding packProofHash); advanceStage.lastUnitHash uses this digest.
`verifyDataRestoreCompletion(receiptID:UUID,workPlan:WorkPlanV8) async throws -> DataRestoreCompletion19` rereads all28 proofs under fence.
Completion19={receiptID,workPlanHash,packProofHashes:[H],completionRoot:H}; exactly26, root=H("LifeOS/restore-completion/v19",object excluding completionRoot).
This typed result feeds DurableCompletionV8 at20/40; replication markers alone cannot satisfy Op3. Op1 keeps its existing verifier.
R19-06 retains completionRoot in stable publication preparation for finalization; no user success until60.
Failure/cancel settles pending effect and retains proofs before releasing fence; transient errors keep fence and resumable progress.

## Owner binding and planned verification

P03 calendar/finance including travel; P04 training/templates/nutrition/barcodes/photos/lifestyle; P05 journal transaction; P06 Planning ports.
P12 usage Apple port in UsageManualReadingStore.swift; P16 clipper Apple port/composition in ModuleNavigation.swift.
P13 raw/sanitized tax in TaxDocuments.swift; P14 widget proof in WidgetSnapshotPublisher.swift; P01 trust; P18 recoveryImports/journal.
Windows usage/clipper ports consume P02/P15 verified gateway/local-owner boundary, no direct arbitrary filesystem access from Apple.
R19-04 defines remote mutation dispatch; remote restore uses authenticated verified archive source, never substitutes a replication store ID.
Planned cases: all26/28 coverage, empty/preserved/raw packs, unknown host, changed source, lost response, crash before proof and widget-last completion.
No application test executed by this revision; source/physical-host evidence remains separate.
