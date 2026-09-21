# R17-07 — aggregate receipt files and authorized transactions

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Replaces R16-04 routine mutation prose and R15 inventory hash ambiguity. Fixed paths are unchanged.
P18 is sole writer; P16 uses public calls. No per-receipt file, second database, caller-selected path or unauthenticated replacement.

## File mapping and canonical hashes

|Domain numeric|canonical relative path|operations|
|---|---|---|
|recovery1|`Receipts/recovery-imports.json`|recoveryImport1|
|data2|`Receipts/data-management-receipts.json`|dataExport2,dataRestore3|
|deletion3|`Receipts/data-management-deletions.json`|dataDeletion4|

Each file contains all current logs/retired IDs for its domain. Mutating one receipt rewrites that bounded WHOLE FileV8.
InventoryV9 = `{domain:Domain,relativePath:String,fileHash:H?,byteCount:U64,writeSequence:U64,migrationEpoch:U64,receiptHeadHash:H,terminalHeadHash:H,terminalCount:U32}`.
All keys present. Null fileHash legal only in bootstrap initial inventory for missing canonical file; then byteCount/writeSequence=0 and empty roots.
After canonicalVerified all3 files exist, including empty domain containers. Never unlink an aggregate file to prune a receipt.
fileHash=SHA256(exact CJ(FileV8) bytes), byteCount=encoded count. Roots use these arrays:
HeadRow=`{receiptID:UUID,operationID:UUID,phase:PhaseV8,headHash:H,retired:Bool}`.
Each log contributes snapshot phase/headHash/identity.operationID and retired=false; retiredIDs contribute terminal values and retired=true.
Sort all rows lowercase receiptID; unique across both collections. receiptHeadHash=H(`LifeOS/receipt-file-heads/v9`, {domain,heads:[HeadRow]}).
Terminal rows select phase60/90/91 (including retired IDs), same sorted encoding;
terminalHeadHash=H(`LifeOS/receipt-file-terminal-heads/v9`, {domain,heads:[HeadRow]}), terminalCount=array length.
Empty root hashes the same object with heads:[], never null or empty SHA sentinel.
inventoryHash=H(`LifeOS/receipt-file-inventory/v9`, {schemaVersion:9,authorityID,migrationEpoch,files:[InventoryV9]}) with exactly3 domain-ordered entries.
All hashes include null keys and writeSequence/epoch; no dictionary iteration, timestamps, JSON whitespace or path-derived hash.
Historical proof canonicalInventoryHash uses EXACTLY this domain/preimage and historical entries.
Current inventory uses this same function on latest authorized files; it need not equal historical proof's inventory.

## Exact intent / commit

FileIntentV9 = `{intentID:UUID,receiptID:UUID?,domain:Domain,relativePath:String,operation:FileOp,retirementProofHash:H?,retirementProofSequence:U64?,expectedInventoryHash:H,oldEntry:InventoryV9,newEntry:InventoryV9,candidateName:String,intentHash:H}`.
FileOp numeric create=1,append=2,compact=3,prune=4,migrate=5. Generic unqualified replace is forbidden.
candidateName EXACT basename of target + `.next-` +lowercase intentID; under same pinned Receipts directory, <=128 UTF8 bytes.
intentHash=H(`LifeOS/receipt-file-intent/v9`, intent excluding intentHash). Whole intent authenticated by mutation envelope.
FileCommitV9 = `{intent:FileIntentV9,resultInventoryHash:H,observedEntry:InventoryV9}`.
Commit carries complete intent, not only its ID; observedEntry MUST equal newEntry; result inventory swaps only that domain entry.
Prior kind2/8 intent or active checkpoint intent must match complete preimage; arbitrary signed commit without intent invalid.
retirementProofHash/Sequence both null before retirement, both exact historical values after. Epoch never changes on routine write.
receiptID required for append/compact/prune; null for create/migrate. No wildcard multi-receipt edits except migration.

## Operation-specific validation

|operation|old/new rule before signing intent|
|---|---|
|create|only pre-retirement missing oldEntry; new empty FileV8, sequence1; no receipt lost|
|append|old file must exist; exactly one existing receipt advances by legal transition OR one new identity appears; other logs/retiredIDs byte-identical|
|compact|exactly one log changes to signed anchor; head/phase/work cursor preserved; or terminal workPlan summarized per R17-02; no identity removed|
|prune|one compact terminal log replaced by RetiredID of same receipt/operation/phase/head; no archive/source data delete implied|
|migrate|pre-retirement only; every input identity/head accounted for by R17-02 signed rebase; divergent histories block|

For every operation newEntry.writeSequence=old+1, new epoch=authority epoch and path/domain unchanged.
For compact, receiptHeadHash/terminal root unchanged except terminal projection retired remains false.
For prune roots change only that row's retired flag; counts/IDs remain; old/new file hashes usually differ and are recomputed, never assumed unequal.
A logically identical append retry returns stored receipt result WITHOUT another file transaction/writeSequence.
R17-02 prospective capacity check and chain validation run before candidate preparation; if compaction needed finish its independent transaction first.

## Exact filesystem order and crash table

`applyReceiptMutation(domain,receiptID,expectedReceiptHead,operation,transform) -> FileV8` runs on P18 authority actor under one interprocess lock.
transform is an internal pure typed operation, never an external arbitrary write closure; produces complete validated FileV8 and immutable candidate bytes.
Read verified old aggregate → compute new bytes/entries/inventory → exclusive-create candidate mode0600/nofollow → write/fsync candidate+parent
→ append signed intent/fsync authority log → atomic rename candidate over target → fsync target parent → re-read/verify target entry
→ append signed commit/fsync log → return receipt. No state projection exposed between intent and commit.
All handles pinned to same fixed directory; reject symlink/reparse/identity mismatch. Source content never logged in errors.
If directory fsync fails, no commit/return; reopen recovery retains intent. Disk-full leaves old or recoverable new, not an empty store.

|reopen with durable intent|action|
|---|---|
|target equals oldEntry, candidate exact newEntry|fsync candidate/parent again; replace; parent fsync; verify; commit|
|target equals newEntry|fsync target and parent; verify all roots/chains; append commit|
|target equals oldEntry, candidate absent|append kind11 abort with unchangedInventoryHash; old remains authoritative; caller retries new intent|
|target/candidate third hash or wrong type/epoch|externalModification; do not overwrite/delete|
|target missing, oldEntry.fileHash nonnull|externalModification even with candidate; preserve evidence|
|target missing, oldEntry.fileHash null, valid candidate|bootstrap create may proceed and commit|
|already matching commit|verify target/current later inventory; no-op, never overwrite a later authorized head|

No intent but candidate present→never apply it; classify as owned orphan after validating current authority; cleanup may remove only exact owned temp.
No intent and changed target→externalModification, never auto-accept by filename or timestamp.
Abort authenticates old inventory; no subsequent commit for that intentID is legal. Reattempt allocates new intentID.
Every recovery decision uses aggregate file hash AND decoded roots/epoch/sequence; a receipt head alone cannot authorize other contents.
R17-05 retirement proof fields are authoritative; R15 `canonicalInventoryHash,lastRecordHash` meanings persist with the NEW exact proof object.
