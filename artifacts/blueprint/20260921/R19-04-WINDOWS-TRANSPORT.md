# R19-04 — authenticated Windows data-management transport

> R20-06-DISPATCH.md explicitly supersedes the five reviewed topics and related field additions; this R19 sheet remains authoritative only where retained. Prior readiness is historical.
Supersedes the closed R10/R11 route list ONLY by adding the route below; all framing, nonce/signature and response checks remain.
P01 types/codecs/SyncTransport.swift; P02 gateway main.py/replication.py; P15 Node server.ts/history.ts; no additional source paths.
Do not add replication_keys.py or edit clipper-store.ts: helper declarations belong to these existing allowed files.
R18 deletion targets stay typed domain IDs. Windows supported targets are usageLocal/clipperLocal wholeStore, host windows only.
No remote raw tax/photo transfer, arbitrary filename, shell/SSH execution, generic filesystem deletion or new public listener.

## One external transport and concrete calls

POST `/replication/v1/data/manage`, tag `data.manage`, over enrolled Tailscale HTTPS; no redirect, query or content encoding.
Existing edge authorization plus R10 request/R11 response authentication and current membership are mandatory; unsigned requests denied.
Request and response raw bodies <=65536; decoded typed payload<=49152, headers<=32768, timeout30s, one mutation in flight/dataset.
Capabilities hello adds `data.manage.v19`; absent capability→unsupported, never fall back to an unauthenticated legacy endpoint.
`SyncTransport.manageData(_ request:DataManageRequest19,endpoint:SyncEndpoint) async throws -> DataManageResponse19`.
P02 `handle_data_manage(frame: VerifiedHTTPFrameV6) -> SyncHTTPResponseV6` dispatches decoded action to:
`prepare_deletion(input)`, `apply_deletion(context)`, `inspect_deletion(context)`, `close_deletion_fence(close)` in replication.py.
All receive verified member/epoch context internally, never a client-provided role. Python awaitable wrappers in main.py await blocking I/O off event loop.
Same operations exposed through P01 remote LifeOSDataStoreAdapter; no second deletion client in TailscaleSyncClient.

## Exact wire payloads, outcomes and authorization

DataManageRequest19={schemaVersion:19,datasetID:UUID,operationID:UUID,action:Action19,payload:Payload19}.
Actions deletion.prepare/deletion.apply/deletion.inspect/deletion.close, restore.prepare/restore.apply/restore.inspect.
Payloads respectively DeletionPrepareInput19,DeletionApplyContext19,DeletionApplyContext19,DeletionClose19,
RestorePrepareInput19,RemoteRestoreApply19,RestoreApplyContext19. No null union: only selected payload schema accepted.
RemoteRestoreApply19={context:RestoreApplyContext19,source:RemotePackSource19}; source={storeID,packHash,sourceHash,blobHash:H,byteCount:U64}.
Restore source is a verified <=8MiB usage/clipper pack staged through existing signed bounded blob transfer; NOT arbitrary URL/path.
Server revalidates host-entry hashes/sourceHash against staged blob before restore. Blob content may contain only the two Windows descriptor formats.
DeletionClose19={receiptID:UUID,operationID:UUID,fenceID:UUID,workPlanHash:H,disposition:String,completedTargetKeys:[H]}.
Disposition exactly completed|abandoned; completed requires every Windows target proved, list sorted<=2; abandoned requires no unresolved effect.
DataManageResponse19={schemaVersion:19,operationID:UUID,action:Action19,resultKind:String,result:Result}.
Results: preparedDeletion→DeletionPrepared19; appliedDeletion→DeletionAppliedV8; inspectedDeletion→DeletionInspection19;
closed→RemoteFenceProof19; preparedRestore→RestorePrepared19; appliedRestore/inspectedRestore→DataCompletionProof19 or null ONLY inspect absent.
RemoteFenceProof19={operationID,fenceID,workPlanHash,completedTargetKeys,disposition,collectorsDisabled:Bool,proofHash:H}.
Hash=H("LifeOS/remote-fence/v19",object excluding proofHash); completed always collectorsDisabled=true.
Successful/applicable nullable variants validated before wrapping/signing R11 response. Errors use existing signed HTTP error carrier plus closed error code.
App must be current nonrevoked enrolled app member with the dataset's owner-approved data-management capability in server configuration.
Relay/storing-only identities cannot call this route. Explicit native Delete/Restore confirmation creates operation; background sync never does.
Gateway requires payload receipt/operation/dataset/server host match admitted identity and exact target allowlist before dispatch.
Deletion trust retirement happens only AFTER remote proofs and close receipt are durable locally; receipt keys are never transport credentials.
HTTP retry uses R11 fresh session/nonce when necessary; same immutable operation/context identity survives transport attempts.

## Local Windows owner boundary (same machine, no public API)

Gateway forwards only admitted operations to Node at fixed `http://127.0.0.1:<configured API port>/internal/data-manage`.
This is implementation IPC behind the single external transport; never expose via Vite/proxy/public routing.
LocalDispatch19={schemaVersion:19,datasetID,serverKeyID:H,memberKeyID:H,epoch:U64,dispatchID:UUID,operationID,requestHash:H,issuedAt:timestamp,expiresAt:timestamp,request:DataManageRequest19,signature:Data}.
requestHash=H("LifeOS/data-manage-request/v19",request); dispatchID allocated once per admitted call; expiresAt=issuedAt+30000ms.
Server key signs F("LifeOS/local-data-dispatch/v19",CJ(dispatch without signature)); P02 typed `sign_local_data_dispatch` in replication.py.
The Windows existing DPAPI signer gains only this typed method and `sign_data_completion(proof)`; generic sign(kind,body) remains unchanged.
Node verifies Ed25519 with pinned enrolled gateway public key provisioned read-only by P17, exact epoch/dataset/loopback Host, time window and request hash.
Pin is `data-management-gateway-public.json` under protected service data root; public key is not trusted from request itself; absence blocks startup admin route.
Gateway rechecks current membership before issuing dispatch. Node never consumes external nonce; gateway is its admission authority.
Dispatch cache persists last256 IDs/hash/result, <=8MiB; identical returns same result, different hash conflicts; expired uncached dispatch rejected.
An expired dispatch may be reissued only by gateway's renewed membership check. Durable mutation identity is receipt/operation/target, not dispatchID.
Node response={schemaVersion:19,dispatchID,requestHash,resultKind,result}; no secret or arbitrary reflection.
Gateway verifies response against durable owner marker read from protected local store AND actual canonical content/absence under the owner gate before signing external response.
Gateway and Node run same protected service identity/root; loopback peer modification by that identity is outside distinct-principal guarantees.
No assertion that unsigned loopback responses alone prove durable mutation. Never sign success if marker/readback differs.
P15 `handleDataManage(dispatch:LocalDispatch19): Promise<LocalDataResult19>` lives in server.ts; auth before any path resolution/effect.

## Collector fencing and actual deletion implementation

P15 declares `WindowsDataManagementOwner19` in server.ts; it serializes usage/clipper admin plus ALL read-refresh/ingest paths via one gate.
Durable `data-management-owner-v19.json` in protected API root holds active operation, prepared targets, pending intent, applied proofs, closed tombstones and enabled flags.
Maximum one active op, two targets,256 closed operation tombstones,16MiB; at capacity reject NEW operation before effect, never evict active identity.
Exact persisted owner object: {schemaVersion:19,datasetID:UUID,active:RemoteActive19?,closed:[RemoteClosed19],dispatchCache:[DispatchCache19],usageEnabled:Bool,clipperEnabled:Bool,stateHash:H}.
RemoteActive19={operationID:UUID,receiptID:UUID,fenceID:UUID,workPlanHash:H,kind:String,prepared:[RemotePrepared19],pending:RemotePending19?,proofs:[RemoteProof19]}.
kind deletion|restore; prepared/proofs <=2 keyed by exact storeID. RemotePrepared19 tagged {kind,payload} carries full deletion or restore input+Prepared.
RemotePending19 is same tagged full apply context; restore also includes RemotePackSource19. RemoteProof19 tagged carries full context and applied marker/proof.
RemoteClosed19={operationID,receiptID,fenceID,workPlanHash,kind,proofs:[RemoteProof19],fenceProof:RemoteFenceProof19?}; fenceProof required for deletion closure.
DispatchCache19={dispatchID:UUID,requestHash:H,expiresAt:timestamp,resultKind:String,result:Result}; each<=32768,<=256 and8MiB total.
Closed/prepared records are sorted by operationID/storeID, dispatchCache by dispatchID; unknown keys/duplicates rejected before admission.
Hash=H("LifeOS/windows-data-owner/v19",complete object without stateHash); atomicWriteFile + existing path identity/ACL protection.
Startup loads/reconciles owner record BEFORE creating collectors or accepting reads/ingest; corruption blocks them, never resets to enabled.
Prepare: hold gate; mark relevant collectors disabled durably; cancel/await owned work; acquire existing store writer lock; read canonical state/version; persist Prepared; return.
Usage all write methods in history.ts check persisted owner fence while holding withHistoryWriteLock; lock order ownerGate→historyLock, never inverted.
P15 adds `UsageHistory.prepareDeletion(input)`, `applyDeletion(context)`, `inspectDeletion(context)` using existing durable-state owner.
Whole deletion uses empty validated entries/idempotency state and next revision, commits via existing atomic state/projection repair; no unowned rm of usage history.
Clipper: after gate drains every server-owned ingest/refresh, capture authoritative envelope hash/revision, persist intent, unlink only pinned configured store file, sync parent.
Dispose cached ClipperStore instance and recreate via server-owned factory after verified absence; no edits needed in clipper-store.ts.
All server entrypoints must use that factory/gate; no retained ingest reference may bypass it. Out-of-process raw-file writers are forbidden by deployment ACL/operator contract.
Clipper absence returns unavailable through existing reader; never fabricate a zero snapshot. Retain deletion marker outside deleted content.
Usage afterHash and clipper afterHash use exact R18 absent marker preimage after verified logical content removal; infrastructure remains.
Prepared/intent stores original beforeHash and version. Apply same-context retry checks stored marker first; changed precondition→409 staleTarget.
Write pending intent -> effect/flush/parent sync -> verify absence or canonical empty state -> persist applied marker -> return.
Crash pending: exact before→apply; exact after→flush/readback/marker; other→staleTarget. Response loss→inspect same context returns marker.
Close completed leaves producer flags disabled durably; explicit later reconnection is required to re-enable collectors, not automatic restart.
Close abandoned settles pending effects and records stopped/retained state; it may re-enable only undeleted scopes explicitly selected by user, default disabled.

## Restore through the same owner

prepare/apply/inspect restore use same gate, captured beforeHash/version, pending intent and atomic/readback proofs from R19-02.
Usage restored with existing history validator/atomic owner; clipper restored using verified existing envelope through atomicWriteFile, recreate cache after publication.
Node returns unsigned exact proof fields; gateway re-reads marker and signs `F("LifeOS/data-completion-signature/v19",raw32(proofHash))` with server key.
signerKeyID is known before proof hashing and stored in marker. Repeated signing is deterministic Ed25519; no wall-clock fields.
Restoring trust/key files or enabling collectors from archive metadata is prohibited. R19-02 preserved policy does not authorize remote key writes.
If source blob or host is unavailable return gatewayUnavailable/sourceChanged; no empty proof. Restore progress remains resumable locally.

## Durable sequencing, ownership and planned checks

Gateway durable session reservation -> admitted local dispatch -> owner intent/effect/proof -> verify marker -> cached signed R11 response+nextNonce -> send.
Crash after effect before external cache uses inspect/marker, never executes a second clear with a fresh beforeHash.
R19 errors staleTarget,idCollision,deletionInProgress,operationReuse,capacity,collectorFenced,sourceChanged map409/429/503 as applicable; I/O507/503, auth401/403.
P01 Swift/TS contracts; P02 gateway route/signing/public marker verification; P15 Node owner/history/gating; P17 pin/ACL setup; P18 journal consumer.
Keep dependencies unchanged: P02 codes against declared P01/P15 interfaces; real route capability stays disabled until P15 implementation verifies.
Planned checks include replay/expired dispatch, non-app principal, Host spoof, missing pin, offline/rejoin, ingests racing prepare, crash at every durable boundary.
No deployment, tests or dependency edits in this planning revision.
