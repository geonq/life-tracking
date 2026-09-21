# OS 27 / toolchain decisions
Status: planning, not compiled API acceptance. Source links: 25-RESEARCH-EVIDENCE.md.

## Binding deployment decision
Retain options.deploymentTarget.iOS="17.0" and macOS="14.0" in ios/project.yml.
Reason: Mac remains usable before its planned upgrade; no required domain feature needs OS27-only storage.
Use modern visuals opportunistically without requiring the user to upgrade the Mac before completion.
P16 owns all settings/target membership. Do not change bundle IDs, team or App Group to fix builds.
Keep current SWIFT_VERSION: 5.9 until CP-C checks accepted values for the selected Xcode;
if rejected, set "5.0" (Swift 5 language mode), never invent "6.4" as a language-mode value.
Set SWIFT_STRICT_CONCURRENCY: complete for app/test targets in P16; classify preexisting warnings.
Do not globally enable default MainActor isolation or migrate every ObservableObject to @Observable.
New interfaces explicitly annotate isolation. Swift 6 language-mode migration is deferred, not a quality exemption.
Xcode27 release notes specify Swift6.4 and host macOS26.6+. No toolchain/OS install in planning.
P00 records sw_vers, selected developer directory, installed SDK versions and device OS/build read-only.
If host cannot run Xcode27, baseline packets proceed; CP-C/27 visual acceptance stays blocked.
Do not install multiple simulator runtimes to satisfy an imaginary all-OS matrix.
Use installed compatible runtime for baseline behavior; OS27 simulator for new branches when available.
Physical iPhone17/iOS27 proof covers signing, touch, HealthKit, widgets; Mac27 proof after upgrade.
Baseline branch must compile in the selected SDK; minimum-OS behavior needs an available older runtime/device or stays unverified.

## Compile and runtime gating
P16 sets LIFEOS_SDK27 only when the selected SDK symbol inventory passes CP-C; default undefined.
Wrap references to 27-only names in #if LIFEOS_SDK27, then platform checks, then #available.
Availability checks alone do not make missing SDK declarations compile.
Do not identify SDK availability using #if swift(>=6) or compiler version alone.
For 26 glass use separate LIFEOS_SDK26; SDK27 enables both after validation.
All unguarded public view/DTO signatures remain baseline-compatible; new API types stay inside modifiers.

## Adoption matrix
|API/member|Verified availability|LifeOS binding decision / fallback|
|---|---|---|
|Document, ReadableDocument, WritableDocument|iOS27/macOS27|Defer vault migration; existing scoped picker + coordinated store remains writer|
|DocumentReader/Writer async snapshots|27 family|No new conformance now; would need CP-D ownership/undo/CAS amendment|
|NavigationTransition protocol|iOS18/macOS15|Member availability must be checked separately|
|.zoom(sourceID:in:)|iOS18; native Mac not listed|iPhone semantic card→detail only; Mac same-host matchedGeometryEffect or opacity|
|.crossFade|iOS27; native Mac not listed|Optional iPhone non-editor info sheet; native editor sheet retained; Mac opacity|
|.glassEffect(_:in:)|iOS26/macOS26|Floating planning toolbar only; opaque raised surface if reduced transparency/low power|
|ToolbarContent.visibilityPriority(_:)|iOS27/macOS26.1|Primary action .high; retain native overflow; old baseline ordered items/Menu|
|.toolbarOverflowMenu(content:)|iOS27; native Mac not listed|iPhone secondary actions; Mac explicit Menu in toolbar|
|.topBarPinnedTrailing|iOS27; native Mac not listed|Calendar New / Planning Add; baseline .topBarTrailing; Mac .primaryAction|
|toolbarMinimizeBehavior|Mentioned in What’s New; exact symbol fetch unresolved|Do not adopt; stable toolbar avoids gesture/layout jumps|
|New reorderable containers/swipeActionsContainer|Overview only, exact signatures unverified|Defer; retain List.onMove and native actions; CP-C required to reconsider|
|@Observable/@Bindable|existing baseline feature|New high-churn UI state only; existing coordinator lifetime retained|
|State macro / ContentBuilder|Xcode27 overview|Compiler benefit; do not manually rename ViewBuilder or rely on lazy init for I/O|
|AsyncImage caching improvements|Xcode27 overview|Do not use for private authenticated media; bounded existing loader remains|
|RoundedRectangle continuous|baseline|Card/control shape; radius tokens, not device-corner guessing|
|ContainerRelativeShape/containerBackground|baseline widget use|System container owns outer widget geometry; preserve tint/lock handling|

## Document decision rationale
LifeOS is a multi-module app with a folder-backed vault, not a single-document editor application.
New DocumentGroup automatically participates in read/write/undo lifecycle; existing publication uses explicit CAS/journals.
Installing both over the same file risks a stale autosave bypassing conflict/recovery checks.
OS27 does not remove iCloud conflicts, bookmark lifetime or remote reconciliation requirements.
No new FileDocument type is proposed as a substitute. Existing store remains valid Foundation-based I/O.
Future CP-D requires read-only prototype contract, one writer authority, undo mapping and conflict matrix before adoption.
This deferral is an architectural choice, not a claim the API is unavailable.

## Rejections / capability boundaries
No FinanceKit, new CloudKit authority, paid entitlements or automatic Developer enrollment.
No Metal/Skia/React/WebView animation runtime; Canvas is sufficient pending measured evidence.
No Foundation Models advisor, private Zepp API, unsupported dynamic toolbar symbol or Catalyst workaround.
Glass on data cards, graph canvas and nested translucent layers is rejected for contrast and compositing cost.
Permission declarations are not entitlement proof; profile denial remains U4.
