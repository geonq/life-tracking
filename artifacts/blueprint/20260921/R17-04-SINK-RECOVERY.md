# R17-04 — one sink recovery API and bounded verification

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Replaces all R16-02 APIs, tail summaries, error mappings and recovery instructions.
Uses R17-01 next-ordinal/offset/hash cursor and R17-03 wrapper. Recovery runs under P18 single writer lock.

## Exact interfaces

`LifeOSSinkErrorV8: String` cases: sinkMalformed,sinkPlanMismatch,sinkHashMismatch,sinkReceiptAhead,
sinkFinalArtifactMismatch,receiptIdentityConflict,unsupportedArchiveVersion,diskFull,operationCancelled,archiveIOFailed,capacity.
Decode/length/order errors map sinkMalformed, digest mismatch sinkHashMismatch, valid-but-different planned bytes sinkPlanMismatch.
ENOSPC/EDQUOT→diskFull, cancellation→operationCancelled, other filesystem errors→archiveIOFailed.
No error asserts that an interrupted write left bytes untouched. Recovery classifies the actual prefix on next open.

```swift
protocol LifeOSPlanReaderV8: Sendable {
  var archiveID: UUID { get }; var planHash: String { get }; var totalFrameCount: UInt64 { get }
  func openFrames(from ordinal: UInt64) throws -> any LifeOSPlannedFrameIteratorV8
}
protocol LifeOSPlannedFrameIteratorV8 {
  mutating func next() throws -> LifeOSArchiveFrameV8? // exact R17-03 bytes, monotonic
}
protocol LifeOSRecoverySinkV8 {
  func read(at offset: UInt64, count: Int) throws -> Data // bounded positional read
  func length() throws -> UInt64
  func sync() throws
  func truncate(to offset: UInt64) throws
  func syncParent() throws
  func finalize() throws -> LifeOSFinalizedArchiveV8 // never appends footer
}
// Sole public reconciliation method; no tail-only or overloaded alternative.
func reconcileSinkAhead(receiptID: UUID, expectedHeadHash: String,
                        sink: any LifeOSRecoverySinkV8,
                        plan: any LifeOSPlanReaderV8) throws -> LifeOSSinkRecoveryResultV8
```

FrameV8 retains R16 `archiveID,planHash,frameOrdinal,frameKind,payload,frameHash`; payload=complete inner bytes.
ResultV8 = `{adoptedCount:U64,truncatedBytes:U64,nextOrdinal:U64,endOffset:U64,lastFrameHash:H?,finalArtifact:FinalizedArchiveV8?}`.
R16 finalized object fields retained. No success result before all required fsync/receipt commits.
P18 method opens current receipt internally; verifies CAS and PreRecord against plan, never trusts a caller-supplied log/tail.
P01 owns pure frame/plan validation; P18 sink handle opened nofollow, regular-file identity pinned, exclusive lock.
Plan iterator has access only to validated immutable staged/source bytes; it cannot mutate stores or receipt.

## Reopen scan and exhaustive branches

One full scan from byte0 streams actual frames alongside plan. Read each bounded header then declared body/digest.
Maintain ordinal, offset, incremental raw SHA256, verified footer, receipt-boundary match; never allocate archive-size index.
Scan records can be valid, incomplete-at-EOF, malformed, or digest-invalid; scanner returns classification+offset, not unconditional throw.
Compare ALL complete valid frames byte-for-byte with plan; computed hash is not a substitute for the comparison.
Let C=receipt nextOrdinal; B=verified prefix frame count; offset/hash at C must equal persisted receipt proof.
Apply rows in this order; a blocking row suppresses every mutation:

|condition|decision|
|---|---|
|receipt no emission cursor / wrong plan|phaseMismatch / sinkPlanMismatch; no sink mutation|
|complete malformed, hash-invalid, duplicate/skipped/out-of-order frame anywhere|sinkMalformed or sinkHashMismatch; retain bytes, never truncate|
|complete valid frame differs from plan, count exceeds plan, bytes after final footer|sinkPlanMismatch; retain bytes|
|scan EOF/incomplete before C, hence B<C|sinkReceiptAhead; never rewind receipt or truncate evidence|
|boundary C same ordinal but offset/hash disagree|receiptIdentityConflict; retain bytes|
|C=B, complete EOF and no footer|aligned; no receipt mutation|
|C<=B and incomplete final record after verified boundary|truncate ONLY that incomplete suffix to verified offset; fsync file and parent, then continue|
|B>C, verified planned frames|fsync file BEFORE adopting any frame, then adopt C...B-1 as below|
|B=total and valid final footer at total-1|after adoption, finalize without writing; return finalArtifact; do not yet commit receipt success|
|B<total with footer, or B=total without required footer|sinkPlanMismatch|
|final path already published before receipt finalize|same scan/verification; finalize is idempotent, then caller finalizes receipt|

An incomplete record means EOF before declared bytes/digest; impossible/over-limit header is malformed, not a truncatable suffix.
A complete invalid suffix is NEVER truncated. This explicit fail-closed rule supersedes R16's hash-invalid-suffix wording.
fsync makes currently readable valid frames durable; reading after crash alone does not establish durability.
If file/parent fsync fails, do not adopt. Tail truncation does not change C/hash; no fake progress transition is appended.

## Adoption and normal write algorithm

After full scan validates and sync succeeds, reopen plan iterator at C and stream sink a second time starting at saved receipt offset.
For each frame i compare exact bytes again; retain next offset/hash; call advanceEmission with nextOrdinal=i+1,
endOffset=end(i), durableFrameHash=hash(i), recoveryAction=sinkAheadAdopted and CURRENT receipt head.
Update expected head from each successful result. Do not reuse the original head across adoptions.
Crash between adopted frames resumes from the last persisted nextOrdinal. Exact duplicate retry is no-op, differing bytes conflict.
After final adoption, caller finalizeArtifact→bindArtifact→commitBound follows R17-01; footer presence alone is not completion.
Normal writes maintain in-memory VerifiedSinkState `{nextOrdinal,endOffset,lastHash,rawHashAccumulator}` initialized by open scan.
Build one planned frame, append at endOffset, file fsync, positional readback ONLY that frame, compare, then persist next cursor.
Advance VerifiedSinkState after receipt commit; on any ambiguous I/O/receipt result invalidate state and reopen/reconcile.
Never call a zero-based scan after every append. SHA accumulator adds each frame once; finalize uses accumulator and streaming semantic verification.
Reopen may require two sequential passes (validation+adoption) plus final hashing; all O(total bytes+frames), O(one-frame+iterator) working memory.
Within a process normal write is O(frame bytes); receipt replacement cost is separately bounded by R17-02 aggregate file cap.
User cancellation before next frame preserves progress; cancellation after append requires reopen, not attempted in-memory rollback.
