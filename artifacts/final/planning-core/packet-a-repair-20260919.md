# Planning storage Packet A repair

Date: 2026-09-19 Europe/Berlin
Release: NO-GO; this receipt clears only the Packet A repair gate.

## Scope

- Additive optional-key decoding while required fields and semantic validation remain strict.
- SQLite payload type/count/ceiling/length checks before allocation or hashing.
- NUL-safe, explicit-length text binding for all persisted strings.
- Regression coverage for additive keys, missing/wrong fields, oversized payloads, and public NUL inputs.

## Changed files

- `ios/Planning/PlanningStorageDomain.swift`
- `ios/Planning/PlanningMutationJournal.swift`
- `ios/Planning/PlanningConflictResolver.swift`
- `ios/LifeOSTests/PlanningStorageDomainTests.swift`
- `ios/LifeOSTests/PlanningMutationJournalTests.swift`
- `ios/LifeOSTests/PlanningConflictResolverTests.swift`
- `ios/LifeOSMacSnapshotTests/PlanningDurabilityTests.swift`

## Evidence

- Storage guard: PASS; 40.6 GiB free; 710 MiB global DerivedData; no active simulator.
- Mac build-for-testing: exit 0; `/private/tmp/lifeos-planning-packet-a-repair-controller-20260919b`.
- Focused elevated Mac suite: 19/19, 0 failures; `TEST EXECUTE SUCCEEDED`; log at `/private/tmp/lifeos-planning-packet-a-repair-controller-20260919b-test.log`.
- Generic iOS device SDK build-for-testing: exit 0; `TEST BUILD SUCCEEDED`; log at `/private/tmp/lifeos-planning-packet-a-repair-controller-ios-20260919b-build.log`.
- iOS simulator and physical iPhone runtime remain unavailable; no runtime pass is claimed.
- Astra Medium final review: ACCEPT. No blocking findings; no deferred feature approval.

## Deferred

Publication/outcome expansion, durable keepBoth/conflict idempotency, vault coordination/bookmarks/symlink closure, graph/UI/gateway wiring, terminal payload reclamation, and live Obsidian round-trip remain later packets.
