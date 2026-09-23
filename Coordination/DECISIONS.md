# LifeOS decisions

Updated 2026-09-23 Europe/Berlin. Historical milestone detail is summarized
in Coordination/archive; task contracts remain authoritative for execution.

## Product authority

- Native SwiftUI/WidgetKit on Mac and iPhone is the product; Windows over
  Tailscale is the private structured-data/document boundary.
- Calendar, finance, HealthKit/Zepp, Obsidian, tax, usage and widgets keep
  their domain authority. Do not add a competing universal store.
- Missing live data stays unavailable; production has no demo fixtures.
  No in-app advisor or conversational AI; calorie-photo estimation is the
  only permitted AI flow.
- SF Pro/system typography, semantic SF Symbols, compact hierarchy, distinct
  palette, green estimates, orange calories, direct manipulation and
  interruptible Reduce Motion-aware animation are product constraints.

## Execution and acceptance

- Use one Luna implementation worker at a time; Astra reviews concrete diffs
  and evidence in batches. Workers must not invent missing shared signatures.
- Current source bytes outrank stale prose. A receipt is valid only for its
  declared source SHA and scope. Source presence is not runtime acceptance;
  unknown, unavailable, unsupported, failed and pending stay distinct.
- Each accepted tranche records exact files, evidence, complexity, cleanup,
  commit/push and local/origin parity. Never claim completion by percentage.
- Apple test lanes are serial, use one owned simulator and separate artifact
  paths. Never claim a stopped, interrupted or uncollected test run as green.

## Sync and domain boundaries

- Sync uses bounded, canonical payloads and durable local application before
  acknowledgement. Device identity and remote timestamps are not trusted
  without the protocol's authenticated evidence.
- Windows relay binds to loopback by default, denies Windows administration,
  bounds framing/concurrency and stays unavailable until an authenticated
  handler is injected.
- Obsidian Canvas routing remains read-only for Markdown-backed sessions;
  vault selection/revocation and journal/resource handoff are transactional.
- CP-B Batch A is complete. Batch B's validator/history contract is in
  tasks/p04-cpb-batch-b-amendment.md; keep its adapter ledger empty.
  B-D use injected bindings. Production registration is blocked by trusted
  descriptor membership and populated-remote legacy reconciliation.
- Zepp proprietary metrics remain unsupported without a legitimate source;
  physical HealthKit/Zepp provenance is still pending.

## Current evidence

- main and origin/main match at 09f5575; CP-B Batch B is pushed.
- Astra static review is GO and 57/57 focused training tests passed on iOS 27.
- Broad logic result is 1,621/1,640 on iOS 26.5; the simulator selector fix
  and 19 narrow Planning/HealthKit test failures remain open.
- Windows runtime/ACL, physical iPhone, live provider, native picker/vault,
  final security and whole-app acceptance are still unverified.
