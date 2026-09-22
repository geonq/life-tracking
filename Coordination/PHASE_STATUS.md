# PHASE STATUS — LifeOS

Updated 2026-09-22 Europe/Berlin. Release: NO-GO.

- Current source checkpoint: `433ea64`; `main`, `origin/main`, and
  `codex/p06-b` are synchronized with the validated P06-B documentation.
- P00: complete; 258 leaves and 7 aliases reconciled, with acceptance evidence
  still pending where the ledger says pending.
- P01: shared sync contract/codec complete at `a21ccf3` + `673dc0a`.
- P02: durable store, relay, authenticated gateway exchange, bounded
  dependency paging, contiguous frontiers, stream-head migration, and nested
  device-signature verification complete at `038cd37`.
- P03: strict calendar codec and durable store/adapter/composition are complete
  at `e76be67` and `9d222ac`.
- P04: strict training payload serialization is pushed at `b0e52e1`; durable
  fitness/nutrition/journal/lifestyle adapters remain open behind CP-B.
- P05 D1: bounded graph/parser/spatial/session/vault work is pushed at `ca2caf1`.
- `0451afb` restores URL-safe Base64 decoding, Xcode 27 public-key compatibility,
  and the actor-safe store URL surface.
- `80579bc` prepares canonical calendar bytes before atomic persistence, keeps
  v1 peer dates compatible, and preserves the global Finance `.iso8601` codec.
- P06-A native Canvas viewport/input checkpoint is pushed at `4ff27e3` after
  Astra PASS. The full macOS lane passed 405/405, focused macOS interaction
  tests passed 19/19, the final worker passed focused iOS interaction tests
  18/18, and generic iOS builds passed. Native physical input remains open.
- P06-B planning workspace transaction checkpoint is implemented at `86baaa8`.
  Calendar can route a selected existing vault to a read-only validated canvas
  document. Selection persistence, revocation, initialize/attach/restore
  resource ordering, journal readiness, and mirrored failure regressions are
  included. Astra medium review is clear for validation.
- P06-B read-only node inspector is pushed at `454f4d1`. It adds selected-node
  metadata, exact in-vault Markdown preview/refresh, Mac trailing inspection,
  iPhone sheet presentation, and lifecycle/path guards without Canvas writes.
- P06-B inspector evidence: Xcode 27 macOS focused suites passed 73/73. The
  iPhone 17 run passed all 21 interaction tests and every new inspector test;
  four older workspace tests failed after offline-host network timeouts, so
  this run is qualified and not a full iOS green gate.
- P06-B evidence: Xcode 27 macOS focused suites passed 107/107; fresh iOS
  27 build-for-testing succeeded and the serial simulator rerun passed 62/62
  focused tests. The simulator was shut down afterward.
- P06-B existing-document chooser is pushed at `433ea64` after Astra medium
  READY TO CHECKPOINT. It validates one existing `.canvas` or `.md` in the
  attached vault's `LifeOS/` root, keeps the old Canvas on failure, and gives
  Markdown a read-only preview. Swift parsing and macOS/iPhone 17 arm64
  build-for-testing passed; runtime picker/viewport evidence remains open
  because testmanagerd/CoreSimulator refused execution.
- Evidence: API typecheck and 160 tests pass; gateway replication is 23 passed
  with one cryptography-dependent skip; `LifeOSMacLogic` passed 405/405 tests
  on Xcode 27/macOS 26.6.2.
- Host: Xcode 27.0 and macOS 26.6.2 arm64 are available. CoreSimulator was
  intermittent after the final run; signing, physical iPhone, Windows, and
  live-provider evidence remain unknown or unavailable.

Next: continue native graph/vault UI with mounted picker presentation and a
real-vault round trip, visual/motion, widgets, providers,
Windows, physical-device, and final security evidence gates. Release remains
NO-GO until those gates close.
