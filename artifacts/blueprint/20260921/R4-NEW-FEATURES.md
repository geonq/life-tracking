# Requests added beyond the frozen258 leaves — exact ownership
Read R4-11 action logic,20 motion tokens,27 layout values and per-domain payload/archive maps.
No row below is optional unless explicitly labelled optional. Evidence column is release evidence, not a coding-design gap.
|Feature|Packet / exact files and functions|Binding behavior / evidence|
|---|---|---|
|Windows outage8+days|P01 SyncEngine.synchronizeOnce; P02 ReplicationStore.append; P03/P04/P06/P13 applyRemote|Same signed ops/heads/receipts on Mac relay; no pending expiry; two-device/reconnect/conflict proof|
|Health projection without Windows|P11 ObservationRelayPublisher.publish/readLatest; P02 R4-15 observation routes|Signed iPhone projection only, monotonically sequenced cache, no raw HK samples; Mac source/asOf preserved|
|Robinhood/net worth|P09 FinanceRobinhoodImporter.importCSV; FinanceInvestmentActivityStore.merge; FinanceNetWorthBreakdown.init|Separate holdings/cash/source time/consolidation; real export reimport/duplicate/valuation proof|
|Recurring Manage Payment|P09 FinanceRecurringPaymentsViewModel.save(row:cadence:status:anchorDate:)/resetAutomatic|Explicit weekly/monthly/yearly/paused/ignored; deterministic detector never overrides manual state|
|Institution-aware import|P09 FinanceImportViewModel.handlePickedFile/applyMapping/confirmPreparedImport|File content classification, preview/confirm; unknown mapping explicit, no made-up firm|
|NextSemis optional gate|P16 DisabledNextSemisReader.read|Returns unavailable unsupported, UI hidden; mandatory direct Robinhood path independent|
|Gym tracking/rest/report|P10 FitnessTrainingCoordinator.start/save/pause/resume/finish/historyProjection|LifeOS source record, deadline-based rest, completion survives restart; no Zepp proprietary parity claim|
|Training templates sync|P04 FitnessStrengthTemplateStore.upsert/delete/commitReplication; P10 saveTemplate|Separate existing store mapped R4-14; session template snapshots immutable|
|Zepp minimal dependency|P11 HealthKitProductionBridge.storedStates; P14 LifeOSOpenZeppForSyncIntent.perform|Zepp export source only, no fictitious command to force sync; real physical provenance proof|
|Obsidian shapes/nodes/edges/notes|P05 PlanningCanvasReducer.apply; P06 PlanningProjectCoordinator.open/commit/connectNotes|Canvas coordinates+Markdown content preserved, per-node notes via scoped read, no new DB source of notes|
|iCloud selected vault|P06 PlanningVaultAccess.select/restore; PlanningVaultStore.stage/publish|LifeOS subfolder only, file coordination/conflict recovery; actual vault selection U1|
|SF Pro/compact typography/SF Symbols|P07 Typography.swift/LifeOSIcon.swift and20 tokens; P16 OverviewView.body|Native system font, compact role sizes, no oversized metric override; rendered narrow/default/wide proof|
|High-end home/detail transition|P07 LifeOSMotion.animation; P16 OverviewView.openHome|Same route authority, interruption safe; matched geometry where available, opacity fallback, no snapshot-host jump|
|Native web-inspired motion|P07 LifeOSOrbGeometry.make/LifeOSOrbState.reduce; LifeOSMotionLifecycle.send|20 deterministic<=192particles,30fps max, one visible, static reduced/low power; no JS/CSS/Skia runtime|
|Mac Calendar pinch/scroll/now line|P08 CalendarInteractionReducer.reduce; CalendarViewportTransform.zoomAt|20 ownership/formulas, one today label, no slider; DST/trackpad/Escape proof|
|Dark tinted grey wallpaper widgets|P14 LifeOSWidgetChrome.RoleModifier.body; each widget view.body in F04|Contrast independent of wallpaper, SF font, source/privacy states; actual locked/tinted physical screenshots|
|Lock Screen event + usage|P14 NextEventWidgetView.body; LifeOSUsageAccessoryCircularView.body|Existing rectangular event/circular usage kinds; no duplicate registrations; physical lock evidence|
|Extra existing Health/Recovery widgets|P14 HealthMonitorWidgetView.body/RecoveryRingWidgetView.body|Keep both registrations in addition to258 reference mapping; committed source and correct nil/stale|
|Gemini Pro/retain Claude/extensible Usage|P12 UsageProviderCatalog.descriptor; UsageCoordinator.saveUsageManualReading/updateUsageRegistryPreferences|Exact existing product IDs; manual subscription versus API distinct; add/hide/pin/order no executable config|
|Calorie-photo-only AI|P10 FitnessNutritionView.sendPhotosForAnalysis/confirmPhotoProposal; P02 GoogleFoodPhotoProposalClient.generate|Existing authorized provider, no advice/coach; proposals excluded until confirmed; retention/corpus proof|
|Morning Shortcut/USB renewal|P14 three existing AppIntent.perform functions; installer verify_signed_bundle/run_bounded|Truthful action reports, in-place installation retains data; physical trust/profile evidence required|
|Security findings|P15 R4-13 exact function table; P01 WireScanner/SyncTrustStore|Batched Astra negative-case review before release; no claim of penetration proof from plan|
|Storage/SSD/process discipline|P18 free_bytes/assert_builds_are_idle/safe_remove_directory/run_lane/cleanup_simulator|>=15GiB floor/20target, serial owned processes, stable caches; no perpetual write/delete loop|
|Live data/no demo|P16 LifeOSApplicationServices.start; OverviewView.body; current provider coordinators.refresh|Production mode never loads fixture; cache/source-unavailable distinct, existing bank consent reused|
|Advisor/coaching removal|P10/P16 existing route/body ownership; P15 deep-link/source audit|No generic AI destination/call; retain factual explanations and nutrition photo only|
|macOS27/iOS27|P07 PlatformVisualAdapter.route/cardRadius; P16 project.yml|17/14 baseline fallback, optional SDK27 file guard, no unverified Mac zoom API|
|Git/coordination completeness|P00 ledger reconciliation; P18 release-matrix generation|Later execution publishes accepted changes per prior authorization; current task explicitly no commit/push|
