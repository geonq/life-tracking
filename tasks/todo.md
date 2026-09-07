# TODO — LifeOS completion pass

Updated 2026-09-07 22:53 Europe/Berlin. This is the current manual queue.

## Source and evidence

- Branch: `lifeos-foundation-checkpoint-20260812`.
- Local HEAD: `65b2140`; local origin tracking ref: `f600a44`.
- iOS logic: 1,245 passed. macOS logic: 47 passed on the previous checkpoint.
- API contracts/typecheck/tests: 91 passed.
- Windows candidate verifier and read-only preflight pass; the authorized
  install retry is active and needs sanitized post-install evidence.
- Three Astra Medium audits are complete. Treat their P1 findings as release
  blockers and their tranche order as the current plan.

## Ordered implementation queue

1. **Nearby trust and Calendar authority**
   - Disable automatic unpaired Calendar exchange; implement explicit pairing,
     key binding, revocation, replay protection, and negative tests.
   - Bound incoming revisions and recover poisoned counters.
   - Validate every Calendar item before changing authority, ETag, or replay
     state; quarantine already-invalid data.

2. **Windows ingress and lifecycle**
   - Preserve raw loopback socket identity through Uvicorn and authenticate
     gateway-to-API callers with a scoped credential.
   - Enforce snapshot age/identity/Serve policy during live requests and
     existing streams.
   - Add rights-aware ACL assertions and tests.
   - Make migration quiesce writers, carry every authoritative envelope,
     revocation/tombstone/replay companion, and classify reinstall/upgrade.
   - Separate pre-acceptance rollback from rollback after new writes; add
     durable recovery phases and process/concurrency tests.

3. **Durable sync and providers**
   - Freeze domain ownership, replica IDs, server epoch, cursors, conflicts,
     tombstones, and byte/count limits in versioned contracts.
   - Add atomic Calendar outbox/receipt persistence and retries, then replicate
     supported Nutrition, Supplements, Fitness journal, Finance imports/budget,
     and preference stores without silent resurrection.
   - Persist/coalesce Enable Banking refresh state and cache; preserve partial
     success and revocation. Keep Trade Republic as confirmed CSV imports.

4. **Health, Shortcuts, and signing**
   - Add bounded HealthKit reconciliation/export with provenance and deletions;
     keep anchors on iPhone and unsupported Zepp metrics unavailable.
   - Add LifeOS App Intents/status results backed by the same sync coordinator.
     Zepp fallback must open the app with a manual instruction when no supported
     action exists; never claim that opening it synchronized data.
   - Build a reviewed Mac USB Personal Team refresh/install workflow that keeps
     the app identity/data, inspects actual profiles/entitlements, and returns
     an expiry receipt.

5. **Widgets and visual finish**
   - Preserve all 18 iOS and 17 Mac kinds. Publish real Tasks data, Finance
     history/budget/inflow data, and truthful Fitness capability states.
   - Fix RHR wording, transparent inner panels, metadata contrast, and dense
     typography. Verify the exact blue ramp, green estimates, grey wallpaper,
     dark/clear/tinted appearances, and every route.
   - Standardize chart gesture ownership, Mac hover/focus, iPhone scrubbing,
     selection persistence, interruption, and motion behavior.

## Closed in this pass

- PayPal removed from active Swift/API/catalog/settings scope.
- Estimate/projection series uses green; warning stays semantic.
- Finance spend, income, and wealth percentages use deterministic largest-
  remainder integer-cent allocation and sum to 100%.
- Persisted lifestyle conflict selection is deterministic.
- Calendar empty timed space uses deliberate double tap.
- PowerShell 5.1 deployment wrapper and SYSTEM task XML are host-compatible;
  source/static/behavioral/legacy Serve tests pass.

## External acceptance gates

- Signed Personal Team App Group/device/widget/background evidence.
- Enable Banking consent/readback for Sparkasse Leipzig and Revolut.
- Physical HealthKit/Zepp/Helio provenance and Mac replica evidence.
- Every widget/module and primary destination in light/dark/grey-wallpaper
  visual and interaction captures.
- Fault traces for offline, kill during upload, revocation, reinstall, expired
  signing, server restore, and rollback.

## Working rules

Use disjoint file ownership for workers, one bounded change set per checkpoint,
relevant tests before integration, and coordination updates under 200 lines.
Never place secrets or user data in source, logs, archives, prompts, or worker
messages. Never claim an external or physical gate from source evidence alone.
