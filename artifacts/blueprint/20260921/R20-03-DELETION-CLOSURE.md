# R20-03 — persisted remote closure before credential retirement

Supersedes R19-03 mutable journal and R19-05 Final19/completion/proofRoot formats for NEW operations.
Retains R18 target order, R19 exact prepare/apply contexts, individual target proofs, receipt phases and R19 publication sequence.
P01 DTO/hash in SyncContract/SyncWireCodec; P18 journal in LifeOSDataManagement; P02 signatures in replication.py; P15 owner persistence server.ts.
R20-01's request20/local dispatch applies also to deletion. No new receipt authority key or new source path.

## Standalone authenticated closure record

`RemoteDeletionClosure20={schemaVersion:20,datasetID:UUID,targetHostID:UUID,receiptID:UUID,operationID:UUID,fenceID:UUID,workPlanHash:H,disposition:String,completedTargetKeys:[H],appliedProofs:[RemoteDeletionApplied20],pending:null,collectorsDisabled:true,memberKeyID:H,epoch:U64,recordHash:H,signerKeyID:H,signature:Data}`.
RemoteDeletionApplied20={context:DeletionApplyContext19,applied:DeletionAppliedV8};0..2 entries sorted target plan order.
completedTargetKeys sorted lexicographic and exactly the same set as appliedProofs context targetKeys; no duplicate store/target.
Completed requires all planned Windows targets; abandoned permits settled subset, never unresolved pending intent.
recordHash=H("LifeOS/remote-deletion-closure/v20",record excluding recordHash/signature); signature=Ed25519(F("LifeOS/remote-deletion-closure-signature/v20",raw32(recordHash))).
<=12288 encoded bytes; public key pin/epoch from verified admission/current enrolled server, not from returned record itself.
Gateway typed sign_deletion_closure(record) verifies identity, original prepared tokens, marker hashes and actual absent/empty state first.
No timestamp/random field. Deterministic signature permits reconstructing identical record after a sign/install crash.
`deletion.close` request payload=R19 DeletionClose19; resultKind=closed,result=RemoteDeletionClosure20 (replaces RemoteFenceProof19).
Add `deletion.status` payload={receiptID:UUID,operationID:UUID,fenceID:UUID,workPlanHash:H}; resultKind=deletionStatus,
result={closure:RemoteDeletionClosure20?}; null means known active/unclosed; unknown op404 operationUnknown, never equivalent to completed.
Gateway constructs body -> signs -> Node installDeletionClosure verifies pinned key/current owner body -> atomically stores full closure -> responds.
Node closed20 entry stores full closure (required iff kind deletion), not just hash; current collector flags remain false on completed AND abandoned close.
R19 optional automatic abandoned re-enable is superseded: explicit subsequent user reconnect only; restart never re-enables deleted scopes.
Lost response: close/status yields retained exact signed record; transport session may change, proof does not.

## Exact mutable journal and hash

`CredentialRetirement20={state:State,intentHash:H?,proof:CredentialRetirementProof20?}`; State notStarted=0,intended=1,retired=2.
`CredentialRetirementProof20={schemaVersion:20,receiptID:UUID,operationID:UUID,fenceID:UUID,workPlanHash:H,remoteClosureRoot:H,trustTargetKey:H,markerHash:H,proofHash:H}`.
proofHash=H("LifeOS/credential-retirement-proof/v20",proof excluding proofHash); same trust marker as existing target proof; no secret material.
`DeletionJournal20={schemaVersion:20,setup:DeletionSetup20,receiptID:UUID,operationID:UUID,fenceID:UUID,workPlanHash:H,pending:DeletionApplyContext19?,proofs:[DeletionProofV8],remoteClosures:[RemoteDeletionClosure20],retirement:CredentialRetirement20,fenceState:U8,fenceClosed:Bool,completion:DeletionCompletion20?,journalHash:H}`.
remoteClosures<=1 configured Windows host; [] iff no closure yet/no remote targets. Complete objects/signatures included; never only hashes.
Sort by targetHostID; proof order fixed target plan; <=16MiB including plan/proofs/closure. Reserve max closure bytes before first destructive effect.
journalHash=H("LifeOS/deletion-journal/v20",journal excluding journalHash/completion); includes retirement and COMPLETE closures.
All fields required. completion excluded only to avoid self-reference; it is validated/signature-checked separately on every load.
No optional synthesized migration of Journal19. Existing active19 journal is read-only recoveryNeedsSchemaEvidence until full closure proof recovered and explicitly rebased.
P18 `persistRemoteDeletionClosure(closure:RemoteDeletionClosure20,journal:DeletionJournal20) throws -> DeletionJournal20` verifies then atomically replaces/fsyncs file+parent, rereads hashes/signature.
Validation uses pinned server identity captured before revocation: add `remoteServerPins:[RemoteServerPin20]` to DeletionSetup19 for new R20 setup.
RemoteServerPin20={targetHostID:UUID,keyID:H,publicKey:Data,epoch:U64};<=1, exact enrolled key at user-confirmed setup, keyID=SHA256(raw32).
Setup hash includes pins under NEW domain LifeOS/deletion-setup/v20 and schemaVersion20; type name DeletionSetup20 replaces19 in Journal20.
Setup20 exact={schemaVersion:20,identity:IdentityV8,receiptID:UUID,operationID:UUID,attempt:U16,authorityID:UUID,fenceID:UUID,workPlan:WorkPlanV8,remoteServerPins:[RemoteServerPin20],setupHash:H}.
Pins are audit evidence bound before effect; preserve them when replicationTrust is deleted.
prepareDeletion arguments/setup capability use Setup20.setupHash; no current trust lookup required to verify saved proof AFTER credential retirement.

## Final immutable projection and signatures

`remoteClosureRoot=H("LifeOS/deletion-closures/v20",{receiptID,operationID,fenceID,workPlanHash,closures:[{targetHostID,recordHash}]})`.
For local-only selective plan closures=[] is hashed explicitly; no fabricated server proof. Full26-store deletion requires configured Windows closure.
`DeletionJournalFinal20={schemaVersion:20,receiptID:UUID,operationID:UUID,authorityID:UUID,fenceID:UUID,workPlanHash:H,setupHash:H,targetCount:U32,proofs:[DeletionProofV8],remoteClosures:[RemoteDeletionClosure20],remoteServerPins:[RemoteServerPin20],retirement:CredentialRetirement20,pending:null,fenceClosed:true}`.
Final projection copies fields exactly from durable journal/setup; retirement.state=retired with proof when plan includes trust, otherwise notStarted/null fields.
`finalJournalHash=H("LifeOS/deletion-final-journal/v20",Final20)`; does not include completion, receipt head or mutable released state.
`proofRoot=H("LifeOS/deletion-proof-root/v20",{receiptID,workPlanHash,targetCount,lastTargetProofHash,remoteClosureRoot,credentialRetirementProofHash})`.
credentialRetirementProofHash nullable iff no trust target; every other successful completion field below nonnull.
`DeletionCompletion20={schemaVersion:20,authorityID:UUID,receiptID:UUID,operationID:UUID,attempt:U16,fenceID:UUID,workPlanHash:H,setupHash:H,targetCount:U32,lastTargetProofHash:H,remoteClosureRoot:H,credentialRetirementProofHash:H?,proofRoot:H,journalHash:H,fenceClosed:true,completionHash:H,signerKeyID:H,signature:Data}`.
journalHash here equals finalJournalHash, deliberately distinct from mutable journal hash. completion<=4096 bytes.
completionHash=H("LifeOS/deletion-completion/v20",record excluding completionHash/signature); receiptDevice signs F("LifeOS/deletion-completion-signature/v20",raw32(completionHash)).
ReceiptAuthorityKeyStore19 adds signDeletionCompletion20(record:DeletionCompletion20,authorization:VerifiedDeletionSigning20) throws -> ReceiptSignature19.
Unsigned record argument omits signature ONLY; other fields/hash/pin required. VerifiedDeletionSigning20 is internal non-Codable {authorityID,receiptID,operationID,completionHash}.
P18 constructs capability after Final20/roots/readback verification; key actor checks active receipt authority pin and exact object identity/hash.
SyncWireCodec.verifyDeletionCompletion20(record:DeletionCompletion20,pin:ReceiptPublicIdentity19) throws verifies exact20 codec/domain/signature.
Do not add20 bytes to ReceiptSignatureKind19.deletionCompletion19; historical ten-kind verifier stays unchanged.
Snapshot/PublicationPreparation/DeletionRetention fields retain names but carry Completion20/hash for new records; old19 verified only with original codec.
New deletion artifact identity uses LifeOS/deletion-artifact-identity/v20 with same R19 field list except schemaVersion20; representation logical.deletion.v20.
R19 sinkCommitID/preparation/finalization still hashes complete supplied fields. No circular journal/completion hash.

## Required order and crash branches

1. Finish every stage0 ordinary target; pending=null; validate Windows proofs under live trust. Call deletion.close while transport credentials available.
2. Verify returned standalone closure against setup pin/plan/target proofs. Persist complete closure in Journal20, file+parent fsync and reread.
3. Compute retirement.intentHash=H("LifeOS/credential-retirement-intent/v20",{receiptID,operationID,fenceID,workPlanHash,remoteClosureRoot,trustTargetKey}).
   Persist state=intended/proof=null with full closures before invoking trust target. No generic Keychain wipe; receipt keys/pins/audit preserved.
4. Execute original trust pending-intent path, inspect exact revoked enrollment/credential absence, record trust target proof and RetirementProof20 atomically; state=retired.
5. Publish/readback final widget; add final proof; reconstruct Final20 and roots; set fenceClosed=true/fenceState=settled and signed completion durably.
6. R19 preparePublication->40->50->60; release local fence idempotently. Remote remains disabled; no network request needed after3.

|restart boundary|required action|
|---|---|
|close response lost/no local closure|same authenticated close/status before retirement; offline retains holding state|
|gateway signed but Node not installed|reconstruct/sign/install exact body; do not return unpersisted closure|
|local closure temp/rename crash|load old or new valid journal; no retirement until full verified closure reread+synced|
|closure saved/before retirement intent|compute same intent from saved closure, persist once; never contact server unnecessarily|
|intent saved/credentials partly removed|inspect original trust context, finish idempotent retirement, retain original beforeHash; no re-enrollment|
|retirement effect before marker/proof|derive proof from authenticated pending intent + exact absence/revocation inspection; persist before widget|
|retired/before final widget or Final20|resume only remaining target; reproduce Final20 from complete retained closures/pins/proofs|
|settled/before40,40/50,60 before release|R19 finalization recovery with Completion20; no remote credentials or newly sampled proof fields|
|credentials gone but required closure missing|deletionRecoveryMissing; preserve state, no fabricated closure/success or fresh trust enrollment|

Pruning only after terminal and released/settled-abandon; retain full Completion20 and binding identity per R19 compact/retired policy.
Final20 can be reproduced exactly while journal retained. After pruning only signed attestation of its hash remains; no claim of individual-proof replay.
Planned checks: lost closure, every credential-removal boundary, keychain locked, wrong server pin, altered closure subset, local-only plan and final-hash reproducibility.
