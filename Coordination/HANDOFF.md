# HANDOFF — LifeOS native app

Updated 2026-09-21 Europe/Berlin.

## Active task

P00 truth/capability reconciliation is complete. P01 shared sync contracts and
P02 authenticated replication exchange are implemented and pushed. Release is
still NO-GO because Apple signing/runtime, Windows deployment, live providers,
physical-device comparison, and final UI/security evidence remain open.

## Current truth

- `main` and `origin/main` point to `038cd37` (`feat: harden authenticated replication exchange`).
- P00 ledger remains the source of acceptance truth: 258 leaves, 7 aliases,
  pending evidence; do not infer a percentage from source presence.
- P01 checkpoints: `a21ccf3`, `673dc0a`.
- P02 checkpoints: `a629ad3` durable SQLite core, `cd78a0f`/`1f65326` relay and
  security corrections, `83365b1` signed-frame verification, `038cd37`
  authenticated exchange integration and nested record hardening.
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
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v services/gateway/test_replication.py`:
  21 passed, 1 cryptography-dependent skip. Python compilation and `git diff
  --check` pass. Xcode build is blocked by the local license gate.

## Next action

Continue P03/P04 domain adapters and then P05/P06 graph/vault review. Keep one
worker and one Apple lane at a time; preserve gradual commits, pushes, compact
handoffs, and evidence-led gates. Windows remains unavailable and must not be
treated as validated.
