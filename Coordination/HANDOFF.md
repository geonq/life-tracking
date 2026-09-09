# HANDOFF — LifeOS native app

Updated 2026-09-09 18:34 Europe/Berlin.

## Current verdict

**NO-GO for completion until the external acceptance gates are exercised.**
The local source, security repairs, backend contracts, and available native
logic/snapshot suites are green. The app has not been certified against the
always-on Windows runtime, provider consent, real HealthKit/Zepp data, the
physical iPhone, or Personal Team installation.

Advisor and generic conversational AI are absent from the product path. Calorie
photo tracking is the only permitted in-app AI flow. No usage watcher or
overnight scheduler is part of the product.

## Git and review state

- Branch: `lifeos-foundation-checkpoint-20260812`.
- Latest source commit before this documentation refresh: `656e3f1`.
- The branch contains the native commit `9a46ac5` and backend/Windows commit
  `656e3f1` after the previous handoff `f813a70`.
- PR #1 remains open, draft, and mergeable against `main`; it is intentionally
  not merged until the external gates and the existing UI acceptance lane are
  complete.
- No reset, force-push, lost commit, or branch replacement was found. Keep
  future changes as small attributable commits.

## Implemented source slices

- SF Pro/system typography, shared dark design tokens, responsive cards and
  states, motion ownership, transparent grey-wallpaper widget readability.
- Calendar mobile scrolling, late-day reachability, paging, editing, Mac
  trackpad magnification, explicit pairing, authenticated payloads, bounded
  decoding, timestamp validation, and precise timestamp transport.
- Finance live Enable Banking state, manual Trade Republic import, durable
  imported-finance reconciliation, and truthful unavailable states.
- Fitness recovery, biology, nutrition, local workout templates/exercises/
  sessions/sets/history/PRs/reports, and bounded read-only HealthKit evidence.
- HealthKit refresh/status App Intents for native Shortcut composition.
- Tax redaction before persistence/evidence, page exclusion from sync,
  formula-safe CSV export, atomic replacement, and legacy migration.
- Bounded API/gateway reads, localhost/JSON headers, constant-time secret
  comparison, explicit Codex executable paths, Windows manifest/ACL/recovery
  checks, safe staging, and serialized durable fitness publication.

## Security review status

The twelve Claude findings are addressed in source and regression tests:
nearby calendar pairing/authentication, remote timestamp/deletion validation,
Calendar Codable invariants/count/title limits, the no-bearer-token sync design,
bounded JSON reads, tax redaction and page handling, CSV formula neutralization,
atomic tax writes, symlink-safe usage writes, localhost Host checks, explicit
Codex path resolution, and constant-time ingest-secret comparison.

Astra’s final review found no P0/P1. Its P2/P3 follow-up findings were then
fixed: tax redaction field boundaries, macOS Fitness refresh coalescing and
generation ownership, timezone conversion overflow handling, subsecond
Calendar edit/delete ordering, Calendar PUT MIME checks, and icon schema/hash
checks before ImageIO decoding.

## Verification evidence

- API: **131 Vitest tests passed**; TypeScript typecheck passed.
- Gateway: **447 pytest tests passed**; two dependency deprecation warnings.
- Repository validators: **157 tests passed and 47 subtests passed**.
- iOS logic: **1,526 tests passed, 0 failures**, iPhone 17 simulator.
- macOS logic/snapshots: **49 tests passed, 0 failures**.
- The available Apple destination LifeOS build succeeded with unsigned
  development settings.
- Native release, calendar topology, XcodeGen, changed-file Swift parsing,
  Advisor source scan, and `git diff --check` passed.

## External acceptance gates

- Windows services are not installed in the current read-only inspection;
  gateway/sync/API ports were not listening and only a development Node
  runtime was present. Provision the standalone approved runtime, install the
  service host, configure Tailscale Serve, and run recovery/readback checks.
- Enable Banking consent/readback and real account observations are unverified.
- Physical iPhone HealthKit permissions/data, Zepp sync, Shortcut execution,
  USB refresh, and seven-day Personal Team renewal are unverified.
- Run iOS UI, macOS UI, and widget acceptance for scrolling, keyboard/sheet
  dismissal, real pinch/hover feel, clear/tinted/transparent rendering, and
  the grey wallpaper. The earlier macOS UI lane exposed calendar/settings
  interaction failures and must be rerun after repair.
- Obsidian graph/mind-map integration remains a separately scoped feasibility
  item tracked in GitHub issue #2; it is not silently represented as complete.

## Operating rule

Do not claim full completion from source or simulator evidence alone. Keep
coordination files below 200 lines, use live data in production paths, isolate
visual fixtures, and update this handoff after every coherent pushed group.
