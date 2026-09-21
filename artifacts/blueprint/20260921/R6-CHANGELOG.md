# Revision6 changelog — final contract correction
Planning-only; no source/build/test/xcodegen/commit/push action.

1. Closed the replication enum: Usage is local-only and Clipper is read-only gateway data. Their leaf rows now point to
   existing local/read-only owners and cannot invent payloads, archives, adapters, ACKs or tombstones.
2. Sealed manual travel and user-data management with bounded Codable values, an explicit registry, atomic receipts,
   crash/interruption recovery, protected/raw-data rules and release evidence.
3. Reconciled inbox persistence with the real Planning design: JSON domains embed one ledger; Planning uses the existing
   `journal.sqlite` schema-v3 `sync_operations`, `sync_receipts` and `sync_meta` envelope, with no second database or
   invented `sync_frontiers` table.
4. Assigned RecoveryArchive to `LifeOS/recovery-archive/v2`, added canonical bytes, epoch records, immutable source-key
   lookup, eight-epoch overflow and exact rotation/reseed custody behavior.
5. Made recovery imports receipt-first and resumable, including every crash point, duplicate retry, disk-full and partial
   projection behavior.
6. Replaced Calendar's optional commit with one receipt/generation/intent-ID signature and separated viewport pinch,
   paging and scroll from item drag/resize, including the corrected focal-point formula.
7. Added a signature index and leaf audit for every R5-introduced name, including storage audit, compaction, readback,
recovery, Planning and data-management APIs. R6 is still a blueprint; source correctness requires later evidence.

## Revision7 supersession

R7-CHANGELOG records the next correction pass. R6 remains preserved history; current readiness is R7-READINESS.
