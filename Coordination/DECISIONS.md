# LifeOS decisions

Updated 2026-09-22 Europe/Berlin.

## Product authority

- Native SwiftUI/WidgetKit on Mac and iPhone is the product.
- Windows over Tailscale is the private structured-data/document boundary.
- Calendar, finance, HealthKit/Zepp, Obsidian, tax, usage, and widgets retain
  their own authority; do not add a competing universal store.
- Missing live data stays unavailable. No demo data in production.
- No generic advisor or conversational AI. Calorie-photo estimation is the
  only permitted in-app AI flow.
- SF Pro/system typography, semantic SF Symbols, compact hierarchy, distinct
  palette, green estimates, orange calories, direct manipulation, and
  interruptible Reduce Motion-aware animation remain product authority.

## Execution authority

- One Luna implementation worker at a time; Astra reviews actual diffs and
  evidence in batches. Workers never guess a missing shared signature.
- Current source bytes outrank stale coordination prose; receipt evidence is
  accepted only for its declared source SHA and scope.
- Source existence never equals runtime acceptance. Unavailable, unsupported,
  unknown, failed, and pending remain separate.
- Every accepted tranche records exact files, hashes, evidence, complexity,
  cleanup, commit, push, and local/origin parity. The current code checkpoint
  is P06-A native Canvas `4ff27e3` after native persistence `80579bc` and
  Xcode-27 compatibility `0451afb`.
- Apple lanes are serialized, use owned result paths, and are not claimed from
  an interrupted or silent command.

## P00 decisions

- The baseline is the observed HEAD and local origin ref: 328b18e...
- The frozen denominator is 258 leaves plus 7 aliases; no completion percentage
  is calculated.
- P00 retains every old registry/reference locator as pending source evidence.
  It rejects duplicate IDs, duplicate aliases, alias collisions, and
  nonexistent claimed receipt paths.
- P05 D1 is accepted at `ca2caf1`; Canvas edits are invalid for Markdown-backed
  sessions, while Markdown source replacement remains the supported edit.
- Xcode 27.0, the iOS 27 runtime, and the iPhone 17 simulator are available;
  the license is accepted. Signing/profile and physical-device evidence remain
  unknown because no valid identity/profile was observed.
- Windows remains unknown/unavailable by task constraint; P00 did not connect.
- Proprietary Zepp readiness/load/PAI/Training Effect parity remains unsupported
  without a legitimate source. Physical HealthKit/Zepp provenance is pending.

## P01/P02 execution decisions

- P01 wire counters for R20 administrative blobs and observation epochs are
  canonical decimal strings on both Swift and TypeScript; admin store IDs are
  restricted to usageLocal and clipperLocal.
- The P02 SQLite core is a durable, serialized, already-verified input
  boundary. It does not invent cryptography or unauthenticated blob download.
- The Mac relay binds to loopback by default, denies Windows administration,
  bounds framing/concurrency, and returns 503 until an authenticated handler is
  injected. Its install script only renders a reviewed recipe.
- Astra review found and the controller fixed chunk retry/progress,
  transaction rollback, SQLite integer, HTTP framing, response media-type,
  IPv6 binding, and Python-runtime issues before the 1f65326 push.
- The 83365b1 verifier rejects malformed/unknown fields, non-canonical integer
  tokens, invalid routes, body-hash mismatches, and unauthenticated frames
  before route composition; durable sender authorization remains a gateway
  integration obligation.

## P02 authenticated exchange checkpoint

- Checkpoint 038cd37 is pushed on main and origin/main. It adds authenticated
  exchange, nested signature verification against the pinned roster, contiguous
  device frontiers, and a separate gateway acknowledgement cursor.
- Dependency paging is FIFO/de-duplicated, byte-bounded, restart-safe, and
  never advertises an unresolved or noncontiguous device sequence as delivered.
- A durable stream-head table and sequence index bound frontier reads. The
  composite index is created only after legacy-column migration; an original
  schema regression covers this ordering.
- Focused Python evidence is 21 passing tests with one cryptography-dependent
  skip on this Mac.

## P03 calendar checkpoint

- `e76be67` is the pushed source checkpoint. The app targets include Sync;
  widget targets remain isolated from it.
- Calendar wire data uses strict version-1 `calendarSeries`, lowercase UUID
  IDs, deterministic ordering, bounded canonical JSON, NFC wire normalization,
  and icon hash-before-image verification.
- Durable calendar replication must use the current `SyncDomainAdapter` and
  embedded `SyncAdapterEnvelope`; no sidecar ledger or later R7 API is allowed.
- `9d222ac` is the durable calendar checkpoint. It separates local outbound
  ACKs from authenticated evidence, retains replay anchors atomically, rejects
  forged ACKs, retains stale conflicts, and omits unsupported zero frontiers.
- API evidence is typecheck plus 160 passing tests; gateway replication is 23
  passing tests with one crypto-dependent skip. Astra static review passed.

## P04 fitness payload checkpoint

- `b0e52e1` adds strict training serialization, bounded canonical JSON, NFC wire normalization, finite/fractional numeric handling, and parser/domain regressions; it is serialization only and CP-B still blocks durable store adapters.
- Astra static review passed. The Xcode 27 Mac lane passes 379/379 native
  tests and the iOS 27 simulator logic lane passes 1,837/1,837; signed UI and
  physical-device evidence remain open.

## 2026-09-22 P06-A native Canvas checkpoint

- `4ff27e3` is pushed on main and origin/main after Astra PASS. It adds the
  native viewport, AppKit/UIKit input bridge, owner tokens and touch quarantine,
  shared node/edge geometry, cached presentation queries, retry recovery, and
  focused platform regressions. Main macOS evidence is 405/405 full and 19/19
  focused; final worker iOS evidence is 18/18 focused plus generic build.
- This is a bounded Canvas tranche. Vault routing, inspector/document flows,
  Calendar integration, CP-B adapters, signed UI, physical-device input, and
  external provider evidence remain open.

## 2026-09-22 Apple lane resource hygiene

- Apple validation runs through `scripts/validate_apple_on_mac.sh` or
  `scripts/run_prerelease_lanes.sh`, never through multiple ad-hoc xcodebuild
  lanes. Keep `-jobs 1`, disable parallel test destinations, use one simulator,
  and preserve separate log/result/DerivedData paths.
- Both lane scripts own a simulator cleanup trap. If a command is interrupted,
  inspect the exact xcodebuild/xctest process tree, stop only the owned stalled
  process, then run `simctl shutdown` and verify no LifeOS test process or booted
  simulator remains before starting another lane.
- A long silent interval during first-use simulator runtime preparation is not
  evidence of a dead test. Read the owned log and process state first; do not
  start a second lane or kill Apple CoreSimulator daemons while preparation is
  progressing.

## 2026-09-22 P06-B planning workspace transaction checkpoint

- `86baaa8` is the validated P06-B source checkpoint. It adds the read-only
  Calendar-to-Obsidian `.canvas` workspace, transactional vault selection,
  journal/resource handoff, and mirrored iOS/macOS regressions.
- Selection persistence uses a bounded composite record plus durable pending
  and explicit decision records. Recovery rolls back before a decision, keeps
  only a matching decided candidate, validates transaction/device evidence,
  and keeps legacy pending records rollback-only.
- Initialize, attach, and restore prepare candidate journals before publishing
  access or replacing installed resources. Ordinary candidate rejection keeps
  the old workspace; uncertain access commits invalidate access and release
  writer resources. Revoke stays serialized and reports failed durability.
- Private-file removal flushes the existing parent directory even when the
  entry is already absent. The test-only fault seam sits between unlink and
  directory flush; production defaults to no fault.
- Validation: Astra medium final review had no P1/P2 blocker; Xcode 27 macOS
  focused lane passed 107/107, and the fresh serial iOS 27 simulator rerun
  passed 62/62 focused tests. These are focused code-boundary gates, not full
  release evidence for CP-B, signed UI, physical iPhone, Windows, providers,
  or final security.

## 2026-09-22 P06-B read-only node inspector

- `454f4d1` is the accepted source checkpoint after Astra medium review. It
  adds selected Canvas node metadata, exact `LifeOS/` Markdown reference
  validation, bounded read-only preview, refresh/back, Mac trailing inspection,
  iPhone sheet presentation, and late-result guards for selection, vault,
  lifecycle, and cancellation changes. It does not create, edit, publish, or
  network-read documents.
- Xcode 27 macOS focused suites passed 73/73: 22 interaction and 51 workspace.
  The iPhone 17 run passed all 21 interaction tests and all new inspector tests;
  four older workspace tests failed after the offline Windows host caused
  backend/websocket timeouts. Astra found no P1/P2 inspector blocker, but the
  test-host isolation issue stays qualified and separate from this checkpoint.
- Mounted native presentation, signed/App Group behavior, physical-device
  input, real-vault round trip, and final visual review remain open.

## 2026-09-22 P06-B existing-document chooser

- `433ea64` is pushed on `main` and `origin/main` after Astra medium's
  post-correction READY TO CHECKPOINT review. The chooser accepts one existing
  `.canvas` or `.md` selected inside the attached vault's exact `LifeOS/`
  directory; component containment, traversal/query/fragment, extension,
  symlink, generation, and lifecycle checks remain mandatory.
- Canvas selection keeps the current project and viewport until a candidate
  opens successfully. Markdown is a read-only inspector preview. Cancellation,
  failure, stale results, and retry preserve or clear state deliberately; a
  successful retry clears all four prior error/retry fields.
- The tranche introduces no vault mutation, enumeration, indexing, network,
  or CP-B adapter behavior. The six-file source allowlist and mirrored
  contract tests are the accepted scope.
- Swift parsing, macOS and iPhone 17 arm64 build-for-testing passed. Mac test
  execution was blocked by testmanagerd sandboxing and the iOS focused run by
  CoreSimulator refusal; mounted picker/viewport runtime evidence is pending.

## 2026-09-22 P06-B mounted picker hardening

- `1df4642` is pushed on `main` and `origin/main` after Astra medium's final
  source gate. The native picker now retains AppKit ownership through sheet
  completion, dismisses the owned UIKit picker through its actual relationship,
  returns nil for pre-presentation cancellation, and uses static representable
  teardown with owner tokens.
- SwiftUI refuses overlapping picker tasks, disables all competing open/retry
  controls while a picker is active, clears document tickets on teardown, and
  surfaces sanitized picker errors. Folder/document public APIs and
  `asCopy: false` remain unchanged.
- Mac and iPhone 17 arm64 build-for-testing passed. Native mounted picker,
  interactive dismissal, viewport, and real-vault no-mutation evidence remain
  pending; the exact next contract is `tasks/p06b-mounted-picker-plan.md`.
