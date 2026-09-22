# P06-B mounted picker and vault round-trip plan

Updated 2026-09-22 Europe/Berlin. Base: `afce4ed`. This is a bounded plan
for native presentation evidence after the chooser checkpoint `433ea64`.
Release remains NO-GO.

## Contract

- Accept exactly one existing `.canvas` or `.md` beneath the attached vault's
  exact `LifeOS/` directory. `PlanningVaultStore.resolveSelectedDocument` stays
  the authority for containment, traversal, query/fragment, extension,
  symlink, generation, and bounded-read checks.
- Do not enumerate, index, edit, publish, network-read, or add CP-B behavior.
- Keep the current Canvas/project/selection/viewport mounted through picker
  presentation, cancellation, validation failure, and Markdown preview.
- Markdown remains a read-only standalone preview. Back returns to the retained
  Canvas or to the ready state without manufacturing a project.
- Every async terminal path resumes once; late or stale results publish nothing.

## First implementation packet

Only these files may change:

- `ios/Planning/PlanningNativeDocumentPicker.swift`
- `ios/LifeOS/Modules/Planning/PlanningWorkspaceView.swift`

Presentation invariants:

- Add an internal MainActor phase (`idle`, `presenting`, `dismissing`,
  `finished`) to each native picker coordinator. Only idle may start.
- Keep singleton lifetime ownership until native dismissal completion. Capture
  the first terminal result and ignore duplicate delegate/cancel callbacks.
- Cancellation returns nil, creates no visible error, and never dismisses a
  controller or sheet the coordinator did not create.
- SwiftUI picker actions guard `pickerTask == nil`; they never cancel-and-
  replace a live picker. Disable all picker/document retry/open controls while
  a picker task is active. Done and disappearance cancel the owned task and
  invalidate its generation.
- iOS retains the mounted presenter through completion, handles interactive
  dismissal via `UIAdaptivePresentationControllerDelegate`, and clears a
  presenter bridge only if it is still the current bridge-owned presenter.
- macOS requires a visible host window with no attached sheet, uses an async
  sheet, and releases lifetime ownership only after `endSheet` completion.
  Host closure and task cancellation settle the owned panel once.
- Add stable identifiers: `planning-picker-error`,
  `planning-document-retry`, `planning-workspace-canvas`, and
  `planning-note-source`.

## Second implementation packet

After the first packet is reviewed, only these files may change:

- `ios/LifeOS/Modules/Planning/PlanningCanvasView.swift`
- `ios/LifeOSMacSnapshotTests/PlanningWorkspaceTests.swift`
- `ios/LifeOSTests/PlanningWorkspaceTests.swift`

Add instance-scoped DEBUG-only viewport and mounted-workspace probes. The
viewport probe must drive the same setter as native input and report every
change; no persistence or public behavior changes. Use hosted `NSWindow` and
visible `UIWindow` tests, controlled picker closures, continuations, and no
fixed sleeps. Tests must close their own host and cancel tasks.

Required mounted tests in both suites:

```text
testMountedDocumentPickerRejectsDuplicatePresentation
testMountedDocumentPickerCancellationPreservesCanvasViewport
testMountedDocumentPickerFailurePreservesCanvasViewport
testMountedDocumentPickerUnmountCancelsAndIgnoresLateSelection
testMountedDocumentPickerCanReopenAfterCancellation
testMountedDocumentPickerErrorIsVisibleAndClearsOnSuccess
testMountedPickedMarkdownBackPreservesCanvasViewport
testMountedStandaloneMarkdownPreviewBackReturnsToReady
testMountedRealVaultChooserRoundTripDoesNotMutateVault
testMountedRealVaultChooserRejectsSiblingAndSymlink
```

Platform presentation tests:

```text
testMacDocumentPickerUsesOwningWindowSheet
testMacDocumentPickerRejectsOccupiedSheet
testMacDocumentPickerHostClosureSettlesCancellation
testIOSDocumentPickerUsesMountedPresenter
testIOSDocumentPickerRejectsOccupiedPresenter
testIOSDocumentPickerInteractiveDismissalSettlesCancellation
```

Viewport assertions must use a nonidentity value such as translation `(137,
-83)` and scale `1.35`, then verify exact values after cancel, failure,
Markdown Back, and retained-project routing.

## Vault evidence

Use a unique temporary root and isolated application-support directory. Prepare
valid `Personal.canvas`, distinct `Second.canvas`, multiline Unicode `Note.md`,
malformed `Broken.canvas`, a symlink escape, `LifeOS-other`, and an outside
file. After fixture setup, compare every regular-file hash/length/mtime,
symlink destination, and relative entry set before and after each operation.
Fixture-only enumeration is allowed; never enumerate the user's production
vault. Application-support grant writes stay outside the vault assertion.

## Acceptance and stops

Mounted evidence must show attach, Canvas open, nonidentity pan/zoom, picker
cancel/reopen, malformed-Canvas error with unchanged viewport, Markdown
source/Back, ready-state Markdown preview, second Canvas routing, and zero
fixture mutations. Report mounted seams separately from actual native picker
evidence. Record source SHA, OS/Xcode/destination, test names, screenshots,
viewport values, and the manifest comparison.

Stop for a continuation leak/double resume, overlapping picker, stale-result
publication, viewport reset, containment bypass, or vault mutation. If
testmanagerd/CoreSimulator refuses execution, retain the exact failure and
mark the runtime lane blocked; do not kill Apple system daemons or call builds
runtime acceptance.
