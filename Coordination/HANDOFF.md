# HANDOFF — LifeOS native app

Updated 2026-09-19 Europe/Berlin.

## Active task

Continue the strict release-gate workflow. Release remains NO-GO; use accepted evidence and explicit S/L/W/P/U gates, never a guessed percentage.

## Current truth

- main and origin/main are clean and aligned at 5dae724, which includes the Astra-accepted Planning Storage Packet A, Packet B publication journal, and Packet C filesystem publication adapter.
- Windows disposable staging is separate from canonical install/recovery. Canonical LifeOSAPI is stopped, LifeOSGateway is absent, no LifeOS listener is bound, the legacy sync task is Ready, Tailscale is running, and BitLocker is on C:/D:.
- No generic advisor, conversational AI, or demo fallback is allowed. Calorie-photo tracking is the only in-app AI flow. Usage keeps Claude and provider-neutral/manual Gemini boundary rows without fabricated quota.
- Native SwiftUI/WidgetKit, SF Pro/system typography, brand palette, compact hierarchy, truthful unavailable states, green estimates, and interruptible motion remain product authority.

## Latest accepted evidence

- Planning Storage Packet A repair: additive optional-key decoding; strict required/type/semantic validation; bounded payload validation before allocation/hash; NUL-safe explicit-length SQLite text binding. Astra Medium ACCEPT.
- Packet A source files and focused tests are recorded in artifacts/final/planning-core/packet-a-repair-20260919.md. Storage guard PASS with 40.6 GiB free; Mac build-for-testing PASS; focused Mac durability 19/19; generic iOS device SDK build PASS. Simulator and physical iPhone remain unverified.
- Packet B publication journal is Astra Medium ACCEPTED and pushed at 25e6135. Its receipt records 57/57 focused Mac durability tests, independent xcresult validation, generic iOS SDK build, storage guard and diff checks, including retry/reopen and repeated-continuation replay.
- Packet C filesystem publication adapter is Astra Medium ACCEPTED and pushed at 5dae724. Its receipt records 84/84 focused Mac tests, 21/21 crash-recovery probe cases, adversarial path/identity checks, generic iOS device-SDK build success, and clean diff checks. Signed app, iCloud provider, physical-device, Windows, and whole-app visual gates remain separate.
- Obsidian Canvas/Markdown codec and value binding are pushed at f53c77c; focused codec tests 31/31, independent smoke pass, Mac logic 193/193. Durable store, conflict journal, graph/UI, gateway route, and sync remain open.
- Mac Home repair d2ece98 passed geometry 2/2 and dark snapshot acceptance 1/1. Stability receipt records focused 1/1 while an isolated manual build stayed alive; old XCTest crashes were not reproduced in the normal fixture.
- Finance detector/import, mapping, recurring management, investment/Robinhood validation, and bounded live readback are source-reviewed and locally tested; live provider reconciliation remains open.
- Usage registry/manual Gemini hierarchy, tax parser security, and UsageHistory locking are pushed and reviewed. Current evidence includes 55/160 usage-lock tests and 192/193 full Mac lanes as recorded by their receipts.
- Storage guard syntax/tests pass 10/10. Apple lanes are serialized with -jobs 1; CoreSimulatorService is unavailable.
- Canonical Windows preflight remains STOP/NO-GO; receipt is artifacts/final/windows/preflight-4db1eaa-20260918.md. No canonical mutation has been performed.

## Open gates

- Dispatch graph/spatial index and native Canvas interaction from the now-accepted local filesystem adapter, then bounded gateway wiring and the Mac→Obsidian→iPhone round trip.
- Canonical Windows candidate verification, supervised recovery/install, service/ACL/Serve/health/readiness/listener checks, and rollback receipt.
- Live Enable Banking consent/readback, recurring reconciliation, Trade Republic import, Robinhood/net-worth separation, and offline outage behavior.
- LifeOS-owned workouts plus physical Zepp/HealthKit provenance; proprietary Zepp readiness/load/PAI/Training Effect stays unavailable without evidence.
- Existing and lock-screen widgets, App Group, personal signing, background refresh, native Shortcuts, and physical iPhone behavior.
- Whole-app visual/motion acceptance and final batched Astra security review across Swift, gateway, Windows deployment, tax/privacy, secrets, symlinks, identity, headers, bounds, dependencies, and recovery.
- Automatic Gemini subscription quota/authentication remains unsupported until an official endpoint is verified. No generic advisor AI.

## Next action

Use `artifacts/final/planning-core/packet-c-publication-20260919.md` for the accepted local adapter evidence. The next Luna packet is graph/spatial index and native views; keep real-vault provider behavior, gateway wiring, and device proof behind their own reviewed packets.

## Validation discipline

Run the storage guard before Apple lanes. Use fresh owned result/DerivedData paths, serial xcodebuild, and explicit success markers; a quiet compile is not a stop condition. An interrupted lane is unverified. Clean only targeted disposable apps/caches; never broad-kill or delete active evidence.

## Blockers

Installed-service/canonical Windows state, live providers, simulator runtime, physical device, and whole-app visual acceptance remain external or environment-bound. Packet A acceptance does not approve those gates.
