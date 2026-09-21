# Revision6 Calendar commit and gesture contract
Planning-only. This supersedes the R5 optional-operation and incomplete gesture signatures.

## Canonical commit values
```swift
public enum CalendarResizeEdge: String, Codable, Sendable { case none, leading, trailing }
public struct CalendarBeginContext: Sendable {
 public let intentID: UUID; public let generation: UInt64; public let itemID: String?
 public let baseHead: String?; public let originalInterval: DateInterval?; public let resizeEdge: CalendarResizeEdge
 public let pointerOrigin: CGPoint; public let scaleOrigin: Double; public let dayInterval: DateInterval
 public let hourHeight: Double; public let scrollOffset: Double
}
public struct CalendarCommitIntent: Sendable {
 public let intentID: UUID; public let generation: UInt64; public let itemID: String
 public let baseHead: String; public let originalInterval: DateInterval
 public let draftInterval: DateInterval; public let resizeEdge: CalendarResizeEdge
}
public struct CalendarSeriesCommitResult: Sendable {
 public let receipt: SyncCommitReceipt; public let generation: UInt64; public let intentID: UUID
}
```
Viewport contexts have `itemID == nil`, `baseHead/originalInterval == nil`, and `resizeEdge == .none`; an item
context has all item fields. Dates are finite, end > start, hour height is 32...240, scroll is finite, and the
generation is monotonic per `CalendarCoordinator` task. `baseHead` is the exact head read with the original interval.

The one replicated series entry point is:
```swift
public func CalendarStore.commitReplicatedSeries(
 _ payload: CalendarSeriesPayload, operation: SyncOperation, generation: UInt64, intentID: UUID
) throws -> CalendarSeriesCommitResult
public func CalendarStore.commitReplicatedDeletion(
 _ intent: DeleteIntent, operation: SyncOperation, generation: UInt64, intentID: UUID
) throws -> CalendarSeriesCommitResult
```
Both validate the operation/domain/store, recheck the base head inside the writer transaction, create the domain
`SyncCommitReceipt`, inbox terminal state and widget projection, then return the same receipt plus correlation fields.
Local edits use the existing local CalendarStore command and are never routed through a replicated entry point.

## Reducer and ownership signatures
```swift
public enum CalendarGestureTarget: Sendable { case viewport, item(id: String, edge: CalendarResizeEdge) }
public struct CalendarDraftState: Sendable {
 public let context: CalendarBeginContext; public let draftInterval: DateInterval?
}
public struct CalendarUpdateInput: Sendable { public let pointer: CGPoint; public let scale: Double }
public struct CalendarInteractionReducer: Sendable {
 public static func begin(_ context: CalendarBeginContext) throws -> CalendarDraftState
 public static func update(_ state: CalendarDraftState, _ input: CalendarUpdateInput) throws -> CalendarDraftState
 public static func finish(_ state: CalendarDraftState) throws -> CalendarCommitIntent?
 public static func cancel(_ state: CalendarDraftState) -> CalendarDraftState
}
public func CalendarCoordinator.makeBeginContext(
 target: CalendarGestureTarget, pointer: CGPoint, scale: Double, generation: UInt64
) throws -> CalendarBeginContext
public func CalendarCoordinator.commit(_ intent: CalendarCommitIntent) async throws -> CalendarSeriesCommitResult
```
`makeBeginContext` reads the selected item's interval/head under one read lock. `finish` returns nil for viewport,
nonfinite input, unchanged interval, cancelled gesture or a superseded generation. It returns an intent only when an
item draft differs from its original. `commit` checks the coordinator generation and intent ID before awaiting, then
rechecks generation/base head immediately before calling the canonical CalendarStore function. `staleBase` preserves
the draft for conflict UI; duplicate intent returns its stored receipt; cancellation before the store transaction writes
nothing, after commit returns the durable receipt.

## Gesture ownership and formulas
`CalendarViewportController` alone owns horizontal paging, vertical scrolling and trackpad/iPhone viewport pinch.
`CalendarItemInteractionController` alone owns item hit-testing, drag and leading/trailing resize. A viewport gesture
cannot create an item intent and an item gesture cannot page or change global scale.

For viewport pinch, `timeAtFocal = (focalY + scrollOffset) / hourHeight`; then
`newHeight = clamp(oldHeight * scale, 32, 240)` and `newScroll = timeAtFocal * newHeight - focalY`.
The transform is applied continuously with bounded state and no store write. A horizontal page changes day index only;
scroll changes `scrollOffset` only. Item drag translates the original interval by the snapped pointer delta; resize
changes only the selected edge and clamps to minimum 5 minutes. End commits once through the reducer; interruption,
scene phase loss, Escape, cancelled task or a new begin calls `cancel` and restores the original preview.

## Acceptance evidence
Evidence must separately exercise Mac pinch/scroll/page, iPhone pan/pinch/drag/resize, DST boundaries, overlapping
items, unchanged/cancelled gestures, stale head, duplicate intent, generation race, nonfinite pointer/scale and disk-full.
No animation callback, viewport transform or widget reload may call a commit function.

## Revision7 supersession

R7-04 is the final Calendar contract. It preserves the full begin context and viewport/item separation, but replaces
the ambiguous local command with `commitLocalSeries`/`commitLocalDeletion`, which allocate a durable `SyncOperation`
inside the local transaction before publishing.
