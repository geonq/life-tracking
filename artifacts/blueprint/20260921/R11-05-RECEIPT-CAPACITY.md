# R11 receipt capacity, progress and resumability

Planning-only. This sheet supersedes the incorrect R10 39/40-transition proof. It bounds receipts for many small
files and uses durable cursor checkpoints rather than one transition per chunk.

## Fixed archive/work bounds

The archive has `maxPacks=26`, `maxFilesPerPack=4,096`, `maxFiles=106,496`, `maxDataBytes=268,435,456`
(256 MiB), ordinary file <=4 MiB, domain envelope <=32 MiB, and chunk size exactly 1 MiB except a final
1...1 MiB chunk. Empty files have zero chunks. Because every nonempty file contributes at most one final partial
chunk and all full chunks consume the 256 MiB data budget:

`maxChunks <= maxFiles + ceil(maxDataBytes/1MiB) = 106,496 + 256 = 106,752`.

The bounded work-unit stream has one unit per file footer and one per chunk footer, so
`maxWorkUnits <= 106,496 + 106,752 = 213,248`. A checkpoint is emitted after every 8,192 units and at each
pack boundary; duplicate cursor checkpoints are coalesced. Thus work checkpoints are at most
`ceil(213,248/8,192)=27`, pack checkpoints at most 26, and at most 53 checkpoint records are needed.

## Exact receipt policy

```swift
public enum LifeOSReceiptCapacityV6 {
 public static let maxWorkUnits: UInt64 = 213_248; public static let checkpointStride: UInt64 = 8_192
 public static let maxWorkCheckpoints: UInt16 = 27; public static let maxPackCheckpoints: UInt16 = 26
 public static let maxCheckpointsPerAttempt: UInt16 = 53; public static let maxLifecycleRecords: UInt16 = 5
 public static let maxFailureMarkers: UInt16 = 1; public static let maxActiveRecords: UInt16 = 64
 public static let maxLogRecords: UInt16 = 256
}
```

Lifecycle records are `prepared, streaming, finalizing, bound, committed`; a single `interrupted` or `failed`
marker may be appended per attempt. Checkpoints are same-state `streaming` progress and do not invent states.
The active attempt maximum is `53 + 5 + 1 = 59`, below the hard 64-record limit. Completed prior attempts are
compacted before a new attempt; total log records are capped at 256.

## Compaction and resume

`LifeOSReceiptStoreV6.compact` writes one anchor containing the latest verified cursor, source manifest hash,
transition hash and attempt, fsyncs the replacement, then prunes only transitions/checkpoints strictly covered
by that anchor. The current anchor and every record after it remain. If pruning would remove the only verified
cursor, it returns `historyCapacity` without mutation. Resume scans the manifest from the anchor cursor, hashes
already durable chunks, and rewrites only missing/mismatched chunks; it never needs a pruned transition.

The cursor is `(packIndex,fileIndex,chunkIndex,completedUnits,currentUnit)` and advances monotonically. A file
footer increments one unit after its chunk hashes and footer are fsynced; the next file begins at the next cursor.
Pack-boundary checkpoints are emitted after the last file footer. A crash before a checkpoint may repeat up to
8,191 work units, but cannot exceed the archive cap or create duplicate logical records. A crash during log
replacement chooses the old or new complete file by hash. Disk-full/cancellation preserves the last renamed log;
success is returned only after `committed` is durable.

P18 owns constants, checkpoint scheduling, compaction and resume; R11-04 owns finalization. The acceptance proof
must construct 106,496 empty files plus 256 MiB data spread across them, and must show bounded records,
deterministic resume and no schema-valid cursor outside the declared maxima.
