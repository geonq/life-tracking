# Revision5 typed deletion and calendar interaction contract
Supersedes empty-payload deletion in R4-03, the incomplete reducer context in R4-11/R4-16,
and generic domain deletion references in the R4 leaf tables. P01 owns shared deletion values;
P03 owns Calendar; P04/P06/P09/P13 own their typed domain adapters.

## Typed delete values
```swift
public enum DeleteScope: String, Codable, Sendable { case entity, calendarSeries, aggregate }
public enum DeleteReason: String, Codable, Sendable { case user, remoteUser, retention, revoke }
public struct DeleteIntent: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let entityID: String
 public let scope: DeleteScope; public let baseHead: String?; public let reason: DeleteReason
 public let requestedBy: String; public let logicalSequence: String
}
public struct TombstonePayload: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let tag: String; public let entityID: String
 public let scope: DeleteScope; public let deletedBy: String; public let deleteSequence: String
 public let baseHead: String?; public let cascadeEntityIDs: [String]
}
```
All fields are required (nullable `baseHead` is explicit null), version1, tags `deleteIntent`/`tombstone`, and
IDs/sequence use the R4 canonical rules. `cascadeEntityIDs` is sorted unique, <=1024, and is an explicit identity
list; no title/date/name matching. There is no valid empty payload for `commitReplicatedSeries` or any typed commit.
`DeleteIntent` is the signed operation input; the store creates `TombstonePayload` from the validated operation,
never trusts a remote wall-clock deletion timestamp. `reason` is the closed `DeleteReason` enum.

## CAS and replay algorithm
`resolveEntity(entityID:)` loads the current head and stable local identity under the store writer lock.
Existing entity requires `baseHead == currentHead`; absent entity requires `baseHead == nil`; otherwise return
`staleBase` and retain a conflict branch containing the intent. A matching operation hash returns its stored receipt
without another delete. A new valid intent writes the tombstone, entity head, inbox state and terminal receipt in one
transaction, then publishes. Repeating the same tombstone is a no-op receipt. A concurrent non-delete branch creates
`SyncConflict(deletionBranch:currentBranch:)`; it never silently wins by timestamp. A revoked/stale epoch is blocked
before the store transaction. Cancellation before commit changes nothing; after commit leaves the tombstone/receipt.

## Exact domain entry points
```swift
CalendarStore.commitReplicatedSeries(_ payload: CalendarSeriesPayload, operation: SyncOperation, generation: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResult
CalendarStore.commitReplicatedDeletion(_ intent: DeleteIntent, operation: SyncOperation, generation: UInt64, intentID: UUID) throws -> CalendarSeriesCommitResult
FinanceSyncAdapter.commitReplicatedDeletion(_ intent: DeleteIntent, kind: SyncStoreKind, operation: SyncOperation?) async throws -> SyncCommitReceipt
FitnessSyncAdapter.commitReplicatedDeletion(_ intent: DeleteIntent, kind: SyncStoreKind, operation: SyncOperation?) async throws -> SyncCommitReceipt
PlanningVaultStore.stageReplicatedDeletion(_ intent: DeleteIntent, operation: SyncOperation?) throws -> PlanningMutationReceipt
TaxDocumentStore.commitReplicatedDeletion(_ intent: DeleteIntent, operation: SyncOperation?) throws -> SyncCommitReceipt
```
The Finance/Fitness adapter resolves `kind` to the existing store: imported transactions, recurring overrides,
investment ledger, budgets, allocation rules, tracking preferences, training, templates, meals, goals, supplements,
journal, lifestyle, or barcode records. The adapter owns the typed dispatch; a caller cannot select a raw file path.
Calendar resolves `seriesID` from `entityID`, creates one tombstone for the series plus explicit item tombstones,
and leaves unrelated series untouched. Planning uses its journal and filesystem publication recovery; Tax only deletes
the sanitized publication record and local raw-cache index, never remote raw PDF/OCR bytes. Widget snapshots are
regenerated after the domain receipt and are never deletion authorities.

## Calendar gesture boundary
```swift
public enum CalendarResizeEdge: String, Sendable { case none, leading, trailing }
public struct CalendarBeginContext: Sendable {
 public let itemID: String; public let baseHead: String; public let original: DateInterval
 public let edge: CalendarResizeEdge; public let pointerOrigin: CGPoint; public let scaleOrigin: Double
 public let dayInterval: DateInterval; public let hourHeight: Double; public let scrollOffset: Double
}
public struct CalendarCommitIntent: Sendable {
 public let itemID: String; public let baseHead: String; public let original: DateInterval
 public let draft: DateInterval; public let edge: CalendarResizeEdge
}
```
`CalendarCoordinator.makeBeginContext(itemID:pointer:scale:)` reads the item and current replication head under one
read lock; missing/invalid/nonfinite input returns `invalidInput`. The reducer owns only the draft: `.begin(context:)`
captures all fields, update transforms the selected edge or whole interval, and `.end` returns a
`CalendarCommitIntent` only when `draft != original`. Cancel/Escape or an unchanged draft returns no intent and writes
nothing. P08 calls `CalendarCoordinator.commit(_:)`, which rechecks `baseHead` under the writer lock before invoking
`CalendarStore.commitReplicatedSeries`; mismatch returns `staleBase` and keeps the draft for conflict UI. A late
animation callback cannot commit because the reducer generation and intent ID must still match.

## Required acceptance cases
Series delete, item delete, replay, stale CAS, concurrent edit, tombstone restart, widget refresh, drag, leading/trailing
resize, cancel, unchanged drag, stale head during gesture, DST boundary, nonfinite gesture and disk-full must each show
the named result. No worker may use an empty payload, current time as a conflict winner, or a title-based identity lookup.

## Revision6 supersession
R6-06 replaces the optional-operation `commitReplicatedSeries` reference with the required operation/generation/intent-ID
signature, adds the receipt result wrapper, and separates viewport ownership from item gestures. Its formulas and context
are authoritative for Calendar implementation.
