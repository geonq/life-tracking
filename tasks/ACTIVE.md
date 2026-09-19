# Active LifeOS execution

Status: IN PROGRESS — updated 2026-09-19 Europe/Berlin.

main and origin/main are clean and aligned at 25e6135, including the accepted Planning Storage Packet A checkpoint and Packet B publication journal. Release remains NO-GO. The 258-leaf registry is acceptance evidence, not an implementation percentage.

## Product authority

- Native SwiftUI/WidgetKit on Mac and iPhone is the product; Windows over Tailscale is the private structured-data/document boundary.
- Use truthful live data. Calendar, Reminders, Obsidian, HealthKit/Zepp, finance and tax retain their domain authority; do not add a competing universal store.
- No generic advisor or conversational AI. Calorie-photo estimation is the only in-app AI flow.
- Use SF Pro/system typography, semantic icons, brand palette, green estimates, orange calories, compact hierarchy, Notion-style calendar scrolling/pinch, interruptible motion and Reduce Motion final states.

## Current accepted packet

- Planning Storage Packet A is Astra Medium ACCEPTED. It adds strict additive-key decoding, pre-allocation payload bounds, NUL-safe explicit-length SQLite text binding and adversarial durability tests.
- Evidence receipt: artifacts/final/planning-core/packet-a-repair-20260919.md.
- Controller evidence: storage guard PASS with 40.6 GiB free; Mac build-for-testing PASS; focused Mac durability 19/19; generic iOS device SDK build PASS. Simulator/physical device remain open.
- Packet A is committed and pushed at e9a2a2c; its acceptance is a completed checkpoint.
- Packet B publication journal is Astra Medium ACCEPTED and pushed at 25e6135. Its receipt records 57/57 focused Mac tests, independent result validation, generic iOS SDK build and storage guard PASS, including retry/reopen and repeated-continuation replay. Filesystem publication remains a separate gate.
- Packet C design is recorded at artifacts/final/planning-core/packet-c-design-20260919.md (145 lines); it is the next exact Luna allowlist after controller review.

## Existing evidence

- Finance packets cover institution detection/import, mapping/reimport, recurring Manage Payment controls, investment/Robinhood validation and bounded live readback. Live provider acceptance remains open.
- Usage packets cover provider-neutral registry, Claude retention, manual Gemini subscription readings and compact hierarchy; automatic subscription quota is unsupported without an official endpoint.
- Windows disposable source suites and storage guard pass. Canonical host currently has Tailscale/BitLocker healthy, LifeOSAPI stopped, LifeOSGateway absent, no LifeOS listener and only the legacy sync task Ready.
- Mac Home d2ece98 passed geometry 2/2 and dark snapshot acceptance 1/1; stability receipt records focused 1/1 with an isolated manual fixture alive.
- Obsidian Canvas/Markdown codec/value binding f53c77c passed focused 31/31 and smoke checks; durable store, conflict journal, graph/UI, gateway and sync remain open.
- Tax parser f62ef9e and UsageHistory locking dfeab04 are pushed and Astra-accepted. Core Mac logic receipt is 193/193; generic iOS compile passes while CoreSimulator is unavailable.
- Canonical Windows preflight is STOP/NO-GO: artifacts/final/windows/preflight-4db1eaa-20260918.md.

## Remaining work

1. Implement the exact Packet C filesystem publication/bookmark/iCloud scope from its accepted design before graph/spatial index, native views, bounded gateway route and live round trip.
2. Finish Windows candidate verification and supervised recovery/install, then verify service identity/ACLs, Serve, health/readiness, listener, restart and rollback.
3. Verify live Enable Banking, recurring reconciliation, Trade Republic import, Robinhood/net-worth separation and the accelerated Windows outage.
4. Implement/verify LifeOS-owned workouts and physical Zepp/HealthKit provenance; leave proprietary Zepp fields unavailable without evidence.
5. Verify existing and lock-screen widgets, App Group, signing, background refresh, native Shortcuts and physical iPhone behavior.
6. Perform route-level visual/motion acceptance and final batched Astra security review, then close every release-blocking finding.

## Worker contract

Luna Max receives one exact disjoint file set at the current SHA. Astra Medium reviews the actual diff and evidence after each meaningful batch. Workers report changed paths, tests/exit codes, evidence, complexity and uncertainty. Unexpected scope, destructive migration, security-boundary change or reproducible crash stops the tranche.

Every accepted tranche is committed and pushed to main, checked for local/remote SHA parity, and reflected in HANDOFF, PHASE_STATUS and this file. Apple lanes use one serial xcodebuild process with the storage guard; quiet compilation continues until an explicit result. Clean only targeted disposable processes/caches.

See tasks/final-execution-plan.md for ownership, dependencies, tests and stop conditions.
