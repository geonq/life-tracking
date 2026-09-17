# LifeOS product and design specification

Updated 2026-09-17 Europe/Berlin. This is the product-level inventory for the
personal LifeOS installation. It records requested behavior, design decisions,
security boundaries, and the evidence still required. Implementation details
and acceptance receipts remain in `tasks/`, `Coordination/`, and
`docs/LIFEOS_ACCEPTANCE_REGISTRY.md`.

## Release truth

- Release is **NO-GO**. The last pushed checkpoint is `c871339`; the finance
  institution detector/importer slice is now pushed after focused tests,
  serialized native verification, and Astra Medium **MERGE** review.
- Source, tested, visual, interaction, live-data, and physical-device evidence
  are separate claims. A source implementation is not a product sign-off.
- The personal product is a native SwiftUI/WidgetKit app for this Mac and
  iPhone. The Windows PC is a private Tailscale backend and storage boundary.
- No generic advisor, conversational assistant, usage watcher, or in-app AI is
  allowed. Calorie photo tracking is the only in-app AI feature.

## Product surface and features

### Shell and Home

- Native navigation sections: Home, Calendar, Finance, Fitness, and Tax.
- Home is a compact “what matters now” dashboard with cards linking to module
  detail. It may surface Usage, Clipper Analytics, Health, and current signals.
- Route state has one native navigation authority, native back behavior,
  deep links, command/search entry where already implemented, and no AppKit
  raster route host.
- Cards report unavailable, stale, locked, demo-preview, and live states
  explicitly. Personal production screens never silently replace missing data
  with fixtures.

### Calendar, tasks, and planning

- Calendar owns events, recurrence, exceptions, edit/resize, deletion,
  conflict handling, undo, and day/week/month timeline presentation.
- Mac timeline interaction uses trackpad pinch in/out for density. The gesture
  keeps its focal time, is continuous, cancellable, and does not use a visible
  zoom slider or double-mutate state.
- iPhone owns vertical 00:00–24:00 scrolling, paging, drag/edit arbitration,
  auto-scroll, blank-space scrolling, recurrence, DST, and touch feedback.
- Calendar has a single today marker, stable time gutter, bounded recurrence
  expansion, accessible event labels, and deterministic overlap layout.
- Reminders is the task authority. Grocery and Shopping are distinct lists
  whose ownership and clearing rules must not create a second task store.
- Calendar may project task counts or generic summaries only within the
  privacy boundary; permission to show counts never exposes task titles.
- Obsidian Canvas planning is available from the planning/calendar area. The
  vault is the semantic authority for notes and links; Canvas coordinates and
  visual styles are presentation metadata. Nodes support text, color, shapes,
  arrows, drag, canvas pan/zoom, focused detail, and opening the linked note.
  Mac, iPhone, Obsidian, and CLI access must round-trip without destructive
  overwrites or a competing mutable database.
- The intended private vault location is the existing non-Uni iCloud vault,
  with a dedicated LifeOS folder after the actual path is confirmed.

### Finance

- Enable Banking is the live connected-account path for the two existing bank
  accounts. Historical proof exists; deployment/readback recertification is a
  remaining acceptance gate.
- Trade Republic is a manual CSV import. The parser previews rows, keeps
  stable IDs, deduplicates/reconciles reimports, preserves investment-order
  metadata, and never calls imported orders current holdings.
- CSV imports detect institution layouts from versioned fingerprints. A bare
  date-plus-amount file stays unknown; ambiguous or unsupported formats require
  an explicit mapping path and never become a guessed provider.
- Recurring-payment detection is deterministic and explainable. Candidates
  expose cadence, amount/date evidence, confidence, and an auditable Manage
  Payment action for weekly, monthly, or yearly user confirmation.
- CSV import reports the detected institution, source layout, currency,
  skipped-row diagnostics, and provenance without persisting raw filenames,
  account identifiers, or statement text in detection metadata.
- Robinhood exports are a separate investment activity/holding ledger. They
  contribute to net worth only after a verified schema and valuation path; they
  must not be treated as EUR bank transactions. `thenextsemis.vercel.app` is an
  optional final net-worth source after the direct import path is stable.
- PayPal is removed from the product scope.
- All financial arithmetic uses explicit currency and integer cents/decimal
  rules. Live and imported data retain source, freshness, reconciliation, and
  unavailable state.

### Fitness, health, workouts, and nutrition

- HealthKit/Zepp data supplies recovery, sleep, load, stress, energy reserve,
  resting heart rate, steps, active energy, body signals, and other supported
  metrics with source metadata and truthful unavailable states.
- Zepp is a read-only sync source. LifeOS owns the workout templates, exercise
  configuration, training sessions, sets/reps/weight/rest, completion state,
  personal records, history, and native reports.
- Workout setup should cover common exercises such as curls and bench press,
  support editing offline, finish exactly once, derive durable timers from
  timestamps, and reconcile a completed session with Zepp after the user marks
  it done. Unsupported Zepp fields remain unavailable rather than fabricated.
- Nutrition includes meals, macro/calorie goals, barcode/manual entry where
  already supported, supplements/history, and calorie photo preparation plus
  AI estimation. Photo results are local previews until explicitly saved and
  are clearly non-clinical estimates.
- Biological age remains experimental and non-clinical, requiring a reviewed
  model with explicit source metadata.

### Tax and documents

- Tax documents are imported, reviewed, matched, stored locally, and exported
  as structured CSV with privacy-safe metadata and bounded archive handling.
- Raw page text is sensitive, protected, and excluded from unnecessary sync.
  Export cells are safe against spreadsheet formula injection. Writes are
  atomic and a failure must retain the prior store.

### Usage and Clipper

- Usage can display provider limits, reset time, banked resets, freshness, and
  activity for connected providers such as Codex and Claude when real data is
  available. Demo fixtures are preview-only and must be visibly labeled.
- Clipper Analytics can show views, subscribers, revenue, and trends only from
  a connected source; absent history remains unavailable.

### Widgets and device flows

- Preserve existing widget identifiers and supported families, including the
  current Calendar, Next Event, Usage, Tasks, Finance, Net Worth, Cash Flow,
  Health, Fitness, Nutrition, Recovery, Stress, and Energy Reserve widgets.
- The requested Notion Calendar-style Lock Screen experience refines the
  existing `LifeOSNextEventWidget` accessory family: title first, compact
  time range second, no decorative card, and a restrained semantic bar.
- Widgets have distinct empty, unavailable, locked/redacted, stale, preview,
  and live states. They never use personal data for gallery placeholders.
- Home Screen transparency, dark mode, tinted/vibrant modes, and the grey
  wallpaper are tested independently. WidgetKit controls final background
  removal and tint; the app does not fake transparency with a custom toggle.
- The Mac and iPhone use the App Group snapshot boundary with versioned,
  privacy-filtered, bounded, atomic snapshots. Reload requests are best-effort
  and do not mean immediate display.
- An Apple Shortcut must support a morning Zepp sync with one click. A second
  personal Shortcut should support connecting the iPhone by USB to the Mac and
  renewing the local authentication/signing flow on the actual cadence, while
  preserving app data. Its exact capabilities and device receipts remain a
  gate; no App Store purchase or $100 developer license is assumed.

## Design system

- Typography is native SF Pro/system typography. Use Dynamic Type-compatible
  native styles, restrained weights, and compact hierarchy; large display text
  is reserved for page titles and hero values, never ordinary labels or every
  card metric.
- Spacing uses a consistent 4/8/12/16/24/32/48 token rhythm. Cards have clear
  alignment, useful density, quiet borders, and intentional empty space.
- Read the private brand palette file as the palette source. Accent/detail
  colors must not collapse into the same blue and saturation band. Estimates
  are green; calories are orange; state colors remain semantic and consistent.
- The default personal presentation is dark, minimal, modern, and readable on
  transparent Home Screen widgets over a grey wallpaper. Validate grey levels
  and varied luminance instead of assuming a flat background.
- Icons use a coherent SF Symbols/native symbol language with deliberate
  weight, optical size, and semantic purpose. Avoid arbitrary cheap-looking
  glyph mixes, decorative icons, emoji, and inconsistent stroke families.
- Mac interactions include hover/focus feedback, keyboard affordances, and
  smooth route transitions. iPhone interactions use native glide, drag, sheet,
  spring, and swipe behavior. Every animation has a clear state transition,
  no jump-cut, no stale callback, no lost input, and no excessive delay.
- Motion is polished but quiet: use matched geometry/opacity/scale only where
  it explains continuity, fill dead space with subtle motion only when it
  serves orientation, and keep loading/empty/error transitions intentional.
- Calendar pinch, scrolling, paging, editing, and navigation have separate
  gesture ownership. Canceled interactions restore the prior state.
- Layouts must remain compact and unclipped across Mac widths, iPhone sizes,
  dark/transparent/tinted modes, German/English text, long titles, and normal
  system text scaling. The user’s visual acceptance is required for final
  “high-end” sign-off.

## Data ownership and backend

- An always-on private Windows backend/storage host is reached through
  Tailscale. Its connection identity and address stay in local operator
  instructions; disk encryption is enabled.
- Windows owns structured snapshots, service publication, recovery artifacts,
  and permitted connector boundaries. Apple clients own presentation and
  local authority for calendar, reminders, HealthKit, workouts, and manual
  finance edits according to their contracts.
- Publication uses protected ACLs, identity-bound native handles, bounded
  process I/O, job-tree cleanup, monotonic deadlines, atomic replacement, and
  rollback retention. Canonical install/health/restart/restore evidence is
  still required.
- Live data is preferred for bug testing. Synthetic fixtures are isolated,
  labeled, and cannot silently write personal stores or prove live behavior.

## Security requirements

- Calendar peer sync requires explicit pairing/pinned identity and authenticated
  invitations; advertising is opt-in. Transport encryption without peer
  authentication is insufficient.
- Remote timestamps, decoded calendar items, snapshot counts, response sizes,
  content types, and recurrence expansion are bounded and validated. Logical
  clocks/skew rules prevent remote timestamps from wiping local data.
- Sync tokens live in Keychain with device-only protection. Local API requests
  validate Host and content type, expose only the required surface, and set
  defensive response headers.
- Tax text/pages, identifiers, exports, and storage permissions are treated as
  sensitive. Atomic replacement, formula-injection defense, per-line history
  recovery, lock-protected usage writes, no-follow temporary files, and secure
  directory modes are required.
- Windows process launch resolves trusted absolute binaries, restricts handle
  inheritance, validates service identity/ACLs, kills descendants on failure,
  and preserves the original publication error through recovery.
- Secrets require strong minimum length and standard constant-time comparison.
  Dependency advisories, CSP, CI action pinning, regex fuzzing, duplicate-ID
  traps, and icon validation order remain part of the final security batch.

## Storage and process policy

- `scripts/maintain_macos_storage.sh` is the required Apple-build preflight.
  It reports by default; deletion requires explicit `--apply`.
- Cleanup is limited to generated DerivedData, device-support caches,
  validation artifacts, and shutdown/unavailable simulators. Source, personal
  data, final evidence, and the kept iPhone 17 simulator are outside scope.
- The guard refuses active or uncheckable `xcodebuild`, skips booted
  simulators, preserves the current device support configuration, and fails
  below a 15 GiB free-space floor. Apple lanes call it before every lane and
  run `xcodebuild -jobs 1` with owned DerivedData.
- No background cleanup scheduler or usage-limit watcher exists. Stop only
  task-owned idle apps/processes; do not kill unrelated Mac work.
- The latest verified cleanup removed global DerivedData and stale simulator
  support, left the volume above the configured floor, and is covered by the
  pushed storage regression tests.

## Engineering and evidence gates

- Prefer O(n) maps/aggregation, indexed lookups, bounded reads, and one rebuild
  per revision. Use O(n log n) only for required ordering/layout; never put
  storage I/O or full-history scans in a pointer/gesture frame.
- Every tranche has exact file ownership, one behavior change, focused tests,
  a diff review, and a clean pushed checkpoint. Luna Max implements bounded
  packets; Astra Medium plans and reviews batches.
- Required evidence categories are source, build, runtime, visual,
  interaction, live, system/device, and operator. Each receipt records SHA,
  command/exit/count, device/OS/viewport/theme/mode, expected/observed result,
  and an artifact digest where applicable.
- Final completion requires: secure canonical Windows deployment and restore;
  live Enable Banking and Trade Republic/finance reconciliation; recurring
  payments and verified Robinhood/net worth path; Zepp/workout sync; Obsidian
  Canvas round trip; all widget/privacy/Shortcuts/signing gates; physical
  iPhone receipts; whole-app visual and interaction acceptance; and a final
  Astra Medium security review with no unresolved release blocker.

## Current open work

1. Add explicit user mapping, recurring payment management, and verified
   Robinhood/net-worth flows on top of the pushed institution-aware importer.
2. Re-certify canonical Windows install, listener/health/restart/restore, and
   live Enable Banking readback on GEONQSERVER.
3. Implement and verify Zepp workout reconciliation, Apple Shortcuts, personal
   signing renewal, widget accessory/privacy refinement, and full Mac/iPhone
   runtime evidence.
4. Implement the Obsidian Canvas/iCloud mapping after the actual vault path and
   three-way conflict contract are confirmed.
5. Run batched Astra Medium design/security/product reviews, close every
   acceptance row, and only then change the release verdict.
