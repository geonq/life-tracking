# R11 alias migration and Planning SQLite fence

Planning-only. This sheet supersedes R9-04 and amends R10-01. It defines one migration fence for
`trust.json`, every JSON domain envelope, and the Planning `journal.sqlite`; WAL/SHM files are never
copied or independently replaced.

## Registry and exact values

```swift
public enum SyncAliasStorageV6: String, Codable, Sendable { case jsonEnvelope, planningSQLite }
public struct SyncAliasArtifactV6: Codable, Sendable {
 public let logicalKind: String; public let storage: SyncAliasStorageV6
 public let relativePath: String; public let companionPaths: [String]
 public let oldSHA256: String; public let stagedSHA256: String
 public let oldByteCount: UInt64; public let stagedByteCount: UInt64
}
public struct SyncAliasMigrationInputV6: Codable, Sendable {
 public let migrationID: UUID; public let datasetID: UUID; public let oldEncoding: String
 public let newEncoding: String; public let oldAliasHash: String; public let newAliasHash: String
 public let artifacts: [SyncAliasArtifactV6]
}
public enum SyncAliasPhaseV6: String, Codable, Sendable {
 case prepared, validatedOld, staged, verified, planningPrepared, fenced, committing
 case committed, interrupted, rejected, rolledBack, blocked
}
public struct SyncAliasMigrationJournalV6: Codable, Sendable {
 public let schemaVersion: Int; public let input: SyncAliasMigrationInputV6
 public let fenceID: UUID; public let completedPaths: [String]; public let phase: SyncAliasPhaseV6
 public let commitCursor: UInt32; public let backupRelativePath: String
 public let createdAt: Int64; public let updatedAt: Int64; public let errorCode: String?
 public let transitionHash: String
}
public struct SyncAliasMigrationFenceV6: Codable, Sendable {
 public let migrationID: UUID; public let oldAliasHash: String; public let newAliasHash: String
 public let expectedArtifacts: [String]; public let commitCursor: UInt32; public let signature: String
}
```

`artifacts` contains exactly one row for each of the 17 logical stores plus `trust`; the Planning row is
`logicalKind="planning"`, `storage=.planningSQLite`, `relativePath="Planning/<vaultID>/journal.sqlite"` and
`companionPaths=[]`. Its `oldByteCount/stagedByteCount` are the SQLite main-file sizes; WAL and SHM are
SQLite-managed and excluded. Paths are NFC relative UTF-8, unique, and sorted by raw UTF-8 bytes. Hashes
are lower-case SHA-256 hex. A staged envelope is <=32 MiB; all lists are <=18 entries.

## Planning SQLite bridge

The existing `PlanningMutationJournal` actor adds these exact methods; it remains the only SQL authority:

```swift
public struct SyncPlanningAliasInputV6: Sendable {
 public let migrationID: UUID; public let oldAliasHash: String; public let newAliasHash: String
 public let oldEnvelopeHash: String; public let stagedEnvelope: Data; public let backupRelativePath: String
}
public enum SyncPlanningAliasResultV6: Sendable { case old, new, blocked(String) }
public extension PlanningMutationJournal {
 func prepareAliasFence(_ input: SyncPlanningAliasInputV6) throws -> String
 func commitAliasFence(_ migrationID: UUID, expectedOldEnvelopeHash: String) throws -> String
 func recoverAliasFence(_ migrationID: UUID) throws -> SyncPlanningAliasResultV6
}
```

`journal.sqlite` adds `planning_alias_fence(migration_id TEXT PRIMARY KEY, phase TEXT, old_alias_hash
TEXT, new_alias_hash TEXT, old_envelope_hash TEXT, staged_envelope BLOB, staged_envelope_hash TEXT,
backup_relative_path TEXT, cursor INTEGER, updated_at_ms INTEGER)`. The blob is bounded to 32 MiB and
is not a second envelope authority: it is a resumable candidate owned by the migration row.

## One path order and commit phases

1. `SyncTrustStore.beginAliasMigration` takes the writer lock, validates the closed 18-row registry, and
   writes `prepared`; `validateOld` hashes every live JSON path and `sync_meta.envelope`, writes `validatedOld`.
2. `stageAliasMigration` writes exclusive/no-follow JSON temps and the signed new trust table, fsyncs every
   candidate, and writes `staged`. It then calls `prepareAliasFence` for Planning: SQLite backup API writes
   `backupRelativePath`, fsyncs it and its directory, then `BEGIN IMMEDIATE` verifies `sync_meta`'s old hash,
   inserts the candidate row, and commits; the journal advances to `planningPrepared` only after that commit.
3. `verifyStaged` decodes all candidates and preserves operation bytes, IDs, heads, frontiers, inbox,
   outbox, ACKs, conflicts and UUIDs. It writes `verified`; `fenceAliasMigration` fsyncs the signed V6
   fence and writes `fenced`. Readers serve the old set for all fenced phases.
4. Before the first live replacement, `commitAliasMigration` copies every old JSON path to the journal's
   exclusive/no-follow backup directory, fsyncs each file and directory, and records its hash. The Planning
   SQLite backup was already completed by `prepareAliasFence`; its WAL/SHM are never copied.
5. The sole order is ascending `relativePath` UTF-8, with `trust.json` forced last. JSON rows use atomic
   same-volume replace plus directory fsync. At the Planning row, `commitAliasFence` runs `BEGIN IMMEDIATE`,
   rechecks the old envelope hash, updates the SQL fence row to `committing`, replaces `sync_meta.envelope`
   and its hash, updates the row to `committed` with the new cursor, and commits; no SQLite file rename occurs.
   The migration journal advances only after that commit.
6. After every row is new and hashed, trust is replaced last. `commitAliasMigration` writes `committed`,
   and readers switch to new only after one complete validation. Cancellation/disk-full records
   `interrupted` and leaves the last cursor retryable.

## Recovery and compatibility

Before sync, `recoverAliasMigration` hashes the live set. For pre-fence phases it deletes only staging and
marks `rolledBack`. For `fenced|committing`, old rows are restored from verified backups; the Planning row
uses `recoverAliasFence`: old hash re-applies the candidate transaction, new hash marks it complete, and
neither hash is `blocked` without selecting a mixed view. A committed fence is retained through two clean
startup validations, then its backup is pruned. Missing backup, hash mismatch, corrupt SQLite or disk-full
returns typed `aliasRecoveryBlocked|diskFull` and never exposes partial aliases.

Legacy R3 UUID store IDs remain in signed bytes. `SyncStoreIDResolver` verifies old bytes before aliasing;
the V6 journal records both encodings. V1 transport carries the UUID, V2 may carry the new raw value plus
`newAliasHash`; an alias change during a stream is rejected before inbox persistence. No operation, sequence,
receipt, checkpoint or frontier is re-signed or rewritten.

P01 owns value/hash/fence types and `SyncTrustStore`; P05 owns the Planning SQL fence port; P06 owns file staging,
backup, replace and fsync. Acceptance requires forced crashes before/after the Planning SQL commit and each
JSON cursor: restart yields either the verified old or verified new complete set, never a mixed set.

## R12 supersession

R12-01 corrects ownership: P01 owns `SyncTrustStore.swift`, P05 owns only the injected Planning SQL port, and
P06 owns filesystem bytes. R12-01 also replaces the interrupted-cancellation recovery rule with deterministic
rollback/roll-forward classification and a reader fence that serves no mixed view.
