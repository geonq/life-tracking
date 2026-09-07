# HANDOFF — life-tracking (LifeOS native app)

Updated 2026-09-07 22:53 Europe/Berlin.

## Current verdict

**NO-GO for completion or production cutover.** The source foundation is
substantially complete, but Astra found P1 security, migration, authority, and
sync blockers in addition to signed-device, provider-consent, and visual
evidence gates. `tasks/final-plan.md` and `tasks/luna-audit.md` are retained as
product evidence, not current runtime state. No Codex/Claude watcher or
overnight scheduler is active.

Three Astra Medium read-only passes completed on this checkpoint: security and
migration, cross-device automation and persistence, and UI/widgets. Their
findings are the current planning baseline; no Astra worker edited, deployed,
pushed, or created scheduling machinery.

## Source state

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD: `65b2140` (`Fix SYSTEM snapshot task registration`). The local origin
  tracking ref remains `f600a44` because the external push was rejected by the
  approval layer; do not claim remote parity until it is approved and pushed.
- The Windows source changes are committed in `e1e1966`; PayPal/UI scope and
  finance/conflict fixes are in later checkpoints.
- Working tree is clean at the local checkpoint. Never reset or discard another
  worker's work.

## Verified evidence

- iOS unsigned simulator logic suite: **1,245 tests, 0 failures** after the
  current finance/lifestyle changes.
- macOS unsigned logic suite: **47 tests, 0 failures** on the prior checkpoint;
  rerun after the next macOS-visible change.
- API contracts build/typecheck/tests: **pass** (11 files, 91 tests).
- Windows source tests: PowerShell 5.1 static, behavioral, and legacy Serve
  upgrade/rollback assertions: **pass** in a temporary secret-free bundle.
- Windows candidate `65b2140` verifier: **pass**, 80 files; archive SHA-256
  `b8b8948374a1729c335e9e497cf537b993cea84744306abfdd0088f151eb403f`.
- Windows candidate preflight: **pass**; no service, ACL, task, data, or Serve
  state was changed by preflight. The authorized install retry is active;
  final service/readback evidence is pending.

## Product state

- PayPal is removed from active Swift/API/catalog/settings scope.
- Estimate/projection visuals use vivid green; warning remains a state color.
- Finance spend, income, and wealth percentages use one integer-cent
  largest-remainder allocator and sum deterministically to 100%.
- Lifestyle persisted conflict selection is deterministic by sorted conflict
  key; mixed states still fail closed.
- Calendar empty timed space creates on deliberate double tap.
- Existing module/widget scope remains intact; Finance analytics remains a
  Finance sub-surface.

## Open gates, in order

- Close P1 security and authority gates: authenticated nearby pairing and
  bounded Calendar revisions; authenticated gateway-to-API callers; raw
  loopback identity through Uvicorn; runtime snapshot leases; quiesced,
  versioned migration and rollback authority; rights-aware ACL verification;
  complete Calendar item validation.
- Finish Windows service identity, task XML, ACL, Tailscale Serve, snapshot,
  protected endpoint, finance readback, and rollback evidence.
- Add durable client outbox/acknowledgement semantics and a domain ownership
  contract before calling Mac↔iPhone sync automated. Widgets stay projections.
- Replace `group.com.hermes.lifeos.REPLACE_WITH_TEAM_CONFIGURED_ID` with the
  real Personal Team App Group; prove signed app/widget round-trip and
  background refresh on iPhone.
- Complete Enable Banking consent/readback for Sparkasse Leipzig and Revolut;
  Trade Republic remains a manual CSV import path.
- Validate HealthKit/Zepp/Helio samples and provenance on the physical device.
- Complete Tasks, Finance, and Fitness widget data paths, then verify all
  widgets over the grey wallpaper in transparent-dark, tinted, and full-color
  modes without changing the approved brand ramp.
- Document and test the morning Zepp sync and Mac USB refresh/install Shortcuts;
  report Apple permission/signing gates truthfully.
- Decide whether the lifestyle ledger's full-file rewrite needs a separate
  storage migration; do not mix it into another patch.

## Execution rules

Make one bounded change set at a time, run relevant checks, update this file
and `PHASE_STATUS.md`, then commit and attempt the authorized push. Record an
approval block without weakening source provenance. Keep secrets out of source,
logs, archives, prompts, and test output. Use unsigned Xcode settings for
simulator/macOS checks. Treat entitlements, live consent, physical-device
behavior, and remote runtime state as external evidence gates.

## Human gates

Geonq must provide the real App Group during signed release, approve Apple
device trust/Developer Mode and Health permissions, and complete bank consent.
The personal installation can use free Personal Team signing with periodic USB
refresh if Apple permits it; show exact expiry and capability behavior from the
signed device.
