# Apple API implementation matrix
Availability columns refer to the baseline iOS 17/macOS 14 unless a newer version is explicit.
Apple symbol links are in 12-REFERENCES.md. Implementation compiles availability against installed SDK.
E = existing integration; N = proposed symbol. Priority M required, S improvement, O optional.
|API|Exact integration point|Availability/fallback|Entitlement/privacy|Priority and reason|
|---|---|---|---|---|
|system Font / monospacedDigit|E Typography.swift LifeOSTypography.Role|baseline|none; no bundled font|M consistent compact type|
|SF Symbols / symbolEffect|E LifeOSIcon.swift; MotionKit numeric/symbol modifiers|baseline; static replacement if unsupported symbol|none|M semantic stable icons|
|RoundedRectangle continuous|E DesignTokens.swift shape helpers|baseline|none|M smooth corners|
|ContainerRelativeShape|P14 widget backgrounds|baseline; explicit rounded shape outside real container|App Group for data only|M system widget corners, not automatic universal nesting|
|Material / UnevenRoundedRectangle|P07 shared surface helpers|baseline; opaque surface for reduced transparency|none|S overlay hierarchy|
|matchedGeometryEffect|E MotionKit matchedCard; P16 shell namespace|baseline; route crossfade when ownership unavailable|none|M semantic hero continuity|
|PhaseAnimator / KeyframeAnimator|P07 finite success/error feedback|baseline; immediate final reduced-motion state|none|S bounded one-shot feedback|
|contentTransition numericText|E MotionKit numericTransition()|baseline|none|M numeric changes without layout jump|
|Canvas / GraphicsContext|P06 PlanningCanvasView; P07 LifeOSOrbRenderer|baseline|Canvas elements need separate semantic views|M bounded drawing|
|TimelineView animation paused|P07 LifeOSOrbRenderer|baseline; static frame|none|M one bounded clock|
|MagnifyGesture|E CalendarView, P06 PlanningCanvasViewport|iOS17/macOS14; native bridge if arbitration fails|none|M focal zoom|
|UIScrollView / NSScrollView bridges|E CalendarView and CalendarViews|baseline|none|M preserve existing scroll ownership|
|UIGestureRecognizerRepresentable|Not required|newer OS; use UIViewRepresentable coordinator at baseline|none|O avoid deployment bump|
|UIViewPropertyAnimator|P08 existing iOS bridge only if needed|iOS baseline; SwiftUI on Mac|none|S interruptible scrub/settle escape hatch|
|NSAnimationContext / NSViewRepresentable|P08 Mac bridge|macOS baseline|none|S focused trackpad fallback|
|NavigationStack / sheet / Menu|P16 shell; each product form|baseline; no iOS18 navigationTransition dependency|none|M native navigation/form behavior|
|sensoryFeedback|P07 helper + P11 workout save|iOS17; omit unsupported Mac haptic|none|S committed action only|
|WidgetKit containerBackground / privacySensitive|P14 widget views/publisher|baseline; renderingMode branching; newer accented modifiers guarded|App Group capability/profile validation|M wallpaper/lock privacy|
|AppIntent / AppEntity / EntityQuery|P14 LifeOSAppIntents.swift|baseline|only authorized app data; no raw sensitive Siri payload|M deterministic Shortcuts|
|ActivityKit|Deferred workout live activity|iOS16.1+ only; ordinary workout view fallback|profile/lifecycle verification|O not completion dependency|
|HealthKit anchored/observer queries|E HealthKitAdapter.changes/startObserver|iPhone only; qualified cache on Mac|HealthKit usage strings + actual grant|M incremental provenance|
|HKWorkoutBuilder|N HealthKitWorkoutExporter.exportCompleted|iOS12+; app-local save if denied|write HKWorkoutType permission|M optional export of completed app-owned workout|
|HKLiveWorkoutBuilder|Deferred|physical supported workout session only|HealthKit lifecycle permission|O no invented watch sensor stream|
|PhotosPicker|E FitnessNutritionView|baseline|selected photo access; sanitize EXIF|M calorie input|
|Vision/PDFKit/UTType|E TaxDocuments.swift and TaxDocumentsView|baseline; bounded text/manual fallback|user-selected file access|M existing import|
|VNDocumentCameraViewController|N future scanner in TaxDocumentsView|iOS13+ supported device; file picker fallback|camera explanation|O completion not dependent|
|QuickLook|P13 tax explicit preview|baseline|scoped file lease lifetime|S safe preview|
|NSFileCoordinator / NSFilePresenter|E PlanningCoordinatedAccess + N PlanningVaultObserver|baseline|user-selected scoped bookmark|M local cross-process coordination, not distributed lock|
|security-scoped bookmark|E PlanningVaultAccess.select/restore|baseline; ask reselect on stale grant|sandbox user-selected read/write, checked profile|M durable vault binding|
|BGAppRefreshTaskRequest|E LifeOSBackgroundRefresh|iOS13+; foreground/manual sync fallback|permitted task identifiers, expiration handler|M opportunistic refresh|
|URLSession async bytes|E TailscaleSyncClient + N SyncTransport|baseline|network entitlements Mac; exact HTTPS endpoints|M bounded cancellation|
|Keychain|N SyncIdentityStore|baseline; unavailable/locked means pause|device-only accessibility; no shared secrets in defaults|M device key storage|
|CryptoKit Curve25519.Signing / SHA256|N SyncWireCodec|baseline|none; private key Keychain|M standard signatures and digests|
|OSLog / signposts|P18 release metrics|baseline|privacy-sensitive interpolation default; IDs hashed|M diagnose latency without payload logs|
|Observation @Observable|Only measured hot models later|iOS17/macOS14; retain ObservableObject otherwise|none|O blanket migration rejected|
|EventKit|Existing adapter only if present; new mirroring deferred|iOS17 full/write-only permission APIs, Mac entitlement|user grant; external source authority|O avoid second calendar writer|
|Core Spotlight|Deferred project-title indexing|baseline|exclude note bodies/health/finance/tax|O not required|
|UserNotifications|Existing calendar/supplement notifications; P14 intents|baseline|explicit permission|M keep schedules local|
|FinanceKit|Do not add|entitlement/distribution constraints|not viable Personal Team German setup|Rejected; Enable Banking remains|
|CloudKit / SwiftData / Core Data rewrite|Do not add|not a fix for current integration gaps|containers/migrations conflict with constraints|Rejected|
|Metal / JS / React / Skia runtime|Do not add|no profiled need|extra memory/runtime|Rejected; native bounded drawing|
|NSUbiquitousKeyValueStore for data|Do not add|preferences only if ever needed|not a domain database|Rejected for vault/finance/health|
|NWPathMonitor|N SyncEngine connectivity trigger|baseline; connectivity does not prove service health|none|S event-triggered retry, not polling|

## Target membership details
ios/project.yml lists Shared in all four app/extension products.
HealthKit*.swift excluded from native Mac and widget Shared inclusion.
Planning included in LifeOS and LifeOSMac, not extensions.
LifeOSMac explicitly includes OverviewView, CodexView, Usage, Settings, CalendarView,
FitnessTrainingCoordinator, Modules, TaxDocumentsView and WidgetSnapshotPublisher.
Place new HealthKit exporter under Shared/HealthKitWorkoutExporter.swift so exclusions work.
Place new orchestration in ios/Sync and explicitly add to two app targets through P16.
Place pure SyncContract in Shared only because store files used by extensions reference its DTOs.
Widget extension never starts engine, listener, collector, or provider refresh.
Project generator is run only by integration owner after implementation approval, once per cohesive membership change.
