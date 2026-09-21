# R17-08 — authoritative dispatch and section precedence

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Read this sheet FIRST, then the ordered `contractFiles` array for your packet in 14-OWNERSHIP.json.
Each array is explicit filenames, not a glob; repeated filenames removed preserving first occurrence.
Read older baseline first, amendments in numeric revision order, R17 last. Highest listed revision wins ONLY for its stated topic.
No historical READY claim authorizes execution. User final go remains required. 203 existing exclusive paths are unchanged.

## Contract groups (expanded exactly in manifest)

|group|scope|
|---|---|
|BASE|baseline, domain/product packets, contracts/migration, requirements, no-guessing, dependencies, checkpoint and coverage rules|
|VISUAL|03/04/05/12, OS27 matrix17, interaction20, research25 and composition27|
|WIRE|R3 DTO/HTTP/value schemas; R4 domain values/codecs/keys/trust/transport; R5–R12 protocol/trust/alias corrections|
|ARCHIVE|R4 archive/release, R6–R16 receipt/recovery/manifest/authority amendments; R17-01…07|
|CALENDAR|R4 calendar/templates; R5 deletion, R6/R7/R8/R9 gestures and R10/R11 transaction/field corrections|
|FINANCE|R3 finance features; R4 finance values/algorithms; R6 travel boundary|
|FITNESS|R3 fitness/usage; R4 fitness/values/algorithms; R6 domain closure|
|PLANNING|R4 planning; R8 alias; R9 alias; R10 SQLite; R11 fence; R12 trust/port amendments|
|PLATFORM|R3 platform/widgets/security; R4 dependency/security/widgets; baseline release matrix|

The generated `__meta.contractGroups` arrays define exact group membership; do not infer filenames from this prose.
The `__meta.packetContractGroups` entries select groups per row below; union them, deduplicate, then order baseline numbered sheets first and revision-numbered sheets ascending (filename ascending within revision).
That exact compiled order is persisted in each contractFiles array; R17 remains last. Group table order is selection order, not conflicting override precedence.
`contractFiles` also includes that packet's exact R2-Pxx sheet; baseline R2 hashes are evidence anchors, not instructions to overwrite changed code.

|packet|selected groups plus R2-Pxx|exclusive objective|
|---|---|---|
|P00|BASE,VISUAL,PLATFORM|reconcile current source/evidence and full feature ledger, toolchain inventory|
|P01|BASE,WIRE,ARCHIVE|all wire types/codecs/validators/trust/signatures; no persistence implementation in P18 files|
|P02|BASE,WIRE,PLATFORM|gateway/relay HTTP, bounded authenticated transport; consume P01 DTOs|
|P03|BASE,WIRE,CALENDAR,FINANCE|durable calendar/finance adapters/markers and travel store|
|P04|BASE,WIRE,FITNESS|durable fitness/nutrition/supplement adapters/markers|
|P05|BASE,WIRE,PLANNING|existing D1 acceptance/repair and injected SQLite port|
|P06|BASE,WIRE,PLANNING,VISUAL|native vault graph, one writer/publication/observer, gestures|
|P07|BASE,VISUAL|SF Pro/SF Symbols, compact tokens, interruptible transitions/orb lifecycle|
|P08|BASE,CALENDAR,VISUAL|calendar layout, one now-line, scroll/pinch/drag ownership|
|P09|BASE,FINANCE,VISUAL|live finance, imports/recurrence/net-worth/travel presentation|
|P10|BASE,FITNESS,VISUAL|workout/nutrition/lifestyle UI and durable flows, no generic advisor|
|P11|BASE,FITNESS,PLATFORM|HealthKit/Zepp provenance/export/reconciliation, honest unavailable states|
|P12|BASE,FITNESS,PLATFORM,VISUAL|capability-based usage providers, truthful manual Gemini boundary|
|P13|BASE,WIRE,PLATFORM,VISUAL|tax privacy/retention/export/sanitized adapter|
|P14|BASE,CALENDAR,FITNESS,PLATFORM,VISUAL|all widgets, lock screen, App Intents, real signing/Shortcuts limits|
|P15|BASE,WIRE,PLATFORM|proved dead paths, Node/CI/security hardening; route foreign-file repairs to owner|
|P16|BASE,WIRE,ARCHIVE,PLATFORM,VISUAL|app/target membership and public API composition only|
|P17|BASE,WIRE,PLATFORM|Windows deployment/restore/service/ACL/Tailscale evidence when host available|
|P18|BASE,WIRE,ARCHIVE,PLATFORM,VISUAL|receipt/archive/authority implementation FIRST; final evidence separately|

## Explicit section-level supersession

|historical clauses|final authority / retained portion|
|---|---|
|R15-01 Complete V7 records/log/anchor, durable active call order, migration; R16-01 all|R17-01 lifecycle+R17-02 container/migration; retain R15 finalization/binding V7 fields/hash domains only|
|R15-02 cursor/currentUnit/validation/persistence|R17-01 next-ordinal cursor and dispatcher; R17-04 recovery; retain R15 frame order, emission pass semantics and planHash/count formula|
|R15-03 bounds/partition|retain greedy payload algorithm/canonical order/vectors; R17-03 overrides chunk-index cap and envelope-aware item check|
|R13-01 inner bytes/objects|retained exactly except chunk index now0...4095; R17-03 owns outer wrapper and total bounds|
|R15-04 mutation envelope, fence policy, replay; R16-03/04|R17-05/06/07 complete replacement; retain fixed authority path, authorized keys, signature framing only as explicitly repeated|
|R15-05 crash protocol, proof/preimage, inventories|R17-05/07 replacement; original source fingerprints retained with UUID typing|
|R11 capacity/cadence; R16 transition-capacity sentence|R17-02 active receipt compaction, R17-06 authority rotation (independent)|
|R15-06/R16-05 and older dispatch; 11 P18 final-only prompt|this sheet+14 contractFiles+updated11 prompts|
|24 added source paths or stale packet dependencies|14 files/dependencies ONLY; no reserved paths may be added|
|17 OS27 matrix;03/20/27 UI design|retained; compile/runtime availability and device evidence gates remain mandatory|
|all other earlier clauses|retained only for their listed group/topic; no permission to resurrect a replaced schema|

R17 is read after older sheets and controls every conflict in the first8 rows; do not union competing wire objects or overload API variants.
Any unresolved source/contract contradiction is an explicit Astra amendment request, not a worker-selected alternative.

## Ownership, call edges and two P18 dispatches

P01 declares public wire types and pure validator/hash/plan interfaces in its existing Sync files; no import of P18 implementation.
P18 implements actor/filesystem/sink with injected P01 protocols and domain public marker ports. P16 composes after P18 implementation.
P18-I (implementation) follows P01,P06,P15; owns only its3 Shared receipt/archive/data-management files and owned test seams.
P18-E (evidence) is a later invocation of SAME owner after P16 and available P17 evidence; owns release scripts/matrix/UI checks.
Do NOT make P18-I depend on P16; evidence ordering is a controller phase, not a compile/packet dependency edge.
Existing packet DAG remains acyclic. Source ownership is never shared even across P18 invocations.
P16 membership-only edits may register declared files before integration; do not invoke app services until provider implementations ready.
Final evidence includes integrated Mac/simulator, visual/motion, outage/rejoin, adversarial security and storage/process cleanup.
Physical iPhone/OS27 SDK/windows/provider gates may remain unverified; report them explicitly, never declare an app release from blueprint readiness.
