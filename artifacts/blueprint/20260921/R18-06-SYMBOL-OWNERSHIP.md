# R18-06 — exact relocation into the existing203-path allowlist

> R19-07-DISPATCH.md supersedes the six topics under review; use R19 active-schema and capacity rules. This R18 sheet is retained only where expressly compatible.

Supersedes R4-09/R4-12/R4-16/R4-RELEASE-INTERFACES,24 and R2-P16 NEW FILE instructions for symbols below.
No path is added/removed/reassigned. A symbol relocation changes declarations within its existing owner, not ownership of a file.
P16 remains sole editor of ios/project.yml and app composition. Keep target membership explicit, no new directory globs.

|obsolete proposed source|declaration's ONLY allowed source|packet|
|---|---|---|
|ios/Sync/SignerCLI.swift|ios/Sync/SyncIdentityStore.swift|P01|
|ios/Shared/PlatformVisualAdapter.swift|ios/Shared/LifeOSMotionKit.swift|P07|
|ios/Shared/PlatformVisualAdapter27.swift|ios/Shared/LifeOSMotionKit.swift guarded section|P07|
|ios/Shared/ReleaseCapabilities.swift|ios/Shared/TailscaleSyncClient.swift (core capability types); domain protocols below|P16|
|ios/Shared/LifeOSApplicationServices.swift|ios/LifeOS/Modules/ModuleNavigation.swift|P16|
|ios/LifeOS/LifeOSApplicationServices.swift|ios/LifeOS/Modules/ModuleNavigation.swift|P16|

No empty compatibility files/type duplicates. Swift app targets share declarations within their module; do not `import` a Swift filename.

## Signer source and target

P01 puts `SignerCLI` and its exact R4-09 request/reply/verifyBatch contracts after SyncIdentityStore declarations.
Wrap CLI imports, enum and `@main struct LifeOSSyncSignerMain` in `#if os(macOS) && LIFEOS_SYNC_SIGNER`.
`LifeOSSyncSignerMain.main() async` invokes `SignerCLI.run()` once; stderr sanitized errors, stdout framed reply only.
Shared identity/key types stay outside guard for app use. No app @main or SwiftUI imported into signer compile branch.
P16 target LifeOSSyncSigner: macOS command-line tool, minimum14; define LIFEOS_SYNC_SIGNER for THIS TARGET ONLY.
Exact project-relative source list: Sync/SyncIdentityStore.swift,Sync/SyncWireCodec.swift,Shared/SyncContract.swift,Sync/DomainWireValues.swift.
Link Foundation,Security,CryptoKit; no UIKit,SwiftUI,HealthKit,WidgetKit, app roots or receipt implementations.
P01 keeps those four files pure model/codec/key declarations: no concrete domain-store/view dependencies; inject ports instead.
App targets compile these files without flag. No @main CLI symbol is emitted in app/widget test modules.
P02 implements Python bridge/install at its existing allowed files, consumes signer ABI; it must not edit native signer source.
P16 records code-signing/absolute-install identity; R4-09 custody/security semantics unchanged.

## Platform visual adapter

P07 declares `enum PlatformVisualAdapter` in LifeOSMotionKit.swift, with R4-12 route(reduceMotion:) and cardRadius(outer:inset:).
Use SwiftUI import once; platform-specific APIs behind #if os(iOS)/os(macOS) and runtime #available checks.
SDK27-only declarations additionally behind `#if LIFEOS_SDK27`; P16 sets flag only for configured verified SDK27 builds.
Do not create PlatformVisualAdapter27.swift; its proposed functionality is a guarded section in same allowed file.
App/widget style targets may include this file only if it imports no app services/store/key/network owners.
OS27 visual availability, native fallback, SF Pro/SF Symbols, reduced-motion and explicit visual evidence remain17/20/27 authority.

## Capability declaration split without circular source dependency

P16 TailscaleSyncClient.swift: CapabilityBlocker,CapabilityResult,LifeOSRuntimeConfiguration,SyncEndpoint,LifeOSRunMode.
R4-RELEASE-INTERFACES spells shapes; these are app-level types, excluded from widgets/signer.
P09 FinanceReadback.swift: BankReadbackError,BankReadbackUnavailable,BankReadbackProvider,BankReadbackTransport,
BankReadbackClient,DisabledBankReadbackProvider; use R5-05 throwing semantics and R6-07 concrete initializers.
P16 adds `extension TailscaleSyncClient: BankReadbackTransport` in TailscaleSyncClient.swift; retain existing fetch method without duplicate implementation.
P09 FinanceWealthProjection.swift: NextSemisReader,DisabledNextSemisReader with existing declared protocol shape.
P06 PlanningVaultAccess.swift: VaultAccessProvider, with existing restore signature and PlanningVaultAccessSnapshot.
These protocols reference the shared capability declarations at app compilation; no source ownership or packet dependency edge implied by type reference.
Membership wiring may occur before wave compilation, but P16 integrated composition executes only after its existing DAG dependencies.
No separate ReleaseCapabilities TYPE is mandated; the obsolete filename grouped these declarations. Do not invent a new runtime class.

## Single application-services owner

P16 puts `@MainActor final class LifeOSApplicationServices: ObservableObject` in ModuleNavigation.swift.
Imports Foundation,SwiftUI (Combine via SwiftUI or explicit Combine if needed); no unconditional UIKit/AppKit crossing platforms.
Exact retained public API: `start() async`, `stop() async`, `refresh(reason: SyncReason) async` plus constructor injection from retained composition contract.
One instance per app process at LifeOSApp/LifeOSMacApp roots, shared across scenes; no per-screen store construction.
Store recovery→accepted projections→one sync task→refresh; generation cancellation semantics R4-11 unchanged.
ModuleNavigation.swift already belongs to both app source sets (LifeOS directory / Mac LifeOS/Modules). Do not also list it explicitly twice.
Exclude it from widgets/signer; widgets consume snapshots only. HealthKit instance construction remains #if os(iOS) in app composition.
LifeOSMacApp and LifeOSApp use same type name, no copies in Shared or platform folders and no filename imports.

## Membership acceptance / planned tests

P16 project.yml replaces obsolete file references with table locations; XcodeGen execution occurs only in later authorized implementation.
Signer source list has exactly one @main under flag; apps one existing @main without flag; no new file path sneaks into source generation.
P01 SyncProtocolTests covers signer request bounds/kind restriction/verify batch; P02 test_relay checks exact fixed executable ABI.
P07 MotionContractTests covers fallback/corner equation; final OS27 visuals remain device/SDK evidence, not asserted by file relocation.
P09 FinanceCompletionTests covers throwing cancellation/disabled provider; P06 PlanningInteractionTests covers vault unavailable capability.
P18 CompletionFlowsTests covers shared service start/stop idempotency across scenes, one sync task and accepted-snapshot startup ordering.
Later batch builds include both app targets, signer and widgets to prove membership; no build was run in this planning revision.
