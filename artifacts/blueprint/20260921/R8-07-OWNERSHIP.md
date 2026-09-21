# R8 canonical packet ownership and dependency table

Planning-only. This sheet supersedes the inaccurate packet table in R7-06. The exact source-edit allowlist remains the
file arrays in `14-OWNERSHIP.json`; a path may appear in one packet only. R2 packet sheets are historical dispatch notes,
not a second allowlist. R8 documents are planning inputs and are not source files.

|Packet|Canonical responsibility|Dependencies|R8 contract ownership / boundary|
|---|---|---|---|
|P00|Baseline, capability and context reconciliation|—|R8 process/index evidence; no domain implementation|
|P01|Replication contracts, codec, trust, IDs and transport engine|P00|R8-01/02/03; SyncOperation, aliases, inbox/ACK/frontier interfaces|
|P02|Signed relay and Windows gateway replication|P01|HTTP/Tailscale framing and relay; passes P01 signed bytes through|
|P03|Calendar and finance durable stores/adapters|P01|R8-04 Calendar commands/delete; Calendar/Finance store transactions and pack sources|
|P04|Fitness and local record durable adapters|P01|Fitness/training/nutrition stores, Zepp/HealthKit payload adapters and pack sources|
|P05|Existing graph candidate acceptance|P00|Graph data-model candidate only; no graph UI or vault filesystem ownership|
|P06|Native graph and Obsidian/iCloud vault integration|P01,P05,P07|Planning adapter, vault links/graph projection, planning pack source|
|P07|Shared visual, motion and orb foundation|P00|Design tokens, SF Symbols, native transitions/orb renderer; no feature persistence|
|P08|Calendar interaction and visual repair|P03,P07|Gesture reducers/viewport UI; calls P03 command builder, never stores directly|
|P09|Finance product integration|P03,P07|Enable Banking, imports, recurring/manage UI, Trade Republic, Robinhood/wealth and Finance views|
|P10|Fitness and nutrition product|P04,P07|Workout UI, nutrition and calorie-photo-only AI presentation; calls P04 stores|
|P11|HealthKit workout export/reconciliation|P04|HealthKit authorization/export and Zepp reconciliation evidence|
|P12|Usage product capability model|P07|Claude/Gemini/provider capability registry and Usage UI; no generic advisor AI|
|P13|Tax retention and product|P01,P07|Tax store/CSV/privacy projection and tax pack source|
|P14|Widgets, intents and personal installation|P03,P04,P07,P11|All widget projections including Lock Screen, App Intents, Shortcuts/signing/install|
|P15|Dead paths and independent security hardening|P02,P08,P09,P10,P12,P13|Findings and fixes only in its allowlisted files; returns domain fixes to owners|
|P16|Application composition and target integration|P02,P03,P04,P06,P08,P09,P10,P11,P12,P13,P14|project.yml, target membership, app composition and dependency wiring|
|P17|Windows deployment and rollback|P02,P15|Service host, ACLs, deploy/rollback, gateway pack sources and outage recovery|
|P18|Final evidence, storage and data-management operations|P15,P16|R8-05 receipts, R8-06 streaming sink, release matrix and storage discipline|

## Non-overlap and call graph

P01 defines protocol types, canonical bytes, signing, alias resolution and adapter interfaces. P02 transports those
interfaces. P03/P04/P06/P13 implement their domain adapters and atomic stores; P09/P10/P14 are product callers and do
not create parallel persistence. P17 owns only Windows service paths; P02 owns the relay boundary. P18 orchestrates
data-management and evidence, while source adapters remain with their domain packets. P07 owns visual primitives;
P08 owns Calendar gesture state; P03 owns Calendar mutation and sync projection. P05 owns graph candidate data, P06 owns
native graph UI/vault integration. P15 may remove dead code or harden only its listed paths and must route a domain
behavior change to the owning packet.

The required R8 contract-to-packet map is: R8-01/P01, R8-02/P01, R8-03/P01, R8-04/P03+P08 (types in P01),
R8-05/P18 (hash primitive in P01), R8-06/P18 (source adapters in P03/P04/P06/P09/P10/P12/P13/P14/P17),
R8-07/P00. A worker receives one packet and its dependencies; if a requested edit crosses a boundary, it stops at the
interface and records an Astra review gate rather than touching the other packet's files.

## Allowlist and dispatch rules

`14-OWNERSHIP.json` revision 8 is the machine-readable authority for packet files, titles and dependencies. Its `files`
arrays are immutable evidence hashes until the owning packet deliberately refreshes them. Before coding, a worker checks
that every planned path is in its packet array, that no path is in another array, and that source status/hash is current.
The only permitted cross-packet changes are interface implementation at the owner and composition/wiring in P16.
Historical R2 manifests, R7 tables and generated project files cannot authorize a new path. P00 records a mismatch;
P16 resolves target membership only after the owner packet provides the implementation symbol.

R8 adds three P18 allowlist entries for the newly specified implementation boundary: `ios/Shared/LifeOSReceiptCoordinator.swift`,
`ios/Shared/LifeOSDataArchiveWriter.swift` and `ios/Shared/LifeOSDataManagement.swift`. They are new files, not edits
to another packet's store. Domain adapters remain in their existing P03/P04/P06/P09/P10/P12/P13/P14/P17 arrays.

The JSON top-level `__meta` object is reserved revision metadata and is not a packet. Allowlist readers skip `__meta`,
require exactly P00–P18, and reject unknown packet keys, duplicate paths or a path appearing in two packet arrays.

## Revision9 supersession

R9-06 is the only current ownership table. It adds the previously missing Trust, wire-value, travel-store, projection,
Planning journal and filesystem-publication paths, assigns them once, and carries the final capacity/backpressure rules.
