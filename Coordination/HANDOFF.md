# HANDOFF — LifeOS native app

Updated 2026-09-21 Europe/Berlin.

## Active task

P00 truth/capability reconciliation is complete. P01 shared sync contracts,
P02 authenticated replication exchange, P03 calendar replication, and the P04
strict training payload boundary are implemented and pushed. Release is still
NO-GO because Apple signing/runtime, Windows deployment, live providers,
physical-device comparison, and final UI/security evidence remain open.

## Current truth

- `main` and `origin/main` point to `b0e52e1` (`feat: add strict fitness payload boundary`).
- P00 ledger remains the source of acceptance truth: 258 leaves, 7 aliases,
  pending evidence; do not infer a percentage from source presence.
- P01 checkpoints: `a21ccf3`, `673dc0a`.
- P02 checkpoints: `a629ad3` durable SQLite core, `cd78a0f`/`1f65326` relay and
  security corrections, `83365b1` signed-frame verification, `038cd37`
  authenticated exchange integration and nested record hardening.
- P03 checkpoint: `e76be67` activates app Sync sources and adds a strict,
  bounded, NFC-normalized CalendarSeriesPayload/CalendarPayloadCodec with
  deterministic ordering and icon hash-before-ImageIO validation.
- P03 durable checkpoint: `9d222ac` adds the calendar store/adapter/composition,
  authenticated ACK separation, replay-anchor durability, safe compaction,
  conflict retention, contiguous frontier handling, and focused Swift
  regression coverage. It was reviewed by Astra and pushed to `origin/main`.
- P04 payload checkpoint: `b0e52e1` adds strict training payload serialization,
  bounded canonical JSON, NFC wire normalization, finite/fractional numeric
  handling, and focused parser/domain regressions. It is serialization only;
  durable fitness store adapters are still open. Astra static review passed.
- P04 adapter dispatch is blocked at CP-B: the current source has no sealed
  `SyncStoreKind`, replication coding map, command-to-wire identity row, or
  training tombstone contract. Do not let a worker invent these boundaries.
- The eight D1 graph files remain untracked candidate bytes. Do not stage,
  edit, delete, or treat them as production until P05 reviews them.

## P02 evidence

- Gateway migration creates the sequence index after legacy-column repair;
  durable stream heads make frontier reads transactional and bounded.
- Dependency-aware paging is FIFO/de-duplicated, byte-bounded, restart-safe,
  and advertises only contiguous delivered device sequences.
- Swift verifies nested operation/ack signatures against the endpoint's pinned
  member roster and separates the gateway acknowledgement cursor from device
  frontiers.
- `PYTHONPATH=. python3 -m unittest services.gateway.test_replication`: 23
  passed, 1 cryptography-dependent skip. API typecheck and 160 API tests pass.
  Python bytecode generation was sandbox-blocked; `git diff --check` passes.
  Calendar Swift source received an Astra PASS; live Xcode build and Swift
  tests are blocked by the local license gate (exit 69).

## Next action

Resolve CP-B or keep the adapter lane paused while P05/P06 graph/vault review
advances. Keep one worker and one Apple lane at a time; preserve gradual
commits, pushes, compact handoffs, and evidence-led gates. Windows remains
unavailable and must not be treated as validated.
