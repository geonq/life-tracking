# HANDOFF — LifeOS native app

Updated 2026-09-11 Europe/Berlin.

## Current verdict

Local source checks are current and passing, but the release is **pending a
new final Astra Medium security review** plus external acceptance gates. The
previous final Astra review was **RED** because Windows recovery was
unfinished and because the gateway accepted more calendar items than native
clients. The local source patches now cover that calendar boundary, bounded
PNG/JPEG validation, native-shaped TaxDocument publication, privacy-safe
document responses, and bounded usage idempotency replay. The Windows runtime
is still not green.

Do not claim a production release, remote backend availability, or device
acceptance from the local source results. No generic conversational
assistant/advisor/AI product exists. Calorie-photo tracking is the only
permitted in-app AI flow. No Claude scheduling or usage watcher is part of the
product.

## Git and review state

- Branch: `lifeos-foundation-checkpoint-20260812`.
- Source checkpoint: `1d79a1306717a03eae2bcf48daf847bb40e9e4ba`.
- After this coordination commit, the local branch is 24 commits ahead of its
  origin-tracking ref and has not been pushed. The coordination snapshot is
  committed in the local history.
  Source/security commits `f425b2a` and `1d79a13` are committed locally but
  remain unsynchronized with origin, so remote or PR state is unverified.
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

The source/security status remains **pending fresh Astra review**. The prior
review also left raw WebSocket probing unverified because the local environment
lacked the `websockets` package, although ASGI WebSocket tests passed. The
fresh review must repeat adversarial HTTP/WS, authentication, bounds, replay,
deployment, and dependency checks and issue the release gate.

## Verification evidence

- Full repository source validator: **163 passed**, **47 subtests passed**.
- Gateway: **490 passed**, with two dependency warnings.
- API: **141 tests passed** and TypeScript typecheck passed.
- Contracts: **198 tests passed** and build passed.
- Full and production-only `npm audit`: **zero vulnerabilities**.
- Unsigned `LifeOSMacLogic` build, unsigned `LifeOSLogic` build, direct
  `LifeOSWidget` iOS target, `LifeOSPrereleaseIOS`, and macOS logic XCTest
  passed; the macOS XCTest result contains **54 passed tests**.
- The named `LifeOSWidgets` scheme exposes only macOS destinations; that is
  scheme metadata, not a source failure.

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

1. Run the new final Astra Medium security review after this documentation refresh.
2. Synchronize the candidate and PR, then complete bounded Windows recovery,
   installation, and remote runtime verification.
3. Complete provider, physical-device, signing, visual, widget, and
   CoreSimulator acceptance gates.
4. Resolve the issue #2 Obsidian/Zepp decisions with evidence before calling
   the app complete.

Keep this file and the other coordination files below 200 lines. Record new
external evidence here before marking a gate complete.
