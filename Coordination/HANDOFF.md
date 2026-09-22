# HANDOFF — LifeOS native app

Updated 2026-09-22 Europe/Berlin.

## Active task

P00/P01/P02/P03, P04 training serialization, P05 D1 graph/session, the Xcode
27 native compatibility checkpoint, the bounded P06-A native Canvas
viewport/input checkpoint, the P06-B planning workspace transaction,
read-only node inspector, and existing-document chooser are pushed. Release
remains NO-GO:
CP-B adapters, signed UI/device evidence, Windows/live providers,
physical-device comparison, remaining UI/motion work, and final security
evidence are still open.

## Current truth

- `main` and `origin/main` are synchronized at source checkpoint `1df4642`;
  the transaction workspace is `86baaa8`, the inspector is `454f4d1`, the
  chooser is `433ea64`, and picker hardening is `1df4642` in that history.
- `codex/p06-b` is synchronized with the same source and documentation state.
- The P00 ledger remains acceptance truth: 258 leaves, 7 aliases, pending evidence.
- P01: `a21ccf3`, `673dc0a`; P02: `038cd37`; P03 durable calendar: `9d222ac`.
- P04 payload boundary: `b0e52e1`; durable fitness adapters remain open.
- P05 D1: `ca2caf1`; bounded Markdown links, graph projection, spatial index,
  edit reducer, canvas session, vault access-context checks, and regressions.
- `0451afb` fixes Xcode 27 public-key decoding, exposes the immutable store URL
  safely across actors, and adds the URL-safe Base64 regression coverage.
- `80579bc` canonicalizes calendar persistence before commit, preserves the
  v1 peer date path, and repairs Xcode 27 test assumptions without widening
  the global Finance date codec.
- `4ff27e3` adds the P06-A native planning canvas viewport, AppKit/UIKit input
  bridge, sequence ownership/quarantine, shared node geometry, presentation
  caching, retry recovery, and platform interaction regressions.
- `454f4d1` adds read-only selected-node metadata, exact in-vault `LifeOS/*.md`
  validation, bounded Markdown preview/refresh, Mac trailing inspection,
  iPhone sheet presentation, and late-result authority guards.
- `433ea64` adds the native existing-document chooser. It accepts exactly one
  existing `.canvas` or `.md` inside the attached vault's `LifeOS/` root,
  preserves the mounted Canvas on cancellation/failure, and routes Markdown to
  a read-only preview. It adds no enumeration, indexing, network, vault write,
  or CP-B behavior.
- `1df4642` hardens the native picker lifetime: no overlapping SwiftUI picker
  task, owner-token guarded representable teardown, ancestor-safe iOS dismissal,
  exactly-once cancellation, and AppKit sheet completion ownership. The
  bounded next plan is `tasks/p06b-mounted-picker-plan.md`.

## Evidence

- API typecheck and 160 API tests pass; gateway replication is 23 passed with
  one cryptography-dependent skip on this Mac.
- Planning source checks, focused harnesses, and semantic test typechecks pass.
- `LifeOSMacLogic` on Xcode 27/macOS 26.6.2 passed all 405 tests, including
  DomainSync, planning durability/filesystem/graph, finance, fitness, widgets,
  snapshots, and usage suites. Native warnings remain in snapshot setup only.
- The final P06-A worker passed 18/18 focused iOS interaction tests and the
  generic iOS build; the pushed mainline generic iOS build also passed. The
  simulator service was intermittent after the run, so no new full iOS count
  is claimed. Signed UI, App Group, physical iPhone, Windows, and live-provider
  evidence remain pending; no claim is made for those lanes.
- P06-B source review passed Astra medium's final gate with no P1/P2 blocker.
  The isolated Xcode 27 macOS lane passed 107/107 focused tests. A fresh iOS
  27 build-for-testing succeeded, and the serial iPhone 17 simulator rerun
  passed 62/62 focused tests: 6 filesystem, 18 interaction, and 38 workspace.
  The first full iOS attempt had two order/timing failures; both tests passed
  alone and the full rerun passed. The rerun is the canonical evidence.
- The inspector patch’s Xcode 27 macOS focused suites passed 73/73 (22
  interaction and 51 workspace). The iPhone 17 run passed all 21 interaction
  tests and every new inspector test; four older workspace tests failed after
  offline-host backend/websocket timeouts. Astra classified the patch READY TO
  CHECKPOINT with no P1/P2 blocker; mounted UI evidence remains open.
- The chooser patch passed Swift parsing, macOS `LifeOSMacLogic`
  build-for-testing, and iPhone 17 arm64 simulator build-for-testing. Direct
  macOS execution was blocked by the testmanagerd sandbox; the iOS simulator
  service refused the focused run. The generic x86_64 simulator build still
  has the pre-existing `PlanningGraphTests` type-check failure. These are
  qualified environment/build facts, not runtime acceptance.
- The picker hardening patch passed Astra's final source gate, Swift parsing,
  macOS `LifeOSMacLogic` build-for-testing, and iPhone 17 arm64
  `LifeOSLogic` build-for-testing. Native mounted presentation, interactive
  dismissal, viewport preservation, and real-vault mutation evidence remain
  unverified.
- The iPhone 17 simulator was shut down after validation; no owned xcodebuild,
  xctest, LifeOS app, or booted simulator process remains. Build outputs and
  result bundles are isolated under `/tmp` and are disposable.

## Next action

Continue with the mounted picker probes and real-vault round trip defined in
`tasks/p06b-mounted-picker-plan.md`. Keep one worker and one Apple lane at a
time; preserve gradual commits, pushes, compact handoffs, and evidence-led
gates. Investigate test-host network isolation separately; do not call
qualified iOS runs green.
