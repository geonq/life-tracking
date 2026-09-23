# Active LifeOS execution

Status: IN PROGRESS — P00/P01/P02/P03 calendar, P04 training payload, P05
D1 graph/session, Xcode 27 compatibility, bounded P06-A native Canvas, and
P06-B planning workspace transaction checkpoint complete; CP-B batch A
complete. Two source-confirmed security fixes are next, before CP-B batch B;
release NO-GO. Updated 2026-09-23.

## Current checkpoint

main and origin/main are pushed at `c1b811e`, including `fbeb81c`,
`4fdf23e`, `0171b2a`, `691590d`, and `79dcf69`. Do not infer other branch
parity. P04 SyncStoreKind is at ebef1ac; native picker tests remain at
7cc189f, following chooser 433ea64, workspace 86baaa8, inspector 454f4d1, and
lifecycle checkpoint 4436211.
P00 generated the schemaVersion 2 requirement ledger and capability inventory.
The ledger has 258 leaves, 7 aliases, 0 accepted, 183 partial source states and
75 missing states. It is evidence-led, not a completion percentage.

The design-contract correction at `4fdf23e` is Astra medium READY; generic
arm64 iOS 27 build-for-testing and five focused iPhone 17/iOS 27 design tests
passed. Nutrition-photo descriptor fix at `c1b811e` is Astra READY; 31 focused
API tests, API typecheck and diff-check passed. Mac evidence does not establish
Windows reparse-point behavior; native Windows tests and protected file/parent
ACLs remain required. Simulator is shut down; 22 GiB remain free.

## Current native checkpoint

P05 D1 is accepted and pushed at ca2caf1. It covers bounded graph/parser/
spatial primitives, Canvas edit/session state, atomic vault access-context
checks, and focused regression sources. The follow-up 0451afb restores
URL-safe sync decoding and Xcode 27 compatibility. The follow-up 80579bc
prepares canonical calendar bytes before commit and keeps the global Finance
date codec unchanged. P06-A is pushed at 4ff27e3 with native Canvas
viewport/input ownership, touch quarantine, shared geometry, presentation
caching, retry recovery and focused platform regressions. The committed
mainline generic iOS build passes; final mainline macOS evidence is 405/405
full tests and 19/19 focused interaction tests. The worker’s iOS 27 focused
evidence is 18/18; physical native input remains open.

P01 is pushed at a21ccf3 with the shared contract correction at 673dc0a. P02
is pushed through 038cd37 and includes authenticated exchange integration,
stream-head/index migration, dependency-aware bounded paging, contiguous
device frontiers, separate acknowledgement cursor progression, and nested
signature verification. Focused Python evidence is 21 passing tests with one
crypto-dependent verifier skip on this Mac; the Xcode 27 Mac lane is now green.
P03 is pushed at e76be67 and includes target activation plus a strict bounded
calendar wire codec. Durable calendar wrapper, adapter, composition, ACK
separation, compaction/frontier hardening, and focused regressions are pushed
at 9d222ac. API evidence is 160/160
tests and focused gateway evidence is 23 passed with one crypto-dependent skip.
P04 training payload serialization, bounded local canonical JSON, NFC and
numeric/domain/parser regressions are pushed at b0e52e1 after Astra static PASS.
No durable fitness store adapter is claimed yet; native logic lanes are green,
while signed UI, physical-device, and external-provider evidence remain open.
The closed 17-case SyncStoreKind registry is pushed at ebef1ac; macOS and
iOS arm64 builds pass and protocol tests compiled, but their runtime remains
unverified. Astra sealed tasks/p04-cpb-training-adapter-contract.md. CP-B
batch A schema-3 bootstrap state, stable entity-key map, bind and bootstrap is
complete. B-D may run only against injected bindings. Production registration
E remains blocked by trusted descriptor membership and populated-remote legacy
reconciliation. The full plan defines intents, sequence/signing, remote apply,
receipt retention, exact tests and complexity limits; no worker may guess.

P06-B now has a pushed read-only Calendar-to-Obsidian Canvas workspace with
durable selection transaction recovery and prepare-before-publish journal
handoff. Mac focused evidence is 107/107 and iOS simulator focused evidence is
62/62; real vault round trip, native graph gestures, CP-B transport, and device
evidence remain open.

The follow-on inspector is pushed at 454f4d1. It provides read-only node
metadata and in-vault Markdown preview/refresh with mirrored Mac/iPhone logic
coverage. Mac focused evidence is 73/73; the iPhone run passed all inspector
tests but four older workspace tests failed after offline-host network timeouts.
Treat that iOS run as qualified, not green; mounted UI and test-host isolation
remain open.

The existing-document chooser is pushed at 433ea64 after Astra medium review.
It validates one existing Canvas or Markdown file inside the attached vault's
LifeOS directory, preserves the current Canvas on failure/cancellation, and
keeps Markdown read-only. Swift parsing plus macOS and iPhone 17 arm64
build-for-testing passed. Mac testmanagerd and iOS CoreSimulator blocked
runtime execution, so mounted picker/viewport evidence remains pending.

Picker hardening is pushed at 1df4642 after Astra medium READY TO COMPILE. The
AppKit sheet and UIKit picker retain ownership through dismissal, SwiftUI
prevents overlapping tasks and competing controls, representable teardown is
static and owner-token guarded, and picker errors are sanitized. Both Apple
arm64 build-for-testing lanes pass. The mounted probes and real-vault
no-mutation round trip are specified in tasks/p06b-mounted-picker-plan.md.

The source evidence packet at c4243a3 adds the DEBUG viewport probe and
mirrored hosted lifecycle/fixture tests. Follow-up 4436211 removes SwiftUI
presenter state writes during representable reconciliation using weak
owner-token storage. Astra medium READY; Xcode 27/macOS 27 hosted tests passed
15/15 with zero runtime warnings; fresh macOS and iPhone 17 arm64
build-for-testing passed. Controlled selection still does not prove native
picker presentation or the real-vault round trip.

P06-B native picker tests are added at 7cc189f: four macOS cases cover
owner-sheet presentation, occupied-sheet rejection, host closure, and task
cancellation/lifetime reacquisition; four iOS cases cover mounted presentation,
occupied-presenter rejection, adaptive-dismissal callback, and task
cancellation/lifetime reacquisition. Astra medium returned READY TO CHECKPOINT.
Mirrored suites parse and match; serial macOS 27 and iOS Simulator arm64
build-for-testing passed. Picker runtime and isolated vault-manifest evidence
remain pending; the earlier macOS XCTest launch canceled before tests began.

## Next execution

1. Fix/test bounded Windows `RotatingLogSink` redaction across arbitrary
   output chunks and EOF/flush; Astra medium reviews the diff.
2. Resume CP-B batch B: persist each successful local command as an intent in
   the same transaction as its local receipt; export is never a sync ACK.
3. Batch C seals intents with the replication key and atomically commits signed
   bytes, entity heads and contiguous sequence allocation.
4. Batch D applies verified operations and persists receipts before ACKs; do
   not compact tombstones or replay evidence in CP-B.
5. Keep batch E production registration blocked until trusted descriptor
   membership and populated-remote legacy reconciliation are resolved.
6. Retry P06-B native picker runtime and isolated vault-manifest evidence when
   Apple test services permit it; continue remaining visual, motion, widgets,
   providers, Windows, device and final-security gates.

The remaining source-confirmed PR #1 issue is Windows `RotatingLogSink`; GitHub
review-thread state is unverified after `c1b811e` because the saved `gh` token
is invalid. SSH Git authentication/push works. No completion percentage is
calculated from these checkpoints.
