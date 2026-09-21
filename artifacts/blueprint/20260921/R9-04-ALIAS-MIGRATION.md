# R9 store-ID alias migration journal and fence

Planning-only. This sheet supersedes the R8-02 “atomic trust and envelopes” sentence. P01 owns
`SyncTrustStore.swift`, `SyncWireCodec.swift` and the migration journal. Domain packets only expose their existing
envelope read/write transaction; they do not implement alias policy.

## Files, identities and journal schema

The live trust path is `Application Support/LifeOS/Replication/trust.json`. The single migration journal is
`Application Support/LifeOS/Replication/store-id-migration.json`; staging is the sibling directory
`store-id-migration/<migrationID>/`. Domain envelope paths remain the existing descriptor paths resolved only by
`DomainWireValues.liveEnvelopeURL(for:applicationSupport:)`; there is no new domain sidecar. The 18 protected paths are trust plus
the closed 17 `SyncStoreKind` envelopes. `SyncAdapterEnvelopeV2.storeUUID` and every retained R3 UUID reference are
read-only identity evidence, not values to regenerate.

```swift
public enum SyncAliasMigrationPhase: String, Codable, Sendable {
 case prepared, validatedOld, staged, verified, fenced, committing, committed, interrupted, rejected, rolledBack
}
public enum SyncAliasMigrationErrorCodeV5: String, Codable, Sendable {
 case aliasSourceChanged, aliasRecoveryBlocked, hashMismatch, diskFull, cancelled, lockBusy, invalidMapping
}
public struct SyncMigrationFileV5: Codable, Equatable, Sendable {
 public let relativePath: String; public let oldSHA256: String; public let stagedSHA256: String
 public let kind: SyncStoreKind?; public let byteCount: UInt64
}
public struct SyncAliasMigrationJournalV5: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let migrationID: UUID; public let datasetID: String
 public let oldEncoding: SyncStoreIDEncodingV4; public let newEncoding: SyncStoreIDEncodingV4
 public let oldTrustHash: String; public let oldAliasTableHash: String; public let newAliasTableHash: String
 public let files: [SyncMigrationFileV5]; public let completedPaths: [String]
 public let phase: SyncAliasMigrationPhase; public let fenceID: UUID?; public let createdAt: Date; public let updatedAt: Date
 public let errorCode: SyncAliasMigrationErrorCodeV5?; public let transitionHash: String
}
public struct SyncAliasMigrationFenceV5: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let migrationID: UUID; public let oldTrustHash: String
 public let newTrustHash: String; public let oldAliasTableHash: String; public let newAliasTableHash: String
 public let expectedFiles: [SyncMigrationFileV5]; public let commitCursor: UInt16; public let signature: String
}
public enum DomainWireValues {
 public static func liveEnvelopeURL(for kind: SyncStoreKind, applicationSupport: URL) throws -> URL
}
public extension SyncTrustStore {
 func load() throws -> SyncTrustRecord
 func beginAliasMigration(datasetID: String, old: SyncStoreIDEncodingV4,
   new: SyncStoreIDEncodingV4) throws -> SyncAliasMigrationJournalV5
 func validateOld(_ journal: SyncAliasMigrationJournalV5) throws -> SyncAliasMigrationJournalV5
 func stageAliasMigration(_ journal: SyncAliasMigrationJournalV5) throws -> SyncAliasMigrationJournalV5
 func verifyStaged(_ journal: SyncAliasMigrationJournalV5) throws -> SyncAliasMigrationJournalV5
 func fenceAliasMigration(_ journal: SyncAliasMigrationJournalV5) throws -> SyncAliasMigrationJournalV5
 func commitAliasMigration(_ journal: SyncAliasMigrationJournalV5) throws -> SyncAliasMigrationJournalV5
 func recoverAliasMigration() throws -> SyncAliasMigrationJournalV5?
}
```

`files` has exactly 18 unique normalized relative paths, sorted bytewise; `completedPaths` is a prefix in that order.
Hashes are lower-case SHA-256 of exact file bytes. The journal transition hash is
`SHA256(Frame("LifeOS/store-alias-migration/v5",CanonicalJSON(journal without transitionHash)))`; dates are UTC
milliseconds. The owner signature on the fence uses `Frame("LifeOS/store-alias-fence/v5",CanonicalJSON(fence without
signature))` and the pinned owner key in `SyncTrustStore`.

## Resumable phases and transaction order

`SyncTrustStore.beginAliasMigration(datasetID:old:new:) throws -> SyncAliasMigrationJournalV5` acquires the existing
replication writer lock, reads trust plus all 17 live envelopes, verifies the old hashes/encoding/storeUUIDs and writes
`prepared` with no live mutation. `validateOld` then checks exactly one alias for each kind and UUID, all envelope
datasets/heads/frontiers/checkpoints, no unresolved previous journal and no noncanonical bytes. Missing/extra/changed
files return `aliasSourceChanged` and leave the journal `rejected` without staging.

`stageAliasMigration(_:)` writes the new owner-signed table into staging `trust.json`, and writes each staged domain
envelope with only `storeIDEncoding`, `aliasTableHash` and the compatibility projection changed. Operation bytes,
operation hashes, receipt IDs, heads, frontiers, outbox/inbox/ACKs/conflicts and `storeUUID` are byte-preserved. Each
candidate is flushed, fsynced and hashed before the journal changes to `staged`. `verifyStaged(_:)` decodes all 18
candidates with the bounded codec, validates old/new mapping and compares every preserved field; only then does it write
`verified`.

`fenceAliasMigration(_:)` writes the owner-signed `SyncAliasMigrationFenceV5` with `commitCursor=0`, fsyncs its file and
directory, then changes the journal to `fenced`. From this point every `SyncTrustStore.load()` and domain envelope
loader reads the fence first: it serves the old set while phase is `fenced`, or the new set only after all new hashes
are committed. A mixed set is never exposed to an adapter.

Before the first live replace, `commitAliasMigration(_:)` copies each old file to
`store-id-migration/<migrationID>/backup/<relativePath>` with exclusive/no-follow creation, fsyncs every backup and
records the verified `oldSHA256` values already present in the journal. The backup directory is retained through
recovery and is deleted only after the committed fence has passed two startup validations.

`commitAliasMigration(_:)` replaces staged files one at a time in the sorted `files` order. After each same-volume
atomic replace it fsyncs the directory and writes the next `commitCursor/completedPaths` to the journal. Trust is the
last file, so no reader can select new aliases until all domain envelopes are new. After all 18 new hashes match,
the journal becomes `committed`; the fence is retained until the next successful startup validation. Cancellation or
disk-full stops at the last cursor and returns `interrupted`/`diskFull` without deleting either verified set.

## Crash recovery and rollback

`recoverAliasMigration() throws` runs before any sync. For `prepared|validatedOld|staged|verified`, it revalidates the
old set, deletes only staging, and marks `rolledBack`. For `fenced|committing`, it hashes every live path: all old
means resume commit, all new means mark `committed`, and a mixed set means restore only the old `.r9-backup` files
whose hashes match `oldSHA256`, then resume from zero. Any hash mismatch or missing backup is `aliasRecoveryBlocked`;
no partial alias state is accepted. A committed journal is retained until two successful loads and then pruned only
after the fence and old backups have content hashes recorded in the receipt log.

`SyncStoreIDResolver` verifies legacy UUID signatures against their original bytes before mapping to kind. It never
rewrites a signed operation, checkpoint or sequence. V1 transport continues to carry the original UUID reference;
V2 carries `kind.rawValue` plus `newAliasTableHash`. A peer changing encoding or alias hash mid-stream is rejected
before `persistInbox`. `SyncTrustStore` exposes `load`, `beginAliasMigration`, `stageAliasMigration`,
`verifyStaged`, `fenceAliasMigration`, `commitAliasMigration` and `recoverAliasMigration`; P02 only transports the
negotiated values.

## Revision11 supersession

R11-01 is the final alias contract. It adds the `planningSQLite` artifact row and coordinates the Planning
`sync_meta` transaction with the same fenced UTF-8 path order as JSON replacements. Its V6 journal/fence types,
backup/recovery phases, SQL bridge methods and trust-last rule supersede the V5 shapes above; operation bytes,
UUID store IDs and signed history remain unchanged.
