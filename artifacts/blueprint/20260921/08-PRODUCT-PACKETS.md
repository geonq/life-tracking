# Product implementation packets
Read 03-DESIGN and 04-SCREENS alongside exact allowlists in 14-OWNERSHIP.json.
Each packet owns both functional and visual completion of its screens; no later duplicate redesign packet.
Run one compile/typecheck at integrated wave boundary, then batched behavior/captures.

## P07 — shared visual foundation
Use existing LifeOSTypography.Role values; audit consumers instead of reducing system-wide readability.
Extend LifeOSMotion.Timing with route/panel/numeric/success/error and resolve hero alias to .46/.88 spring.
LifeOSMotionLifecycle.send remains the settlement-generation authority; add only necessary visibility hooks.
LifeOSOrbState.reduce(event), LifeOSOrbGeometry.make(kind,size), LifeOSOrbRenderer.frame(time) are new.
Renderer owns TimelineView/Canvas only; app operation controls generation/status.
LifeOSComponents supplies compact card/header/status/form primitives with semantic surfaces.
LifeOSIcon maps existing navigation semantics to consistently sized SF Symbols; reject arbitrary icon packs.
Delete superseded local token duplicates after all known call sites resolve through aliases.
Acceptance: interrupted hero settles; no stale callback; static reduced/low-power orb;
one meaningful status label; repeated view redraw neither restarts orb nor allocates new particle geometry.

## P08 — Calendar
Repair CalendarView/CalendarViews platform bridge ownership, retain existing recurrence editing UI.
Add CalendarViewportTransform.timeAt(y)/offsetFor(time)/zoomAt(focalY,scale) in CalendarLayout.
Pin now-line to today column only; gutter owns time label; clamp 24h scroll bounds.
Use visible-range event layout; overlap sweep O(n log n), bounded day cache keyed day+revision.
Input updates O(1) transforms; auto-scroll single cancellable owner; no onChange persistence loop.
Remove slider zoom presentation; retain keyboard controls in command menu.
Rename icon-picker “Chat” to “Message” (this is copy, not AI feature removal).
Acceptance: Mac pinch/wheel coexist; phone scroll/paging/create coexist; one now-label;
rapid pinch reversal, drag-to-edge cancel, overlap and recurrence exceptions work.

## P09 — Finance
FinanceRecurringObservation.fromImported/fromReadback normalizes reviewed evidence without fabricating import provenance.
FinanceRecurringPaymentDetector.makeInput/detect accepts normalized stream through an additive API;
retain compatibility wrapper for current imports. Store interface belongs P03.
FinanceCoordinator.refresh captures snapshot generation; build recurring input once per accepted revision.
FinanceWealthProjector.project handles timestamped account/holding coverage with Decimal/integer money.
FinanceRobinhoodImporter must require complete snapshot for authoritative holdings, never infer opening holdings.
Complete existing importer mapping/dedup/corrections; no hardcoded user account names beyond source identifiers.
FinanceView/Analytics/ChartMode/Recurring/Import views apply 04 layouts; native sheets and single toolbar.
enablebanking.py retains existing credentials/config; implement only demonstrated pagination/retry/refresh gaps.
No new bank onboarding if valid configuration already exists. No mutation of live bank transactions.
Acceptance: real CSV preview→confirm→reimport→correction, no duplicate totals;
manual recurring survives live refresh; source/currency valuation trace; stale snapshot remains visible.
Local sanitized recorded data verifies behavior; actual live account/consent proof waits Windows.
New NextSemis adapter is explicitly not dispatched.

## P10 — Fitness/Nutrition UI
FitnessTrainingCoordinator uses store receipt and HealthKit exporter injected interface (P11/P16 composition).
Complete templates/sets/load/rest/history/reports using existing domain, not new training storage.
Rest timer uses absolute end instant and one visible timeline, no per-second persisted counter.
FitnessView and detail surfaces use shared compact header/status, no duplicate unavailable text.
Rename displayed Coaching to Observations; do not generate advice.
Keep legacy coding key “coaching” if persisted compatibility requires it; expose factual domain alias,
then remove unused view helper after call sites move. Do not erase source data in a cosmetic cleanup.
Nutrition manual form one Save; proposal/edit drafts not in totals; failure preserves user input.
Lifestyle/supplement/strength/biology features preserved and mapped in inventory, not silently removed.
Acceptance: full local workout→report→edit; meal save once; rest survives background;
source facts distinguished from unsupported values; compact Mac and phone forms.

## P11 — HealthKit
Add HealthKitWorkoutExporter.exportCompleted(session) with idempotent lineage/query-before-retry.
Add HealthKitWorkoutReconciler.match(session,candidates) returning exact/ambiguous/unavailable.
Extend existing adapter writes only with explicit workout permission; no automatic permission prompt at launch.
Anchor persistence remains recoverable; deleting source observation updates linked report provenance, not user-entered sets.
Main app HealthKitProductionBridge injects exporter/reconciler; Mac compile excludes HealthKit files.
Acceptance locally: pure matching cases, duplicate export prevention, source deletion, unit validation.
Physical-only: grant/deny, saved HKWorkout, Zepp export comparison and background delivery.
Unavailable Zepp proprietary metrics are explicitly excluded from accuracy promises, not faked.

## P12 — Usage
Extend existing UsageCapability/AuthKind/RegistryAdapter with bounded adapter descriptors.
UsageCoordinator.refresh routes only allowlisted implementations; manual products have no pretend refresh action.
Persist pin/hide/order and manual window readings; distinguish subscription/API/project credentials.
CodexView/UsageRegistryDetailView replace giant ring with compact meter/reset/chart layout.
UsageProjectionChart retains actual/green-estimate/neutral-target distinction and real range coverage.
Secrets remain at collector; no generic shell command from a provider identifier.
Acceptance: unknown provider manual metadata only; stale Gemini entry explicit;
Codex automatic and Claude available; window/reset/timezone changes don't mix records;
no manufactured usage history, quota or banked resets.

## P13 — Tax
Split persisted protected raw extraction cache from TaxDocument publication DTO.
TaxDocumentStore.save migrates atomically with verified backup; export sanitized extracted fields only.
TaxSyncAdapter rejects pages, original PDFs and raw identifier fields at encode boundary.
Local QuickLook opened only by explicit action with scoped lease; arbitrary external URL not auto-opened.
Retention controller purges eligible OCR cache only, never original PDF or pending review/conflict.
TaxDocumentsView uses list/detail with one export action and concise retention status.
Acceptance: legacy migration/restart; identifier masking everywhere; formula injection; malformed large PDF;
raw text cannot enter sync DTO/log/widget; user deletion cannot resurrect after reconnect.
