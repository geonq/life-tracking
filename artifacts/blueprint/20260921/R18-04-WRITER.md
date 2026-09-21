# R18-04 — one V8 writer and recovery boundary

> R19-07-DISPATCH.md supersedes the six topics under review; use R19 active-schema and capacity rules. This R18 sheet is retained only where expressly compatible.

Supersedes R16 writer variants and R17-04 RecoverySink protocol and normal-write pseudo-call boundary.
Retains R17-03 exact frame bytes/limits/footer and R17-04 exhaustive recovery decisions, amended below.
P01 owns public frame/plan/position values in SyncContract.swift and pure codecs in SyncWireCodec.swift.
P18 owns concrete sink+writer in ios/Shared/LifeOSDataArchiveWriter.swift and receipt CAS in LifeOSReceiptCoordinator.swift.

## Exact public types and interface

```swift
public struct LifeOSSinkPositionV8: Equatable, Sendable {
 public let nextOrdinal: UInt64
 public let endOffset: UInt64
 public let lastFrameHash: String?
}
public struct LifeOSDurableFrameV8: Sendable {
 public let previous: LifeOSSinkPositionV8
 public let current: LifeOSSinkPositionV8
 public let frameHash: String
 public let encodedByteCount: UInt32
 // internal initializer; only verified sink can construct, never Codable
}
public protocol LifeOSArchiveSinkV8: AnyObject {
 func read(at offset: UInt64, count: Int) throws -> Data
 func length() throws -> UInt64
 func sync() throws
 func truncate(to offset: UInt64) throws
 func syncParent() throws
 func append(_ frame: LifeOSArchiveFrameV8,
             expected: LifeOSSinkPositionV8) throws -> LifeOSDurableFrameV8
 func finalize() throws -> LifeOSFinalizedArchiveV8
}
// Concrete final class in P18 file; only coordinator actor owns its instance.
final class LifeOSFileArchiveSinkV8: LifeOSArchiveSinkV8 { /* implementation per order below */ }
```
`LifeOSRecoverySinkV8` is retired, not a competing conformance; replace every parameter with `any LifeOSArchiveSinkV8`.
Keep ONE `reconcileSinkAhead(receiptID:expectedHeadHash:sink:plan:)` from R17-04 with that substitution; no overload.
Concrete init is `init(partialURL:URL,finalURL:URL,plan:any LifeOSPlanReaderV8) throws` under coordinator lock.
It opens nofollow/exclusive writer, pins file+parent identities and exact validated owned paths; init does not overwrite or truncate existing bytes.
Sink is deliberately not Sendable; coordinator actor owns/reuses it synchronously, with interprocess advisory lock for full session.
No await occurs within sink method, authority replacement or positional write; no detached tasks receive the descriptor.
Reconciliation initializes sink's private VerifiedSinkState only after full successful plan scan/durability; no public setter from caller guesses.

## Frame identity

LifeOSArchiveFrameV8 retains exact fields archiveID:UUID,planHash:H,frameOrdinal:U64,frameKind:UInt8,payload:Data,frameHash:H.
payload is the COMPLETE inner record from R17-03; encoded bytes are its LOS8 wrapper, never JSON/base64 encoding.
`encodeArchiveFrameV8(_ frame) throws -> Data` validates plan identity, inner mapping, caps and recomputed frameHash before writing.
frameHash equals lowercase hex of the trailing32 digest bytes, not a hash of a Swift object's memory or full wrapper again.
Maximum encoded bytes1114213, ordinal0...426373; expected/current addition uses checked UInt64 and off_t range validation.
Expected.lastFrameHash null iff ordinal0; at0 offset0. For later ordinals compare all three fields to verified sink state.
Expected offset MUST equal actual file length before append. Unexpected extra bytes→sinkNeedsRecovery, no new write.
Receipt and sink may differ after an interrupted commit; reconciliation owns that condition, append never adopts it silently.

## Append algorithm and errors

1. Require valid verified state, exact expected position, frame.ordinal=expected.nextOrdinal and matching archive/plan.
2. Get exact next plan frame from iterator, compare all encoded bytes; mismatch→sinkPlanMismatch before any write.
3. Encode bounded frame once; pwrite loop at expected.endOffset, handling EINTR; zero-progress write→archiveIOFailed.
4. Any short/error/ENOSPC/cancel after first byte invalidates verified state; retain partial bytes; throw typed error.
5. After all bytes: fsync descriptor; bounded pread loop of this frame; compare byte-for-byte and digest; mismatch→sinkHashMismatch.
6. Update private verified position/hash accumulator and return DurableFrame(previous,current,hash,byteCount).
No receipt advancement before step6; coordinator calls advanceEmission with current position and current expected receipt head.
Receipt commit failure invalidates sink state and requires reopen/reconcile; never append next frame speculatively.
A successful append is durable sink progress, not successful whole export. The receipt is authoritative for acknowledged progress.
On EINTR retry operation; on ENOSPC/EDQUOT diskFull; Task cancellation operationCancelled; all other I/O archiveIOFailed.
`LifeOSSinkErrorV8` adds sinkNeedsRecovery and sinkPositionConflict; position mismatch with otherwise aligned bytes uses latter.
Creation fsyncs parent before first receipt0 registration; existing file append needs file fsync, not parent fsync per frame.
truncate is recovery-only, followed by file+parent fsync; any failed fsync invalidates state, no durability proof returned.
If receipt commit succeeded but response was lost, R18-05 retry returns same stored result; do not append frame twice.

## Recovery, finalization and older interfaces

On reopen R17-04 full scan verifies all complete frames and records receipt boundary. Its exact invalid-tail rules remain binding.
Before adopting sink-ahead bytes fsync file; each adopted frame persists nextOrdinal=i+1,endOffset=end(i),lastFrameHash=hash(i).
Read bytes from pinned sink against exact plan iterator; invalidate sink state until entire reconciliation completes.
Crash mid-adoption reopens from durable receipt prefix; R18-05 handles lost response. Complete invalid suffix is never auto-truncated.
`LifeOSDataArchiveWriter.emitFinalized` alone emits final footer via append; sink.finalize writes ZERO frame bytes.
finalize requires verified nextOrdinal=plan.totalFrameCount and exact final footer; fsyncs, same-volume publish, fsync parent, verifies file identity.
An identical already-published final file is idempotent; a different existing final file fails sinkFinalArtifactMismatch without replacement.
Finalization return retains R16 fields; raw file hash includes LOS8 wrappers. Caller persists40→50→60 only under R18-01 validation.
Legacy V5/V6/V7 sink interfaces become READ-ONLY format verifiers or private adapters that produce V8 frames before this boundary.
No older append/write method may remain an execution path for new exports. Migration legacy reader writes only through V8 sink.
If a legacy signature is referenced, update caller under its owning packet; never add a second authoritative writer.
Normal append O(frame bytes), memory one frame within8MiB pipeline budget; reopen O(total bytes+frames), no per-frame zero-based rescans.
Receipt whole-file transaction cost remains separately bounded and must be measured, not advertised as constant-time persistence.

## Planned verification

P01 SyncProtocolTests: maximum frame bytes, metadata/inner bounds, forged hash, ordinal/offset overflow and kind mismatch.
P18 CompletionFlowsTests: short writes/EINTR/disk-full at every boundary, successful fsync before proof, no proof after readback mismatch.
Crash after frame sync before receipt CAS; reopen/adopt then resume; no duplicate footer or second writer path.
Final existing same/different bytes, partial tail truncation, complete invalid tail preservation, two-process lock and cancellation.
Source audit at execution verifies no legacy writer calls remain and no full scan occurs inside normal append loop.
