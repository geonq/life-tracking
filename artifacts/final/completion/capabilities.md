# P00 completion inventory

Observed 2026-09-21 Europe/Berlin from the LifeOS repository. P00 performed
no source edits, builds, installs, xcodegen, fetch, Windows SSH, bank access,
vault access, or physical-device access.

## Git and registry truth

- Branch: main
- HEAD: 328b18e16bcbb5856db40b0ffd3f90101a051096
- Local origin/main: 328b18e16bcbb5856db40b0ffd3f90101a051096 (observed locally; no fetch)
- Worktree: eight untracked D1 candidate files; no tracked diff.
- Frozen registry: 258 unique leaves, 7 aliases, 0 accepted; registry hash
  bbea06f1f1d0cc874c8ac605cba920fd4a539b2286baaaf73e0cb7299cbd87c1.
- Reference crosswalk and materialized registry IDs match exactly. Duplicate
  ID/alias checks pass. Old source/reference links remain as pending evidence
  rows; they do not count as acceptance receipts.
- Ownership inventory: 203 unique paths; 145 existing and
  hash-matched to the committed ownership manifest; 58 expected
  new/unpublished paths remain absent.

## D1 candidate hashes

The eight D1 files match their R20 ownership fingerprints, but remain
untracked and have no implementation acceptance receipt. packet-d-design is a
design receipt only; packet-c-publication is the accepted local adapter
prerequisite, not D1 acceptance.

| Path | Current SHA-256 | Receipt/status |
|---|---|---|
| ios/LifeOSMacSnapshotTests/PlanningCanvasSessionTests.swift | 009a777a52be8f8a938a721553f20e989d2f9ab2b744b773f7b97cafd2b11b86 | untracked candidate; no execution receipt |
| ios/LifeOSMacSnapshotTests/PlanningGraphTests.swift | 17fe3f25655a9fdfbe4c4aff503b3f9b60e23aa27a64ac7ba18827e38431c2fc | untracked candidate; no execution receipt |
| ios/LifeOSTests/PlanningGraphTests.swift | 739c0fb7297b8e0d4895479ea34cb7e8e54bfc102660385bfb8909d94fefda4f | untracked candidate; no execution receipt |
| ios/Planning/PlanningCanvasEdit.swift | f8f8c620fc00e783d4640e537021f2745ee4420f552b6a8cee30bf162bfd555a | untracked candidate; no execution receipt |
| ios/Planning/PlanningCanvasSession.swift | 1f00eb56ab76ab84cc0bcab1de0bb42402510b22ed8d20690643ba293569dc85 | untracked candidate; no execution receipt |
| ios/Planning/PlanningGraphProjection.swift | 7f3d7ec050dcdcf771f87cda1ea1224b218fbb01b63f2150bcabb961c8873d58 | untracked candidate; no execution receipt |
| ios/Planning/PlanningMarkdownLinks.swift | 113721e4cd549233f5ff54c29189c589da0a37eb73deb9cbaa05f3f8b722cb35 | untracked candidate; no execution receipt |
| ios/Planning/PlanningSpatialIndex.swift | 775baa5311fd8f23d0cd01b0dd99b34ec3ce9e024773701cbd4fbfa9103302e0 | untracked candidate; no execution receipt |

D1 design receipt: artifacts/final/planning-core/packet-d-design-20260919.md
SHA-256 c05a76ec86d7a1b0bf45347ff8b4f33daf56dbbe2aa05bff861ca6dcd8deb5ce.
D1 execution acceptance: unavailable; P05 must review these exact bytes and
produce its own focused evidence.

## Receipt inventory

| Receipt | Receipt SHA-256 | Declared source SHA | Scope state |
|---|---|---|---|
| artifacts/final/T0/calendar-security-reconciliation.md | 15aac158db07e576262ace4aa02d8b6a838273093562440746b0862255ec0f2c | e07a0a43a015ab8682ec9c4e32a00bb6d6b24dd2 | pass (I) |
| artifacts/final/T0/security-findings.md | f6d564d65e35beba917a6425d463f6ad2cf2cf8ab79f864ba3c4222ab5715bdc | not declared | pass (S) |
| artifacts/final/T0/t1-a1-review.md | 10f8115ec42a02db077785180b7d3fec9eed244566a83904043f5a5c8a8ed14b | cb9c621e29d2662ec1fe3e34a10f81cec305e1f8 | fail (W) |
| artifacts/final/T0/t10a-capability-preflight.md | a862a4e2f55bf3ed95a0cb3fddd5ea068bac0d1bf9d4e300f26b8af3961831d3 | 8ab5739abdff59dc901aa61c942463dfee0f0186 | pass (S) |
| artifacts/final/planning-core/packet-a-repair-20260919.md | 735fba173d3afab1097f73f8463e0286ec64cd123e5ce9d282a187463bd2c9f0 | e9a2a2c3341aa97b14220fb7b133bc6849c61019 | pass (L) |
| artifacts/final/planning-core/packet-b-publication-20260919.md | 9b8329c4a57d4a9ef7ad4098cd09bd8ec9bd6545534d510590f66374a2c74840 | 298628ff3e7694b88d17f5624b56bdb7e0ae661e | pass (L) |
| artifacts/final/planning-core/packet-c-publication-20260919.md | b30c5287703ef5abc0c9f62eb5618cdcf37ffa5828861085a6ccbd7ef36a27e8 | 490f39c435e1f6c01563f8548a7d91c62848a5ea | pass (L) |
| artifacts/final/stability/2026-09-18-lifeosmac.md | ce8dbcca0b26d0df35331108c63085e118152ac66fcc723488d406997ca3dbd3 | not declared | pass (M) |
| artifacts/final/windows/preflight-4db1eaa-20260918.md | 620ed6af2ef666e743e6e5808de099700c0c28ab4efaaba8cf7663df377f3399 | 4db1eaa35766fecce7cbdfa48309db4bf9f89f24 | pending (W) |

## Checkpoint contradictions resolved

- Historical `01-BASELINE.md`, R2 material, and older coordination notes name
  earlier refs such as `d3e62b7`, `321a2b5`, and `5dae724`; the observed
  HEAD and local origin/main are `328b18e...`. P00 uses the observed ref as
  the baseline and retains old locators only as historical/pending evidence.
- `14-OWNERSHIP.json` has fingerprints for the eight D1 paths while Git
  reports those paths as untracked. P00 records their exact bytes and hashes
  but does not promote them to accepted implementation.
- The capability-preflight receipt has its own declared source SHA and
  predates the current Xcode/SDK 27 observation. P00 does not rewrite or
  broaden that receipt; current host facts are observation-only and runtime
  queries remain unknown.
- Earlier Windows availability statements conflict with this packet's explicit
  no-contact constraint. P00 records Windows as unknown/unavailable and keeps
  the prior STOP/NO-GO receipt in its declared scope.

## Host, SDK, signing, and external capabilities

- Host observed: macOS 26.6.2 build 25G83, arm64.
- Xcode observed: 27.0, build 27A266a; iPhoneOS and macOS SDK settings files
  report 27.0. xcrun SDK/simulator queries were blocked because the
  Xcode/SDK license is not accepted; this is a tool precondition, not proof
  that the SDK is denied.
- Code-signing identities: 0 valid identities found; provisioning-profile
  directory absent. Personal signing/App Group/HealthKit/widget profile
  capability is therefore denied for this account at this observation.
  Source entitlements remain source-only.
- Simulator/physical iPhone runtime: unknown in P00 because CoreSimulator and
  devicectl were blocked by the same license precondition; no install or
  runtime claim is made.
- Windows/Tailscale: unknown/unavailable by explicit task constraint; P00 did
  not contact the host. The prior Windows preflight remains STOP/NO-GO and is
  retained as evidence.
- Enable Banking, Trade Republic, Robinhood, Zepp/HealthKit permissions,
  selected iCloud vault, Apple App Group registration, and live provider
  quotas: unknown, not denied and not fabricated.
- Unsupported boundary: proprietary Zepp readiness/load/PAI/Training Effect
  parity and generic advisor/conversational AI remain unsupported by product
  policy; calorie-photo estimation is the only permitted in-app AI.

## Ledger summary

- sourceStatus counts: {'partial': 183, 'missing': 75}
- Evidence entries: classes {'S': 573, 'L': 259, 'P': 158, 'M': 113, 'W': 91, 'I': 13, 'U': 2}; states {'pending': 1053, 'pass': 127, 'fail': 27, 'unsupported': 2}.
- Complexity: ledger construction is O(files + requirements + receipt bytes);
  current source hashing is O(total bytes of existing owned files). No source
  parser or build was used.
- The ledger does not claim application completion, runtime acceptance,
  security green-light, or a completion percentage.

## First dependency sequence

1. P01 seals shared replication DTOs/codecs, key custody, and exact R20
   declarations; no dependent packet guesses missing signatures.
2. P02 builds the signed local relay/gateway against P01 contracts; Windows
   deployment remains separate and unavailable.
3. P03 adapts calendar/finance stores; P04 adapts fitness/local records.
4. P05 accepts or repairs the eight D1 candidates; P06 then owns native graph/
   vault integration after P05 and P01.
5. P18-I integrates receipt/archive authority after P01/P06/P15; P16 composes
   targets after packet interfaces are stable; P18-E and P17 provide final
   evidence only when their environments are available.
