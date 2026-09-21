# Revision8 readiness

Planning-only. This revision changed only documents under `artifacts/blueprint/20260921/`; it does not claim that the
application is complete or that source code is bug-free.

## Verdict

**READY FOR LUNA — all seven R8 contract blockers are sealed for implementation.**

|Review blocker|Sealed contract|Status|
|---|---|---|
|Historical bootstrap|V4 bundle carries ordered owner-signed epoch chain and coverage for every retained source epoch|sealed — R8-01|
|Store-ID migration|Signed V1 UUID bytes, V2 kind IDs, owner aliases, frontiers, checkpoints and handshake are reconciled|sealed — R8-02|
|Identity/hash derivation|Mapping/alias/table/chain/UUIDv5 preimages exclude hash fields and reject collisions|sealed — R8-03|
|Calendar local commands|Complete fields, gesture contexts, resize edge, tombstones, CAS and local/replicated paths are explicit|sealed — R8-04|
|Receipt identity|Unique IDs, transition bytes, parent lineage, crash resume and bounded pruning are explicit|sealed — R8-05|
|Export streaming|Frame source/sink, 1 MiB bound, fsync/rename, cancellation/resume and ownership are explicit|sealed — R8-06|
|Packet ownership|P00–P18 titles/dependencies, allowlist and cross-packet boundaries have one authority|sealed — R8-07|

## Readiness audit

The R8 sheets were cross-read for duplicate authority, undefined R8 names, invalid local/replicated call direction,
unbounded arrays, self-referential hashes, schema-valid-but-undecodable frames and packet overlap. R8-01 is final for
epoch/recovery, R8-02 for store identity, R8-03 for derivation, R8-04 for Calendar commands, R8-05 for receipts,
R8-06 for export and R8-07 for ownership. R7 statements are history unless these sheets explicitly retain them.
Implementation workers must still perform the R7/R8 no-guessing checklist and stop on source evidence that contradicts
the sheets; that is an execution review, not an unsealed architecture choice.

## True external evidence gates

These are release evidence, not blueprint blockers: live Enable Banking consent and exports; Trade Republic/Robinhood
fixtures; physical iPhone HealthKit/Zepp permissions and workout accuracy; iCloud Obsidian vault permission and merge
behavior; Windows gateway outage/reconnect; Personal Team signing, App Groups and seven-day renewal; installed
iOS/macOS SDK and availability captures; visual/motion review on Mac trackpad and iPhone; final batched security and
penetration review; and storage/process telemetry. Each has a compile-safe offline or unavailable state in the retained
R4–R7 contracts. Demo data cannot satisfy a release gate.
