## 2026-09-22 P06-B planning workspace transaction checkpoint

- `86baaa8` is the validated P06-B source checkpoint. It adds the read-only
  Calendar-to-Obsidian `.canvas` workspace, transactional vault selection,
  journal/resource handoff, and mirrored iOS/macOS regressions.
- Selection persistence uses a bounded composite record plus durable pending
  and explicit decision records. Recovery rolls back before a decision, keeps
  only a matching decided candidate, validates transaction/device evidence,
  and keeps legacy pending records rollback-only.
- Initialize, attach, and restore prepare candidate journals before publishing
  access or replacing installed resources. Ordinary candidate rejection keeps
  the old workspace; uncertain access commits invalidate access and release
  writer resources. Revoke stays serialized and reports failed durability.
- Private-file removal flushes the existing parent directory even when the
  entry is already absent. The test-only fault seam sits between unlink and
  directory flush; production defaults to no fault.
- Validation: Astra medium final review had no P1/P2 blocker; Xcode 27 macOS
  focused lane passed 107/107, and the fresh serial iOS 27 simulator rerun
  passed 62/62 focused tests. These are focused code-boundary gates, not full
  release evidence for CP-B, signed UI, physical iPhone, Windows, providers,
  or final security.

## 2026-09-22 P06-B read-only node inspector

- `454f4d1` is the accepted source checkpoint after Astra medium review. It
  adds selected Canvas node metadata, exact `LifeOS/` Markdown reference
  validation, bounded read-only preview, refresh/back, Mac trailing inspection,
  iPhone sheet presentation, and late-result guards for selection, vault,
  lifecycle, and cancellation changes. It does not create, edit, publish, or
  network-read documents.
- Xcode 27 macOS focused suites passed 73/73: 22 interaction and 51 workspace.
  The iPhone 17 run passed all 21 interaction tests and all new inspector tests;
  four older workspace tests failed after the offline Windows host caused
  backend/websocket timeouts. Astra found no P1/P2 inspector blocker, but the
  test-host isolation issue stays qualified and separate from this checkpoint.
- Mounted native presentation, signed/App Group behavior, physical-device
  input, real-vault round trip, and final visual review remain open.

## 2026-09-22 P06-B existing-document chooser

- `433ea64` is pushed on `main` and `origin/main` after Astra medium's
  post-correction READY TO CHECKPOINT review. The chooser accepts one existing
  `.canvas` or `.md` selected inside the attached vault's exact `LifeOS/`
  directory; component containment, traversal/query/fragment, extension,
  symlink, generation, and lifecycle checks remain mandatory.
- Canvas selection keeps the current project and viewport until a candidate
  opens successfully. Markdown is a read-only inspector preview. Cancellation,
  failure, stale results, and retry preserve or clear state deliberately; a
  successful retry clears all four prior error/retry fields.
- The tranche introduces no vault mutation, enumeration, indexing, network,
  or CP-B adapter behavior. The six-file source allowlist and mirrored
  contract tests are the accepted scope.
- Swift parsing, macOS and iPhone 17 arm64 build-for-testing passed. Mac test
  execution was blocked by testmanagerd sandboxing and the iOS focused run by
  CoreSimulator refusal; mounted picker/viewport runtime evidence is pending.

## 2026-09-22 P06-B mounted picker hardening

- `1df4642` is pushed on `main` and `origin/main` after Astra medium's final
  source gate. The native picker now retains AppKit ownership through sheet
  completion, dismisses the owned UIKit picker through its actual relationship,
  returns nil for pre-presentation cancellation, and uses static representable
  teardown with owner tokens.
- SwiftUI refuses overlapping picker tasks, disables all competing open/retry
  controls while a picker is active, clears document tickets on teardown, and
  surfaces sanitized picker errors. Folder/document public APIs and
  `asCopy: false` remain unchanged.
- Mac and iPhone 17 arm64 build-for-testing passed. Native mounted picker,
  interactive dismissal, viewport, and real-vault no-mutation evidence remain
  pending; the exact next contract is `tasks/p06b-mounted-picker-plan.md`.
