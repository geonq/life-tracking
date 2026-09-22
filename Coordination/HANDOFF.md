# HANDOFF — LifeOS native app

Updated 2026-09-22 Europe/Berlin.

## Active task

P00/P01/P02/P03, P04 training serialization, P05 D1 graph/session, the Xcode
27 native compatibility checkpoint, the bounded P06-A native Canvas
viewport/input checkpoint, and the P06-B planning workspace transaction
checkpoint are pushed. Release remains NO-GO:
CP-B adapters, signed UI/device evidence, Windows/live providers,
physical-device comparison, remaining UI/motion work, and final security
evidence are still open.

## Current truth

- `main` and `origin/main` are synchronized with the validated P06-B
  documentation checkpoint; P06-B source is `86baaa8` in that history.
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
- The iPhone 17 simulator was shut down after validation; no owned xcodebuild,
  xctest, LifeOS app, or booted simulator process remains. Build outputs and
  result bundles are isolated under `/tmp` and are disposable.

## Next action

Continue native graph/vault routing and inspector UI. Keep one worker and one
Apple lane at a time; preserve gradual commits, pushes, compact handoffs, and
evidence-led gates.
