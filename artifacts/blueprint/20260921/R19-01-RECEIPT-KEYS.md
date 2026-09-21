# R19-01 — receipt-authority custody and exact signing ports

> R20-06-DISPATCH.md explicitly supersedes the five reviewed topics and related field additions; this R19 sheet remains authoritative only where retained. Prior readiness is historical.
Normative replacement for receipt-signing assumptions in R17-02/05/06 and R18-02; R4-09 replication custody remains unchanged.
P01 owns declarations in SyncContract.swift, codecs in SyncWireCodec.swift, key actors in SyncIdentityStore.swift.
These are locations inside ios/Shared or ios/Sync already assigned by14; no new source file, package or CLI action.
R17 CJ/F/H, UUID, timestamp and base64url conventions apply. Key IDs are lowercase SHA256(raw Ed25519 public key).

## Separate roles and persisted identity

`ReceiptKeyRole19: String` is receiptOwner | receiptDevice; it is NOT a SyncKeyRole case.
`ReceiptPublicIdentity19={schemaVersion:19,installationID:UUID,role:ReceiptKeyRole19,keyID:H,publicKey:Data}`.
P01 adds `actor ReceiptAuthorityKeyStore19` in SyncIdentityStore.swift; only native app composition receives it.
Keychain class generic-password, service `LifeOS.receipt-authority.v1`, account `<installationID>/<role>`.
Synchronizable=false; accessible=AfterFirstUnlockThisDeviceOnly; default application access group, never widget/shared group.
Value is canonical `{schemaVersion:19,installationID,role,seed:base64url32,publicKey:base64url32,keyID}` <=1024 bytes.
Software CryptoKit Curve25519.Signing.PrivateKey; no Secure Enclave claim. Public verification never needs seed retrieval.
Separate Keychain account `installation` stores `{schemaVersion:19,installationID,ownerKeyID,deviceKeyID}` <=512 bytes.
Replication service `LifeOS.replication.v1`, roles app/relay/owner, retirement and closed sign(kind:bytes:) allowlist are UNCHANGED.
Receipt keys sign no HTTP, replication operation, membership, ACK, provider or arbitrary message. Replication keys sign no new receipt record.
SignerCLI identity/sign/verify allowlist unchanged: it cannot initialize/load/use receipt keys or export private material.

## Explicit bootstrap and recovery

`initializeReceiptAuthority(authorization: ReceiptBootstrapAuthorization19) throws -> ReceiptKeyPair19` is native-only.
ReceiptKeyPair19 contains the two PUBLIC identities. Authorization is a non-Codable value with internal initializer.
`authorizeReceiptBootstrap(confirmedFingerprint: String?, existingAuthorityHash: H?) throws -> ReceiptBootstrapAuthorization19`
is called by P16 only after explicit foreground setup confirmation; nil fingerprint allowed only first setup with no authority.
Authorization binds installationID and current absence/existing hash under the same exclusive bootstrap lock; cannot cross a task/session.
No automatic key creation from open(), decoding, network request, deletion, missing key, or migration retry.
First setup: create owner key, device key, then installation pin; reread keys and pin before constructing authority/fence.
Crash with partial keys and no authority/seal: subsequent explicit initialize reuses validated existing keys and completes missing rows.
Duplicate Keychain item: reread and compare identity; never overwrite. Keys plus pin become custody BEFORE R17 prepared BootstrapSeal.
R17 ownerKeyID/publicKey mean receiptOwner; authorized deviceKeyID/publicKey mean receiptDevice for NEW authorities.
Prepared/activated BootstrapSealV9 lives in this service at `<installationID>/seal/<authorityID>`; R17 activation order unchanged.
Open verifies pin -> public keys -> immutable authority -> seal -> signed mutation log. Never derive trust from authority file alone.
Missing/locked key with existing pin/authority returns receiptKeyUnavailable; malformed seed/pin mismatch returns receiptKeyCorrupt.
Already signed records remain verifiable with pinned public keys; inability to sign blocks new mutation, not read-only inspection.
No regeneration with an activated authority. Recovery requires explicit restoration of original device-local keys/secure state or a separately authorized new authority; never quietly reset logs.
Historical R15/R17 authorities signed by replication keys verify under their ORIGINAL pinned key/codec only, read-only.
`openForMutation` on such authority returns receiptAuthorityKeyMigrationRequired; no undeclared key substitution or original signature rewrite.
No deployed historical receipt authority is assumed from a planning document. Observed legacy key ownership requires an explicit migration amendment before mutation.

## Typed signing API and exact preimages

`ReceiptSignature19={keyID:H,signature:Data}`; signature exactly64 bytes. Each method validates the complete typed object BEFORE signing.
Public methods are synchronous actor-isolated throws; callers await actor crossing. Input objects omit ONLY signature, retaining signerKeyID/hash fields.
`publicIdentities() throws -> ReceiptKeyPair19`; `verifyReceiptSignature(kind:ReceiptSignatureKind19,object:Data,signature:ReceiptSignature19,pin:ReceiptKeyPair19) throws`.
Verification decodes canonical bounded typed object selected by kind; no caller-selected label/preimage escape hatch.

|method / kind|role|exact signed bytes and validation|
|---|---|---|
|signAuthority(record:) / authority|receiptOwner|F("LifeOS/receipt-authority-owner/v9",CJ(record without signature)); exact paths, embedded valid device fence and public pins|
|signSealUpgrade(upgrade:) / sealUpgrade|receiptOwner|F("LifeOS/receipt-seal-upgrade/v9",CJ({authorityID,authorityFileHash,logHeadHash,logHeadSequence})); existing pinned authority only|
|signMutation(record:) / mutation|receiptDevice|F("LifeOS/receipt-authority-mutation/v9",CJ(record without signature)); recompute R17 recordHash and legal kind/fields|
|signLegacyIntent(intent:) / legacyIntent|receiptDevice|raw32(intentHash); recompute H("LifeOS/legacy-retire-intent/v9",intent excluding intentHash/signature)|
|signLegacyProof(proof:) / legacyProof|receiptDevice|raw32(proofHash); recompute H("LifeOS/legacy-retire-proof/v9",proof excluding proofHash/signature)|
|signRetirement(proof:) / retirement|receiptDevice|raw32(proofHash); recompute H("LifeOS/receipt-retirement-proof/v9",proof excluding proofHash/signature)|
|signCheckpoint(checkpoint:) / checkpoint|receiptDevice|F("LifeOS/authority-checkpoint-signature/v9",raw32(checkpointHash)); recompute complete R17 checkpoint hash|
|signAnchor(anchor:) / anchor|receiptDevice|F("LifeOS/receipt-anchor-signature/v8",raw32(anchorHash)); recompute complete R18 anchor including retryEvidenceHash|
|signCompletion(proof:) / completion19|receiptDevice|F("LifeOS/data-completion-signature/v19",raw32(proofHash)); recompute R19-02 proofHash|
|signDeletionCompletion(record:) / deletionCompletion19|receiptDevice|F("LifeOS/deletion-completion-signature/v19",raw32(completionHash)); recompute R19-05 completionHash|

ReceiptSignatureKind19 is exactly the ten strings in table; unknown kinds rejected. No generic public sign(bytes:) method.
Raw-hash signing retained ONLY for three explicitly listed historical v9 contracts; their different hash domains are verified first.
Every object authorityID/installation/key/epoch/receipt identity must match current immutable authority and injected verified state.
P18 decides legal durable transitions; key actor checks typed/pinned identity, not disk state or a fabricated claim of fsync.
`signMutation` takes additionally `authorization: ReceiptMutationAuthorization19`, non-Codable capability built by P18 replay validator.
It binds authorityID, epoch, nextSequence, previousRecordHash and recordHash; key actor requires exact equality.
Bootstrap sequence0 uses R17 embedded fence under unused explicit BootstrapAuthorization; no ordinary mutation capability before activated seal.
No signing API exports seed. All errors content-free; never log object bodies, keys, raw tax/health data or signatures as diagnostics.

## Retention and deletion exclusions

`retireReplicationCredentials` addresses ONLY LifeOS.replication.v1 accounts and SyncTrustStore enrollment; never generic Keychain deletion.
DeleteUserData preserves both receipt roles, installation pin, seal, Receipts authority/logs, active completion journal and retry evidence.
These are audit infrastructure, not a 27th user store. R19-02 recoveryImports/replicationTrust handling must preserve them.
There is no receipt-key retirement API in normal data deletion. Full installation erase is outside this operation and cannot be inferred.
Reinstallation with preserved app data but unavailable ThisDeviceOnly keys is explicitly receiptKeyUnavailable, not blank history.

## Planned proof cases

P01 tests every kind/role cross-product; foreign authority, wrong label/hash/pin and CLI misuse must fail before signing.
Crash bootstrap after each Keychain row/seal/file boundary; only explicit initial setup can complete missing initial rows.
P18 deletion/reopen/compaction after replication-key retirement must use unchanged receipt pins and validate original receipt signatures.
P16 setup supplies authorization; background startup never prompts itself into new trust. Independent security/runtime evidence remains required.
