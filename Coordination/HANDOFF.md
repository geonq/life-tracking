# HANDOFF — LifeOS native app

Updated 2026-09-16 Europe/Berlin.

## Active task

Continue the finance institution-detection tranche after the verified Windows
publication/security and macOS storage checkpoint. Keep the release verdict
honest; do not call the product done.

## Current truth

- Release is **NO-GO**. `main` and `origin/main` are clean and equal at
  `8fde743` (`Harden Windows publication and bound Apple build storage`).
- Windows verification uses disposable staging at
  `C:\Users\domke\lifeos-a2-snapshot-20260916`; canonical installation and
  recovery remain untouched. `LifeOSGateway` is absent and `LifeOSAPI` stopped.
- No generic advisor, usage watcher, demo fallback, or conversational AI is
  allowed. Calorie-photo tracking is the only in-app AI boundary.

## Latest evidence

- Windows static, legacy Serve, native progress, native snapshot, and complete
  behavior suites pass on GEONQSERVER. Behavior has one explicit skip because
  the installed-service branch cannot run without `LifeOSGateway`.
- Native snapshot coverage includes job-tree cleanup, monotonic deadlines,
  restricted stdio handles, ACL/identity checks, ReplaceFileW states 1175/1176,
  partial 1177 recovery, and zero/one/multiple preserved-path diagnostics.
- Local deployment source harness: 75 passed, 2 environment skips. Native C#
  extraction/build: 0 errors, 31 nullable/platform warnings.
- Storage tests: 7 passed, 2 subtests. `bash -n` passes. Storage check reports
  28.8 GiB free, 16 GiB Developer root, 11 GiB device support, and one kept
  shutdown iPhone 17 simulator.

## Storage policy

- `scripts/maintain_macos_storage.sh` is report/dry-run by default; deletion
  requires `--apply`, uses scoped generated paths, skips booted simulators,
  refuses active or uncheckable `xcodebuild`, and fails build lanes below a
  15 GiB floor.
- Apple validation/prerelease lanes call the guard before every lane and use
  serialized `xcodebuild -jobs 1`. No scheduler was added.
- The guard is the required preflight for future Apple lanes. Generated
  DerivedData and validation artifacts have owned paths; source, personal
  data, final evidence, and the kept simulator are outside cleanup scope.

## Open gates

- Finance institution-detection plan, implementation, focused tests, Astra
  review, then commit and push to `main`.
- Canonical Windows install/listener/health/Serve/Enable Banking readback.
- Finance live connector/import/recurring/net-worth work; Zepp workouts;
  Obsidian Canvas round trip; widgets, Shortcuts, signing, physical iPhone.
- Whole-app visual/runtime acceptance remains open; current UI slices are
  evidence for those slices only, not product-wide approval.

## Next action

Reconcile the current Astra finance plan, dispatch only its bounded Luna patch,
run focused tests and a batched Astra review, then refresh coordination,
commit specific files, push, and verify local/remote parity plus open GitHub
issues/PRs.

## Blockers

No blocker on source/disposable Windows evidence. Installed-service, canonical
deployment, simulator runtime, physical device, live providers, and final
visual acceptance are external or environment-bound and remain unverified.
