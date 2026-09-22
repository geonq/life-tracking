# HANDOFF — LifeOS native app

Updated 2026-09-23 Europe/Berlin.

## Active task

P06-B native mounted picker presentation and real-vault round-trip evidence,
per tasks/p06b-mounted-picker-plan.md. Release remains NO-GO.

## Current source state

- main and origin/main are synchronized at 4436211. This checkpoint fixes
  SwiftUI presenter ownership during representable updates and adds hosted
  lifecycle regressions. The older codex/p06-b branch is still at 960f030.
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
- Fresh macOS and iPhone 17 arm64 build-for-testing passed. No iOS runtime
  picker evidence is claimed.
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

Implement the six platform presentation tests in the active plan, then run the
bounded hosted macOS/iOS lanes and compare a unique fixture vault manifest
before/after. Keep one Luna xhigh implementation worker and one Apple test
lane active at a time; have Astra medium review before checkpoint. Do not call
build evidence runtime acceptance.
