# R19-05 — non-circular deletion completion and retained verification

> R20-06-DISPATCH.md explicitly supersedes the five reviewed topics and related field additions; this R19 sheet remains authoritative only where retained. Prior readiness is historical.
Supersedes R18-02 claim that lastTargetProofHash alone binds journalHash/fenceClosed and its logical sinkCommitID rule.
R18 individual proof/marker chain remains; R19-03 journal/phase35 creation and R19-06 finalization supersede old ordering.
P01 types/hash validation in SyncContract/SyncWireCodec; P18 journal/coordinator implementation, R19-01 receipt key signing.

## Exact terminal record and hash graph

`DeletionJournalFinal19={schemaVersion:19,receiptID:UUID,operationID:UUID,authorityID:UUID,fenceID:UUID,workPlanHash:H,setupHash:H,targetCount:U32,proofs:[DeletionProofV8],remoteFenceProofs:[RemoteFenceProof19],pending:null,fenceClosed:true}`.
All keys required. Proofs exactly plan count in target order; previousProofHash chain complete, targetKey/preconditions match immutable plan.
remoteFenceProofs contains exactly one completed proof for the configured Windows host if any Windows targets, otherwise[].
Closed means all deletion effects settled and no further effect may enter this operation; it does NOT mean local writes have resumed.
`journalHash=H("LifeOS/deletion-final-journal/v19",DeletionJournalFinal19)`; this is terminal projection, not hash of a self-containing file.
The mutable journal's ordinary journalHash R19-03 and this final journalHash use distinct domains/meanings; never compare them as same quantity.
`proofRoot=H("LifeOS/deletion-proof-root/v19",{receiptID,workPlanHash,targetCount,lastTargetProofHash,remoteFenceProofHashes:[H]})`.
Remote hash list sorted by canonical completedTargetKeys; lastTargetProofHash required because deletion always includes final widget target.
`DeletionCompletion19={schemaVersion:19,authorityID:UUID,receiptID:UUID,operationID:UUID,attempt:U16,fenceID:UUID,workPlanHash:H,setupHash:H,targetCount:U32,lastTargetProofHash:H,remoteFenceProofHashes:[H],proofRoot:H,journalHash:H,fenceClosed:true,completionHash:H,signerKeyID:H,signature:Data}`.
completionHash=H("LifeOS/deletion-completion/v19",record excluding completionHash/signature); signerKeyID included.
Signature from signDeletionCompletion per R19-01; validate current receipt authority key, not retired replication credentials.
Completion<=4096 CJ bytes; remote list<=1, targetCount<=10000; journal projection<=16MiB, streamed hashing bounded by existing journal cap.
Hash dependencies: plan/setup -> ordered target/remote proofs -> finalJournalHash/proofRoot -> completionHash/signature -> finalization -> binding -> receipt.
No completion, finalization, binding, receipt head, current clock or post-release mutable fence field enters final journal hash.

## Exact storage and phase validation

R19-03 Journal.completion stores complete signed DeletionCompletion19, null until settled; completion never participates in ordinary journalHash.
Add required nullable `deletionCompletion:DeletionCompletion19?` to R19 SnapshotV8 and thus every transition/anchor snapshot.
For new Op4 phase35 completion may be null or set ONLY with complete durable proofs; at40/50/60 it is required and byte-identical.
Other operations require null. Failure/cancel copies existing completion unchanged; never creates a successful completion to excuse partial deletion.
No phase35 self-transition exists solely to attach completion: journal stores it first; finalizeArtifact stores it in snapshot simultaneously with40.
`verifyDeletionCompletion(journal:DeletionJournal19,plan:WorkPlanV8,authority:ReceiptPublicIdentity19) throws -> VerifiedDeletionCompletion19`.
Internal result non-Codable. Verifier reconstructs exact Final19 from journal, rehashes all proofs/preconditions/root, verifies signature/key/identity/fence and remote closure.
It checks final widget target marker/snapshot readback and trust revocation after remote closure; no accepted count supplied by caller.
`finalizeArtifact` uses this capability before40; raw archiveHash/manifestRootHash/artifactFileHash remain null for deletion.
Replace ONLY deletion artifactIdentityHash preimage with H("LifeOS/deletion-artifact-identity/v19",{schemaVersion:19,receiptID,attempt,preparedArtifactID,relativePath,retention,completionHash}).
FinalizationV7 carries that identityHash and R19-06 sinkCommitID; its v7 finalization hash already authenticates every finalization field.
bindArtifact and commitBound revalidate completion in snapshot and identityHash; no need to treat a journal hash as file hash.
This is an explicit new deletion identity domain; historical V6/V7 migrations keep original verification and do not rewrite their signed proofs.
R19 new snapshot keys missing from earlier V8 require verified read-only legacy handling as R18-05, never synthesized nil/defaults.

## Durable order and restart

After every ordinary/remote target proved, close remote fence completed WHILE replication credentials still valid; persist remote proof locally.
Then revoke replication trust/credentials, publish final redacted widget, append final target proof and advance35 to targetCount.
R18 stage order retained; remote close is between stage0 and stage1, not after trust revocation.
Build Final19, verify readbacks, set local fenceState=settled/fenceClosed=true, construct/sign completion and atomically publish journal with it; fsync file+parent.
Take R19-06 publication preparation, then finalize40 -> bind50 -> commit60. Release local admission fence only after60 and settled proofs.
Local fence release updates mutable journal.fenceState to released, preserving completion and the immutable Final19 projection byte-for-byte.
At reboot: holding/settled gates producers; released requires verified receipt60 or explicit terminal-abandon settlement, never file flag alone.
Crash before settled journal commit: re-inspect target proofs/remote receipt and complete once; no earlier deletion rerun.
Crash after settled before40: verify completion and reconstruct finalization preparation; no effect repeats.
Crash after40/50: use snapshot completion and stored R19-06 preparation; finish next edge.
Crash after60 before release: verify terminal receipt+completion, release locally once; remote collectors remain disabled.
Corrupt/missing active journal before40 blocks deletionRecoveryMissing. At40/50 use retained snapshot plus immutable artifacts, never infer missing target proofs from a counter.
Active journal cannot be intentionally pruned; unexpected loss before60 is blocked even if summary verifies.

## Pruning without unverifiable success

Terminal compact log retains COMPLETE DeletionCompletion19 in snapshot plus R19-06 preparation summary and finalization/binding.
Delete raw journal only after60 (or settled90/91), no active authority/file intent, and successful compact readback.
R18 RetiredIDV8 adds required nullable `deletionSummary:DeletionRetention19?` for NEW R19 files.
DeletionRetention19={completion:DeletionCompletion19,artifactIdentityHash:H,finalizationHash:H,bindingRecordHash:H}; required for Op4 successful60, otherwise null unless previously completed.
RetiredID adds `operationKind:Op` so validation of deletionSummary is unambiguous; retains receiptID/operationID/terminalPhase/terminalHeadHash/retryDisposition.
Retired rows <=8192 bytes;256 rows<=2MiB. They remain inside authenticated aggregate-file/authority inventory, not an unauthenticated audit sidecar.
Terminal receipt cap32768 remains checked after added fields; if exceeded return capacity before compaction, never discard proof to fit.
After pruning, verify signature, IDs, workPlanHash, proofRoot construction, completionHash and retained artifact identity.
Without raw journal, signature attests the verified final journal hash; individual target membership cannot be re-proved from a digest. Do not claim full historical replay.
Exact retry remains expired(pruned) per R18; retained proof is audit evidence, not permission to restart mutation or reconstruct the original API result.
New deletion cannot reuse old operationID/fence/target proof; history cap never silently drops identity protection.
Failure/abandon pruning never fabricates fenceClosed=true or completed proof; retains phase90/91 and no success claim.

## Planned checks

P01 mutate each bound field independently, verify deterministic domains and reject circular/old identity preimages for new completion.
P18 missing remote close/widget/trust proof forbids40; crash around settle/finalize/bind/commit/release; changed journal must fail before40.
Compact/prune after60 retains verifiable signed completion without raw journal; partial failure remains partial after pruning.
No runtime evidence or independent security acceptance claimed.
