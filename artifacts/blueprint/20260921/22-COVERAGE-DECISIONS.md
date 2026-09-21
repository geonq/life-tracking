# Product coverage and unresolved decisions
Status reflects source/previous receipts, not a new runtime audit or completion score.
I=implemented source; P=partial/integration open; M=missing planned behavior; U=unverified environment.
Each family expands into individual requirement IDs in P00; a family row never closes all reference screenshots.

|Feature|State / authority|Packet|Required release evidence|
|---|---|---|---|
|Home, Clipper, route/detail|P; accepted domain snapshots / collector|P07/P16|G01/G15/G18 normal launch, real/empty, reversible routes|
|Calendar create/edit/recurrence/undo|I/P; CalendarStore/external source where configured|P03/P08|G02 restart, DST, one now label, full scroll/pinch|
|Mac↔iPhone outage sync|M; local stores, signed spool only transport|P01–P04/P16|G03–G05 8-day conflicts/replay/reconnect|
|Obsidian vault codecs/journals|I; selected Markdown/Canvas files|P05/P06|G06 no outside writes, unknown fields preserved|
|Mindmap nodes/shapes/arrows/notes|P/M; Canvas authored, Markdown derived|P06|G06 Mac/phone pan/pinch/drag/open and Obsidian roundtrip|
|Live Sparkasse/Revolut|P/U; existing Enable Banking Windows credentials|P09/P17|G07 actual identities/freshness/consent/pagination|
|Recurring detect/manage|I/P; source observations+explicit overrides|P03/P09|G09 weekly/monthly/yearly/nonrecurring across refresh|
|Institution CSV, Trade Republic|I/P; original import provenance|P09|G08 real preview/reimport/correction, unknown mapping|
|Robinhood investments/net worth|I/P; qualified holding/cash observations|P09|G08 valuation time/currency/coverage/no transfer double count|
|NextSemis|optional deferred|none until amendment|Not required; no UI scraping integration|
|Workout templates/sets/rest/history/report|I/P; LifeOS training ledger|P04/P10|G10 complete/edit/restart/offline once|
|Zepp physiological observations|P/U; HealthKit exported source|P11|G10 physical comparison, explicit unsupported metrics|
|Nutrition manual/photo/barcode/recipe/recent|P; confirmed ledger, photo proposal separate|P04/P10/P16|G11 all input flows, save once, offline manual|
|Health metrics/biology/strength/stress|P; source-backed values, experimental labels|P10/P11|G10/G18 each existing drilldown, no invented accuracy|
|Supplements/inventory/reminders|I/P; local occurrence receipts|P04/P10/P14|G12 Taken decrements once; Skip/Snooze no decrement|
|Lifestyle/journal/goals/correlations|I/P; factual user/source records|P04/P10|G12 timezone/restart/edit; no causal medical claims|
|Usage Codex/Claude/Gemini|I/P; reviewed collectors/manual subscription|P12|G14 connection capability/window/reset/stale distinctions|
|Provider add/hide/pin/order|P; local preferences/manual metadata|P12|G14 unknown never executable; Claude retained|
|Tax extraction/export/privacy|I/P; protected local raw+sanitized publication|P13/P15|G13 formula neutralization/raw exclusion/recovery|
|Existing widget catalog|I/P; App Group derived snapshots|P14|G16 every registered kind→producer→deep link and stale|
|Lockscreen next event + usage|I/P; snapshot/WidgetKit|P14|G16 accessory capture, locked privacy/grey dark tint|
|Morning Shortcut/Zepp step|P; App Intents actual available actions|P14|G17 honest action result, no false Zepp sync claim|
|USB signing renewal|P/U; Mac installer+Apple profile|P14|G17 in-place install retains records; expiry/trust checked|
|Windows deployment/reconnect|P/U; protected source candidate/service|P02/P17|G05/G07 ACL/reparse/identity/restart/rollback|
|Prior Claude security findings|I/P; current defenses with residual review|P03/P13/P15/P17|G19 each original finding linked to current proof|
|Storage/process discipline|I/P; owned artifacts/task lifecycle|P18|G20 free floor, incremental builds, no stale app/process|
|Advisor removal|I/P; no generic AI routes; old copy pending|P10/P15/P16|G01/G18 no advice UI, calorie-photo only|

## User-dependent items: five categories, unchanged
U1 Pick actual non-Uni vault and approve creation within its LifeOS subfolder through UI.
U2 Confirm actual device endpoint/key fingerprints during pairing.
U3 Physical unlock/permissions/USB trust/developer signing interactions.
U4 Conditional decision only if Personal Team profile rejects required capabilities; no payment presumed.
U5 Choose actual exports/renew consent only if needed; reuse existing working configuration first.
Zero additional aesthetic or architecture questions deferred to user.
These are not five currently unanswered product-design questions; they are five execution-dependent categories.
Windows return and Xcode27 host compatibility are environment gates, not invented user decisions.

## Scope gaps requiring Astra resolution, not Luna invention
CP-A Independent Astra Medium acceptance unavailable in this session.
CP-B Complete binary/wire schema and signing key rotation / complete domain bridge field bindings.
CP-C Selected SDK, member declarations and OS27 guarded modifier acceptance.
CP-D Only if adopting new Document API later; not a blocker for chosen existing vault architecture.
CP-E Actual pinned dependency/tool release hashes; no invented version.
CP-F Reference-leaf audit: expand original Bevel/Revolut/Notion features into concrete missing source steps.
Calorie photo/barcode pipeline and Clipper gaps cannot be hidden by broad P10/P16 prose: see26.
