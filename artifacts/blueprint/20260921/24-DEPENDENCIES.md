# Ownership and call-graph amendments
Original14-OWNERSHIP.json retained unchanged as history and primary exact per-file allowlist.
R2-Pxx repeats it for dispatch. No packet may edit another owner's implementation file.
New helper declarations must live in an already-owned file unless explicitly added here.

## Additional ownership only if named checkpoint passes
P16: ios/Shared/LifeOSApplicationServices.swift (NEW), excluded from WidgetKit, app roots share composition.
P15: package.json (EXISTING), only if security lock update requires compatible manifest change at CP-E.
P02: services/gateway/nutrition.py (EXISTING if found, otherwise NEW only after CP-F schema seal).
P02 nutrition ownership is RESERVED, not authorization to invent provider/photo contracts.
All additional source paths need fingerprint/status confirmed at dispatch; this phase creates no source files.
P07 guarded API modifiers stay in LifeOSMotionKit.swift/LifeOSComponents.swift; no duplicate platform kit.
P06 view helpers stay in its owned files; no generic new database or document host.

## Runtime edges
LifeOSApp / LifeOSMacApp -> LifeOSApplicationServices -> one store instance per durable file.
Services -> SyncEngine(adapters:[Calendar,Finance(each store),Fitness(each store),Planning,Tax]).
SyncEngine -> SyncTransport -> exact enrolled Mac relay / Windows HTTPS origin.
SyncTransport receives signed bytes; domain adapters receive verified immutable operations.
CalendarView -> CalendarCoordinator -> CalendarStore -> durable receipt -> widget revision notification.
PlanningCanvasView -> PlanningProjectCoordinator -> PlanningCanvasSession -> PlanningVaultStorePersistence.
PlanningVaultObserver -> coordinator.invalidate -> store.read -> compare base hash -> visible update/conflict.
FinanceImportViewModel -> importer -> preview -> confirmed store mutation -> recurring/wealth projections.
FinanceCoordinator -> existing Windows TailscaleSyncClient -> immutable readback -> projections.
FitnessTrainingView -> coordinator -> FitnessTrainingStore; completed receipt -> P11 exporter.
AppIntent -> same coordinated store API -> receipt -> publisher; no independent mirror ledger.
UsageCoordinator -> allowlisted adapter -> collector/manual reader; provider metadata cannot select executable.
TaxDocumentsView -> protected store; TaxSyncAdapter -> sanitized projection only.

## Corrected scheduling
W0:P00 and CP-A/B/F contract seal (planning artifacts, no mass rebuild).
W1:P01,P02 local service,P03,P04,P05,P07 baseline; P16 membership substep; one integrated compile/batch.
W2:P06,P08,P09,P11 then P10,P12,P13,P14; interfaces handed to P16 as each becomes stable.
P10 depends on P11 interface availability, added to original dependency list; implementation may use injected stub only in tests.
P14 depends on P09/P12/P13 snapshot contracts as well as original dependencies; no fabricated producer placeholders.
W3:P16 final composition, P15 security; relay deployment only after reviewed local auth/integrity evidence.
P02 gateway integration consumes P13 DTO after its contract exists; no circular file editing.
W4:P17 Windows deployment/live data when available. W5:P18 final acceptance, W/P exclusions explicit.
P18 can run Mac/simulator portions while P17 unavailable, but release remains blocked on required Windows proof.
One Luna worker / one Apple lane. No simultaneous writes to shared files or two implementations of same interface.
