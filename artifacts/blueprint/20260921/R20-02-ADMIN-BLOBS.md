# R20-02 — administrative blob admission and canonical restore pack

Supersedes R19-04 RemotePackSource19/8MiB limit and use of store-authorized blobs for Usage/Clipper.
Retains the17-member SyncStoreKind/alias set, R11 chunk bounds and existing V6 replication payloads unchanged.
P01 codec/DTO/transport in existing Sync files/replication.ts; P02 gateway replication.py/main.py; P15 local reader in server.ts.
P18 packs verified archive sources in LifeOSDataArchiveWriter.swift; no new dependency, arbitrary URL or additional public listener.

## Isolated namespace and role exception

Admin blob namespace tuple=(datasetID,operationID,fenceID,targetHostID,storeID,blobHash); namespace literal data.restore.v20.
storeID here is LifeOSDataStoreID constrained to usageLocal|clipperLocal, NEVER a SyncStoreKind/legacy alias/replication stream.
Only current enrolled app member with existing owner-approved data-management capability, matching holding restore admission, may upload/read.
Admission fixes source descriptors/hashes before first upload. Same dataset alone is insufficient; another app/operation cannot read them.
Windows only. Mac relay returns403 administrativeScopeDenied. Storing/relay principals cannot initiate administrative uploads as app identities.
No alias table enlargement, no membership enrollment route, no raw/photo/tax/Apple-host bytes, no sync operation may reference this namespace.
New tags on existing POST /replication/v1/blob and /blob/read are admin.blob.put and admin.blob.read; negotiated capability data.restore.v20 required.
Dispatch selects exact tag + payload schema BEFORE store resolver; existing blob.put/blob.read still require permitted replicated store.
Authenticated R10 request/R11 response, TLS/edge/Host/nonce checks and R11 per-route raw caps remain mandatory for both branches.
Only this explicit administrative branch bypasses replication-store lookup; it performs the stricter admission checks above instead.

## Exact source, bundle and segmentation

`AdminBlobRef20={index:U16,blobHash:H,byteCount:U64}`;1..33554432 bytes each, contiguous indices0..count-1.
`RemotePackSource20={schemaVersion:20,namespace:"data.restore.v20",datasetID:UUID,operationID:UUID,fenceID:UUID,targetHostID:UUID,storeID:LifeOSDataStoreID,packHash:H,sourceHash:H,manifestFormat:String,manifestHash:H,manifestByteCount:U64,bundleHash:H,byteCount:U64,segments:[AdminBlobRef20]}`.
All fields required; encoded source <=8192 bytes,1..17 refs; counts sum byteCount. No filename, bearer credential or location URL.
byteCount is exact transport-bundle bytes, NOT data-only byte count; sourceHash remains R19-02 Windows-host source hash.
manifestHash = hex(SHA256(F("LifeOS/manifest-pack-object/v7",originalCanonicalPackManifestBytes))) exactly R14-02; packHash is its existing semantic hash.
Bundle bytes = ASCII LIFEADM (7 bytes) || UInt16BE(20) || UInt64BE(manifestByteCount) || manifestBytes || windowsFileBytes.
windowsFileBytes concatenates raw content for every Windows-host descriptor in canonical UTF8 path order; zero-byte files contribute0.
No per-file framing is needed: validated manifest byte counts determine boundaries. Reject trailing bytes and omitted data.
The COMPLETE original pack manifest preserves Apple/Windows descriptors to verify packHash, but ONLY Windows content bytes follow it.
Treat manifest as bounded streaming JSON, not materialized tree; use R14/R15 canonical object/partition rules and current file descriptors.
The V6 manifest has no host field; do NOT add one silently. For NEW Usage/Clipper pack production use these exact reserved relativePath values:
usageLocal: apple/usage-preferences.json -> Apple standard LifeOS.Usage.history.v1; windows/usage-history.json -> Windows UsageHistory canonical envelope.
clipperLocal: apple/revoked-preferences.json -> Apple standard LifeOS.Clipper.locallyRevoked.v1; windows/clipper-snapshot.json -> Windows canonical envelope.
This table is the complete descriptor lookup for these packs, not a caller-selected prefix-to-filesystem rule. All other paths rejected.
Absent Apple key or Windows content produces no file entry for that host, with explicit empty-unit source hash; unreachable Windows is not absence.
Each pack has0..2 entries, each host at most1,32MiB Windows envelope/4MiB Apple key cap; general bundle ceilings below remain conservative upper bounds.
Legacy pack paths require an unambiguous R7 descriptor match and validated host binding during archive verification; otherwise archiveHostAmbiguous, no mutation.
Legacy accepted formats remain readable; source preparation canonicalizes ONLY the transport descriptor lookup, never rewrites original signed manifest bytes.
For legacy manifests with explicit R7 host fields, use original version-specific decoder and host field; manifestHash uses that format's original hash domain.
Source20 manifestFormat is exactly packObjectV7 or legacyPackV2; apply the selected exact codec, never fallback after failure.
packObjectV7 uses the framed hash above; legacyPackV2 uses the original R7 packHash verification AND manifestHash=rawSHA256(original pack bytes).
Only legacy entries matching the same four registry destinations are admissible; manifestFormat is included in admission/source equality and bundleHash verification.
Windows Usage/Clipper content remains existing canonical domain-envelope bytes validated by its owner, not a replacement schema.
R19 sourceHash entries use {relativePath,byteCount,sha256}; sha256 here is independently streamed raw file SHA256, not the archive chunk-derived fileDigest.
Server validates chunk hashes/fileDigest from manifest as it reads, computes raw sha256, then sourceHash and owner envelope validation before apply.
P18 computes the identical sourceHash during original archive verification; any mismatch rejects before mutation.
Split bundle consecutively into32MiB segments (all nonfinal full); segment hash raw SHA256, bundleHash raw SHA256 of concatenation.
No base64 in stored bundle; wire chunks alone use base64url. Empty store still has a nonempty manifest/header bundle and explicit empty entries.

## Export-to-restore capacity closure

Retain archive total data<=268435456, manifest per pack<=268435456, ordinary file<=4194304, domain envelope<=33554432.
Remote Windows host subset is bounded by that archive total; allowed administrative bundle<=536870929 (=17+256MiB+256MiB).
ceil(536870929/33554432)=17 segments, so a maximum permitted pack never needs an oversized replication blob.
HTTP chunk<=262144 and raw put/read limits524288 stay unchanged; every segment<=32MiB. JSON source overhead<=8192 fits data.manage49,152 payload cap.
Two Windows bundles from one admitted archive: data sum<=256MiB, each manifest<=256MiB, headers34; total<=805306402 bytes.
Administrative staging separate from the R3 replication spool256MiB; hard ceiling805306402 plus bounded metadata4MiB per active dataset.
Reserve actual declared storage under configured15GiB free-space floor BEFORE admission; inadequate capacity fails admission, not partial silent truncation.
Limits are protocol compatibility ceilings, not permission to allocate that much RAM; one262144-byte HTTP chunk, one<=1MiB file verification window.
Maximum-size export remains representable for restore; lack of disk/provider/host remains typed capacity/unavailable, never a format mismatch.
No export is marked complete if its Windows source lacks a supported owner descriptor or fails these same envelope/path/hash checks.

## Exact upload/read schemas

`AdminScope20={namespace:"data.restore.v20",datasetID:UUID,operationID:UUID,fenceID:UUID,targetHostID:UUID,storeID:LifeOSDataStoreID}`.
`AdminBlobPut20={schemaVersion:20,scope:AdminScope20,blobHash:H,totalBytes:U64,offset:U64,chunkHash:H,bytesBase64URL:String,isFinal:Bool}`.
`AdminBlobPutResult20={schemaVersion:20,blobHash:H,nextOffset:U64,complete:Bool}`.
`AdminBlobRead20={schemaVersion:20,scope:AdminScope20,blobHash:H,offset:U64,limit:U32}`.
`AdminBlobReadResult20={schemaVersion:20,blobHash:H,totalBytes:U64,offset:U64,bytesBase64URL:String,chunkHash:H,isFinal:Bool}`.
Chunk hash raw SHA256(decoded bytes); offsets multiples262144, length=min(262144,total-offset), final iff offset+length=total.
Read limit exactly262144; final response may be shorter. Unknown/unadmitted hash403, missing/incomplete read404, wrong offset416, altered retry409.
Put accepts only blobHash/totalBytes enumerated in the immutable admission source segments for the same scope.
Identical offset+bytes returns existing contiguous nextOffset, including completed blobs. Gaps fail409 expectedOffset; no sparse unverified holes.
Complete only after entire hash verified, file synced, same-volume publication, parent sync and durable metadata commit. Recover exact orphan before replying.
No user-controlled filesystem path: names are fixed encoded scope hash and blobHash under protected admin root, nofollow/exclusive/ACL checks.
Metadata stored in existing replication.sqlite table admin_blobs, primary key(dataset,operation,host,store,hash), total/received/complete/pinned, contentHash.
Scope hash=H("LifeOS/admin-blob-scope/v20",scope); disk location admin-blobs/<scopeHash>/<blobHash>[.partial].
Files are data artifacts, not new source paths. Partial hash state may be recomputed on reopen; contiguous metadata is checked against actual bytes.

## Restore apply, retention and resume

RemoteRestoreApply20={context:RestoreApplyContext20,source:RemotePackSource20}; equality to admitted source is mandatory.
Gateway verify_admin_pack(source,admission) returns internal VerifiedAdminPack20 with pinned handles/read methods; not a caller-decodable trust object.
Node receives scope/source via signed LocalDispatch20, opens same protected root by deterministic mapping, independently validates bundle before mutation.
No arbitrary absolute path is sent through IPC. Gateway also readbacks owner marker and final state before signing DataCompletionProof19.
P01 `putAdministrativeBlob(_:endpoint:)` and `readAdministrativeBlob(_:endpoint:)`; P02 put_admin_blob/read_admin_blob/verify_admin_pack.
P18 `stageRemotePack(unit:verifiedArchive:admission:) async throws -> RemotePackSource20` must reproduce pre-admitted bytes exactly.
Prepare source hashes/descriptors locally before restore.open; staging subsequently uploads only these immutable declared bytes.
Retry resumes using server nextOffset via duplicate last chunk; absent completed chunks can be reuploaded identically while holding.
No automatic24h cleanup for any admitted/holding/settling/settled/releasing operation; pin every referenced segment through terminal release.
Released operation: cleanup may delete unreferenced bytes after signed release is durable; retain source descriptors/hashes in closed record.
Interrupted uploads without an admitted operation are impossible; rejected request temps may be removed only if unreferenced and owned.
Restart revalidates pins from active owner admission before collector startup/cleanup; metadata absence never authorizes deleting active payload.
At retention capacity refuse new admission; never prune active packs, closure records or unsent local source to make space.
Lost release response remains recoverable from closed record even if source blobs cleaned; no restore replay permitted after release.
Historical v19 source<=8MiB is not silently relabeled; read-only until explicit conversion from verified immutable archive to20 before any new effect.
Planned boundary vectors:0 files,4MiB ordinary,32MiB envelope,32MiB+1 bundle,536870929-byte bundle,17th-segment17 bytes; +1 rejected.
Check forbidden host/store, another member, hash collision attempt, traversal, crash at publication, rejoin after>7days and source-loss during apply.
