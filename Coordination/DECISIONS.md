# DECISIONS — life-tracking (LifeOS native app)

Updated 2026-09-08 09:40 Europe/Berlin.

## Active design decisions

- The supplied screenshots are a release-blocking quality signal. The app
  needs a coordinated redesign before completion.
- `tasks/design-overhaul-plan.md` is the current design and execution source.
  Astra Medium’s review is incorporated: shared primitives come first,
  foreground/background pairs are explicit, empty-state policies are distinct,
  gestures have ownership, and visual evidence is required.
- Use Apple SF Pro/system fonts throughout. Remove Inter, Space Grotesk, and
  custom font registration after all calls are migrated.
- Read `colors.md` before palette edits. Main blue is `#0253C4`; estimates and
  projections are green; calories are orange; nearby blue accents need distinct
  hue/value. Keep contrast-safe foreground pairs.
- Remove Advisor from every product layer. Calorie picture tracking remains
  the only AI behavior inside the app.
- Use one page frame and shared card/status/button/selector/sheet recipes.
  Cards must carry useful grouping; unavailable states remain compact and
  truthful without giant empty placeholders.
- Calendar vertical scroll, horizontal paging, event editing, and Mac pinch
  magnification have separate gesture ownership. Preserve wall-clock/DST
  semantics and make late-day content reachable.

## Data and security boundaries

- Python remains Calendar authority; local edits need durable outbox receipts
  before sync is called automatic. Missing records never imply deletion.
- Enable Banking is the live bank path; Trade Republic remains confirmed manual
  import. HealthKit stays iPhone-owned and unsupported Zepp actions stay
  visibly unavailable.
- Windows gateway access remains fail-closed with scoped credentials,
  protected snapshots, atomic recovery, rights-aware ACL checks, and no
  secrets in source or logs.
- Personal Team signing, physical-device permissions, widget rendering,
  bank consent, and Windows/Tailscale runtime require direct evidence.

## Workflow decisions

- Use Luna Max for bounded implementation and Astra Medium for batched code
  review. Keep worker write scopes disjoint and make gradual commits.
- Keep coordination files below 200 lines. Never add scheduling or usage-limit
  watcher machinery.
