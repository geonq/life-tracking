# HANDOFF — LifeOS native app

Updated 2026-09-12 Europe/Berlin.

## Release state

**NO-GO.** The current Usage source tranche is GREEN. Runtime, live provider,
visual, security, and device evidence is still incomplete.

## Current source checkpoint

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD and origin: `7877ec5 Wire coherent Usage presentation state`.
- Usage now carries a per-provider/window presentation packet and authority;
  omitted supported scopes become authoritative-empty, cached history cannot
  resurrect them, and failed history writes retry after an identical refresh.
- Independent Astra review of this exact Usage patch: **GREEN**.
- iPhone 17 simulator focused suite: **108 tests, 0 failures**.
- macOS snapshot suite on the current commit: **54 tests, 0 failures**.
- Windows source suite: **61 passed, 1 skipped, 0 failures**; the skip is
  Windows PowerShell 5.1 unavailable on Mac.

## Still open

- Remote recovery/install, service listeners, health, and Tailscale Serve are
  unverified; the last contained state had replacement API stopped and gateway
  absent.
- Live Enable Banking consent/account/transaction readback is unverified.
- AppKit route/runtime behavior, visual captures, compact hierarchy, gesture
  behavior, widgets, physical iPhone, signing, and Shortcuts are unverified.
- Zepp workout fidelity/sync and the Obsidian Canvas mind map are unbuilt or
  unverified; see GitHub issue #2.
- Final operational security and device/transport checks remain open.

## Boundaries and next action

Keep SF Pro/system styling, compact Linear/Vercel quality, truthful live data,
no generic advisor or in-app AI, and calorie-photo tracking as the only AI.
Implement the bounded AppKit route host/reducer next, obtain Astra review, then
run visual/runtime evidence before touching the Windows install.
