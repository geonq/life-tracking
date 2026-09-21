# TODO — LifeOS completion gates

Updated 2026-09-21 Europe/Berlin. Release: NO-GO.
Current checkpoint: b0e52e1.
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
  passed with one crypto-dependent skip. Native Swift evidence is pending the
  Xcode license gate.
- P04 fitness payload boundary: b0e52e1. Training payload serialization uses a
  strict tagged root, bounded local canonical JSON, NFC wire normalization,
  finite/fractional numeric handling, and direct parser/domain regressions.
  Durable store adapters are not included in this checkpoint; Astra static
  review passed and native Swift evidence remains pending the license gate.

## Ordered implementation

1. P04 adapts finance, fitness, nutrition,
   supplements and lifestyle stores with local durability before acknowledgement.
2. P05 reviews the eight D1 candidates against their exact design packet; P06
   adds native Canvas/inspector/vault integration only after P01/P05.
3. P07 shared visual/motion primitives; P08 calendar; P09 finance; P10 fitness;
   P11 HealthKit/Zepp provenance; P12 usage; P13 tax; P14 widgets/intents.
4. P15 security/dead-path hardening; P16 composition and target membership.
5. P18 receipt/archive authority and final Mac/simulator evidence; P17 Windows
   deployment/live providers when the PC returns; P18-E final release evidence.

## Release gates still open

- OS27 compile/runtime, signing, App Group, widgets, Shortcuts and physical
  iPhone behavior.
- Windows identity/ACL/service/Serve/health/readiness/restart/rollback.
- Enable Banking, Trade Republic, Robinhood/net-worth, outage/rejoin and live
  provider readback.
- Obsidian real-vault/iCloud round trip, native graph gestures and transport.
- LifeOS workouts plus physical HealthKit/Zepp comparison; proprietary Zepp
  metrics remain unavailable without legitimate provenance.
- Whole-app visual/motion review, measured performance, adversarial security,
  storage cleanup, and final registry acceptance.
