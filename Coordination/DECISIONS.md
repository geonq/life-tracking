# DECISIONS — LifeOS native app

Updated 2026-09-12 Europe/Berlin.

## Product and design

- Use the native SF Pro/system facade, compact hierarchy, 4/8/12/16/24/32/48
  spacing, 12pt Home/Usage cards, semantic SF Symbols, and distinct palette
  values from `colors.md`. Estimates are green; calories are orange.
- Home shows one compact Usage lead surface and avoids duplicate provider
  rings. Usage is an operational monitoring surface with truthful live or
  explicit fixture provenance.
- Calendar owns iPhone vertical scrolling and Mac trackpad magnification.
  Paging, editing, and zoom must not compete for the same gesture. Its
  density contract is 40 pt minimum, 64 pt default, and 120 pt maximum; Mac
  pinch is primary and the secondary preset menu has no slider or dotted
  track.
- Use direct user motion and restrained transitions. Rapid route reversal must
  start from the currently visible state.
- Generic conversational assistant/advisor/AI is removed from every product
  layer. Calorie-photo tracking is the only permitted in-app AI behavior.
- The shared foundation is reviewed GREEN at `6751bb5`. Both responsive
  containers route unrestricted builders through one owning VStack, and the
  iPhone suite measures sibling and ForEach rows in a mounted window. Screen
  work proceeds in bounded tranches; actual Mac sheet resizing remains a
  runtime acceptance item.
- The Usage chart tranche is reviewed GREEN at `6713de1`. Normalize and
  coalesce source dates once per revision with last-source authority; split
  observed cadence gaps before the 240-point render budget; keep estimate and
  target guides continuous; use cached binary-search selection; retain whole
  segment endpoints and visible singleton observations.
- The compact empty-state/icon/tax tranche is reviewed GREEN at `82b4eb1`.
  Amount values and evidence preserve only validated monetary intersections;
  known identifiers in labels and non-monetary fragments are masked. Fitness
  uses the ECG waveform symbol, with platform-specific boxes and glyphs
  asserted in the design contract.

## State and data boundaries

- Scene-owned state retains Calendar position, Finance chart/detail choices,
  Fitness section, and Usage provider/graph/range across route replacement.
- Python remains Calendar authority. Local edits persist an outbox receipt
  before sync; missing records never imply deletion.
- Enable Banking is the live bank path; Trade Republic remains a manual
  import. Production paths must use real data and truthful unavailable states.
- LifeOS owns workout templates, exercises, sessions, sets, history, PRs, and
  reports. Zepp is a read-only sync source; unsupported fields remain
  unavailable until evidence supports them.
- Obsidian integration remains a feasibility item in issue #2. Markdown/YAML
  links are semantic source; Canvas coordinates are presentation metadata.

## Security and runtime

- Windows gateway access remains fail-closed with scoped credentials,
  protected snapshots, atomic recovery, identity-bound bounded reads, ACL
  checks, and journal-bound Node staging.
- Gateway and native calendar limits are both 1,024. Oversized incoming or
  persisted state fails closed without destructive truncation.
- Calendar icon publication must perform bounded PNG/JPEG structure and CRC
  validation before persistence, so a signature-only or corrupted image
  cannot pass the gateway while failing native decoding.
- Tax document publication follows the native-shaped `TaxDocument` schema,
  rejects raw page payloads, validates stored index entries, and returns only
  privacy-safe metadata. The gateway must not become a raw-page sync path.
- Usage idempotency is a bounded replay journal: retained keys preserve
  replay and fingerprint-reuse behavior, while the oldest keys are retired so
  ingestion does not permanently stop at the capacity limit. Presentation
  authority is per provider/window; a valid complete connector payload marks
  every omitted supported scope authoritative-empty, cached history cannot
  resurrect it, and failed archive writes remain pending for retry.
- The current native sync boundary is Tailscale connection identity plus an
  edge capability. The app does not persist that bearer token; do not document
  it as a Keychain-stored sync token. Legacy credential cleanup and physical
  transport remain verification items.
- Keep secrets out of source, prompts, logs, and archives. Do not claim
  provider, Windows-native, physical-device, or visual evidence from source
  checks alone. Final Astra Medium source review is GREEN at `eb9ca620…`;
  operational and device gates remain open.
- Native Shortcuts may open Zepp and report LifeOS refresh/status; a public
  Zepp API is not assumed. Personal Team signing and seven-day renewal remain
  platform-managed steps.

## Workflow

- Use Luna Max for bounded implementation and Astra Medium for batched review.
  Keep write scopes disjoint, native builds serialized with `-jobs 1`, and
  close completed workers and processes immediately.
- Keep coordination files below 200 lines. Use live production reads and keep
  visual fixtures isolated from production paths.
- Do not add a Claude usage-limit watcher, overnight supervisor, demo fallback,
  generic assistant, or unrelated conversational AI.
- Do not merge PR #1 while Windows, provider, physical-device, and visual
  gates remain unresolved, even when local automated suites pass.
