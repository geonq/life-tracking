# Additional source reconciliation and exact remaining actions
Source-only observations, no builds/tests. These refine CP-S rather than falsely closing it.

## Calendar: confirmed current boundary
CalendarDomain.swift CalendarItem.CodingKeys:
id,title,kind,icon,iconAsset,systemIconName,status,start,end,createdAt,updatedAt,deletedAt,timeZoneIdentifier,recurrence.
occurrenceSourceID is transient, explicitly not encoded/persisted. Do not send generated occurrences as standalone events.
CalendarRecurrenceRule keys frequency,interval,until; four frequency cases daily/weekly/monthly/yearly.
CalendarItemKind aliases daily_schedule→dailySchedule and CalendarProgress blocked→aborted are legacy decode behavior;
new domain wire must choose canonical cases, not copy aliases into signed metadata.
CalendarItem.init(from:) and validatedForPersistence() already validate; do not implement a duplicate validator abstraction.
Current title cap240 UTF8 bytes; CalendarSnapshot cap1024 items/256KiB; recurrence expansion max400 per item.
CalendarSnapshot current schema1 keys schemaVersion/items; missing/null items accepted only legacy decoder policy.
CalendarStore.load uses bounded FileHandle.read; save validates, encodes JSONEncoder.calendar, writes/protects temp,
then replaceItemAt/moveItem and updates cache. mutate closure runs without suspension between latest read and save.
Do not call a nonexistent CalendarMutation DTO. CP-S01 must trace actual recurrence editing helpers/callers and decide
aggregate shape for split-series/exception operation before naming its signature, including icon/date payload encoding.
At256KiB existing cap, adding replicated copies can exceed size even during migration. CP-S01 must supply a bounded
same-transaction layout/capacity decision with old maximum-sized snapshot migration; do not silently raise caps or drop items.

## Planning: confirmed current journal seam
PlanningVaultStore.stage(_:)→PlanningMutationJournal.stageMutation(_:)→withOperation→withOpen→transaction→stageMutationLocked.
transaction<T>(_ body:() throws->T) throws->T executes BEGIN IMMEDIATE, COMMIT, ROLLBACK on error.
stageMutationLocked returns existing receipt for matching fingerprint; mutationID reused with different fingerprint throws.
Publication is separate: PlanningVaultStore.publish→PlanningFilesystemPublication.publish; journal phases preserve recovery.
PlanningMutationJournal.beginPublication/recordStagedIdentity/markPublishing/recordPublicationOutcome are existing seams.
PlanningVaultStore.publishPendingPage→journal.loadPublicationRecoveryPage→publication recovery with bounded budget.
PlanningMutationJournal.recordConflict/resolveConflict/durableResolutionLocked own conflict receipts, not a new sync sidecar.
Existing tables: vault,documents,mutations,publication_attempts,conflicts,payloads,receipts,mutation_reservations,
publication_details,conflict_resolutions,legacy_conflict_inspections. createSchemaAndVault/verifySchema validate exact schema.
Existing migrateV1ToV2 is history; do not reset user_version to protocol1 or reuse AUTOINCREMENT as unsigned wire sequence.
CP-S04 now specifically: inspect full verifySchema+stageMutationLocked+recordPublicationOutcome+durableResolutionLocked;
write exact additive next-version SQL/column constraints, migration, and inbox/outbox/ACK commit placement around file publication.
Do not ACK applied when only staged in SQL: filesystem published and journal terminal receipt must both be recoverable.
A journal commit cannot make SQLite+external iCloud file atomic; preserve witness/recovery protocol, no false atomicity claim.
P06 allowlist amendment: ios/Planning/PlanningMutationJournal.swift and ios/Planning/PlanningFilesystemPublication.swift
for reviewed CP-S04 integration only. P05 candidate graph/reducer review retains original bounded ownership.
No new parallel SQLite journal or Document autosave writer authorized.

## Exact checkpoint closure artifacts
CP-S01…05 each output: DTO coding-key table (including nested values), old-format default table, strict new-format decoder,
entity-key/aggregate mapping, existing reducer call with all arguments, transaction order, migration+rollback examples,
checkpoint archive encoding/restoration and required maximum-size/duplicate/concurrent/DST or source-specific evidence.
R3 outer schema examples are not substitute for these domain examples. No worker can fill these from intuition.
CP-W output: scanner state functions + canonical string escaping/signature byte vectors, independent review record.
CP-K output: exact Mac keychain bridge symbols, Windows protected-key accessor, bootstrap/rotation/reseed transaction.
CP-L output per feature: source reference→current named body/action/reducer→missing delta→exact new signature if needed.
CP-SEC output per finding: current control flow, fix/no-change reasoning and bounded adversarial evidence plan.
