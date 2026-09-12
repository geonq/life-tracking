# CHANGELOG — LifeOS native app

## 2026-09-12 — coherent Usage presentation state

- `7877ec5` wires the coordinator packet through iOS and macOS Home/Usage.
- Authority is durable per provider/window; complete payload omissions become
  explicit empty state and cached history cannot reappear after refresh.
- Failed history persistence remains pending and retries on an identical
  refresh; dataset identity, generation, cancellation, and viewport bounds are
  covered by focused tests.
- Verification: iPhone 17 simulator **108/108**; macOS snapshots **54/54**;
  Windows source suite **61 passed, 1 skipped**.
- Independent Astra review: **GREEN** for this source tranche. Overall release
  remains **NO-GO** until runtime, live backend, visual, device, Zepp,
  Obsidian, and final security evidence is recorded.

Earlier entries are preserved in
`Coordination/archive/CHANGELOG-2026-09-12-pre-usage.md`.
