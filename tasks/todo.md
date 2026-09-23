# TODO — LifeOS completion gates

Updated 2026-09-23 Europe/Berlin. Release: NO-GO.
Latest pushed checkpoint: 09f5575 (CP-B Batch B); main and origin/main are
synchronized. Astra static review and 57/57 focused iOS 27 tests passed. Focused FitnessTrainingStoreTests pass 57/57 on iOS 27. The broader lane
selected iPhone 17/iOS 26.5 and completed 1,621/1,640 with 19 Planning/HealthKit
failures; the full-suite gate is not green.
Use artifacts/final/completion/requirements.json instead of percentages.

## P00 complete

- Reconciled HEAD, local origin/main, branch, registry, reference crosswalk,
  258 unique leaves and 7 aliases.
- Recorded current source hashes against the 203-path ownership manifest.
- Recorded all eight D1 hashes and the design/prerequisite receipt boundary.
- Recorded host, Xcode 27, SDK 27, signing/profile, simulator and external
  capability facts with unknown distinct from denied.
- Preserved old source/reference links as pending evidence; no acceptance was
  inferred from files, fixtures, or historical receipts.
- Wrote compact coordination state. No source, blueprint, build, install,
  fetch, SSH, provider, vault, or physical-device operation was performed.

## Completed execution checkpoints

- P01 shared sync foundation and cross-language R20 contract correction:
  a21ccf3, 673dc0a. TypeScript contract tests: 219 passed.
- P02 durable replication core: a629ad3. Focused Python tests: 5 passed.
- P02 loopback relay and Astra-reviewed bounds/security corrections: 1f65326.
  Focused relay tests: 5 passed.
- P02 strict Swift-compatible signed-frame verification: 83365b1. Focused
  replication tests: 8 passed, one crypto-dependent skip on this Mac.
- P02 authenticated gateway exchange: 038cd37. Nested operation/ack signatures,
  pinned membership, dependency-aware byte-bounded paging, contiguous device
  frontiers, separate acknowledgement cursor progression, stream-head/index
  migration, and original-schema regression are covered. Focused suite: 21
  passed, one cryptography-dependent skip.
- P03 calendar codec/target activation: e76be67. Strict bounded series payload,
  deterministic ordering, wire-boundary NFC normalization, and icon hash-before-
  ImageIO validation are checked in.
- P03 durable calendar replication: 9d222ac. Calendar store/adapter/composition,
  authenticated ACK separation, replay-anchor durability, safe compaction,
  missing-parent conflict retention, frontier pagination safety, and focused
  regressions are reviewed and pushed. API tests are 160/160; gateway is 23
  passed with one crypto-dependent skip.
- P04 fitness payload boundary: b0e52e1. Training payload serialization uses a
  strict tagged root, bounded local canonical JSON, NFC wire normalization,
  finite/fractional numeric handling, and direct parser/domain regressions.
  Durable store adapters are not included in this checkpoint; Astra static
  review passed. The native Mac lane is green; iOS and physical-device
  evidence remain open.
  CP-B's contract is sealed; B is pushed at 09f5575. C/D remain ahead and
  E production registration stays blocked by its explicit trust gates.
- P05 D1 graph/session checkpoint: ca2caf1. Bounded Markdown link scanning,
  graph projection, spatial indexing, Canvas reducer/session state, atomic vault
  access-context validation, and focused regressions are reviewed and pushed.
  Markdown Canvas edits are rejected before mutation; source replacement remains
  supported. Xcode 27 native Mac evidence is 379/379 tests passed; iOS
  simulator, signing, physical-device, and external-provider evidence remain
  open.

- Xcode 27 compatibility checkpoint: 0451afb. URL-safe Base64 decoding, actor
  isolation compatibility, and focused protocol regressions are pushed. The
  full LifeOSMacLogic suite passes 379/379. The follow-up native persistence
  checkpoint 80579bc canonicalizes calendar bytes before commit and keeps the
  global Finance date codec unchanged; LifeOSLogic passes 1,837/1,837 on the
  iOS 27 iPhone 17 simulator.

- P06-A native Canvas checkpoint: `4ff27e3`. Native viewport, AppKit/UIKit
  input bridge, owner tokens/touch quarantine, shared geometry, cached
  presentation queries, retry recovery, and interaction regressions are pushed
  after Astra PASS. Main macOS evidence is 405/405 full and 19/19 focused;
  final worker iOS focused evidence is 18/18 and generic iOS builds pass.

- P06-B planning workspace transaction checkpoint: `86baaa8` source with
  synchronized documentation. Read-only Calendar-to-Obsidian Canvas routing,
  bounded composite/pending/decision selection persistence, revoke durability,
  initialize/attach/restore resource ordering, journal readiness, and mirrored
  failure regressions are implemented. Astra medium review passed; focused
  Xcode 27 evidence is 107/107 macOS and 62/62 iOS simulator tests.

- P06-B read-only node inspector: `454f4d1`. Selected-node metadata, exact
  in-vault Markdown preview/refresh, Mac/iPhone presentation, and lifecycle/path
  guards are pushed after Astra medium READY TO CHECKPOINT. Mac focused evidence
  is 73/73. The iPhone run passed all inspector tests, while four older
  workspace tests failed after offline-host network timeouts; no full iOS green
  claim is made.

- P06-B existing-document chooser: `433ea64`. Native Mac/iPhone selection of
  one existing `.canvas` or `.md` under attached `LifeOS/`, bounded path and
  symlink checks, cancellation/failure preservation, read-only Markdown preview,
  retry-state cleanup, and mirrored contract regressions are pushed after Astra
  medium READY TO CHECKPOINT. Swift parsing and both arm64 build-for-testing
  lanes pass; testmanagerd/CoreSimulator blocked runtime picker evidence.

- P06-B picker lifecycle hardening: `1df4642`. Astra medium found no P0–P3
  issue after correction. AppKit sheet completion ownership, UIKit ancestor-safe
  dismissal, pre-presentation cancellation, static owner-token teardown,
  SwiftUI task gating, retry disabling, and sanitized picker errors are pushed.
  macOS and iPhone 17 arm64 build-for-testing pass; mounted/runtime evidence is
  still open. The next exact contract is `tasks/p06b-mounted-picker-plan.md`.

- P06-B lifecycle evidence checkpoint: 4436211. Owner-token presenter
  storage avoids SwiftUI reconciliation writes; mirrored DEBUG hosted tests
  cover lifecycle, picker races, viewport retention, and fixture safety. Astra
  medium READY; macOS hosted suite 15/15 with zero runtime warnings, plus fresh
  macOS and iPhone 17 arm64 build-for-testing. Native picker presentation and
  real-vault runtime evidence remain open.

## Ordered implementation

1. Finish the selector fix and repair the known Planning/HealthKit test failures;
   rerun the full logic lane on iOS 27 before calling that gate green.
2. Implement CP-B C/D with injected bindings and durable local application;
   keep production registration blocked until E's trust gates pass.
3. Continue P06-B native picker presentation and real-vault round-trip evidence
   from tasks/p06b-mounted-picker-plan.md.
3. P07 shared visual/motion primitives; P08 calendar; P09 finance; P10 fitness;
   P11 HealthKit/Zepp provenance; P12 usage; P13 tax; P14 widgets/intents.
4. P15 security/dead-path hardening; P16 composition and target membership.
5. P18 receipt/archive authority and final Mac/simulator evidence; P17 Windows
   deployment/live providers when the PC returns; P18-E final release evidence.

## Release gates still open

- iOS 27 simulator/runtime UI, signing, App Group, Shortcuts and physical
  iPhone behavior. Focused store tests pass; the broad logic suite has 19
  failures on iOS 26.5 and needs a full iOS 27 rerun.
- Windows identity/ACL/service/Serve/health/readiness/restart/rollback.
- Enable Banking, Trade Republic, Robinhood/net-worth, outage/rejoin and live
  provider readback.
- Obsidian real-vault/iCloud round trip, native graph gestures and transport.
- Mounted native document picker, viewport preservation, and retry/cancellation
  behavior on Mac and iPhone.
- LifeOS workouts plus physical HealthKit/Zepp comparison; proprietary Zepp
  metrics remain unavailable without legitimate provenance.
- Whole-app visual/motion review, measured performance, adversarial security,
  storage cleanup, and final registry acceptance.
