# HANDOFF — LifeOS native app

Updated 2026-09-14 Europe/Berlin.

## Release state

**NO-GO.** The Usage visual/source, calendar security, macOS route, and
personal installer security slices have passing source evidence. Runtime, live
provider, whole-app visual, physical device, and end-to-end deployment
evidence is still incomplete.

## Current source checkpoint

- Application source checkpoint: `e07a0a4 Harden calendar remote merge boundary`
  layered over `e8bbefa Refine compact usage presentation and chart contract`;
  Windows recovery-instrumentation checkpoint: `0a8d5b6`;
  historical deployable code candidate: `6baa1f3`. Mainline contains
  implementation merge `c09c3b7` plus subsequent documentation syncs; later
  documentation-only commits may advance main without changing the application
  source. GitHub CLI reports PR #1 merged into `main` at `c09c3b7`.
- Finance source checkpoint: `fd8ccfb Refine Finance responsive hierarchy`.
- macOS now has one value-driven Home `NavigationStack` with a bounded typed
  path. Sidebar Home resets it; Back pops one detail and preserves origin.
- Cross-module Usage/Finance/Calendar deep links preserve the saved Home
  detail. Calendar editor callbacks are mount-guarded and cancelled on exit.
- Usage packet/authority, omission handling, persistence retry, and bounded
  chart interaction remain GREEN from `7877ec5`.
- Usage hierarchy, compact quota cards, chart legend/controls, responsive
  720/960pt boundaries, and endpoint hit targets are implemented across
  `33c74c9` and `e8bbefa`. The latter keeps empty-history range selection
  reachable, preserves connector-specific recovery states, and applies the
  224/256pt Mac chart contract. Astra Medium reviewed the corrected candidate
  **GREEN**; the serialized Mac production build succeeded and the exact
  artifact was inspected. The focused test harness compiled the candidate but
  could not start XCTest because the sandbox blocked `testmanagerd`; no
  assertion failure was observed. This is a Usage slice, not whole-app visual
  acceptance.
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
  `6baa1f3` candidate verifier passed **108 files**. Native PowerShell 5.1
  static, behavior, failure-parity, and legacy Serve suites passed exit 0 for
  diagnostics at `14a3b7f`, strict progress validation at `4e14e38`, strict
  journal observation at `9e43dd7`, and bounded phase telemetry at `0a8d5b6`;
  Astra Medium reviewed all four slices **GREEN**. The latest disposable
  native run passed static, behavior, and legacy Serve suites under Windows
  PowerShell 5.1. The digest telemetry handoff uses a mutable holder because
  named `[ref]` arguments are rebound incorrectly by Windows PowerShell 5.1.
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
- T0 requirements mapping is generated at
  `artifacts/final/T0/requirements-map.md`: 258 leaves, seven aliases, and
  zero accepted, with statuses unchanged. T10a capability preflight is
  recorded at `artifacts/final/T0/t10a-capability-preflight.md` and is
  **SOURCE GAP**: source declares the required surfaces, but the configured
  Team ID differs from the installed identity and the physical iPhone
  developer tunnel is not currently usable.
- T0 calendar reconciliation is recorded at
  `artifacts/final/T0/calendar-security-reconciliation.md`. The public
  CalendarStore merge bypass is fixed and pushed at `e07a0a4`; Astra Medium
  reviewed the two-file patch **GREEN**. The focused iPhone 17 simulator
  receipt is **96/96 with 0 failures**. Peer transport identity remains open.
- T1/A1 Windows recovery review is recorded at
  `artifacts/final/T0/t1-a1-review.md` and is **RED**. Astra found four
  blocking recovery-boundary defects; no canonical Windows state was changed.
- A1.4 is now a scoped **GREEN** subpacket at `9539841`: install/rollback
  failure messages no longer claim an unverified stopped/disabled writer
  state, and exact branch assertions cover the changed messages. A1.1–A1.3
  remain RED; this does not authorize canonical recovery.
- Mac Tax accessibility repair is committed at `66953af`: macOS exposes one
  direct `import-tax-pdf` button, platform-specific empty-state actions
  compile, and the exact artifact passed direct AX inspection and native picker
  interaction. The complete Mac UI suite remains unverified because XCTest
  automation initialization is still unreliable in this environment.
- Shared visual foundation is committed at `628d4b3`: the current `tasks/design.md`
  palette is applied, the system/SF Pro typography facade remains compact, and
  `LifeOSCard` uses one hairline border, flat structural fills, and the bounded
  floating shadow. The exact serialized `LifeOSMac` build succeeded; Home and
  Calendar were opened from that binary. Astra Medium reviewed the corrected
  diff **GREEN**. This is foundation evidence only; route-by-route visual,
  gesture, widget, phone, and physical acceptance remain open.
- Mac shell refinement is committed at `39f2c21`: sidebar defaults/clamps,
  collapsed rail, toolbar/search geometry, selected navigation treatment, and
  iOS route animation ownership were reviewed by Astra Medium **GREEN**. The
  exact serialized Mac build succeeded and Home, Usage, and Calendar were
  opened from that artifact. Collapsed/automatic-compact behavior, rapid route
  reversal, and iPhone tab-bar rendering remain runtime checks.
- The frozen acceptance registry is structurally valid (**258 scored leaves,
  7 aliases**) but has **0 accepted leaves**; `--score` correctly fails the P0
  gate. Scoped GREEN tranche reviews are not a product-completion percentage.
- `tasks/design.md` is the current 191-line visual contract. A narrow Mac shell
  candidate compiled and passed 6 selected tests, but Astra Medium returned RED
  because the shell was not captured and the collapsed header may exceed the
  52-point rail. It was quarantined at `/private/tmp/lifeos-mac-shell-candidate-red.patch`
  (SHA-256 `7deeb53418ad81bb3eb9c223e9649d88cba33c836c6e4b97ef83daf7aaa17be3`)
  and the source was restored to `5ebc17e` before the reviewed `66953af`
  accessibility repair.

## Still open

- Windows is reachable and BitLocker was freshly read fully encrypted with
  protection on for C: and D:. No LifeOS recovery/install process is running;
  `LifeOSAPI` is stopped and `LifeOSGateway` is absent.
  A fresh read-only probe found the durable deployment marker `active` with a
  manifest, but no stage, `recovery.json`, or `recovery.progress.jsonl` at the
  default backup root; the older 31,401-unit journal receipt is therefore not
  treated as current. Install and live Enable Banking readback remain
  uncertified; diagnostics and phase telemetry were tested only in a
  disposable copy, and the canonical transaction was not resumed or installed.
- Three bounded T1a/T1b Luna Max recovery-preparation attempts were stopped
  after producing no usable report. They made no source or Windows mutation.
  The T1/A1 review is RED with four source blockers; the current source-owner
  packet must repair those boundaries before any disposable measurement.
- Astra rejected an uncommitted runtime optimization for a mutating
  reconcile-only path and TOCTOU gap; it is preserved at
  `/private/tmp/lifeos-red-runtime-optimization-20260913.patch` and excluded.
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
- Claude's supplied High/Medium/Low security findings are reconciled
  finding-by-finding in `artifacts/final/T0/security-findings.md`. Most API,
  parsing, atomic-write, and secret-comparison findings are fixed at source
  level; peer transport identity, tax/deployment proof, regex fuzzing,
  cross-process history locking, dependency audit, and deployed evidence
  remain open or partial. No broad worker report was received, so this matrix
  is parent-led source evidence rather than an Astra release sign-off.
- Two T12 Calendar Luna Max attempts (`01a09cc4-6798-7423-a649-222b9d65af3e`
  and `01a09cd9-123b-70f0-9da0-872586cfaaf1`) were stopped without a verified
  build or runtime handoff. Their incomplete patch was archived locally and
  discarded; no Calendar change from those attempts is in the branch.

## Boundaries and next action

Keep SF Pro/system styling, compact Linear/Vercel quality, truthful live data,
no generic advisor or in-app AI, and calorie-photo tracking as the only AI.
The old AppKit route-host/raster plan is superseded by the native stack in
`070b7db`. The bounded T0 CalendarStore security reconciliation is pushed at
`e07a0a4`; current next step is the T1 owner repair for the A1 RED findings,
  followed by a separately bounded disposable recovery measurement;
conforming T11 source remains subject to runtime verification. The latest
committed Usage tranche is `e8bbefa`. Calendar gesture work is not accepted and
must use the smaller T12 packets in `tasks/final-execution-plan.md`. The two
broad security workers returned no report, so any further reconciliation must
use a completed bounded execution method before code changes. Keep the Windows
marker untouched until fresh strict recovery observation, identity/ACL checks,
and reviewed performance authorize mutation. Live bank readback, physical
signing/widgets, whole-app visual/runtime, Zepp, Obsidian, and final release
evidence remain open.
