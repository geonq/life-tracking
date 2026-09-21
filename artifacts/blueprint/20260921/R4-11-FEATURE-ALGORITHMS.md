# Exact screen actions and algorithms (inherit20/27 design values)
All existing symbols remain in their existing files; additions below explicitly marked NEW. No generic feature dispatcher/store.
R4-LEAVES files bind ALL258 requirements to these existing/proposed functions, packet ownership and actual evidence needs.
Astra wave review is required on resulting diff/evidence; absent current evidence is not an undefined architecture choice.

## Home/composition P16
OverviewView.body/supportingDashboard/openHome(_:) in ios/LifeOS/OverviewView.swift remain route owners.
Tap tile→openHome destination, preserve selected provider/domain snapshot, animate20 route token; never push duplicate detail.
LifeOSApplicationServices.start(): recover each store independently→publish accepted snapshots→start one SyncEngine task→provider refresh.
stop(): cancel generation-owned refresh/sync/observers; await child completion; don't terminate unrelated app/test processes.
refresh(reason:): coalesce same in-flight request, capture generation, apply result only same generation; finally clear task slot.
@MainActor service exposes existing CalendarCoordinator/FinanceCoordinator/FitnessTrainingCoordinator/UsageCoordinator/ClipperCoordinator;
private adapter references; one service instance per process shared by scenes. No runtime dictionary of arbitrary store classes.
Overview unreadable source shows one status+setup action, not repeated paragraph/no-data chart/giant empty hero.

## Calendar P08 (ios/LifeOS/CalendarView.swift)
CalendarView.body/quickCreate/quickCreationDate retained; create explicit button/pointer action, default selected day12:00–12:30.
NEW CalendarViewportTransform.timeAt(y:)/offsetFor(time:)/zoomAt(focalY:scale:) exactly20; add in CalendarView.swift.
NEW CalendarInteractionReducer.reduce(state:CalendarInteractionState,event:CalendarInteractionEvent)throws->CalendarInteractionState
in CalendarView.swift: state owns phase idle/paging/moving/resizing/magnifying, captured itemID/baseHead, original interval,
preview interval, pointerOrigin, dayInterval, hourHeight, scrollOffset; all geometry finite; no store reference.
Events begin/update/end/cancel have pointer CGPoint, scale Double, timestamp Date; begin additionally target(id:String?,edge:Bool).
Owner arbitration editing>resize>move>pinch>vertical scroll/page;8pt direction lock and20 formulas; one owner to end.
Drag/resize snaps to5min elapsed-time increment; min5min duration, preserve timezone; one CalendarCoordinator.save on end.
Cancel/Escape restores preview/no save; stale remote edit after begin returns staleBase and conflict action, never overwrites.
Now overlay only today, one gutter label; timer one per visible calendar, update minute boundary; no per-cell timers.
Overlap layout: sort by(start,end,id), sweep active end min-heap, reuse smallest free column, max concurrency width;
O(n log n), stable tie ID, no pairwise overlap scan. Day/Week/Month/Timeline/Agenda preserve selected day/filter/scroll key.
Sidebar/inspector bind existing selection state; save via coordinator, keep focus on validation failure.

## Finance P09
FinanceView.body and FinanceAnalyticsView.body own charts; data from FinanceCoordinator.refresh/apply, never view network.
FinanceStatementImporter.parseCSV(data:)/inspectCSV/prepareKnownImport/prepareMappedImport select content fingerprint;
FinanceImportedTransactionStore.commitPreparedImport applies confirmed preview; unknown schema routes explicit mapping controls.
FinanceRecurringPaymentDetector.detect/normalizedMerchantKey/nextExpectedDate retain existing deterministic detector.
FinanceRecurringPaymentsView.body + FinanceRecurringPaymentManageSheet.body call store.saveOverride/clearOverride through existing coordinator;
weekly/monthly/yearly/ignored/paused explicit; detection never replaces override; nextExpectedDate uses source timezone and calendar arithmetic.
FinanceRobinhoodImporter.importCSV→investmentStore.merge; FinanceNetWorthBreakdown.init(bankCash:investmentSnapshots:activities:asOf:maximumObservationAge:)
retains latest verified observations and consolidation exclusions; no own net-worth summation in View.body.
FinanceBudgetStore.setBudget/remove; FinanceAllocationStore.create/update/remove; trackingStore.commitDraft exactly R4-04.
Chart mode/range/series/provider are single source of selection state. Sort series once per revision, binary nearest-x scrub,
reuse selection for keyboard previous/next; no per-frame parse/aggregate. Overflow money wraps or scales only within20 role range.

## Fitness/Health/Nutrition P10/P11
FitnessView.body/FitnessStressDetailView.body/FitnessStrengthDetailView.body/FitnessBiologyDetailSurface.body own existing drilldowns.
NEW FitnessDetailSelection.select(day:Date,calendar:Calendar)->Date = startOfDay; range(token:String,ending:Date,calendar:Calendar)throws->DateInterval
in FitnessCoreDetailDomain.swift; tokens day/week/month/6months/year, calendar date addition preserving DST; unknown invalidInput.
All metric trend cards use actual independent source availability/window; don't copy one metric into another or infer proprietary Zepp score.
Range/day/tag control updates selection once; facts and chart read same bounded projection. Baseline/calibrating stays factual data state.
FitnessTrainingCoordinator.start/save/pause/resume/finish/discard/delete/saveTemplate/deleteTemplate remain exact command owners.
Set editing changes draft only until Save; rest deadline=stored Date, remaining=max(0,deadline-now), never persisted each tick.
Training view report uses historyProjection, reconciles importedRecordKey only exact verified source identity; no fuzzy silent link.
HealthKitFitnessRepository.refresh uses existing bounded source filter, HealthKitProductionBridge.requestReadAuthorization/storedStates/
startObservers/stopAllObservers; anchored deletions preserved; read permission denial cannot be distinguished from no readable data.
FitnessJournalStore.upsert/delete/setTagState and FitnessLifestyleLedger.addQuantity/correct/delete own manual input; no causal diagnosis.
SupplementNotificationDelegate existing willPresent/didReceive→SupplementStore receipt transaction before completion handler;
Taken decrements once; Skip/Snooze preserve stock; denied notification is not skipped/missed inferred from no OS callback.
FitnessNutritionView.saveMealDurably/confirmBarcodeProposal/saveBarcodeRecord/confirmPhotoProposal/sendPhotosForAnalysis retained;
one primary Save, validation inline, proposal cancellation drops late result, confirmed meal ledger only totals per R4-05.
No conversational advisor/coaching route; source explanations remain static evidence text. Photo pipeline reuses configured client only.

## Revision5 binding corrections
R5-01 is the binding authority for RF/BF/DT/NU/PC/DA/CA/ST rows. It replaces broad view/refresh/storage helper names
with the actual typed store commands and source projections; all 258 leaf IDs remain unchanged.

## Usage P12
UsageCoordinator.refresh/cancel/saveUsageManualReading/updateUsageRegistryPreferences retained; no changed overload required.
UsageView.body, UsageProjectionChart, UsageFactsView.body, UsageConnectionsView.body consume same selected provider/window.
UsageRegistryAdapter.fromLegacy/legacyMapping preserve current provider IDs; manual Gemini consumer product separate from AIStudioAPI.
Use EXISTING UsageProviderCatalog.descriptor(for:UsageProviderID)->UsageProviderDescriptor?; do not add duplicate UsageAdapterDescriptor.
Current exact mapping: codex→codex_cli/.localCLI/.officialQuota; claude→claude_statusline/.collectorSecret/.officialQuota;
gemini_subscription→gemini_subscription_manual/.none/.manualEntry; gemini_api→gemini_api_meter/.apiKey/.localMetering+.manualEntry;
glm→glm_manual,deepseek→deepseek_manual,google_ai_studio→google_ai_studio_legacy (.apiKey/.manualEntry).
NEW UsageConnectionActions.canRefresh(_ descriptor:UsageProviderDescriptor)->Bool returns true only adapterID codex_cli/claude_statusline;
unknown provider false, manual editor only. Existing reviewed catalog is authority; do not extend enum cases or rename persisted IDs.
Manual entry/reset at source timezone; stale after window reset; never turn token activity into remaining quota/banked resets.
Provider hide/pin/order preferences local; Claude preserved; no credentials in model descriptor.

## Planning/Tax/widgets/automation
PlanningCanvasReducer.apply + PlanningCanvasSession.commitInteraction/commitInspectorEdit/undo/redo/retryPending retained.
PlanningCanvasViewport functions20: focal invariant, viewport cull, pointer ownership; no per-frame rebuild/write;
PlanningProjectCoordinator.open/commit/connectNotes→existing scoped read/stage/publish R4-06; note click opens bounded editor.
TaxDocumentStore.load/save/delete and TaxCSVExporter.escape exact R4-07; server never receives raw record Codable.
WidgetSnapshotPublisher.publish→mapFinance/mapFitness/mapFitnessWidgets/mapNutrition after commit; preserve all existing kinds.
Every widget URL uses LifeOSDeepLink.init(url:) as sole decoder; invalid/deleted entity navigates owning module safely.
LifeOSMorningStatusIntent.perform/LifeOSOpenZeppForSyncIntent.perform/LifeOSUSBRefreshStatusIntent.perform remain truthful outcomes.
install_personal_device.sh verify_signed_bundle/run_bounded/cleanup and installer checks.connected_iphone_udids are exact renewal path;
no uninstall, fixed bundle/team/UDID; no automated Apple trust dismissal; permission errors are named release setup states.

## Revision6 supersession
R6-07 is the final leaf noun/verb audit; R6-06 is the final Calendar interaction/commit path; R6-01 keeps Usage and
Clipper outside replication. Existing rendering algorithms remain subordinate to those ownership corrections.
