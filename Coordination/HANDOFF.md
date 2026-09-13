# HANDOFF — LifeOS native app

Updated 2026-09-13 Europe/Berlin.

## Release state

**NO-GO.** The Usage visual/source, calendar security, macOS route, and
personal installer security slices have passing source evidence. Runtime, live
provider, whole-app visual, physical device, and end-to-end deployment
evidence is still incomplete.

## Current source checkpoint

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD and origin: `6f421f8 Refine Usage hierarchy and facts layout`.
- macOS now has one value-driven Home `NavigationStack` with a bounded typed
  path. Sidebar Home resets it; Back pops one detail and preserves origin.
- Cross-module Usage/Finance/Calendar deep links preserve the saved Home
  detail. Calendar editor callbacks are mount-guarded and cancelled on exit.
- Usage packet/authority, omission handling, persistence retry, and bounded
  chart interaction remain GREEN from `7877ec5`.
- Usage hierarchy, compact quota cards, chart legend/controls, responsive
  720/960pt boundaries, and endpoint hit targets are implemented at
  `6f421f8`. The focused macOS Usage visual run is **3/3 with 0 failures**;
  seven exported PNG attachments were inspected. This is a Usage slice, not
  whole-app visual acceptance.
- Calendar pairing/authentication, bounded envelope negotiation, replay and
  merge rules, mutation fencing, durable store writes, and cross-OS symbol
  fallback are committed at `8942b8e`. The focused iPhone 17 suite is
  **107/107 with 0 failures**; the macOS production build exits 0.
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
- Backend security tranche: Astra scoped GREEN at `87e7db6`; API typecheck and
  the full API suite pass (**15 files, 148 tests**). Secret bounds, Host
  allowlisting, bounded history/atomic writes, and Windows Codex path/quoting
  checks are covered. Native Windows execution, deployed ACL/reparse behavior,
  and Windows rename durability remain unverified.

## Still open

- Windows is reachable and BitLocker is fully encrypted/protected. The
  rollback marker has cleared but its PowerShell cleanup process is still
  present; no reinstall retry or live Enable Banking readback is certified.
- The calendar Astra review found and the source fixed one P2 compatibility
  issue: a valid SF Symbol name unavailable on the receiving OS must survive
  decode and render through a local fallback. The targeted Astra re-review was
  blocked by that worker's inability to read the files, so it is not recorded
  as a green sign-off; local focused tests and the macOS build pass.
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
