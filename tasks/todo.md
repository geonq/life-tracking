# TODO — LifeOS completion gates

Updated 2026-09-09 18:34 Europe/Berlin.

Local source implementation and review are complete at source commit `656e3f1`.
The remaining queue requires external runtime, provider, device, and visual
evidence.

## Active gates

1. Provision and verify the Windows standalone runtime, service host, Tailscale
   Serve path, protected snapshots, restart recovery, and remote readback.
2. Complete Enable Banking consent/readback with the real accounts and import a
   real Trade Republic CSV through the durable reconciliation path.
3. Exercise HealthKit, Zepp sync, Shortcuts, USB refresh, and seven-day Personal
   Team signing/renewal on the physical iPhone 17 and Mac.
4. Rerun iOS UI, macOS UI, and WidgetKit acceptance: scroll reachability,
   keyboard/sheet dismissal, pinch/hover behavior, and transparent grey-wallpaper
   rendering.
5. Verify live freshness and truthful unavailable states after authority setup;
   keep visual fixtures out of production reads and sync.
6. Resolve the Obsidian graph/mind-map feasibility item in GitHub issue #2.

## Completed verification

API 131 tests plus typecheck; gateway 447 tests; repository validators 157
tests plus 47 subtests; iOS logic 1,526 tests; macOS logic 49 tests; available
unsigned LifeOS build; Swift parsing; XcodeGen; native calendar; release
invariants; Advisor source scan; and diff check.

## Constraints

Use live production data, serialize native builds, keep coordination files under
200 lines, use bounded implementation/review scopes, and record external gates
separately from source evidence. Do not add a usage watcher, scheduler, demo
fallback, or unrelated conversational AI.
