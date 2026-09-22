# Active LifeOS execution

Status: IN PROGRESS — P00/P01/P02/P03 calendar, P04 training payload, P05
D1 graph/session, Xcode 27 compatibility, bounded P06-A native Canvas, and
P06-B planning workspace transaction checkpoint complete; CP-B adapters paused;
release NO-GO,
updated 2026-09-22.

## Current checkpoint

main and local origin/main match at picker-hardening checkpoint 1df4642, with
chooser source 433ea64, transaction workspace 86baaa8, and inspector 454f4d1.
P00 generated the schemaVersion 2 requirement ledger and capability inventory.
The ledger has 258 leaves, 7 aliases, 0 accepted, 183 partial source states and
75 missing states. It is evidence-led, not a completion percentage.

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
The next adapter attempt is blocked by CP-B: SyncStoreKind, replication
metadata migration, command-to-wire identity persistence, signing/sequence
ownership, and training tombstone semantics are absent or unsealed. P05 graph
review may advance independently; no worker may guess these interfaces.

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

## Next execution

1. P04: finance, fitness, nutrition and local-record adapters
   with local durability before acknowledgement.
2. P06-B: mounted native picker probes and real-vault round trip from
   tasks/p06b-mounted-picker-plan.md; retain the CP-B adapter pause
   until shared persistence identities and tombstones are sealed.
3. P07-P16: visual/motion system, screen migration, widgets, providers,
   security cleanup, and target composition.
4. P17/P18: Windows/live-provider, physical-device, and final evidence only
   when the environments are available.

Every tranche must state base SHA, exclusive files, named symbols, invariants,
tests, evidence, complexity, stop conditions, review result, commit/push and
remote parity. No source/build changes were made by P00.
