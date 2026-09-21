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
  cleanup, commit, push, and local/origin parity. This P00 pass did not commit
  or push.
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
