# R20-01 — restore admission, settlement and release

Replaces R19-02 journal/fence lifecycle and R19-04 restore admission/closure; preserves their domain proof fields and policies.
P01 types in SyncContract.swift, hashes in SyncWireCodec.swift, ports in SyncDomainAdapter.swift; P18 orchestration in LifeOSDataManagement.swift.
P02 gateway functions in replication.py/main.py; P15 Windows owner in server.ts/history.ts. Exact locations in14; no new source path.
R17-01 CJ/F/H, lowercase UUID, enum-number, decimal-string unsigned integer and explicit-null rules apply throughout R20.
A fence stops writers; it is not a rollback. Restore abandonment retains verified applied effects and reports partial completion.

## Immutable admission and exact journal

`RestoreAdmission20={schemaVersion:20,datasetID:UUID,authorityID:UUID,receiptID:UUID,operationID:UUID,preparedArtifactID:UUID,fenceID:UUID,workPlanHash:H,units:[DataRestoreUnit19],sources:[RemotePackSource20],admissionHash:H}`.
fenceID=UUIDv5(namespace:operationID,name:F("LifeOS/restore-fence/v20",CJ({datasetID,receiptID,basePlanHash}))); basePlanHash defined below. Never randomize on retry.
Exactly28 units from verified plan; sources exactly the two Windows units, ordered by registry. No Windows unit omitted on outage.
admissionHash=H("LifeOS/restore-admission/v20",admission excluding admissionHash); <=32768 bytes; reject before durable admission if larger.
`RestoreFenceState20` admitted=1,holding=2,settling=3,settled=4,releasing=5,released=6; monotonic, no implicit timeout release.
`ProducerFlags20={usageEnabled:Bool,clipperEnabled:Bool}` records PRE-restore remote flags, never archive configuration.
`RestoreJournal20={schemaVersion:20,identity:IdentityV8,admission:RestoreAdmission20,workPlan:WorkPlanV8,state:RestoreFenceState20,pending:RestoreApplyContext20?,proofs:[DataCompletionProof19],remoteAdmission:RemoteRestoreAdmission20?,settlementIntent:RestoreSettle20?,remoteSettlement:RemoteRestoreSettlement20?,localSettlement:LocalRestoreSettlement20?,releaseIntent:RestoreRelease20?,remoteRelease:RemoteRestoreRelease20?,journalHash:H}`.
All keys required; optional fields explicit null. proofs <=28, sorted unit order; one pending context; file <=3MiB including <=2MiB plan.
journalHash=H("LifeOS/restore-journal/v20",journal excluding journalHash); complete signatures included, never excluded by recursive key removal.
Path remains DataManagement/restore-journal.json; atomic replacement, file fsync + parent fsync under P18 dataset/interprocess lock.
Journal is excluded from restore/recoveryImports replacement. Only one restore OR deletion active per dataset, including releasing state.
RestorePrepareInput20 = exact RestorePrepareInput19 fields PLUS fenceID,admissionHash; replaces19 for new restore ports/remote payloads.
RestorePrepared20 = exact Prepared19 fields; inputHash now H("LifeOS/restore-input/v20",complete Input20).
RestoreApplyContext20={input:RestorePrepareInput20,prepared:RestorePrepared20}; source content/proof hashes remain R19-02.
DataCompletionProof19 identity must match admitted unit and journal fence via inputHash/context lookup; no new optional proof fields.
All four R19 restore adapter signatures replace Input/Prepared/Context19 with20; return DataCompletionProof19/DataStoreState19 unchanged.

## Exact remote actions and persisted records

DataManageRequest20/Response20 retain R19 outer fields with schemaVersion20; no alternate v19 payload accepted for new operations.
Keep deletion.prepare/apply/inspect and restore.prepare/apply/inspect with their exact current payloads; add actions below.
Transport manageData accepts20; local signed dispatch uses LocalDispatch20 = R19 fields with version20, request20, requestHash domain LifeOS/data-manage-request/v20.
Local dispatch signature domain becomes LifeOS/local-data-dispatch/v20; no unversioned reinterpretation. Bounds remain R19 unless R20-02 says otherwise.
`restore.open` payload=RestoreAdmission20; resultKind=restoreAdmitted, result=RemoteRestoreAdmission20.
`restore.close` payload=RestoreSettle20 with disposition completed; `restore.abandon` same payload with disposition abandoned.
Both return resultKind=restoreSettled,result=RemoteRestoreSettlement20. No closure changes collector flags to enabled.
`restore.release` payload=RestoreRelease20; resultKind=restoreReleased,result=RemoteRestoreRelease20.
`restore.status` payload={receiptID:UUID,operationID:UUID,fenceID:UUID,admissionHash:H}; resultKind=restoreStatus.
Status result={admission:RemoteRestoreAdmission20,settlement:RemoteRestoreSettlement20?,release:RemoteRestoreRelease20?}; unknown op=404 operationUnknown, never successful null.
`RestoreSettle20={receiptID:UUID,operationID:UUID,fenceID:UUID,admissionHash:H,disposition:String,unitProofHashes:[H]}`.
Hash list exactly server's persisted completed Windows unit proofs in registry order (0..2 for abandoned,2 for completed).
`RestoreRelease20={receiptID:UUID,operationID:UUID,fenceID:UUID,admissionHash:H,settlementHash:H,terminalPhase:U8,terminalHeadHash:H}`.
terminalPhase60 iff completed;90/91 iff abandoned. No effect replay, undo or implicit collector-enable request in release.
`RemoteRestoreAdmission20={schemaVersion:20,datasetID:UUID,targetHostID:UUID,receiptID:UUID,operationID:UUID,fenceID:UUID,workPlanHash:H,admissionHash:H,memberKeyID:H,epoch:U64,priorFlags:ProducerFlags20,recordHash:H,signerKeyID:H,signature:Data}`.
`RemoteRestoreSettlement20={schemaVersion:20,receiptID:UUID,operationID:UUID,fenceID:UUID,admissionHash:H,disposition:String,unitProofHashes:[H],pending:null,collectorsDisabled:true,recordHash:H,signerKeyID:H,signature:Data}`.
`RemoteRestoreRelease20={schemaVersion:20,receiptID:UUID,operationID:UUID,fenceID:UUID,admissionHash:H,settlementHash:H,terminalPhase:U8,terminalHeadHash:H,enabledFlags:ProducerFlags20,recordHash:H,signerKeyID:H,signature:Data}`.
Each record <=4096 bytes; hash domains LifeOS/restore-admitted/v20, LifeOS/restore-settled/v20, LifeOS/restore-released/v20 respectively; exclude recordHash/signature only.
Signature=Ed25519(F("LifeOS/restore-control-signature/v20",raw32(recordHash))); typed kind validation recomputes distinct hash domain first.
Gateway signer adds sign_restore_control(record); storing key only, no generic private-key exposure. Receipt keys never sign HTTP.
Gateway verifies owner durable pending-free state, constructs signed record, installs it durably via Node installRestoreControl(record), then sends external response.
Node verifies pinned gateway signature + exact prepared owner state, atomically persists full signed record before returning install success.
Crash before install: reconstruct same deterministic fields/signature; no timestamp or random ID in control records. Crash after install: return retained record.
`RemoteActive20` = R19 active fields PLUS admission:RestoreAdmission20?,state:RestoreFenceState20?,priorFlags:ProducerFlags20?,admitted:RemoteRestoreAdmission20?,settlementIntent:RestoreSettle20?,settlement:RemoteRestoreSettlement20?,releaseIntent:RestoreRelease20?,release:RemoteRestoreRelease20?.
Restore requires admission/state/priorFlags; subsequent nullability follows order below. Deletion requires these additions null.
Owner schemaVersion20/stateHash domain LifeOS/windows-data-owner/v20; prepared/pending contexts use20 for restore,19 for deletion; source20.
RemoteActive20 additionally requires controlSigningContext:{datasetID:UUID,targetHostID:UUID,memberKeyID:H,epoch:U64,signerKeyID:H}, captured at first admission.
Never resample these fields during replay/signing; current transport admission must still authorize the pinned member. Epoch rotation blocks mutation pending explicit recovery.
`RemoteClosed20={active:RemoteActive20,deletionClosure:RemoteDeletionClosure20?}`; restore requires active.state=released and full admitted/settlement/release, deletionClosure=null.
Deletion closed requires deletionClosure and all restore-only fields=null; pending=null in both. Replaces R19 RemoteClosed19/fenceProof in full.
Owner20 exact keys={schemaVersion:20,datasetID:UUID,active:RemoteActive20?,closed:[RemoteClosed20],dispatchCache:[DispatchCache20],usageEnabled:Bool,clipperEnabled:Bool,stateHash:H}.
DispatchCache20 retains R19 cache fields with result selected from Response20 union, each<=32768,total<=8MiB/count256.
Max256 total closed ops; keep R19 owner16MiB cap. Reserve encoded worst-case new closure before admission; byte cap overrides count.
No active/closed ID eviction. Reuse same IDs/different hash ->409 idCollision; cap exhaustion rejects new admission without effects.

## Ordered local and remote algorithm

1. Verify complete immutable archive and28 units, reserve journal/receipt capacity; drain local writers under exclusive dataset lock.
2. Persist journal(state=admitted, all optional fields null, proofs=[]). This contains immutable identity/plan before any domain effect.
3. Publish receipt prepare phase10 using journal identity/workPlanHash; interrupted creation reuses identical prepare command.
4. Send restore.open. Server verifies current app+admin capability, pins dataset/server/unit allowlist/source limits and member identity.
   Persist active admitted + priorFlags + both current flags=false before draining collectors; gate denies new work immediately.
   Drain owned in-flight work, reconcile older store intents, persist holding; sign/install admission record; return. No source effect yet.
5. Persist returned remoteAdmission and local state=holding before any restore.prepare/apply. Stage R20-02 source bytes under this admission.
6. Prepare exact unit, persist pending before apply, invoke owner, verify signed proof, append proof+clear pending atomically, then advance receipt pack.
7. Persist settlementIntent + state=settling. Reconcile pending first. Completed requires28 proofs including fresh final widget; abandoned keeps verified prefix.
8. Call close/abandon; remote gate drains, reconciles pending, verifies claimed proof hashes, persists settling then complete signed settled record; stay disabled.
9. Persist remoteSettlement, construct localSettlement below, persist state=settled. No unsigned/missing remote proof passes this boundary.
10. Completed: R19 preparePublication ->40->50->60. Abandoned: R18 terminal90/91 only AFTER settled proof; failure does not silently become abandonment.
11. Reread verified terminal receipt; persist releaseIntent + state=releasing, call restore.release, persist remoteRelease, then state=released; allow local writers.
No receipt phase changes at release; public UI distinguishes committed-but-release-pending from ready. Do not reuse/prune journal until released.

## Local settlement, release and proof rules

`LocalRestoreSettlement20={schemaVersion:20,receiptID:UUID,operationID:UUID,fenceID:UUID,admissionHash:H,disposition:String,proofHashes:[H],remoteSettlementHash:H,pending:null,settlementHash:H}`.
proofHashes ordered by28 units; completed exactly28; abandoned only proven units. Hash domain LifeOS/restore-local-settlement/v20 excluding settlementHash.
Local settlement stored atomically within journal and authenticated by receipt authority when its hash enters publication/terminal receipt.
Restore admission itself is bound into new Op3 WorkPlanV8 by required restoreFencePolicy20:{fenceID:UUID,sourceDescriptors:[RemotePackSource20]}?;
other operations require null. Avoid a hash cycle: fenceID derivation uses basePlanHash=H("LifeOS/restore-base-plan/v20",plan excluding workPlanHash/restoreFencePolicy20).
Derive fence, construct sources, add policy, then compute final workPlanHash; source hashes do not include fence/plan, source descriptors include fence only.
Admission hashes final plan+units/sources; no admissionHash is added to WorkPlan. Journal verifies policy/source equality before receipt prepare.
Historical active V8 missing policy/settlement field remains read-only per dispatch; do not silently synthesize fields in signed data.
New restore PublicationPreparation19 adds required nullable restoreSettlementHash (set iff Op3); sinkCommitID/preparationHash include it.
SnapshotV8 adds required nullable restoreSettlementHash; Op3 phase40/50/60/90/91 requires it; all other ops null.
For abandon/fail, coordinator copies verified settled hash in terminal transition; incomplete/ambiguous effects cannot reach90/91.
Completion root remains the R19 all28-proof root; settlement binds fence/proofs and remote stop, never substitutes for domain completion.
Server release verifies its full signed settlement and exact operation/member authorization. Client terminal hash is an authenticated app assertion;
server cannot independently prove the local receipt chain. P18's local verified-terminal capability is mandatory before constructing Release20.
Completed release restores priorFlags exactly. Abandoned release leaves both false; explicit later user reconnect may re-enable selected retained data.
No archive flag enables collectors; new local work starts only after corresponding release checks. Local abandonment warns of partial state.
Remote persists releaseIntent with intended flags before changing them, then verifies/installs signed release and moves active to closed atomically.
In-process collectors start only after durable signed release; startup compares retained release/flags before enabling. A failed install keeps them stopped.

## Restart and lost responses

|durable boundary|required recovery|
|---|---|
|local admitted/no receipt|verify journal, issue identical prepare; no effects before receipt10|
|remote admitted/draining/no signed admission|repeat open; stay gated, drain and install same admission; never recapture priorFlags|
|open response lost|repeat open or status, verify retained admission, persist holding; no second operation|
|pending apply|R19 inspect original context: before retry, exact after finish proof, other staleTarget; keep fence|
|settlement intent/no signed settlement|repeat same close/abandon; response loss uses status; never re-enable by timeout|
|remote settled/local not settled|verify saved/status record, persist local settlement; remote retains full record|
|local settled/receipt40 or50|R19 finalize/bind recovery, no domain effects; fence remains held|
|terminal/local not releasing|derive release from exact terminal hash and saved settlement; persist intent first|
|release request/response lost|same release/status returns retained release; no recapture flags or repeated restore|
|remote released/local crash|verify remote signed release plus local terminal, persist released; then permit local producers|
|corrupt/missing active journal or owner|block writers, preserve evidence; never infer release from absent work or elapsed time|

Errors: restoreInProgress409,operationUnknown404,restoreNotSettled409,restoreNotTerminal409,restoreControlMismatch409; corruption503,capacity413,diskFull507.
Ports: P18 openRestore(admission),settleRestore(disposition),releaseRestore(verifiedTerminal); P02 open_restore/settle_restore/release_restore/restore_status.
P15 WindowsDataManagementOwner19 gains matching methods; rename is unnecessary. P16 startup recovers both journals before any collectors/sync.
Planned checks: every numbered crash boundary, response loss, partial abandonment, source loss, prior-disabled flags, revoked member and offline release.
