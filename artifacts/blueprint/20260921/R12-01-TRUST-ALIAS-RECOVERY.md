# R12 trust ownership and interrupted alias recovery

Planning-only. This sheet supersedes the ownership and recovery clauses in R11-01. It closes the mixed-state
case where JSON files are old while Planning `sync_meta` is new, or the reverse.

## One owner and dependency edge

`ios/Sync/SyncTrustStore.swift` has exactly one owner: **P01**. P01 owns trust records, alias journal/fence
types, signature verification, reader selection and migration orchestration. P05 owns only
`ios/Planning/PlanningMutationJournal.swift` and its SQLite implementation of the P01-owned port. P06 owns
filesystem staging/backup/replace/fsync. `SyncTrustStore` never imports P05; composition injects the port, so
the graph is `P00 → P01 → P05 → P06` for this path (P06 also retains its existing P07 dependency).

```swift
public protocol SyncAliasPlanningPort: Sendable {
 func prepareAliasFence(_ input: SyncPlanningAliasInputV6) async throws -> String
 func commitAliasFence(_ migrationID: UUID, expectedOldEnvelopeHash: String) async throws -> String
 func restoreAliasFence(_ migrationID: UUID) async throws -> String
 func inspectAliasFence(_ migrationID: UUID) async throws -> SyncPlanningAliasResultV6
}
public actor SyncTrustStore {
 public init(planning: any SyncAliasPlanningPort, files: any SyncAliasFilePort)
 public func beginAliasMigration(_ input: SyncAliasMigrationInputV6) async throws -> SyncAliasMigrationJournalV6
 public func requestCancellation(_ migrationID: UUID) async throws -> SyncAliasMigrationJournalV6
 public func recoverInterrupted(_ migrationID: UUID) async throws -> SyncAliasMigrationJournalV6
 public func loadView() async throws -> SyncAliasTrustViewV6
}
public protocol SyncAliasFilePort: Sendable {
 func hashLive(_ relativePaths: [String]) async throws -> [String:String]
 func replaceFromStage(_ relativePath: String, stage: String) async throws
 func restoreFromBackup(_ relativePath: String, backup: String) async throws
 func validateSet(_ hashes: [String:String]) async throws
}
public enum SyncAliasTrustViewV6: Sendable {
 case old, new, unavailable(String), blocked(String)
}
public enum SyncAliasRecoveryDecisionV6: String, Codable, Sendable { case none, rollback, rollForward }
// R11 SyncAliasMigrationJournalV6 adds these durable fields:
// public let cancelRequested: Bool; public let recoveryDecision: SyncAliasRecoveryDecisionV6
```

`SyncAliasPlanningPort` is declared by P01; P05 conforms `PlanningMutationJournal` to it. No worker may add a
second `SyncTrustStore`, trust file, migration journal or Planning envelope implementation. `14-OWNERSHIP.json`
records P05's dependency on P01 and P01's sole ownership of `SyncTrustStore.swift`.

## Final phases and reader fence

`SyncAliasPhaseV6` is extended with `recovering`; `SyncAliasRecoveryDecisionV6` is
`none|rollback|rollForward`; the journal stores `cancelRequested: Bool` and the decision. A signed fence is
written before the first live replacement. `loadView` reads the signed fence/journal before opening any domain:

|phase|reader result|
|---|---|
|prepared, validatedOld, staged, planningPrepared, verified|old live set|
|fenced, committing, interrupted, recovering|run/rejoin recovery; return no domain view until complete|
|committed|new live set after one complete hash validation|
|rolledBack|old live set after one complete hash validation|
|blocked|`migrationBlocked`; never serve a mixed set|

The old view during pre-fence phases is the live old set. During fenced recovery no caller reads live files;
the writer lock and fence make visibility atomic at the whole-dataset level. `SyncAliasFilePort` methods are
`hashLive(_:)`, `replaceFromStage(_:stage:)`, `restoreFromBackup(_:backup:)`, and `validateSet(_:)`, each
async-throwing and no-follow. Planning's port reports only atomic `.old|.new|.blocked` for `sync_meta`.

## Cancellation and deterministic recovery

Cancellation before `fenced` deletes only staging and records `rolledBack`. Cancellation at or after `fenced`
sets `cancelRequested=true`, records `interrupted`, keeps every verified JSON backup, Planning SQLite backup,
staged file and signed fence, and returns without exposing data. `recoverInterrupted` then:

The recovery writer has one fixed order: `jsonNonTrustPaths` (all JSON artifacts except `trust.json`, sorted by
relative-path UTF-8), then the logical Planning row (`journal.sqlite` through the SQL port), then `trust.json`.
The same order is used for rollback and roll-forward; the Planning row is never replaced as a filesystem byte
file, and trust is never visible as new before every other artifact validates.

1. Acquires the same writer lock, revalidates the fence and hashes every JSON path plus Planning `sync_meta`.
   Each artifact must be exactly `old`, `new`, or `invalid`; the SQL port must be exactly old/new/blocked.
2. If every artifact is old, persists `decision=rollback`. If at least one is new and every candidate is old
   or new with valid stage/backup hashes, persists `decision=rollForward`. This deliberately rolls forward the
   case “JSON old, Planning new”; it never serves that mixed state.
3. For rollback, restores `jsonNonTrustPaths` from exclusive backups in order, calls `restoreAliasFence` for the
   Planning row, restores `trust.json` last, verifies every old hash and fence state, then records `rolledBack`.
4. For roll-forward, replaces `jsonNonTrustPaths` from staged bytes in order; at the Planning row, calls
   `commitAliasFence` if SQL is old and skips it only when the new SQL hash is verified. It validates all non-trust
   artifacts, replaces `trust.json` last, validates the complete new set, then records `committed`.
5. If any artifact is invalid, a stage/backup is missing, or either set cannot be verified, records `blocked`
   and leaves all evidence for manual recovery; it never guesses a winner.

## Crash points and retention

The journal is fsynced after the recovery decision and after every path cursor. A crash before the decision
repeats classification; before/after a JSON replace it observes old/new and skips or repeats atomically; before/
after the SQLite transaction SQLite exposes old/new only; before/after trust replacement the same decision resumes;
after all new hashes but before the journal commit records `committed`. Disk-full/cancellation leaves
`interrupted|recovering` and no reader view. Backups and the signed fence remain until two clean validations of
the selected set, then are pruned in one bounded cleanup transaction.

P01 owns all trust/fence/recovery symbols; P05 owns SQL port implementation; P06 owns bytes and fsync. Acceptance
must force every listed crash point and prove that no observer can load JSON-old/Planning-new or the inverse.
