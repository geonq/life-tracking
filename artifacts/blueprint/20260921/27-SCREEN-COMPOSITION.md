# Screen composition and component ownership
Status: proposed implementation contract; no visual capture acceptance performed in this revision.
Every screen uses current semantic data/provenance and existing validators; no decorative empty metrics.
Shared component bodies P07; screen-specific rendering/state in original14 packet owner.

## Home — P16 OverviewView / application roots
One22pt Mac/24pt phone page heading. Sidebar208–232pt; max content1280 with24pt side inset.
Top today agenda full width: next event + today count + New. No giant title duplicate below toolbar.
Below: Mac two equal columns gap16; phone one column. Cards Usage,Finance,Fitness,Clipper by saved order.
Primary number28/30pt, label13/15, metadata12/13; card inset16; no fixed hero-height empty space.
OverviewLayoutContract computes columns(width:CGFloat)->Int:>=900=>2,else1 within content bounds.
OverviewMetricCard body orders title/status, value, supporting facts, disclosure; one actionable empty state.
Card to matching detail uses route identity; preserve source card footprint, scroll offset and focus on back.

## Usage — P12 CodexView / UsageRegistryDetailView
Header connection selector + period + refresh/Edit. Main value max28Mac/30phone with window label beside.
Thin8pt usage meter; reset/freshness below in flexible row; no centered truncated ring label.
Mac chart240–300pt/phone200–240pt; controls before chart, legend after. Facts as aligned key/value rows.
Hide unsupported automatic refresh, expose manual Edit timestamp; provider manager sheet supports order/pin/hide.
No empty fixed tiles for unused providers. Chart range state owned once by detail view model.

## Calendar — P08 CalendarView/CalendarViews
Mac sidebar + timeline + optional280pt inspector; phone timeline and native editor sheet.
Toolbar date previous/next/Today/New; display density controlled by pinch, menu keyboard alternatives.
Gutter width56Mac/48phone; one now label; no label per column. Day header remains outside vertical scroller.
Event minimum visual height18pt, hit target expands without extending event duration; overlapping columns sweep layout.
No external animation of scroll offsets during direct manipulation; zoom formula20 preserves focal instant.

## Finance — P09 FinanceView/Analytics/Recurring/Import
Header accounts/source status + import/refresh; consolidated balance and asOf single summary row.
Mac main chart2/3 width + category list1/3 at>=1000; otherwise stack. No disconnected giant plot frame.
Chart mode/range one compact control row; expense/income/cash/net worth share selected range.
Below: transactions and recurring, merchant/source/amount aligned. Manage Payment sheet cadence picker+Save/Cancel.
Import sheet: detected institution/account→preview diagnostics→confirm. Unknown format offers mapping, never forced match.
Net worth shows included/excluded accounts, valuation date/currency; partial is visible adjacent to total.

## Fitness/training — P10 FitnessView and module detail views
Recovery summary one primary value/source timestamp; related sleep/load/stress as compact two-column Mac cards.
Unsupported metric one concise explanation/link; no duplicate status paragraphs or empty circular ornament.
Training header Start/Resume; exercises as list with set rows(reps/load/completion), rest bar below current exercise.
Finish opens report after durable receipt; HealthKit export pending is separate small status.
History detail/edit preserves sets/order, no chart replacing core logging controls.
Biology labels experimental supported values clearly; no manufactured score/advice to fill space.

## Nutrition — P10 FitnessNutritionView
Daily totals + meal list + Add; Add menu Manual/Photo/Barcode/Recipe/Recent mapped to real capability.
Manual form fields left-aligned text, numeric trailing with unit label once; one primary Save, Cancel secondary.
Photo proposal shows image + editable item/portion/calorie range; confirm required, draft excluded from total.
No technical storage prose in normal form. Save error appears at action row retaining draft; never fake success.
Supplement/lifestyle/journal flows retain documented dose/inventory/factual observation semantics.

## Tax — P13 TaxDocumentsView
Mac240–320pt list + flexible detail; phone list→detail. Title/type/year and masked reference only collapsed.
Detail extracted fields then explicit original preview, export action in toolbar. Retention in Settings/detail footer.
No raw tax identifier/paragraph in notification, widget or collapsed preview. Errors actionable without raw payload.

## Planning — P06 PlanningCanvasView/NodeInspector/NoteView
Canvas fills remaining viewport; floating toolbar with Add,Connect,Fit,Layers;280pt Mac inspector.
Phone selection does not instantly open sheet; explicit Inspect opens sheet; double tap/Open note opens editor.
Nodes SwiftUI; edges/grid Canvas. Solid authored arrows, dashed derived links; layer toggle visible.
Shapes round rectangle/rectangle/capsule optional presentation extension; standard Obsidian rectangle fallback.
Note editor save/cancel explicit; external change retains draft and offers versions. No conflict auto-overwrite.
OS27 textSelection gestures enabled only in editor/preview, not draggable node labels.
Native text selection must not be preempted by canvas highPriorityGesture while editing.

## Widgets/lock screen — P14
Each registered kind mapped to exact source DTO and deep-link target in requirements ledger.
Small one primary value+short status; medium2–3 facts; large adds meaningful series, never developer paragraphs.
NextEvent accessoryRectangular time/title/location bounded; title truncates gracefully, tap correct event.
System containerBackground/ContainerRelativeShape; no guessed device-corner radius or transparent text on grey.
Normal/tinted/locked stale variants captured on actual phone; privacySensitive alongside explicit redacted payload policy.

## OS27 release-note consequences
P11 limited-history HealthKit permission is partial coverage, not empty/full authorization inference.
New HR/cycling zones only if actual source samples+SDK types verified; no proprietary Zepp equivalence claim.
P07/P16 inspect State init patterns: no declaration initializer plus different initializer assignment.
P06 node gestures versus newly selectable Text are explicit above; retain native editing gestures.
Mac menus may hide symbols under system policy; never force every menu icon for decorative consistency.
NSRefreshController is deferred; explicit refresh avoids another Calendar scroll gesture owner.
Storage capacity may be rounded; never assume reported free bytes are exact or promise write success from preflight.
