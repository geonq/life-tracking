# CHANGELOG — LifeOS native app

## 2026-09-12 — Usage monitoring hierarchy

- `fce94b9` replaces the oversized Usage presentation with compact quota
  cards, a truthful chart legend, grouped range controls, and responsive
  720/960pt layout boundaries.
- Mac controls meet the 32pt contract and iPhone controls the 44pt target;
  endpoint stepping disables correctly and selected details wrap safely.
- Verification: iPhone focused suite **95/95**; macOS settled and breakpoint
  renders **1/1** each; five rendered captures inspected. Astra Medium review:
  **GREEN**. Overall release remains **NO-GO**.

## 2026-09-12 — native macOS route lifecycle

- `070b7db` replaces the shell’s custom route progress state with one typed,
  value-driven Home `NavigationStack` and bounded path grammar.
- Home detail history survives sidebar module switches and Finance/Calendar
  deep links; explicit Home resets it and Back pops one destination.
- Calendar’s deferred macOS editor presentation now checks live mount identity
  and generation in both callbacks and invalidates on disappearance.
- Removed obsolete transition policy/source assertions and the unused route
  cancellation action. Astra Medium review: **GREEN**.
- Verification: iOS focused suite **95/95**; macOS route tests **2/2 exit 0**;
  full macOS snapshot run **51/51 cases passed** before result-archive I/O
  failure. Overall release remains **NO-GO**.

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
