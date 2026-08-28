# LifeOS acceptance registry

State: **FROZEN**
Created: 2026-08-13 from the binding Design repository and independent source,
contract, and evidence audits through app commit `f24388a`.

This file is the denominator for the 95% checkpoint after T0 completes. Until
every leaf has an exact acceptance statement, evidence type, owner, severity,
current status, and producing commit—and the validator records a registry
hash—no percentage is valid.

## Registry rules

- One behavior has one scored leaf. A reference may alias another leaf but may
  not increase the denominator. `IMG_0645–0651` alias widget rows `WG-11–WG-16`
  and `WG-09`; they are not seven extra rows.
- Statuses: `missing`, `foundation`, `blocked-external`, `accepted`. `accepted`
  requires immutable evidence at the recorded evidence commit; a
  canceled/zero-test result is not evidence. Fixture screenshots can prove
  layout only, never live data.
- Claim kinds: `live`, `interaction`, `operator`, and `layout-only`. Accepted
  `live` claims require at least one substantive real-data contract:
  `integration`, `device`, or `live-readonly`. Source, unit, UI, visual,
  security-negative, release-signature, or performance evidence cannot accept a
  live claim by itself. Accepted `interaction` claims require integration,
  UI-runtime, or
  device contract; explicitly profiled performance/layout interaction rows may
  use the bounded `interaction-performance` or `interaction-layout` contracts.
  Accepted `operator` claims require `operator`, or the bounded device plus
  release-signature/security-negative alternatives. Accepted `layout-only`
  claims require `milestone-visual` or `ui-runtime` and can never use
  `live-readonly`. Foundation rows may declare an incomplete future contract
  while UNFROZEN; every row must satisfy its bounded contract before FROZEN.
- Every P0 must be accepted. Aggregate >=95% is insufficient if any workstream
  is below 90% or geonq has not accepted the final visual/interaction review.
- Evidence types: `source`, `unit`, `integration`, `ui-runtime`, `device`,
  `milestone-visual`, `security-negative`, `operator`, `live-readonly`,
  `performance`, and `release-signature`. The validator rejects unknown types.
- Every release area must cover its applicable honest states: observed,
  unavailable, stale, partial/calibrating, fixture-only demo, pending/denied/
  revoked, and locked/redacted. Missing values never become zero.
- T0 must replace `TBD` values, reconcile the status against current source,
  write evidence paths and producing SHAs, validate unique IDs/aliases, and
  record `Frozen registry SHA-256:` here. Every accepted row also records a
  64-character `evidence_sha256`; local `repo://` artifacts are hashed from
  tracked repository content. Remote `https://` evidence is not accepted.
  This is unconditional; the legacy CLI path switch cannot disable it.

Frozen registry SHA-256: `bbea06f1f1d0cc874c8ac605cba920fd4a539b2286baaaf73e0cb7299cbd87c1`

## Machine contract

The fenced JSON block at the end of this file is normative metadata for the
Markdown tables above. `scripts/validate_acceptance_registry.py` materialises
each table row into a leaf with the complete contract: `id`, `aliases`,
`workstream`, `owner`, `severity`, exact `source` path(s), exact `acceptance`,
`evidence_types`, `evidence_path`, `evidence_sha256`, `producing_sha`, `threshold`,
`blocker`, and `status`, plus a bounded `claim_kind` enum.
`implementation_baseline_commit` (`f24388a`) is the audited app baseline;
the legacy nullable `registry_producing_commit` field is retained only for
schema compatibility and is not a trust anchor. The tracked `HEAD` blob proves
the frozen registry definition, while each accepted row's `producing_sha` (E)
independently binds its source and evidence artifact. Split definitions replace compound
scaffold rows with atomic leaves before scoring; their source rows are not
counted. The seven Bevel widget frame references are aliases of existing widget
leaves, never scored leaves. RF/RM boundaries and atomic keys are declared in
`non_overlap_groups` and are checked for duplicates. `--score` always fails
while State is `UNFROZEN`. Source locators are stable (`design://` resolves in
the LifeOS Design repository; `repo://` resolves to a tracked file in this app
repository) and do not embed a developer's absolute filesystem path. CI may pass
`--expected-commit` only as an intentional audit override: when supplied, accepted
leaves must have evidence produced by that resolved commit. Normal CI/local
validation does not pass `HEAD` as an evidence override. FROZEN validation
requires a real Git repository, an exact tracked `HEAD` registry blob, and
resolves every accepted E with `git cat-file`. No field attempts to embed the
SHA of the commit containing itself. Normal development CI validates this
integrity contract; final/release acceptance explicitly invokes `--score` so
the P0, 95%, and per-workstream gates do not make every intermediate tranche
red immediately after the denominator is frozen. The Native Apple workflow's
manual `final_acceptance` input invokes that gate in hosted CI as well.

## A. Bevel non-widget functional rows — 52 scored leaves

Source: `Bevel Reference/IMG_0382.jpeg`–`IMG_0433.jpeg`. `IMG_0380–0381`
are style-only and enforced through `UX-*`, not feature leaves.

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| BF-0382 | Transparent LifeOS load/strain gauge, inputs, reset/explanation; no Bevel formula claim | P0 | foundation | unit + device + visual |
| BF-0383 | Source-labelled recovery/readiness, wake timing, HRV explanation | P0 | foundation | unit + device + visual |
| BF-0384 | Date/share/profile/activity/weather plus Load/Recovery/Sleep/coaching/Stress/Energy/Nutrition routes | P0 | foundation | integration + ui-runtime + visual |
| BF-0385 | Macro/glucose surface plus six independently sourced Health Monitor metrics | P0 | foundation | integration + device + visual |
| BF-0386 | Health timeline rows, routing, reorder/filter/edit persistence | P1 | foundation | integration + ui-runtime |
| BF-0387 | Journal week/date navigation, pinned mood and daytime tags | P1 | foundation | unit + integration + ui-runtime + visual |
| BF-0388 | Journal night/day tags plus automatic goals with provenance | P0 | foundation | unit + integration |
| BF-0389 | Automatic goal completed/failed/neutral truth states | P0 | foundation | unit + integration + visual |
| BF-0390 | Remaining goals, exceeded/calibrating semantics, date selection | P0 | foundation | unit + integration + visual |
| BF-0391 | 30-day activity calendar/counts/chart and source-defined performance target | P1 | foundation | unit + integration + ui-runtime + visual |
| BF-0392 | Cardio load/focus/recovery and Strength volume with reviewed units | P0 | foundation | unit + device |
| BF-0393 | Strength anatomy/groups, progress, templates and add workflow | P1 | foundation | unit + integration + ui-runtime + visual |
| BF-0394 | Biology gated age/date/radial and biomarker navigation | P0 | foundation | unit + device + visual |
| BF-0395 | Weight/HRV/RHR/body-fat/fat-free/VO2 trends and show-all | P0 | foundation | integration + device |
| BF-0396 | Load detail/date/target/duration/energy/coaching/workout drilldown | P1 | foundation | unit + integration + ui-runtime + visual |
| BF-0397 | Expandable HR zones 0–5 with reconciled durations/bpm/range | P0 | foundation | unit + integration + ui-runtime |
| BF-0398 | Load/duration/day-HR/energy/steps trend cards and source-defined status | P0 | foundation | unit + integration + visual |
| BF-0399 | Recovery unavailable state, why-no-data, insights and empty timeline | P0 | foundation | integration + ui-runtime + visual |
| BF-0400 | Six independently sourced recovery trends, range/date/detail | P0 | foundation | integration + visual |
| BF-0401 | Sleep quality/duration/time-in-bed semantics, why-no-data, need/wind-down | P0 | foundation | unit + integration + visual |
| BF-0402 | Typed sleep interval, wind-down/target/wake/need radial and timeline | P0 | foundation | unit + device + visual |
| BF-0403 | Meaningful range-specific sleep/REM/deep/HR-drop/balance trends | P0 | foundation | unit + integration + visual |
| BF-0404 | Sleep-balance/wake/onset continuation with honest empty states | P0 | foundation | unit + integration + visual |
| BF-0405 | Stress hero, HRV/HR/coaching and interpretable daily chart | P1 | foundation | unit + integration + visual |
| BF-0406 | Stress month calendar/rings/navigation/today/info | P1 | foundation | integration + ui-runtime + visual |
| BF-0407 | Intraday 0–100 chart, time axis, duration and reconciled bands | P0 | foundation | unit + integration + visual |
| BF-0408 | Stress/non-activity/sleep-stress trends with independent availability | P0 | foundation | unit + integration + visual |
| BF-0409 | Stress tabs, average, ranges, calendar navigation and scrubbing | P1 | foundation | integration + ui-runtime + visual |
| BF-0410 | Source-defined stress bands, multi-window analysis and resources | P0 | foundation | unit + integration + visual |
| BF-0411 | Non-activity stress drilldown parity and range analysis | P1 | foundation | integration + ui-runtime + visual |
| BF-0412 | Non-activity resources/explanation and provenance | P1 | foundation | source + integration + visual |
| BF-0413 | Energy Reserve level/charge/discharge/coaching/daily chart with uncertainty | P0 | foundation | unit + integration + visual |
| BF-0414 | Energy intraday chart and expenditure/activity event reconciliation | P0 | foundation | integration + visual |
| BF-0415 | Nutrition quality/protocol/library/goals with honest locked state | P0 | foundation | integration + visual |
| BF-0416 | Macro units/progress, net-energy sign convention and quality contributions | P0 | foundation | unit + integration + visual |
| BF-0417 | Food-quality categories and explicit glucose unavailable/observed state | P0 | foundation | integration + visual |
| BF-0418 | Durable meal timeline, empty meal, ranges and trends navigation | P0 | foundation | integration + ui-runtime |
| BF-0419 | Nutrition/macro/net-energy/glucose trends with independent empty states | P0 | foundation | integration + visual |
| BF-0420 | Macro drilldown/date/tabs/chart/ranges/average-total semantics | P1 | foundation | unit + integration + ui-runtime |
| BF-0421 | Macro week table across periods with average/total reconciliation | P1 | foundation | unit + integration + visual |
| BF-0422 | Net-energy eaten/burned chart, ranges and analysis | P0 | foundation | integration + visual |
| BF-0423 | Net-energy multi-window table and deficit/average/total semantics | P0 | foundation | unit + integration + visual |
| BF-0424 | Performance target uncertainty/chart/zone/status breakdown | P0 | foundation | unit + integration + visual |
| BF-0425 | Cardio-load trend/status breakdown with calibrating/no-data truth | P0 | foundation | unit + integration + visual |
| BF-0426 | Cardio-focus filters/splits/trends/no-data | P0 | foundation | unit + integration + ui-runtime |
| BF-0427 | Durable hydration day/history/none/add/settings workflow | P1 | foundation | integration + ui-runtime |
| BF-0428 | Hydration add/edit quantity/unit/time/journal confirmation | P1 | foundation | unit + integration + ui-runtime |
| BF-0429 | Hydration goal/preset/nightly reminder persistence | P1 | missing | integration + device |
| BF-0430 | Caffeine history/none/quick/custom workflow | P1 | foundation | integration + ui-runtime |
| BF-0431 | Caffeine goal/quick/nightly/recommended-context settings | P1 | missing | integration + device |
| BF-0432 | Alcohol history/alcohol-free/none/quick/custom/settings workflow | P1 | foundation | integration + ui-runtime |
| BF-0433 | Durable historical Active/Sick/Injured/Training break annotation and recomputation audit | P0 | foundation | unit + integration |

## B. Revolut Finance feature rows — 21 scored leaves

Source: both recordings in `Revolut Reference/`; timecodes are preserved in the
archived reference matrix.

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| RF-01 | Finance overview: search/profile, linked accounts, spend, watchlist, navigation | P0 | foundation | live-readonly + ui-runtime + visual |
| RF-02 | Travel globe/map, percent/country/trip counts, auto/manual add, Reduce Motion | P1 | missing | integration + ui-runtime + visual |
| RF-03 | Analytics overview: wealth, spending-abroad and working Tool routes | P1 | missing | integration + ui-runtime |
| RF-04 | Durable validated budget amount/cycle setup | P0 | missing | unit + integration + ui-runtime |
| RF-05 | Automatic income-sorting CRUD and deterministic allocation preview | P0 | missing | unit + integration |
| RF-06 | Wealth allocation categories, percentages, add/consent flow | P0 | missing | live-readonly + ui-runtime |
| RF-07 | Wealth observations/projection data, axes and exact-value semantics | P0 | missing | unit + integration + ui-runtime + visual |
| RF-08 | Income line/bar/ring modes, ranges, weekly bars and category management | P0 | missing | integration + ui-runtime + visual |
| RF-09 | Income category totals/count/percent/transaction drilldown | P0 | foundation | unit + integration + ui-runtime |
| RF-10 | Net cash flow income/spend series, signed categories and periods | P0 | foundation | unit + integration + visual |
| RF-11 | Spending modes/categories/percent/count/transactions | P0 | foundation | unit + integration + ui-runtime + visual |
| RF-12 | Back/navigation preserves selected Finance context | P1 | foundation | ui-runtime |
| RF-13 | Income/expense tracking preferences, frequency/date, save/cancel | P1 | missing | integration + ui-runtime |
| RF-14 | Income selected amount/category updates across mode/range | P1 | missing | integration + ui-runtime + visual |
| RF-15 | Income category ring and timestamped merchant/source transactions | P0 | foundation | unit + integration + ui-runtime |
| RF-16 | Selected-day/value data semantics and accessible textual summary | P1 | foundation | unit + integration + ui-runtime |
| RF-17 | Spending period average/category summary and restored context | P1 | foundation | unit + integration + ui-runtime |
| RF-18 | Spending merchant/date/amount/source drilldown and reconciliation | P0 | foundation | unit + integration + ui-runtime |
| RF-19 | Net-cash-flow graph/bar switch and category selection | P1 | foundation | ui-runtime + visual |
| RF-20 | Overview wealth/travel scroll context and routes | P1 | missing | ui-runtime |
| RF-21 | Wealth range/asset selection retains context through Tools/end-to-end routes | P1 | missing | ui-runtime + visual |

### Revolut motion quality — six additional scored leaves

| ID | Binding outcome | Severity | Current | Required evidence |
|---|---|---:|---|---|
| RM-01 | Source card and destination header are one continuous hero morph | P1 | foundation | ui-runtime + milestone-visual |
| RM-02 | One-shot ring sweep; transient halo removed at rest; static RM fallback | P1 | foundation | ui-runtime + milestone-visual |
| RM-03 | Stroke trims left-to-right with synchronized gradient mask; static RM fallback | P1 | foundation | ui-runtime + milestone-visual |
| RM-04 | Continuous nearest-point touch/hover tracking and bubble motion (data/AX semantics live in RF-16) | P1 | foundation | ui-runtime + milestone-visual |
| RM-05 | One moving spring pill for exact 1W/1M/6M/1Y/Max; instant RM fallback | P1 | foundation | ui-runtime + milestone-visual |
| RM-06 | In-place numeric text updates without unrelated layout movement | P1 | foundation | ui-runtime + milestone-visual |

## C. Calendar runtime definition of done — 13 scored leaves

Binding platform split (from `design://developers/design-coordination/00-READ-FIRST.md`):
iOS follows the compact Figma mobile/current interaction layout; macOS keeps the
five-view sidebar plus inspector layout from the Calendar module contract. The
macOS shell leaves below are scored separately; neither platform may substitute
for the other.

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
| CA-11 | macOS exposes the five-view Day/Week/Month/Timeline/Agenda switcher and each view preserves the selected date/context | P0 | foundation | source + ui-runtime |
| CA-12 | macOS has a collapsible sidebar with mini-calendar, calendar list, and per-calendar filters that preserve the main grid context | P1 | foundation | ui-runtime + milestone-visual |
| CA-13 | macOS keeps a persistent right inspector for selected event editing while preserving grid position, date, and selection context | P0 | foundation | unit + ui-runtime |

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
| US-01 | Usage route, durable history, source-truth metadata, hero shell, honesty banner, tabs, account switcher, and range controls (expanded into atomic leaves below) | P0 | foundation | integration + ui-runtime |
| US-02 | Usage facts, provider capability labels, Facts rows, projection/bar charts, selection controls, model mix, heatmap, and honest states (expanded into atomic leaves below) | P0 | foundation | unit + integration |
| NU-01 | Manual/barcode/photo proposals never enter totals/sync/widgets before confirmation | P0 | foundation | unit + integration |
| NU-02 | Food-photo held-out accuracy, correction lineage, consent, deletion and retention pass | P0 | foundation | integration + operator |
| NU-03 | Gateway-owned Open Food Facts barcode/package lookup validates and provenance-labels responses; honest misses fall back to manual/package-label entry without fabricated nutrition | P0 | foundation | integration + live-readonly |
| SU-01 | Supplement plans/schedules/actions/inventory/refills persist and sync idempotently | P0 | foundation | integration + device |
| SU-02 | Launch-time notification delegate implements `willPresent` and `didReceive`; validates occurrence, persists idempotently before completion, handles foreground/background/terminated Taken/Snooze/Skip, relaunch/DST/denial/lock screen | P0 | foundation | device + integration |
| SY-01 | BitLocker C/D verified before deployment/credentials | P0 | blocked-external | operator |
| SY-02 | Tracked gateway identity/ACL/loopback/direct-listener/forged-header negatives pass | P0 | missing | security-negative |
| SY-03 | Dual-auth canary/rollback passes before transitional bearer removal | P0 | missing | security-negative + operator |
| SY-04 | Exact private host and App Group injected only by signed release configuration | P0 | blocked-external | device + security-negative |
| SY-05 | Calendar server ETag/If-Match conflict returns truth; bounded merge retry, no blind PUT | P0 | missing | integration |
| DT-02 | Encryption/key custody/protection/atomicity/backup/export/delete/locked-device proven | P0 | missing | device + integration |
| DT-03 | Rolling 12-month retention: max 3 images/meal, originals 90d, detail 365d, derivatives <=500 KiB; 8/9 GiB warnings, 10 GiB ingest gate; all storage classes; transactional compaction/export/provenance and never silent deletion | P0 | foundation | integration + performance |
| SG-01 | Release xcconfig fails on placeholders/unknown/empty/unresolved/fixture flags | P0 | foundation | source + integration |
| SG-02 | Signed apps/extensions pass strict signature/entitlement/App Group inspection | P0 | blocked-external | device |
| QA-01 | Committed isolated Xcode schemes/plans run with nonzero expected test counts | P0 | foundation | integration |
| QA-02 | Pointer runner materialization is isolated; cancellation/zero-test never passes | P0 | foundation | ui-runtime |
| QA-03 | Accessibility audit, Dynamic Type, VoiceOver, Reduce Motion pass thresholds | P0 | missing | device |
| QA-04 | Launch/render/scroll/storage performance pass frozen thresholds | P1 | missing | performance |
| QA-05 | Final iPhone/Mac visual and interaction review accepted by geonq | P0 | blocked-external | operator + milestone-visual |

The Usage source anchors above are deliberately expanded into 18 scored leaves by
the machine contract: `US-01A` route/history, `US-01B` observed-versus-estimated
truth, `US-01C` sourced reset/pace/runway/streak/credit facts, `US-01D` hero
shell metadata, `US-01E` provenance honesty banner, `US-01F` Graphs/Facts/Insights
tabs, `US-01G` graph/account switching, `US-01H` honest range controls,
`US-02A` sourced wire/unavailable facts, `US-02B` provider capability labels,
`US-02C` Facts rows, `US-02D` four-series projection chart, `US-02E` token
activity bar chart, `US-02F` pointer/touch/hover scrub, `US-02G` keyboard/stepper
selection, `US-02H` model mix, `US-02I` heatmap, and `US-02J` honest loading,
demo, unavailable, and Reduce Motion states. Chart style is covered by these
Usage leaves; no separate bklit/cross-cutting chart leaf is counted.

`NU-03` is intentionally separate from `NU-01B`: NU-01B proves that a barcode
proposal cannot enter totals before confirmation, while NU-03 proves the
gateway-owned Open Food Facts lookup, provenance/quality handling, and the
not-found/manual package-label fallback.

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
| WS-01 | Confirmed app state publishes versioned protected per-module widget snapshots and coalesced budget-aware reloads | P0 | foundation | integration + device |
| WS-02 | Widget providers read fresh/expired/locked snapshots after reload; reload is a request, never an immediate-display promise | P0 | foundation | integration + device |

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
| PC-01 | Sparkasse/Enable Banking | consent/session expiry/revoke/freshness/retry/live read-only | P0 | missing | integration + live-readonly |
| PC-02 | Revolut Personal | explicit supported/unavailable capability and consent lifecycle | P0 | missing | integration + live-readonly |
| PC-03 | Revolut Business | eligibility/consent/token lifecycle/freshness/revoke | P0 | missing | integration + live-readonly |
| PC-04 | Trade Republic | manual import parser/provenance/duplicates/reconciliation/reimport | P0 | missing | integration |
| PC-05 | Codex | wire capability/freshness/rate limit/history/scheduler/restart | P0 | foundation | integration + live-readonly |
| PC-06 | Claude | statusline capability/freshness/history/forwarder install/restart | P0 | foundation | integration + live-readonly |
| PC-07 | GLM | credential scope/wire capability/freshness/retry or explicit unavailable | P0 | missing | integration + live-readonly |
| PC-08 | DeepSeek | credential scope/wire capability/freshness/retry or explicit unavailable | P0 | missing | integration + live-readonly |
| PC-09 | Google AI Studio | credential scope/wire capability/freshness/retry or explicit unavailable | P0 | missing | integration + live-readonly |

## T0 freeze checklist

- [x] Re-read binding references and record the resolved Calendar platform split: iOS compact/Figma interaction layout; macOS five-view sidebar + inspector. The old `04` conflict note is stale.
- [x] Replace initial cross-cutting compound rows with atomic leaves.
- [x] Add exact source paths and acceptance text to every leaf.
- [x] Re-audit all `foundation`/`missing` statuses at the new producing commit.
- [x] Add evidence/registry validator and run its negative tests.
- [x] Record owners, dependencies, and external-input IDs; accepted rows must
  add tracked artifact paths, SHA-256, explicit result, and positive test count.
- [x] Record fixed per-workstream numerators/denominators and workstream map.
- [x] Record the reviewed freeze manifest and registry SHA-256.
- [x] Independent Luna/max review: no duplicates, omissions, split/merge gaming,
      stale evidence, fixture-live confusion, or P0 bypass.
- [x] Only then change State to `FROZEN` and permit percentage reporting.

<!-- acceptance-registry:data:start -->
```json
{
  "schema_version": 1,
  "state": "FROZEN",
  "implementation_baseline_commit": "f24388a82649a54ba5c9cf6567420c2d34b63fa6",
  "registry_producing_commit": null,
  "frozen_registry_sha256": "bbea06f1f1d0cc874c8ac605cba920fd4a539b2286baaaf73e0cb7299cbd87c1",
  "freeze_manifest": {
    "leaf_ids": [
      "BF-0382",
      "BF-0383",
      "BF-0384",
      "BF-0385",
      "BF-0386",
      "BF-0387",
      "BF-0388",
      "BF-0389",
      "BF-0390",
      "BF-0391",
      "BF-0392",
      "BF-0393",
      "BF-0394",
      "BF-0395",
      "BF-0396",
      "BF-0397",
      "BF-0398",
      "BF-0399",
      "BF-0400",
      "BF-0401",
      "BF-0402",
      "BF-0403",
      "BF-0404",
      "BF-0405",
      "BF-0406",
      "BF-0407",
      "BF-0408",
      "BF-0409",
      "BF-0410",
      "BF-0411",
      "BF-0412",
      "BF-0413",
      "BF-0414",
      "BF-0415",
      "BF-0416",
      "BF-0417",
      "BF-0418",
      "BF-0419",
      "BF-0420",
      "BF-0421",
      "BF-0422",
      "BF-0423",
      "BF-0424",
      "BF-0425",
      "BF-0426",
      "BF-0427",
      "BF-0428",
      "BF-0429",
      "BF-0430",
      "BF-0431",
      "BF-0432",
      "BF-0433",
      "CA-01",
      "CA-02",
      "CA-03",
      "CA-04",
      "CA-05",
      "CA-06",
      "CA-07",
      "CA-08",
      "CA-09",
      "CA-10",
      "CA-11",
      "CA-12",
      "CA-13",
      "CL-01",
      "CL-02A",
      "CL-02B",
      "CL-02C",
      "CL-03A",
      "CL-03B",
      "DA-01A",
      "DA-01B",
      "DA-02A",
      "DA-02B",
      "DA-03A",
      "DA-03B",
      "DA-04A",
      "DA-04B",
      "DA-05A",
      "DA-05B",
      "DA-06A",
      "DA-06B",
      "DA-07A",
      "DA-07B",
      "DT-02A",
      "DT-02B",
      "DT-02C",
      "DT-03A",
      "DT-03B",
      "DT-03C",
      "GW-01A",
      "GW-01B",
      "GW-01C",
      "GW-02A",
      "GW-02B",
      "GW-02C",
      "GW-03A",
      "GW-03B",
      "GW-04A",
      "GW-04B",
      "GW-04C",
      "HK-01A",
      "HK-01B",
      "HK-02A",
      "HK-02B",
      "HK-03A",
      "HK-03B",
      "HK-04A",
      "HK-04B",
      "HK-05A",
      "HK-05B",
      "IA-01",
      "IA-02",
      "IA-03A",
      "IA-03B",
      "IA-03C",
      "NU-01A",
      "NU-01B",
      "NU-01C",
      "NU-02A",
      "NU-02B",
      "NU-02C",
      "NU-02D",
      "NU-03",
      "PC-01A",
      "PC-01B",
      "PC-02A",
      "PC-02B",
      "PC-03A",
      "PC-03B",
      "PC-04A",
      "PC-04B",
      "PC-05A",
      "PC-05B",
      "PC-06A",
      "PC-06B",
      "PC-07A",
      "PC-07B",
      "PC-08A",
      "PC-08B",
      "PC-09A",
      "PC-09B",
      "PR-01A",
      "PR-01B",
      "QA-01A",
      "QA-01B",
      "QA-02A",
      "QA-02B",
      "QA-03A",
      "QA-03B",
      "QA-03C",
      "QA-04A",
      "QA-04B",
      "QA-04C",
      "QA-05",
      "RF-01",
      "RF-02",
      "RF-03",
      "RF-04",
      "RF-05",
      "RF-06",
      "RF-07",
      "RF-08",
      "RF-09",
      "RF-10",
      "RF-11",
      "RF-12",
      "RF-13",
      "RF-14",
      "RF-15",
      "RF-16",
      "RF-17",
      "RF-18",
      "RF-19",
      "RF-20",
      "RF-21",
      "RM-01",
      "RM-02",
      "RM-03",
      "RM-04",
      "RM-05",
      "RM-06",
      "SG-01A",
      "SG-01B",
      "SG-01C",
      "SG-02A",
      "SG-02B",
      "ST-01A",
      "ST-01B",
      "ST-01C",
      "ST-02A",
      "ST-02B",
      "ST-03A",
      "ST-03B",
      "SU-01A",
      "SU-01B",
      "SU-01C",
      "SU-02A",
      "SU-02B",
      "SU-02C",
      "SU-02D",
      "SY-01",
      "SY-02A",
      "SY-02B",
      "SY-02C",
      "SY-03A",
      "SY-03B",
      "SY-04A",
      "SY-04B",
      "SY-05A",
      "SY-05B",
      "SY-05C",
      "US-01A",
      "US-01B",
      "US-01C",
      "US-01D",
      "US-01E",
      "US-01F",
      "US-01G",
      "US-01H",
      "US-02A",
      "US-02B",
      "US-02C",
      "US-02D",
      "US-02E",
      "US-02F",
      "US-02G",
      "US-02H",
      "US-02I",
      "US-02J",
      "UX-01A",
      "UX-01B",
      "UX-01C",
      "UX-02A",
      "UX-02B",
      "UX-03A",
      "UX-03B",
      "WG-01",
      "WG-02",
      "WG-03",
      "WG-04",
      "WG-05",
      "WG-06",
      "WG-07",
      "WG-08",
      "WG-09",
      "WG-10",
      "WG-11",
      "WG-12",
      "WG-13",
      "WG-14",
      "WG-15",
      "WG-16",
      "WS-01A",
      "WS-01B",
      "WS-02A",
      "WS-02B"
    ],
    "aliases": {
      "IMG_0645": "WG-11",
      "IMG_0646": "WG-12",
      "IMG_0647": "WG-13",
      "IMG_0648": "WG-14",
      "IMG_0649": "WG-09",
      "IMG_0650": "WG-15",
      "IMG_0651": "WG-16"
    },
    "split_map": {
      "IA-03": [
        "IA-03A",
        "IA-03B",
        "IA-03C"
      ],
      "UX-01": [
        "UX-01A",
        "UX-01B",
        "UX-01C"
      ],
      "UX-02": [
        "UX-02A",
        "UX-02B"
      ],
      "UX-03": [
        "UX-03A",
        "UX-03B"
      ],
      "ST-01": [
        "ST-01A",
        "ST-01B",
        "ST-01C"
      ],
      "ST-02": [
        "ST-02A",
        "ST-02B"
      ],
      "ST-03": [
        "ST-03A",
        "ST-03B"
      ],
      "US-01": [
        "US-01A",
        "US-01B",
        "US-01C",
        "US-01D",
        "US-01E",
        "US-01F",
        "US-01G",
        "US-01H"
      ],
      "US-02": [
        "US-02A",
        "US-02B",
        "US-02C",
        "US-02D",
        "US-02E",
        "US-02F",
        "US-02G",
        "US-02H",
        "US-02I",
        "US-02J"
      ],
      "NU-01": [
        "NU-01A",
        "NU-01B",
        "NU-01C"
      ],
      "NU-02": [
        "NU-02A",
        "NU-02B",
        "NU-02C",
        "NU-02D"
      ],
      "SU-01": [
        "SU-01A",
        "SU-01B",
        "SU-01C"
      ],
      "SU-02": [
        "SU-02A",
        "SU-02B",
        "SU-02C",
        "SU-02D"
      ],
      "SY-02": [
        "SY-02A",
        "SY-02B",
        "SY-02C"
      ],
      "SY-03": [
        "SY-03A",
        "SY-03B"
      ],
      "SY-04": [
        "SY-04A",
        "SY-04B"
      ],
      "SY-05": [
        "SY-05A",
        "SY-05B",
        "SY-05C"
      ],
      "DT-02": [
        "DT-02A",
        "DT-02B",
        "DT-02C"
      ],
      "DT-03": [
        "DT-03A",
        "DT-03B",
        "DT-03C"
      ],
      "SG-01": [
        "SG-01A",
        "SG-01B",
        "SG-01C"
      ],
      "SG-02": [
        "SG-02A",
        "SG-02B"
      ],
      "QA-01": [
        "QA-01A",
        "QA-01B"
      ],
      "QA-02": [
        "QA-02A",
        "QA-02B"
      ],
      "QA-03": [
        "QA-03A",
        "QA-03B",
        "QA-03C"
      ],
      "QA-04": [
        "QA-04A",
        "QA-04B",
        "QA-04C"
      ],
      "GW-01": [
        "GW-01A",
        "GW-01B",
        "GW-01C"
      ],
      "GW-02": [
        "GW-02A",
        "GW-02B",
        "GW-02C"
      ],
      "GW-03": [
        "GW-03A",
        "GW-03B"
      ],
      "GW-04": [
        "GW-04A",
        "GW-04B",
        "GW-04C"
      ],
      "CL-02": [
        "CL-02A",
        "CL-02B",
        "CL-02C"
      ],
      "CL-03": [
        "CL-03A",
        "CL-03B"
      ],
      "PR-01": [
        "PR-01A",
        "PR-01B"
      ],
      "WS-01": [
        "WS-01A",
        "WS-01B"
      ],
      "WS-02": [
        "WS-02A",
        "WS-02B"
      ],
      "DA-01": [
        "DA-01A",
        "DA-01B"
      ],
      "DA-02": [
        "DA-02A",
        "DA-02B"
      ],
      "DA-03": [
        "DA-03A",
        "DA-03B"
      ],
      "DA-04": [
        "DA-04A",
        "DA-04B"
      ],
      "DA-05": [
        "DA-05A",
        "DA-05B"
      ],
      "DA-06": [
        "DA-06A",
        "DA-06B"
      ],
      "DA-07": [
        "DA-07A",
        "DA-07B"
      ],
      "HK-01": [
        "HK-01A",
        "HK-01B"
      ],
      "HK-02": [
        "HK-02A",
        "HK-02B"
      ],
      "HK-03": [
        "HK-03A",
        "HK-03B"
      ],
      "HK-04": [
        "HK-04A",
        "HK-04B"
      ],
      "HK-05": [
        "HK-05A",
        "HK-05B"
      ],
      "PC-01": [
        "PC-01A",
        "PC-01B"
      ],
      "PC-02": [
        "PC-02A",
        "PC-02B"
      ],
      "PC-03": [
        "PC-03A",
        "PC-03B"
      ],
      "PC-04": [
        "PC-04A",
        "PC-04B"
      ],
      "PC-05": [
        "PC-05A",
        "PC-05B"
      ],
      "PC-06": [
        "PC-06A",
        "PC-06B"
      ],
      "PC-07": [
        "PC-07A",
        "PC-07B"
      ],
      "PC-08": [
        "PC-08A",
        "PC-08B"
      ],
      "PC-09": [
        "PC-09A",
        "PC-09B"
      ]
    },
    "atomic_keys": {
      "BF-0382": "BF-0382",
      "BF-0383": "BF-0383",
      "BF-0384": "BF-0384",
      "BF-0385": "BF-0385",
      "BF-0386": "BF-0386",
      "BF-0387": "BF-0387",
      "BF-0388": "BF-0388",
      "BF-0389": "BF-0389",
      "BF-0390": "BF-0390",
      "BF-0391": "BF-0391",
      "BF-0392": "BF-0392",
      "BF-0393": "BF-0393",
      "BF-0394": "BF-0394",
      "BF-0395": "BF-0395",
      "BF-0396": "BF-0396",
      "BF-0397": "BF-0397",
      "BF-0398": "BF-0398",
      "BF-0399": "BF-0399",
      "BF-0400": "BF-0400",
      "BF-0401": "BF-0401",
      "BF-0402": "BF-0402",
      "BF-0403": "BF-0403",
      "BF-0404": "BF-0404",
      "BF-0405": "BF-0405",
      "BF-0406": "BF-0406",
      "BF-0407": "BF-0407",
      "BF-0408": "BF-0408",
      "BF-0409": "BF-0409",
      "BF-0410": "BF-0410",
      "BF-0411": "BF-0411",
      "BF-0412": "BF-0412",
      "BF-0413": "BF-0413",
      "BF-0414": "BF-0414",
      "BF-0415": "BF-0415",
      "BF-0416": "BF-0416",
      "BF-0417": "BF-0417",
      "BF-0418": "BF-0418",
      "BF-0419": "BF-0419",
      "BF-0420": "BF-0420",
      "BF-0421": "BF-0421",
      "BF-0422": "BF-0422",
      "BF-0423": "BF-0423",
      "BF-0424": "BF-0424",
      "BF-0425": "BF-0425",
      "BF-0426": "BF-0426",
      "BF-0427": "BF-0427",
      "BF-0428": "BF-0428",
      "BF-0429": "BF-0429",
      "BF-0430": "BF-0430",
      "BF-0431": "BF-0431",
      "BF-0432": "BF-0432",
      "BF-0433": "BF-0433",
      "RF-01": "finance.revolut.overview-content",
      "RF-02": "RF-02",
      "RF-03": "RF-03",
      "RF-04": "RF-04",
      "RF-05": "RF-05",
      "RF-06": "finance.revolut.wealth-allocation",
      "RF-07": "finance.revolut.chart-data-semantics",
      "RF-08": "RF-08",
      "RF-09": "RF-09",
      "RF-10": "RF-10",
      "RF-11": "RF-11",
      "RF-12": "RF-12",
      "RF-13": "RF-13",
      "RF-14": "finance.revolut.selected-amount-semantics",
      "RF-15": "RF-15",
      "RF-16": "finance.revolut.scrub-value-semantics",
      "RF-17": "RF-17",
      "RF-18": "RF-18",
      "RF-19": "RF-19",
      "RF-20": "RF-20",
      "RF-21": "finance.revolut.range-context",
      "RM-01": "finance.revolut.hero-morph-motion",
      "RM-02": "finance.revolut.ring-reveal-motion",
      "RM-03": "finance.revolut.chart-draw-motion",
      "RM-04": "finance.revolut.scrub-motion",
      "RM-05": "finance.revolut.range-pill-motion",
      "RM-06": "finance.revolut.numeric-update-motion",
      "CA-01": "CA-01",
      "CA-02": "CA-02",
      "CA-03": "CA-03",
      "CA-04": "CA-04",
      "CA-05": "CA-05",
      "CA-06": "CA-06",
      "CA-07": "CA-07",
      "CA-08": "CA-08",
      "CA-09": "CA-09",
      "CA-10": "CA-10",
      "CA-11": "CA-11",
      "CA-12": "CA-12",
      "CA-13": "CA-13",
      "WG-01": "WG-01",
      "WG-02": "WG-02",
      "WG-03": "WG-03",
      "WG-04": "WG-04",
      "WG-05": "WG-05",
      "WG-06": "WG-06",
      "WG-07": "WG-07",
      "WG-08": "WG-08",
      "WG-09": "WG-09",
      "WG-10": "WG-10",
      "WG-11": "WG-11",
      "WG-12": "WG-12",
      "WG-13": "WG-13",
      "WG-14": "WG-14",
      "WG-15": "WG-15",
      "WG-16": "WG-16",
      "IA-01": "IA-01",
      "IA-02": "IA-02",
      "NU-03": "nutrition.barcode.open-food-facts-gateway",
      "SY-01": "SY-01",
      "QA-05": "QA-05",
      "CL-01": "CL-01",
      "IA-03A": "IA-03A",
      "IA-03B": "IA-03B",
      "IA-03C": "IA-03C",
      "UX-01A": "UX-01A",
      "UX-01B": "UX-01B",
      "UX-01C": "UX-01C",
      "UX-02A": "UX-02A",
      "UX-02B": "UX-02B",
      "UX-03A": "UX-03A",
      "UX-03B": "UX-03B",
      "ST-01A": "ST-01A",
      "ST-01B": "ST-01B",
      "ST-01C": "ST-01C",
      "ST-02A": "ST-02A",
      "ST-02B": "ST-02B",
      "ST-03A": "ST-03A",
      "ST-03B": "ST-03B",
      "US-01A": "US-01A",
      "US-01B": "US-01B",
      "US-01C": "US-01C",
      "US-01D": "US-01D",
      "US-01E": "US-01E",
      "US-01F": "US-01F",
      "US-01G": "US-01G",
      "US-01H": "US-01H",
      "US-02A": "US-02A",
      "US-02B": "US-02B",
      "US-02C": "US-02C",
      "US-02D": "US-02D",
      "US-02E": "US-02E",
      "US-02F": "US-02F",
      "US-02G": "US-02G",
      "US-02H": "US-02H",
      "US-02I": "US-02I",
      "US-02J": "US-02J",
      "NU-01A": "NU-01A",
      "NU-01B": "NU-01B",
      "NU-01C": "NU-01C",
      "NU-02A": "NU-02A",
      "NU-02B": "NU-02B",
      "NU-02C": "NU-02C",
      "NU-02D": "NU-02D",
      "SU-01A": "SU-01A",
      "SU-01B": "SU-01B",
      "SU-01C": "SU-01C",
      "SU-02A": "SU-02A",
      "SU-02B": "SU-02B",
      "SU-02C": "SU-02C",
      "SU-02D": "SU-02D",
      "SY-02A": "SY-02A",
      "SY-02B": "SY-02B",
      "SY-02C": "SY-02C",
      "SY-03A": "SY-03A",
      "SY-03B": "SY-03B",
      "SY-04A": "SY-04A",
      "SY-04B": "SY-04B",
      "SY-05A": "SY-05A",
      "SY-05B": "SY-05B",
      "SY-05C": "SY-05C",
      "DT-02A": "DT-02A",
      "DT-02B": "DT-02B",
      "DT-02C": "DT-02C",
      "DT-03A": "DT-03A",
      "DT-03B": "DT-03B",
      "DT-03C": "DT-03C",
      "SG-01A": "SG-01A",
      "SG-01B": "SG-01B",
      "SG-01C": "SG-01C",
      "SG-02A": "SG-02A",
      "SG-02B": "SG-02B",
      "QA-01A": "QA-01A",
      "QA-01B": "QA-01B",
      "QA-02A": "QA-02A",
      "QA-02B": "QA-02B",
      "QA-03A": "QA-03A",
      "QA-03B": "QA-03B",
      "QA-03C": "QA-03C",
      "QA-04A": "QA-04A",
      "QA-04B": "QA-04B",
      "QA-04C": "QA-04C",
      "GW-01A": "GW-01A",
      "GW-01B": "GW-01B",
      "GW-01C": "GW-01C",
      "GW-02A": "GW-02A",
      "GW-02B": "GW-02B",
      "GW-02C": "GW-02C",
      "GW-03A": "GW-03A",
      "GW-03B": "GW-03B",
      "GW-04A": "GW-04A",
      "GW-04B": "GW-04B",
      "GW-04C": "GW-04C",
      "CL-02A": "CL-02A",
      "CL-02B": "CL-02B",
      "CL-02C": "CL-02C",
      "CL-03A": "CL-03A",
      "CL-03B": "CL-03B",
      "PR-01A": "PR-01A",
      "PR-01B": "PR-01B",
      "WS-01A": "WS-01A",
      "WS-01B": "WS-01B",
      "WS-02A": "WS-02A",
      "WS-02B": "WS-02B",
      "DA-01A": "DA-01A",
      "DA-01B": "DA-01B",
      "DA-02A": "DA-02A",
      "DA-02B": "DA-02B",
      "DA-03A": "DA-03A",
      "DA-03B": "DA-03B",
      "DA-04A": "DA-04A",
      "DA-04B": "DA-04B",
      "DA-05A": "DA-05A",
      "DA-05B": "DA-05B",
      "DA-06A": "DA-06A",
      "DA-06B": "DA-06B",
      "DA-07A": "DA-07A",
      "DA-07B": "DA-07B",
      "HK-01A": "HK-01A",
      "HK-01B": "HK-01B",
      "HK-02A": "HK-02A",
      "HK-02B": "HK-02B",
      "HK-03A": "HK-03A",
      "HK-03B": "HK-03B",
      "HK-04A": "HK-04A",
      "HK-04B": "HK-04B",
      "HK-05A": "HK-05A",
      "HK-05B": "HK-05B",
      "PC-01A": "PC-01A",
      "PC-01B": "PC-01B",
      "PC-02A": "PC-02A",
      "PC-02B": "PC-02B",
      "PC-03A": "PC-03A",
      "PC-03B": "PC-03B",
      "PC-04A": "PC-04A",
      "PC-04B": "PC-04B",
      "PC-05A": "PC-05A",
      "PC-05B": "PC-05B",
      "PC-06A": "PC-06A",
      "PC-06B": "PC-06B",
      "PC-07A": "PC-07A",
      "PC-07B": "PC-07B",
      "PC-08A": "PC-08A",
      "PC-08B": "PC-08B",
      "PC-09A": "PC-09A",
      "PC-09B": "PC-09B"
    },
    "non_overlap_groups": [
      {
        "id": "revolut-hero-morph",
        "leaves": [
          "RF-01",
          "RM-01"
        ],
        "boundary": "RF-01 owns overview content/routes; RM-01 owns only the continuous hero-morph transition."
      },
      {
        "id": "revolut-ring-reveal",
        "leaves": [
          "RF-06",
          "RM-02"
        ],
        "boundary": "RF-06 owns wealth allocation semantics; RM-02 owns only one-shot ring reveal/resting-halo behavior."
      },
      {
        "id": "revolut-chart-draw",
        "leaves": [
          "RF-07",
          "RM-03"
        ],
        "boundary": "RF-07 owns observed/projection axes and values; RM-03 owns only stroke/gradient draw-on behavior."
      },
      {
        "id": "revolut-chart-scrub",
        "leaves": [
          "RF-16",
          "RM-04"
        ],
        "boundary": "RF-16 owns selected value/date and accessibility semantics; RM-04 owns only continuous nearest-point bubble tracking."
      },
      {
        "id": "revolut-range-selector",
        "leaves": [
          "RF-21",
          "RM-05"
        ],
        "boundary": "RF-21 owns range/asset context retention; RM-05 owns only the moving range-pill transition and Reduce Motion fallback."
      },
      {
        "id": "revolut-numeric-update",
        "leaves": [
          "RF-14",
          "RM-06"
        ],
        "boundary": "RF-14 owns selected amount/category semantics; RM-06 owns only in-place numeric text transition without unrelated layout movement."
      }
    ],
    "workstream_leaf_counts": {
      "Fitness": 62,
      "Finance": 33,
      "Calendar": 13,
      "Widgets": 20,
      "Overview/IA": 5,
      "Nutrition": 8,
      "Sync/Storage": 31,
      "Security/Release": 29,
      "Accessibility": 7,
      "Settings/Connections": 25,
      "Usage": 18,
      "Supplements": 7
    },
    "workstream_map": {
      "BF-0382": "Fitness",
      "BF-0383": "Fitness",
      "BF-0384": "Fitness",
      "BF-0385": "Fitness",
      "BF-0386": "Fitness",
      "BF-0387": "Fitness",
      "BF-0388": "Fitness",
      "BF-0389": "Fitness",
      "BF-0390": "Fitness",
      "BF-0391": "Fitness",
      "BF-0392": "Fitness",
      "BF-0393": "Fitness",
      "BF-0394": "Fitness",
      "BF-0395": "Fitness",
      "BF-0396": "Fitness",
      "BF-0397": "Fitness",
      "BF-0398": "Fitness",
      "BF-0399": "Fitness",
      "BF-0400": "Fitness",
      "BF-0401": "Fitness",
      "BF-0402": "Fitness",
      "BF-0403": "Fitness",
      "BF-0404": "Fitness",
      "BF-0405": "Fitness",
      "BF-0406": "Fitness",
      "BF-0407": "Fitness",
      "BF-0408": "Fitness",
      "BF-0409": "Fitness",
      "BF-0410": "Fitness",
      "BF-0411": "Fitness",
      "BF-0412": "Fitness",
      "BF-0413": "Fitness",
      "BF-0414": "Fitness",
      "BF-0415": "Fitness",
      "BF-0416": "Fitness",
      "BF-0417": "Fitness",
      "BF-0418": "Fitness",
      "BF-0419": "Fitness",
      "BF-0420": "Fitness",
      "BF-0421": "Fitness",
      "BF-0422": "Fitness",
      "BF-0423": "Fitness",
      "BF-0424": "Fitness",
      "BF-0425": "Fitness",
      "BF-0426": "Fitness",
      "BF-0427": "Fitness",
      "BF-0428": "Fitness",
      "BF-0429": "Fitness",
      "BF-0430": "Fitness",
      "BF-0431": "Fitness",
      "BF-0432": "Fitness",
      "BF-0433": "Fitness",
      "RF-01": "Finance",
      "RF-02": "Finance",
      "RF-03": "Finance",
      "RF-04": "Finance",
      "RF-05": "Finance",
      "RF-06": "Finance",
      "RF-07": "Finance",
      "RF-08": "Finance",
      "RF-09": "Finance",
      "RF-10": "Finance",
      "RF-11": "Finance",
      "RF-12": "Finance",
      "RF-13": "Finance",
      "RF-14": "Finance",
      "RF-15": "Finance",
      "RF-16": "Finance",
      "RF-17": "Finance",
      "RF-18": "Finance",
      "RF-19": "Finance",
      "RF-20": "Finance",
      "RF-21": "Finance",
      "RM-01": "Finance",
      "RM-02": "Finance",
      "RM-03": "Finance",
      "RM-04": "Finance",
      "RM-05": "Finance",
      "RM-06": "Finance",
      "CA-01": "Calendar",
      "CA-02": "Calendar",
      "CA-03": "Calendar",
      "CA-04": "Calendar",
      "CA-05": "Calendar",
      "CA-06": "Calendar",
      "CA-07": "Calendar",
      "CA-08": "Calendar",
      "CA-09": "Calendar",
      "CA-10": "Calendar",
      "CA-11": "Calendar",
      "CA-12": "Calendar",
      "CA-13": "Calendar",
      "WG-01": "Widgets",
      "WG-02": "Widgets",
      "WG-03": "Widgets",
      "WG-04": "Widgets",
      "WG-05": "Widgets",
      "WG-06": "Widgets",
      "WG-07": "Widgets",
      "WG-08": "Widgets",
      "WG-09": "Widgets",
      "WG-10": "Widgets",
      "WG-11": "Widgets",
      "WG-12": "Widgets",
      "WG-13": "Widgets",
      "WG-14": "Widgets",
      "WG-15": "Widgets",
      "WG-16": "Widgets",
      "IA-01": "Overview/IA",
      "IA-02": "Overview/IA",
      "NU-03": "Nutrition",
      "SY-01": "Sync/Storage",
      "QA-05": "Security/Release",
      "CL-01": "Finance",
      "IA-03A": "Overview/IA",
      "IA-03B": "Overview/IA",
      "IA-03C": "Overview/IA",
      "UX-01A": "Accessibility",
      "UX-01B": "Accessibility",
      "UX-01C": "Accessibility",
      "UX-02A": "Accessibility",
      "UX-02B": "Accessibility",
      "UX-03A": "Accessibility",
      "UX-03B": "Accessibility",
      "ST-01A": "Settings/Connections",
      "ST-01B": "Settings/Connections",
      "ST-01C": "Settings/Connections",
      "ST-02A": "Settings/Connections",
      "ST-02B": "Settings/Connections",
      "ST-03A": "Settings/Connections",
      "ST-03B": "Settings/Connections",
      "US-01A": "Usage",
      "US-01B": "Usage",
      "US-01C": "Usage",
      "US-01D": "Usage",
      "US-01E": "Usage",
      "US-01F": "Usage",
      "US-01G": "Usage",
      "US-01H": "Usage",
      "US-02A": "Usage",
      "US-02B": "Usage",
      "US-02C": "Usage",
      "US-02D": "Usage",
      "US-02E": "Usage",
      "US-02F": "Usage",
      "US-02G": "Usage",
      "US-02H": "Usage",
      "US-02I": "Usage",
      "US-02J": "Usage",
      "NU-01A": "Nutrition",
      "NU-01B": "Nutrition",
      "NU-01C": "Nutrition",
      "NU-02A": "Nutrition",
      "NU-02B": "Nutrition",
      "NU-02C": "Nutrition",
      "NU-02D": "Nutrition",
      "SU-01A": "Supplements",
      "SU-01B": "Supplements",
      "SU-01C": "Supplements",
      "SU-02A": "Supplements",
      "SU-02B": "Supplements",
      "SU-02C": "Supplements",
      "SU-02D": "Supplements",
      "SY-02A": "Sync/Storage",
      "SY-02B": "Sync/Storage",
      "SY-02C": "Sync/Storage",
      "SY-03A": "Sync/Storage",
      "SY-03B": "Sync/Storage",
      "SY-04A": "Sync/Storage",
      "SY-04B": "Sync/Storage",
      "SY-05A": "Sync/Storage",
      "SY-05B": "Sync/Storage",
      "SY-05C": "Sync/Storage",
      "DT-02A": "Sync/Storage",
      "DT-02B": "Sync/Storage",
      "DT-02C": "Sync/Storage",
      "DT-03A": "Sync/Storage",
      "DT-03B": "Sync/Storage",
      "DT-03C": "Sync/Storage",
      "SG-01A": "Security/Release",
      "SG-01B": "Security/Release",
      "SG-01C": "Security/Release",
      "SG-02A": "Security/Release",
      "SG-02B": "Security/Release",
      "QA-01A": "Security/Release",
      "QA-01B": "Security/Release",
      "QA-02A": "Security/Release",
      "QA-02B": "Security/Release",
      "QA-03A": "Security/Release",
      "QA-03B": "Security/Release",
      "QA-03C": "Security/Release",
      "QA-04A": "Security/Release",
      "QA-04B": "Security/Release",
      "QA-04C": "Security/Release",
      "GW-01A": "Security/Release",
      "GW-01B": "Security/Release",
      "GW-01C": "Security/Release",
      "GW-02A": "Security/Release",
      "GW-02B": "Security/Release",
      "GW-02C": "Security/Release",
      "GW-03A": "Security/Release",
      "GW-03B": "Security/Release",
      "GW-04A": "Security/Release",
      "GW-04B": "Security/Release",
      "GW-04C": "Security/Release",
      "CL-02A": "Finance",
      "CL-02B": "Finance",
      "CL-02C": "Finance",
      "CL-03A": "Finance",
      "CL-03B": "Finance",
      "PR-01A": "Security/Release",
      "PR-01B": "Security/Release",
      "WS-01A": "Widgets",
      "WS-01B": "Widgets",
      "WS-02A": "Widgets",
      "WS-02B": "Widgets",
      "DA-01A": "Sync/Storage",
      "DA-01B": "Sync/Storage",
      "DA-02A": "Sync/Storage",
      "DA-02B": "Sync/Storage",
      "DA-03A": "Sync/Storage",
      "DA-03B": "Sync/Storage",
      "DA-04A": "Sync/Storage",
      "DA-04B": "Sync/Storage",
      "DA-05A": "Sync/Storage",
      "DA-05B": "Sync/Storage",
      "DA-06A": "Sync/Storage",
      "DA-06B": "Sync/Storage",
      "DA-07A": "Sync/Storage",
      "DA-07B": "Sync/Storage",
      "HK-01A": "Fitness",
      "HK-01B": "Fitness",
      "HK-02A": "Fitness",
      "HK-02B": "Fitness",
      "HK-03A": "Fitness",
      "HK-03B": "Fitness",
      "HK-04A": "Fitness",
      "HK-04B": "Fitness",
      "HK-05A": "Fitness",
      "HK-05B": "Fitness",
      "PC-01A": "Settings/Connections",
      "PC-01B": "Settings/Connections",
      "PC-02A": "Settings/Connections",
      "PC-02B": "Settings/Connections",
      "PC-03A": "Settings/Connections",
      "PC-03B": "Settings/Connections",
      "PC-04A": "Settings/Connections",
      "PC-04B": "Settings/Connections",
      "PC-05A": "Settings/Connections",
      "PC-05B": "Settings/Connections",
      "PC-06A": "Settings/Connections",
      "PC-06B": "Settings/Connections",
      "PC-07A": "Settings/Connections",
      "PC-07B": "Settings/Connections",
      "PC-08A": "Settings/Connections",
      "PC-08B": "Settings/Connections",
      "PC-09A": "Settings/Connections",
      "PC-09B": "Settings/Connections"
    }
  },
  "unresolved_scope_decisions": [],
  "resolved_scope_decisions": [
    "Calendar platform split: iOS follows the Figma compact/current interaction layout; macOS keeps the five-view Day/Week/Month/Timeline/Agenda sidebar plus persistent inspector layout.",
    "Runtime, accessibility, storage, image-analysis, barcode, freshness, retry/replay, and responsive thresholds are fixed before freeze; no placeholder counts as a pass.",
    "The tracked clean HEAD blob anchors the registry definition without a self-referential embedded commit; each accepted row independently anchors evidence at its producing SHA."
  ],
  "workstream_leaf_counts": {
    "Accessibility": 7,
    "Calendar": 13,
    "Finance": 33,
    "Fitness": 62,
    "Nutrition": 8,
    "Overview/IA": 5,
    "Security/Release": 29,
    "Settings/Connections": 25,
    "Supplements": 7,
    "Sync/Storage": 31,
    "Usage": 18,
    "Widgets": 20
  },
  "blocker_by_status": {
    "missing": "implementation incomplete",
    "foundation": "acceptance evidence incomplete",
    "blocked-external": "external input or signed-device/operator gate",
    "accepted": "none"
  },
  "claim_kinds": {
    "live": "A provider or retained source fact; fixture/demo evidence is forbidden.",
    "interaction": "A user-visible interaction contract backed by real or unavailable state; fixture/demo evidence is forbidden.",
    "operator": "A signed-device, operator, release, or security procedure claim; fixture/demo evidence is forbidden.",
    "layout-only": "A non-live layout/demo claim; fixture evidence is allowed, but it can never prove provider or live facts."
  },
  "claim_kind_evidence_matrix": {
    "live": {"alternatives": [["integration"], ["device"], ["live-readonly"]], "accepted_forbidden": []},
    "interaction": {"alternatives": [["integration"], ["ui-runtime"], ["device"]], "accepted_forbidden": []},
    "operator": {"alternatives": [["operator"], ["device", "release-signature"], ["device", "security-negative"]], "accepted_forbidden": []},
    "layout-only": {"alternatives": [["milestone-visual"], ["ui-runtime"]], "accepted_forbidden": ["live-readonly"]}
  },
  "evidence_profiles": {
    "interaction-performance": {"claim_kind": "interaction", "required_all": ["performance"]},
    "interaction-layout": {"claim_kind": "interaction", "required_all": ["milestone-visual"]}
  },
  "defaults": {
    "threshold": "All required evidence types pass at the producing commit; no canceled, zero-test, or fixture-only result."
  },
  "prefix_defaults": {
    "BF": {"workstream": "Fitness", "owner": "fitness-worker", "claim_kind": "live"},
    "RF": {"workstream": "Finance", "owner": "finance-worker", "claim_kind": "live"},
    "RM": {"workstream": "Finance", "owner": "finance-worker", "claim_kind": "interaction"},
    "CA": {"workstream": "Calendar", "owner": "calendar-worker", "claim_kind": "interaction"},
    "WG": {"workstream": "Widgets", "owner": "widgets-worker", "claim_kind": "live"},
    "IA": {"workstream": "Overview/IA", "owner": "root", "claim_kind": "interaction"},
    "UX": {"workstream": "Accessibility", "owner": "release-worker", "claim_kind": "interaction"},
    "ST": {"workstream": "Settings/Connections", "owner": "root", "claim_kind": "live"},
    "US": {"workstream": "Usage", "owner": "usage-worker", "claim_kind": "live"},
    "NU": {"workstream": "Nutrition", "owner": "nutrition-worker", "claim_kind": "live"},
    "SU": {"workstream": "Supplements", "owner": "nutrition-worker", "claim_kind": "live"},
    "SY": {"workstream": "Sync/Storage", "owner": "root", "claim_kind": "live"},
    "DT": {"workstream": "Sync/Storage", "owner": "root", "claim_kind": "live"},
    "SG": {"workstream": "Security/Release", "owner": "root", "claim_kind": "operator"},
    "QA": {"workstream": "Security/Release", "owner": "root", "claim_kind": "interaction"},
    "GW": {"workstream": "Security/Release", "owner": "root", "claim_kind": "live"},
    "CL": {"workstream": "Finance", "owner": "finance-worker", "claim_kind": "live"},
    "PR": {"workstream": "Security/Release", "owner": "root", "claim_kind": "live"},
    "WS": {"workstream": "Widgets", "owner": "widgets-worker", "claim_kind": "live"},
    "DA": {"workstream": "Sync/Storage", "owner": "root", "claim_kind": "live"},
    "HK": {"workstream": "Fitness", "owner": "fitness-worker", "claim_kind": "live"},
    "PC": {"workstream": "Settings/Connections", "owner": "root", "claim_kind": "live"}
  },
  "source_templates": {
    "BF": "design://Bevel Reference/IMG_{digits}.jpeg",
    "RF": [
      "design://Revolut Reference/ScreenRecording_08-10-2026 12-21-55_1.mp4",
      "design://Revolut Reference/ScreenRecording_08-10-2026 12-23-28_1.mp4"
    ],
    "RM": [
      "design://Revolut Reference/ScreenRecording_08-10-2026 12-21-55_1.mp4",
      "design://Revolut Reference/ScreenRecording_08-10-2026 12-23-28_1.mp4"
    ],
    "CA": [
      "design://developers/design-coordination/04-calendar-notion.md",
      "design://Figma Reference/InspoNotionCalendar.png",
      "design://Figma Reference/InspoNotionCalendarMonthViewMac.png"
    ],
    "WG": [
      "design://developers/design-coordination/06-widget-system.md"
    ],
    "IA": [
      "design://docs/03-information-architecture.md",
      "repo://docs/LIFEOS_95_EXECUTION_PLAN.md"
    ],
    "UX": [
      "design://developers/design-coordination/00-READ-FIRST.md",
      "design://developers/design-coordination/01-color-system-v2.md"
    ],
    "ST": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://modules/settings/README.md"],
    "US": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://developers/design-coordination/02-charts-rings-widgets.md"],
    "NU": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://modules/fitness/overview.md"],
    "SU": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://modules/fitness/supplements-and-reminders.md"],
    "SY": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://technical/architecture-overview.md"],
    "DT": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://technical/architecture-overview.md"],
    "SG": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "repo://scripts/validate_native_release.py"],
    "QA": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://developers/design-coordination/00-READ-FIRST.md"],
    "GW": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "repo://services/api/README.md"],
    "CL": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "repo://packages/contracts/src/clipper.ts"],
    "PR": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "repo://services/api/src/server.ts"],
    "WS": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://developers/design-coordination/06-widget-system.md"],
    "DA": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://technical/architecture-overview.md"],
    "HK": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://modules/fitness/health-data-and-metrics.md"],
    "PC": ["repo://docs/LIFEOS_95_EXECUTION_PLAN.md", "design://modules/finance/accounts-and-connections.md"]
  },
  "aliases": [
    {"alias": "IMG_0645", "leaf_id": "WG-11", "source": "design://Bevel Reference/IMG_0645.jpeg"},
    {"alias": "IMG_0646", "leaf_id": "WG-12", "source": "design://Bevel Reference/IMG_0646.jpeg"},
    {"alias": "IMG_0647", "leaf_id": "WG-13", "source": "design://Bevel Reference/IMG_0647.jpeg"},
    {"alias": "IMG_0648", "leaf_id": "WG-14", "source": "design://Bevel Reference/IMG_0648.jpeg"},
    {"alias": "IMG_0649", "leaf_id": "WG-09", "source": "design://Bevel Reference/IMG_0649.jpeg"},
    {"alias": "IMG_0650", "leaf_id": "WG-15", "source": "design://Bevel Reference/IMG_0650.jpeg"},
    {"alias": "IMG_0651", "leaf_id": "WG-16", "source": "design://Bevel Reference/IMG_0651.jpeg"}
  ],
  "non_overlap_groups": [
    {"id": "revolut-hero-morph", "leaves": ["RF-01", "RM-01"], "boundary": "RF-01 owns overview content/routes; RM-01 owns only the continuous hero-morph transition."},
    {"id": "revolut-ring-reveal", "leaves": ["RF-06", "RM-02"], "boundary": "RF-06 owns wealth allocation semantics; RM-02 owns only one-shot ring reveal/resting-halo behavior."},
    {"id": "revolut-chart-draw", "leaves": ["RF-07", "RM-03"], "boundary": "RF-07 owns observed/projection axes and values; RM-03 owns only stroke/gradient draw-on behavior."},
    {"id": "revolut-chart-scrub", "leaves": ["RF-16", "RM-04"], "boundary": "RF-16 owns selected value/date and accessibility semantics; RM-04 owns only continuous nearest-point bubble tracking."},
    {"id": "revolut-range-selector", "leaves": ["RF-21", "RM-05"], "boundary": "RF-21 owns range/asset context retention; RM-05 owns only the moving range-pill transition and Reduce Motion fallback."},
    {"id": "revolut-numeric-update", "leaves": ["RF-14", "RM-06"], "boundary": "RF-14 owns selected amount/category semantics; RM-06 owns only in-place numeric text transition without unrelated layout movement."}
  ],
  "row_overrides": {
    "RF-01": {"atomic_key": "finance.revolut.overview-content"},
    "RM-01": {"atomic_key": "finance.revolut.hero-morph-motion"},
    "RF-06": {"atomic_key": "finance.revolut.wealth-allocation"},
    "RM-02": {"atomic_key": "finance.revolut.ring-reveal-motion"},
    "RF-07": {"atomic_key": "finance.revolut.chart-data-semantics"},
    "RM-03": {"atomic_key": "finance.revolut.chart-draw-motion"},
    "RF-16": {"atomic_key": "finance.revolut.scrub-value-semantics"},
    "RM-04": {"atomic_key": "finance.revolut.scrub-motion"},
    "RF-21": {"atomic_key": "finance.revolut.range-context", "claim_kind": "interaction"},
    "RM-05": {"atomic_key": "finance.revolut.range-pill-motion"},
    "RF-14": {"atomic_key": "finance.revolut.selected-amount-semantics"},
    "RM-06": {"atomic_key": "finance.revolut.numeric-update-motion"},
    "RF-12": {"claim_kind": "interaction"},
    "RF-19": {"claim_kind": "interaction"},
    "RF-20": {"claim_kind": "interaction"},
    "SY-01": {"claim_kind": "operator", "threshold": "BitLocker protection status is On and percentage encrypted is 100% (Fully Encrypted) for Windows volumes C: and D: before credentials or deployment."},
    "QA-05": {"claim_kind": "operator"},
    "CL-01": {"claim_kind": "operator"},
    "CA-01": {"platform": "iOS"},
    "CA-02": {"platform": "iOS"},
    "CA-03": {"platform": "iOS"},
    "CA-04": {"platform": "iOS"},
    "CA-05": {"platform": "macOS"},
    "CA-06": {"platform": "iOS + macOS"},
    "CA-07": {"platform": "iOS + macOS"},
    "CA-08": {"platform": "iOS + macOS"},
    "CA-09": {"platform": "iOS + macOS"},
    "CA-10": {"platform": "iOS + macOS"},
    "CA-11": {"platform": "macOS", "source": ["design://modules/calendar/overview.md", "design://developers/design-coordination/00-READ-FIRST.md"]},
    "CA-12": {"platform": "macOS", "source": ["design://modules/calendar/overview.md", "design://developers/design-coordination/00-READ-FIRST.md"]},
    "CA-13": {"platform": "macOS", "source": ["design://modules/calendar/overview.md", "design://developers/design-coordination/00-READ-FIRST.md"]},
    "NU-03": {"source": ["design://modules/fitness/nutrition-and-food.md", "design://developers/design-coordination/05-real-data-connectors.md", "repo://services/api/src/open-food-facts.ts", "repo://services/api/src/barcode-server.test.ts"], "atomic_key": "nutrition.barcode.open-food-facts-gateway", "threshold": "EAN-8, EAN-13, and UPC-A only; request/response <=256 KiB; timeout <=5s; <=15 requests/minute/IP; cache <=1000 entries; bounded retry backoff 5/15/60/300 seconds; miss or invalid response falls back to explicit manual/package-label entry."}
  },
  "split_groups": {
    "IA-03": [
      {"id": "IA-03A", "severity": "P0", "acceptance": "Every release destination has a real workflow or a truthful unavailable state with setup/retry action.", "evidence_types": ["source", "ui-runtime"]},
      {"id": "IA-03B", "severity": "P0", "acceptance": "No duplicate destination or duplicate concept remains in release navigation.", "evidence_types": ["source", "ui-runtime"]},
      {"id": "IA-03C", "severity": "P0", "acceptance": "Normal KPI surfaces never fabricate a value when their source is missing, stale, or unavailable.", "evidence_types": ["source", "ui-runtime"]}
    ],
    "UX-01": [
      {"id": "UX-01A", "severity": "P1", "acceptance": "Release surfaces use black/white-led hierarchy in both themes.", "evidence_types": ["milestone-visual"], "evidence_profile": "interaction-layout"},
      {"id": "UX-01B", "severity": "P1", "acceptance": "Semantic and brand accents are used only where a real distinction exists.", "evidence_types": ["source", "milestone-visual"], "evidence_profile": "interaction-layout"},
      {"id": "UX-01C", "severity": "P1", "acceptance": "Gradients are restrained component treatments and no resting glow, bloom, or halo remains.", "evidence_types": ["source", "milestone-visual"], "evidence_profile": "interaction-layout"}
    ],
    "UX-02": [
      {"id": "UX-02A", "severity": "P1", "acceptance": "Every Mac release area lays out correctly at the frozen narrow, default, and max widths.", "threshold": "Mac widths 900/1200/1512/1800x982 plus physical iPhone 17 portrait", "evidence_types": ["milestone-visual"], "evidence_profile": "interaction-layout"},
      {"id": "UX-02B", "severity": "P1", "acceptance": "Responsive layouts preserve content and interaction at both themes and Reduce Motion.", "evidence_types": ["milestone-visual", "ui-runtime"]}
    ],
    "UX-03": [
      {"id": "UX-03A", "severity": "P1", "acceptance": "Hover and focus feedback communicates only clickability, precision, or disclosure.", "evidence_types": ["ui-runtime", "milestone-visual"]},
      {"id": "UX-03B", "severity": "P1", "acceptance": "Static cards do not acquire decorative hover motion or hue changes.", "evidence_types": ["ui-runtime", "milestone-visual"]}
    ],
    "ST-01": [
      {"id": "ST-01A", "severity": "P0", "acceptance": "Settings initiates and completes gateway-owned OAuth/PKCE without exposing a raw token to the app.", "evidence_types": ["integration", "ui-runtime"]},
      {"id": "ST-01B", "severity": "P0", "acceptance": "Settings renders pending, authorized, expiry, and failure states with truthful status.", "evidence_types": ["integration", "ui-runtime"]},
      {"id": "ST-01C", "severity": "P0", "acceptance": "Settings supports revoke and retry while raw tokens remain outside client storage, logs, and screenshots.", "evidence_types": ["integration", "security-negative"]}
    ],
    "ST-02": [
      {"id": "ST-02A", "severity": "P0", "acceptance": "Settings distinguishes HealthKit/device unavailable, pending, denied, authorized, and revoked states.", "evidence_types": ["device", "ui-runtime"]},
      {"id": "ST-02B", "severity": "P0", "acceptance": "Health source setup and retry actions lead to the relevant permission or device workflow.", "evidence_types": ["device", "ui-runtime"]}
    ],
    "ST-03": [
      {"id": "ST-03A", "severity": "P0", "acceptance": "Settings shows each bank/provider connection status and consent state without receiving credentials or raw tokens.", "evidence_types": ["integration", "ui-runtime"]},
      {"id": "ST-03B", "severity": "P0", "acceptance": "Settings shows expiry, revoke, retry, and diagnostics outcomes for bank/provider connections.", "evidence_types": ["integration", "ui-runtime"]}
    ],
    "US-01": [
      {"id": "US-01A", "severity": "P0", "acceptance": "Usage has one Home-owned route and durable daily history across relaunch.", "evidence_types": ["integration", "ui-runtime"]},
      {"id": "US-01B", "severity": "P0", "acceptance": "Usage distinguishes observed, estimated, projected, stale, and unavailable facts.", "evidence_types": ["integration", "ui-runtime"]},
      {"id": "US-01C", "severity": "P0", "acceptance": "Usage reset, target pace, runway, streak, and credit facts derive only from retained source observations or render Not available.", "evidence_types": ["unit", "integration"]},
      {"id": "US-01D", "severity": "P0", "acceptance": "The Usage hero shell shows remaining percent/unit, Reset, Banked resets, and freshness metadata; missing fields render Not available.", "threshold": "Observed provider data is fresh only when observedAt is <=15 minutes old; older data is stale/refresh_due and missing data remains Not available.", "evidence_types": ["ui-runtime", "integration"]},
      {"id": "US-01E", "severity": "P0", "acceptance": "The Usage honesty banner renders confidence headline, reason, and quality tags only from provenance and never fabricates confidence.", "evidence_types": ["ui-runtime", "integration"]},
      {"id": "US-01F", "severity": "P0", "acceptance": "Graphs, Facts, and Insights tabs are present; Insights uses the truthful requires-more-history or not-connected state when no source exists.", "evidence_types": ["ui-runtime", "integration"]},
      {"id": "US-01G", "severity": "P0", "acceptance": "The graph selector and Account switcher change Usage remaining versus token activity/provider in place and update the whole screen.", "evidence_types": ["ui-runtime", "integration"]},
      {"id": "US-01H", "severity": "P0", "acceptance": "The Usage range control stays visible, enables only ranges backed by real history, and labels deeper unavailable ranges Needs more history.", "evidence_types": ["ui-runtime", "integration"]}
    ],
    "US-02": [
      {"id": "US-02A", "severity": "P0", "acceptance": "Every displayed Usage fact maps to a sourced wire field or an explicit unavailable state.", "evidence_types": ["unit", "integration"]},
      {"id": "US-02B", "severity": "P0", "acceptance": "Provider capability, freshness, and unsupported-state labels remain distinct and source-labelled.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; future clock skew >5 seconds is invalid/unknown; unsupported remains unavailable.", "evidence_types": ["unit", "integration"]},
      {"id": "US-02C", "severity": "P0", "acceptance": "Facts rows for lifetime, peak daily, longest turn, current/longest streak, credits, and banked resets are sourced or Not available with account and timestamp semantics.", "evidence_types": ["ui-runtime", "integration"]},
      {"id": "US-02D", "severity": "P0", "acceptance": "The projection chart maps Target, Actual, Current estimate, and Past estimate to distinct series and styles; Past estimate is omitted when stored history is absent.", "evidence_types": ["ui-runtime", "integration"]},
      {"id": "US-02E", "severity": "P0", "acceptance": "The token-activity bar chart shows honest daily coverage and complete-day summary, with a selectable nearest bar.", "evidence_types": ["ui-runtime", "integration"]},
      {"id": "US-02F", "severity": "P0", "acceptance": "Pointer, touch, and hover nearest-point scrubbing updates the bubble/detail row continuously with selected series, value, and date.", "evidence_types": ["integration", "ui-runtime"]},
      {"id": "US-02G", "severity": "P0", "acceptance": "Keyboard previous/next stepper controls select the same chart points independently of dragging and preserve exact value/date semantics.", "evidence_types": ["ui-runtime", "device"]},
      {"id": "US-02H", "severity": "P0", "acceptance": "Model-mix stacked capsules use the usage.primary to usage.primaryGlow tonal ramp rather than a provider palette.", "evidence_types": ["ui-runtime", "milestone-visual"], "claim_kind": "interaction", "evidence_profile": "interaction-layout"},
      {"id": "US-02I", "severity": "P0", "acceptance": "The Usage heatmap supports tap/hover selection and dimming and uses usage.primary to usage.primaryGlow intensity.", "evidence_types": ["ui-runtime", "milestone-visual"], "claim_kind": "interaction", "evidence_profile": "interaction-layout"},
      {"id": "US-02J", "severity": "P0", "acceptance": "Not-connected, demo, loading, and Reduce Motion states remain honest with no fabricated values and no resting glow.", "evidence_types": ["integration", "ui-runtime", "milestone-visual"]}
    ],
    "NU-01": [
      {"id": "NU-01A", "severity": "P0", "acceptance": "Manual meal proposals stay out of totals, sync, and widgets until explicit confirmation.", "evidence_types": ["unit", "integration"]},
      {"id": "NU-01B", "severity": "P0", "acceptance": "Barcode meal proposals stay out of totals, sync, and widgets until explicit confirmation.", "evidence_types": ["unit", "integration"]},
      {"id": "NU-01C", "severity": "P0", "acceptance": "Photo meal proposals stay out of totals, sync, and widgets until explicit confirmation.", "evidence_types": ["unit", "integration"]}
    ],
    "NU-02": [
      {"id": "NU-02A", "severity": "P0", "acceptance": "A held-out weighed/labeled photo corpus has at least 80% of meals within ±20% calories.", "threshold": ">=140 meals; >=20 meals per food class; calories >=80% within ±20%; MAPE <=25%; median <=15%; p95 <=60%; per-class >=70%; failure <=20%; macros >=70% within ±20%; macro MAPE <=30%; macro MAE protein <=10 g, carbs <=15 g, fat <=10 g; proposal-only until explicit confirmation.", "evidence_types": ["integration", "operator"], "status": "missing"},
      {"id": "NU-02B", "severity": "P0", "acceptance": "Photo corrections preserve explicit correction lineage and source provenance.", "evidence_types": ["integration"], "status": "foundation"},
      {"id": "NU-02C", "severity": "P0", "acceptance": "Photo analysis requires explicit consent and user confirmation before durable commit.", "evidence_types": ["integration", "ui-runtime"], "status": "foundation"},
      {"id": "NU-02D", "severity": "P0", "acceptance": "Photo originals and derived data obey the frozen deletion and retention policy.", "evidence_types": ["integration", "operator"], "status": "missing"}
    ],
    "SU-01": [
      {"id": "SU-01A", "severity": "P0", "acceptance": "Supplement products, plans, schedules, occurrences, and inventory persist across relaunch.", "evidence_types": ["integration", "device"]},
      {"id": "SU-01B", "severity": "P0", "acceptance": "Taken, Snooze, and Skip actions are idempotent across relaunch, DST, offline periods, and permission changes.", "evidence_types": ["integration", "device"]},
      {"id": "SU-01C", "severity": "P0", "acceptance": "Refill and expiry state syncs with revisions and never silently loses user actions.", "evidence_types": ["integration", "device"]}
    ],
    "SU-02": [
      {"id": "SU-02A", "severity": "P0", "acceptance": "The launch-time notification delegate implements foreground delivery and background/terminated action delivery.", "evidence_types": ["device", "integration"], "status": "missing"},
      {"id": "SU-02B", "severity": "P0", "acceptance": "Notification actions validate plan and occurrence identity and reject stale or unknown actions.", "evidence_types": ["device", "integration"], "status": "foundation"},
      {"id": "SU-02C", "severity": "P0", "acceptance": "Notification action state is persisted idempotently before the completion handler runs.", "evidence_types": ["device", "integration"], "status": "missing"},
      {"id": "SU-02D", "severity": "P0", "acceptance": "Foreground/background/terminated, relaunch, DST, denial, and lock-screen states are covered without fabricated adherence.", "evidence_types": ["device", "integration"], "status": "missing"}
    ],
    "SY-02": [
      {"id": "SY-02A", "severity": "P0", "acceptance": "The tracked gateway authenticates the intended Tailscale identity and enforces ACL authorization.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"},
      {"id": "SY-02B", "severity": "P0", "acceptance": "Direct listeners and forged identity headers are rejected fail-closed.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"},
      {"id": "SY-02C", "severity": "P0", "acceptance": "Unauthorized peers cannot reach protected gateway routes or mutate stored state.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"}
    ],
    "SY-03": [
      {"id": "SY-03A", "severity": "P0", "acceptance": "Dual-auth canary accepts the new identity path while retaining the transitional bearer read-only.", "threshold": "At most 3 attempts per request; replaying the same accepted mutation 10 times yields exactly 1 durable record.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"},
      {"id": "SY-03B", "severity": "P0", "acceptance": "Rollback is proven before the transitional bearer can be removed.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"}
    ],
    "SY-04": [
      {"id": "SY-04A", "severity": "P0", "acceptance": "The exact private .ts.net host is injected only by signed local or CI release configuration.", "evidence_types": ["device", "security-negative"]},
      {"id": "SY-04B", "severity": "P0", "acceptance": "The release App Group is signed, non-placeholder, and identical across app and widget targets.", "evidence_types": ["device", "security-negative"]}
    ],
    "SY-05": [
      {"id": "SY-05A", "severity": "P0", "acceptance": "Calendar GET returns an ETag and PUT requires If-Match for the authoritative revision.", "evidence_types": ["integration"]},
      {"id": "SY-05B", "severity": "P0", "acceptance": "A revision conflict returns authoritative truth and never silently overwrites it.", "evidence_types": ["integration"]},
      {"id": "SY-05C", "severity": "P0", "acceptance": "The client performs bounded fetch-merge-retry and has no blind PUT fallback.", "threshold": "At most 3 fetch-merge-retry attempts; replaying one accepted mutation 10 times yields exactly 1 durable record.", "evidence_types": ["integration"]}
    ],
    "DT-02": [
      {"id": "DT-02A", "severity": "P0", "acceptance": "Key custody, encryption at rest, protection class, and locked-device behavior are proven for every persisted payload.", "evidence_types": ["device", "integration"]},
      {"id": "DT-02B", "severity": "P0", "acceptance": "Writes are crash-safe and atomic across database, index, WAL, and temporary files.", "evidence_types": ["integration"]},
      {"id": "DT-02C", "severity": "P0", "acceptance": "Backup exclusion, export, restore, and user deletion propagate across all storage classes.", "evidence_types": ["device", "integration"]}
    ],
    "DT-03": [
      {"id": "DT-03A", "severity": "P0", "acceptance": "Retention enforces at most three images per meal, 90-day originals, 365-day detail, and derivatives no larger than 500 KiB.", "threshold": "3 images/meal; originals <=90d; detail <=365d; derivatives <=500 KiB (binary KiB)", "evidence_types": ["integration", "performance"], "status": "foundation"},
      {"id": "DT-03B", "severity": "P0", "acceptance": "The 8 GiB warning, 9 GiB compaction warning, and 10 GiB ingest gate include database, WAL, cache, logs, backups, and temporary files.", "threshold": "8/9/10 GiB thresholds fire at exact configured binary GiB boundaries; all storage bytes are included", "evidence_types": ["integration", "performance"], "status": "foundation"},
      {"id": "DT-03C", "severity": "P0", "acceptance": "Compaction is transactional, proves export and provenance first, and never silently deletes user truth.", "evidence_types": ["integration", "operator"], "status": "foundation"}
    ],
    "SG-01": [
      {"id": "SG-01A", "severity": "P0", "acceptance": "Release configuration fails on placeholder App Group or host values.", "evidence_types": ["source", "integration", "operator"], "status": "foundation"},
      {"id": "SG-01B", "severity": "P0", "acceptance": "Release configuration fails on unknown provisioning mode or empty release allowlists.", "evidence_types": ["source", "integration", "operator"], "status": "foundation"},
      {"id": "SG-01C", "severity": "P0", "acceptance": "Release configuration fails on unresolved build variables or fixture/demo flags.", "evidence_types": ["source", "integration", "operator"], "status": "foundation"}
    ],
    "SG-02": [
      {"id": "SG-02A", "severity": "P0", "acceptance": "Signed app and extension binaries pass strict signature inspection.", "evidence_types": ["release-signature", "device"]},
      {"id": "SG-02B", "severity": "P0", "acceptance": "Expanded entitlements and App Group membership match the signed release contract.", "evidence_types": ["release-signature", "device"]}
    ],
    "QA-01": [
      {"id": "QA-01A", "severity": "P0", "acceptance": "The seven isolated schemes/test plans are committed and named: LifeOSLogic, LifeOSUI, LifeOSMacLogic, LifeOSMacUI, LifeOSWidgets, LifeOSPrereleaseIOS, and LifeOSPrereleaseMac.", "evidence_types": ["source", "integration"], "status": "foundation"},
      {"id": "QA-01B", "severity": "P0", "acceptance": "Each lane has a runnable command, exact only-testing scope, minimum nonzero expected count, timeout, and retained result path.", "threshold": "Exact only-testing lane counts: LifeOSLogic=386, LifeOSUI=18, LifeOSMacLogic=31, LifeOSMacUI=6, LifeOSWidgets=26, LifeOSPrereleaseIOS=404, LifeOSPrereleaseMac=63; no skip/cancel; exact only-testing scope", "evidence_types": ["integration"], "status": "foundation"}
    ],
    "QA-02": [
      {"id": "QA-02A", "severity": "P0", "acceptance": "Mac UI runner materialization is isolated with inspected host, loader, and app paths before a smoke test.", "evidence_types": ["ui-runtime"]},
      {"id": "QA-02B", "severity": "P0", "acceptance": "Canceled, materialization-failed, and zero-test runs are retained as failures and never accepted.", "evidence_types": ["ui-runtime"]}
    ],
    "QA-03": [
      {"id": "QA-03A", "severity": "P0", "acceptance": "Accessibility audit covers labels, actions, focus order, and contrast on every release area.", "threshold": "WCAG labels/role/value/action; contrast >=4.5:1 normal text and >=3:1 large text/UI components; charts convey distinctions without color alone", "evidence_types": ["device", "ui-runtime"]},
      {"id": "QA-03B", "severity": "P0", "acceptance": "Dynamic Type and VoiceOver/custom-action alternatives preserve the critical workflows.", "threshold": "Maximum Dynamic Type and largest Mac text size across all P0 flows; no clipping, overlap, or lost action", "evidence_types": ["device", "ui-runtime"]},
      {"id": "QA-03C", "severity": "P0", "acceptance": "Reduce Motion removes decorative animation while preserving information and interaction.", "threshold": "All P0 flows with Reduce Motion; no decorative animation/resting glow; transitions instant or <=100ms crossfade", "evidence_types": ["device", "ui-runtime"]}
    ],
    "QA-04": [
      {"id": "QA-04A", "severity": "P1", "acceptance": "Launch and first-render latency meet the frozen release threshold.", "threshold": "Signed Release on physical iPhone 17 and Mac; 30 fresh launches each; p95 shell <=1.5s; meaningful cached route <=2.5s; none >5s or failure; offline shell required; simulator diagnostic only", "evidence_types": ["performance"], "evidence_profile": "interaction-performance"},
      {"id": "QA-04B", "severity": "P1", "acceptance": "Scroll and interaction latency meet the frozen release threshold at narrow/default/max sizes.", "threshold": "Widths 900/1200/1800x982 plus physical iPhone 17 portrait; both themes and Reduce Motion; 3x30s per surface for scroll/calendar drag/chart scrub/tab; p95 frame <=16.7ms; none >50ms; input-visible p95 <=100ms; zero lost input", "evidence_types": ["performance"], "evidence_profile": "interaction-performance"},
      {"id": "QA-04C", "severity": "P1", "acceptance": "Storage accounting, compaction, and restore meet the frozen performance threshold.", "threshold": "Versioned 12-month benchmark including all storage bytes with manifest SHA; authoritative Windows accounting <=5s p95, compaction <=120s, encrypted restore <=180s; signed physical iPhone 17 client-cache accounting <=2s p95 and encrypted cache rebuild from the same manifest-backed server snapshot <=60s; crash at each transaction boundary; zero loss, duplication, provenance/correction/tombstone/pinned-media mismatch; 100% manifest equality", "evidence_types": ["performance"], "evidence_profile": "interaction-performance"}
    ],
    "GW-01": [
      {"id": "GW-01A", "severity": "P0", "acceptance": "The approved gateway authenticates and bounds every Calendar, Usage, Finance, Clipper, Nutrition, Fitness, and Supplement route.", "evidence_types": ["integration", "security-negative"]},
      {"id": "GW-01B", "severity": "P0", "acceptance": "Direct listeners, forged headers, and unauthorized route access fail closed.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"},
      {"id": "GW-01C", "severity": "P0", "acceptance": "Oversized bodies/responses and timeouts are rejected within the frozen limits.", "threshold": "Usage/Finance/Clipper/Calendar/Supplement/Fitness control or telemetry request/response <=256 KiB and <=8s; Claude/Codex ingest <=16 KiB and <=8s; nutrition barcode <=256 KiB and <=5s; nutrition photo <=3 images and <=20 MiB aggregate sanitized input, schema response <=256 KiB, provider timeout <=30s; exact content type required; overflow, redirect, and timeout fail closed.", "evidence_types": ["integration", "security-negative"]}
    ],
    "GW-02": [
      {"id": "GW-02A", "severity": "P0", "acceptance": "Provider secrets are encrypted at rest and scoped to the service identity.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"},
      {"id": "GW-02B", "severity": "P0", "acceptance": "Service-SID ACLs prevent unauthorized read or write of provider secrets.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"},
      {"id": "GW-02C", "severity": "P0", "acceptance": "Rotation, revocation, and fail-closed startup behavior are tested.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"}
    ],
    "GW-03": [
      {"id": "GW-03A", "severity": "P0", "acceptance": "Codex collector reaches the authenticated gateway and Node route without collecting prompts or file contents.", "evidence_types": ["integration", "security-negative"]},
      {"id": "GW-03B", "severity": "P0", "acceptance": "Codex collector retry and restart behavior is idempotent and bounded.", "threshold": "At most 3 attempts per delivery; replaying one accepted observation 10 times yields exactly 1 durable record.", "evidence_types": ["integration", "security-negative"]}
    ],
    "GW-04": [
      {"id": "GW-04A", "severity": "P0", "acceptance": "Claude collector uses the exact external-to-loopback route and authenticated forwarder.", "evidence_types": ["integration", "security-negative"]},
      {"id": "GW-04B", "severity": "P0", "acceptance": "Claude retry and replay handling is idempotent and dual-auth compatible.", "threshold": "At most 3 attempts per delivery; replaying one accepted observation 10 times yields exactly 1 durable record.", "evidence_types": ["integration", "security-negative"]},
      {"id": "GW-04C", "severity": "P0", "acceptance": "Unauthorized Claude requests and forged identity are rejected.", "evidence_types": ["security-negative", "operator"], "claim_kind": "operator"}
    ],
    "CL-02": [
      {"id": "CL-02A", "severity": "P0", "acceptance": "Clipper ingestion preserves integer EUR cents, typed fields, and source provenance through gateway and client.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "CL-02B", "severity": "P0", "acceptance": "Partial, stale, and unavailable Clipper states remain distinct from zero.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; future clock skew >5 seconds is invalid; partial quality never becomes observed and unavailable never becomes zero.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "CL-02C", "severity": "P0", "acceptance": "Clipper-only retry preserves typed error details and cannot duplicate an accepted record.", "threshold": "At most 3 attempts; replaying one accepted snapshot 10 times yields exactly 1 durable record.", "evidence_types": ["integration"]}
    ],
    "CL-03": [
      {"id": "CL-03A", "severity": "P0", "acceptance": "Clipper Overview and detail surfaces expose only confirmed or honest unavailable data.", "evidence_types": ["ui-runtime", "live-readonly"]},
      {"id": "CL-03B", "severity": "P0", "acceptance": "Clipper connection, revoke, and error states provide truthful setup/retry actions.", "evidence_types": ["ui-runtime", "live-readonly"]}
    ],
    "PR-01": [
      {"id": "PR-01A", "severity": "P0", "acceptance": "Fixture and demo routes are unreachable through production app and gateway configuration.", "evidence_types": ["integration", "security-negative"]},
      {"id": "PR-01B", "severity": "P0", "acceptance": "The production health endpoint cannot be mistaken for live product data.", "evidence_types": ["integration", "security-negative"]}
    ],
    "WS-01": [
      {"id": "WS-01A", "severity": "P0", "acceptance": "Confirmed app state publishes versioned, privacy-filtered, protected per-module widget snapshots atomically.", "evidence_types": ["integration", "device"], "status": "foundation"},
      {"id": "WS-01B", "severity": "P0", "acceptance": "Widget timeline reload requests are coalesced and budget-aware.", "evidence_types": ["integration", "device"]}
    ],
    "WS-02": [
      {"id": "WS-02A", "severity": "P0", "acceptance": "Widget providers render fresh, expired, locked, redacted, unavailable, and stale snapshots truthfully after reload.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; expired at the snapshot schema's explicit expiresAt; locked/redacted never expose private values.", "evidence_types": ["integration", "device"], "status": "foundation"},
      {"id": "WS-02B", "severity": "P0", "acceptance": "A reload request is not treated as an immediate-display guarantee.", "evidence_types": ["integration", "device"], "status": "foundation"}
    ],
    "DA-01": [
      {"id": "DA-01A", "severity": "P0", "acceptance": "Calendar authority and schema version are explicit at the client/server boundary.", "evidence_types": ["source", "integration"]},
      {"id": "DA-01B", "severity": "P0", "acceptance": "Calendar revisions, idempotency, offline queue, tombstones, deletion propagation, and retention have positive and negative integration evidence.", "evidence_types": ["integration"]}
    ],
    "DA-02": [
      {"id": "DA-02A", "severity": "P0", "acceptance": "HealthKit/Fitness authority and the device-local or authenticated-upload exception are explicitly recorded.", "evidence_types": ["source", "device"]},
      {"id": "DA-02B", "severity": "P0", "acceptance": "Fitness revisions, idempotency, offline behavior, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.", "evidence_types": ["integration", "device"]}
    ],
    "DA-03": [
      {"id": "DA-03A", "severity": "P0", "acceptance": "Confirmed nutrition records are authoritative and draft proposals are excluded from durable totals.", "evidence_types": ["source", "integration"]},
      {"id": "DA-03B", "severity": "P0", "acceptance": "Nutrition revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.", "evidence_types": ["integration"]}
    ],
    "DA-04": [
      {"id": "DA-04A", "severity": "P0", "acceptance": "Supplement schedule, occurrence, action, and inventory authority is explicit with a versioned schema.", "evidence_types": ["source", "integration"]},
      {"id": "DA-04B", "severity": "P0", "acceptance": "Supplement revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.", "evidence_types": ["integration"]}
    ],
    "DA-05": [
      {"id": "DA-05A", "severity": "P0", "acceptance": "Usage sample, aggregation, and provider authority is explicit with a versioned schema.", "evidence_types": ["source", "integration"]},
      {"id": "DA-05B", "severity": "P0", "acceptance": "Usage revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.", "evidence_types": ["integration"]}
    ],
    "DA-06": [
      {"id": "DA-06A", "severity": "P0", "acceptance": "Finance account, transaction, budget, and holding authority is explicit with reconciliation IDs and a versioned schema.", "evidence_types": ["source", "integration", "live-readonly"]},
      {"id": "DA-06B", "severity": "P0", "acceptance": "Finance revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "DA-07": [
      {"id": "DA-07A", "severity": "P0", "acceptance": "Clipper snapshot authority, schema, and correction/revocation behavior are explicit.", "evidence_types": ["source", "integration", "live-readonly"]},
      {"id": "DA-07B", "severity": "P0", "acceptance": "Clipper revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "HK-01": [
      {"id": "HK-01A", "severity": "P0", "acceptance": "HealthKit capability and iOS-only entitlement are present with no macOS or fixture claim.", "evidence_types": ["release-signature", "device"]},
      {"id": "HK-01B", "severity": "P0", "acceptance": "NSHealthShareUsageDescription and NSHealthUpdateUsageDescription are present and truthful.", "evidence_types": ["release-signature", "device"]}
    ],
    "HK-02": [
      {"id": "HK-02A", "severity": "P0", "acceptance": "HealthKit availability is checked with HKHealthStore.isHealthDataAvailable().", "evidence_types": ["device", "ui-runtime"]},
      {"id": "HK-02B", "severity": "P0", "acceptance": "Restricted, unavailable, denied, pending, and revoked health-source states remain distinct.", "evidence_types": ["device", "ui-runtime"]}
    ],
    "HK-03": [
      {"id": "HK-03A", "severity": "P0", "acceptance": "Read and write authorization are separate and write status uses authorizationStatus(for:).", "evidence_types": ["device", "ui-runtime"]},
      {"id": "HK-03B", "severity": "P0", "acceptance": "Read denial is treated as indistinguishable from no readable samples and never becomes zero.", "evidence_types": ["device", "ui-runtime"]}
    ],
    "HK-04": [
      {"id": "HK-04A", "severity": "P0", "acceptance": "Anchored queries reconcile source/device, units, duplicates, revisions, and deletions.", "evidence_types": ["unit", "device", "integration"]},
      {"id": "HK-04B", "severity": "P0", "acceptance": "HealthKit reconciliation preserves partial/stale provenance and never fabricates zero values.", "evidence_types": ["unit", "device", "integration"]}
    ],
    "HK-05": [
      {"id": "HK-05A", "severity": "P0", "acceptance": "A signed physical-device Helio/Zepp to HealthKit path proves source provenance.", "evidence_types": ["device", "live-readonly"]},
      {"id": "HK-05B", "severity": "P0", "acceptance": "Physical-device evidence covers partial, stale, and conflict states without fixture substitution.", "evidence_types": ["device", "live-readonly"]}
    ],
    "PC-01": [
      {"id": "PC-01A", "severity": "P0", "acceptance": "Sparkasse/Enable Banking consent and session lifecycle is gateway-owned and read-only.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "PC-01B", "severity": "P0", "acceptance": "Sparkasse/Enable Banking expiry, revoke, freshness, and retry states are source-labelled.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; at most 3 attempts; replaying one observation 10 times yields exactly 1 durable history record.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "PC-02": [
      {"id": "PC-02A", "severity": "P0", "acceptance": "Revolut Personal support or unavailable capability is explicit and consent is gateway-owned.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "PC-02B", "severity": "P0", "acceptance": "Revolut Personal expiry, revoke, freshness, retry, and no-secret-client behavior are proven.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; at most 3 attempts; replaying one observation 10 times yields exactly 1 durable history record.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "PC-03": [
      {"id": "PC-03A", "severity": "P0", "acceptance": "Revolut Business eligibility and consent/token lifecycle are explicit and gateway-owned.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "PC-03B", "severity": "P0", "acceptance": "Revolut Business expiry, revoke, freshness, retry, and no-secret-client behavior are proven.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; at most 3 attempts; replaying one observation 10 times yields exactly 1 durable history record.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "PC-04": [
      {"id": "PC-04A", "severity": "P0", "acceptance": "Trade Republic manual import parses supported records with provenance and duplicate detection.", "evidence_types": ["integration"]},
      {"id": "PC-04B", "severity": "P0", "acceptance": "Trade Republic reimport and reconciliation preserve corrections without duplicate balances.", "evidence_types": ["integration"]}
    ],
    "PC-05": [
      {"id": "PC-05A", "severity": "P0", "acceptance": "Codex capability, wire fields, freshness, and rate-limit semantics are explicit.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; future clock skew >5 seconds is invalid/unknown.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "PC-05B", "severity": "P0", "acceptance": "Codex history, scheduler, restart, retry, and unavailable behavior are proven.", "threshold": "At most 3 attempts; replaying one accepted observation 10 times yields exactly 1 durable history record.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "PC-06": [
      {"id": "PC-06A", "severity": "P0", "acceptance": "Claude statusline capability, freshness, history, and forwarder install contract are explicit.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; future clock skew >5 seconds is invalid/unknown.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "PC-06B", "severity": "P0", "acceptance": "Claude restart, retry, and unavailable behavior are proven without prompt/file-content collection.", "threshold": "At most 3 attempts; replaying one accepted observation 10 times yields exactly 1 durable history record.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "PC-07": [
      {"id": "PC-07A", "severity": "P0", "acceptance": "GLM credential scope and wire capability are explicit or the provider is visibly unavailable.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "PC-07B", "severity": "P0", "acceptance": "GLM freshness, retry, rate-limit, history, and restart behavior are proven or unavailable.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; at most 3 attempts; replaying one observation 10 times yields exactly 1 durable record; unsupported stays unavailable.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "PC-08": [
      {"id": "PC-08A", "severity": "P0", "acceptance": "DeepSeek credential scope and wire capability are explicit or the provider is visibly unavailable.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "PC-08B", "severity": "P0", "acceptance": "DeepSeek freshness, retry, rate-limit, history, and restart behavior are proven or unavailable.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; at most 3 attempts; replaying one observation 10 times yields exactly 1 durable record; unsupported stays unavailable.", "evidence_types": ["integration", "live-readonly"]}
    ],
    "PC-09": [
      {"id": "PC-09A", "severity": "P0", "acceptance": "Google AI Studio credential scope and wire capability are explicit or the provider is visibly unavailable.", "evidence_types": ["integration", "live-readonly"]},
      {"id": "PC-09B", "severity": "P0", "acceptance": "Google AI Studio freshness, retry, rate-limit, history, and restart behavior are proven or unavailable.", "threshold": "Fresh <=15 minutes from observedAt; stale >15 minutes; at most 3 attempts; replaying one observation 10 times yields exactly 1 durable record; unsupported stays unavailable.", "evidence_types": ["integration", "live-readonly"]}
    ]
  }
}
```
<!-- acceptance-registry:data:end -->
