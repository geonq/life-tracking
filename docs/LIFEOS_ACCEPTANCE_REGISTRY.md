# LifeOS acceptance registry

State: **UNFROZEN — SCORING PROHIBITED**
Created: 2026-08-13 from the binding Design repository and three independent
read-only audits of app commit `32fbdfc`.

This file is the denominator for the 95% checkpoint after T0 completes. Until
every leaf has an exact acceptance statement, evidence type, owner, severity,
current status, and producing commit—and the validator records a registry
hash—no percentage is valid.

## Registry rules

- One behavior has one scored leaf. A reference may alias another leaf but may
  not increase the denominator. `IMG_0645–0651` alias widget rows `WG-11–WG-16`
  and `WG-09`; they are not seven extra rows.
- Statuses: `missing`, `foundation`, `blocked-external`, `accepted`. `accepted`
  requires evidence at the recorded commit; a canceled/zero-test result is not
  evidence. Fixture screenshots can prove layout only, never live data.
- Every P0 must be accepted. Aggregate >=95% is insufficient if any workstream
  is below 90% or geonq has not accepted the final visual/interaction review.
- Evidence types: `source`, `unit`, `integration`, `ui-runtime`, `device`,
  `milestone-visual`, `security-negative`, `operator`, `live-readonly`.
  `performance`, and `release-signature`. The validator rejects unknown types.
- Every release area must cover its applicable honest states: observed,
  unavailable, stale, partial/calibrating, fixture-only demo, pending/denied/
  revoked, and locked/redacted. Missing values never become zero.
- T0 must replace `TBD` values, reconcile the status against current source,
  write evidence paths and producing SHAs, validate unique IDs/aliases, and
  record `Frozen registry SHA-256:` here.

Frozen registry SHA-256: `UNFROZEN`

## A. Bevel non-widget functional rows — 52 scored leaves

Source: `Bevel Reference/IMG_0382.jpeg`–`IMG_0433.jpeg`. `IMG_0380–0381`
are style-only and enforced through `UX-*`, not feature leaves.

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| BF-0382 | Transparent LifeOS load/strain gauge, inputs, reset/explanation; no Bevel formula claim | P0 | foundation | unit + device + visual |
| BF-0383 | Source-labelled recovery/readiness, wake timing, HRV explanation | P0 | foundation | unit + device + visual |
| BF-0384 | Date/share/profile/activity/weather plus Load/Recovery/Sleep/coaching/Stress/Energy/Nutrition routes | P0 | foundation | ui-runtime + visual |
| BF-0385 | Macro/glucose surface plus six independently sourced Health Monitor metrics | P0 | foundation | integration + device + visual |
| BF-0386 | Health timeline rows, routing, reorder/filter/edit persistence | P1 | foundation | integration + ui-runtime |
| BF-0387 | Journal week/date navigation, pinned mood and daytime tags | P1 | foundation | unit + ui-runtime + visual |
| BF-0388 | Journal night/day tags plus automatic goals with provenance | P0 | foundation | unit + integration |
| BF-0389 | Automatic goal completed/failed/neutral truth states | P0 | foundation | unit + visual |
| BF-0390 | Remaining goals, exceeded/calibrating semantics, date selection | P0 | foundation | unit + visual |
| BF-0391 | 30-day activity calendar/counts/chart and source-defined performance target | P1 | foundation | unit + ui-runtime + visual |
| BF-0392 | Cardio load/focus/recovery and Strength volume with reviewed units | P0 | foundation | unit + device |
| BF-0393 | Strength anatomy/groups, progress, templates and add workflow | P1 | foundation | unit + ui-runtime + visual |
| BF-0394 | Biology gated age/date/radial and biomarker navigation | P0 | foundation | unit + device + visual |
| BF-0395 | Weight/HRV/RHR/body-fat/fat-free/VO2 trends and show-all | P0 | foundation | integration + device |
| BF-0396 | Load detail/date/target/duration/energy/coaching/workout drilldown | P1 | foundation | unit + ui-runtime + visual |
| BF-0397 | Expandable HR zones 0–5 with reconciled durations/bpm/range | P0 | foundation | unit + ui-runtime |
| BF-0398 | Load/duration/day-HR/energy/steps trend cards and source-defined status | P0 | foundation | unit + visual |
| BF-0399 | Recovery unavailable state, why-no-data, insights and empty timeline | P0 | foundation | ui-runtime + visual |
| BF-0400 | Six independently sourced recovery trends, range/date/detail | P0 | foundation | integration + visual |
| BF-0401 | Sleep quality/duration/time-in-bed semantics, why-no-data, need/wind-down | P0 | foundation | unit + visual |
| BF-0402 | Typed sleep interval, wind-down/target/wake/need radial and timeline | P0 | foundation | unit + device + visual |
| BF-0403 | Meaningful range-specific sleep/REM/deep/HR-drop/balance trends | P0 | foundation | unit + visual |
| BF-0404 | Sleep-balance/wake/onset continuation with honest empty states | P0 | foundation | unit + visual |
| BF-0405 | Stress hero, HRV/HR/coaching and interpretable daily chart | P1 | foundation | unit + visual |
| BF-0406 | Stress month calendar/rings/navigation/today/info | P1 | foundation | ui-runtime + visual |
| BF-0407 | Intraday 0–100 chart, time axis, duration and reconciled bands | P0 | foundation | unit + visual |
| BF-0408 | Stress/non-activity/sleep-stress trends with independent availability | P0 | foundation | unit + visual |
| BF-0409 | Stress tabs, average, ranges, calendar navigation and scrubbing | P1 | foundation | ui-runtime + visual |
| BF-0410 | Source-defined stress bands, multi-window analysis and resources | P0 | foundation | unit + visual |
| BF-0411 | Non-activity stress drilldown parity and range analysis | P1 | foundation | ui-runtime + visual |
| BF-0412 | Non-activity resources/explanation and provenance | P1 | foundation | source + visual |
| BF-0413 | Energy Reserve level/charge/discharge/coaching/daily chart with uncertainty | P0 | foundation | unit + visual |
| BF-0414 | Energy intraday chart and expenditure/activity event reconciliation | P0 | foundation | integration + visual |
| BF-0415 | Nutrition quality/protocol/library/goals with honest locked state | P0 | foundation | integration + visual |
| BF-0416 | Macro units/progress, net-energy sign convention and quality contributions | P0 | foundation | unit + visual |
| BF-0417 | Food-quality categories and explicit glucose unavailable/observed state | P0 | foundation | integration + visual |
| BF-0418 | Durable meal timeline, empty meal, ranges and trends navigation | P0 | foundation | integration + ui-runtime |
| BF-0419 | Nutrition/macro/net-energy/glucose trends with independent empty states | P0 | foundation | integration + visual |
| BF-0420 | Macro drilldown/date/tabs/chart/ranges/average-total semantics | P1 | foundation | unit + ui-runtime |
| BF-0421 | Macro week table across periods with average/total reconciliation | P1 | foundation | unit + visual |
| BF-0422 | Net-energy eaten/burned chart, ranges and analysis | P0 | foundation | integration + visual |
| BF-0423 | Net-energy multi-window table and deficit/average/total semantics | P0 | foundation | unit + visual |
| BF-0424 | Performance target uncertainty/chart/zone/status breakdown | P0 | foundation | unit + visual |
| BF-0425 | Cardio-load trend/status breakdown with calibrating/no-data truth | P0 | foundation | unit + visual |
| BF-0426 | Cardio-focus filters/splits/trends/no-data | P0 | foundation | unit + ui-runtime |
| BF-0427 | Durable hydration day/history/none/add/settings workflow | P1 | missing | integration + ui-runtime |
| BF-0428 | Hydration add/edit quantity/unit/time/journal confirmation | P1 | missing | unit + ui-runtime |
| BF-0429 | Hydration goal/preset/nightly reminder persistence | P1 | missing | integration + device |
| BF-0430 | Caffeine history/none/quick/custom workflow | P1 | missing | integration + ui-runtime |
| BF-0431 | Caffeine goal/quick/nightly/recommended-context settings | P1 | missing | integration + device |
| BF-0432 | Alcohol history/alcohol-free/none/quick/custom/settings workflow | P1 | missing | integration + ui-runtime |
| BF-0433 | Durable historical Active/Sick/Injured/Training break annotation and recomputation audit | P0 | foundation | unit + integration |

## B. Revolut Finance feature rows — 21 scored leaves

Source: both recordings in `Revolut Reference/`; timecodes are preserved in the
archived reference matrix.

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| RF-01 | Finance overview: search/profile, linked accounts, spend, watchlist, navigation | P0 | foundation | live-readonly + ui-runtime + visual |
| RF-02 | Travel globe/map, percent/country/trip counts, auto/manual add, Reduce Motion | P1 | missing | integration + ui-runtime + visual |
| RF-03 | Analytics overview: wealth, spending-abroad and working Tool routes | P1 | foundation | ui-runtime |
| RF-04 | Durable validated budget amount/cycle setup | P0 | missing | unit + integration + ui-runtime |
| RF-05 | Automatic income-sorting CRUD and deterministic allocation preview | P0 | missing | unit + integration |
| RF-06 | Wealth allocation categories, percentages, add/consent flow | P0 | foundation | live-readonly + ui-runtime |
| RF-07 | Wealth observations/projection data, axes and exact-value semantics | P0 | foundation | unit + ui-runtime + visual |
| RF-08 | Income line/bar/ring modes, ranges, weekly bars and category management | P0 | missing | integration + ui-runtime + visual |
| RF-09 | Income category totals/count/percent/transaction drilldown | P0 | foundation | unit + ui-runtime |
| RF-10 | Net cash flow income/spend series, signed categories and periods | P0 | foundation | unit + visual |
| RF-11 | Spending modes/categories/percent/count/transactions | P0 | foundation | unit + ui-runtime + visual |
| RF-12 | Back/navigation preserves selected Finance context | P1 | foundation | ui-runtime |
| RF-13 | Income/expense tracking preferences, frequency/date, save/cancel | P1 | missing | integration + ui-runtime |
| RF-14 | Income selected amount/category updates across mode/range | P1 | missing | ui-runtime + visual |
| RF-15 | Income category ring and timestamped merchant/source transactions | P0 | foundation | unit + ui-runtime |
| RF-16 | Selected-day/value data semantics and accessible textual summary | P1 | foundation | unit + ui-runtime |
| RF-17 | Spending period average/category summary and restored context | P1 | foundation | unit + ui-runtime |
| RF-18 | Spending merchant/date/amount/source drilldown and reconciliation | P0 | foundation | unit + ui-runtime |
| RF-19 | Net-cash-flow graph/bar switch and category selection | P1 | foundation | ui-runtime + visual |
| RF-20 | Overview wealth/travel scroll context and routes | P1 | foundation | ui-runtime |
| RF-21 | Wealth range/asset selection retains context through Tools/end-to-end routes | P1 | foundation | ui-runtime + visual |

### Revolut motion quality — six additional scored leaves

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| RM-01 | Source card and destination header are one continuous hero morph | P1 | foundation | ui-runtime + milestone-visual |
| RM-02 | One-shot ring sweep; transient halo removed at rest; static RM fallback | P1 | foundation | ui-runtime + milestone-visual |
| RM-03 | Stroke trims left-to-right with synchronized gradient mask; static RM fallback | P1 | foundation | ui-runtime + milestone-visual |
| RM-04 | Continuous nearest-point touch/hover tracking and bubble motion (data/AX semantics live in RF-16) | P1 | foundation | ui-runtime + milestone-visual |
| RM-05 | One moving spring pill for exact 1W/1M/6M/1Y/Max; instant RM fallback | P1 | foundation | ui-runtime + milestone-visual |
| RM-06 | In-place numeric text updates without unrelated layout movement | P1 | foundation | ui-runtime + milestone-visual |

## C. Calendar runtime definition of done — 10 scored leaves

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| CA-01 | Continuous virtualized day-window swipe; fast fling can cross a boundary | P0 | foundation | ui-runtime |
| CA-02 | Header month/week and column headers track the in-flight swipe | P1 | foundation | ui-runtime + milestone-visual |
| CA-03 | Today retarget behaves correctly for near and far destinations | P1 | foundation | ui-runtime |
| CA-04 | Month expand/collapse morph, selected range, week numbers and today geometry | P1 | foundation | ui-runtime + milestone-visual |
| CA-05 | Create is deliberate; Mac pointer anchor/date/12:00–12:30/cancel/relaunch pass | P0 | foundation | ui-runtime |
| CA-06 | Full searchable emoji/system/custom picker, persistence and true no-icon | P1 | foundation | ui-runtime + milestone-visual |
| CA-07 | Compact event detail editing preserves cross-day/DST truth and save failures | P0 | foundation | unit + ui-runtime |
| CA-08 | Now-line/time label/all-day row update and remain aligned | P1 | foundation | unit + ui-runtime |
| CA-09 | Overlap/stacking plus move/resize/month drag/auto-scroll/undo/Escape persist safely | P0 | foundation | unit + ui-runtime |
| CA-10 | Reduce Motion, keyboard, VoiceOver/custom actions and focus alternatives all work | P0 | foundation | device + ui-runtime |

## D. Widget catalog — 16 scored leaves

| ID | Widget / aliases | Severity | Current | Required evidence |
|---|---|---:|---|---|
| WG-01 | Calendar — Notion style | P1 | foundation | device + milestone-visual |
| WG-02 | Next Event | P1 | foundation | device + milestone-visual |
| WG-03 | Usage Ring small | P1 | foundation | device + milestone-visual |
| WG-04 | Usage Ring + Trend medium | P1 | foundation | device + milestone-visual |
| WG-05 | Usage Ring lock circular | P1 | foundation | device + milestone-visual |
| WG-06 | Finance Net Worth Trend | P1 | foundation | device + milestone-visual |
| WG-07 | Finance Spend Ring | P1 | foundation | device + milestone-visual |
| WG-08 | Finance Cash Flow Sparkline | P1 | foundation | device + milestone-visual |
| WG-09 | Fitness Health Monitor Bars (`IMG_0649`) | P0 | foundation | integration + device + milestone-visual |
| WG-10 | Today's Tasks remains selectable with a truthful unavailable/setup route until Tasks exists | P1 | foundation | integration + device |
| WG-11 | Nutrition Overview (`IMG_0645`) | P0 | foundation | device + integration + milestone-visual |
| WG-12 | Calories & Macros (`IMG_0646`) | P0 | foundation | device + integration + milestone-visual |
| WG-13 | Net Energy Trend (`IMG_0647`) | P0 | foundation | device + integration + milestone-visual |
| WG-14 | Daily Overview (`IMG_0648`) | P0 | foundation | integration + device + milestone-visual |
| WG-15 | Stress Trend (`IMG_0650`) | P0 | foundation | integration + device + milestone-visual |
| WG-16 | Energy Reserve Trend (`IMG_0651`) | P0 | foundation | integration + device + milestone-visual |

Every widget leaf requires deterministic provider/payload/freshness/privacy/
deep-link tests. One consolidated T7/prerelease device matrix proves catalog and
gallery behavior. Milestone visuals cover the seven exact Bevel targets plus
representative Calendar, Usage and Finance families—not sixteen independent
visual campaigns. Production publishing/live-source proof is scored separately
below. The seven Bevel aliases require exact iPhone `.systemMedium` evidence and
their frame-specific actions/routes; they do not create extra scored rows.

## E. Cross-cutting product and release leaves — initial scaffold

T0 must expand any row that contains multiple independently fail-able behaviors;
splitting after the registry freezes is prohibited without a recorded decision
and a new registry hash.

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| IA-01 | Mac primary IA is exactly Home/Calendar/Finance/Fitness/Tax/Settings | P0 | foundation | source + ui-runtime |
| IA-02 | iOS tabs are Home/Calendar/Finance/Fitness/More; Usage Home-owned | P0 | foundation | source + ui-runtime |
| IA-03 | No dead release destination, duplicate concept, or fabricated normal KPI | P0 | foundation | source + ui-runtime |
| UX-01 | Black/white-led hierarchy, semantic accents, subtle gradients, no resting glow | P1 | foundation | milestone-visual |
| UX-02 | Every Mac release area responsive at narrow/default/max without orphan grids | P1 | foundation | milestone-visual |
| UX-03 | Hover/focus only signals action, precision or disclosure; static cards stay still | P1 | foundation | ui-runtime + milestone-visual |
| ST-01 | Settings OAuth/PKCE initiate/callback/pending/authorized/expiry/failure/revoke/retry; no raw token | P0 | missing | integration + ui-runtime |
| ST-02 | Settings HealthKit/device unavailable/pending/denied/authorized/revoked lifecycle | P0 | missing | device + ui-runtime |
| ST-03 | Settings bank/provider status, consent, expiry, revoke, retry and diagnostics lifecycle | P0 | missing | integration + ui-runtime |
| US-01 | One Usage route with durable daily history and actual/estimate/projection truth | P0 | foundation | integration + ui-runtime |
| US-02 | Every Usage fact/provider capability has a sourced wire field or unavailable state | P0 | foundation | unit + integration |
| NU-01 | Manual/barcode/photo proposals never enter totals/sync/widgets before confirmation | P0 | foundation | unit + integration |
| NU-02 | Food-photo held-out accuracy, correction lineage, consent, deletion and retention pass | P0 | missing | integration + operator |
| SU-01 | Supplement plans/schedules/actions/inventory/refills persist and sync idempotently | P0 | foundation | integration + device |
| SU-02 | Launch-time notification delegate implements `willPresent` and `didReceive`; validates occurrence, persists idempotently before completion, handles foreground/background/terminated Taken/Snooze/Skip, relaunch/DST/denial/lock screen | P0 | missing | device + integration |
| SY-01 | BitLocker C/D verified before deployment/credentials | P0 | blocked-external | operator |
| SY-02 | Tracked gateway identity/ACL/loopback/direct-listener/forged-header negatives pass | P0 | missing | security-negative |
| SY-03 | Dual-auth canary/rollback passes before transitional bearer removal | P0 | missing | security-negative + operator |
| SY-04 | Exact private host and App Group injected only by signed release configuration | P0 | blocked-external | device + security-negative |
| SY-05 | Calendar server ETag/If-Match conflict returns truth; bounded merge retry, no blind PUT | P0 | missing | integration |
| DT-02 | Encryption/key custody/protection/atomicity/backup/export/delete/locked-device proven | P0 | missing | device + integration |
| DT-03 | Rolling 12-month retention: max 3 images/meal, originals 90d, detail 365d, derivatives <=500 KiB; 8/9 GiB warnings, 10 GiB ingest gate; all storage classes; transactional compaction/export/provenance and never silent deletion | P0 | missing | integration + performance |
| SG-01 | Release xcconfig fails on placeholders/unknown/empty/unresolved/fixture flags | P0 | missing | source + integration |
| SG-02 | Signed apps/extensions pass strict signature/entitlement/App Group inspection | P0 | blocked-external | device |
| QA-01 | Committed isolated Xcode schemes/plans run with nonzero expected test counts | P0 | missing | integration |
| QA-02 | Pointer runner materialization is isolated; cancellation/zero-test never passes | P0 | foundation | ui-runtime |
| QA-03 | Accessibility audit, Dynamic Type, VoiceOver, Reduce Motion pass thresholds | P0 | missing | device |
| QA-04 | Launch/render/scroll/storage performance pass frozen thresholds | P1 | missing | performance |
| QA-05 | Final iPhone/Mac visual and interaction review accepted by geonq | P0 | blocked-external | operator + milestone-visual |

## F. Gateway, collectors, Clipper and production truth

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| GW-01 | Tracked approved gateway authenticates and bounds Calendar/WS/Usage/Finance/Clipper/Nutrition/Fitness/Supplement routes; rejects direct listener, forged header, oversized body/response and timeout | P0 | missing | integration + security-negative |
| GW-02 | Windows provider secrets encrypted at rest with service-SID ACL, scoped load, rotation/revocation and fail-closed startup | P0 | missing | security-negative + operator |
| GW-03 | Codex collector reaches gateway→Node with auth/retry/restart and no prompt/file-content collection | P0 | foundation | integration + security-negative |
| GW-04 | Claude collector uses exact external→loopback route, dual auth, idempotent retry/replay and unauthorized rejection | P0 | foundation | integration + security-negative |
| CL-01 | Clipper authoritative source and supported fields are explicitly approved; unsupported values unavailable | P0 | blocked-external | operator + source |
| CL-02 | Clipper ingestion→gateway→typed API/client preserves integer cents, provenance, partial/stale and safe retry | P0 | missing | integration + live-readonly |
| CL-03 | Clipper Overview/detail workflow and connection/revoke/error states pass without fabricated normal data | P0 | foundation | ui-runtime + live-readonly |
| PR-01 | Fixture/demo routes are unreachable through production app/gateway config; `/health` cannot resemble live product data | P0 | missing | integration + security-negative |
| WS-01 | Confirmed app state publishes versioned protected per-module widget snapshots and coalesced budget-aware reloads | P0 | missing | integration + device |
| WS-02 | Widget providers read fresh/expired/locked snapshots after reload; reload is a request, never an immediate-display promise | P0 | missing | integration + device |

## G. Per-domain authority and synchronization

Each row must name authoritative source, schema/version, revision/idempotency,
offline queue, tombstone/deletion propagation, retention, and positive/negative
integration evidence before that domain is live-enabled.

| ID | Domain | Severity | Current | Required evidence |
|---|---|---:|---|---|
| DA-01 | Calendar authority plus ETag conflict/merge/crash behavior | P0 | foundation | integration |
| DA-02 | HealthKit/Fitness authority; explicit device-local exception or authenticated upload policy | P0 | missing | source + device + integration |
| DA-03 | Nutrition confirmed-record authority; drafts excluded | P0 | foundation | integration |
| DA-04 | Supplements schedule/occurrence/action/inventory authority | P0 | foundation | integration |
| DA-05 | Usage samples/aggregation/provider authority | P0 | foundation | integration |
| DA-06 | Finance account/transaction/budget/holding authority and reconciliation | P0 | missing | integration + live-readonly |
| DA-07 | Clipper snapshot authority and correction/revocation behavior | P0 | missing | integration + live-readonly |

## H. HealthKit and device-source gates

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| HK-01 | iOS-only HealthKit capability/entitlement plus `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription`; no macOS/fixture claim | P0 | missing | release-signature + device |
| HK-02 | `HKHealthStore.isHealthDataAvailable()` and restricted/unavailable handling | P0 | missing | device + ui-runtime |
| HK-03 | Separate read/write authorization; `authorizationStatus(for:)` for writes; read denial treated as indistinguishable from no readable samples | P0 | missing | device + ui-runtime |
| HK-04 | Anchored queries reconcile source/device, units, duplicates, revisions and deletions without zero fabrication | P0 | missing | unit + device + integration |
| HK-05 | Signed physical-device Helio/Zepp→HealthKit provenance and partial/stale/conflict evidence | P0 | blocked-external | device + live-readonly |

## I. Provider-specific connection and capability gates

| ID | Provider | Binding outcome | Severity | Current | Required evidence |
|---|---|---|---:|---|---|
| PC-01 | Sparkasse/GoCardless | consent/PKCE/token expiry/revoke/freshness/retry/live read-only | P0 | missing | integration + live-readonly |
| PC-02 | Revolut Personal | explicit supported/unavailable capability and consent lifecycle | P0 | missing | integration + live-readonly |
| PC-03 | Revolut Business | eligibility/consent/token lifecycle/freshness/revoke | P0 | missing | integration + live-readonly |
| PC-04 | Trade Republic | manual import parser/provenance/duplicates/reconciliation/reimport | P0 | missing | integration |
| PC-05 | Codex | wire capability/freshness/rate limit/history/scheduler/restart | P0 | foundation | integration + live-readonly |
| PC-06 | Claude | statusline capability/freshness/history/forwarder install/restart | P0 | foundation | integration + live-readonly |
| PC-07 | GLM | credential scope/wire capability/freshness/retry or explicit unavailable | P0 | missing | integration + live-readonly |
| PC-08 | DeepSeek | credential scope/wire capability/freshness/retry or explicit unavailable | P0 | missing | integration + live-readonly |
| PC-09 | Google AI Studio | credential scope/wire capability/freshness/retry or explicit unavailable | P0 | missing | integration + live-readonly |

## T0 freeze checklist

- [ ] Re-read all binding references and resolve the Calendar view-set conflict.
- [ ] Replace initial cross-cutting compound rows with atomic leaves.
- [ ] Add exact source paths and acceptance text to every leaf.
- [ ] Re-audit all `foundation`/`missing` statuses at the new producing commit.
- [ ] Add evidence/registry validator and run its negative tests.
- [ ] Record owners, dependencies, external-input IDs, artifact paths and SHA.
- [ ] Record fixed per-workstream numerators/denominators and registry SHA-256.
- [ ] Independent Luna/max review: no duplicates, omissions, split/merge gaming,
      stale evidence, fixture-live confusion, or P0 bypass.
- [ ] Only then change State to `FROZEN` and permit percentage reporting.
