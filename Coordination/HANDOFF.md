# HANDOFF — LifeOS native app

Updated 2026-09-11 Europe/Berlin.

## Current verdict

The source security checkpoint is **GREEN** after the final Astra Medium
review. The shared visual foundation is **GREEN** at `6751bb5` after Astra
re-reviewed the macOS sheet repair, public responsive builder composition,
hosted-view coverage, and interaction layering. Release remains pending
operational, provider, device, and visual acceptance. Do not infer
runtime/device acceptance from source checks.

The ChartKit/Usage source tranche is also **GREEN** at `6713de1` after three
Astra review cycles. It preserves real cadence gaps, bounded rendering,
cached selection, duplicate-source authority, and singleton observations.

Do not claim a production release, remote backend availability, or device
acceptance from the local source results. No generic conversational
assistant/advisor/AI product exists. Calorie-photo tracking is the only
permitted in-app AI flow. No Claude scheduling or usage watcher is part of the
product.

## Git and review state

- Branch: `lifeos-foundation-checkpoint-20260812`.
- Source checkpoint: `6713de1` (`Harden Usage chart rendering and selection`).
- Shared-foundation checkpoint: `6751bb5` (`Prove responsive builder content is preserved`).
- The local branch is synchronized with its origin-tracking ref. The latest
  security checkpoints are `b82f23b` (fail closed on versioned tax evidence),
  `2fb2b9b` (native privacy test typing), and `eb9ca62` (bounded native tax
  lookahead). Keep these small, attributable commits when synchronizing.
- Recent source checkpoints include `ceddd2b` (design validator contract),
  `c814299` (widget typography compile fix), `544633b` (finance detail return),
  `ebbfff2` (gateway/native calendar-limit alignment), `f425b2a` (bounded
  usage idempotency replay journal), and `1d79a13` (calendar image and tax
  document boundary hardening). Preserve small, attributable commits when
  synchronization is later authorized.

## Implemented source slices

- Compact SF Pro/system typography, semantic SF Symbols, separated accents,
  responsive surfaces, widget contrast, and restrained route/microinteraction
  behavior.
- Calendar scrolling, minute-precise restoration, paging/editing, Mac
  trackpad magnification, explicit pairing, authenticated payloads, bounded
  decoding, timestamp validation, and fail-closed oversized-state handling.
- Finance live-source contracts, manual Trade Republic import, durable
  reconciliation, and truthful unavailable/provenance states.
- Fitness recovery/biology/nutrition plus local workout templates, exercises,
  sessions, sets, history, PRs, reports, and bounded HealthKit evidence.
- Usage charts normalize once per revision, split real telemetry gaps before
  the render cap, keep derived guides continuous, cache binary-search
  selection, coalesce duplicates last-source-wins, and retain singleton data.
- Tax redaction before persistence/evidence, page exclusion from sync,
  formula-safe CSV export, atomic replacement, and legacy migration.
- Bounded API/gateway reads, localhost/JSON headers, constant-time secret
  comparison, explicit Codex executable paths, Windows manifest/ACL/recovery
  checks, and bounded protected-storage admission.
- Gateway calendar images now undergo bounded PNG/JPEG structure and CRC
  validation before publication. Tax metadata follows the native-shaped
  `TaxDocument` contract, rejects raw page payloads, validates the index, and
  exposes privacy-safe list responses. Usage idempotency retains a bounded
  replay window by retiring the oldest keys instead of stopping permanently.

## Security status

Known Claude/Astra source findings have local mitigations and regression
coverage, but the independent release gate is still pending. The gateway
calendar maximum is exactly 1,024, matching the native limit. Overflow
requests are rejected before persistence, and an already oversized persisted
snapshot fails closed without truncating or modifying the raw state. Calendar
image structure/CRC checks and native-shaped TaxDocument/index checks now
protect the other affected publication paths. Usage replay remains bounded;
retired keys may be accepted as new requests while retained keys preserve
replay and fingerprint-reuse behavior.

The current native sync boundary uses Tailscale connection identity plus an
edge capability. The native app does not persist that bearer token; do not
describe the current transport as a Keychain-stored sync token. Legacy
credential cleanup and the physical transport still require verification.

Final Astra Medium source verdict: **GREEN** at `eb9ca620…`. It independently
ran the gateway/API suites, reproduced current and legacy raw-evidence cases,
confirmed authenticated reads fail closed without mutating bytes, and reviewed
the native, calendar, API, WebSocket, replay, process, and deployment bounds.
The green verdict does not prove effective Windows ACLs, remote restart
recovery, live penetration results, or physical-device behavior.

## Verification evidence

- Full repository source validator: **163 passed**, **47 subtests passed**.
- Gateway: **549 passed**, with two dependency warnings.
- API: **141 tests passed** and TypeScript typecheck passed.
- Contracts: **198 tests passed** and build passed.
- The final security pass did not rerun `npm audit`; advisory status was not
  refreshed in this checkpoint.
- Unsigned `LifeOSMacLogic` build, unsigned `LifeOSLogic` build, direct
  `LifeOSWidget` iOS target, `LifeOSPrereleaseIOS`, and macOS logic XCTest
  passed; the macOS XCTest result contains **54 passed tests**.
- Foundation repair evidence: unsigned `LifeOSMac` build passed, and the
  focused iPhone 17 `LifeOSDesignSystemTests` suite passed **39 tests with
  0 failures**, including mounted sibling/`ForEach` layout probes.
- Chart tranche evidence: focused iPhone 17 chart/design suites passed **56
  tests with 0 failures** (17 chart, 39 design), and unsigned `LifeOSMac`
  build passed after `6713de1`.
- The named `LifeOSWidgets` scheme exposes only macOS destinations; that is
  scheme metadata, not a source failure.
- The shared-foundation repair through `6751bb5` compiled for unsigned iOS
  logic and macOS and passed the focused hosted-view suite. Full native XCTest
  and runtime visual acceptance remain unverified; Mac sheet presentation and
  resize behavior remain explicit runtime checks.

## External acceptance gates

- Complete bounded Windows recovery, candidate installation, standalone
  runtime, ACL/readback, Tailscale Serve, restart recovery, and health checks
  on `domke@tailscaleip`. Current evidence is: `LifeOSAPI` stopped, no
  listener on expected ports, deployment marker active, recovery phase
  `artifacts`, 31,226 recovery units.
- Synchronize the candidate and refresh PR state before using the Windows
  release builder.
- Complete real Enable Banking consent/readback and one real Trade Republic
  import; keep missing-provider states truthful.
- Exercise HealthKit, Zepp sync, morning refresh/USB Shortcuts, and seven-day
  Personal Team signing renewal on the iPhone 17 and Mac.
- Inspect the Mac UI and iPhone behavior for compact hierarchy, transparent
  grey-wallpaper widgets, calendar scroll/pinch, sheets, hover, route
  reversal, and animation quality. CoreSimulator/device evidence is not yet
  recorded.
- Obsidian graph/mind-map feasibility remains tracked in GitHub issue #2 and
  is not silently represented as complete.

## Next serialized queue

1. Complete the icon/component, shell/truth-gate, and screen visual
   tranches with an Astra review after each bounded batch.
2. Complete bounded Windows recovery,
   installation, and remote runtime verification.
3. Complete provider, physical-device, signing, visual, widget, and
   CoreSimulator acceptance gates.
4. Resolve the issue #2 Obsidian/Zepp decisions with evidence before calling
   the app complete.

Keep this file and the other coordination files below 200 lines. Record new
external evidence here before marking a gate complete.
