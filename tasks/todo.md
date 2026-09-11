# TODO — LifeOS completion gates

Updated 2026-09-11 Europe/Berlin.

Current checkpoint: `ebbfff2c1eda6d017669cc391050f45296b4429d` on
`lifeos-foundation-checkpoint-20260812`. The local branch is 20 commits ahead
of origin tracking and has not been pushed. Local source checks pass, but the
previous final Astra review was RED, so release status remains pending.

## Active gates

1. Run a fresh Astra Medium security review after this coordination refresh.
   Include adversarial HTTP/WS, authentication, replay, input bounds,
   dependency, and deployment checks.
2. Synchronize the candidate and refresh GitHub PR state after the review.
3. Complete bounded Windows recovery, candidate install, standalone runtime,
   protected readback, Tailscale Serve, restart recovery, and health checks on
   `domke@tailscaleip`. Current host evidence is stopped `LifeOSAPI`, no
   expected listeners, an active deployment transaction, recovery phase
   `artifacts`, and 31,226 units.
4. Complete real Enable Banking consent/readback and one real Trade Republic
   import. Keep missing-provider states truthful.
5. Exercise iPhone 17 HealthKit, Zepp sync, morning refresh and USB Shortcuts,
   and seven-day Personal Team signing renewal.
6. Restore/verify CoreSimulator and capture Mac/iPhone visual, gesture,
   widget, and animation evidence, including compact text, transparent
   grey-wallpaper widgets, calendar scroll/pinch, sheets, hover, and route
   reversal.
7. Resolve the Obsidian graph/mind-map feasibility and storage decision in
   GitHub issue #2. Do not mark it complete without evidence.

## Completed local verification

- Repository source validator: **163 passed**, **47 subtests passed**.
- Gateway: **483 passed**, with two dependency deprecation warnings.
- API: **141 tests passed** and typecheck passed.
- Contracts: **198 tests passed** and build passed.
- Full and production-only `npm audit`: **zero vulnerabilities**.
- Unsigned `LifeOSMacLogic`, `LifeOSLogic`, direct `LifeOSWidget` iOS target,
  and `LifeOSPrereleaseIOS` passed; macOS logic XCTest passed **54 tests**.
- The `LifeOSWidgets` macOS-only destination list is a scheme metadata issue,
  not a source failure.
- Calendar authority now rejects more than 1,024 items, matching native. An
  oversized persisted snapshot fails closed without truncating raw state.

## Constraints

Use live production data, serialize native builds with one compiler job, keep
coordination files below 200 lines, use disjoint bounded worker scopes, and
close workers/processes after use. Keep fixtures explicit and isolated. Do not
add a Claude usage watcher, overnight supervisor, demo fallback, generic
assistant/advisor, or unrelated conversational AI. Calorie-photo AI only.

Do not claim Windows runtime, provider, physical-device, visual, CoreSimulator,
or Obsidian completion from source checks alone.
