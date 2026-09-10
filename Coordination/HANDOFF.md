# HANDOFF — LifeOS native app

Updated 2026-09-10 09:50 Europe/Berlin.

## Current verdict

**Source candidate is green for the local compile and automated gates. Release
and merge are still pending external runtime evidence.** The reviewed native
and backend batches are committed locally; do not reset or discard them.

Advisor and generic conversational AI are absent from the product path. Calorie
photo tracking is the only permitted in-app AI flow. No usage watcher or
overnight scheduler is part of the product.

## Git and review state

- Branch: `lifeos-foundation-checkpoint-20260812`.
- Local `HEAD`: `3f274e9` (`Harden protected storage and deployment boundaries`).
- Remote branch currently resolves to `46c4160`; the two reviewed implementation
  commits and this coordination update still need an attributable push.
- The working tree contains only the coordination-document refresh.
- PR #1 was last observed as open and draft; refresh it with `gh` after pushing.
- Preserve small coherent commits. Do not merge until the external gates below
  have direct evidence.

## Implemented source slices

- SF Pro/system typography, dark tokens, separated semantic accents, compact
  Home/Usage cards, semantic SF Symbols, grey-wallpaper widget legibility, and
  reduced model-bar animation replay.
- Calendar mobile scrolling, minute-precise timeline restoration, attainable
  bottom-edge clamping, paging/editing, Mac trackpad magnification, explicit
  pairing, authenticated payloads, bounded decoding, and timestamp validation.
- Finance live Enable Banking state, manual Trade Republic import, durable
  imported-finance reconciliation, scene-retained chart state, and truthful
  unavailable states.
- Fitness recovery/biology/nutrition, local workout templates/exercises/
  sessions/sets/history/PRs/reports, and bounded read-only HealthKit evidence.
- Tax redaction before persistence/evidence, page exclusion from sync,
  formula-safe CSV export, atomic replacement, and legacy migration.
- Bounded API/gateway reads, localhost/JSON headers, constant-time secret
  comparison, explicit Codex executable paths, Windows manifest/ACL/recovery
  checks, and bounded protected-storage executor admission.
- Mac module identity is stable across same-module routes; Home and Usage stay
  mounted together, detail entry remains 180ms/8pt, and outgoing detail fade is
  120ms with reversal-aware starting values.

## Security status

The twelve Claude findings are addressed in source and regression tests:
nearby calendar pairing/authentication, remote timestamp/deletion validation,
Calendar Codable limits, Keychain sync token handling, bounded JSON reads, tax
redaction/page handling, CSV formula neutralization, atomic tax writes,
symlink-safe usage writes, localhost Host checks, explicit Codex path
resolution, and constant-time ingest-secret comparison.

The protected storage executor now has a fixed four-worker/four-queued budget,
typed overload/shutdown responses, exactly-once slot ownership, and repeated
cancellation draining. Windows ACL and PowerShell behavior still require a
real Windows run; source tests are not a substitute for that gate.

## Verification evidence

- Gateway: **463 pytest tests passed**, with dependency deprecation warnings.
- API: **140 Vitest tests passed** and TypeScript typecheck passed. Loopback
  tests required elevated execution because the sandbox rejects local binds.
- macOS: unsigned `LifeOSMacLogic` build passed; **54 native tests passed**.
- iOS: generic unsigned `LifeOSLogic` build passed. CoreSimulator currently
  refuses connections, so iPhone simulator tests have no current execution
  result.
- Swift parse checks and `git diff --check` passed.
- No visual sign-off has been claimed from PNG existence alone. The real Mac
  UI and physical iPhone still need interaction/rendering evidence.

## External acceptance gates

- Run the staged Windows verifier/installer, standalone runtime, Tailscale Serve,
  restart recovery, protected snapshots, and remote readback on `domke@tailscaleip`.
- Complete Enable Banking consent/readback with the real accounts and import a
  real Trade Republic CSV through the durable reconciliation path.
- Exercise HealthKit, Zepp sync, native morning refresh/USB shortcut flows, and
  seven-day Personal Team signing renewal on the iPhone 17 and Mac.
- Inspect the Mac UI at the documented viewport and verify Home/Usage hierarchy,
  calendar pinch/scroll, rapid route reversal, hover, sheets, and compact text.
- Restore CoreSimulator before claiming current iPhone UI/gesture/widget tests.
- Obsidian graph/mind-map integration remains GitHub issue #2 and is not silently
  represented as complete.

## Next serialized queue

1. Commit this coordination refresh, push the three local commits, and capture
   GitHub status with `gh`.
2. Re-run the Windows staged verifier/preflight and then perform remote runtime
   gates without mutating the dirty Windows checkout unnecessarily.
3. Capture visual/native evidence, provider/device evidence, and only then move
   PR #1 from draft or merge it under the user's authorized workflow.

Keep this file and the other coordination files below 200 lines. Record every
new external result here before calling the phase complete.
