# CHANGELOG — life-tracking (LifeOS native app)

## 2026-09-12 — Usage hierarchy tranche

- `8c2c097` applies the agreed compact Usage geometry: 112pt summary band,
  96pt/8pt ring with a 72pt narrow fallback, accessibility-safe omission,
  metadata-sized chart controls, flat supplementary sections, and removal of
  unsourced Suggested pace/Runway rows.
- Astra Medium re-review is GREEN after one RED repair cycle. Serialized
  unsigned universal `LifeOSMac` build passed; CoreSimulator remains unavailable.
- Source/runtime/provider/device gates remain separate and open; no release
  percentage is reported until the acceptance ledger has valid evidence.

## 2026-08-28 — reviewed tranche committed and pushed

- `f1241d9` native (Home Usage tap fix, chart selection, Finance/Nutrition
  domain), `89d1952` registry hash reconciliation, `5df0085` gateway relink
  BLOCKER fix, `babcd3c` API Gemini temperature restore + fail-closed history,
  `333f85f` forwarder installer hardening, `f379853` XcodeGen signing.
- Verified clean-tree: gateway 163, scripts+installer 99, API 88/88,
  contracts 85/85, dashboard 2/2, tsc clean, unsigned macOS/iOS builds pass.
- Coordination rotated under the 100-line cap; history preserved in archive/.

Coordination history is intentionally rotated into the current zero-context
checkpoint. Do not infer acceptance from older session notes.
Older entries (2026-08-12) are archived at [`archive/CHANGELOG-2026-08-28.md`](archive/CHANGELOG-2026-08-28.md).

## 2026-08-26 — background request coalescing

- Repeated launch/active/background scheduling now cancels the prior pending
  `BGAppRefreshTaskRequest` for the LifeOS identifier before submitting the
  next request.
- Sequential unsigned iOS/macOS builds, Info.plist lint, and diff hygiene
  passed. iOS cadence, signed widget readback, and App Group runtime behavior
  remain OS/device gates.

## 2026-08-26 — runtime freshness and Usage consistency

- Usage widget kinds now reload explicitly after a successful shared snapshot
  write, so fresh app data is not left waiting for a later timeline request.
- Added a system-managed iOS `BGAppRefreshTask` request with permitted task
  identifier, Background Fetch mode, concurrent real-data refresh, snapshot
  publish, and resubmission. Cadence remains controlled by iOS and requires
  signed/device verification.
- Home Usage now uses the paired Clipper-style zoom navigation, shared chart
  reveal, numeric transition, and stable-date interactive compact sparkline.
- Verification after this tranche: cached macOS build succeeded; cached iOS
  test build succeeded; CoreSimulator remained unavailable.

### 16:25 final seal

Contracts 84/84, API 77/77, direct no-write TypeScript, plist lint, and diff
hygiene pass. Cached macOS/iOS native builds pass. CoreSimulator and all live,
signed-device, background, and independent-agent gates remain open.

## 2026-08-26 — afternoon completion tranche

- Added snapshot-keyed Calendar recurrence materialization so one-day paging
  does not re-expand the full recurrence horizon for every swipe/recenter.
- Added a disabled PayPal Personal official-API eligibility descriptor and
  restricted the native consent button to Enable Banking connectors.
- Added an in-subtree chart reveal wrapper and migrated Usage Projection plus
  Fitness activity, biology, and strength rendering/selection to dataset-aware
  reveals and stable date identities. Strength now supports touch, pointer, and
  accessibility adjustment.
- Verification: contracts 84/84, Node API 77/77, unsigned macOS build, and
  generic unsigned iOS test build passed. CoreSimulator runtime was unavailable
  afterward; no device acceptance was inferred.
- Final local check at 15:50: the loopback API suite passed 77/77 and direct
  no-write TypeScript checks passed for contracts, API, and dashboard. The root
  build wrapper remains unable to rewrite protected generated files on this
  host; no source diagnostic was reported.
- Recorded the next nutrition lane: Windows-only Google AI Studio secret,
  proposal-only food-photo inference, deterministic grams-eaten barcode
  scaling, and searchable exact supplement/nutrient facts with a manual no-AI
  path.
- Sealed the 16:06 handoff after making Home compact sparklines interactive
  with stable date selection and documenting the supplied supplement-label
  basis/count examples.

## 2026-08-13 — audited 95% execution-plan checkpoint

- T0 implementation checkpoint: machine registry materializes 258 atomic leaves
  plus seven aliases with stable sources, bounded claim kinds, commit/evidence
  gates, and explicit Usage/Open Food Facts coverage. It remains UNFROZEN.
- Added seven platform-valid Xcode schemes/test plans, centralized lane manifest,
  pinned/digest-verified XcodeGen, deterministic project/test-plan validation,
  strict xcresult minimums, and fail-closed release validation.
- Full isolated iOS logic run passed 386/386 after the baseline caught and fixed
  the missing 678th curated emoji. Runtime cleanup left no simulator/app running.

- Three independent Luna/max read-only audits reconciled Claude's status scan
  against product scope, server/data paths, and Xcode/runtime evidence. They
  reject “backlog essentially cleared”: the app is a substantial foundation,
  not a nearly complete live product.
- Tracked plan `docs/LIFEOS_95_EXECUTION_PLAN.md` defines security-first,
  dependency-ordered parallel execution and four visual-review milestones.
- Tracked registry `docs/LIFEOS_ACCEPTANCE_REGISTRY.md` is intentionally
  `UNFROZEN — SCORING PROHIBITED`; T0 must atomize/populate/validate/hash it
  before any percentage is reported. Three final reviews accept the drafts with
  no remaining P0/P1 in product, architecture/data, or Xcode scopes.
- GitHub input/permission notifications use draft PR #1 comments beginning
  `@geonq ACTION REQUIRED`; routine progress does not generate notification spam.
