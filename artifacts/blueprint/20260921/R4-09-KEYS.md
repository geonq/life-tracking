# Exact identity/key-custody contract — CP-K sealed
Ed25519 software signing via CryptoKit/cryptography; do not claim Curve25519 private key is Secure Enclave backed.
Private key never appears in JSON, CLI args, log, widget, archive, sync payload, or UserDefaults.

## Concrete native key API (P01 SyncIdentityStore.swift)
actor SyncIdentityStore: initialize(role:SyncKeyRole,datasetID:UUID)throws->SyncPublicIdentity;
publicIdentity()throws->SyncPublicIdentity; sign(kind:SyncSignedKind,bytes:Data)throws->Data;
retire(keyID:String)throws. No public loadOrCreateKey()->Data: revision2 proposal superseded.
SyncKeyRole enum app,relay,owner; SyncPublicIdentity {deviceID:String,keyID:String,publicKey:String,role:SyncKeyRole}
Codable/Sendable; strings UUID/HASH/base64url32; public metadata only. DeviceID allocated once alongside key.
SecItemAdd/CopyMatching/Update/ Delete fixed class kSecClassGenericPassword, service='LifeOS.replication.v1',
account=datasetID+'/'+role, kSecAttrSynchronizable=false,kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
valueData canonical local identity JSON{schemaVersion:1,deviceID:UUID,seed:base64url32};<=1024bytes.
Create Curve25519.Signing.PrivateKey() only on explicit initialize and errSecItemNotFound with NO existing trust identity.
errSecDuplicateItem→reread existing; errSecInteractionNotAllowed/notAvailable→identityUnavailable, never regenerate.
Corrupt seed/public mismatch→corruptStore; absent seed with existing trust→identityUnavailable recovery, not new identity.
sign validates requested kind allowed for role: owner membership only; app operation/ack/checkpoint/frame/observation; relay stored-ACK/frame only.
Operation and ACK fields must match local identity, not arbitrary supplied foreign origin; owner init UI is explicit.
Secrets live only within key actor/sign operation memory; best-effort temporary buffer clearing, no impossible memory-copy guarantee.
Keychain locked/denied means local commits retain unsigned outbox; UI says sync unavailable, not save failed if domain committed.

## Mac Python relay bridge (P02, no key in Python)
Keep services/mac-relay/main.py. Add Swift executable target LifeOSSyncSigner in ios/project.yml (P16),
sources ios/Sync/SignerCLI.swift + shared codec/key/value files, macOS14 deployment, no UI target sources.
Install signed executable to fixed user Application Support/LifeOS/bin/LifeOSSyncSigner (0700directory/0700file),
verify bundle team/code signature on launch; no PATH/CWD lookup. P02 LaunchAgent invokes absolute Python+script paths.
SignerCLI.run() reads ONE length-prefixed JSON request from stdin(max2MiB), stdout one framed reply(max2MiB), then exits.
SignerRequest {schemaVersion:1,action:'identity'|'sign',kind:String?,body:String?}; required nullable slots;
identity requires both null, sign kind=frame or acknowledgement and body=base64url canonical signed-kind content.
SignerReply {schemaVersion:1,identity:SyncPublicIdentity?,signature:String?,error:SyncErrorCode?}; exactly success slots or error.
For sign stored-ACK only level stored/local replica; frame senderID local relay/status200 or documented error, exact route list.
No arbitrary owner/membership/operation signing, no private-key export action. Validation in native executable, not only Python.
Native helper owns separate relay-role Keychain identity; app displays helper public fingerprint for local enrollment.
Python call_signer(request:SignerRequest)->SignerReply uses subprocess.Popen([fixed_path],shell=False), bounded stdin/stdout,
5s deadline, single serial call, returncode0+valid reply; timeout kill owned child/reap, error identityUnavailable.
Keychain approval/trust on first helper run is user-gated release setup; denial has defined unavailable result and compile-safe interface.
Mac cryptography only PUBLIC signature verification using pinned package; helper handles all relay private signing.

## Windows custody (P02 services/gateway/replication_keys.py)
WindowsReplicationSigner.initialize()->SyncPublicIdentity; load()->None; sign(kind:str,body:bytes)->bytes.
Use existing locked service data root; keys/replication.ed25519.dpapi is exclusive private file, never environment raw key.
Seed cryptography Ed25519PrivateKey.generate().private_bytes(Raw,Raw,NoEncryption) inside service process only.
Protect with CryptProtectData current USER scope, flags CRYPTPROTECT_UI_FORBIDDEN=1, entropy UTF8('LifeOS/replication/v1'),
no CRYPTPROTECT_LOCAL_MACHINE; service identity must own profile. If no usable user DPAPI profile return identityUnavailable.
Python ctypes DATA_BLOB=(DWORD cbData, POINTER(BYTE) pbData); CryptProtectData/UnprotectData restype BOOL,
argtypes DATA_BLOB*,LPCWSTR or LPWSTR*,DATA_BLOB*,void*,void*,DWORD,DATA_BLOB*; capture GetLastError on false.
Bound output<=8192; copy then zero buffer and LocalFree; exclusive temp+FlushFileBuffers+atomic rename through protected storage layer.
DPAPI decrypted seed32bytes and stored public key must match pinned keyID. ACL owner service SID/System only per existing protector;
reject reparse/world-readable/wrong owner before opening. Source env vars may carry fixed path, never seed.
Windows process sees ONLY its storing-role seed; cannot forge app applying receipt or owner membership.
Missing file with known identity fails closed; initialize explicit operator action only, no automatic reset.
Existing provider/ingest secrets remain separate current custody; no copying into replication key file or signature frame.

## Exact errors/visibility
identityUnavailable: locked/denied/DPAPI profile/helper unavailable; corruptStore: malformed custody record;
unauthenticated: signature invalid; revoked: not in current membership; capacity: bounded I/O; timedOut: helper deadline.
User UI sees public identity/fingerprint/status only. Windows and relay see synced personal payloads by authorization,
not bank provider credentials on Mac, not HealthKit anchor on Windows, not owner seed outside native owner actor.
References: [Keychain](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)),
[device-only availability](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly),
[DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata).

## Mac verification amendment (supersedes Python cryptography verifier above)
SignerRequest adds REQUIRED verification:[SignatureCheck], <=256; identity/sign require empty verification.
SignatureCheck {publicKey:String,message:String,signature:String}, base64url32/raw<=2MiB/64; Codable Sendable, Python str fields, TS strings.
Action verify requires kind/body null; SignerReply adds REQUIRED verified:[Bool], empty for other actions.
Native verifyBatch(_ checks:[SignatureCheck])throws->[Bool] uses CryptoKit, preserves input order; no state writes.
Mac pure replication validation injects call_signer(action verify) per batch, not subprocess per operation; deadline5s/one helper.
No Mac cryptography dependency required. Windows injects native Python Ed25519 verifier using existing pinned wheel.
Bridge total request2MiB overrides individual message cap; precompute byte budget, reject capacity before spawning.

## Revision5 historical verification
R5-04 supersedes the one-epoch recovery wording: trust stores current plus bounded historical epochs with purpose-scoped
verification. Historical signatures may verify an archive but never authorize live writes; import mappings and receipts
are committed before a restored frontier is advertised.

## Revision6 supersession
R6-04 adds the concrete recovery signing input, immutable operation-key index, eight-epoch capacity rule and revoke/
rotation/reseed signatures. Private-key custody and device-only storage remain the R4-09 foundation.
