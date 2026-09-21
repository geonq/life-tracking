# R20-06 — authoritative amendments and packet dispatch

Read R20-READINESS and this sheet, then packet contractFiles in14-OWNERSHIP.json. Editor assessment only; independent acceptance pending.
This revision writes blueprint documents only. No source/test/project/dependency edits, builds, xcodegen, commits or pushes.

|conflict|R20 authority|retained contract|
|---|---|---|
|R19 restore fenceID missing, no close/release, incomplete journal|R20-01|R19 domain restore proofs/policies, all26 stores/28 host units|
|R19 8MiB unscoped restore blob, R3 store-only authorization|R20-02|17 replication stores, existing V6 branch,32MiB blob/262144 chunks|
|R19 remote proof not in journal; credential retirement loses authentication|R20-03|R18 individual deletion markers/target order; R19 receipt finalization|
|R19 undefined bootstrap authorization to signMutation|R20-04|R17 original signed authority/fence bytes and sequence-zero bootstrap order|
|R10/R11/R19 closed list drops R4 observations|R20-05|R4 inner signatures/publisher; R10 requests/R11 responses/nonces|
|R19 read maps/prompts omit these amendments|R20-06 +14 +11|203 exclusive source paths,19 packets, existing dependency DAG|

No blanket replacement of unrelated features, design, OS27, migrations or algorithms. Historical signed objects retain original codec/hash domains.
All new runtime journals/requests/control records explicitly carry20; active receipt remains V8 with required R20 fields, no default-on-decode.
Observed prior V8 shapes remain read-only until an evidence-backed migration; no automatic hash rewrite under same version.

## Closed declaration replacements

Restore Input/Prepared/Context19 ->20; DataCompletionProof19 remains exact; WorkPlan units remain19 and adds nullable restoreFencePolicy20.
Journal19 restore ->RestoreJournal20; RemotePackSource19 ->20; data manage/local dispatch requests/responses ->20.
RemoteActive/Closed owner shape20 supports restore fence state and signed controls; deletion uses R20-03 full closure.
DeletionSetup/Journal/Final/Completion19 ->20 for new operations; Snapshot deletionCompletion type is20 with historical decoder kept separate.
All PublicationPreparation19 objects add restoreSettlementHash nullable; all SnapshotV8 objects add restoreSettlementHash nullable.
Op3 terminal phases require settled hash; other ops null; complete preimages include new keys. Typed pure validators updated once in P01.
ReceiptKeyStore19 name/custody remains; bootstrap method added, ordinary sequence0 forbidden; new typed deletion completion20 signing added.
Aliases such as RestoreApplyContext20 refer to one declaration, not implicit overloads. Old active19 objects cannot be silently fed to20 methods.
R19 capacity remains except restore journal3MiB/admin staging R20 limits; prospective exact size checked before effect. ObservationAccess20 policy is R20-05 authority.
R19 publication preparation<=4096 and Snapshot<=16384 include the new hash; no cap exception or silent truncation.
R20-03 Completion20<=4096 remains within terminal65536 cap; retained summary<=8192 includes entire completion as before.

## Producer and consumer map (exact allowed files)

P01: Shared/SyncContract.swift DTOs; Sync/SyncWireCodec.swift validators/domains; Sync/SyncIdentityStore.swift bootstrap/key APIs;
Sync/SyncDomainAdapter.swift ports; Sync/SyncTransport.swift route calls; packages/contracts/src/replication.ts matching typed contracts.
P02: gateway/replication.py admin/restore/deletion proof signer and blob/observation handlers; gateway/main.py routes;
mac-relay/main.py observation handlers/response signer integration and explicit admin denial. No replication_keys.py source addition.
P03/P04/P05/P06/P12/P13/P14: existing owned store/adapter files consume RestoreApplyContext20 and persistent dataset gate; no duplicated DTOs.
P11: Shared/HealthKitAdapter.swift ObservationRelayPublisher; LifeOS/HealthKitProductionBridge.swift iOS invocation; existing workout/anchor ownership unchanged.
P15: services/api/src/server.ts owner state/control installation/collector gate; history.ts Usage atomic restore; no clipper-store.ts source edits.
P16: LifeOS/Modules/ModuleNavigation.swift startup fence recovery/foreground bootstrap; existing platform app roots compose only.
P17: existing deployment files provision gateway public pin/ACL; verify administrative data root bounds and writer exclusivity later.
P18-I: Shared/LifeOSDataManagement.swift journals/fence/control sequence; LifeOSReceiptCoordinator.swift bootstrap/receipt fields;
LifeOSDataArchiveWriter.swift verified admin bundle production. All paths above have ios/ prefix where applicable.
P18-E: later planned failure-injection/live-host/visual/device/security evidence, not implementation predecessor.

## Read-map construction and dispatch discipline

Retain all existing ordered contractFiles; add six R20 sheets last in numeric order to every packet to keep shared declarations consistent.
For P01/P02/P11 explicitly retain R4-08,R4-09,R4-15,R10-02,R11-02,R11-03 plus R20-05; all references expand to real filenames in14.
For P01/P02/P15/P18 ensure R3 blob sheets,R7-05,R8-02,R9-03,R14-02,R15-03,R19-02/04 present before R20-02.
Update contractDependencies and sharedContractConsumers; fixed-point closure over historical references terminates by visited set even with document cycles.
Execution dependencies/files/status/fingerprints must remain semantically identical to pre-R20 metadata; no new edge or renamed owned path.
A source symbol referenced from another packet uses P01's final declaration, not a copied historical type. Compile by wave, no speculative per-edit full build.
P00 reconciles source/evidence; P01 publishes interfaces; dependent packets implement; P18-I integrates; P16 composes; P18-E proves release separately.
Actual source contradiction triggers precise escalation with signature/path evidence; editor readiness alone is not permission to guess.
