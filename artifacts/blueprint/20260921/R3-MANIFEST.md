# Revision3 changelog and exact deliverable manifest
Date2026-09-21. Planning-only; source baseline321a2b50232cd0e26a975107921b2b4e7498ee0f unchanged.
Strict verdict: NOT READY FOR LUNA. See [per-packet blockers](R3-READINESS.md).

## Corrections and additions
- Added30 Swift Codable/Sendable + Python/TypeScript shape sheets, per-field rules and canonical/invalid structural examples.
- Defined required-null encoding, strict decode, framed signing bytes, exact HTTP routes/limits/public errors and replay policy.
- Separated shared logical store from origin stream; froze ACK identity/hash and contiguous frontier rules.
- Recorded atomic local outbox/inbox order, server transaction policy, retries/cancellation/disk-full and no-loss retention.
- Mapped current JSON/revision/pending wrappers; preserved legacy attempted-finance identities and rollback limits.
- Inspected actual Calendar validation and Planning journal commit/publication seams; corrected nonexistent mutation-type assumption.
- Added complete product family coverage,18 iOS/17 Mac widget registrations,22 security finding groups and258 historical leaves.
- Preserved historical statuses; generic advisor/coaching remains removed, photo calories only AI, NextSemis optional.
- Explicitly retained unresolved exact domain DTO/archive, codec/key bridge and feature-function review gates; no false READY.
Previous revision index copied byte-for-byte to00-INDEX-V2.md. Revision2 manifest28 remains historical, not current counts.

## Verification scope
Documentation checks only: all blueprint files<=200 lines; relative links; schema examples parse as JSON;
all258 expanded registry leaves unique; all30 schema sheets contain Swift/Python/TypeScript + two JSON examples.
Original01–15 byte-identical to321a2b5.482 non-blueprint tracked/untracked file hashes unchanged, no new outside files.
Eight existing D1 candidates untouched; no build/test/xcodegen/source edit/deletion/commit/push.
Structural examples are not cryptographic golden vectors; no application/security/runtime proof claimed.
No callable Astra Medium worker available: this revision is controller work, independent CP-A sign-off pending.
New user design decisions introduced:0. Five previously documented execution-dependent U categories remain in22.

## Exact files written or updated
|File|Lines|Action|
|---|---:|---|
|[00-INDEX-V2.md](00-INDEX-V2.md)|45|added|
|[00-INDEX.md](00-INDEX.md)|25|updated|
|[R3-00-CONTRACT-RULES.md](R3-00-CONTRACT-RULES.md)|56|added|
|[R3-01-HTTP.md](R3-01-HTTP.md)|56|added|
|[R3-02-TRANSACTIONS.md](R3-02-TRANSACTIONS.md)|60|added|
|[R3-03-MIGRATION-MAP.md](R3-03-MIGRATION-MAP.md)|60|added|
|[R3-04-STORE-SEAMS.md](R3-04-STORE-SEAMS.md)|53|added|
|[R3-05-VALIDATION-PRECISION.md](R3-05-VALIDATION-PRECISION.md)|72|added|
|[R3-06-SOURCE-RECONCILIATION.md](R3-06-SOURCE-RECONCILIATION.md)|48|added|
|[R3-ENUMS.md](R3-ENUMS.md)|94|added|
|[R3-F00-COVERAGE-RULES.md](R3-F00-COVERAGE-RULES.md)|35|added|
|[R3-F01-PRODUCT-FINANCE.md](R3-F01-PRODUCT-FINANCE.md)|18|added|
|[R3-F02-FITNESS-USAGE.md](R3-F02-FITNESS-USAGE.md)|18|added|
|[R3-F03-PLATFORM.md](R3-F03-PLATFORM.md)|16|added|
|[R3-F04-WIDGETS.md](R3-F04-WIDGETS.md)|45|added|
|[R3-F05-SECURITY.md](R3-F05-SECURITY.md)|34|added|
|[R3-F06-REGISTRY-RECEIPT.md](R3-F06-REGISTRY-RECEIPT.md)|20|added|
|[R3-LEAVES-01.md](R3-LEAVES-01.md)|98|added|
|[R3-LEAVES-02.md](R3-LEAVES-02.md)|98|added|
|[R3-LEAVES-03.md](R3-LEAVES-03.md)|98|added|
|[R3-MANIFEST.md](R3-MANIFEST.md)|82|added|
|[R3-READINESS.md](R3-READINESS.md)|38|added|
|[R3-S01-SyncStream.md](R3-S01-SyncStream.md)|39|added|
|[R3-S02-SyncPosition.md](R3-S02-SyncPosition.md)|39|added|
|[R3-S03-SyncFrontier.md](R3-S03-SyncFrontier.md)|39|added|
|[R3-S04-SyncPayload.md](R3-S04-SyncPayload.md)|51|added|
|[R3-S05-SyncOperation.md](R3-S05-SyncOperation.md)|91|added|
|[R3-S06-SyncAck.md](R3-S06-SyncAck.md)|75|added|
|[R3-S07-SyncMember.md](R3-S07-SyncMember.md)|51|added|
|[R3-S08-SyncStoreDescriptor.md](R3-S08-SyncStoreDescriptor.md)|47|added|
|[R3-S09-SyncMembership.md](R3-S09-SyncMembership.md)|63|added|
|[R3-S10-SyncConflict.md](R3-S10-SyncConflict.md)|59|added|
|[R3-S11-SyncSignedFrame.md](R3-S11-SyncSignedFrame.md)|87|added|
|[R3-S12-SyncChallengeRequest.md](R3-S12-SyncChallengeRequest.md)|43|added|
|[R3-S13-SyncChallenge.md](R3-S13-SyncChallenge.md)|43|added|
|[R3-S14-SyncHelloRequest.md](R3-S14-SyncHelloRequest.md)|39|added|
|[R3-S15-SyncHelloResponse.md](R3-S15-SyncHelloResponse.md)|47|added|
|[R3-S16-SyncExchangeRequest.md](R3-S16-SyncExchangeRequest.md)|59|added|
|[R3-S17-SyncOperationResult.md](R3-S17-SyncOperationResult.md)|43|added|
|[R3-S18-SyncExchangeResponse.md](R3-S18-SyncExchangeResponse.md)|59|added|
|[R3-S19-SyncError.md](R3-S19-SyncError.md)|47|added|
|[R3-S20-SyncOutboxEntry.md](R3-S20-SyncOutboxEntry.md)|55|added|
|[R3-S21-SyncAdapterEnvelope.md](R3-S21-SyncAdapterEnvelope.md)|83|added|
|[R3-S22-SyncCheckpoint.md](R3-S22-SyncCheckpoint.md)|71|added|
|[R3-S23-BlobChunk.md](R3-S23-BlobChunk.md)|51|added|
|[R3-S24-BlobRead.md](R3-S24-BlobRead.md)|43|added|
|[R3-S25-BlobResult.md](R3-S25-BlobResult.md)|47|added|
|[R3-S26-SyncEntityVersion.md](R3-S26-SyncEntityVersion.md)|43|added|
|[R3-S27-SyncCheckpointReceipt.md](R3-S27-SyncCheckpointReceipt.md)|47|added|
|[R3-S28-SyncCommitReceipt.md](R3-S28-SyncCommitReceipt.md)|47|added|
|[R3-S29-SyncPublicError.md](R3-S29-SyncPublicError.md)|30|added|
|[R3-S30-SyncHealth.md](R3-S30-SyncHealth.md)|30|added|

Revision deliverables:52 files; 51 added,1 updated. Individual maximum200 lines.
