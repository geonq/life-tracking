# LifeOS execution plan to a defensible 95% checkpoint

Updated: 2026-08-13. Branch: `lifeos-foundation-checkpoint-20260812` at
`32fbdfc`. Draft PR: https://github.com/geonq/life-tracking/pull/1. This is the
reviewed execution plan; its companion acceptance registry is intentionally
**UNFROZEN** until T0 completes, so no completion percentage is currently valid.

## 1. Current truth

LifeOS is a substantial native UI/domain foundation, not a nearly finished live
product. Claude's 2026-08-13 scan is useful as an inventory, but its “backlog
essentially cleared” claim is rejected by three independent source audits:

- release navigation and many source-aware Swift domains exist;
- Calendar local editing, Journal, barcode confirmation, Usage foundations,
  partial Sleep/Stress, and strict Finance/Clipper boundaries are real;
- normal Fitness still receives an unavailable snapshot and has no HealthKit
  importer;
- Finance and Clipper API routes are unavailable stubs;
- supplements are session-only, photo nutrition has no Gemini transport, and
  future widgets have no production snapshot publisher;
- Windows gateway identity, deployment, signed host/App Group configuration,
  and real-account/device evidence are not complete;
- the full 59-frame Bevel functional contract, 21 Revolut feature rows plus six
  deduplicated motion leaves, ten Calendar runtime checks, and the sixteen-row
  widget catalog are not accepted.

No percentage will be reported until the acceptance registry in Tranche 0 is
frozen. A large source file, screenshot, fixture, or passing narrow test is not a
completed workflow.

## 2. Meaning of “95% done”

The checkpoint is reached only when all of these are true:

1. Every P0 security, privacy, data-loss, truth, signing, and release-navigation
   row passes. Aggregate percentage cannot excuse a failed P0.
2. At least 95% of the frozen, deduplicated leaf rows in
   `docs/LIFEOS_ACCEPTANCE_REGISTRY.md` pass with linked evidence.
3. No product workstream is below 90%: Overview/IA, Calendar, Finance, Usage,
   Fitness, Nutrition, Supplements, Settings/connections, widgets, sync/storage,
   accessibility, and security/release.
4. Every visible destination has a real workflow or an honest unavailable state
   with a useful setup/retry action; there are no dead primary screens or
   fabricated production values.
5. All required deterministic tests and builds pass at the same commit. Signed
   device, widget, bank, HealthKit, and server checks are explicitly separate
   gates and cannot be replaced with fixtures.
6. geonq completes the final iPhone and Mac visual/interaction review. No agent
   can promise subjective satisfaction before that review.

The registry will deduplicate the binding sources rather than count the same
behavior repeatedly: 52 non-widget functional Bevel stills (`0382–0433`), six
deduplicated Revolut motion leaves plus the separate 21-row Finance feature
matrix, ten Calendar definition-of-done checks, and sixteen widget catalog rows.
Bevel widget images
`0645–0651` map to seven of those sixteen widget rows and are aliases, not seven
additional leaves. Cross-cutting IA, Usage, Settings, transport, storage,
security, accessibility, and release requirements are separate unique leaves.
Each leaf gets a stable ID, owner, evidence type/path, producing commit,
severity, status, and blocking input.

## 3. Non-negotiable product contract

- macOS primary IA: Home, Calendar, Finance, Fitness, Tax, Settings. iOS: Home,
  Calendar, Finance, Fitness, More. Usage belongs to Home; connections, OAuth,
  banks, health devices, sync, storage, privacy, and signing belong to Settings.
- `IMG_0380` and `IMG_0381` are style-only. The remaining Bevel references are
  functional requirements. The seven Bevel widget references are exact iPhone
  widget targets. Both Revolut recordings and the Notion/Figma Calendar
  references are binding interaction inputs.
- Black and white lead the palette; brand and semantic colors are accents.
  Use restrained component gradients. No resting glow, bloom, or decorative
  motion. Hover must communicate clickability, precision, or disclosure.
- Never copy or imply Bevel's private formulas. LifeOS metrics are transparent,
  source-labelled models or remain unavailable/calibrating.
- Never put raw provider, bank, OAuth, or AI secrets in the apps, repository,
  UserDefaults, logs, screenshots, or fixtures. Windows is authoritative.
- Missing, unavailable, partial, stale, calibrating, and observed are distinct.
  A screenshot fixture never proves a live data path.
- Keep `services/windows-service-host/deploy/` untracked and untouched until it
  is explicitly reviewed and approved.

## 4. Execution topology

Root owns architecture, `project.yml`, entitlements/signing/App Group,
shared transport contracts, global navigation, cross-domain persistence,
widget-bundle integration, release composition, acceptance, Git history, and
adversarial review. Up to three Luna/max workers execute bounded lanes:

| Lane | Primary ownership | Files it may not change without root handoff |
|---|---|---|
| A | Calendar/Mac views, pointer/keyboard/accessibility, Calendar client adapter | shared transport, `project.yml`, global navigation |
| B | Fitness/Nutrition/Supplements domains and UI, fitness widget views | shared transport, signing, global navigation |
| C | approved gateway/API, Usage, Finance, Clipper, connection screens | Calendar/Fitness presentation, signing/global navigation |

Only one worker owns a shared file at a time. Every task brief includes exact
acceptance rows, permitted files, failure states, required tests, and forbidden
scope. Workers do not commit. Root inspects the diff, requests an independent
Luna/max review, fixes or rejects findings, runs proportionate verification,
then commits and pushes the accepted tranche.

## 5. Dependency-ordered tranches

### T0 — Freeze truth and make verification cheap

Deliverables:

- complete and freeze the registry scaffold, mapping every source, partial,
  missing, external, and honest-state row; record its hash before scoring;
- add registry validation that rejects duplicate IDs, missing/stale producing
  commits or artifacts, canceled/zero-test results, and fixture-only “passes”;
- commit `LifeOSLogic`, `LifeOSUI`, `LifeOSMacLogic`, `LifeOSMacUI`,
  `LifeOSWidgets`, and `LifeOSPrerelease` schemes/test plans; document runnable
  `-showTestPlans`, `-testPlan`, `build-for-testing`, and
  `test-without-building` commands;
- add a plan matrix naming exact targets, destination/configuration,
  `-only-testing` scope, minimum expected count, timeout, result/log path, and
  diagnostics. `LifeOSMacUI` contains only `LifeOSMacUITests`; widget snapshot
  host/`TEST_HOST`/`BUNDLE_LOADER` intent is explicit;
- isolate/fix the widget-test host configuration and stale native validator;
- pin XcodeGen in CI and fail on generated-project drift;
- make Mac UI runner diagnostics bounded: build-for-testing, inspect xctestrun,
  one smoke, then one pointer test—never another blind broad rerun;
- add a release-only xcconfig/CI injection contract that fails on placeholder
  App Groups, `PROVISIONING_MODE=unknown`, empty release allowlists, fixture
  flags, unresolved build variables, or unintended top-level modules;
- define registry evidence and performance/accessibility thresholds before UI
  implementation begins.

Exit: registry frozen; all existing deterministic suites can be invoked by
lane; the current commit has a complete logic run or explicit test-infrastructure
failure evidence. This tranche changes no product design.

### T1 — Security and synchronization spine (starts immediately, runs in parallel)

Deliverables:

- verify BitLocker C/D before any credential/deployment action;
- add a tracked, reviewed Windows gateway outside the unapproved deploy tree;
  validate Serve/LocalAPI identity, bind backends to loopback, proxy the typed
  Calendar/WS/Usage/Finance/Clipper/Nutrition/Fitness/Supplement route matrix,
  enforce size/time limits, and reject direct listeners/forged identity headers;
- implement provider-scoped Windows credential storage with encryption at rest,
  service-SID ACLs, rotation/revocation, and fail-closed startup; never put
  credentials in service-host environment values or the unapproved deploy tree;
- retain the transitional bearer through a dual-auth migration. Exact order:
  BitLocker → identity/ACL/loopback canary → authorized and unauthorized-node
  tests → signed exact host/App Group → client/server compatibility + rollback
  test → deployed canary → only then stop accepting and remove the bearer;
- map external Claude ingest to the real loopback route and prove collector →
  gateway → Node authentication, retry/replay, and unauthorized behavior;
- inject the exact private `.ts.net` allowlist and real App Group only through
  signed local/CI configuration;
- define authority per domain. HealthKit originates on iPhone; decide whether
  raw samples remain device-local or use versioned authenticated ingestion.
  Every synchronized domain specifies revisions/idempotency, offline queues,
  tombstones, deletion propagation, and retention;
- add server-authoritative Calendar ETag semantics: GET returns ETag, PUT
  requires `If-Match`, conflict returns authoritative truth, and client performs
  bounded fetch–merge–retry with no blind fallback;
- implement encryption/key-custody, atomicity, Data Protection class, backup
  exclusion, and storage-accounting primitives before broad data ingestion;
- implement the 8/9/10 GiB warning/compaction/hard-gate policy transactionally,
  including DB/index/WAL/temp/cache/logs/backups in accounting. Retain at most
  three images per meal, originals for 90 days, detailed history for 365 days,
  derivatives <=500 KiB, and a rolling 12-month policy; verify provenance and
  export before compaction and never silently delete user truth.

Exit: negative peers/direct listeners/forged headers fail closed; secrets remain
server-only; conflict/recovery/canary/rollback tests and registry rows `DT-02`
and `DT-03` pass for every enabled domain. T3–T7 may build local
UI/contracts in parallel, but no live enablement or real-account test occurs
before this exit.

### T2 — Calendar and Mac interaction acceptance

Deliverables:

- isolate and pass Mac click-to-create: click anchor within 48 pt, correct date,
  12:00–12:30 snap, cancel without mutation, relaunch without draft;
- finish move/resize failure recovery, Escape/undo, keyboard and accessibility
  alternatives, auto-scroll, month drag, and DST fold/gap behavior;
- complete Notion-style day/week swipe, velocity settling, adjacent-grid
  preview, month-height morph, overlapping-event stacking, and compact anchored
  Mac editor;
- finish full searchable emoji/system/custom icon behavior, recent persistence,
  genuine no-icon state, reusable upload, and Mac keyboard/hover behavior;
- implement responsive Mac breakpoints and purposeful hover/focus treatment
  without reintroducing dead modules. Each release area—Home, Calendar,
  Finance, Usage, Fitness, Tax, Settings—must later pass narrow/default/max
  pointer and keyboard checks; static cards never get decorative hover.

Exit: all ten Calendar DoD rows pass and the Calendar/Mac visual milestone is
accepted at narrow/default/max widths, both themes, and Reduce Motion.

### T3 — Durable Nutrition and Supplements

Deliverables:

- persist supplement products, schedules, occurrences, actions, inventory,
  refill/expiry state, and reminder reconciliation; preserve Taken/Snooze/Skip
  idempotency across relaunch, DST, offline periods, and permission changes;
- install a launch-time `UNUserNotificationCenterDelegate`; implement
  `willPresent` and `userNotificationCenter(_:didReceive:withCompletionHandler:)`,
  validate plan/occurrence, reject stale/unknown actions, persist idempotently
  before completing, and cover foreground/background/terminated delivery,
  relaunch, DST, denial and lock-screen behavior;
- keep photo/barcode proposals ephemeral or explicitly draft: exclude them from
  totals, sync, widgets, and backups. Only edited explicit confirmation creates
  a durable meal. Add history, totals, macros, hydration, caffeine/alcohol,
  correction/delete, expiry, and sync envelopes;
- finish Open Food Facts gateway composition and honest miss/manual fallback;
- implement Gemini photo analysis only through the Windows gateway, with local
  sanitization, explicit confirmation, correction lineage, provenance, original
  deletion/retention proof, and a held-out weighed/labeled corpus. Release gate:
  >=80% of meals within ±20% calories plus frozen MAPE, median, p95, food-class,
  and macro-quality thresholds in the registry.

Exit: relaunch and sync preserve user-confirmed truth; notification and
inventory states are durable; no food estimate is auto-committed.

### T4 — HealthKit/device ingestion and full Bevel Fitness contract

Deliverables, in this order:

1. HealthKit iOS entitlements, `NSHealthShareUsageDescription`, and
   `NSHealthUpdateUsageDescription`;
   unavailable/restricted/denied/pending/authorized/revoked UX; source
   reconciliation, query anchors, units, freshness, duplicates, partial nights,
   and deleted samples. Confirmed nutrition writes require explicit user
   confirmation and write authorization; if deferred, those registry leaves
   remain blocking. HealthKit is never claimed on macOS/from fixtures.
2. `0382–0386`: Today/readiness hierarchy, monitor, timeline, navigation,
   permission/unavailable states.
3. `0387–0395`: Journal, automatic observations, activity, Strength, Biology,
   trends and drilldowns.
4. `0396–0404`: Load, zones, Recovery, Sleep interval/stages/timeline/trends.
5. `0405–0414`: Stress and Energy Reserve full ranges and drilldowns.
6. `0415–0423`: source-backed Fitness nutrition, glucose, expenditure, and Net
   Energy. T3 owns capture/persistence; T4 owns derived source-backed surfaces.
   Net Energy cannot pass before expenditure is observed or unavailable.
7. `0424–0433`: remaining source-defined targets, insights, history, controls,
   and navigation from the reference registry.

Exit: all 52 non-widget Bevel leaves have truthful source behavior and their
registry-required evidence; no private formula or fixture is presented as
observed. The seven mapped Bevel widget targets close in T7 without recounting.

### T5 — Usage completion

Deliverables:

- keep one Home-owned Usage destination; remove duplicate terminology;
- implement durable daily aggregation, rolling history, actual versus estimate
  history, target pace, runway, reset/banked-reset facts, peak/streak/credits,
  and source freshness;
- preserve bklit-style observed→projected separation, crosshair/date pill,
  keyboard/pointer exact values, muted nonselected series, and uncertainty;
- operationalize Codex and Claude collectors first. For GLM, DeepSeek, and
  Google AI Studio, freeze a provider capability matrix—credentials/scopes,
  wire fields, provenance, rate-limit semantics, scheduler, packaging,
  restart/retry. Unsupported facts remain unavailable. API keys remain Windows.

Exit: every displayed fact is backed or unavailable; projection never implies
an observed future; collectors survive restart and bounded retention.

### T6 — Finance and Revolut completion

Deliverables:

- version Finance schemas first: account identity, balances/holdings, integer
  cents, reconciliation IDs, cursors/pagination, provenance, stale/revoked
  states, and migrations;
- implement gateway-owned OAuth state/PKCE/callback/token storage. Settings may
  initiate, show pending/authorized/expiry/failure/unavailable, revoke, and
  retry—never receive raw tokens. Support GoCardless, Revolut Business where
  eligible, and explicit Trade Republic manual-import fallback;
- ingest accounts, balances, transactions, categories, income, budgets,
  investments, net worth, freshness, and reconciliation;
- complete all Revolut motion leaves explicitly: hero morph, ring reveal, chart
  stroke + gradient draw-on, continuous scrub bubble, spring selector with
  exact `1W/1M/6M/1Y/Max`, and in-place numeric text updates. The separate
  Finance feature matrix—including income/travel rows—also remains binding;
- keep bank connections in Settings while Finance links contextually to setup.

Exit: one consented account at a time passes read-only live tests, revocation,
token expiry, stale/error, reconciliation, and no-secret-client review.

### T7 — Clipper, Settings, widgets, and release composition

Deliverables:

- choose and document Clipper's authoritative source before implementing it;
- compose and audit Settings workflows implemented in T4/T6 plus provider,
  sync, storage, privacy, signing, and diagnostics states;
- publish versioned per-module snapshots only from confirmed state using atomic
  protected writes, explicit locked/redacted behavior, expiry/freshness, signed
  App Group access, and coalesced `WidgetCenter.reloadTimelines(ofKind:)`;
- validate all sixteen catalog rows, including the seven exact Bevel families,
  actual iPhone gallery/home-screen placement, provider reload reads, deep links
  to their intended route/setup state, unavailable, stale, redacted/locked,
  tinted, and accessibility behavior. Today's Tasks remains selectable with a
  truthful unavailable/setup route until its workflow exists;
- remove duplicate/legacy widget registrations and stale internal navigation
  cases only after migration/deep-link tests pass;
- production-gate fixture API routes; complete signed iPhone/Mac archives and
  installs, strict code-signature/expanded-entitlement inspection, App Group
  cross-process, cross-domain backup/restore/export/delete, accessibility,
  performance, and final security review.

Exit: all P0 gates pass, registry is at least 95% with no workstream below 90%,
and the final cross-platform review is accepted by geonq.

## 6. Verification cadence

The dependency graph is not purely serial. After T0, T1 begins immediately;
T2 and local-only T3 work run in parallel. T5/T6 schema/UI work starts after T1
interfaces freeze, while their live tests wait for T1 exit. T4 starts after its
HealthKit authority/permission contract is reviewed. T7 is integration/release.

Use Apple's test pyramid: fast isolated logic tests dominate; integration tests
cover persistence/transport boundaries; UI tests cover a small set of critical
workflows. Test plans separate configurations and CLI lanes.

- Per edit: parse/static invariant plus only the affected deterministic unit
  suite. Preserve the failure `.xcresult`; do not create screenshots.
- Per accepted tranche: all affected unit/integration suites, one appropriate
  platform build, adversarial source review, and `git diff --check`.
- UI/runtime: run only when a pointer, navigation, notification, permission,
  widget, lifecycle, or cross-process behavior is the acceptance target.
- Visual reviews: four milestones only—Calendar/Mac shell; Finance/Usage;
  Fitness/Nutrition/Supplements; Widgets/Settings/final release. Each uses a
  predefined screenshot/recording manifest, not exploratory recaptures. Each
  registry row names code/test, bounded runtime, or milestone-visual evidence;
  the 52 Bevel leaves do not trigger 52 screenshot campaigns.
- All sixteen widget rows get deterministic provider/payload/freshness/privacy/
  deep-link tests. One consolidated T7/prerelease device visual matrix covers
  the seven exact Bevel targets plus representative Calendar/Usage/Finance;
  never recapture per edit. WidgetCenter reloads are coalesced/budget-aware and
  are requests for a new timeline, not immediate-display guarantees.
- Every release area gets a state matrix: observed, unavailable, stale,
  partial/calibrating where applicable, fixture-only demo, pending/denied/
  revoked where applicable, and redacted/locked where applicable—each with a
  truthful useful setup/retry action.
- Mac UI runner: build once, inspect `.xctestrun` host/loader/app paths, run one
  UI-only smoke then pointer with `-only-testing`, retain result/log/xctestrun on
  failure, and stop. Canceled/materialization/zero-test is never a pass.
- Signed release: archive both apps/extensions; verify signatures and expanded
  entitlements; prove App Group cross-process on device. Atomic replacement is
  not encryption—record key custody, protection class, backup and locked-device
  behavior per payload.
- Accessibility/performance: predefined device/OS/theme/tint metadata,
  perceptual tolerances for milestone baselines, accessibility audits, Dynamic
  Type/VoiceOver/Reduce Motion, and frozen launch/render/storage thresholds.
- Prerelease: umbrella plan, release builds, signed devices, widgets/App Group,
  network/security negatives, accessibility, performance, migration, and
  restore tests at the same commit.

Apple references:

- https://developer.apple.com/documentation/xcode/testing
- https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback
- https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results
- https://developer.apple.com/documentation/healthkit/setting-up-healthkit
- https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data
- https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app
- https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions
- https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension
- https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date

## 7. Checkpoint, Git, and notification discipline

- Refresh `Coordination/HANDOFF.md`, `PHASE_STATUS.md`, and `tasks/todo.md`
  about hourly during active work and at every accepted tranche. Keep handoff
  compact; move evidence detail to the acceptance registry/change log.
- Commit and push after each independently reviewed, green, coherent tranche.
  Stage explicit paths only; never stage the unapproved deploy tree; never force
  push. Commit messages name the user-visible invariant.
- Use draft PR #1 as the external checkpoint. When user input, permission, or
  an external action is truly blocking, comment there with
  `@geonq ACTION REQUIRED`, the exact ask, why it blocks, safe default, and work
  that can continue meanwhile. Group requests; do not spam progress comments.
- Close unused LifeOS app processes and simulators immediately after a runtime
  lane. Do not leave runners active between evidence captures.

## 8. Inputs that will be requested just in time

These are not reasons to idle; local implementation can proceed around them.

- confirmation that BitLocker is enabled on Windows C: and D:;
- approved exact private `.ts.net` hostname and signed config/App Group values;
- approval of the reviewed Windows deploy tree;
- Clipper authoritative source choice;
- GoCardless/Revolut Business eligibility and consent;
- signed-device HealthKit/notification/widget permission;
- a dedicated Gemini credential provisioned to the Windows gateway;
- live-account/device test windows and final visual-review windows.

Each request will be sent through the draft PR notification rule above.
