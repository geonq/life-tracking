# Revision5 archive bound correction
The R4 archive allowed 30,000 acknowledgements while the canonical scanner allowed only 10,000 array members.
Revision5 selects one bound: `SyncArchiveLimits.maximumAcknowledgements = 10_000`.

Swift, Python and TypeScript archive decoders must reject `acknowledgements.count > 10_000` before element allocation;
the same limit applies to `DomainArchive`, `RecoveryArchive`, `SyncAdapterEnvelope.acknowledgements`, and every
archive import result. `WireScanner.array` retains its global maximum of10,000. No valid archive can therefore be
undecodable because of ACK count. The existing per-value limits remain the stricter limit for nested arrays.

`makeArchive` counts entities, ACKs, blobs, canonical JSON bytes and decoded blob bytes before signing. If the ACK
limit or 32MiB total cap would be exceeded, it throws `capacity` and leaves the source frontier/pending state unchanged.
There is no automatic chunking in v1: a future chunked archive would require a new root tag/version. Checkpoint
coverage must be compacted/pruned only after signed receipt coverage, never by silently dropping ACKs.

The bound is propagated to `SyncArchiveLimits` in Swift, `SYNC_ARCHIVE_MAX_ACKS = 10_000` in Python and
`const SYNC_ARCHIVE_MAX_ACKS = 10_000` in TypeScript. Canonical rejection examples include 10,001 ACK objects,
an ACK array over the bound nested in a recovery archive, and an otherwise valid archive whose JSON is over32MiB.
Execution evidence must decode exactly10,000 and reject10,001 in all three implementations.

## Revision6 supersession
R6-03 applies this same 10,000 bound to each JSON ledger and the Planning SQL envelope reconstruction. R6 does not
introduce a larger Planning or recovery ACK limit.
