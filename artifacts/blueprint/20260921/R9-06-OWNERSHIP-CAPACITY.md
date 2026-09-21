# R9 canonical ownership, allowlist and capacity

Planning-only. This is the only R9 packet/path ownership table. `14-OWNERSHIP.json` is its machine-readable file
allowlist; every source path appears exactly once there. A sheet may name another packet's public function, but may not
edit its file. R9 supersedes R8-07 and all earlier overlapping path prose.

## Required path corrections

|Path|Single owner|Status/decision|
|---|---|---|
|`ios/Sync/SyncTrustStore.swift`|P01|new; trust load, alias journal/fence, historical trust custody|
|`ios/Sync/DomainWireValues.swift`|P01|new; closed wire enums/value validation used by Swift/TS/Python|
|`ios/Planning/PlanningMutationJournal.swift`|P05|existing; planning SQLite mutation/sync envelope transaction|
|`ios/Planning/PlanningFilesystemPublication.swift`|P06|existing; vault publication/observer acknowledgement|
|`ios/Shared/FinanceTravelStore.swift`|P03|new; local travel record persistence only, no replication|
|`ios/Shared/FinanceTravelProjection.swift`|P09|new; read-only finance UI projection from P03 records|
|`ios/Shared/LifeOSReceiptCoordinator.swift`|P18|R8-added; receipt logs, cursor and retry state machine|
|`ios/Shared/LifeOSDataArchiveWriter.swift`|P18|R8-added; R9 typed frame sink and chunk finalization|
|`ios/Shared/LifeOSDataManagement.swift`|P18|R8-added; registry/export/restore/delete composition|

The two missing R9 implementation paths (`SyncTrustStore.swift`, `DomainWireValues.swift`, `FinanceTravelStore.swift`,
`FinanceTravelProjection.swift`) are explicit new files; a Luna worker creates them only in the owning packet. The two
existing Planning paths stay in their listed owners. No `UsageSyncAdapter`, `ClipperSyncAdapter`, travel replication
adapter, second SQLite database, `SyncLedgerV1` file or generic advisor path is allowed.

P03's travel symbols are exactly the R6-02 signatures `FinanceTravelStore.recover/load/append/update/delete` and
`FinanceTravelProjection.project`; P09 calls them through the public actor/projection boundary and never persists a
second copy. R7's 26-pack adapter wraps that same P03 store under `financeTravel` with `syncPolicy=never`.

## Canonical P00–P18 table

|Packet|Owns the implementation boundary|Dependencies|
|---|---|---|
|P00|requirements/evidence ledger and baseline coordination docs|—|
|P01|`ios/Shared/SyncContract.swift`; `ios/Sync/{SyncWireCodec,SyncIdentityStore,SyncTrustStore,DomainWireValues,SyncTransport,SyncEngine,SyncDomainAdapter}.swift`; contracts package|P00|
|P02|gateway/relay HTTP handlers, `validate_http_frame`, nonce fence, SQLite server store|P01|
|P03|CalendarStore/Domain/Coordinator; Finance durable stores; `FinanceTravelStore`; Calendar/Finance adapters|P01|
|P04|FitnessTraining, Nutrition, Supplement, Journal/Lifestyle stores and adapters|P01|
|P05|existing graph candidate plus `PlanningMutationJournal` and its SQLite transaction|P00|
|P06|native graph/vault UI, `PlanningFilesystemPublication`, vault observer and Planning adapter|P01,P05,P07|
|P07|tokens, SF Pro/SF Symbols, motion/orb/transition primitives|P00|
|P08|Calendar view/reducer, item gestures, V5 viewport types and interaction evidence|P03,P07|
|P09|Finance UI, Enable Banking/import/recurrence/wealth projections, `FinanceTravelProjection`|P03,P07|
|P10|Fitness/workout/Nutrition UI and Zepp/HealthKit presentation|P04,P07|
|P11|HealthKit provider and read-only outage observation relay|P04|
|P12|usage provider capability model and Usage UI|P07|
|P13|Tax store/sanitization/export UI and Tax adapter|P01,P07|
|P14|widgets, Lock Screen, App Intents, shortcuts and personal install|P03,P04,P07,P11|
|P15|dead-code removal, security hardening and review evidence|P02,P08,P09,P10,P12,P13|
|P16|app/target composition, endpoint registration and shared lifecycle|P02,P03,P04,P06,P08,P09,P10,P11,P12,P13,P14|
|P17|Windows gateway/service/DPAPI and outage return|P02,P15|
|P18|receipts, R9 archive writer/management, release/QA orchestration|P15,P16|

P01 owns schema/signing declarations; P02 owns only the transport carrier; P03/P04/P05/P06/P13 implement domain
adapters; P18 consumes their public target-marker methods. P09 never edits P03 stores, and P06 never edits P01 codec.
The `14-OWNERSHIP.json` lists exact files, status and historical SHA; its `__meta.revision` is 9 and its contract
sheet list is R9-01 through R9-06. This resolves retained R4–R8 references by relocation, not by duplicate aliases.

## Capacity and backpressure contract

|Input|Hard result|
|---|---|
|ordinary archive file `>4 MiB`|`ordinaryFileTooLarge`; reject before file header, retain source and cursor|
|domain envelope `>32 MiB`|`domainEnvelopeTooLarge`; reject before decode/header; never create schema-valid undecodable state|
|one chunk `>1 MiB`|`chunkTooLarge`; no partial reference|
|ordinary archive total `>256 MiB`|`archiveTooLarge`; no final artifact|
|HTTP signed body `>2 MiB`|P02 `413 capacity`; read incrementally and stop allocation|
|domain envelope decoded bytes `>32 MiB`|codec `capacity` before projection|
|sink queue above 2 frames or 2 MiB|producer awaits; programming overflow is `backpressureExceeded`, never drop/reorder|
|disk full during chunk/manifest/fence|`diskFull`; last receipt cursor and old authoritative store survive|

Domain envelopes may be streamed as canonical JSON or opaque bytes in <=1 MiB chunks until 32 MiB. Ordinary files use
the 4 MiB limit even if chunking would technically fit. The sink's `accept` is the only producer boundary, and every
caller awaits it before creating the next frame. Capacity errors are typed, persisted in the owning receipt and are
retryable only after the input or available capacity changes.

## Boundary acceptance

The ownership audit is complete only when `jq empty 14-OWNERSHIP.json` passes, no path occurs twice, every R9 type has
one declaration sheet, and a worker can trace `CalendarCoordinator → CalendarStore`, `SyncEngine → adapter`,
`LifeOSDataManagement → source → R9 sink`, and `P02 HTTP → P01 verifier` without crossing an allowlist boundary.
The remaining release evidence (live gateway, physical devices, vault permission, signing and visual review) is
external evidence, not an unsealed ownership decision.

## Revision10 supersession

R10-01, R10-02, R10-03, R10-04 and R10-05 are the current detailed contracts for the affected P05,
P02, P08/P03, P18 and archive-capacity boundaries.

## Revision12 supersession

R12-01 and R12-05 are now current for this ownership boundary: `SyncTrustStore.swift` is P01-only, P05 depends
on P01 for the injected Planning SQL port, and the R12 worker dispatch controls all trust/Planning edits.
