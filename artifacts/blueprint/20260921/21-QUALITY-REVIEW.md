# Code quality and Astra wave review contract
Applies only after execution go. This planning pass does not assert these checks passed.

## Required engineering rules
- Swift UI/coordinator state @MainActor; stores actors or documented existing locked classes.
- Sendable DTOs immutable; new @unchecked Sendable requires exact lock/lifetime proof and Astra acceptance.
- Existing @unchecked stores must be audited rather than blindly relabeled actors, which breaks synchronous callers.
- No Task.detached capturing views/stores/HealthKit references; heavy pure work uses owned actor/executor.
- No await in locked critical sections; actors recheck version after suspension before durable mutation.
- Every long-lived Task has owner/cancel/deinit/scene shutdown; no immortal polling just because a view exists.
- Bound bytes before decode, counts before allocations, image dimensions before full rasterization.
- No sort/filter/map of full datasets per drag/frame; precompute revision-keyed paths/indexes.
- State Big O including encoding/fsync; dictionary expected O(1), not guaranteed worst-case O(1).
- Checked integer money overflow; Decimal prices/quantities; stable timezone/calendar semantics.
- No arbitrary shell/executable/URL supplied by remote providers; fixed argv and validated absolute binaries.
- No silent demo fallback, generic advisor/AI coaching or fabricated proprietary metrics.
- Never log credentials, note bodies, raw PDFs/tax text, health readings or bank identifiers.

## Safe refactor vs expansion
Safe: replace duplicate local token with existing central token; indexed lookup preserving order/IDs;
extract pure projection with same serialized schema; remove proven unused helper after consumers migrate.
Not safe without amendment: new store/framework, new schema/ownership, new auth flow, changed money semantics,
new automatic health inference, new OS minimum, broad package upgrades, removing unconnected required features.
Do not rewrite accepted code because it looks old. Provide defect/measurement or concrete duplication evidence.
Dead-code row must include symbol, target memberships, static+string references, generated/macro/intents use,
replacement symbol, persisted-key compatibility and removal owner. Zero rg hits alone is insufficient.
Fixtures remain test/debug-only; release selection path must be impossible, not just visually labelled.

## Packages / supply chain
No new Swift package is authorized. Use system SwiftUI/Foundation/CryptoKit/SQLite/HealthKit/WidgetKit.
No JS/CSS/React/Skia runtime in app. MIT references require pinned commit/license and attribution if code adapted.
P02 cryptography is the only proposed new Python dependency; CP-E verifies available version,
wheel support on actual Mac/Windows architecture, license, transitive hashes and lock process before pinning.
Do not invent version numbers or install unpinned packages. Retain existing FastAPI/ASGI dependencies.
P15 security updates may change package-lock only with manifest compatibility and advisory evidence.
No broad npm audit fix --force; major upgrades need explicit amended packet.
Pin CI actions by full reviewed SHA and XcodeGen by verified release/checksum; no guessed checksum.
CI pull_request never gets secrets for fork code. Immutable dependency provenance recorded in release receipt.

## Target membership
P16 exclusively owns project.yml; no manual generated pbxproj edits.
ios/Sync app targets only; HealthKit implementation iOS app only; pure reconciliation DTO may compile on Mac.
Widget targets only receive pure models, snapshot reader, coordinated intent writes; no relay/health/provider tasks.
Existing broad Shared membership must exclude new executable services; compare explicit source lists after generation.
Do not list same file twice via folder inclusion+explicit path; remove only verified duplicate membership.
OS27 identifiers cannot leak through unguarded public signatures or widget initializer paths.

## Wave rubric — reject on any material failure
|Axis|Required reviewer evidence|
|---|---|
|Correctness|Named requirements→symbols→outcome; empty/error/cancel/duplicate/concurrent cases|
|Authority|One writer per domain; provider facts not user editable; no unsupported synthetic values|
|Persistence|Crash boundary table, old-schema retention, durable receipt before success, safe rollback|
|Security|Auth/signature/epoch/path/body bounds; least privilege; no sensitive logs/exfiltration|
|Concurrency|Task owner, reentrancy check, lock scope, no stale UI result, revocation fence|
|Complexity|Input caps, expected/worst runtime, allocation/write amplification, no nested full scans|
|Design|Compact hierarchy, full money/title readable, brand color roles, meaningful states|
|Motion|Direct tracking, interrupted reversal, one owner, reduced/low-power/offscreen stop|
|Availability|Exact member/platform/SDK guard, old fallback, actual selected toolchain evidence|
|Proof|Source hash, command/result, actual capture, environment exclusions; no inferred pass|

Astra result ACCEPT / REQUEST CHANGES with file:symbol, violated invariant, minimal correction and affected check.
Review waves W1/W2/W3/W4/W5 in original10; no mandatory full test suite per micro-edit.
Retain targeted migration/auth checks before real data is changed; batch ordinary UI/behavior after integration.
Planning depth cannot replace adversarial review of the actual diff or runtime/device evidence.
