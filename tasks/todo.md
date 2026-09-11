# TODO — LifeOS completion gates

Updated 2026-09-12 Europe/Berlin.

Current source checkpoint: `b05c4fb`; coordination tip: `84b8336` on
`lifeos-foundation-checkpoint-20260812`, synchronized with origin and draft PR
#1. Final Astra Medium source security, shared foundation, ChartKit/Usage, and
Calendar density reviews are GREEN.
Release status remains pending external gates.

## Active gates

1. Complete remaining screen visual batches with bounded Astra reviews.
2. Complete bounded Windows recovery, candidate install, standalone runtime,
   protected readback, Tailscale Serve, restart recovery, and health checks on
   `domke@tailscaleip`. Latest read-only SSH reached `geonqserver`; the new
   services are not installed, no expected listener was reported, and only
   `LifeOSAPIStaging` and `LifeOSSyncServer` scheduled tasks were present.
3. Complete real Enable Banking consent/readback and one real Trade Republic
   import. Keep missing-provider states truthful.
4. Exercise iPhone 17 HealthKit, Zepp sync, morning refresh and USB Shortcuts,
   and seven-day Personal Team signing renewal.
5. Restore/verify CoreSimulator and capture Mac/iPhone visual, gesture,
   widget, and animation evidence, including compact text, transparent
   grey-wallpaper widgets, calendar scroll/pinch, sheets, hover, and route
   reversal.
6. Resolve the Obsidian graph/mind-map feasibility and storage decision in
   GitHub issue #2. Do not mark it complete without evidence.

## Completed local verification

- Repository source validator: **163 passed**, **47 subtests passed**.
- Gateway: **549 passed**, with two dependency deprecation warnings.
- API: **141 tests passed** and typecheck passed.
- Contracts: **198 tests passed** and build passed.
- Final security review did not rerun `npm audit`; advisory status is
  unrefreshed.
- Unsigned `LifeOSMacLogic`, `LifeOSLogic`, direct `LifeOSWidget` iOS target,
  and `LifeOSPrereleaseIOS` passed; macOS logic XCTest passed **54 tests**.
- The `LifeOSWidgets` macOS-only destination list is a scheme metadata issue,
  not a source failure.
- Chart tranche: focused iPhone 17 suites passed **56 tests with 0 failures**
  (17 chart, 39 design); unsigned `LifeOSMac` build passed at `6713de1`.
- Calendar authority now rejects more than 1,024 items, matching native. An
  oversized persisted snapshot fails closed without truncating raw state.
- Calendar density review: Astra Medium GREEN with no findings; `git diff
  --check` and the serialized universal unsigned `LifeOSMac` build passed at
  `b05c4fb`. The contract is 40/64/120 pt with Mac pinch as primary.

## Constraints

Use live production data, serialize native builds with one compiler job, keep
coordination files below 200 lines, use disjoint bounded worker scopes, and
close workers/processes after use. Keep fixtures explicit and isolated. Do not
add a Claude usage watcher, overnight supervisor, demo fallback, generic
assistant/advisor, or unrelated conversational AI. Calorie-photo AI only.

Do not claim Windows runtime, provider, physical-device, visual, CoreSimulator,
or Obsidian completion from source checks alone.
