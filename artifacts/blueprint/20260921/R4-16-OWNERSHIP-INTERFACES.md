# Definitive interfaces, file ownership and screen-state types
R4 supersedes all CP-* design placeholders in R2/R3. Existing files retained, additions below assigned single owner.
No source changes in planning. During later coding, build source names exactly; do not invent packet-local duplicate DTOs.

## P01 wire/interface additions (exact allowlist)
ios/Shared/SyncContract.swift; ios/Sync/SyncWireCodec.swift; ios/Sync/SyncIdentityStore.swift;
ios/Sync/SyncTrustStore.swift; ios/Sync/SyncTransport.swift; ios/Sync/SyncEngine.swift;
ios/Sync/SyncDomainAdapter.swift; ios/Sync/DomainWireValues.swift; packages/contracts/src/replication.ts.
SyncSignedKind:String,Sendable cases operation,acknowledgement,membership,frame,checkpoint,observation.
SyncKeyRole:String,Codable,Sendable app/relay/owner. SyncStoreKind exact17 cases R4-15.
All R3 named DTOs+R4 shared types go SyncContract.swift, Wire4 values DomainWireValues.swift; no same-named R2 variants emitted.
SyncEndpoint keeps id:UUID/url:URL only; trust record supplies pinned key/epoch by endpoint.id (one authority).

## Per-domain actor constructor dependencies
CalendarSyncAdapter.init(store:CalendarStore,storeID:String,trust:SyncTrustStore);
FinanceSyncAdapter.init(kind:SyncStoreKind,store:any FinanceReplicationStore,storeID:String,trust:SyncTrustStore);
FitnessSyncAdapter.init(kind:SyncStoreKind,store:any FitnessReplicationStore,storeID:String,trust:SyncTrustStore);
PlanningSyncAdapter.init(store:PlanningVaultStore,storeID:String,trust:SyncTrustStore);
TaxSyncAdapter.init(store:TaxDocumentStore,storeID:String,trust:SyncTrustStore).
Protocol FinanceReplicationStore:Sendable and FitnessReplicationStore:Sendable each declares
func commitReplication(_ payload:<FinancePayload or FitnessPayload>,operation:SyncOperation?)async throws->SyncCommitReceipt.
This bracket is two explicitly separate protocol signatures with those exact respective types, not a runtime generic.
Existing actors retain their isolation. FitnessJournalStore and FitnessStrengthTemplateStore become explicitly @MainActor;
their globally isolated class references satisfy Sendable, and adapters await commitReplication on MainActor.
Retain their existing bounded synchronous persistence transaction on that actor; no new actor-owned parallel file/store.
P04 updates initialization and command callers to MainActor; no Task.detached or @unchecked Sendable bridge.
Private synchronous locked reducer executes after await acquisition; no await inside data/receipt commit block.
FitnessJournalRecord explicitly add checked Sendable conformance (all existing stored members value/Sendable types), no unchecked extension.
Store constructors receive immutable current membership IDs/epoch via trust snapshot; unsigned op with stale epoch retained blocked,
never sent. Graceful rotation freezes allocations before switching trust; emergency recovery R4-10.

## Domain file ownership
P03 adds ios/Sync/CalendarSyncAdapter.swift,FinanceSyncAdapter.swift,CalendarPayloadCodec.swift,FinancePayloadCodec.swift;
existing CalendarStore/CalendarDomain/CalendarCoordinator and six Finance*Store files R3-04 only for scoped migration/commit.
P04 adds ios/Sync/FitnessSyncAdapter.swift,FitnessPayloadCodec.swift; existing training/meal/goal/supplement/journal/lifestyle/barcode
store files R3-04, plus FitnessStrengthDomain.swift store/Sendable/conversion section R4-14.
P06 adds ios/Sync/PlanningSyncAdapter.swift,PlanningPayloadCodec.swift; existing PlanningVaultStore/PlanningMutationJournal/
PlanningFilesystemPublication changes only R4-06. Graph/index/session files remain P05, UI R2-P06.
P13 adds ios/Sync/TaxSyncAdapter.swift,TaxPublicationCodec.swift; existing TaxDocuments.swift exposes internal sanitized helper
needed by codec (change private TaxPrivacy→internal ONLY within app shared module), no raw export interface.
P02 services/gateway/replication.py,replication_keys.py,main.py; services/mac-relay/main.py/install.sh/README.md;
P02 adds ios/Sync/SignerCLI.swift implementation; P16 alone project.yml target membership. Mac install uses fixed paths R4-09.
P11 adds ios/Sync/ObservationRelayPublisher.swift, existing LifeOSApp observation builder/client hooks coordinated through P16.
P16 adds ios/Shared/ReleaseCapabilities.swift,ios/LifeOS/LifeOSApplicationServices.swift; app roots coordinate source publication.
P07 adds baseline ios/Shared/PlatformVisualAdapter.swift and LifeOSOrb.swift; optional27 source not required for baseline.
No source .py/.swift/.ts file is written by current planning task; these are future ownership paths only.

## Exact Calendar transient state (P08 CalendarView.swift)
CalendarInteractionPhase:String,Sendable idle/paging/moving/resizing/magnifying.
CalendarGestureTarget:Sendable {let id:String?;let edge:Bool}; nil means viewport, UUID text if item.
CalendarInteractionState:Sendable {var phase:CalendarInteractionPhase;var itemID:String?;var baseHead:String?;
var original:DateInterval?;var preview:DateInterval?;var pointerOrigin:CGPoint;var dayInterval:DateInterval;
var hourHeight:Double;var scrollOffset:Double}. All transient; initial idle/nil/nil/nil/nil/zero/selected-day/64/0.
CalendarInteractionEvent:Sendable cases begin(target:CalendarGestureTarget,pointer:CGPoint,scale:Double,time:Date),
update(pointer:CGPoint,scale:Double,time:Date),end(pointer:CGPoint,scale:Double,time:Date),cancel.
Reducer ignores update/end when idle, duplicatebegin cancels prior preview then captures new; nonfinite invalidInput;
cancel restores original and idle. End returns final preview+idle, caller commits once using captured baseHead.
MainActor retains captured command before resetting state; cannot commit twice from animation callback.

## Exact remaining operational functions
Storage uses maintain_macos_storage.sh free_bytes/assert_builds_are_idle/plan_derived_data/safe_remove_directory existing,
release lanes run_lane/cleanup_simulator. No new perpetual cleanup daemon/source-wide deletion behavior.
Installer run_bounded/verify_signed_bundle/cleanup and checks.connected_iphone_udids existing; UDID args fixed by user setup.
Astra wave reviewer checks actual code/evidence at function bindings, not abstract row count; no new architecture is delegated to Luna.

## Revision5 ownership amendment
R5-02 owns durable sync-engine methods, R5-03 owns deletion and Calendar gesture values, R5-04 owns recovery trust
records, and R5-05 owns throwing bank readback. R5-01 is the authoritative audit for every leaf function cell.

## Revision6 supersession
R6-07 is the final symbol index and false-owner audit. R6-01 owns the local Usage/read-only Clipper boundary; R6-02 owns
travel/data management; R6-04/05 own recovery verification/import; R6-06 owns Calendar interaction and commit.
