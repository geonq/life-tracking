# HANDOFF — LifeOS native app

Updated 2026-09-12 Europe/Berlin.

## Release state

**NO-GO.** The Usage visual/source, macOS route, and personal installer
security slices are GREEN. Runtime, live provider, whole-app visual, physical
device, and end-to-end security evidence is still incomplete.

## Current source checkpoint

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD and origin: `1d1af18 Harden personal device installation flow`.
- macOS now has one value-driven Home `NavigationStack` with a bounded typed
  path. Sidebar Home resets it; Back pops one detail and preserves origin.
- Cross-module Usage/Finance/Calendar deep links preserve the saved Home
  detail. Calendar editor callbacks are mount-guarded and cancelled on exit.
- Usage packet/authority, omission handling, persistence retry, and bounded
  chart interaction remain GREEN from `7877ec5`.
- Usage hierarchy, compact quota cards, chart legend/controls, responsive
  720/960pt boundaries, and endpoint hit targets are reviewed GREEN at
  `fce94b9`. iPhone focused tests are **95/95**; macOS settled and breakpoint
  renders are **1/1** each, with five rendered captures inspected.
- Verification: iOS focused route/Usage suite **95 tests, 0 failures**;
  macOS route tests **2/2, exit 0**; full macOS snapshot run executed
  **51/51 test cases with 0 failures** before its result-archive I/O crash.
- Windows source suite: **61 passed, 1 skipped, 0 failures**.
- Personal installer security slice: Astra Medium scoped GREEN at `1d1af18`;
  **13/13 tests** and `bash -n` pass. Exact Apple command allowlisting,
  minimal child environment, hostile Python-startup rejection, toolchain
  redirect regression, signed app/widget validation, bounded output, and
  timeout/cancellation checks are covered. Physical signing and install are
  still unverified.

## Still open

- Windows is reachable and BitLocker is fully encrypted/protected. The
  rollback marker has cleared but its PowerShell cleanup process is still
  present; no reinstall retry or live Enable Banking readback is certified.
- Runtime route transitions, whole-app visual captures, calendar gestures,
  widgets, physical iPhone, signing, and Shortcuts.
- Zepp workout fidelity/sync and the Obsidian Canvas mind map; see issue #2.
- Final operational security, transport, and release acceptance checks.

## Boundaries and next action

Keep SF Pro/system styling, compact Linear/Vercel quality, truthful live data,
no generic advisor or in-app AI, and calorie-photo tracking as the only AI.
The old AppKit route-host/raster plan is superseded by the native stack in
`070b7db`. Next: continue the whole-app visual/runtime pass, then close the
Windows backend, live provider, device/signing, Zepp, Obsidian, and security
gates with evidence.
