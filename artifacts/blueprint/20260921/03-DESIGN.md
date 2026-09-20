# Native design and motion contract
## Ownership
Typography.swift owns LifeOSTypography.Role; DesignTokens.swift owns colors/surfaces/shapes/LifeOSMotion.Timing.
LifeOSMotionKit.swift owns reusable animation lifecycle and content modifiers.
LifeOSInteractionKit.swift owns feedback/interaction helpers; LifeOSIcon.swift owns semantic symbol mapping.
No second token enum with duplicate values. New orb renderer consumes the same lifecycle conventions.
Use existing approved brand ramps. References inform behavior, not a CSS/React dependency.

## Typography, spacing and surfaces
|Role|Mac pt|iPhone pt|Weight|
|---|---:|---:|---|
|Page title|22|24|semibold|
|Section title|15|18|semibold|
|Card title|14|16|semibold|
|Body|13|17|regular|
|Label/button|13|15|medium/semibold|
|Metadata|12|13|regular|
|Primary metric|28|30|semibold|
|Compact metric|22|24|semibold|
These match existing roles. Remove ad-hoc 40–60pt dashboard values and duplicated page titles.
System font only; monospacedDigit for changing numbers; no fixed width that clips localized money.
Mac body can use 13pt; do not apply that size to phone forms. Dynamic type must expand/scroll, not clip.
Spacing 4/8/12/16/24/32/48; Mac card padding 16, phone 16; section separation 24.
Mac sidebar 208–232pt, content inset 24; content max 1280pt centered.
Main dark canvas #08090A, primary surface #121315, raised #1A1C1F; light canvas #F7F8FA, surface white.
Primary text dark #F5F5F7/light #17181B; secondary dark #A5A8AE/light #5E6269.
Borders dark white 8%, light black 8%; avoid borders around every nested value.
Shapes continuous radius 12 cards/8 controls/16 inspector content; nested radius max(0, outerRadius-inset).
Native sheets own their outer corners. ContainerRelativeShape only where an actual container provides geometry.
Materials only sidebar/toolbar/popover separation; no stacked translucent cards or permanent bloom.

## Color roles
Main brand #0253C4; interactive blue #036BFC with lighter existing-ramp foreground on dark when needed.
Income/success/estimate green #00B65D (readable light variant #60D386).
Loss/error red #E50019; secondary data teal #00B5B5; sleep violet #7539FF.
Calories orange #EF8600; warning amber #DFBB00. Forecast green dashed; target neutral dotted.
Provider identity retains existing palette; no second same-saturation blue to pretend distinct data.
Use shape/line pattern/label too, not color alone. Check text contrast in rendered surfaces.
Wallpaper transparency is WidgetKit-controlled; never hardcode an invisible card assuming wallpaper color.

## Token table (seconds; spring response is not a completion timer)
|Token|Contract|
|---|---|
|press/release/hover|easeOut .08/.14/.12, fill/opacity only|
|route|easeOut .16 crossfade, stable shell|
|selection|spring response .28 damping .90|
|hero|spring response .46 damping .88, shared semantic card only|
|panel|easeOut .24, content offset <=8pt|
|modal|native sheet; custom inner content .24 opening/.16 closing|
|numeric|easeOut .22 numericText|
|success|finite .40 settle → static check|
|error|keyframes 0,-3,+3,-2,+1,0pt over .22, field only|
|calendarSettle|spring .28/.92|
|chart|existing .72 one-shot stroke reveal; never y-value interpolation|
|ring|spring .45/.92 on first valid snapshot only|
|tracking|nil animation; direct coordinates|
|reduced|.10 opacity; final geometry immediate|
Keep current public aliases forwarding to tokens until all call sites migrated, then remove unused aliases once.
One transition completion uses animation completion/lifecycle generation, never sleep(duration).

## Interaction contracts
Route: one NavigationStack state owner; same route tap no-op; preserve per-route scroll/selection.
Hero: source card and detail use one namespace/ID; exactly one source; preserve source layout footprint.
If ownership cannot be continuous across native navigation, use stable crossfade; no screenshot-based host.
Do not morph unrelated full pages. Back restores prior list scroll and selection.
Chart: precompute path by snapshot+range revision; scrub index binary search O(log n), marker move O(1).
Calendar vertical scrolling and horizontal paging have separate recognizer ownership.
Mac pinch scale uses content under focal point, no slider. Wheel scroll remains vertical; keyboard +/- optional.
iPhone graph: two-finger pan/pinch; one-finger empty-canvas pan; long press 180ms then node drag.
iPhone calendar: vertical timeline scroll wins until horizontal intent exceeds 1.3 directional ratio.
Node drag consumes gesture only after recognition; cancelling restores committed origin.
Mac graph: trackpad pan, pinch, Space+drag, click select, Shift multiselect, Return edit, Escape cancel, Cmd-Z undo.
Gesture start invalidates prior settle UUID; direct movement starts at currently presented transform.
Zoom: world=(focal-oldTranslation)/oldScale; newTranslation=focal-newScale*world.
This corrects the research formula, which omitted division by oldScale when scale is absolute.
Clamp graph scale .25...2; no full-graph layout/rebuild during pan/pinch.
Keyboard focus visible; hover changes fill/foreground only, no universal hover lift.

## Orb
New LifeOSOrbState: idle, active(kind,generation), paused(kind,generation), completed, failed.
Kind: connecting/searching/working/solving. Solving used for calorie proposal only.
start creates generation; update preserves clock; completion accepted only for active generation.
After 180ms of real work show orb; fast completions skip it. No artificial minimum wait.
TimelineView(.animation(minimumInterval: 1/30, paused: ...)) owns one screen clock.
Canvas precomputes fixed points per kind/size; inline 24pt/64 dots, detail 72pt/192 dots.
Each frame O(D), D capped 192; memory O(D); no array sorting/JSON/I/O in frame closure.
Working = bounded rotating dots; connecting = two rings converge; searching = arc sweep; solving = phased orbit.
Normalized deterministic sine/cos transforms; maintain continuous phase across kind changes.
One active orb per screen; group status for concurrent tasks instead of one timer per task.
Pause on disappear, background, low power (static), Reduce Motion (static); cancel releases timeline.
Success changes to checkmark and status; failure changes to actionable text, never indefinite spinning.
Progress known? show real progress text/bar beside orb, never fabricated percentages.
Orb never in widgets, idle background, navigation, generic AI/Advisor, or every small request.
Performance budget: 60Hz interactions p95 <16.7ms frame; orb at 30Hz; no repeatable >33ms stalls.
Targets are to be measured later, not guarantees of current hardware performance.
