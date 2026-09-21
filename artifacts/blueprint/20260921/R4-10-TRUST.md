# Enrollment, epoch fences, rotation and secure recovery
P01 owns SyncTrustRecord in SyncContract.swift; P02 reads validated equivalent dataclass/interface.
```swift
public struct SyncTrustRecord:Codable,Equatable,Sendable {
 public let schemaVersion:Int; public let datasetID:String; public let ownerPublicKey:String
 public let membership:SyncMembership; public let epochFence:String; public let checkpoints:[TrustCheckpoint]
}
public struct TrustCheckpoint:Codable,Equatable,Sendable {public let storeID:String;public let checkpointHash:String;public let frontier:SyncFrontier}
```
Python frozen SyncTrustRecord(schemaVersion:int,datasetID:str,ownerPublicKey:str,membership:SyncMembership,epochFence:str,checkpoints:tuple[TrustCheckpoint,...]);
TrustCheckpoint(storeID:str,checkpointHash:str,frontier:SyncFrontier). TS readonly same fields, arrays ReadonlyArray.
Every key required/no defaults; version1/dataset UUID/pub32/fence POSQ/checkpoints<=32 unique storeID/HASH/valid frontier.
Persist trust.json under private ApplicationSupport/LifeOS/Replication (Windows protected data root). Public keys not credentials,
but owner key pin integrity protected by device-only Keychain item service LifeOS.replication.ownerpin/account datasetID.
Pinned owner fingerprint=SHA256(raw32pub). Trust file may not replace pin. Windows operator pins hash in protected key record.

## Exact operations
SyncTrustStore.bootstrap(ownerPublicKey:Data,membership:SyncMembership,confirmation:String)throws->SyncTrustRecord;
install(_ membership:SyncMembership)throws; authorize(_ frame:SyncSignedFrame)throws->SyncMember;
prepareRotation(replacing:SyncPublicIdentity,checkpoints:[SyncCheckpoint])throws->SyncMembership;
revoke(deviceID:String)throws->SyncMembership; reseed(checkpoint:SyncCheckpoint,archive:Data)throws->SyncCheckpointReceipt.
SyncPairingCoordinator.makeOffer()async throws->SyncPublicIdentity;
confirm(ownerFingerprint:String,membership:SyncMembership)async throws; cancel()->Void; MainActor UI, trust actor performs storage.
Offer contains PUBLIC key/device ID only. User verifies full64hex fingerprint via existing Mac/phone screen/QR,
then owner builds membership with exact app/relay/Windows IDs/endpoints/storeIDs; owner native signature required.
No nearby invitation acceptance, no network auto-enrollment, no trusting displayName or Tailscale headers as app identity.
Mac/iPhone corresponding stores share storeID, origin differs. Blank/unknown user endpoints return identityUnavailable until configured.
All role/keyID/publicKey/storeKind uniqueness/epoch constraints validated before persistence. Foreign dataset never silently merged.

## Commit/fence ordering
Install: verify pinned owner signature→require next epoch/current previousHash→acquire writer fence→persist candidate trust+fence
atomically→replace in-memory trust→invalidate outstanding challenges→release. DB membership copy updated under same server writer;
file crash reconciliation chooses only owner-signed next epoch, never rolls fence backward. No request admitted during reconciliation.
Every admission captures epoch; transaction rechecks current epoch under writer immediately before COMMIT.
Old nonce reservations invalid after restart/epoch transition; replay cannot update received/applied or ACK.
Sequence is (dataset,store,origin), contiguous UInt64 string; never device timestamp. See R3-05 for gap rejection and retry.
Owner signature verifies membership, app signature verifies operations, actual receiver signature verifies receipt level;
relay cannot issue applied even with valid relay frame. Validate embedded signer too, not merely transport key.

## Rotation/revocation
Graceful prepareRotation requires all required members reachable and all unsigned/pending acknowledged through sealed checkpoints.
If any pending/offline member: return busy with NO state change; application continues local edits on old valid epoch.
On satisfied prepare, briefly freeze new allocations; owner signs epoch+1 replacing one member key, previousHash current,
store IDs unchanged. Install on all members via signed local import, reseed through checkpoints; then release allocation fence.
Failure mid-install: remaining members stop sync on epoch mismatch; data stays local, no automatic downgrade. Retry install idempotent.
Emergency revoke signs epoch+1 without revoked member; remaining apps retain local state, block old-epoch incoming work.
Old pending from revoked identity kept as recovery-only data; explicit user selects payload to reissue with new current mutation ID
through normal domain command after comparing current head. Never silently re-sign old bytes or revive tombstones.
Owner-key rotation is explicitly NOT automatic v1 feature; owner key loss means isolated local usage plus explicit export/new-dataset
re-enrollment. No insecure recovery backdoor; compile interface returns identityUnavailable/recoveryRequired presentation.

## Checkpoint/reseed
Owner-approved current checkpoint+archive verified against receiptRoot/all required signed ACKs and hash before install.
No archive behind local applied frontier or containing unresolved uncovered local pending can install; staleBase preserves both.
Archive payload decoder closed by R4-02…07, restore uses existing store durability; no whole disk/file restore by remote path.
Reseed does not reset origin sequence to1 under same origin ID. New device gets new ID; existing sequence resumes durable max+1.
Tombstones>=30d eligible ONLY after signed required coverage; unresolved conflict/pending never garbage-collected.
Signing errors preserve local domain receipt/outbox; transport reattempt new nonce/requestID same operation; R3 retry limits remain.
Release evidence: pair/mismatch/cancel/key-locked, replay/sequence/epoch-race, one-device outage, restart mid-install,
forged stored-vs-applied ACK, old checkpoint, disk-full and explicit revoked-edit recovery. Implementation APIs are sealed now.

## Revision5 recovery amendment
Use RecoveryArchiveVerifier.verify, SyncTrustStore.prepareImport/commitImport, ArchiveMappedIdentity and
ArchiveImportReceipt exactly as R5-04 specifies. key(for:purpose:) distinguishes current live admission from
historical archive verification; rotation retains historical material until signed receipt coverage permits pruning.
 
## Revision6 supersession
R6-04 gives the concrete recovery signing domain, epoch/index schemas, eight-epoch overflow and custody rules. R6-05
gives the receipt-first import retry state machine. Those signatures supersede the shorthand names in this historical sheet.
