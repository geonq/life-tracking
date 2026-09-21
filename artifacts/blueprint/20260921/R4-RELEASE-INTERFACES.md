# Compile-safe device/provider interfaces and explicit release gates
P16 adds ios/Shared/ReleaseCapabilities.swift; P17 binds real configuration; no paid purchase or physical UI automation inferred.
```swift
public enum CapabilityBlocker:String,Codable,Sendable {
 case unsupported,missingConfiguration,permissionRequired,locked,notDownloaded,serverOffline,upstreamRejected
}
public enum CapabilityResult<Value:Sendable>:Sendable {case available(Value),unavailable(CapabilityBlocker)}
public protocol BankReadbackProvider:Sendable {func readback()async throws->FinanceReadbackResult}
public protocol VaultAccessProvider:Sendable {func restore()async->CapabilityResult<PlanningVaultAccessSnapshot>}
public protocol NextSemisReader:Sendable {func read()async->CapabilityResult<[FinanceInvestmentAccountSnapshot]>}
public struct DisabledNextSemisReader:NextSemisReader { public func read()async->CapabilityResult<[FinanceInvestmentAccountSnapshot]> }
```
DisabledNextSemisReader.read always unavailable(.unsupported); UI optional integration hidden, Robinhood local import remains complete.
Bank adapter invokes existing TailscaleSyncClient.fetchFinanceReadback; R5-05 maps missing configuration, offline,
authorization, expiry, stale, malformed and server failures to its closed throwing taxonomy. Cancellation throws
`.cancelled` and preserves the accepted cache; it never becomes an empty successful readback.

## Revision5 bank contract
R5-05 supersedes the nonthrowing declaration above. BankReadbackProvider.readback() async throws -> FinanceReadbackResult
uses BankReadbackError; FinanceCoordinator preserves its last snapshot on failure and propagates cancellation.
Vault adapter calls existing PlanningVaultStore.restore; selection absent permissionRequired, cloud file missing notDownloaded;
never create/fill empty personal vault automatically. UI gives exact action to select actual non-Uni vault/LifeOS subfolder.
NEW LifeOSRuntimeConfiguration:Sendable {let endpoints:[SyncEndpoint];let vaultSelected:Bool;let mode:LifeOSRunMode};
SyncEndpoint:Sendable {let id:UUID;let url:URL}; LifeOSRunMode enum production/visualFixture, fixture allowed debug-only.
URL must exact enrolled HTTPS origin, no query/userinfo/path; production missing endpoint allowed offline local mode, not fake success.
No credentials in runtime config; key actor owns all secret access.

## Required user/device evidence, no unresolved implementation decision
U1 user selects existing non-Uni iCloud vault. Until selection, graph demos forbidden normal UI; Create/Select action with unavailable state.
U2 user confirms owner/device fingerprints, server/relay endpoint and signed membership. Until then no network data exchange.
U3 physical iPhone unlock/HealthKit consent/USB trust/Personal Team signing prompts. Until then manual workouts/mac baseline work,
health source unavailable, install action requires permission. Never fake App Group or signed physical entitlement success.
U4 Personal Team capability availability: same code compiles with HealthKit/App Group production adapters gated by runtime capability;
if provisioned capability absent, return unsupported; no $100 membership purchase. User decides later only if required capability impossible.
U5 actual bank exports/consent/source comparison when needed; reuse existing configured connection first. No creating fake live accounts.
W Windows return: gateway adapter interface compiles and local pending survives8+days; real DPAPI/service-SID ACL proof when server returns.
X SDK27 availability: baseline iOS17/macOS14 compiles, optional source excluded until configured SDK; no implicit deployment-target raise.
These are RELEASE evidence gates. They do not leave function/error/codec/ownership decisions to Luna.

## Health export to Mac (read-only, separate from user edit operations)
P11 uses existing HealthKitFitnessProjection to create existing FitnessSnapshot through current HealthKitFitnessComposition;
P16 persists that accepted source-backed projection through existing fitness snapshot path; never transmit raw samples/anchor/store.
Existing LifeOSApp.publishFitnessObservation()→TailscaleSyncClient.publishFitnessObservation(FitnessObservationEnvelope);
Mac TailscaleSyncClient.fetchFitnessObservation()→FitnessObservationEnvelope.decode. Preserve current GET/POST fitness/observation contract.
Envelope current1/max128KiB,32metrics/31days/8values per day/64workouts,15minute stale threshold; existing validators retained.
P16 surfaces publish error as source-sync status instead of try? suppression; accepted local source snapshot retained.
For Windows outage the exact signed cache relay is R4-15 ObservationRelayPublisher, still not editable health authority.
Pipeline disabled until physical read permission/source proof; returns permissionRequired/unsupported rather than invented readiness.
Workout LifeOS records remain fully editable offline; imported HK session match uses exact importedRecordKey identity, no guessing.

## Renewal/Shortcuts
Existing Morning/OpenZepp/USB intents return current report; open Zepp is not proof it exported HealthKit.
Installer fixed UDID/bundle/team, profile expiration from actual provisioning profile, use existing verify_signed_bundle/run_bounded.
No promise of silent background reinstall or seven-week license. Failed install leaves existing app/data intact.

## Final evidence acceptance
Astra Medium independent review of W1/W2/W3 diffs mandatory before source acceptance; record actual worker provenance.
No callable Astra worker in this planning session; READY means implementation contract, not already reviewed code/security green light.
Review failure returns precise affected function to controller; worker cannot improvise cross-packet architecture to hide it.
Mac normal-launch/visual/security final suite plus device/server gates remain required before product release.

## Revision6 supersession
R6-07 supplies the concrete bank client/disabled-provider signatures, while R6-02 supplies local travel and data
management receipts. Their unavailable and interruption behavior is compile-safe and remains evidence-gated.
