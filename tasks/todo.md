# TODO — LifeOS completion gates

Updated 2026-09-10 09:50 Europe/Berlin.

The reviewed source batches are locally green and committed. Preserve them,
commit this coordination refresh, then continue with remote or device acceptance.

## Active gates

1. Push the three local commits and refresh PR #1/issue status with GitHub CLI.
3. Run staged Windows verifier/preflight on `domke@tailscaleip`, then verify the
   standalone runtime, protected storage, Tailscale Serve, restart recovery,
   and remote readback.
4. Complete real Enable Banking consent/readback and one real Trade Republic
   import. Keep unavailable/provenance states truthful when a source is absent.
5. Exercise iPhone 17 HealthKit, Zepp sync, morning refresh and USB shortcuts,
   and seven-day Personal Team renewal.
6. Restore CoreSimulator and rerun iOS logic/UI/widget acceptance. On the Mac,
   verify the compact Home/Usage hierarchy, calendar gestures, route reversal,
   hover, sheets, and reduced-motion behavior.
7. Resolve the Obsidian graph/mind-map feasibility item in GitHub issue #2.

## Completed verification

Gateway 463 tests; API 140 tests plus typecheck; unsigned macOS build and 54
native tests; generic unsigned iOS build; Swift parse; `git diff --check`; and
focused regression coverage for backend cancellation/admission, calendar
bottom-edge restoration, scene-retained Usage state, and Mac route identity.

## Constraints

Use live production data, serialize native builds with one compiler job, keep
coordination files below 200 lines, use disjoint bounded worker scopes, close
workers/processes after use, and record host/device evidence separately from
source evidence. Do not add a Claude usage watcher, overnight supervisor,
placeholder demo fallback, Advisor, or unrelated conversational AI.
