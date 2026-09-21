# HANDOFF — LifeOS native app

Updated 2026-09-21 Europe/Berlin.

## Active task

P00 truth/capability reconciliation is complete. P01 shared sync contracts,
P02 authenticated replication exchange, and the P03 strict calendar wire codec
plus durable calendar adapter are implemented and pushed. Release is still
NO-GO because Apple signing/runtime, Windows deployment, live providers,
physical-device comparison, and final UI/security evidence remain open.

## Current truth

- `main` and `origin/main` point to `9d222ac` (`feat: harden calendar replication lifecycle`).
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

Continue P04 domain adapters and P05/P06 graph/vault review. Keep one
worker and one Apple lane at a time; preserve gradual commits, pushes, compact
handoffs, and evidence-led gates. Windows remains unavailable and must not be
treated as validated.
