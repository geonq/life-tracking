# HANDOFF — life-tracking (LifeOS native app)

Updated 2026-09-07 21:30 Europe/Berlin.

## Current verdict

**NO-GO for completion.** The source foundation is substantially complete, but
Windows runtime cutover, signed-device evidence, live provider consent, and
physical widget/background checks remain open. `tasks/final-plan.md` and
`tasks/luna-audit.md` are retained as product evidence; they are not current
runtime state and are not Astra-authored.

The Claude handoff was reviewed after Claude stopped. Luna Max completed the
source/evidence pass, but the Codex weekly limit was reached before an Astra
worker could run. No Astra review or plan exists; the current decisions below
are manually verified Codex state. There is no active Codex/Claude watcher or
overnight scheduler.

## Source state

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD and origin: `c75c1cb` (`Make finance percentages deterministic`).
- The Windows source changes are committed in `e1e1966`; PayPal/UI scope and
  the percentage/conflict fixes are in later checkpoints.
- Working tree was clean after the checkpoint push. Verify parity before the
  next mutation; never reset or discard another worker's work.

## Verified evidence

- iOS unsigned simulator logic suite: **1,245 tests, 0 failures** after the
  current finance/lifestyle changes.
- macOS unsigned logic suite: **47 tests, 0 failures** on the prior checkpoint;
  rerun after the next macOS-visible change.
- API contracts build/typecheck/tests: **pass** (11 files, 91 tests).
- Windows host source checks: PowerShell 5.1 static, behavioral, and legacy
  Serve upgrade/rollback assertions: **pass** in a temporary secret-free bundle.
- Windows source is not deployed. The host still needs staged candidate
  preflight, service/ACL/readback, snapshot freshness, health, and rollback
  evidence before cutover.

## Product state

- PayPal is removed from active Swift/API/catalog/settings scope.
- Estimate/projection visuals use vivid green; warning remains a state color.
- Finance spend, income, and wealth percentages use one integer-cent
  largest-remainder allocator and sum deterministically to 100%.
- Lifestyle persisted conflict selection is deterministic by sorted conflict
  key; mixed states still fail closed.
- Calendar empty timed space creates on deliberate double tap.
- Existing module/widget scope remains intact; no new top-level travel module
  was invented. Finance analytics remains a Finance sub-surface.

## Open gates

- Build a clean Windows candidate with a standalone Windows `node.exe`; run
  verifier and preflight on `domke@geonqserver`; deploy only after every
  service identity, ACL, Tailscale Serve, snapshot, and rollback assertion is
  read back from the host.
- Replace `group.com.hermes.lifeos.REPLACE_WITH_TEAM_CONFIGURED_ID` with the
  real Personal Team App Group when signing; prove app/widget round-trip and
  background refresh on the iPhone.
- Complete Enable Banking consent/readback for Sparkasse Leipzig and Revolut
  Personal. Trade Republic remains a manual import path.
- Validate HealthKit/Zepp/Helio samples and provenance on the physical device.
- Document and test the supported morning Zepp sync Shortcut and Mac USB
  refresh/install Shortcut. They may report Apple permission/signing gates;
  they cannot bypass them.
- Decide whether the lifestyle ledger's full-file rewrite needs a larger
  storage migration; do not change it as an unreviewed drive-by optimization.

## Execution rules

Make one bounded change set at a time, run the relevant checks, update this
file and `PHASE_STATUS.md`, then commit and push. Keep secrets out of source,
logs, archives, prompts, and test output. Use unsigned Xcode settings for
simulator/macOS checks. Treat missing entitlements, live consent, physical
device behavior, and remote runtime state as external evidence gates.

## Human gates

Geonq must provide the real App Group during signed release, approve Apple
device trust/Developer Mode and Health permissions, complete bank consent, and
approve any persistent Windows admin cutover. The personal installation can
use free Personal Team signing with periodic USB refresh if Apple permits it;
the exact expiry and capability behavior must be shown from the signed device.
