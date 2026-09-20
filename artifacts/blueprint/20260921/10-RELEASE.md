# Minimal verification and strict release gates
No builds/tests ran in authoring this blueprint. This is an execution plan, not a test receipt.
Strong planning reduces rework; it does not establish correctness of asynchronous or device behavior.

## Cohesive waves
W0 P00: source/receipt/capability inventory only; no full build.
W1 P01–P05 + P07: one Mac/iOS compile after P16 membership substep, batched protocol/store/graph tests.
Astra reviews contracts/migrations/admission once for the wave before real-data writes.
W2 P06/P08–P14: one integrated compile, domain flows and route captures on Mac/simulator.
Astra reviews actual visual recordings, interaction state and domain outcomes as one product wave.
W3 P02 relay deployment + P16 composition + P15 security: outage/replay/security/integration batch.
Astra reviews adversarial results and privacy before pairing real devices or exposing relay.
W4 P17 when Windows returns: deployment/live provider/rollback evidence; focused Astra cutover review.
W5 P18 final release: build both platforms, existing unit/integration suites, full essential journeys and physical gates.
Membership setup P16 may precede its final composition; exclusive ownership remains unchanged.
Do not repeat passed unrelated suites without code/config changes or a new finding.
Integrity tests for migrations/auth remain early: waiting until final release risks corrupting real data.
Unit tests can be authored with source changes but run together at wave boundary.
No heavy full rebuild for documentation or simple reversible visual text edits.

## Evidence classes
S source: named function/path/SHA; means implemented, not operational.
L local: exit code + result bundle/receipt, input provenance, environment and exact source hash.
M Mac runtime: normal nonfixture launch, click/gesture recording, save/relaunch and crash logs.
I simulator: UI and pure behavior; cannot certify physical HealthKit/signature/battery/tint behavior.
W Windows: real protected deployment/ACL/Serve/restart/live readback/rollback.
P physical iPhone: entitlement, grant, widgets/lock screen, USB installation, background and Zepp.
Unsupported capability U: exact reason/source and working truthful fallback; user requirement exception remains explicit.
No aggregate percentage. Every requirement retains separate source and acceptance state.

## Essential end-to-end journeys
G01 Normal Mac/iPhone launch uses real data or honest empty states; no silent demo; no crash.
G02 Calendar create/edit/recurrence/drag/resize/delete/undo; restart; day/week scroll; focal pinch.
G03 Pair Mac/iPhone; save on each offline; restart; exchange reordered/duplicated ops; converge without data loss.
G04 Simulate eight days Windows absence with injected clock; concurrent edits/deletes and clock skew;
disk full/cancel/crash between each persistence boundary; no pending mutation deletion or endless retry.
G05 Windows return: authenticate, replay, compare data and applied ACK frontier, then eligible compaction.
G06 Obsidian: selected vault create project/note/edge → edit in Obsidian → reopen in LifeOS;
offline conflicting changes retained, standard Canvas still usable on both platforms.
G07 Existing bank connections reused; provider→gateway→Mac readback identities/amounts/currency;
expiry/consent/revoke/pagination/rate limit and partial status verified.
G08 Trade Republic/Robinhood actual export preview/import/reimport/correct; net worth no double count.
G09 Recurring auto suggestion + manual weekly/monthly/yearly/nonrecurring survives future refresh.
G10 Workout template/sets/rest/complete/report/edit → HK export once → Zepp observation qualified link.
G11 Nutrition manual/photo/barcode review/save/correction; unconfirmed estimates absent from totals.
G12 Existing supplements/lifestyle/journal/goals/notifications preserved and exercised.
G13 Tax parse/review/export/restart/retention; raw data excluded from every publication/log.
G14 Usage add/hide/pin/manual Gemini + actual Codex + retained Claude; true windows/reset/freshness.
G15 Clipper actual collector readback or explicit unavailable; route/detail works.
G16 Widgets catalog/live producer map, locked/stale states, grey-wallpaper dark/tint captures, valid deep links.
G17 Morning Shortcut accurately reports what it did; USB rebuild/reinstall preserves data and reports profile expiry.
G18 Design all screen states and both platforms; SF Pro, palette, compact scale, clipping, focus, rapid reversals.
G19 Authorized adversarial security pass: forged identity/signature, replay, oversized body,
symlink/reparse/filename escape, corrupted stores, CSV formula, regex stress, dependency/CI and log leakage.
G20 Clean git checkpoint, accepted changes pushed, requirements inventory/context updated, resource cleanup.

## Visual/performance evidence
Mac widths 900/1280/1600; phone portrait and large text; light/dark and reduced motion.
Record Home→Usage→back, Finance detail, calendar pinch/scroll/drag and planning pan/pinch/drag.
Pass requires no jump/blank flash/clipped important value/gesture conflict or restart at each redraw.
Measure with signposts/Instruments at representative and maximum bounded datasets.
60Hz frame target p95 <=16.7ms; investigate recurring >33ms stalls; 120Hz devices not promised 120FPS.
Graph query reports visited nodes vs output; pathological overlap O(n) stated honestly.
Memory bounded with repeated navigation; idle orb/background CPU stops; no per-frame file writes.
Physical-device performance remains open if unavailable; simulator timings are diagnostic only.

## Definition of done
All required inventory rows source-complete, migrations recoverable and essential journeys pass their evidence class.
Every real defect fixed/retested; no unreviewed untracked implementation, forbidden AI or production fixtures.
Windows and physical gates cannot be marked passed by source review or simulator.
When environment unavailable: label “technical implementation complete; W/P verification pending” only if all source gates truly closed.
Do not label whole app complete until pending required live/device gates pass or user explicitly accepts a limitation.
Personal Team profiles expire after seven days per Apple; installed app cannot renew its own signature.
USB Shortcut may orchestrate Mac rebuild/install, but device trust/unlock, Apple account/signing intervention
and any unsupported entitlement remain manual/external requirements.
Required widgets/HealthKit may need capabilities absent from Personal Team; inspect actual profile first.
No plan promises “break-proof”, “zero mistakes”, exact Zepp proprietary parity or perpetual background execution.

## Capability and automation acceptance detail
A free signing failure is not a reason to silently ship missing widgets/HealthKit.
Record profile-entitlement mismatch, exact affected feature and available alternative; obtain geonq's decision.
A signed-app profile may expire during an eight-day outage; Windows absence is unrelated to Apple signing.
Renew before expiry through the available Mac; persist a local reminder and show actual provisioning expiration.
No claim of always-available iPhone app beyond that expiry without successful renewal.
