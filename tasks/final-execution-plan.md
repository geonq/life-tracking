# LifeOS final execution plan

Updated 2026-09-22 Europe/Berlin. Authoritative design remains in
artifacts/blueprint/20260921, with R20-06-DISPATCH as the latest contract
precedence. Current implementation checkpoint is 1df4642; the transaction
workspace base is 86baaa8 and the inspector base is 454f4d1.
Release is NO-GO.

## Rules

- One Luna worker at a time, one exact disjoint ownership set.
- Astra reviews the actual diff and focused evidence after each cohesive batch.
- No worker invents shared DTOs, signatures, migrations, route payloads or
  persistence boundaries. Escalate exact conflicts.
- Real data is authoritative; fixtures are explicit and never product data.
- Keep local durability before showing Saved. Preserve pending operations until
  acknowledged. Never silently merge by wall-clock time.
- Commit and push each accepted tranche from its observed base; update
  HANDOFF, PHASE_STATUS and ACTIVE with the resulting SHA.
- Apple lanes use the storage guard, serial xcodebuild, owned result paths and
  explicit result validation. Stop targeted disposable processes only.

## Packet sequence

P00 is complete and documentation-only. Its ledger is the sole current
requirement/evidence inventory.

P01 -> P02 -> P03/P04. P01 owns shared replication declarations, canonical
encoding, identity/key custody, transport and R20 validators. P02 owns the
signed local relay/gateway and does not deploy while Windows is unavailable.
P03 owns calendar and finance durable adapters. P04 owns fitness, nutrition,
supplements and lifestyle durable adapters.

P05 depends on P00/P01 and reviews the eight untracked D1 files. P06 depends on
P01/P05 and owns native planning Canvas, inspector, viewport, gesture bridge,
vault observer/project coordinator and planning transport seam. The read-only
inspector checkpoint `454f4d1` covers selected-node metadata and in-vault
Markdown preview. The chooser checkpoint `433ea64` adds the typed
Canvas/Markdown opening path for one existing document under attached
`LifeOS/`. Picker lifetime hardening is pushed at `1df4642`; the next bounded
tranche is the mounted probes and real-vault round trip in
`tasks/p06b-mounted-picker-plan.md`.

P07 establishes the shared visual/motion/orb primitives. P08 repairs calendar
interaction. P09 integrates finance and live-readback boundaries. P10 owns
fitness/training/nutrition product behavior. P11 owns HealthKit export,
reconciliation and source-qualified Zepp handling. P12 owns provider-neutral
usage and manual Gemini boundaries. P13 owns tax retention and sanitized sync.
P14 owns widgets, lock-screen catalog, App Intents and personal install flow.

P15 performs independent security/dead-path hardening. P16 composes app targets,
stores, navigation and startup fences. P18-I owns receipt/archive/data
authority. P17 verifies Windows deployment only when the host is available.
P18-E performs final evidence, visual, device, provider and adversarial gates.

## Worker handoff contract

Each dispatch includes base SHA, exact allowlist, contract file order, symbols,
invariants, migration rules, focused tests, evidence path, complexity and
stop conditions. The worker reports changed paths, source hashes, command exits,
result paths, skipped/unknown gates, cleanup and unresolved conflicts.

## Completion evidence

Use classes S source, L local, M Mac runtime, I simulator, W Windows,
P physical/provider, and U unsupported. A requirement is not accepted because
its source exists or a test fixture renders. Windows and physical-device gates
remain separate from Mac/simulator evidence. Unknown is not denied; unsupported
is not a hidden failure.

Required final journeys include local/offline sync and replay, calendar gestures,
finance live readback/import/reconciliation, workouts/HealthKit/Zepp provenance,
nutrition confirmation, tax privacy, usage/Codex/Claude/manual Gemini,
Obsidian Mac-to-vault-to-iPhone round trip, widgets/lock screen/Shortcuts,
Windows outage/rejoin, storage bounds, visual/motion review and adversarial
security.

## Current external blockers

The Windows host was not contacted by P00 and remains unavailable by task
constraint. Xcode 27 and SDK settings are installed and the Xcode license is
accepted, but no valid signing identity or provisioning profile is present.
The iOS 27 simulator logic lane is green for its previously completed focused
lanes; the current chooser build-for-testing passed, while runtime execution
was blocked by CoreSimulator. Signed UI and physical runtime evidence remain
unknown. Banking consent,
provider quotas, iCloud vault choice, HealthKit/Zepp permissions, App Group
registration and personal-device signing are also unknown.

Never label the application complete, secure, flawless, or runtime-accepted
until the ledger rows and required S/L/M/I/W/P gates are actually closed.
