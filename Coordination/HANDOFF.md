# HANDOFF — LifeOS native app

Updated 2026-09-23 Europe/Berlin.

## Active task

P06-B native picker implementation is checkpointed; runtime presentation
and isolated vault round-trip evidence remain open. Release remains NO-GO.

## Current source state

- main, origin/main, and codex/p06-b are synchronized. Native picker source
  and mirrored tests are checkpointed at 7cc189f. Runtime evidence remains
  open as described below.
- P01–P05 foundations are in main: authenticated sync, durable calendar,
  fitness payload boundary, graph/session, and native Canvas viewport.
- P06-B prior checkpoints: workspace transaction 86baaa8, inspector
  454f4d1, chooser 433ea64, picker lifecycle hardening 1df4642, hosted
  source probes c4243a3.
- 4436211 stores the native presenter weakly behind owner-token attach/detach,
  avoids state writes during SwiftUI representable updates, and keeps
  isMounted synchronous without publishing unused observation changes.
  DEBUG-only probes exercise mounted view lifecycle, picker actions, viewport,
  inspector, and readiness. macOS/iOS tests are mirrored.

## Verification

- Astra medium reviewed the source patch READY with no P0–P3 findings.
- Xcode 27 / macOS 27.0 focused hosted suite: 15 passed, 0 failed,
  0 runtime warnings. This includes the idle-hosted restore regression and
  ten mounted chooser/workspace cases.
- Astra medium returned READY TO CHECKPOINT with no actionable findings.
  Swift parse, diff-check, and mirrored-suite parity pass. Serial arm64
  build-for-testing passes for LifeOSMacLogic on macOS 27 and LifeOSLogic for
  iOS Simulator.
- Runtime remains unverified. The prior macOS picker run was canceled during
  XCTest LaunchServices worker startup with zero tests executed. Current
  simctl cannot connect to CoreSimulatorService or discover runtimes. No
  native picker runtime result or real-vault round trip is claimed.
- Both serial build sessions exited; 24 GiB remained available on the volume.
- Earlier mainline evidence remains: LifeOSMacLogic 405/405; focused iPhone 17
  P06-B suite 62/62. API tests 160/160; gateway replication 23 passed with
  one crypto-dependent skip.
- No owned xcodebuild, xctest, or LifeOSMac process remains. Old project-scoped
  temporary intermediates were removed, reclaiming about 11 GiB; active test
  bundles and current build caches were retained.

## Limits and next action

Native AppKit/UIKit picker presentation, interactive cancellation, actual
production-vault round trip, signed device/App Group behavior, Windows/live
providers, physical iPhone, whole-app design/security gates, and final
registry evidence remain open. The hosted chooser tests use controlled
selection closures and fixture vaults; they do not prove native picker
presentation or access to the user's real vault.

Next implement the closed SyncStoreKind registry and exhaustive domain/
wire tests in SyncContract.swift and SyncProtocolTests.swift. Keep durable P04
adapters paused until Astra seals the CP-B training bridge contract. Retry
native picker runtime and isolated vault-manifest evidence when LaunchServices
and CoreSimulator are available. Keep Apple lanes serial; builds are not runtime
acceptance.
