# HANDOFF — LifeOS native app

Updated 2026-09-09 20:42 Europe/Berlin.

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
- Latest source commit: `1129a92` (`Finalize shared visual system foundation`).
- Preceding pushed commits are `5087c04` (Windows release bounds/recovery) and
  `7fc3cc3` (visual implementation contract).
- Local `HEAD` matches `origin/lifeos-foundation-checkpoint-20260812`; no dirty
  tracked files, lost commits, reset, force-push, or branch replacement found.
- PR #1 remains open, draft, and mergeable against `main`; it is intentionally
  not merged until the external gates and the existing UI acceptance lane are
  complete.
- Keep future changes as small attributable commits.

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
- The clean release builder produced source SHA `1129a92`; its 81-entry
  candidate manifest verifies, including the 86,989,128-byte standalone Node
  runtime and 100,383,246-byte service host under their exact 256 MiB paths.

## Security review status

The twelve Claude findings are addressed in source and regression tests:
nearby calendar pairing/authentication, remote timestamp/deletion validation,
Calendar Codable invariants/count/title limits, the no-bearer-token sync design,
bounded JSON reads, tax redaction and page handling, CSV formula neutralization,
atomic tax writes, symlink-safe usage writes, localhost Host checks, explicit
Codex path resolution, and constant-time ingest-secret comparison.

Astra source reviews found no P0/P1 and the final foundation/release gate was
GO. Their follow-up findings were fixed: tax redaction field boundaries,
macOS Fitness refresh coalescing and generation ownership, timezone conversion
overflow handling, subsecond Calendar edit/delete ordering, Calendar PUT MIME
checks, icon schema/hash checks before ImageIO decoding, the SF Pro foundation
layout contracts, selector measurement/disabled states, and measured Mac sheet
sizing. No regression against the twelve Claude findings was identified.

## Verification evidence

- API: **131 Vitest tests passed**; TypeScript typecheck passed.
- Gateway: **447 pytest tests passed**; two dependency deprecation warnings.
- Windows builder/deployment source suite: **68 tests passed** with the
  packaged loopback smoke permission.
- Design source suite: **11 tests passed**; Swift parse and `git diff --check`
  passed.
- iOS current source: generic `build-for-testing` succeeded; no simulator
  runtime is installed, so the prior 1,526-test simulator result is baseline
  evidence rather than a current execution claim.
- macOS logic/snapshots: **49 tests passed, 0 failures** on the current source.
- Repository validators: **157 tests passed and 47 subtests passed** on the
  preceding unchanged validator baseline.
- The available Apple destination LifeOS build succeeded with unsigned
  development settings; native release, calendar topology, XcodeGen, and the
  removed-product source scan passed.

## External acceptance gates

- Windows services were not installed/listening in the latest read-only audit.
  The current candidate is built and checksum-verified locally, but it still
  needs Windows PowerShell 5.1 verification, installation, Tailscale Serve,
  and restart/recovery/readback checks. Preserve the dirty remote API checkout.
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
