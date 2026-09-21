# R17-06 — authority checkpoint and atomic rotation

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Replaces R16-04 checkpoint/log clauses and R15's universal sequence-zero-root requirement.
Only post-retirement logs rotate; bootstrap/relocation has a finite <=32-record budget and must complete or block before rotation.
P18 owns lock/rotation; P01 codecs/signatures. No new source path or mutable authority marker.

## Complete checkpoint payload

CheckpointV9 = `{schemaVersion:9,authorityID:UUID,migrationEpoch:U64,authorityFileHash:H,bootstrapFence:MutationV9,baseSequence:U64,baseHeadHash:H,retirementProof:RetirementProofV9,retirementProofHash:H,retirementProofSequence:U64,currentInventory:[InventoryV9],resultInventoryHash:H,terminalHeads:[TerminalHeadV9],activeIntents:[FileIntentV9],fence:FenceV9,checkpointHash:H,signerKeyID:String,signature:Data}`.
TerminalHeadV9 = `{domain:Domain,count:U32,rootHash:H}`; exactly3 sorted domain rows, including empty roots.
This is a per-FILE authenticated aggregate of terminal heads; it deliberately does not copy unbounded per-receipt arrays.
R17-07 defines exact root/hash preimages and file reconstruction. Missing canonical bytes cannot be invented from a root.
FenceV9 = `{migrationEpoch:U64,expectedInventoryHash:H,fenceRecordHash:H,open:Bool}`.
Epoch equals immutable authority. expectedInventoryHash=resultInventoryHash. fenceRecordHash=original fenceOpen recordHash; checkpoint.bootstrapFence is the complete original signed fence.
It must equal owner.bootstrapFence for new authorities; old-format compatibility validates its original codec/signature and upgraded Keychain authorization.
open=false after retirement; routine file intents do not reopen migration fence. Pending FileIntent is the separate write-transaction fence.
checkpointHash=H(`LifeOS/authority-checkpoint/v9`, checkpoint excluding checkpointHash/signature).
Inner signature signs F(`LifeOS/authority-checkpoint-signature/v9`, raw32(checkpointHash)); outer envelope additionally signed R17-05.
Checkpoint is payload of kind10 in the ordinary framed MutationV9, never a bare JSON file or an unsigned first frame.

## Bounded collections and byte budgets

currentInventory exactly3 entries, each<=512 CJ bytes; terminalHeads exactly3, each<=256.
retirementProof exactly3 complete dispositions/proofs<=16384 CJ bytes; owner authority<=32768, referenced by hash only.
activeIntents length0 or1, one FileIntent<=8192 CJ bytes. No active legacy intent is legal after retirement.
fence<=512; complete bootstrapFence<=8192; fixed checkpoint identifiers/hashes/signature and envelope<=4096 combined.
Worst permitted encoded checkpoint frame <=16384+1536+768+8192+512+8192+4096+36=39716 <65572.
Still measure exact CJ length before mutation; oversize→capacity with current log intact, never omit collections.
Each FileIntent references full old/new Inventory entry and candidate bytes on disk; it never embeds aggregate receipt file bytes.
Receipt count is bounded R17-02; terminal roots include both compact terminal logs and retained retiredIDs.
If a per-object size cap cannot be met, reject that transaction BEFORE its intent is durable; no unrepresentable active state.

## Root validation and replay after rotation

An unrotated first record MUST be kind1 sequence0 previous=null matching embedded bootstrap fence.
A rotated first record MUST be kind10, sequence=payload.baseSequence+1, previousRecordHash=payload.baseHeadHash.
Verify immutable authority/activated seal, authorityFileHash, device signature and complete inner checkpoint signature before trusting base head.
Verify retirement proof signature/hash/epoch,3 dispositions and proof's historical inventory; do not compare historical inventory to current files.
Verify current inventory/terminal roots against present canonical files, allowing one pending FileIntent old/new case per R17-07.
With pending exact-new bytes, checkpoint roots still describe oldEntry: compare roots to authenticated oldEntry, then validate actual bytes against newEntry and commit; never require old bytes to remain on disk.
Verify baseSequence>=retirementProofSequence; retirementProofSequence is the original kind7 sequence and never reset.
Each later record is sequence+1/previous=current head. Root signature is an AUTHENTICATED REBASE, not proof that deleted bytes remain accessible.
R15 requirement to replay from sequence0 is explicitly inapplicable to a valid signed checkpoint root.
retirementProofHash must be identical in every later intent/commit/checkpoint; proof history never rewritten by current updates.
Mutation log checkpoints authenticate integrity, not rollback against simultaneous restoration of all local secure state; do not claim hardware monotonicity.

## Active intent and rotation recovery

Checkpoint snapshot is taken at a locked complete record boundary; active intent is included byte-for-byte with its intentHash.
On reopen pending candidate/current file states follow R17-07 without consulting removed intent records.
Exact new canonical file→parent fsync and append matching commit; exact old+valid candidate→replace then commit.
Exact old+missing candidate→append abort and preserve old; third hash→externalModification. No filename-based content adoption.
Proof and terminal roots required for resume are in payload/current files; no discarded record is needed.
No new receipt/file transaction may begin until active intent is committed/aborted or error is surfaced.

## Atomic rotation order

Limits: log<=67108864 bytes, <=262144 records, each CJ<=65536. Before a new transaction reserve8 max-sized frames.
If reserve would cross count/byte limit, rotate before its intent. Recovery may use reserved frames; never start without reserve.
Rotation allowed with0/1 active intent; threshold must leave room for commit/abort and checkpoint. A checkpoint is small by caps above.
1. Lock; verify active log prefix/head/current file state; construct/sign checkpoint of that exact state.
2. Exclusively create fixed same-directory `authority-mutations-v9.log.next` mode0600; refuse symlink/unrelated object.
3. Write ONE framed kind10 record; fsync file; reopen/verify independently, including checkpoint root and actual canonical files.
4. Atomically rename next over active log (same volume); fsync Receipts directory; reopen active and verify root before unlocking.
Old open handle remains valid until step4 completes. No backup/second authoritative log is selected by timestamp.
Crash before rename: active log wins; matching abandoned next is disposable only after active validation.
Crash after rename: valid checkpoint-root active wins; no fallback to discarded history needed.
Directory fsync failure→archiveIOFailed, keep lock state invalidated; restart classifies actual active root, never reports successful rotation.
Existing next at retry: if valid exact expected checkpoint bytes reuse; otherwise preserve and return authorityCheckpointCorrupt.
Neither valid active log nor authenticated root→authorityCheckpointCorrupt; no empty-log bootstrap.
Full reopen scan O(log bytes+receipt bytes); normal append verifies one bounded frame and updates in-memory state.
Checkpoint rotation amortizes bounded log growth; receipt compaction remains a separate R17-02 file mutation.
