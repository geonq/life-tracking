# TODO — LifeOS completion pass

Updated 2026-09-07 Europe/Berlin. This is the current manual work queue; no
overnight runner or usage-limit watcher is part of the project.

## Current source checkpoint

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD: `c75c1cb`, pushed to origin.
- iOS logic: 1,245 tests passed.
- macOS logic: 47 tests passed on the previous source checkpoint; rerun after
  macOS-visible changes.
- API contracts/typecheck/tests: pass, 91 tests.
- Windows deployment source tests: pass on remote PowerShell 5.1 in a
  temporary secret-free bundle; no runtime cutover has happened.
- Astra was unavailable after the Codex weekly limit; `tasks/final-plan.md`
  and `tasks/luna-audit.md` are reconstructed product evidence, not Astra
  output.

## Next bounded work

- [ ] Build a clean Windows candidate and record source/archive hashes.
- [ ] Locate or transfer only a standalone Windows `node.exe`; never package
      provider keys, certificates, runtime secrets, or user data.
- [ ] Run candidate verifier and preflight on `domke@geonqserver`.
- [ ] Read back services, task XML, identities, ACLs, Tailscale Serve state,
      snapshot freshness, `/health`, finance response, and rollback state.
- [ ] Deploy the gateway/snapshot writer only if all preflight checks pass.
- [ ] Verify harmless rollback and restore the previous service state if any
      post-cutover check fails.
- [ ] Rerun macOS logic and snapshot checks after source changes.
- [ ] Review existing widgets over the grey wallpaper in transparent-dark,
      tinted, and full-color modes; improve contrast without changing the
      approved brand palette.
- [ ] Complete signed Personal Team/App Group/device/background evidence when
      Apple capabilities are available.
- [ ] Complete Enable Banking consent/readback for Sparkasse Leipzig and
      Revolut Personal; keep Trade Republic as manual import.
- [ ] Validate physical HealthKit/Zepp/Helio provenance.
- [ ] Add and document the morning Zepp sync and Mac USB refresh/install
      Shortcuts with explicit failure receipts.

## Closed in this pass

- [x] PayPal removed from active Swift/API/catalog/settings scope.
- [x] Estimate/projection series uses vivid green; warning stays semantic.
- [x] Finance spend, income, and wealth whole percentages use deterministic
      integer-cent largest-remainder allocation and sum to 100%.
- [x] Persisted lifestyle conflict selection is deterministic by sorted key.
- [x] Calendar empty timed space uses deliberate double tap.
- [x] PowerShell 5.1 deployment wrapper passes script parameters safely.
- [x] Windows deployment static/behavioral/legacy rollback tests pass.

## Deliberately deferred decisions

- [ ] Evaluate the lifestyle ledger's full-file read/modify/write cost as a
      separate storage migration; do not mix it into a UI or security patch.
- [ ] Keep travel/analytics as existing Finance surfaces unless a concrete
      navigation requirement is accepted; do not invent a top-level module.

## Working rules

Use one bounded change set, run its relevant checks, update the handoff and
phase files, commit, push, and verify remote parity. Keep coordination files
under 200 lines. Never claim simulator, source, consent, device, or remote
runtime evidence for a gate that was not actually observed.
