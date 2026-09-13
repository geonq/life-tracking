# HANDOFF — LifeOS native app

Updated 2026-09-13 Europe/Berlin.

## Release state

**NO-GO.** The Usage visual/source, calendar security, macOS route, and
personal installer security slices have passing source evidence. Runtime, live
provider, whole-app visual, physical device, and end-to-end deployment
evidence is still incomplete.

## Current source checkpoint

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD and origin: `6baa1f3 Reduce recovery resume memory pressure`.
- Finance source checkpoint: `fd8ccfb Refine Finance responsive hierarchy`.
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
- Fitness Recovery hero measurement/placement is repaired at `03a78a1`. The
  focused macOS snapshot test is **1/1 with 0 failures** and its light/dark
  captures were inspected; the iPhone 17 boundary test is **1/1 with 0
  failures**. Separate 900/1200pt Fitness captures remain open.
- Finance responsive hierarchy is repaired at `fd8ccfb`. The complete scoped
  Mac Finance snapshot set is **16/16 with 0 failures**; responsive Mac
  captures at 900/1200/1512/1800 and focused iPhone 17 layout/selector tests
  pass. The corrected patch has an Astra Medium **GREEN** review. Width is
  derived from the enclosing viewport; fixture renders remain explicitly
  labelled and are not production data.
- Verification: iOS focused route/Usage suite **95 tests, 0 failures**;
  macOS route tests **2/2, exit 0**; full macOS snapshot run executed
  **51/51 test cases with 0 failures** before its result-archive I/O crash.
- Windows source suite: **61 passed, 1 skipped, 0 failures**; the pushed
  `6baa1f3` candidate verifier passed **108 files**, and the remote static and
  behavior suites passed.
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

- Windows is reachable and BitLocker was last read fully encrypted/protected.
  The `6baa1f3` rollback was actually run through unit `31,400`; memory stayed
  near **674 MB** versus the earlier **985 MB** peak, but no final stage
  checkpoint appeared after 45 minutes, so it was safely stopped. The durable
  marker remains `active`, the journal remains `artifacts-complete`, and
  `LifeOSAPI` remains stopped. Install and live Enable Banking readback remain
  uncertified.
- Astra rejected an uncommitted follow-up optimization: its second service
  check could delete a service and its validation context had a TOCTOU gap.
  That patch was removed from the tree and preserved at
  `/private/tmp/lifeos-red-runtime-optimization-20260913.patch`; it is not
  part of the release.
- The calendar Astra review found and the source fixed one P2 compatibility
  issue: a valid SF Symbol name unavailable on the receiving OS must survive
  decode and render through a local fallback. The targeted Astra re-review was
  blocked by that worker's inability to read the files, so it is not recorded
  as a green sign-off; local focused tests and the macOS build pass.
- The first Finance worker patch was rejected before commit for a duplicated
  hero hierarchy and a zero-width responsive preference loop; the parent
  replaced it with the viewport-derived implementation above.
- Runtime route transitions, whole-app visual captures at all review widths,
  calendar gestures, widgets, physical iPhone, signing, and Shortcuts.
- Zepp workout fidelity/sync and the Obsidian Canvas mind map; see issue #2.
- Final operational security, transport, and release acceptance checks.

## Boundaries and next action

Keep SF Pro/system styling, compact Linear/Vercel quality, truthful live data,
no generic advisor or in-app AI, and calorie-photo tracking as the only AI.
The old AppKit route-host/raster plan is superseded by the native stack in
`070b7db`. Next: implement and review the non-mutating recovery validation
needed to avoid repeated full-journal scans, then resume recovery and close
live provider, device/signing, whole-app visual, Zepp, Obsidian, and security
gates with evidence.
