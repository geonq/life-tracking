# R20-04 — sequence-zero receipt signing and capability consumption

Supersedes R19-01's undefined bootstrap signMutation exception; retains separate receipt custody and R17-05 immutable authority/seal order.
P01 only: ios/Sync/SyncIdentityStore.swift key actor, Shared/SyncContract.swift DTOs, SyncWireCodec.swift hashes.
P18 constructs authority in LifeOSReceiptCoordinator.swift; P16 requests foreground setup authorization in ModuleNavigation.swift.
ReceiptAuthorityKeyStore19 remains a separate actor in the same file as SyncIdentityStore. No replication key/role/CLI permission expansion.

## Typed entry point, return and domains

`signBootstrapFence(record:UnsignedAuthorityMutationV9,authorization:ReceiptBootstrapAuthorization19) throws -> SignedBootstrapFence20`.
UnsignedAuthorityMutationV9 = exact R17 MutationV9 excluding signature ONLY; recordHash and receiptDevice signerKeyID required and recomputed.
`SignedBootstrapFence20={record:LifeOSAuthorityMutationV9}` is Sendable with internal initializer, not externally Codable capability.
The enclosed signed record is ordinary persisted R17 MutationV9; no new record kind or wire signature format.
`signMutation(record:UnsignedAuthorityMutationV9,authorization:ReceiptMutationAuthorization19) throws -> ReceiptSignature19` remains ordinary API.
Ordinary method rejects sequence0/kind fenceOpen ALWAYS; bootstrap method rejects everything except exact kind1/sequence0/previousRecordHash=null.
Bootstrap signature bytes EXACT F("LifeOS/receipt-authority-mutation/v9",CJ(record without signature)); hash domain unchanged R17.
No generic authorization union or public raw sign method. Every caller selects the typed method, no inferred authorization from sequence value.
Verification kind mutation continues verifying both original fence and later records; verification does not grant mutation authorization.

## Bootstrap authorization and durable reservation

ReceiptBootstrapAuthorization19 is non-Codable, unforgeable outside key actor with fields:
{installationID,authorityID,migrationEpoch,bootstrapToken,deviceKeyID,ownerKeyID,expectedExistingAuthorityHash:H?,authorizationID:UUID}.
P01 `authorizeReceiptBootstrap(confirmedFingerprint:String?,existingAuthorityHash:H?,authorityID:UUID,migrationEpoch:UInt64,bootstrapToken:UUID)` returns that capability.
Extends R19 exact signature with required identity arguments. First setup requires existingAuthorityHash=null and no activated seal/authority.
Existing-activated recovery is NOT first setup: this API returns receiptAuthorityAlreadyActive; old-authority migration remains separate owner recovery.
Before issuing capability, exclusive bootstrap lock + explicit native setup confirmation + matching pinned Keychain installation/roles required.
AuthorityID/token allocated once for the attempt before authorization; retry reads durable reservation below instead of generating new IDs.
Capability valid only in current key actor/session. Its authorizationID cannot be serialized or supplied by network/CLI/background UI.
`BootstrapReservation20={schemaVersion:20,installationID:UUID,authorityID:UUID,migrationEpoch:U64,bootstrapToken:UUID,ownerKeyID:H,deviceKeyID:H,fenceHash:H,fence:LifeOSAuthorityMutationV9,status:Status}`.
Status reserved=1,activated=2; size<=12288. Keychain service LifeOS.receipt-authority.v1, account <installationID>/bootstrap/<authorityID>.
Same device-only accessibility/unsynchronizable/default app access group as R19 keys; contains public signed material, never private seed.
Reservation written AFTER signature calculation but BEFORE returning SignedBootstrapFence20; SecItemAdd duplicate -> reread exact comparison.
Crash before reservation persisted: no returned fence/no authority publication possible; explicit retry signs same authorized candidate deterministically.
Crash after reservation persisted: matching candidate returns stored complete signature, no new random IDs/preimage; changed candidate ->bootstrapConflict.
Only one unactivated reservation per installation; reserve all fields before authority publication. A second authority request cannot bypass active reservation.
No normal data deletion removes reservations, pin, receipt keys or BootstrapSeal. Retain activated reservation as bounded one-authority evidence.

## Validation, ownership and use-once meaning

Bootstrap method validates complete record key set/hash, role pin, authorityID/epoch/token, exact3 source/initial inventories in fixed order/caps,
and equality to capability/reservation, plus absent activated seal and no ordinary mutation history.
Fence signerKeyID equals receiptDevice. Only bootstrapFence is signed; kind2..11, foreign authority/epoch, nonzero sequence or nonnull predecessor rejected.
Owner signAuthority(record:) receives additional `authorization:ReceiptBootstrapAuthorization19` for first creation;
it verifies embedded fence equals stored reservation exactly, public pins/token/epoch/inventory hashes match, and seal is absent/prepared for this authority.
Returning fence does not activate mutation rights. Capability is consumed for a SINGLE recordHash, with identical retries allowed before activation.
R17 ordering: signed reserved fence -> complete signed authority -> persist prepared BootstrapSealV9 -> authority exclusive-create/file+parent sync
-> log exclusive-create with identical fence/file+parent sync -> persist activated seal -> mark reservation activated -> ordinary mutations permitted.
`activateReceiptBootstrap(verified:VerifiedBootstrapPublication20) throws` is key-actor API used ONLY by P18 after rereading authority/log.
VerifiedBootstrapPublication20 is internal non-Codable {authorityID,authorityFileHash,bootstrapToken,fenceHash,logHeadHash,logHeadSequence:0}.
P18 factory validates file identities, signatures, synced complete sequence-zero log; actor checks prepared seal/hash/token/reservation before activation.
If activated seal write succeeds but reservation status update fails: open treats seal as authoritative activated; repair reservation status before ordinary mutation.
No ordinary mutation may be signed using stale bootstrap capability once seal activated, including an identical sequence-zero retry; return bootstrapAlreadyActivated.
Caller after activation reads stored fence/authority instead of signing anew. `signMutation` requires active seal + replay-validated nextSequence>=1 capability.
Ordinary capabilities bind authority/epoch/sequence/predecessor/hash as R19; neither kind1 nor bootstrap authorization accepted through that method.

## No-backup first-start recovery

|state|action|
|---|---|
|reservation absent, no seal/authority/log|foreground authorize/init keys; construct and reserve exact fence|
|reservation present, no seal/authority/log|foreground retry may reuse exact candidate; changed discovery needs explicit discardUnusedBootstrap below|
|prepared seal absent authority/log|R17 may clear matching prepared seal; reservation remains; reuse exact candidate or explicitly discard before rediscovery|
|prepared seal +authority +missing/torn-first log|verify authority/reserved fence/seal; recreate exact embedded fence, sync, activate without signing new bytes|
|prepared seal +complete fence-only log|reread/sync, activate; retained signatures enough, no new bootstrap capability necessary|
|activated seal +reserved status|repair status to activated, refuse bootstrap signer, replay log normally|
|activated seal +missing log|authorityMutationLogMissing; no sequence-zero reconstruction or key regeneration|
|reservation/authority/fence mismatch or prepared with later records|authorityInvalid/bootstrapConflict; preserve all bytes, no reset|

`discardUnusedBootstrap(authorization:ReceiptBootstrapAuthorization19,verifiedAbsence:VerifiedBootstrapAbsence20) throws` is foreground-only.
P18 verifies no authority/log/canonical/legacy effects and no activated seal under exclusive lock; absence capability binds authority/token/pinned parent.
Actor removes only matching prepared seal/reservation AFTER verifying absence; never removes keys/installation pin, activated records or user data.
This narrowly replaces R17's implicit rediscovery after prepared-seal/no-authority crash; rediscovery cannot silently alter a reserved fence.
Read-only startup can finish prepared publication using signed material, but cannot issue new bootstrap authorization or discard a reservation.
Existing replication-signed historical authority remains read-only per R19; this API is not an undocumented key migration.

## Error and proof cases

Extend closed local errors: bootstrapConflict,bootstrapAlreadyActivated,receiptAuthorityAlreadyActive,bootstrapConfirmationRequired.
All error bodies content-free. No seeds, bodies or tax/health content logged; no Keychain secrets archived or synced.
Planned vectors: all11 mutation kinds through bootstrap/ordinary APIs; changed token/epoch/pin/inventory/hash; duplicate exact retry before activation.
Crash each Keychain/file/seal boundary; same stored signature/recordHash on recovery; activated history cannot be downgraded by deleting its log.
No hardware monotonicity claim; restoring all secure state is outside rollback resistance. No source implementation/security acceptance claimed.
