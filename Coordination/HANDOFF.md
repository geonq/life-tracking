# HANDOFF — LifeOS native app

Updated 2026-09-12 Europe/Berlin.

## Release state

**NO-GO.** Usage and the macOS route source slices are GREEN. Runtime, live
provider, visual, security, and device evidence is still incomplete.

## Current source checkpoint

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD and origin: `070b7db Repair macOS native route lifecycle`.
- macOS now has one value-driven Home `NavigationStack` with a bounded typed
  path. Sidebar Home resets it; Back pops one detail and preserves origin.
- Cross-module Usage/Finance/Calendar deep links preserve the saved Home
  detail. Calendar editor callbacks are mount-guarded and cancelled on exit.
- Usage packet/authority, omission handling, persistence retry, and bounded
  chart interaction remain GREEN from `7877ec5`.
- Verification: iOS focused route/Usage suite **95 tests, 0 failures**;
  macOS route tests **2/2, exit 0**; full macOS snapshot run executed
  **51/51 test cases with 0 failures** before its result-archive I/O crash.
- Windows source suite: **61 passed, 1 skipped, 0 failures**.

## Still open

- Remote recovery/install, service listeners, health, Tailscale Serve, and
  live Enable Banking consent/account/transaction readback.
- Runtime route transitions, visual captures, compact hierarchy, gesture
  behavior, widgets, physical iPhone, signing, and Shortcuts.
- Zepp workout fidelity/sync and the Obsidian Canvas mind map; see issue #2.
- Final operational security, transport, and release acceptance checks.

## Boundaries and next action

Keep SF Pro/system styling, compact Linear/Vercel quality, truthful live data,
no generic advisor or in-app AI, and calorie-photo tracking as the only AI.
The old AppKit route-host/raster plan is superseded by the native stack in
`070b7db`. Next: capture the actual macOS and iPhone surfaces, fix visual and
gesture issues against `design.md`, then continue backend/device gates.
