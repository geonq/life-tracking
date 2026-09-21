# Exact design and interaction amendments
P07 owns tokens/helpers; original03 values remain unless expressly changed below.

## Implementable token mapping
Typography.swift LifeOSTypography.Role: pageTitle22/24, sectionTitle15/18, cardTitle14/16,
body13/17, label/button13/15, metadata12/13, metric28/30, metricCompact22/24 (Mac/iPhone pt).
Use existing role modifier; semibold titles/metrics/button, regular body/meta, medium label.
No new .font(.system(size:)) in product views; metric width flexible, monospaced digits, no lineLimit1 on money.
Space tokens4/8/12/16/24/32/48; card16 inset; sections24 apart; Mac content24 inset/max1280.
Continuous card radius12, control8, panel16; nestedRadius(outer:inset:)=max(0,outer-inset).
Stroke=1/displayScale physical pixel, dark white8%/light black8%; selection stroke1.5pt semantic tint.
Elevation: cards none; floating popover black12% blur12/y4; never perpetual glow.
Dark canvas08090A/surface121315/raised1A1C1F/textF5F5F7/metaA5A8AE.
Light canvasF7F8FA/surfaceFFFFFF/text17181B/meta5E6269.
Brand ramp verified colors.md: main0253C4/action036BFC/bright5DA0FD; no invented second category blue.
On dark, action label uses5DA0FD when necessary for contrast; filled blue button needs measured foreground contrast.
Income/success/estimate green00B65D (dark foreground60D386); lossE50019; secondary00B5B5;
sleep7539FF/caloriesEF8600/warningDFBB00; foreground contrast chooses existing light/dark pair.
Usage actual blue/estimate green dashed/target neutral dotted; provider identification by label, not competing blues.
SF Symbols through LifeOSIcon only: home house, calendar calendar, finance creditcard, fitness heart,
tax doc.text, planning point.3.connected.trianglepath (CP-C verifies symbol; fallback square.grid.2x2).
Mac nav glyph18pt/row36pt; phone glyph20pt/hit44pt; regular weight, hierarchical rendering.

## Named motion APIs (P07 additions in existing motion files)
LifeOSMotion.Timing.route=.16, panel=.24, numeric=.22, success=.40, error=.22 seconds.
LifeOSMotion.animation(for: LifeOSMotionRole, reduceMotion: Bool) -> Animation?
LifeOSMotionRole: press, release, hover, route, selection, hero, panel, numeric, success, error, calendarSettle, tracking.
press/release/hover easeOut .08/.14/.12; selection spring(response:.28,dampingFraction:.90).
hero spring(.46,.88); calendarSettle spring(.28,.92); tracking=nil.
Reduced motion: geometry immediate, opacity.10; low power: no orb timeline, no decorative chart/ring reveal.
Native sheet owns outer presentation; never add a second whole-sheet scale animation.
Numeric contentTransition(.numericText()) only accepted revision change; status opacity; symbol replacement for result.
Error keyframes0,-3,+3,-2,+1,0pt at0,.04,.08,.13,.17,.22s; invalid field only.
No sleep(duration) for completion; generation-owned lifecycle and animation completion callback.
start new gesture invalidates prior settle; latest displayed geometry becomes starting transform.
No animation completion callback commits domain state. User action commits; animation merely reflects result.

## Orb executable geometry contract (P07 LifeOSOrb.swift)
LifeOSOrbKind: connecting, searching, working, solving; solving allowed only for calorie-photo processing.
LifeOSOrbGeometry.make(kind: LifeOSOrbKind, diameter: CGFloat) -> [LifeOSOrbParticle].
LifeOSOrbParticle Sendable value: phase/radius/speed/dotRadius/opacity as Double; deterministic seed constant.
Inline20pt uses48 dots, hero64pt uses192. Never allocate particle arrays in frame callback.
Particle i: phase=2π*i/N; ring=(i%3+1)/3; baseRadius=.38*diameter*ring.
Position(t)=center+r(t)*(cos(phase+speed*t),sin(phase+speed*t)); speed=.6rad/s connecting,.9 searching,.5 working,.35 solving.
r(t)=baseRadius*(1+.04*sin(.8*t+phase)); opacity=.35+.45*(.5+.5*sin(t+phase)).
No randomness each frame, blur/glow, Canvas text or hit targets. This is a proposed native interpretation, not copied renderer parity.
TimelineView(.animation(minimumInterval:1/30,paused:...)); one visible orb per screen; O(N) fixed bounded dots.
Show only if explicit operation lasts>=200ms; hide on result without enforcing artificial minimum duration.
State reducer accepts event+generation; stale result ignored; inactive scene/offscreen/reduced/lowPower static t=0.
Status label outside Canvas says real operation; no generic thinking/advisor text.
Success replaces orb with static check; error with actionable message; cancelled returns idle.

## Viewport functions (P06 PlanningCanvasViewport)
worldPoint(screen:CGPoint)->CGPoint=(screen-translation)/scale.
screenPoint(world:CGPoint)->CGPoint=translation+scale*world.
zoom(to:CGFloat, around:CGPoint): world=worldPoint(focal), newScale=clamp(.25...2), translation=focal-newScale*world.
pan(by:CGSize) changes translation; fit(bounds:CGRect,in:CGSize,padding:CGFloat=32) clamps scale, centers bounds.
Reject nonfinite or zero viewport/scale; empty fit returns scale1/translation.zero; never NaN.
Gesture update changes transform only; visible query uses world viewport+64screen-point overscan.
Node drag delta=(pointer-currentStart)/gestureStartScale; selection<=256; no global index rebuild until commit.
Space+drag pans Mac; trackpad wheel pans canvas, pinch zooms about local pointer centroid.
iPhone empty one-finger pan; two-finger pan/pinch; node long-press180ms then drag; movement>8pt before recognition pans.
Recognizer owner locked until end: editing > connector > nodeDrag > viewport; Escape/cancel discards preview.
P06 bridge owns gestures; never install both SwiftUI and platform recognizers for same input simultaneously.

## Calendar functions (P08 CalendarViewportTransform)
timeAt(y:CGFloat)->TimeInterval; offsetFor(time:TimeInterval)->CGFloat; zoomAt(focalY:CGFloat,scale:CGFloat).
Use elapsed-time coordinates within each actual day interval; DST days can be23/25h, not fixed86400s.
hourHeight clamp40...160pt; retain instant at focalY by recomputing scroll offset after scale change.
Directional lock after8pt: horizontal if abs(dx)>1.3*abs(dy), vertical otherwise; hold owner to end.
Vertical UIScrollView/NSScrollView owns timeline; pinch cannot trigger page drag/create gesture.
Now line in today column only; single gutter time label; wall clock update once/minute while visible.
Auto-scroll one task at display cadence; max600pt/s, edge zone32pt; cancellation stops before commit.
