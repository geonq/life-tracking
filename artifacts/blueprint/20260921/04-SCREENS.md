# Screen-specific composition and behavior
All screens implement live/loading/empty/stale/error/partial and keyboard/focus behavior.
Use concise product copy: “Connect account”, “Last synced …”, “Saved on this device”.
Remove “reviewed source”, “durable storage”, internal fixture lineage and developer explanations from normal UI.
Actual absence is not zero. Demo data is explicit development-only; live data remains normal launch behavior.

## Home
Compact header title “Today” with date, refresh state and no duplicate LIFE OS wordmark in content.
Desktop top row: agenda 2/3 width, next action/status 1/3; second row Finance/Fitness/Usage compact cards.
Phone: next event, day agenda, compact summary rows; no 500pt hero card.
Metrics grouped by meaning, one primary number per card; details reveal on deliberate click.
Usage provider row does not reserve empty circles for unconnected providers.
Clipper preserves real collector values and drilldown; no fabricated revenue/trends.
Navigation card hit area includes card but nested controls remain independently operable.

## Calendar
Maintain current day/week/month modes and recurrence/exception/holiday semantics.
Exactly one now-line in the current-day column; time label in gutter, never repeated across weekdays.
Scroll full 24-hour grid with stable hour gutter; initial focus near now; manually chosen position persists.
Mac pinch adjusts hour height 40...120pt anchored at pointer time; no visible scale slider.
Horizontal date navigation stays distinct from vertical timeline scroll.
Create/edit/move/resize/duplicate/delete/undo; overlap layout deterministic; timed/all-day separate.
Event editor: title then dates/timezone/recurrence; one primary Save, Cancel; inline validation.
Dragging near edge autoscrolls from a single display callback; stops on exit/cancel/end.
Planning entry sits in Calendar toolbar/section, preserving calendar selection when returning.
Calendar native external/reminders connections retain source authority and explicit write permissions.

## Finance
Desktop: title + account switcher + “Import”; compact net-worth/balance summary (not huge empty hero).
Next row chart (2/3) + upcoming recurring list (1/3); transaction table beneath, filters in one toolbar.
Phone: summary, single chart, recurring preview, transaction list; details in native sheet.
Chart modes appear only when meaningful for selected metric; no ring view for time-series just to fill space.
One range control, title/value aligned; source status in one quiet footer; no repeated unavailable cards.
No connection: compact connection action + explanation; preserve imported transactions and holdings below.
Manage Payment sheet: cadence weekly/monthly/yearly/nonrecurring, next date, matching merchant/account, amount tolerance.
Detector suggestions distinguished from confirmed rules; user override wins; history/provenance accessible.
CSV flow: choose file → detected firm/confidence → mapping if uncertain → preview → commit summary.
Robinhood activity is investment activity; transfer to broker not counted as investment loss or spending twice.
Net worth shows excluded/stale components; exact currencies and valuation timestamps visible.

## Fitness and biology
Today overview: recovery only if sourced, sleep, activity, training action; no wall of unavailable tiles.
Desktop compact two-column data groups; phone one meaningful card per section.
Unknown readiness displayed as a compact missing-source row; avoid duplicate “Unavailable” explanation.
Training: template picker, exercises/sets/reps/load, rest timer, finish, history, editable native report.
Workout completion durable immediately; HealthKit export/reconciliation is separate status.
Biology: explain only actual metric limits near detail; remove empty giant “experimental age” card from overview.
Retain an explicit unavailable detail row for required unsupported metric so scope is visible.
Sleep/stress/energy views share metric header/period control; source-authored facts under “Observations”.
No “Coaching”, recommendation engine, Advisor, chat entry or fabricated proprietary scores.
Lifestyle/supplements retain existing schedules, local logs, history, notifications and corrections.

## Nutrition
Manual meal sheet width 440...520pt on Mac; phone system form/full sheet.
Single vertical form: name, energy, macros; label above or aligned column, consistent field widths.
Primary “Save meal”, secondary Cancel. Remove “Apply local preview” from ordinary manual entry.
Photo: select → processing orb → editable proposal → Save meal.
No photo claim before analysis; unconfirmed proposal excluded from daily totals.
Saving ends sheet after durable receipt; error retains form; retry preserves operation ID.
Barcode, goals, meal history, corrections and supplements remain existing functional scope.
Do not rewrite factual manual input as AI-derived data.

## Usage
Header selected connection + window + refresh; 28pt max main metric on Mac.
Thin usage meter and reset time beside it; remove oversized ring with truncated centered status text.
Chart gets useful area (Mac 240...300pt high); legend below; controls grouped above.
Provider manager supports add/hide/pin/reorder and separate product types.
Gemini subscription manual reading shows timestamp; API metering separately labelled.
Claude remains available but hidden if unused; no fixed empty slot.
Graph/facts sections share range state; unavailable range disabled with reason.
Use orb only if a real explicit refresh exceeds delay; manual entry opens immediately.

## Tax and Settings
Tax: documents list + detail preview, extraction fields, export action, retention/privacy control.
Do not expose raw identifiers on collapsed cards/notifications/widgets.
Settings: connections, sync status/queue/conflicts, paired devices, vault picker, appearance, automation/signing.
Show Mac and Windows independently; reconnect now button; last applied vs last contacted distinct.
Pairing screen requires fingerprint confirmation; no auto-accept discovery.

## Planning
Full available content canvas, floating compact toolbar, 280pt Mac inspector.
Phone inspector is sheet; selecting node does not immediately obscure canvas.
Canvas standard nodes/groups/colors/arrows plus “Open note”; note body in native editor/preview.
Presentation shape choices support round rectangle/rectangle/capsule as LifeOS extension, with standard rectangular Obsidian fallback.
Do not claim custom shape equality in stock Obsidian; nodes/links/content must remain usable there.
Solid authored arrows vs subdued dashed derived links; toggle derived layer to avoid clutter.
Double-click/Return opens note; URL opens only explicit http/https user action.
Text nodes and groups preserve original order; connect handle never silently rewrites note content.
No automatic force layout moving authored nodes; Fit and explicit tidy command may be separate future scope.

## Widgets
Retain registered catalog + accessoryRectangular next-event Lock Screen widget.
Next event: time, title, short location; calendar tap deep-links to correct item/date.
Small widgets one primary metric, no developer status paragraphs; unconnected state one action.
Grey wallpaper/dark/tinted/default modes get actual captures; system tint may override accent semantics.
Privacy-sensitive details redact when locked; placeholders remain useful and unobtrusive.
No timelines for decorative animation; publish only when snapshot digest changes or meaningful time boundary.
