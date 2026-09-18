# LifeOS final execution plan

Prepared by Astra Medium from the Luna Max audit on 2026-09-18. Baseline:
`f53c77c`, clean `main`, aligned with
`origin/main`. Release is **NO-GO**. The 258-leaf registry has 0 accepted
leaves; it is an acceptance ledger, not a completion percentage.

## Rules for every tranche

1. One Luna Max implementation worker at a time. Astra Medium reviews the
   actual diff and evidence in batches. Close each worker after its report.
2. Dispatch from the current SHA with exact file paths, symbols, invariants,
   prohibited changes, focused tests, evidence path, and stop conditions.
3. Shared integration owners are exclusive for `ios/project.yml`, generated
   Xcode changes, app entry points, `ModuleNavigation.swift`, `Settings.swift`,
   `TailscaleSyncClient.swift`, gateway `main.py`, and contract exports.
4. Each tranche ends with focused verification, Astra review, a commit, push,
   and local/remote SHA parity. Unexpected scope, destructive migration,
   security-boundary change, or reproducible crash stops that tranche.
5. Real data is authoritative. Fixtures are explicit and labelled. Missing
   data stays unavailable. No generic advisor or conversational AI; calorie
   photo tracking is the only in-app AI.
6. Apple lanes use `-jobs 1 -parallel-testing-enabled NO`, a fresh owned
   result/DerivedData path, the storage guard, and independent xcresult
   validation. A quiet compile is not a hang; an interruption is unverified.

## 1. Stability and truth ledger — L/S

The three historical `EXC_BAD_ACCESS` reports are real crashes in temporary
XCTest hosts. The stability receipt shows a separate manual LifeOSMac build
survived a focused serial 1/1 test and no new crash report appeared. Do not
change lifecycle code, suppress reporting, or disable tests without a new
symbolicated reproduction.

Diagnostic scope: `ios/LifeOSMac/LifeOSMacApp.swift`,
`ios/LifeOSMacSnapshotTests/LifeOSMacSnapshotTests.swift`,
`ios/LifeOSMacUITests/LifeOSMacUITests.swift`,
`ios/TestPlans/LifeOSMacLogic.xctestplan`, `ios/project.yml`, and
`scripts/run_prerelease_lanes.sh`. Record PID/parent/path/arguments, crash
UUID/exception/stack, explicit UI-test termination, and manual-app behavior.
Keep manual and temporary builds separate; never use broad `killall`.

Reconcile `Coordination/{HANDOFF,PHASE_STATUS,DECISIONS}.md`,
`tasks/{ACTIVE,todo,final-execution-plan}.md`, and `README.md`. Every
requirement row is `requirement → owner → source status → verification →
SHA/evidence → next action`, classified S (source), L (local), W (Windows), P
(physical/provider), or U (unsupported).

## 2. Canonical Windows backend — W/S

Owner: `services/windows-service-host/deploy/`, `services/windows-service-host/src/`,
`services/windows-service-host/tests/`, `scripts/build_windows_release.sh`,
`scripts/tests/test_windows_release_builder.py`, and
`scripts/tests/test_windows_deployment_source.py`.

Read actual roots, service state, marker, transaction, manifest, journal,
progress identity, protected configuration, and staging candidate. Resolve
the 31,401-unit history into one current receipt. Run candidate verification
and read-only preflight; Astra reviews the exact cutover packet; then perform
the already-authorized transaction-bound recovery/install. Never clear a
marker to bypass recovery.

Verify `LifeOSAPI`/`LifeOSGateway` service accounts, dependencies, ACL/SID and
reparse protections, loopback-only children, Tailscale Serve identity and
capability policy, direct-listener rejection, `/health`, `/ready`, restart,
reboot, and rollback. Preserve secrets out of command lines and receipts.
Use disposable failure injection before canonical mutation. Stop on identity
mismatch, unexplained journal state, missing rollback material, or preflight
failure. Evidence goes under `artifacts/final/windows/`.

## 3. Live finance and wealth — S/L/W/P

Connector owner: `services/gateway/{enablebanking,test_enablebanking,test_gateway}.py`,
`ios/Shared/{FinanceDomain,FinanceCoordinator,FinanceReadback}.swift`, and
the existing consent/settings tests. Recover the existing Enable Banking
configuration first. Compare provider → gateway → Mac/iPhone account identity,
exact amount/currency, transaction identity, timestamps, freshness, consent,
revoke, expiry, pagination, partial failure, retry and offline cache behavior.

Import/wealth owner: `FinanceStatementImporter.swift`,
`FinanceInstitutionDetector.swift`, `FinanceImportMapping.swift`,
`FinanceImportedTransaction*.swift`, `FinanceRecurringPayment*.swift`,
`FinanceRobinhoodImporter.swift`, `FinanceInvestment*.swift`,
`FinanceWealthProjection.swift`, `FinanceBankCashProjection.swift`, Finance
views, and matching tests. Run real Trade Republic/Robinhood preview → confirm
→ relaunch → reimport/correction → net-worth reconciliation. Preserve exact
money, source/account/period/provenance, stable IDs, and correction lineage;
keep investments separate from spending and reject incomplete valuations.
Recurring candidates must remain suggestions until explicit weekly/monthly/
yearly management. NextSemis is the last optional gate.

## 4. Offline durability — S/L/W/P

Each owner proves local-first persistence before acknowledgement, mutation IDs,
bounded replay, conflict/deletion semantics, stale-versus-failed state,
restart during writes, disk-full recovery, expired authorization, and a
clock-controlled eight-day Windows outage. Preserve pending mutations until
acknowledged and never let a stale server snapshot overwrite a newer local
edit. Use existing domain authorities; do not add a universal competing store.

## 5. Fitness, Zepp, and nutrition — S/L/P/U

Workout owner: `ios/Shared/FitnessTraining{Domain,Store,Projection}.swift`,
`FitnessStrengthDomain.swift`, `ios/LifeOS/FitnessTrainingCoordinator.swift`,
`ios/LifeOS/Modules/Fitness/FitnessTraining{View,SessionView}.swift`, and
existing training tests. LifeOS owns exercises, templates, sets, reps, load,
rest, completion, history and reports. HealthKit/Zepp observations are
read-only, source-qualified, timestamped, unit-safe and deletion-aware.

Health owner: `HealthKit{Adapter,Domain,Reconciliation,AnchorStore}.swift`,
`ios/LifeOS/HealthKit{FitnessComposition,FitnessProjection,FitnessRepository,
Integration,ProductionBridge}.swift`. Match records only with explicit
confidence and ambiguity handling. Physical proof compares Zepp, Apple Health,
and LifeOS fields; never claim proprietary Zepp readiness/load/PAI/Training
Effect or exact strength parity without a legitimate source. Calorie-photo
AI remains an editable proposal and confirmed values only enter totals.

## 6. Obsidian Canvas — S/L/W/P

Build four disjoint packets. **Codec/binding:** committed and reviewed at
`f53c77c`; focused tests are 31/31, an independent smoke harness passed, and
the post-commit Mac logic lane is 193/193. It adds
`ios/Planning/{PlanningDomain,PlanningVaultBinding,PlanningCanvasCodec,
PlanningMarkdownCodec}.swift` and codec tests. Read/write standard `.canvas`
and Markdown while preserving node IDs, edges, coordinates, groups, colors,
supported node types, unknown JSON fields and untouched Markdown/frontmatter.
Reject traversal, escaping symlinks, case collisions, duplicate IDs, oversized
inputs and invalid coordinates. Do not promise arbitrary shape parity beyond
the standard format.

**Durability:** new `PlanningVaultStore.swift`,
`PlanningMutationJournal.swift`, `PlanningConflictResolver.swift` and tests.
Use expected content versions, same-directory atomic replacement, recoverable
journal entries and conflict copies. Preferred topology is a selected
non-Uni iCloud vault under `LifeOS/`; do not select a vault by guessing and do
not silently overwrite Obsidian edits.

**Interaction:** new `PlanningGraphProjection.swift`, `PlanningSpatialIndex.swift`,
`ios/LifeOS/Modules/Planning/{PlanningCanvasView,PlanningNodeInspector}.swift`
and tests. Implement pan, focal zoom, selection, node drag, edge editing,
color/type controls, Markdown detail, undo/redo and keyboard actions with
unambiguous Mac/iPhone gesture ownership. Rebuild O(V+E); target spatial
queries O(log V+k); persist committed edits, not every drag frame.

**Transport/wiring:** new `services/gateway/{planning,test_planning}.py` and
`packages/contracts/src/{planning.ts,planning.test.ts}`. Accept only bounded
project-relative operations with identity, expected revision, mutation ID and
explicit conflicts. Add Calendar/project registration only after isolated
codec/store/view tests pass. Prove Mac → Obsidian → iPhone → Mac round trip
before live vault writes.

## 7. Widgets, signing and Shortcuts — S/L/P

Owners: `scripts/install_personal_device{,_checks.py}.sh` (resolve exact
current name), installer tests, `ios/Shared/SigningStatus.swift`,
`ios/LifeOS/Modules/Automation/LifeOSAppIntents.swift`, widget publisher/
snapshot files, `ios/LifeOSWidget/`, `ios/LifeOSMacWidget/`, and the project/
entitlement integration owner. Run capability preflight early.

Provide an honest Morning Sync Shortcut: open Zepp, use an officially exposed
sync action if one exists or show the manual step, then refresh LifeOS and show
observed freshness. Provide USB Refresh: call the reviewed Mac installer,
verify the connected device/profile/App Group, and report expiry/failure.
Opening Zepp is not proof of synchronization; AppIntents cannot renew an
Apple signature. Verify existing widgets plus the lock-screen calendar widget
in dark/tinted/transparent modes on the grey wallpaper, with stale/locked/
deep-link states. Physical signing, App Group, HealthKit, widget, background
refresh and seven-day renewal remain P gates.

## 8. Visual/motion acceptance — S/L/P

Apply the current design coordination docs route by route. Use SF Pro/system
typography, one consistent icon abstraction, compact Mac hierarchy, readable
phone sizing, distinct brand palette, green estimates, truthful unavailable
states, and no generic AI. Calendar must own vertical scrolling and focal
trackpad pinch; navigation/chart motion must be interruptible, avoid jumps and
retired callbacks, and settle correctly under Reduce Motion. Use actual
captures/interaction recordings at Mac widths, light/dark, loading/stale/live,
rapid reversals, and reduced motion. Static snapshots alone cannot certify
motion or whole-app quality.

## 9. Final security/release gate — L/W/P

Astra reviews the final actual diff and deployed evidence for peer admission,
pairing/replay/timestamps/duplicate IDs/deletions, Tailscale identity/header/
Host/redirect/body bounds, secret handling, tax protection/migration/regex/CSV,
atomic writes/symlinks/path traversal, usage cross-process races, offline
restore/retention, executable resolution, dependencies/CI and canonical
deployment. Use disposable data and owned endpoints only; do not attack bank,
Apple, Google or Zepp infrastructure. Every finding names SHA, payload,
expected/observed result, remediation and retest.

## Immediate next dispatch

After the stability and Canvas codec receipts, dispatch the canonical Windows
candidate/preflight packet with exact inspected parameters. In parallel only
when write scopes are disjoint, dispatch Canvas durability or workout source
hardening. Do not start live finance or physical-device acceptance before the
backend/device prerequisites. Finish each packet with review, commit, push,
and handoff update.
