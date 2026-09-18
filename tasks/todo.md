# TODO — LifeOS completion gates

Updated 2026-09-19 Europe/Berlin. Release: **NO-GO**. Current pushed
checkpoint: `e9a2a2c`; Packet A is Astra-accepted and included.
checkpoint. Do not publish completion percentages; use the evidence
ledger and the classifications in `tasks/final-execution-plan.md`.

## Completed checkpoints

- Native provider-neutral usage registry, manual Gemini boundary, hierarchy,
  reset/pin/hide management, and focused visual coverage.
- Finance institution-aware imports, bounded mapping/reimport, recurring
  candidates with explicit weekly/monthly/yearly management, investment and
  Robinhood validation, and bounded live-readback parsing.
- Windows disposable recovery/source suites, protected storage guard, and
  serialized Mac logic evidence.
- Current full Mac logic: **193/193 passed**. Current focused LifeOSMac
  stability lane: **1/1 passed**. Manual app survived the lane; no new crash
  report was produced. See the stability receipt.
- Obsidian Canvas value packet: bounded Canvas/Markdown codecs and binding,
  **31/31** focused tests, independent smoke pass, and current Mac **193/193**
  receipt at `f53c77c`. Durable store, UI, graph, transport, and sync remain.
- Planning Storage Packet A: additive-key validation, pre-allocation payload
  bounds, NUL-safe SQLite text binding, and adversarial durability coverage.
  Astra accepted; receipt: `artifacts/final/planning-core/packet-a-repair-20260919.md`.

## Ordered execution

1. **Truth and stability** — keep the current handoff files under 200 lines,
   remove stale checkpoint/percentage claims from active plans, and preserve
   the focused crash receipt. Do not change app lifecycle code without a new
   reproduced, symbolicated failure.
2. **Canonical Windows deployment** — inspect the marker, transaction,
   manifest, journal, protected configuration, and staging candidate; validate
   candidate and preflight; obtain Astra review of the exact packet; perform the
   authorized recovery/install; then read back service SIDs/ACLs, loopback
   listeners, Tailscale Serve identity, `/health`, `/ready`, restart, and
   rollback. Keep disposable and canonical evidence separate.
3. **Live finance** — recover the existing Enable Banking configuration before
   requesting anything new. Verify Sparkasse Leipzig and Revolut values from
   provider → gateway → Mac/iPhone, consent/revoke/expiry, pagination,
   freshness, retries, and an offline period. Missing data is never zero.
4. **Imports and wealth** — validate real Trade Republic/Robinhood samples
   through preview, confirmation, relaunch, reimport, correction, and net
   worth reconciliation. Keep investment activity separate from spending and
   do not infer holdings or market prices from incomplete exports. NextSemis is
   optional after the direct path is proven.
5. **Offline resilience** — verify local-first edits, mutation IDs, replay,
   conflict/deletion semantics, restart during writes, disk-full behavior, and
   an accelerated eight-day Windows outage without moving the real system clock.
6. **Fitness and Zepp** — keep LifeOS canonical for exercises, templates, sets,
   reps, load, rest, completion, history, and reports. Import read-only,
   source-qualified HealthKit/Zepp observations. Compare real Zepp, Health,
   and LifeOS records on the physical iPhone; leave proprietary load/PAI/
   Training Effect fields unavailable unless a legitimate source exists.
7. **Obsidian Canvas** — continue the four packets from the committed
   lossless Canvas/Markdown codecs; implement vault binding, atomic store, mutation
   journal and conflict copies; graph projection, spatial index and native Mac/
   iPhone interaction; bounded Windows mirror/proposal transport and wiring.
   Do not write a real vault until authority and conflict policy are selected.
8. **Widgets, Shortcuts, signing** — verify the existing widget catalog plus
   the requested lock-screen widget against dark/tinted/transparent grey
   wallpaper states. Provide honest Morning Sync and USB Refresh Shortcuts;
   opening Zepp is not proof of sync and an AppIntent cannot renew a signature.
   Physical App Group, HealthKit, profile-expiry and background evidence remain
   device gates.
9. **Visual and motion acceptance** — apply the current design coordination
   rules route by route: SF Pro/system typography, consistent icon abstraction,
   compact hierarchy, distinct brand palette, green estimates, truthful
   unavailable states, Notion-style calendar pinch/scroll, interruptible
   motion, and Reduce Motion final states. Review actual captures and live
   interactions, not screenshots alone.
10. **Security and release** — Astra Medium reviews the actual final batch for
    peer admission/replay, identity/Host/redirect/body bounds, secrets/tax
    privacy/regex/CSV, atomic writes/symlinks, usage writer races, offline
    restore/retention, dependencies/CI, and canonical deployment. Close every
    release-blocking finding; then verify commit/push parity and the user-facing
    feature/design inventory.

## Required validation discipline

Before an Apple lane:

```sh
bash scripts/maintain_macos_storage.sh --check
```

Use one serial command with `-jobs 1 -parallel-testing-enabled NO`, a fresh
owned DerivedData/result path, and `scripts/validate_xcresult.py`. Poll until
the command exits; quiet compilation is normal. An interrupted lane is
unverified. The iOS generic build is compile evidence only while CoreSimulator
is unavailable.

Every implementation tranche must state its exact base SHA, disjoint files,
named symbols, invariants, focused tests, expected evidence, stop conditions,
review result, commit, push, and remote SHA parity. Do not start overlapping
workers or leave disposable processes running.
