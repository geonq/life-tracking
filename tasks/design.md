# LifeOS design and interaction implementation contract
Updated 2026-09-10. Status: specification only; implementation and visual acceptance remain unverified.

## 1. Authority, intent, and evidence
- Deliver a compact daily planning instrument: precise hierarchy, calm surfaces, immediate feedback, coherent motion. Linear/Vercel are a quality bar, not layouts to clone or a reason to turn the app into a marketing page.
- This file is the worker-facing visual contract at `tasks/design.md`; do not create a competing root `design.md`. Preserve existing functional, data, security, recurrence, and persistence contracts.
- Read inputs: `tasks/design-overhaul-plan.md`, `tasks/full-redesign-and-connectivity-plan.md`, design-coordination `00-READ-FIRST.md`, readable `geon/colors.md`, and the supplied screenshot series. Screenshots are defect evidence, not proof of the current build.
- Source inspected: dashboard `src/main.tsx`/`styles.css`; native `DesignTokens.swift`, Overview, Finance, CalendarViews/CalendarLayout/CalendarView, Biology, Nutrition, TrainingSession, TaxDocumentsView, ModuleNavigation, and UsageWidget. These are distinct implementations; native screenshots must not be attributed to web CSS.
- [Skills UI Clean](https://www.skillsui.app/skills/clean): adopt deliberate spacing, consistent controls, focused actions, complete hover states. Retain LifeOS's explicit brand blue despite the reference's generic anti-blue advice. Its downloadable design/live preview fetch failed; no rendered preview review is claimed.
- [Forever Infinite](https://forevercomponents.com/infinite/) and its [component index](https://forevercomponents.com/components/): use purposeful progress, feedback, and drag continuity as inspiration. The canvas requires JavaScript; its animations were not visually exercised in this pass. Copy no component code, dependencies, particle effects, magnetic cursors, or perpetual decoration.
- Advisor, generic assistant/chat, life advice, AI planning, and assistant entry points are excluded. Calorie-photo estimation is the only in-app AI. Usage accounting is data reporting, not an assistant.
- Evidence boundaries: this document does not certify live connectors, Zepp equivalence, security, frame rate, device rendering, or completed source changes. Final cybersecurity review remains a separate release gate.

## 2. Token ledger: points native, CSS pixels web, at default text size
| Role | Exact target |
|---|---|
| Font | SwiftUI system default design (SF Pro); web `-apple-system, BlinkMacSystemFont, system-ui, sans-serif`; no bundled font, rounded design, Inter, or Space Grotesk |
| Page title | Mac/web 22/28 semibold; iPhone 24/30 semibold; never duplicate the same large title in toolbar and content |
| Section / card title | Mac 15/20 and 14/20 semibold; iPhone 17/22 and 16/22 semibold |
| Body / control | Mac 13/19 regular / 13/18 medium; iPhone 15/21 regular / 15/20 medium |
| Metadata / chart labels | Mac 12/16 regular; iPhone 12/16 regular; meaningful text never below 11 in constrained widgets |
| Primary numeric / secondary numeric | Mac 28/34 and 20/26 semibold; iPhone 30/36 and 22/28 semibold; units body size, baseline aligned |
| Number behavior | Monospaced digits only; locale-aware grouping, currency and decimal input; no animated random/count-up intermediate financial values |
| Tracking / weights | Default tracking; page titles -0.3pt allowed; no all-caps status paragraphs; weights regular 400, medium 500, semibold 600 |
| Space scale | 2, 4, 8, 12, 16, 20, 24, 32, 40, 48; default inline gap 8, card gap 16, section gap 24 |
| Padding | Desktop card 16, mobile card 16; compact row 12 horizontal; sheet 24 desktop / 16 phone |
| Shapes | Control radius 8, card 12, popover/sheet content 16; platform sheet outer shape stays native; pills only for short status/filters |
| Borders / depth | 1pt border; no nested card borders; no rest-state card shadow; popover only: black 24%, y=8, blur=24 |
| Controls | Mac visible/hit height 32, icon hit box 32; iPhone minimum hit box 44×44, primary control height 44; minimum gap 8 |
| Lines / rings | Chart line 2, grid 1 at 50% border opacity; ring 5 at diameter 72, 6 at diameter 112; rounded endpoints |
- Typography roles use semantic scaling. At increased text size, stack/wrap content instead of shrinking essential text; the compact defaults are not a reason to disable system text preferences.

## 3. Color and surfaces
| Token | Dark | Light fallback |
|---|---|---|
| canvas | #000000 | #FAFAFA |
| surface | #131315 | #FFFFFF |
| elevated / hover | #1B1B1E | #F4F4F5 |
| border | #2B2B30 | #D4D4D8 |
| text primary | #F5F5F7 | #18181B |
| text secondary / metadata | #A1A1AA | #52525B |
| action / on-action | #0253C4 / #FFFFFF | same |
| action hover / pressed | #0244A2 / #013174 | same |
| focus / observed chart | #5DA0FD | #0253C4 |
| selected nav foreground / backing | #B8D5FE / #011E47 | #0244A2 / #E6F0FF |
| estimate / success | #60D386 | #01773B |
| calories / warning | #FFB06E | #A25A03 |
| protein / cash flow | #63D2D2 | #067878 |
| error / spending outflow | #FF8585 | #B42335 |
| sleep / fitness identity | #B59AFF | #7040B8 |
| target / unknown | #A1A1AA | #52525B |
- Brand blue is the readable file's main #0253C4; use it for primary actions, never as tiny dark-mode body text. Adjacent data meanings use different hues, line patterns, labels, and ordering; do not use two similarly saturated blues to imply different meanings.
- Estimates are green and dashed, observed series solid, target dotted neutral. Calories stay orange, protein teal. Success and estimate sharing green requires explicit text/pattern distinction.
- Usage retains the current shared observed-blue series contract; providers are named, never distinguished only by near-identical blues. Do not resurrect the older conflicting provider-gradient spec without review.
- Resting cards may have a subtle vertical surface-to-canvas gradient with ≤3% white luminance lift. No ambient glow, animated wallpaper behind readings, saturated card rails on every card, or colorful unavailable states.
- Require ≥4.5:1 normal text and ≥3:1 essential controls/graphics against actual composited backgrounds, including hover/pressed/selected states. Color alone never communicates provenance or errors.

## 4. Shared component recipes and layout
- Own shared tokens in `ios/Shared/DesignTokens.swift`, type in `Typography.swift`, icons in `LifeOSIcon.swift`, motion in `LifeOSMotionKit.swift`; use existing facades. Web mirrors named roles in CSS variables, not an unrelated palette.
- `PageFrame`: one toolbar, one title/action row, then content; max readable width 1200 desktop, centered within available content; charts/calendar may use the remaining width. No viewport-height cards merely to fill space.
- Desktop ≥1100 window width: 208 sidebar, 24 content gutters, 16 grid gap. At 800–1099: 56 icon rail with tooltips and labels on expansion, 20 gutters. Below 800: toolbar module switcher, no permanent rail, 16 gutters.
- Use available content width, not device name, for grids: ≥880 chart + 280 side panel; 600–879 two equal cards; <600 one column. Two compact metrics may share a phone row only if each has ≥156 available width; otherwise stack.
- iPhone: safe-area-aware 16 gutters, 12 grid gap, native bottom navigation Home/Calendar/Finance/Fitness/More; Tax and Settings in More. Preserve current release-visible routes; unavailable internal routes must not become dead navigation items.
- `Card`: 16 padding, title row, 12 gap, content, optional 8 gap metadata; one outer surface. Typical metric card 104–136 high at default type; variable-length content expands. Whole-card navigation has a subtle trailing chevron; nested controls cannot also trigger the card.
- `StatusRow`: 14 symbol, 8 gap, one cause sentence plus at most one action. One parent notice may summarize a shared outage; children show only missing values or specific exceptions.
- `Toolbar`: desktop 48 high; phone native 44 plus safe area. Search 240 desktop or expandable icon on narrow widths; do not leave an empty giant header/search strip.
- `Selector`: intrinsic-width segments, 32 desktop/44 mobile hit height, max four visible options; overflow becomes a labeled menu. Chart metric tabs and range controls occupy one desktop toolbar and two compact phone rows.
- `Sheet`: desktop ideal 520 wide (min 420 constrained by window), max 80% content height; phone system sheet/full screen when keyboard requires. One internal scroll owner; pinned footer above keyboard/safe area; no nested outlined form panel.

## 5. Iconography and control semantics
- Use semantic SF Symbols native, regular/medium monochrome rendering; navigation visual size 17 in a fixed 20 box, inline 14 in 16 box, card 16 in 20 box. Selected icons retain size/weight; tint changes only.
- Map: Home `square.grid.2x2`, Calendar `calendar`, Finance `creditcard`, Fitness `figure.strengthtraining.traditional`, Tax `doc.text`, Usage `chart.bar.xaxis`, Clipper `chart.xyaxis.line`, Settings `gearshape`, Projects `point.3.connected.trianglepath.dotted` only if supported, otherwise `folder`.
- Check every symbol against deployment-target availability; fallback must retain meaning. Use `arrow.clockwise`, `plus`, `chevron.right`, `ellipsis` consistently for actions; no emoji, Unicode diamonds, random logos, mixed outline/fill families, or oversized house branding.
- Web uses one SVG outline family with 24-unit viewBox, 1.5 stroke, rounded caps, same semantic map; use already licensed assets/dependency if available. Do not redistribute SF Symbols into a web icon library.
- Every icon-only action has an accessible label, desktop tooltip after 500ms, keyboard focus, pressed and disabled state. Disabled state retains readable labels and explains the unavailable action on request.

## 6. Motion and navigation ownership
- Hover: background/border interpolation 120ms ease-out, no card translation. Press: 80ms to 0.985 scale for buttons only, release 140ms; rows use surface feedback without text scaling.
- Top-level desktop route: 160ms crossfade, fixed shell; no zoom, card flight, or full-page spring. Home→Usage/Clipper detail: stable header, incoming opacity 0→1 and x=8→0 over 180ms; outgoing 120ms fade. Back mirrors direction, never replays all card/ring entrances.
- iPhone detail navigation uses the native interactive push/pop; no second custom transform layered over it. Sheets use native presentation and interactive dismissal; dirty forms require Keep editing/Discard confirmation.
- Reversal: retarget from current presentation values and velocity, not initial keyframes. Route identity owns task/animation cancellation; latest navigation wins. Test A→B→A at 60ms and 120ms; one visible interactive destination, no flash, duplicate focus, or delayed navigation callback.
- Retain per-route scroll, filters, chart selection where dataset identity permits, and drafts across back navigation. Refresh does not remount the route, reset scroll, or replay reveal effects.
- Selectors/reorder settle: spring response 0.24s, damping 0.90; calendar pager 0.28s/0.92. Direct drag/scrub/pinch tracks input without implicit animation; no spring lag while touching.
- First chart reveal ≤360ms, ring ≤420ms once per meaningful first load; refresh crossfades changed geometry in 100ms. Different datasets crossfade, never morph through invented observations. Tooltips follow directly with 80ms opacity only.
- Reduced Motion: no translation/scale/reveal, immediate state or ≤100ms opacity; preserve direct user manipulation. No perpetual idle animation; pause offscreen work; profile one build/device at a time.

## 7. Truthful state model, shared by all modules
| State | Presentation and behavior |
|---|---|
| Initial loading | Reserve likely populated layout; after 150ms show static skeletons; after 5s show “Still loading” with Cancel/Retry where safe; no fake values |
| Refreshing | Retain last valid content and geometry, one toolbar spinner; coalesce refreshes; show original timestamp until success |
| Live / observed zero | Real value and actual source time; zero is `0`, not a dash; “Live” only when connector and freshness contract permit |
| Partial / stale | Retain only permitted last-known values with “Updated …”/“Some sources unavailable”; explain affected source in details |
| Never connected | One compact 96–144-high setup region at default type; collapse absent chart/category scaffolding; one Connect action |
| Filtered empty | Preserve range/filter controls, explain “No transactions in this range”, offer Clear filters; never trap selection |
| Permission / expired access | “Reconnect [source]” or “Allow Health access”; no frightening technical error or endless Retry loop |
| Transport / validation error | Useful plain-language error, bounded retry; no stack trace, API command, raw response, key, account number, or document text |
| Saving / failed save | Prevent duplicate submission; success only after persistence; failed save retains draft and focus, with inline retry |
- Provenance details live behind a source/status disclosure; replace “reviewed source”, “durable storage”, “in-memory”, “quality unavailable” developer copy with user outcomes. Do not hide uncertainty needed to interpret a value.
- Demo data is an explicit visual-test mode with a compact persistent “Demo” badge; never production fallback. Screenshot fixture tests must be labeled; live acceptance uses actual connected data with private captures handled locally.

## 8. Home, Usage, and Clipper migration
- Home desktop reading order: compact title/action row → today's next event/task → Usage summary → two-column supporting Finance/Fitness/Clipper content. Reuse actual calendar/task data only; absent agenda shows “Nothing planned” with New event.
- Usage Home summary: 28 numeric, 13 unit, 72 ring or compact progress bar, provider rows with 5-hour/7-day windows. Avoid one enormous chart plus a line of detached rings; provider names and resets stay beside their values.
- Usage detail: provider selector + freshness in header; primary window number left and 112 ring right in a 160–184-high summary at desktop default type; weekly window below as a labeled bar. Status belongs outside the ring, never clipped inside it.
- Below summary: one 280-high desktop/200-high phone plot, title and range in its toolbar, compact legend below. Keep Graphs/Facts only if they expose distinct implemented content; move derived explanations into a disclosure, not a redundant Insights shell.
- Actual blue solid, estimate green dashed, target neutral dotted; y-axis unit explicit, one tooltip value/time with provenance. No available history means compact explanation; unavailable ranges cannot fabricate points. Providers' percentages are never summed.
- Clipper: connected account selector, three aligned metrics, one trend, then platform rows. Use real freshness and currency. Missing integration has one setup state, not fabricated audience/revenue.
- Screenshot migration checklist: [ ] shrink title/body/sidebar scale; [ ] replace huge LIFE OS lockup with 16pt wordmark; [ ] remove repeated subtitles; [ ] align left edges; [ ] replace icon mixture; [ ] remove oversized empty cards; [ ] remove repeated unavailable banners; [ ] fix clipped ring status; [ ] consolidate chart controls; [ ] remove route jump/reveal replay; [ ] audit actual live/demo launch path separately on native/web.
- Web-specific `main.tsx`: replace hardcoded “READ-ONLY · DEMO DATA”, “4 min”, demo-fresh labels, shell command errors, and assumed no-action-needed copy with typed source state. Independent source failures must not blank all modules through one shared loading gate. Do not imply a native-only feature exists in web.
- Web `styles.css`: replace 32/23/20 heading ladder, purple focus/metric colors, 6vw gutters, 45vh footer spacing, and four-column metrics at insufficient widths with this ledger. Expand compressed CSS into maintainable component sections during implementation.

## 9. Calendar: scrolling, magnification, and editing
- Preserve mobile three-day strip: today/tomorrow/day-after; one-day increments per swipe. One fixed 44pt time gutter, pinned date header, coordinated all-day/timed horizontal translation. Mac gutter 52; default week view with equal day columns.
- Timeline is one vertical scroll owner, 00:00–24:00 inclusive; default hour height 54, bounds 38–110 from current CalendarInteractionLayout. Bottom inset = actual obscuring navigation/safe-area height +16; unique 24:00 label and 23:45 event must be reachable.
- All-day lane preserves n+1 cells. Keep it separate from timed vertical scroll; large all-day lists get bounded dedicated disclosure rather than consuming the entire timeline viewport.
- Now indicator: one time label in gutter, one dot/line restricted to today's visible column; none if today absent. Avoid collision by hiding the nearby static hour label within 12pt. Never repeat current time across all days.
- Gesture arbitration: after 8pt movement, lock axis when |x| >1.25|y| for paging or |y| >1.25|x| for scrolling; ambiguous diagonal stays undecided, then defaults to scroll. Ordinary swipes over event bodies/resize affordances must still scroll until deliberate edit activation.
- Tap opens; double-tap empty time creates; long press 350ms then drag creates/moves, explicit edge-handle press then drag resizes. Snap commits to 15 minutes, show exact draft time while moving; cancel discards preview. During edit, disable day paging and use edge auto-scroll; preserve recurrence scope confirmation and DST rules.
- Mac pinch over timeline changes hour density: capture h0, offset0, focal y; t=(offset0+y)/h0; h=clamp(h0×magnification,38,110); offset=clamp(t×h-y,0,contentHeight-viewportHeight). Keep focal time within 2pt except at scroll bounds.
- Pinch owns magnification only; two-finger scroll owns scrolling, never changes route/month. Stop scroll momentum at pinch begin. Ignore pinch during active event mutation; cancelled pinch restores initial scale/focal offset. Commit density per scene only at gesture end.
- Remove the visible dotted slider/oversized thumb from screenshot. Secondary density menu offers Compact 38/Default 54/Comfortable 80 and Reset; no persistent zoom chrome. Month expand/collapse is a separate labeled toolbar action; do not overload timeline pinch with month expansion.
- At 38pt/hour short events may use a compact visual marker; selection opens full detail with ≥44pt phone hit affordance without invisible overlays blocking timeline scroll. Keyboard arrows/escape and undo preserve current editing behavior.

## 10. Finance, Fitness, Nutrition, Tax, and workouts
- Finance: title + account scope/updated status; balance 28/34; compact income/spend/cash-flow row; primary chart with intrinsic metric/range toolbar; categories 280-wide side panel only at content ≥880, otherwise below. Transactions follow as 44pt Mac/56pt phone rows with aligned amount/date.
- Empty Finance removes four identical “Not connected” cards and disabled chart-type/range stacks. Expose account connection once; show per-source errors only when distinct. Enable Banking and manual Trade Republic have separate provenance/timestamps; exclude PayPal. Imports preview duplicates and totals before save; never call imported data live bank sync.
- Fitness: one shared date header and source summary; recovery primary metric compact at 136–168 high; load/sleep and stress/reserve pairs only when widths permit. Replace colored rails and duplicated unavailable sentences with aligned labels, one number/status, optional trend.
- Biology: use same date control (previous/date button/next), never a raw numeric stepper as hero. Single “Experimental estimate” disclosure by the value with source/method details; unsupported biological age remains unavailable, never fabricated. Embedded Biology must not add a second header/scroll owner.
- Nutrition: daily kcal + protein summary, meal list, Add meal primary; photo capture inside Add meal only. Photo pending/error/editable estimate/manual entry all return to the same draft. Show estimate/confidence concisely; do not imply exact photo accuracy.
- Meal form: name full-width, kcal/protein/carbs/fat as label-above fields; 2 columns desktop, 1 phone; numeric value left aligned with unit suffix. Footer Cancel + Save meal; no competing preview/save CTAs. Preview edits the draft only; preserving that internal behavior does not require an “Apply local preview” button. Invalid fields show inline cause; save failure keeps draft; dirty dismiss confirms.
- Tax: document list with title, year/type, review status, trailing date; desktop details inspector, phone drilldown. Import progress/cancel above list; review fields grouped by identity/dates/amounts/evidence; masked identifiers; one concise review disclaimer. Failed load shows recovery state and blocks writes; export success describes actual result, never promises filing.
- Workout landing: Continue active session first, then templates and chronological history; primary Start workout, secondary New template. Template editor supports exercise search/add/reorder and planned sets/reps/load/rest without turning each value into a card.
- Active workout: compact elapsed/pause header, exercise accordion, rows Set | Previous | kg | Reps | Done (phone: Previous as secondary line). 44pt rows minimum, decimal keyboard, explicit unit, warm-up/work/drop-set distinction, one active numeric focus; scroll focused field above keyboard.
- Completing a set commits once, gives one subtle haptic/check transition, starts configured rest timer; timer survives backgrounding using timestamps. Rest strip has Skip/+30s; pause and finish are distinct. Offline save state stays visible; failed persistence cannot show completion.
- Finish opens summary of exercises/sets/volume/duration and incomplete-set confirmation; report separates LifeOS-entered sets from imported heart rate/calories. “Waiting for watch sync” is a real state; refresh/reconcile cannot duplicate the workout or overwrite edited sets silently.
- Zepp/watch data may augment a completed workout only when a supported source supplies it and matching is reliable; ambiguous matches need selection. No promise of Zepp-equivalent accuracy or recovered exercise/repetition data from unavailable APIs.

## 11. Calendar Projects / Obsidian scope preservation
- Keep issue-backed Projects mind-map work in scope without claiming implemented vault sync. Calendar toolbar Projects opens a separate canvas, not an overlay competing with timeline gestures.
- Canvas: desktop drag blank space/two-finger pan, pinch zoom 25–200%, node drag/reorder, labeled edge handles; phone two-finger pan/pinch and deliberate node long-press drag. One tap selects, second tap/Open note shows inspector sheet; no accidental edits while panning.
- Node toolbar: 6 semantic colors + neutral, rectangle/rounded rectangle/diamond, title, Open note; 12/16 text and ≥44pt interaction targets. Keep long content in the note inspector; retain selection and viewport on close.
- Storage compatibility is a separate contract: map shapes/edges to supported Obsidian Canvas `.canvas` fields and Markdown file references; flag unsupported shapes before save rather than silently corrupting interoperability. Vault folder, file conflicts, unavailable iCloud/Windows access, and unsaved edits require visible states and round-trip tests.

## 12. Widget contract
- Preserve existing widget families/destinations; audit each Usage/Calendar/Next Event/Finance/Fitness variant. Small: one primary value/event + state; medium: primary + ≤2 supporting values; large: overview + short list. Insets 16 small/medium, 20 large, subject to system content margins rather than double padding.
- Full-color clear/dark mode: white primary, #E6E6E6 supporting text, restrained black backing at 60% under essential content using current contrast policy. No grey-on-grey thin labels or low-opacity blue numbers. Never rely on outer container background surviving system removal.
- Test actual WidgetKit rendering modes; tinted/accented mode uses system-supported accent grouping, high-contrast shapes and labels, not an assumption that brand hex or backing opacity survives. If backing is removed, adopt a system-rendering-compatible foreground treatment and recheck on device.
- Widget type: value 26/30, title 13/17 medium, supporting 12/16; minimum 11 only for secondary timestamp. Units do not truncate values; unavailable dash is not a large fake metric; stale state must remain readable without color.
- Grey wallpaper matrix #606060/#808080/#A0A0A0 plus white stress case; measured composited contrast ≥4.5 text/≥3 graphics. Lock-screen accessory variants use system monochrome semantics; verify destination/deep link, not only appearance.

## 13. Worker sequence and acceptance evidence
- W1 foundation owns DesignTokens/Typography/LifeOSIcon/LifeOSMotionKit and shared component definitions; W2 shell/Home/Usage/Clipper owns OverviewView/CodexView/MacApp/ModuleNavigation and corresponding web surfaces after W1; W3 Calendar owns CalendarView/CalendarViews/CalendarLayout; W4 modules owns Finance/Fitness/Tax views; W5 widgets owns widget targets. Dispatch exact file lists and symbols, refresh line numbers before edits; these names are scope guidance, not permission for unassigned edits.
- Each worker preserves data logic, deletes superseded presentation only after migrating all call sites, avoids duplicate state/animation owners, and returns focused test results plus unresolved states. Bounded collections/visible-item rendering; cache derived aggregates by revision; no unbounded per-frame scans or network requests from view rendering.
- QA native Mac content viewports: 1440×900, 1280×800, 1024×768, 800×600; web CSS viewports same plus 390×844, 402×874, 430×932. iPhone simulator use actual iPhone 17 logical viewport (record size), plus compact 390×844 layout and landscape 844×390. Default and largest text setting must retain essential actions.
- Capture each Home/Usage/Clipper/Finance/Fitness/Biology/Nutrition/Tax/workout surface in populated live, observed-zero, never-connected, loading, stale, partial, and error states where applicable; use explicitly labeled fixtures for deterministic rare states. Test selected/hover/pressed/focused/disabled controls and keyboard-open sheets.
- Geometry acceptance: no clipped values/status/controls, no unintended horizontal scroll, aligned card edges within 1pt, one page title and source notice, no empty first-load chart scaffold >144pt, no text-size exceptions outside the ledger without review. Long names 80 characters, €1,234,567.89, 0 values, and missing reset times must fit/wrap intentionally.
- Calendar recordings: scroll from 00:00 to 24:00 starting over blank/event/resize areas; one-day swipe at slow/fast/diagonal input; only today's now marker; pinch at 38/54/110 around 09:15 and 23:45; cancelled edit/pinch, auto-scroll, DST transitions, and repeated rapid zoom/scroll. No header/gutter drift >1pt.
- Motion recordings: ten Home→Usage→Back and Home→Clipper→Back cycles, reverse at 60/120ms, refresh mid-transition, background/foreground mid-workout, keyboard dismissal, Reduce Motion. No replay, teleport, stale completion, duplicate gesture, or lost draft. Profile p95 frame time against device refresh budget (16.7ms at 60Hz / 8.3ms at 120Hz); record actual measurements, do not infer from code.
- Widget QA: each supported family × full-color/dark/clear/tinted × wallpaper matrix × live/stale/empty; simulator snapshots plus physical iPhone 17 Home Screen check. An image file existing is not evidence of inspection.
- Final report per tranche: source revision, actual viewport/device/mode/state, inspected screenshot/recording paths, expected/observed result, remaining defects. Independent Astra medium design review evaluates these artifacts; security reviewer evaluates security separately. No “world-class”, “flawless”, or complete claim without the checks; this authoring pass ran none of them.
