# R17-05 — persisted authority mutations and bootstrap

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Replaces R15-04 mutation schema/fence rules, R15-05 bootstrap/retirement proof and R16-03 in full.
P01 owns encoding/signatures; P18 authority actor/replay. R17-06 checkpoint; R17-07 file transactions.
Types/encoding use R17-01. Every signature is Ed25519 with the pinned authorized key; no signature inferred from a digest.
All runtime paths below are fixed data files inside existing owners, not additions to the source-path allowlist.

## One exact discriminated envelope

MutationV9 = `{schemaVersion:9,authorityID:UUID,migrationEpoch:U64,sequence:U64,mutationID:UUID,kind:U8,previousRecordHash:H?,payload:Payload,recordHash:H,signerKeyID:String,signature:Data}`.
No R15 flat optional payload fields survive. Payload keys depend ONLY on kind; no other/null union cases emitted.
recordHash=H(`LifeOS/receipt-authority-mutation-hash/v9`, envelope without recordHash/signature).
signature signs F(`LifeOS/receipt-authority-mutation/v9`, CJ(envelope without signature)).
Frame=`UInt32BE(CJ length)||CJ||SHA256(CJ)`; CJ<=65536 bytes, total frame<=65572.
Sequence contiguous U64; overflow→capacity before append. Normal previousRecordHash is exact prior recordHash.

|kind / number|exact payload|
|---|---|
|fenceOpen /1|`{sourceInventory:[FingerprintV9],initialInventory:[InventoryV9],bootstrapToken:UUID}`|
|canonicalReplaceIntent /2|`FileIntentV9` from R17-07 (pre-retirement)|
|canonicalReplaceCommit /3|`FileCommitV9` from R17-07|
|canonicalVerified /4|`{inventory:[InventoryV9],inventoryHash:H}`|
|legacyRetireIntent /5|`LegacyIntentV9` below|
|legacyRetireCommit /6|`{intent:LegacyIntentV9,proof:LegacyProofV9}` (complete copies)|
|retirementProof /7|`{proof:RetirementProofV9}`|
|postRetirementCanonicalIntent /8|`FileIntentV9`|
|postRetirementCanonicalCommit /9|`FileCommitV9`|
|checkpoint /10|`CheckpointV9` from R17-06|
|canonicalAbort /11|`{intentID:UUID,intentHash:H,unchangedInventoryHash:H,reason:AbortReason}`|

AbortReason numeric: missingCandidate=1,explicitCancel=2. Legal only when canonical file still matches old inventory.
Same mutationID+same complete signed bytes is idempotent; same ID/different bytes→authorityReplayConflict.
All kind/phase legality validated BEFORE filesystem effects. Only kinds8/9/10/11 legal after retired.
Exactly one active canonical file intent OR one active legacy intent globally; never both. Begin while active→receiptRelocationInProgress.

## Complete retirement representations

FingerprintV9 retains R15-05 exact fields: sourceID UUID, domain Domain, relativePath, existed Bool,
fileHash H?, byteCount U64, receiptHeadHash H?, observedEpoch U64. Exactly3, domain order.
sourceID allocated once at discovery (UUID); every later reference uses that exact lowercase UUID, never an arbitrary string.
Missing fingerprint: existed=false,fileHash=null,byteCount=0,receiptHeadHash=null. Present hash/byte count verified before fence.
fingerprintHash=H(`LifeOS/legacy-source-fingerprint/v9`, fingerprint without observedEpoch), as R15.
LegacyIntentV9 = `{schemaVersion:9,authorityID:UUID,migrationEpoch:U64,intentID:UUID,sourceID:UUID,relativePath:String,expectedSourceHash:H?,sourceFingerprintHash:H,expectedInventoryHash:H,createdAt:timestamp,intentHash:H,signerKeyID:String,signature:Data}`.
Intent expectedSourceHash null iff fingerprint.existed=false. Hash domain `LifeOS/legacy-retire-intent/v9`, excludes intentHash/signature.
LegacyProofV9 = `{schemaVersion:9,authorityID:UUID,migrationEpoch:U64,intentID:UUID,sourceID:UUID,relativePath:String,expectedSourceHash:H?,postState:1,parentSyncToken:UUID,proofHash:H,signerKeyID:String,signature:Data}`.
Proof hash domain `LifeOS/legacy-retire-proof/v9`, excludes proofHash/signature. Both inner signatures sign raw32 respective hash.
Commit stores COMPLETE intent and proof, including both signatures/key IDs; never only selected proof fields.
DispositionV9 = `{sourceID:UUID,fingerprintHash:H,disposition:String,intent:LegacyIntentV9,proof:LegacyProofV9}`.
disposition exactly `missing` iff original existed=false, else `retired`; post-crash absence never changes this historical fact.
RetirementProofV9 = `{schemaVersion:9,authorityID:UUID,migrationEpoch:U64,retirementDispositions:[DispositionV9],canonicalInventory:[InventoryV9],canonicalInventoryHash:H,lastRecordHash:H,proofHash:H,signerKeyID:String,signature:Data}`.
Exactly3 dispositions sorted lowercase sourceID; inventory exactly3 domain order. lastRecordHash is prior mutation head, NOT proof mutation hash.
proofHash=H(`LifeOS/receipt-retirement-proof/v9`, complete proof excluding proofHash/signature); signature signs raw32(proofHash).
This explicitly supersedes R15's smaller proof preimage and R16's `dispositions` spelling; no alternate hash interpretation.
Before signing, all canonical files/receipt chains and3 committed per-source proofs verify. Historical proof never changes thereafter.

## Unlink/fsync/restart

Under lock verify fingerprint/inventory → append signed intent+fsync log → unlink exact allowed file → fsync source parent
→ create parentSyncToken UUID → sign proof → append complete commit+fsync log. Directory existence/identity is pinned.
For an already absent path WITH pending matching intent: fsync source parent first, then new token/proof/commit.
If parent itself absent, fsync nearest existing fixed application-support ancestor; proof remains about path absence, not actor attribution.
Existing expected hash→repeat unlink/order. Existing other hash→legacyExternalModification, no delete.
Absent without pending intent→legacyRetirementUnproven unless original missing fingerprint is now being processed: first persist its intent.
Valid existing commit→verify and no-op. Commit ID/proof mismatch→authorityReplayConflict.
Never alter original fingerprint or expectedSourceHash to excuse missing bytes after crash.
During retiringLegacy, reads use verified canonical files only; no legacy fallthrough. Projection allowed only once aggregate retirement proof verifies.

## First bootstrap without backup

Authority owner object retains R15 fields and ADDS `bootstrapToken:UUID,bootstrapFence:MutationV9` before owner signature.
bootstrapFence is complete signed kind1 sequence0 previous=null; its source/initial inventories reproduce owner inventory hashes.
Owner signature domain stays `LifeOS/receipt-authority-owner/v9` over all fields except signature (including bootstrapFence).
sourceInventoryHash=H(`LifeOS/receipt-source-inventory/v9`, {schemaVersion:9,authorityID,migrationEpoch,sources:[FingerprintV9]}) in domain order.
initialCanonicalInventoryHash is R17-07 inventoryHash of initialInventory; bootstrapFence payload must reproduce both hashes.
Authority file max32768 bytes; keys32 bytes, signatures64 bytes, allowlists exactly3 each. Never mutate this file after publication.
Before publishing authority, write a device-local Keychain BootstrapSealV9:
`{authorityID:UUID,bootstrapToken:UUID,authorityFileHash:H,status:Status}`; Status prepared=1,activated=2.
Access after-first-unlock-this-device-only; authenticated local key access, no UserDefaults; not a receipt or filesystem sidecar.
Order: construct authority/fence → persist prepared seal → exclusive-create authority +fsync parent → exclusive-create log containing embedded fence
→ fsync log+parent → persist activated seal → permit ANY canonical/legacy mutation.
No bootstrap filesystem effect on canonical/legacy files is permitted before activated seal.

|restart state|exact result|
|---|---|
|no authority/no seal/no log|fresh discovery, construct once|
|prepared seal/no authority/no log|no source mutation possible; clear only matching prepared seal, rediscover under lock|
|authority +prepared seal +missing/torn-only-first-frame log|verify owner/device signatures and seal hash/token; recreate log from embedded fence ONLY; fsync; activate|
|authority +prepared seal +complete matching fence-only log|fsync log+parent; activate; continue|
|prepared seal +any later record|authorityInvalid: violated no-effects-before-activation invariant|
|authority +activated seal +missing log|authorityMutationLogMissing; authenticated full restore required; never recreate sequence0|
|authority+log +missing/wrong seal|authorityBootstrapRequired; explicit owner recovery, never infer first bootstrap|
|log without authority, invalid signed fence, foreign temp|authorityInvalid; preserve evidence|

A valid complete extra log frame while prepared is not truncated. A torn first frame may be recreated only under matching prepared seal.
For activated state, only a final incomplete frame can be truncated to authenticated prefix followed by fsync; complete invalid records block.
No-backup first-bootstrap recovery is automatic ONLY in the prepared states above; deleting activated history cannot masquerade as first bootstrap.
R15 immutable records lacking embedded fence remain read-only migration inputs: existing valid log required; absent log cannot be reconstructed.
Old signed bytes are not edited. For an old-format authority with a complete valid sequence0-rooted log, validate the old owner/mutation codec,
then require a fresh owner signature over F(`LifeOS/receipt-seal-upgrade/v9`, CJ({authorityID,authorityFileHash,logHeadHash,logHeadSequence})).
Verify with pinned owner key and store activated seal plus this authorization in Keychain; no epoch/file identity changes.
The old log's authenticated fenceOpen becomes the in-memory bootstrapFence; all future checkpoints retain it completely.
An old-format authority with no valid log remains authorityMutationLogMissing. Never manufacture its first fence from current files.
Before its first R17 mutation, translate only replayed state to R17 inventory definitions; authorize a kind10 checkpoint rebase with complete proof.
If old proof lacks complete signed per-source intent/proof material, return authorityBootstrapRequired; do not retire/delete/rewrite anything.
This is a closed unsupported legacy-evidence state, not permission for Luna to invent proof. Actual supported migration requires those proofs.
Errors: authorityInvalid,authorityMutationLogMissing,authorityBootstrapRequired,authorityReplayConflict,legacyExternalModification,
legacyRetirementUnproven,receiptRelocationInProgress,externalModification,postRetirementPathDenied,authorityCheckpointCorrupt,capacity,diskFull,operationCancelled,archiveIOFailed.
