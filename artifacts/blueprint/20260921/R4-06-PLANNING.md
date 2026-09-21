# Planning/Obsidian payload and journal transaction seal
P06 owns existing PlanningVaultStore/PlanningMutationJournal/PlanningFilesystemPublication; no second journal/Document autosave.
```swift
public struct PlanningFilePayload:Codable,Equatable,Sendable {
 public let schemaVersion:Int; public let tag:String; public let vaultID:String; public let path:String
 public let media:String; public let bytes:String; public let digest:String; public let byteCount:Int
}
```
```python
@dataclass(frozen=True)
class PlanningFilePayload:
    schemaVersion:int; tag:str; vaultID:str; path:str; media:str; bytes:str; digest:str; byteCount:int
```
```typescript
interface PlanningFilePayload { readonly schemaVersion:1; readonly tag:"planningFile"; readonly vaultID:string; readonly path:string; readonly media:"markdown"|"canvas"; readonly bytes:string; readonly digest:string; readonly byteCount:number }
```
All required; v1/tag planningFile; vaultID canonical UUID matches chosen vault marker. Path<=1024UTF8 within LifeOS/,
validated existing PlanningStoredPath (relative, no traversal/symlink escape); .md/.canvas only; case collision rejects.
bytes base64url of EXACT original file bytes (Markdown<=1MiB/Canvas<=2MiB); byteCount actual, digestSHA256 same bytes.
Existing codecs validate before publication; unknown compatible JSON Canvas/node fields and Markdown YAML remain in exact bytes,
not discarded by transport. Canvas node type extensions preserved; render unknown shape as rectangle without rewriting field.
Opaque document bytes may leave to enrolled dataset only; bookmark/security-scope tokens/inode/path outside LifeOS never leave.
File logical identity SHA256('vault'+NUL+path); rename is explicit old-path delete + new-path put in same local journal batch,
remote publication may complete across two files via existing recovery, never claim external filesystem atomicity.

## Exact bridge methods
PlanningPayloadCodec.encode(vaultID:UUID,path:PlanningStoredPath,bytes:Data)throws->Data;
decode(_ bytes:Data)throws->PlanningFilePayload; expectedVersion(from operation:SyncOperation)throws->PlanningContentVersion.
Expected version derives current applied head's payload digest+byteCount, never remote wall timestamp; new file expected absent.
PlanningSyncAdapter.applyPayload→PlanningVaultStore.stageReplicated(_ payload:PlanningFilePayload,operation:SyncOperation)throws->SyncCommitReceipt.
stageReplicated validates selection/generation/path→PlanningMutationJournal.stageReplicatedMutation(request:PlanningMutationRequest,
operation:SyncOperation)throws->PlanningMutationReceipt→PlanningFilesystemPublication.publish→recordPublicationOutcome.
stageReplicatedMutation adds operation/inbox row and calls existing stageMutationLocked inside SAME transaction.
PlanningVaultStore.completeReplicatedPublication(mutationID:UUID)throws->SyncCommitReceipt reads terminal existing publication receipt,
updates replication entity/head/applied ACK in journal transaction; nonterminal returns missingParent/busy, no applied ACK.
Recovery calls publishPendingPage then completeReplicatedPublication; crash after filesystem publish before ACK is recovered by
existing witness/receipt proof. Retry does not overwrite changed file; conflict retains both exact byte payloads.
Local stageMutationLocked adds unsigned operation within its SQL transaction; publish success determines applying ACK;
UI may show saved-pending-publication only after journal durable, not claim file already in Obsidian.

## Exact additive SQLite v3 migration (existing domain schema v2 retained)
All new tables prefix sync_; do not reuse existing mutations.sequence AUTOINCREMENT for wire UInt64.
sync_meta(store_id TEXT PRIMARY KEY, dataset_id TEXT NOT NULL, origin_id TEXT NOT NULL, epoch TEXT NOT NULL,
next_sequence TEXT NOT NULL, envelope BLOB NOT NULL); one row, bounded canonical SyncAdapterEnvelope metadata.
sync_operations(mutation_id TEXT PRIMARY KEY, operation_hash TEXT NOT NULL, encoded BLOB NOT NULL,
local_mutation_id TEXT UNIQUE REFERENCES mutations(mutation_id), state TEXT NOT NULL CHECK(state IN ('inbox','unsigned','ready','applied','conflict')),
outbox_state TEXT CHECK(outbox_state IN ('unsigned','ready','awaitingAcks','blocked')),
attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 2147483647), last_error TEXT).
sync_receipts(mutation_id TEXT NOT NULL,replica_id TEXT NOT NULL,level TEXT NOT NULL,encoded BLOB NOT NULL,
PRIMARY KEY(mutation_id,replica_id,level)); signature/canonical validation before binding.
Foreign keys ON; all SQL bound parameters, encoded blobs<=32MiB, table aggregate counted in existing256MiBDB cap.
Existing operations' encoded bodies stored once in sync_operations; envelope arrays represented through SELECT projection,
not copied in sync_meta envelope; stored envelope encodes empty outbox/inbox/acknowledgements arrays and reconstructs them for read.
Local rows have nonnull outbox_state; remote rows have null outbox_state/last_error and attempts=0.
Reconstruct outbox operation from encoded, state from outbox_state, attempts/lastError from columns, ACKs via sync_receipts join.
Reconstruct inbox from remote state=inbox; retain entity/conflict/frontier metadata verbatim in sync_meta envelope.
Unsigned encoded rows permit empty signature ONLY locally; hash remains signingBytes hash, unchanged after signing.
Transport-attempt/ACK updates use one SQL transaction; saturate attempts, clear last_error on accepted response, never reset sequence.
P06 extends verifySchema to exact3 new tables/index/column rules and user_version3; supports old v1→v2→v3 chain.
migrateV2ToV3(): existing exclusive writer lock→BEGIN EXCLUSIVE→CREATE3tables→bootstrap current known documents→
PRAGMA user_version=3→COMMIT; old pending mutations retain byte payload/fingerprint/receipts; no filesystem publication in migration.
Existing pending are wrapped with unchanged mutationID mapped local_mutation_id; reserve canonical unsigned sequence once.
Unavailable not-downloaded files have no invented bootstrap; read later through coordinated access then create operation from actual bytes.
On SQL failure ROLLBACK; leave existing file state unchanged. Unknown version read-only; old binary cannot openv3 (preserve backup).

## Archive and external edit handling
PlanningArchive specialized PlanningFilePayload; includes all published files plus unresolved branch bytes/heads.
makeArchive refuses publication in-flight; return busy until recovery terminal. Restore stages each file via same journal,
then publishes bounded pages; checkpoint ACK only when all terminal; interruption resumes journal, not repeated whole-vault overwrite.
External Obsidian edit: coordinated read hash differs from applied head→local mutation with that exact base; simultaneous draft becomes
conflict with observed external bytes; resolveConflict existing keep-local/keep-remote/keep-both, never timestamp winner.
Observer250ms coalesces paths; per-path generation guards; canvas pan/pinch no writes, commit once per gesture.
Release physical/iCloud availability gates do not change API: unselected/permissionLost/notDownloaded states defined, no fake empty success.
Evidence: codec unknown-field roundtrip, mutation retry/crash/recovery, path escape negatives, real Obsidian↔Mac↔iPhone publication.

## Revision6 supersession
R6-03 is authoritative for the inbox/ACK/frontier paragraph: the existing `journal.sqlite` v3 tables are the only
Planning sync persistence, and no `sync_acknowledgements`, `sync_frontiers` or second database may be added.
