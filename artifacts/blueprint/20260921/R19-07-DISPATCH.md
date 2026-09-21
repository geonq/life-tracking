# R19-07 — dispatch, precedence and schema integration

> R20-06-DISPATCH.md explicitly supersedes the five reviewed topics and related field additions; this R19 sheet remains authoritative only where retained. Prior readiness is historical.
Read R19-READINESS, this sheet, then the ordered contractFiles for your packet in14-OWNERSHIP.json.
Editor readiness only. This task is planning-only; no source/build/test/project/dependency/commit/push authorization is exercised here.
Historical readiness claims are not independent acceptance. No blueprint guarantees error-free execution.

## Topic authority and explicit supersession

|conflicting retained clause|R19 authority|retained scope|
|---|---|---|
|R4-09 generic/closed sign used for receipt signatures; R17 implicit owner/device keys|R19-01|R4 replication custody/roles/sign allowlist and CLI restrictions unchanged|
|R9/R17/R18 all-store projection marker requires SyncStoreKind|R19-02|R9 replication marker remains solely replication/recovery Op1|
|R18 deletion expectedBeforeHash needed before prepare; undefined command|R19-03|R18 target variants, canonical order, individual marker/proof hashing|
|R10/R11 routes prohibit remote delete; P02 unnamed remote adapter|R19-04|existing HTTPS auth/nonces/caps plus explicit new route only|
|R18 last target hash allegedly binds entire journal/fence|R19-05|individual target chain, existing authority-file transactions|
|R16 result lacks stable time/commit ID; R18 finalize()/retry gaps|R19-06|R17 frames/footer, R18 append interface, historical V6/V7 verification|
|R18 phase-self-edge prohibition and old receipt byte caps|R19-06 preparation edges/capacity|all other R18 phase/error/CAS/retry rules|
|R17/R18 dispatch and old read maps|R19-07 +14 +11|203 exclusive paths and existing source dependency lists unchanged|

R19-06 capacity section is final over any earlier inline retained cap; R19-05 completion is final for deletion proof fields.
Do not concatenate competing wire shapes. New active V8 is R17 container +R18 retry +all R19 explicit field additions below.
Previously signed R18 V8 is read-only schemaUpgradeRequired, not mutated under missing/default keys; V6/V7 migration remains version-specific.
No actual deployed R18 format is asserted. Observed incompatible real state blocks its mutation and preserves bytes for targeted migration specification.

## Single active-schema checklist

IdentityV8 adds preparedAt/installationID; WorkPlanV8 adds restoreUnits (empty outside Op3).
SnapshotV8 adds publicationPreparation/deletionCompletion, both REQUIRED nullable keys; populated only under R19-05/06 phase rules.
Action adds prepareDeletion and preparePublication; Result detail adds publication; prepare null-CAS exemption includes prepareDeletion.
Initial Op4 command is prepareDeletion, never prepare. preparePublication is the only cursor-preserving preparation self-edge20/30/35.
RetiredID adds operationKind/deletionSummary; successful Op4 carries complete retained deletion evidence.
Sink.finalize requires persisted preparation; reconcileSinkAhead cannot publish before it exists; finalized result contains stable identity/time.
R18-03 historical converted records carry explicit historical provenance and retain historical finalization/binding/identity checks.
For converted V6/V7 records, installationID=current pinned installation; preparedAt=original validated preparation time or original boundAt if preparation absent and bound evidence valid.
No authenticated time evidence→receiptMigrationNeedsEvidence. Historical phase>=40 may keep publicationPreparation=null ONLY with verified migration provenance.
Historical successful deletion may keep deletionCompletion=null ONLY when its original validated proof is retained in migration evidence; cannot assert new R19 completion.
Historical RetiredID without new evidence is not automatically upgraded/pruned; return receiptMigrationNeedsEvidence unless original full proof can be retained.
New receipt validators require R19 fields/evidence; separate migration validator handles these narrowly enumerated historical branches.
Historical active phase<40 must reconstruct full R19 preparation/proofs before40; missing source/markers blocks, never resets cursors.

## Producer/consumer ownership

P01: ReceiptAuthorityKeyStore19, all19 DTOs/ports/pure hashes in existing Sync files; replication transport/signing remains distinct.
P02: Windows route/typed server signing/marker readback and remote restore boundary in gateway main.py/replication.py; Mac relay rejects data.manage route.
P03/P04/P05/P06/P12/P13/P14: exact owned restore/deletion ports, state hashes, durable markers and source-preserving policy.
P15: WindowsDataManagementOwner19 in server.ts, UsageHistory methods in history.ts; public TypeScript DTOs from P01 replication.ts.
P16: explicit receipt bootstrap UI/composition, clipper Apple port in ModuleNavigation.swift; target membership only within its existing paths.
P17: protected public gateway pin/root ACL installation and remote admin capability proof; no private seed copied to Node.
P18-I: all orchestration/journals/publication/receipt persistence in its three Shared files; no source edit outside owned paths.
P18-E: later integrated evidence, including every crash boundary and live remote outage case; not part of this planning revision.
Types/ports land before consumer implementations; P02 may expose disabled capability until P15 owner is wired. This is not a dependency cycle.
P16 composition waits existing P18 dependency. Early membership-only work never starts runtime collectors before fences recover.

## Read maps and preserved DAG

Each packet retains its complete R18 ordered list and gains R19-01…07 in numeric order last; no prior feature/OS27/design sheet is removed.
14 contractDependencies includes every R19 explicit reference and retained R18 arrays; document cross-references may cycle, source dependencies must not.
SharedContractConsumers contains every packet for seven19 sheets; producer/consumer interfaces cannot diverge through partial read maps.
203 paths, their owner/status/fingerprints and19 dependency arrays must compare byte-for-byte semantically to pre-R19 baseline.
Known baseline ownership digest: e4e12a8bb7d5c4c5c313bc8033ba73837f4d12d6bb0cb9aca5a2724c45524ca8 (canonical Python sorted JSON projection).
Native visual/product instructions03/04/17/20/27 remain in force; this revision repairs data infrastructure without reopening their design.
No package, new source file, Windows deployment, signing enrollment or device action is authorized by a planning-readiness label.
