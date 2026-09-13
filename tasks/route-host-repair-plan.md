# RED AppKit route-host repair plan
Baseline: b8e2a02857d8bc2660c53890399762372bd0ae13; inspected six-file uncommitted diff, 2026-09-12.
Planning deliverable only. No implementation, test execution, commit or push is implied.
Authority: AGENTS.md; design.md §§11, 19.6, 20.1, 20.4. Preserve accepted Usage algorithms.
No separately selectable Astra worker interface is exposed in this session; this is the requested planning-role deliverable, not a claim of a separately run model.

## 1. Diagnosis and exact scope
- RED causes: child lifetime != scene lifetime; restorePersistedInspection() runs after every reconciliation; module:home:ready never changes between Home/Usage; source-string tests cannot prove ownership.
- Keep the repaired route reducer's didChange/routeChanged split and normalized Calendar route; do not restart the navigation architecture or resurrect permanently mounted Home/Usage trees.
- Implementation allowlist (all paths relative to repository):
  - ios/LifeOS/Modules/ModuleNavigation.swift — LifeOSMacRouteSnapshot/State/Reducer, new presentation value contracts.
  - ios/LifeOSMac/LifeOSMacApp.swift — LifeOSMacRootView, homeDetail, detail, performNavigationChange, route-host/motion adapter.
  - ios/LifeOS/OverviewView.swift — OverviewView selectedDetail/navigation binding and semantic scroll only.
  - ios/LifeOS/CodexView.swift — UsageView selection bindings, semantic scroll and chart-owner injection only.
  - ios/LifeOS/Usage/UsageProjectionChart.swift — replace the new persistence wrapper; chart handoff boundary only.
  - ios/LifeOSTests/OverviewDomainTests.swift; ios/LifeOSTests/LifeOSChartInteractionTests.swift.
  - ios/LifeOSMacSnapshotTests/LifeOSMacSnapshotTests.swift; ios/LifeOSMacUITests/LifeOSMacUITests.swift.
  - ios/LifeOSUITests/LifeOSUITests.swift — narrow shared-view regression only if needed.
- No other Swift, Shared/UsageCoordinator.swift, project/test-plan files, design.md, coordination, backend, Zepp, Obsidian, visual redesign, font/icon/layout migration. Existing project source membership suffices.
- Preserve UsageChartInspectionState.reduce/select/setViewport, dataset key/reset policy, seed policy, generation/authority rules, effective-domain math, chart sampling/indexing and ingestion. Move no business logic into navigation.

## 2. Smallest state boundary
- Add one @StateObject LifeOSHomePresentationState to LifeOSMacRootView, beside existing Calendar/Finance/Fitness presentation owners; inject it down. It stores presentation values, never coordinators, views, fetch tasks or subscriptions.
- Shape: sceneEpoch: UUID; sessionEpoch: UUID; overview: OverviewPresentation; usage: UsagePresentation; routeGeneration: UInt64; latestPacketRevision: UInt64; fixed owner slots.
- OverviewPresentation = detail: OverviewDetail? (move enum out of private view scope), scroll: SemanticScrollAnchor?; UsagePresentation = provider: Provider, range: UsageRange, scroll: SemanticScrollAnchor?, inspectionTicket: InspectionTicket?.
- SemanticScrollAnchor = section enum + fractional displacement within that section (finite 0...1). Overview IDs: header/usage/clipper/health/finance; Usage IDs: header/summary/chart/facts/additional. Missing section falls back to closest preceding visible section, then top.
- Keep provider/range and Overview detail in validated scene storage ONLY at the canonical scene owner; child views receive bindings. No second writer with the same key. Noncanonical previews/iOS callers get one local owner or their existing scene owner, never a global singleton.
- Scene restore accepts only known enum values; unknown detail -> nil. Persist semantic scroll only if valid; never persist pixel offsets, chart models, gesture state, pending Calendar commands or task generations.
- Preserve Overview's selected detail across ordinary module/Usage replacement. Explicit sidebar Home is a return-to-overview command and clears its nested detail; Back from Usage preserves the prior Home detail/anchor. Test these separately.
- Existing Usage provider/range reconciliation remains unchanged; an unavailable/removed choice may resolve according to that policy. Route-remount alone must not reset a still-valid choice.
- Use ScrollViewReader + named-coordinate geometry preferences in the existing ScrollViews (deployment-compatible); assign IDs to existing sections, not replacement layout wrappers.
- Record top visible section/fraction when scrolling settles and before route removal. Restore once after positive viewport/section layout; tag with route generation and owner. Cancel on route change, user scroll, invalid anchor, privacy change or scene teardown. No arbitrary sleep or unbounded retry task.
- On macOS use the owning NSScrollView clip-view adjustment after semantic target resolution if needed for fractional position; scope bridge to that ScrollView, never search/modify unrelated window scroll views.
- Mounted chart retains its accepted local reducer state; only a SMALL handoff ticket lives above it. Root observes its EXISTING Usage packet once to invalidate tickets while Usage is absent; no extra transport subscription.

## 3. Inspection handoff, NOT durable inspection history
- Remove chart @SceneStorage("LifeOS.usage.chart.inspection.v1"), inspectionPersistenceIdentity concatenation, and unconditional restorePersistedInspection() from reconcileInspectionState().
- New InspectionOwner = sceneEpoch + sessionEpoch + surface enum (canonicalUsageChart). Independent charts must receive distinct stable owner values; standalone callers default to NO remount persistence, not a shared storage slot.
- InspectionTicket = schemaVersion(1), owner, mountSerial, typed dataset fields matching UsageChartDatasetKey, resetEpoch, packetRevision, selectedPointID?, viewport start/end?. No model/observations, account credentials, raw packet or per-dataset cache.
- Fixed two-ticket maximum per scene, one per explicitly registered owner; production canonical Usage uses one. On replacement consume/remove the previous owner's ticket. Reject unregistered owners; do not grow a dictionary by provider/window.
- Ticket codec is process-memory-only Data, max 4,096 encoded bytes; remove/ignore the legacy SceneStorage key entirely (no migration). No disk/UserDefaults/Keychain write for inspection.
- Bounds BEFORE encode/decode: Data.count <= 4,096; version exact; UUIDs valid; all enum values recognized; account/source/point IDs <= 256 UTF-8 bytes each; window/metric <= 64; finite dates, paired endpoints, end > start. Validate strings before encoding; check byte cap before decoder allocation and again after encoding. Reject whole ticket on any invalid field.
- Use typed fields, not delimiter-joined identity strings. Unknown reset epoch forbids handoff; do not infer an epoch from now. Validate viewport through existing viewport/effective-domain helpers, never invent a replacement clamp.
- Account scope currently is a DISPLAY LABEL, not authenticated identity. sessionEpoch is an opaque root/coordinator-lifetime token, not a claim of account authentication. No handoff across process/scene recreation, coordinator replacement, fixture/live boundary, connection/privacy invalidation or return from Settings.
- Without a stable source account ID, allow remount restoration ONLY when root's full packet revision is unchanged since capture and owner/session match. Any packet change while hidden discards ticket, including loading/failure and intermediate empty->populated. Compare packet changes once at root; monotonic local revision must cover updates within the same request generation.
- This conservative rule preserves a settled round trip on the same dataset/packet; fresh hidden data may clear chart inspection. Do not expand this ticket's scope by treating equal account labels as proof of equal accounts. Upstream silent account replacement cannot be proven isolated here.
- Attachment sequence: create new mountSerial -> normal accepted seed/reconcile against CURRENT packet -> atomically take ticket once -> check all scope/revision/identity/epoch/authority guards -> select only ID present in accepted model -> validate viewport -> destroy ticket regardless of success.
- Restoration runs at initial owner attachment only, never on inputRevision/onChange, loading completion, provider selection, or later point reappearance. No deferred candidate waiting for data. authoritativeEmpty/no accepted model rejects ticket.
- After each normal reconciliation invalidate any exported older ticket, then export only current reducer-selected ID/viewport when departing. Never retain an old selection after reducer clears it. Export is disabled on cancelled/obsolete mounts.
- Provider/window/account/source/quality/reset changes clear the old owner's ticket before reconcile; provider A->B->A does not retrieve A's old inspection. Empty->populated does not reselect. Same-key refresh behavior remains the accepted reducer's behavior.
- Do not encode on every pointer sample. Keep selection/viewport local; bounded ticket encode occurs only at explicit handoff, after cancelling active drag/hover. Layout/range changes use existing effective-domain behavior.

## 4. Explicit motion and lifetime ownership
- Add visibleSurfaceIdentity to LifeOSMacRouteSnapshot: home:overview, home:usage, unavailable:<module>, or mountedIdentity for other modules. Keep mountedIdentity stable for intra-Finance/Fitness routes.
- Shell/sidebar/toolbar remain outside the changing host. Replace implicit .transition on detail's stable module identity and sleep-based cleanup with LifeOSMacRouteHost at the actual visibleSurfaceIdentity boundary.
- Implement the bounded macOS adapter in LifeOSMacApp.swift: one NSHostingView for current SwiftUI content; at most one outgoing raster presentation layer. No second outgoing SwiftUI tree, NSHostingView, coordinator or replayed refresh closure.
- Before replacement: save presentation ticket/anchor, cancel destination gestures, capture ONLY the measured content viewport, then remove old child without implicit SwiftUI removal animation. Install new live surface at its identity; all module data owners remain root-owned.
- Raster is local, memory-only, noninteractive and accessibility-hidden by construction; no click/keyboard/AX forwarding. Current live destination alone owns focus, actions, refresh and command binding. Block callbacks from retired mountSerials.
- Bound raster to viewport at backing scale and <=16 MiB RGBA; check width*height overflow before allocation. Release on completion, replacement, resize, window close, privacy/source invalidation and backgrounding. If capture exceeds cap/fails, use instant transition; never retain a stale sensitive image.
- Motion value shape: generation, from/to surface IDs, startedAt, incoming(opacity,x), outgoing(opacity,x), durations; injectable monotonic clock; pure sample(at:) and retarget(to:at:) functions. Raster resource lifetime stays in adapter, not reducer.
- Normal detail entry: opacity 0->1, x +8->0 forward / -8->0 back, 180 ms; outgoing opacity current->0 over 120 ms, no newly introduced outgoing translation/scale. Module switch opacity only, 120 ms. Curve cubic Bézier (0.16,1,0.3,1).
- Drive explicit presentation samples from one bounded animation driver while active; disable implicit layer/SwiftUI animations. Stop driver at settlement. Completion can release resources/restore focus only, never navigate/save.
- A->B->A reversal: sample both layers at event time; swap their surface roles, remount A from its stored presentation values, use former A raster's sampled opacity/x for A's live starting values and capture B at its sampled values. No restart at 0/8 or flash to endpoint.
- Third destination during animation: flatten the current visible composite to ONE outgoing raster at current appearance, discard superseded resources, mount latest live target. Coalesce latest intent, never queue hidden screens. If raster replacement cannot be continuous within cap, settle latest instantly and record fallback.
- Current generation owns cleanup; stale completion is no-op. Repeated same route does not change generation, restart driver, capture, remount, clear transition or republish module intents.
- Reduce Motion at entry: instant route swap. Toggle midflight: invalidate completion, stop driver, remove raster and settle current live opacity=1/x=0 immediately; preserve direct Back/scroll/focus.
- Restore semantic scroll after new layout, then focus only if route generation remains current and user has not moved focus. No focus theft from command palette/sheet.
- Remove dead currentRouteTransition/outgoing timing leftovers and claims that SwiftUI automatically proves reversal. Retain timing properties only if actual explicit driver consumes them.

## 5. Reducer and Calendar command contract
- Keep LifeOSMacRouteReduction.didChange and routeChanged: no change -> return before any publication/motion; command-only -> update routeState without motion or Finance/Fitness generation emission.
- External initial .newCalendarEvent -> stable .calendar route + one pending command. Scene restoration of that route -> stable .calendar WITHOUT pending command; retain LifeOSMacSceneRoot.restoredRoute normalization.
- While pending, repeated .newCalendarEvent coalesces. After consumption, another explicit .newCalendarEvent is a new command even on stable Calendar.
- .select(.calendar)/.navigate(.calendar) cancel pending without route remount; consume clears once without route mutation; repeated consume is no-op.
- .home/.select(any)/.navigate(other)/.showDestinationUnavailable cancel abandoned command. Reversal away before delivery must not open the editor later; valid unavailable restore never resurrects command.
- Invalid restore with no origin is a true no-op and preserves an initial pending command. Do not confuse it with intentional navigation cancellation.
- Calendar binding is live only for current Calendar mount; capture mountSerial in clearing closure so a retired child's late false write cannot consume a newer request. Calendar UI consumption remains the existing binding handshake, not animation completion.
- Persist only stable route, usage flag and sidebar state; command and unavailable transient origin are not replayed across scene recreation.

## 6. Deterministic tests before runtime claims
- OverviewDomainTests.testHomePresentationRoundTripPreservesDetailAndSemanticAnchors: capture/remove/remount bindings; same scene values survive; explicit Home clears nested detail, Usage Back preserves it; unknown anchors fall back.
- OverviewDomainTests.testMacRouteNoOpHasNoEffects: spy route publications, driver starts and mount count; repeated Home/Usage, invalid restore and repeated consume produce zero additional effects.
- OverviewDomainTests.testCalendarCommandInitialRestoreConsumeAndCancellation: table every action in §5; assert routeChanged vs didChange, normalized route and pending state. Include repeated request, stale mount acknowledgement and interrupted delivery.
- LifeOSChartInteractionTests.testInspectionHandoffConsumedOnce: select P/viewport, export/unmount/new mount/same packet; restoration succeeds once, further reconcile cannot take ticket.
- testInspectionRemovalReappearanceDoesNotReplay: selected P -> refreshed model removes P -> P returns; nil selection both before/after remount.
- testInspectionAuthorityResetAndIdentityInvalidateHandoff: table authoritative-empty->populated, reset, provider A/B/A, window 5h/7d/5h, fixture/live, account label/source/quality changes; no restored selection or cross-identity viewport.
- testInspectionHiddenPacketChangeAndSessionRecreationDiscard: change even same-generation packet while hidden, Settings return, new scene/session; ticket unusable. Unchanged packet settled round trip preserves.
- testInspectionCodecRejectsMalformedOversizedAndNonfinite: garbage/truncated JSON, 4,097 bytes, overlong multibyte ID, wrong version/enum, reversed/partial interval, invalid UUID; reject before state mutation. Valid <=4,096-byte envelope round-trips.
- testInspectionOwnersAreIsolatedAndBounded: two distinct owners same dataset never take each other's ticket; third unregistered owner rejected; consumed/invalidated entries released. Legacy SceneStorage content is never consulted.
- Keep all existing LifeOSChartInteractionTests authority/generation/domain tests unchanged and passing; test unknown reset rejection and same-key loading/failure behavior explicitly.
- LifeOSMacSnapshotTests.testRouteMotionSamplesAndReversalContinuity: fake clock at 0/50/100/150/180 ms, compare pre/post-retarget opacity/x within 0.001; correct directions/durations; stale completion cannot release current layer; Reduce Motion settles.
- testMountedRouteHostRoundTripHasOneLiveLifecycle: real offscreen NSWindow/route host with mount/deinit/task/subscription spies; Home->Usage->Home->Usage, layout, flush teardown; active live count=1, outgoing raster<=1, no duplicate coordinator/fetch creation.
- testRouteHostRestoresInspectionAndScrollAfterLayout: exercise injected presentation owner with actual host, not source strings; measure section position tolerance <=2 pt after layout; cancel restoration on superseding route/user input.
- Replace testMacRouteLifecycleUsesTheMountedCurrentLayerOnly's spelling expectations with these behavioral assertions. Keep only supplementary source boundaries (no recursive root/coordinator construction); passing them is not lifecycle evidence.

## 7. Sequential execution and gates
- First worker saves existing diff to /private/tmp/route-host-pre-repair.patch and records HEAD/status; do not overwrite another worker's modifications. Implement §2/3 and prove tests, then §4/5 and runtime; one writer and one native process at a time.
- Commands below run from /Users/georgdomke/Developer/life-tracking. Existing generated project/schemes are used; no xcodegen regeneration/project edits. Stop at failures; fix cause, never weaken assertions.
```sh
git diff b8e2a02 --check
git diff b8e2a02 --stat
python3 -B scripts/validate_acceptance_registry.py
python3 -B scripts/validate_native_calendar.py
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOSLogic -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath /private/tmp/lifeos-route-repair-ios -parallel-testing-enabled NO -jobs 1 CODE_SIGNING_ALLOWED=NO -only-testing:LifeOSTests/OverviewDomainTests -only-testing:LifeOSTests/LifeOSChartInteractionTests -only-testing:LifeOSTests/UsageIngestionTests -only-testing:LifeOSTests/UsageHistoryTests test
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOSMacLogic -destination 'platform=macOS' -derivedDataPath /private/tmp/lifeos-route-repair-mac -parallel-testing-enabled NO -jobs 1 CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOSMacUI -destination 'platform=macOS' -derivedDataPath /private/tmp/lifeos-route-repair-mac-ui -parallel-testing-enabled NO -jobs 1 CODE_SIGNING_ALLOWED=NO -only-testing:LifeOSMacUITests/LifeOSMacUITests/testRouteHostRoundTrip -only-testing:LifeOSMacUITests/LifeOSMacUITests/testRouteHostInterruptionAndReduceMotion test
git diff b8e2a02 --check
git diff b8e2a02 --stat
```
- Add the two named UI tests: real pointer/keyboard Home->Usage->Back->Clipper->Back; valid provider/range, selected point and scrolled section survive the settled round trip; latest destination exclusively hittable/AX-visible; new Calendar command delivered once. Use controlled labeled fixtures and a separate normal-launch unavailable run, never production demo fallback.
- UI timing is not precise enough for 50/100/150 ms proof: use injected-clock mounted-host tests for exact offsets, plus runtime captures of real reversal. Record 60 fps captures, fixed sidebar geometry, outgoing click rejection and Reduce Motion midflight. Launch only the exact binary in the command's DerivedData.
- Run 20 warmed cycles; counters return to baseline, one settled live content tree, no unbounded raster/task/subscription growth. Instruments 20-second trace reports p95/p99/max/hitches; target main-thread p95<=8 ms, frame p95<=16.7 ms at 60 Hz, no app-caused stall>50 ms. Simulator does not prove hardware frame budgets.
- Acceptance: all scoped builds/tests pass with no introduced warnings; inspected runtime evidence; independent Astra Medium GREEN against exact final diff; no out-of-scope edits. A passing build/source test alone cannot clear RED.
- Unsigned simulator cannot prove real macOS AppKit compositor/trackpad/AX behavior, physical iPhone interactive-back/performance, signed entitlements/App Groups/Keychain, signing renewal or live backend/provider/device security. Mac UI runner may require local signing/accessibility permission; if unavailable, record runtime gate blocked, do not replace it with source assertions or claim GREEN.
- Rollback criteria: stale selection resurrection, duplicate live lifecycle/fetch, wrong-owner restore, unbounded memory, retired input/command delivery, discontinuous reversal or untouched-file changes. Preserve failed diff/evidence, revert only repair-owned hunks to saved pre-repair state; never git reset --hard or restore all of base b8e2a02.
- After one failed correction, stop implementation and return exact failing invariant/reproducer to Astra planning. No speculative redesign loop; do not merge/commit/push as part of this plan task.
