# Baseline, authority and decisions
## Evidence hierarchy
Actual source + current git state > receipt scoped to its SHA > coordination narrative.
Observed HEAD and local origin/main: d3e62b7d265259dd3954c719365d161328aa32dd.
d3e62b7 is the graph design document, 4b170a8 coordination, 5dae724 filesystem adapter.
Packet A/B/C acceptance is historical scoped evidence; it is not whole-product release approval.
HANDOFF/PHASE_STATUS/ACTIVE still claiming a clean 5dae724 checkout are incorrect.
The “258 leaves, zero accepted” registry prose is not proof of zero implemented features.
P00 must link receipts to individual requirements, retaining source/local/live/device distinctions.
Do not reset the registry, reimplement accepted code, or extrapolate an overall percentage.

## Unaccepted D1 candidate
Existing untracked files:
- ios/Planning/PlanningMarkdownLinks.swift
- ios/Planning/PlanningGraphProjection.swift
- ios/Planning/PlanningSpatialIndex.swift
- ios/Planning/PlanningCanvasEdit.swift
- ios/Planning/PlanningCanvasSession.swift
- ios/LifeOSMacSnapshotTests/PlanningGraphTests.swift
- ios/LifeOSMacSnapshotTests/PlanningCanvasSessionTests.swift
- ios/LifeOSTests/PlanningGraphTests.swift
These are inspectable candidate work, not discarded work and not approved production code.
Historical reports of 98 Mac and 3 iOS tests are unverified in this planning pass.
P05 assesses actual bytes once; repair findings rather than restart the architecture.

## Required bootstrap inspected
Global CLAUDE.md/AGENTS.md; project AGENTS.md; HANDOFF/DECISIONS/PHASE_STATUS;
tasks/ACTIVE.md, todo.md, final-execution-plan.md; design coordination 00/01/03.
Project CLAUDE.md and .claude-modules are absent.
Design repo AGENTS/HANDOFF identify the native app repo as source authority.
Read-only API/reference/architecture reports are inputs, not independent release certification.

## Binding decisions
D01 Native SwiftUI iOS 17/macOS 14; retain stores, reducers and file publication. No database rewrite.
D02 One motion owner, LifeOSMotion in DesignTokens.swift; Typography roles are already compact.
Fix oversized call sites/layouts rather than indiscriminately shrinking text below readable sizes.
D03 System SF Pro and SF Symbols. Main brand #0253C4; interactive blue #036BFC.
Green estimates explicitly override old orange-estimate prose. Orange remains calories/warnings.
D04 True direct gesture tracking has no spring; settle/hero transitions may use restrained springs.
D05 Windows owns bank/provider secrets and provider refresh; Apple devices own durable local edits.
D06 Mac relay during outage carries signed domain operations. It is not a second bank connector.
D07 App-level device pairing/signatures authenticate new replication regardless of network route.
D08 Existing nearby calendar protocol stays opt-in and isolated until authenticated mutation envelopes replace snapshot writes.
No requirement to manufacture an MCSession certificate: OOB authentication is the actual identity boundary.
Never treat encryptionPreference.required or displayName as authentication.
D09 Preserve conflict branches for simultaneous edits; wall time never chooses a silent winner.
D10 Compaction needs durable ACKs from every enrolled replica; Windows outage delays compaction.
D11 Markdown/YAML owns note meaning; standard Canvas owns authored arrows/layout.
Creating a Canvas arrow does not silently add Markdown links. “Link notes” is a distinct command.
D12 Use native orb for meaningful long operations only; stop at result/cancel/background.
D13 Only calorie-photo AI; factual imported observations are permitted, advice generation is not.
D14 Keep user data on reinstall; export/recovery first if provisioning requires bundle identity change.
D15 Personal Team capability preflight precedes optional expensive widget integration work.
App Group/HealthKit entitlements in source are not evidence the actual provisioning profile allows them.
D16 All domain mutations must have local durability before showing “Saved”; remote success is separate.
D17 Batch verification at cohesive boundaries; retain targeted integrity/security checks before real-data migration.
D18 No claim of flawless animations or security from theoretical planning alone.

## Authority table
|Domain|Durable authority|Windows offline / conflict|
|---|---|---|
|Calendar native events|LifeOS domain store|Edit locally; merge causally; overlapping changes conflict|
|External calendar/reminders|Existing external source if configured|Read cached source; no new mirror authority|
|Planning notes|User-selected vault files + local unpublished drafts|Edit cached files; hash/CAS conflicts preserved|
|Bank observations|Enable Banking via Windows|Read last snapshot with timestamp; no fabricated refresh|
|Imports/recurring/budgets|LifeOS local stores + replicated mutations|Edit/import; exact provenance; manual overrides persist|
|Investments|Statement observations, separately timestamped valuation|No fresh price without source; partial net worth explicit|
|Workouts/meals/supplements/lifestyle|LifeOS local records|Full local logging; causal sync later|
|Health samples|HealthKit on iPhone|Incremental import; Mac receives qualified observations|
|Tax|Local protected original/extraction; sanitized sync projection|Local work; never send raw OCR by generic sync|
|Usage|Reviewed collectors/manual readings|Local CLI if available; manual Gemini stays manual|
|Widgets|Derived App Group snapshot|Read-only cached view with stale/locked states|

## Truly user/device-dependent
U1 User selects the non-Uni vault through each platform picker. Existing Python Trading path is a candidate, not authorization to bind it.
U2 Enroll the actual Mac/iPhone endpoints and confirm pairing fingerprint; no guessed Tailscale IP.
U3 User must unlock/authorize iPhone HealthKit, widgets, USB trust and signing when required.
U4 If Personal Team rejects required capabilities, present exact profile error and choices; no paid enrollment without user choice.
U5 Provide/choose real statements if none available; bank consent expiry requires user reauthorization.
No other product-design choices are deferred to the user. Windows returning is an environment gate.
