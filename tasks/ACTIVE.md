# Active LifeOS execution

Status: IN PROGRESS — updated 2026-09-18 Europe/Berlin.

The authoritative source checkpoint is clean `main` at `d2ece98`, aligned
with `origin/main`. Release remains **NO-GO**. The frozen registry contains
258 leaves, 7 aliases, and 0 formally accepted leaves; this is acceptance
evidence, not an implementation percentage.

## Product authority

- Native SwiftUI/WidgetKit on Mac and iPhone is the product.
- Windows over Tailscale is the private structured-data/document boundary.
- Use truthful live data. Production never silently falls back to fixtures.
- Calendar, Reminders, Obsidian, HealthKit/Zepp, finance and tax retain their
  domain authority; do not create competing mutable stores.
- No generic advisor or conversational AI. Calorie-photo estimation is the
  only in-app AI flow.
- Use SF Pro/system typography, semantic icon abstraction, the brand palette,
  green estimates, orange calories, compact hierarchy, Notion-style calendar
  scrolling/pinch, and interruptible motion with Reduce Motion final states.

## Current evidence

- Finance packets cover institution detection/import, mapping/reimport,
  recurring Manage Payment controls, investment/Robinhood validation, and
  bounded live-readback parsing. They are source-reviewed and locally tested;
  live provider acceptance is still open.
- Usage packets cover provider-neutral registry management, Claude retention,
  manual Gemini subscription readings and compact hierarchy. Gemini API and
  Gemini subscription are separate products; automatic subscription quota is
  unsupported without an official endpoint.
- Windows disposable recovery/source suites and the storage guard pass. The
  canonical host currently has Tailscale and BitLocker healthy but LifeOSAPI
  stopped, LifeOSGateway absent, no LifeOS listener, and only the legacy sync
  task Ready.
- The current serial Mac logic lane is **193/193 passed**. A focused stability
  lane is **1/1 passed** while an isolated manual LifeOSMac build stayed open.
  The three old `EXC_BAD_ACCESS` reports belong to temporary XCTest hosts; a
  separate `SIGABRT` came only from an invalid direct-Mach-O launch. The normal
  LaunchServices fixture produced no new crash. Manual visual checks now launch through
  `scripts/launch_macos_visual_fixture.sh` under a dedicated bundle ID, so
  UI-test relaunch cleanup cannot close the inspected app. Receipt:
  `artifacts/final/stability/2026-09-18-lifeosmac.md`.
- Generic iOS SDK/build-for-testing compiles; CoreSimulator is unavailable and
  physical iPhone/runtime evidence remains open.
- Mac Home composition is pushed at `d2ece98`: the reviewed populated and
  unavailable dark snapshot matrix passes at 800x600, 1200x800, and 1512x982;
  geometry checks pass **2/2** and six kept captures were manually approved.
- The bounded Obsidian Canvas/Markdown codec and value binding packet is pushed
  at `f53c77c`; focused tests are **31/31**, the independent smoke harness
  passed, and the post-commit Mac logic lane is **193/193**. Durable vault
  storage, conflicts, graph/UI, gateway transport, and sync remain open.

## Remaining work

1. Finish canonical Windows candidate/preflight, supervised recovery/install,
   service/ACL/Serve/health/readiness/listener verification, and rollback.
2. Verify real Enable Banking values, consent/revoke/freshness, recurring
   reconciliation, Trade Republic import, and Robinhood/net-worth separation.
3. Build on the committed Obsidian Canvas codec with durable vault storage,
   journal/conflicts, graph/spatial index, native views, bounded gateway route,
   and live round-trip wiring.
4. Verify LifeOS-owned workouts and physical Zepp/HealthKit provenance;
   leave proprietary Zepp fields unavailable without evidence.
5. Verify lock-screen and existing widgets, App Group, signing, background
   refresh, and honest Morning Sync/USB Refresh Shortcuts on the iPhone.
6. Perform route-level visual/motion review and the final Astra security
   review, then close all release-blocking findings.

## Worker contract

Luna Max receives one exact disjoint file set at the current SHA. Astra Medium
reviews the actual diff and evidence after each meaningful batch. Every worker
returns changed paths, tests/exit codes, evidence paths, complexity, and open
uncertainty. Unexpected scope, a data-authority conflict, a destructive
migration, or a reproducible crash stops the tranche.

Every accepted tranche is committed and pushed to `main`, checked for local /
remote SHA parity, and reflected in `Coordination/HANDOFF.md`,
`Coordination/PHASE_STATUS.md`, and this file. Apple lanes use one serial
`xcodebuild` process with the storage guard; quiet compilation continues until
the explicit result. Completed disposable processes and caches are cleaned
through targeted, owned paths only.

See `tasks/final-execution-plan.md` for exact file ownership, dependencies,
tests, evidence and stop conditions.
