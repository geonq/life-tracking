# R17-03 — compatible archive bytes and exact bounds

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Replaces R16-02 framing bounds/finalize writer; amends R13-01 chunkIndex bound and R15-03 count limits.
Retains R10-05 inner data framing, R13-01 inner manifest framing, R14-02 object authority and R15-02 frame order.
P01 implements codecs. P18 implements sink/plan iteration. No third byte representation.

## One wrapper, unchanged inner bytes

Outer bytes = `ASCII(LOS8)[4] || UInt8(8) || UInt64BE(ordinal) || UInt8(kind) || UInt32BE(innerLength) || innerBytes || digest[32]`.
Header=18 bytes, overhead=50. digest=SHA256(F(`LifeOS/archive-frame/v8`, header||innerBytes)).
innerBytes is EXACTLY ONE complete encoded R10 data record OR R13 manifest carrier, including its inner magic/header/digest.
No JSON serialization of the inner byte buffer; no base64; no partial inner record or concatenated records.
Outer kind is R15 emission kind1..13. Data kinds1..6 map inner1..6; outer13→inner7;
outer7/8/9→manifest1/2/3 and outer10/11/12→manifest4/5/6. Reject mismatches before payload decode.
Data records:19-byte header+metadata<=65536+chunk payload<=1048576+32-byte digest → max1114163.
Other data records:payload<=131072 → max196659. Manifest carriers:20-byte header+path<=128+metadata<=8192+payload<=1048576+32 → max1056948.
Manifest header/footer payload<=65536 → max73908. Inner bounds are independently enforced.
Thus max outer innerLength=1114163; max complete outer record=1114213. No trailing bytes inside wrapper.
Lengths checked with overflow-safe addition before allocation. Queue holds at most ONE complete outer frame (1114213 bytes).
This supersedes the old 2-frame/2MiB combined queue rule; total pipeline workspace budget=8MiB excluding bounded receipt/work-plan storage.

## Boundary vectors (codec length layer)

|inner family|components (header,path,metadata,payload,digest)|inner / outer bytes|result|
|---|---|---|---|
|data chunk max|19,0,65536,1048576,32|1114163 /1114213|accept lengths|
|manifest chunk max|20,128,8192,1048576,32|1056948 /1056998|accept lengths|
|manifest control max|20,128,8192,65536,32|73908 /73958|accept lengths|
|data chunk payload+1|19,0,65536,1048577,32|1114164 /1114214|capacity|
|manifest path+1|20,129,8192,1048576,32|1056949 /1056999|capacity even though global wrapper fits|
|outer with innerLength=0|18 header +32 digest|50|sinkMalformed: no inner record|
|valid inner plus1 junk byte|valid inner+00|any permitted global length|sinkMalformed: trailing inner bytes|

Vectors specify length validation only; semantically invalid metadata at those lengths still fails canonical/schema checks.
Digest vector construction is exact: use encoded valid inner fixture B, ordinal0 and corresponding outer kind K;
header=`4c4f533808` +16 hex zeroes +two-hex K +8-hex BE byteCount(B);
expected digest=SHA256(`4c6966654f532f617263686976652d6672616d652f763800` || UInt32BE(18+len(B)) || header || B).
Use R15-03 exact 189/179/170-byte partition vectors as payload fixtures; inner/outer encoders must round-trip byte-for-byte.

## Partition and plan limits

R15 greedy maximal canonical payload partition remains authoritative. max chunk payload=1048576 INCLUDING JSON envelope.
A single item whose item+envelope exceeds this limit is carrierItemTooLarge, even if item alone fits.
Pack <=4096 items; at most4096 chunks, indexes0...4095 (replaces R13's0...255).
Archive index<=26 items/chunks; empty arrays emit one chunk as before. A canonical pack/index object<=268435456 bytes.
Stored object is streamed; counts and object hashes must verify before plan finalization. No array of whole encoded manifests.
Use cached item length and accumulating slice length; serialize each selected slice once: O(total canonical bytes + item count).
Plan iteration uses counts/prefix positions, not repeated scans of prior frames. ordinal max426373, totalFrameCount<=426374.
One immutable plan binds archiveID, packCount, dataFrameCount, manifestCarrierCount, manifestRootHash via R15 planHash.
Immutable staged sources must reproduce every frame at its ordinal; on changed source return sinkPlanMismatch, never re-plan an active receipt.

## Footer ownership and compatibility

`LifeOSDataArchiveWriter.emitFinalized` is the ONLY final footer writer: outer kind13 wrapping inner archiveFooter7,
exactly once at totalFrameCount-1. It appends/syncs/advances receipt exactly like any other frame.
`sink.finalize()` writes NO archive bytes. It verifies done cursor/footer, fsyncs file, atomically publishes final path,
fsyncs parent, reopens same identity and returns raw wrapped artifactFileHash/count plus semantic archive/root hashes.
Destination exists with identical verified bytes→idempotent return; different identity/bytes→sinkFinalArtifactMismatch.
Existing readers get a format-dispatch facade: LOS8→validate/unframe→existing inner verifier; LIFEOSAR→legacy inner verifier.
A detected LOS8 file is never offered directly to a legacy-only decoder; unsupported reader returns unsupportedArchiveVersion.
Never label wrapped bytes as legacy. Export representation tag is `lifeos.archive.wrapped.v8`; legacy representation remains unchanged.
Import supports both exact formats and computes file hash over original bytes, not unwrapped bytes.
Re-encoding a legacy archive is a distinct export with a new raw file hash; R17-02 active partial migration is the sole resumable conversion.
Semantic archiveHash/root definitions from R12-04/R14-02 are unchanged by outer wrapping.
