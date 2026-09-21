# LifeOS decisions

Updated 2026-09-21 Europe/Berlin.

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
  is P04 `b0e52e1`.
- Apple lanes are serialized, use owned result paths, and are not claimed from
  an interrupted or silent command.

## P00 decisions

- The baseline is the observed HEAD and local origin ref: 328b18e...
- The frozen denominator is 258 leaves plus 7 aliases; no completion percentage
  is calculated.
- P00 retains every old registry/reference locator as pending source evidence.
  It rejects duplicate IDs, duplicate aliases, alias collisions, and
  nonexistent claimed receipt paths.
- The eight D1 files are candidate source bytes, not accepted implementation.
- Xcode/SDK 27.0 is installed by file observation, but xcrun runtime queries
  are unknown until the license gate is resolved. Signing is denied for the
  observed account because no valid identity/profile was present.
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
- Astra static review passed; native Swift runtime evidence remains unavailable
  behind the Xcode license gate.
