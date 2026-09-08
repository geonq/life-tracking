# LifeOS Design Overhaul Plan

## 1. Release gate

The app is functionally advanced, but the current UI fails the visual quality gate shown by the supplied screenshots. Treat this as a coordinated redesign before calling LifeOS complete. Preserve working data contracts, real integrations, WidgetKit targets, and secure local networking unless a redesign task explicitly changes their presentation.

Hard product decisions:
- Remove Advisor completely. The only in-app AI surface permitted is calorie estimation from a meal photo.
- Use Apple system typography everywhere: SF Pro on Apple platforms through SwiftUI `.system` fonts or a token facade backed by `.system`. Remove Inter, Space Grotesk, and every custom font registration after migration.
- Read `/Users/georgdomke/Library/Mobile Documents/com~apple~CloudDocs/geon/colors.md` before changing colors. Keep the existing brand palette as the source of truth, use green for estimates/projections, orange for calories, and give protein a clearly different hue/value from blue accents. Never place same-saturation blue accents beside one another.
- Design for dark mode, transparent/tinted widgets over a grey wallpaper, simulator review, and a personal install using Apple Personal Team signing.

## 2. Visual north star

Use a quiet near-black canvas, one restrained surface family, and a 4/8 point spacing rhythm. Every page needs a clear reading order: page identity, primary status, decision or action, supporting detail. Use three text roles per surface (title, body, metadata) with SF Pro weight and optical size doing the hierarchy work. Keep page gutters and card edges aligned to one grid.

Cards are containers for related decisions, not repeated decoration. Remove gratuitous nested cards, excessive empty height, heavy shadows, and full-width controls that do not need the space. Empty and unavailable states retain the same geometry as their populated state, state the cause in one sentence, and offer one useful next action when one exists. Replace placeholder bars and repeated “Not available” labels with a compact, calm state row.

Use SF Symbols with one weight family per context, optical size matched to adjacent text, and fixed icon boxes. Selected navigation rows use a quiet accent wash, a slim leading indicator, correct contrast, and consistent corner treatment. No hand-drawn or mixed-style symbols. Buttons have one primary action, one secondary action, and platform-correct hit areas.

Animation is part of the design. Transitions must be interruptible, state driven, and spatially coherent. Use short hover/press feedback, deliberate page transitions, and meaningful chart/ring reveals. A data refresh must update content without replaying an entrance animation. Reduced motion must settle directly to the final state.

## 3. Token and typography foundation

Primary files: `ios/Shared/DesignTokens.swift`, `ios/Shared/LifeOSMotionKit.swift`, `ios/LifeOS/Info.plist`, Xcode project membership, and all files found by `rg -n 'LifeOSFont|Inter|SpaceGrotesk|custom font|\.ttf' ios packages services`.

Create one `LifeOSTypography` facade backed only by SF Pro/system styles, with explicit roles for page title, section title, card title, body, label, metadata, numeric metric, and button. Preserve Dynamic Type where it does not break the fixed widget contract. Migrate every custom font call to the facade or `.system`; then remove Inter resources and plist registration. Add a negative test/grep check that no product source references the removed fonts.

Centralize canvas, surface, elevated surface, text, border, focus, semantic, and module accent tokens. Add contrast-safe variants for transparent widget backgrounds and grey wallpaper. Keep spacing, radius, control height, chart stroke, and content-width values in tokens; do not repair individual screens with arbitrary constants.

Before screen work, define canonical `LifeOSPageFrame`, card, status row, button, selector, and sheet recipes. Resolve competing `pagePadding`/`pageGutter` and `lifeOSCard`/`flatCard` APIs with an explicit migration path. Add `onAccent` and state-specific foreground pairs; validate normal text at 4.5:1 and essential graphics at 3:1 in supported appearances and pressed/selected states. Define minimum card widths, column collapse rules, numeric/unit wrapping, and metadata truncation so small phones, narrow Mac windows, and large text cannot clip essential content.

## 4. Shell and navigation

Files: `ios/LifeOS/Modules/ModuleNavigation.swift`, `ios/LifeOS/LifeOSApp.swift`, `ios/LifeOSMac/LifeOSMacApp.swift`, shared shell components, and navigation tests.

Rebuild the sidebar/navigation rows around a single icon map using SF Symbols. Normalize icon box size, symbol weight, label baseline, selected wash, leading accent, hover, and keyboard/focus behavior. Remove Advisor from every route, sidebar, More screen, deep link, AppIntent, test fixture, and documentation. Keep Calendar, Finance, Fitness, and the existing module set discoverable without visual competition.

Define one responsive content frame: stable page gutter, maximum reading width, consistent section gap, and a two column threshold that works on Mac and iPhone. Do not let one module invent its own shell geometry.

## 5. Finance and usage

Files: `ios/LifeOS/Modules/Finance/FinanceView.swift`, `FinanceChartModeViews.swift`, `UsageProjectionChart.swift`, finance tests, and finance widgets.

Replace the screenshot’s oversized unavailable block with a compact status header that still reserves the chart’s intended geometry. Make the account summary, updated time, currency, source status, chart mode, range selector, and category panel read as one hierarchy. Use one primary chart, clear axes/labels, and a compact legend. Avoid four equal “not connected” cards; use a concise connection state with an actionable connect/review affordance.

Preserve truthful unavailable, stale, partial, and live states. Make chart controls disappear from hit testing when unavailable. Keep estimates/projections green and distinguish them from observed values using tokenized line/fill styles. Ensure transitions do not interpolate unrelated datasets and reset zoom/scrub when the observed model changes.

Specify four finance availability policies: first-load/no-source is compact, refresh preserves stable geometry, filtered-empty explains the filter, and lost availability preserves only truthful stale context. Availability is evaluated per chart mode and range so an empty selection never traps the user; distinguish observed zero from no observations. Chart identity, dataset revision, mode, and range decide which inspection state survives.

## 6. Calendar

Files: `ios/LifeOS/CalendarView.swift`, `ios/Shared/CalendarViews.swift`, `CalendarLayout.swift`, `CalendarCoordinator.swift`, `CalendarPeerSync.swift`, Calendar widgets, and Calendar tests.

On iPhone, use one vertically scrollable timeline viewport with a single time-label column, a horizontally paged day/week region, and a content height derived from the visible time range plus bottom inset. The scroll container must own vertical scrolling; event gestures must not consume the entire viewport. Keep the current-time marker singular: one line, one label, one marker per displayed day column. Test content beyond 10:00 and the last event so scrolling is observable.

On Mac, add a Notion-like trackpad magnification interaction for timeline density. Map `MagnificationGesture`/native magnification input to a bounded timeline scale, preserve the focal time under the pointer, animate only user initiated scale changes, and keep a small accessible fallback control. Do not use the same gesture to trigger navigation. Define minimum/maximum scale, clamping, cancellation, and state restoration in `CalendarLayout` tests.

Freeze gesture ownership: vertical pan scrolls, horizontal pan pages, tap opens, long-press then drag creates, event drag moves, edge drag resizes, and magnification changes density. Diagonal pans must not create/edit; cancelled drafts are discarded; zoom during editing has deterministic behavior. Preserve wall-clock and DST semantics, including repeated/nonexistent times. Render one intended now-marker assembly for today, and make the last late-day content reachable without accidental blank tail space.

Retain secure manual pairing, encrypted frames, replay/freshness checks, outbox receipts, and revoke behavior. Redesign their presentation as a quiet connection status and focused pairing sheet; never expose keys or raw transport details in the main calendar.

## 7. Fitness, recovery, biology, and nutrition

Files: `ios/LifeOS/Modules/Fitness/FitnessView.swift`, `FitnessCoreDetailDomain.swift`, `FitnessStressView.swift`, `FitnessBiologyView.swift`, `FitnessNutritionView.swift`, HealthKit projection/integration, nutrition photo flow, and related tests.

Replace sparse giant cards with compact responsive sections: readiness hero, load/sleep pair, stress/reserve pair, and supporting metrics. A missing source should look intentional and proportional to the populated card, with one source status line and clear metric labels. Align accent rails, title baselines, numeric metrics, and section captions.

Biology needs a stable page header, compact date navigation, a readable experimental disclosure, and a card layout that does not clip horizontally. Keep experimental values clearly labeled and source backed.

Rebuild the recipe/meal review sheet with a clear title block, grouped form fields, left aligned labels, readable input text, predictable keyboard behavior, and an obvious action order: keep manual, apply local preview, save meal. Use one surface hierarchy and remove the current nested oversized form panel. Preserve the disclaimer and durable local save semantics.

Define draft ownership before changing the controls: keep-manual, local-preview, and save each have explicit persistence and dismissal semantics; failed saves retain edits; repeated save is idempotent; edits after success clear the saved state. Save meal is the sole primary action. Define focus order, keyboard Next/Done, inline validation, dirty-dismiss behavior, and focus return independently of visual icon size.

Keep calorie picture tracking as the sole AI feature. Any nutrition photo request must show source/status, confidence, editable result, and local-save behavior without exposing an Advisor-like chat or generic life advice surface.

## 8. Widgets

Files: `ios/LifeOSWidget/FutureModuleWidgets.swift`, `CalendarWidget.swift`, every widget family/snapshot fixture, `WidgetSnapshotPublisher.swift`, and widget tests.

Review every existing widget in small, medium, large, lock-screen, clear, dark, and tinted modes. Use opaque or contrast-managed panels over transparent/tinted backgrounds, especially grey wallpaper. Make all labels readable at glance, keep the primary metric dominant, and avoid tiny metadata. Keep semantic meaning stable: observed values, estimates, stale states, and unavailable states must be visually distinct. Verify all existing widgets before deleting any; only remove a widget when its information duplicates another and tests/documentation are updated.

For each module, maintain a reference matrix with destination, viewport, state (live, zero, empty, stale, partial, error), expected hierarchy, and interaction evidence. Store captures or snapshot assertions for every matrix row; use short recordings/manual evidence for scroll, pinch, scrub, interrupted transitions, sheet entry, and keyboard behavior.

## 9. Advisor removal boundary

Delete `ios/LifeOS/Modules/Advisor/`, `ios/Shared/AdvisorClient.swift`, `AdvisorModels.swift`, Advisor Swift tests, `packages/contracts/src/advisor.ts` and tests, `services/api/src/advisor.ts`, `advisor-gemini.ts`, their tests, and all Xcode/project references. Remove API routes, capability responses, provider wiring, Advisor secret/env documentation, deep links, navigation, AppIntents, and contract exports. Keep nutrition photo contracts and provider code intact. Add a repository check proving `Advisor`, `advisor`, and `LIFEOS_ADVISOR_SECRET_FILE` have no live product references except an explicit migration note if required.

## 10. Execution order and worker contracts

Each worker must read this plan, the target repo handoff, and only the files in its scope. It must make small commits, update coordination state under 200 lines, run focused tests, and report changed files, commands, failures, and remaining device-only gates.

Every implementation must leave the owned scope smaller or clearer: delete dead files, unreachable routes, obsolete wrappers, duplicate state paths, and unused tokens. Prefer one-pass `O(n)` aggregation; use `O(n log n)` only when deterministic ordering is required and never introduce nested scans over unbounded input. Keep external collections bounded, preserve explicit invariants, remove warnings, and never silence a failing test or compiler diagnostic to make a batch pass.

1. **Foundation/removal — Luna Max:** token typography migration, font resource removal, Advisor deletion, navigation/deep-link cleanup, project membership, negative checks. Owns token/nav/project files until complete.
2. **Calendar — Luna Max:** iPhone scroll architecture, Mac magnification, timeline layout, pairing presentation, focused tests. Owns Calendar files only after step 1.
3. **Finance/Fitness/Nutrition — Luna Max:** screen hierarchy, states, controls, responsive sheets, motion integration, focused tests. Owns module files only.
4. **Widgets/shell/motion — Luna Max:** widget variants/snapshots, remaining shell polish, shared motion fixes. Owns widget/snapshot/motion files after earlier merges.
5. **Windows/backend — Luna Max:** resolve deployment review blockers in `services/windows-service-host` and server/gateway source without changing UI. Validate fail-closed auth, rollback, inventory evolution, recovery, and service snapshot rules.
6. **Final integration/review — Luna Max:** inspect the complete diff, run all feasible suites/builds, remove regressions, update handoff/phase/decision/task docs, and produce a device acceptance checklist. Use batched review by subsystem to control tokens.

## 11. Verification

Run `git diff --check`; `npm test`; API build/typecheck/tests; gateway pytest in `/private/tmp/lifeos-gateway-venv`; unsigned iOS simulator tests/builds; unsigned macOS app/widget builds; and widget snapshot tests. Use the existing project schemes and destinations from the repository scripts rather than inventing new ones. Every worker must report exact commands and counts.

The simulator cannot prove HealthKit authorization, Zepp export, iPhone USB reauthentication, WidgetKit clear/tinted rendering, Personal Team App Group signing, Windows PowerShell behavior, Tailscale reachability, or live bank consent. Track those as explicit external gates. Do not claim completion until each gate is either verified on hardware/runtime or documented as the only remaining user action.

## 12. Acceptance checklist

- SF Pro/system typography is used throughout; custom fonts and registrations are gone.
- Advisor is absent from UI, routes, contracts, providers, secrets, intents, and builds; calorie photo tracking still works.
- Finance, Recovery, Biology, Nutrition, navigation, and widgets match the same restrained hierarchy and have intentional unavailable states.
- Calendar scrolls through the complete iPhone timeline, shows one current-time marker per column, and Mac pinch zoom changes density around the focal time.
- Hover, press, drag, page, chart, sheet, and refresh animations are smooth, interruptible, state correct, and reduced-motion safe.
- Grey-wallpaper transparent/tinted widgets remain readable; estimates are green; blue accents do not collide in saturation.
- No test, build, source, or security review regression remains unexplained.

No scheduling or usage-limit watcher is part of this plan.
