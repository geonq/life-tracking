# R10 Planning SQLite authority and publication fence

Planning-only. R10 supersedes Planning persistence clauses in R7-03, R3-02 and R7-05. The
authoritative Planning replication envelope and publication state live in SQLite; JSON is never
allowed to replace that state.

## Files, versions and authority

|Path|Role|Authority|
|---|---|---|
|`Application Support/LifeOS/Planning/<vaultID>/journal.sqlite`|canonical envelope, operations and publication rows|sole authority|
|`journal.sqlite-wal`, `journal.sqlite-shm`|SQLite-managed transaction files|SQLite only; never copied separately|
|`publication-journal.json`|bounded derived file-recovery hint|rebuildable; never authoritative|
|`publication-staging/<publicationID>.tmp`|exclusive staged bytes|transient, hash checked|
|`publication-backup/<publicationID>/<relativePath>`|pre-replace file backup|recovery evidence until finalized|
|`journal.sqlite.r10.<backupID>.backup`|verified pre-migration SQLite backup|rollback evidence|

`sync_meta(store_id='planning')` contains the complete `SyncAdapterEnvelopeV2` bytes, its SHA-256,
generation and updated timestamp. `planning_publications` is the authoritative file-projection
journal. `publication-journal.json` contains the same rows plus `sqliteRowHash`; a mismatch causes
rebuild from SQLite, never a merge or JSON-to-SQLite overwrite. Its rows are capped at 4096; older
finalized rows are omitted because SQL remains the complete history. All nonterminal rows must fit;
otherwise `capacity` is returned before the next mutation.

## SQLite schema and migration

`PRAGMA journal_mode=WAL; synchronous=FULL; foreign_keys=ON; busy_timeout=1000; user_version=4`.
The v4 tables are `sync_meta(store_id TEXT PRIMARY KEY, envelope BLOB NOT NULL, envelope_hash
BLOB NOT NULL, generation INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL)`,
`sync_operations(mutation_id BLOB PRIMARY KEY, operation_hash BLOB NOT NULL, encoded BLOB NOT NULL,
state TEXT NOT NULL, sequence_sort BLOB NOT NULL, receipt_id BLOB, UNIQUE(operation_hash))`,
`sync_receipts(receipt_id BLOB PRIMARY KEY, encoded BLOB NOT NULL, transition_hash BLOB NOT NULL)`,
`planning_publications(publication_id BLOB PRIMARY KEY, mutation_id BLOB NOT NULL, relative_path
TEXT NOT NULL, temp_relative_path TEXT NOT NULL, target_hash BLOB NOT NULL, encoded_bytes BLOB NOT NULL,
old_hash BLOB,
phase TEXT NOT NULL, sqlite_row_hash BLOB NOT NULL, generation INTEGER NOT NULL, attempt INTEGER
NOT NULL, last_error TEXT, updated_at_ms INTEGER NOT NULL)`, and `planning_migration_fence(migration_id BLOB
PRIMARY KEY, from_version INTEGER NOT NULL, to_version INTEGER NOT NULL, backup_path TEXT NOT NULL,
phase TEXT NOT NULL, old_hash BLOB NOT NULL, new_hash BLOB, updated_at_ms INTEGER NOT NULL)`.
Migration-fence phase is closed to `prepared|committed`; publication phase is the V4 enum below.

`R10-01` migration from `user_version=3` is one fenced operation:

`migrateToV4` is idempotent: version 4 only revalidates the envelope/row hashes; versions other than
3 or 4 return `unsupportedSchema` before opening a write transaction.

1. `PlanningMutationJournal` actor acquires `.journal.lock`, stops new writes, validates the old
   envelope and all SQL rows, then uses SQLite backup API to write `journal.sqlite.r10.<id>.partial`.
2. It fsyncs the partial backup, atomically renames it to `.backup`, fsyncs the directory, and only
   then starts `BEGIN EXCLUSIVE` on the live database.
3. Inside that transaction it creates the v4 tables/indexes, copies the old canonical envelope,
   derives bounded SQL rows, inserts a `prepared` migration fence, sets `user_version=4`, validates
   hashes/counts, changes the fence to `committed`, and commits.
4. It releases the lock after reopening the database and comparing the stored envelope hash. A crash
   before COMMIT leaves v3; a crash after COMMIT leaves v4. The backup is retained until the next
   verified backup. No `VACUUM`, JSON replacement or WAL-file copying is part of migration.

For a legacy publication row, migration reads the target or verified temp bytes under the vault root,
checks the stored hash and 32 MiB bound, and stores those bytes in `encoded_bytes`. If bytes are absent
or mismatched it stores an empty bounded value, `phase=blocked` and `last_error=legacyBytesUnavailable`;
it never upgrades that row to `finalized`.

## Runtime commit and file-journal order

```swift
public struct PlanningCommitInputV4: Codable, Sendable {
 public let mutationID: UUID; public let expectedGeneration: UInt64
 public let expectedEnvelopeHash: String; public let relativePath: String
 public let bytes: Data; public let intentID: UUID
}
public struct PlanningCommitReceiptV4: Codable, Sendable {
 public let mutationID: UUID; public let publicationID: UUID; public let generation: UInt64
 public let envelopeHash: String; public let phase: PlanningPublicationPhaseV4
}
public enum PlanningPublicationPhaseV4: String, Codable, Sendable {
 case planned, staged, renamed, finalized, blocked
}
public struct PlanningPublicationRowV4: Codable, Sendable {
 public let publicationID: UUID; public let mutationID: UUID; public let relativePath: String
 public let tempRelativePath: String; public let targetHash: String; public let oldHash: String?
 public let phase: PlanningPublicationPhaseV4; public let sqliteRowHash: String
 public let generation: UInt64; public let attempt: UInt16; public let lastError: String?
}
public struct PlanningFileJournalV4: Codable, Sendable {
 public let schemaVersion: Int; public let sqliteEnvelopeHash: String
 public let rows: [PlanningPublicationRowV4]
}
public enum PlanningSQLiteErrorV4: Error, Sendable {
 case unsupportedSchema, staleGeneration, staleEnvelope, corruptJournal, blockedPublication
 case diskFull, cancelled, invalidPath, capacity, legacyBytesUnavailable
}
public actor PlanningMutationJournal {
 public func migrateToV4(migrationID: UUID) throws
 public func applyLocal(_ input: PlanningCommitInputV4) throws -> PlanningCommitReceiptV4
 public func loadPublicationBytes(_ publicationID: UUID) throws -> Data
 public func markPublication(_ publicationID: UUID, phase: PlanningPublicationPhaseV4,
   expectedRowHash: String) throws -> PlanningCommitReceiptV4
 public func recoverPublicationFence() throws -> [PlanningCommitReceiptV4]
}
public actor PlanningFilesystemPublication {
 public func stage(_ row: PlanningPublicationRowV4, bytes: Data) throws
 public func renameStaged(_ publicationID: UUID) throws
 public func finalize(_ publicationID: UUID) throws
}
```

`applyLocal` validates a relative path and `bytes <=32 MiB`, opens `BEGIN IMMEDIATE`, reloads generation and envelope
hash, deduplicates `intentID`, allocates mutation/sequence, updates `sync_meta`, inserts the
operation/receipt and a `planned` publication row, then commits. It then atomically writes the
derived file journal, writes the exclusive staging file, fsyncs file and directory, and calls
`stage` with the bytes from the input (or `loadPublicationBytes` during recovery). P06 calls P05's
`markPublication` after each verified filesystem phase;
before `renameStaged`, P06 copies an existing target to `publication-backup/<publicationID>/<relativePath>`
with no-follow/exclusive semantics, fsyncs the backup and directory, then uses same-volume rename plus
directory fsync; `finalize` marks the SQL row
`finalized` in a new transaction and rewrites the derived file journal. Only the SQL commit makes
the mutation real; the projected file is retried from its row.

## Recovery, cancellation and disk-full behavior

Recovery reads SQL rows in `(publicationID, relativePath)` byte order. `planned` restages; `staged`
verifies the temp hash then renames; `renamed` verifies the target hash then finalizes; `finalized`
is ignored. Missing or mismatched bytes are moved to `publication-backup/<id>/quarantine` and the
row becomes `blocked`; authoritative SQL data is never discarded. The JSON hint is rebuilt from
all nonterminal SQL rows before any retry. Cancellation before the SQLite COMMIT writes nothing;
after COMMIT it returns the durable receipt and recovery continues. Disk-full preserves the old
target and SQL envelope, records `diskFull`, and leaves the staged row retryable.

Every multi-file restore/backup uses the same order: acquire writer fence, backup SQLite first,
write the derived file journal second, process relative paths sorted by UTF-8 bytes, fsync each
file/directory, then finalize SQL. Rollback restores only from a verified backup after a fence;
partial JSON or temp files cannot select a different authority.

## Function ownership and acceptance evidence

P05 owns every symbol above and the `journal.sqlite` actor. P06 owns only staging/rename/fsync
operations and may not mutate `sync_meta`. A Luna implementation is accepted when a forced crash at
each listed phase reopens the same envelope hash, resumes the exact publication row, rejects a
stale generation, and never reports a projected file as durable before its SQL phase is finalized.

## R11 supersession

R10-01 remains the base SQLite authority and publication schema. R11-01 is final for alias migration: it adds
`planning_alias_fence`, the `prepareAliasFence/commitAliasFence/recoverAliasFence` calls, trust-last path order,
and coordinated JSON/SQL crash recovery. No JSON hint or database replacement may override the R11 fence.
