# Packet D — Obsidian graph and native Canvas interaction

Prepared by Astra Medium from current `4b170a8` on 2026-09-19.
Packet C is accepted locally; this packet does not claim iCloud, signed-device,
physical-gesture, gateway, Windows, or whole-app release acceptance.

## Source constraints

- Canvas models preserve unknown fields, numeric extension lexemes, ordering,
  and the supported `file`, `text`, `link`, and `group` node types.
- Markdown preserves source/frontmatter but does not extract links. Graph
  projection must scan links without rewriting Markdown.
- `PlanningVaultStore` exposes bounded read/stage/publish/recovery/conflict
  APIs, but no project catalogue. The caller supplies a bounded catalogue.
- `resolveCanvasReference` stays inside the selected `LifeOS/` boundary.
  Outside, ambiguous, external, and not-yet-loaded references remain explicit;
  this packet must not add a recursive vault crawl or a second resolver.
- Native views belong in `ios/LifeOS/Modules/Planning/`. Existing XcodeGen
  directory membership covers both app targets and excludes widgets.

## D1 — projection, index, edit reducer, and session

Only one Luna worker may write this slice. Exact allowlist:

- `ios/Planning/PlanningMarkdownLinks.swift`
- `ios/Planning/PlanningGraphProjection.swift`
- `ios/Planning/PlanningSpatialIndex.swift`
- `ios/Planning/PlanningCanvasEdit.swift`
- `ios/Planning/PlanningCanvasSession.swift`
- `ios/LifeOSMacSnapshotTests/PlanningGraphTests.swift`
- `ios/LifeOSMacSnapshotTests/PlanningCanvasSessionTests.swift`
- `ios/LifeOSTests/PlanningGraphTests.swift`

### Link scanning and graph projection

Implement `PlanningMarkdownLinkScanner.scan(source:) -> PlanningLinkScan` as a
bounded UTF-8 scanner. Return occurrences, source ranges, raw targets, aliases,
anchors, embed flags, and unsupported-syntax diagnostics. Recognize wikilinks,
embeds, inline Markdown links, and reference links. Ignore fenced/inline code
and comments. Do not use a backtracking regex over arbitrary document text.

Define `PlanningProjectInput` with Canvas path/document/original bytes/content
version, supplied note snapshots, vault identity, and access generation.
Define `PlanningProjectGraph` with ordered Canvas instances, semantic note
identities, authored edges, derived link occurrences, unresolved references,
adjacency, and bounds.

`PlanningGraphProjector.project(_:)` retains every Canvas node and edge, keeps
separate Canvas instances that reference one note, and keeps derived Markdown
occurrences separate from authored Canvas edges. `PlanningReferenceResolver`
uses exact validated paths first and unique basename resolution only within the
supplied catalogue; ambiguity returns candidates. Keep anchors/subpaths and
make “catalogue not loaded” distinct from “missing”. Never silently launch
external URLs or read outside the selected boundary.

### Edits and persistence session

Define `PlanningCanvasEdit` for move, resize, insert/delete node,
insert/delete/reconnect edge, set label/color, and replace Markdown source.
Each command stores inverse data. `PlanningCanvasReducer.apply(_:to:)` must
reconstruct validated models while preserving untouched fields, extension
dictionaries, array order, and IDs. Deleting a node removes its authored
incident edges in the same undoable command; derived links remain Markdown
authority. Reject type conversion that would silently lose incompatible data.

Add `PlanningCanvasPersistence` and a `PlanningVaultStorePersistence` adapter
using the existing Packet C APIs unchanged. Add `@MainActor
PlanningCanvasSession` with `load`, `beginInteraction`, `updateInteraction`,
`cancelInteraction`, `commitInteraction`, `commitInspectorEdit`, `undo`,
`redo`, and `refresh`.

Decode/project/index work runs off the main actor and returns immutable results
tagged with document revision and access generation. Discard stale results.
Pointer frames are transient only: zero encoding, journal writes, publication
calls, or vault reads per frame. Pointer-up or inspector Save creates one
validated command and one immutable mutation request. Cancelled/no-op gestures
create none. Stage before reporting “Saved on this device”; publication status
stays separate. Undo/redo are new mutations against the current accepted
version, never reused journal IDs. Bound history to 100 commands and 16 MiB.

### Spatial index contract

Define V as graph vertices, E as authored edges plus link occurrences, and B
as scanned source bytes. Parsing is O(B); projection/index rebuild is O(V+E).
Implement `PlanningSpatialIndex.rebuild(nodes:edges:)`,
`queryNodes(in:)`, `queryEdges(in:)`, and `hitTest(_:tolerance:)` with separate
node/edge bounds. A fixed-width Morton-key radix build with packed BVH is the
candidate implementation; comparison sorting is not acceptable for the stated
linear rebuild target. Quantize only index keys, never persisted coordinates.

Instrument visited nodes, candidates, and results. Test clustered, coincident,
huge, thin, negative, and offscreen geometry. State the real worst case:
overlapping rectangles can force linear traversal. If strict worst-case
O(log V+k) is required, stop acceptance and request a separate index design;
do not redefine k to hide candidates. Bound input to 32 MiB, 10,000 vertices,
and 40,000 relationships with explicit capacity/partial-catalogue state.

## D2 — native Canvas and inspector

D2 starts only after Astra accepts D1. Exact allowlist:

- `ios/LifeOS/Modules/Planning/PlanningCanvasView.swift`
- `ios/LifeOS/Modules/Planning/PlanningCanvasViewport.swift`
- `ios/LifeOS/Modules/Planning/PlanningCanvasGestureBridge.swift`
- `ios/LifeOS/Modules/Planning/PlanningNodeInspector.swift`
- `ios/LifeOS/Modules/Planning/PlanningCanvasStyle.swift`
- `ios/LifeOSMacSnapshotTests/PlanningCanvasViewTests.swift`
- `ios/LifeOSMacSnapshotTests/PlanningCanvasInteractionTests.swift`
- `ios/LifeOSTests/PlanningCanvasInteractionTests.swift`

D2 may modify D1’s session only to connect reviewed interaction events; model
or storage changes reopen D1 review. `PlanningCanvasView` is a SwiftUI shell
with virtualized node overlays, a drawn edge layer, a compact toolbar, and one
selection authority. `PlanningCanvasViewport` exposes `worldToScreen`,
`screenToWorld`, `pan`, `zoom(around:to:)`, `fitSelection`, and `reset`, with
25–200% zoom. Focal zoom preserves the world point under the pinch centroid:
for `p = world*s+t`, set `t' = p-world*s'`.

Mac uses blank-space drag/two-finger scroll for pan and trackpad magnification
around the local pointer. iPhone uses two-finger pan/pinch, tap selection, and
deliberate long-press-then-drag for nodes. A pinch beginning during a node drag
cancels the uncommitted drag before viewport ownership transfers. Inspector
input, text selection, and scrolling must not be intercepted. Locked nodes
cannot move. Edge handles preview endpoint/side/arrow/label/color changes and
commit only valid drops. Mac uses a compact trailing inspector; iPhone uses a
native sheet. Keyboard Escape cancels, Delete removes selected editable items,
Command-Z/Shift-Command-Z undo/redo, and Return opens detail without stealing
text-editor shortcuts.

Use existing `LifeOSTypography`, `DesignTokens`, SF Pro/system roles, semantic
SF Symbols, and existing motion primitives. Keep Mac hierarchy compact, phone
actions at least 44 points, imported/custom Canvas colors exact until changed,
and selection as outline/handles rather than destructive recoloring. Motion
tracks input without spring lag; transitions are short and interruptible.
Reduce Motion removes decorative travel/overshoot while preserving direct
feedback. Test dark contrast and grey backdrops where translucency exists.

## Verification and stop conditions

- Graph tests cover repeated instances, groups, edge order, unknown numeric
  extensions, Markdown preservation, aliases/anchors, ambiguity, missing and
  outside references, malformed and bounded input.
- Index tests compare every query to brute force, include extreme geometry,
  and instrument scaling to 10,000 nodes/20,000 authored edges.
- Session tests prove 1,000 drag updates cause zero writes, release causes one
  stage/publication, cancel/no-op cause none, and undo/redo/conflict/restart/
  stale-generation preserve evidence.
- D2 tests cover focal zoom, transformed dragging, ownership transfer, locked
  nodes, reconnect cancellation, inspector isolation, interruption, dark/light
  snapshots, compact phone, long labels, unavailable/conflict, and Reduce
  Motion states. Native captures and gestures are required; reducer tests alone
  do not certify trackpad/touch behavior.
- Run the storage guard, `xcodegen generate --spec ios/project.yml`, serial
  focused Mac tests with fresh owned result paths, and the generic iOS build.
  When a simulator is unavailable, record runtime unverified. Keep ≥15 GiB
  free and one Apple worker/build lane at a time.
- Stop for scope outside the allowlist, loss of unknown fields, unsupported
  shape claims, unbounded scans, unsafe paths, false save status, or unresolved
  index-complexity claims. Calendar registration, live-vault/iCloud round trip,
  gateway/Windows transport, outage recovery, signing, and physical gestures
  remain separate gates.
